[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Package,
    [Parameter(Mandatory=$true)][string]$ToolRoot,
    [Parameter(Mandatory=$true)][string]$JavaHome,
    [Parameter(Mandatory=$true)][string]$EvidenceDirectory,
    [string]$ScenarioPath,
    [int]$HttpPort = 18080,
    [int]$AdminPort = 18090,
    [int]$BrowserPort = 19222
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$runtimeProcess = $null
$browserProcess = $null
$socket = $null
$evidenceCreated = $false
$adminSecret = [Guid]::NewGuid().ToString('N')
$ownedRoot = Join-Path $env:TEMP ('mxrb-native-runtime-' + [Guid]::NewGuid().ToString('N'))
$report = [ordered]@{ status = 'running'; started_at = [DateTime]::UtcNow.ToString('o'); package_sha256 = (Get-FileHash $Package -Algorithm SHA256).Hash.ToLowerInvariant(); workspace = $ownedRoot }
$script:CdpSequence = 0

function Write-Evidence {
    [System.IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'runtime.json'),
        (ConvertTo-Json -InputObject $report -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Cdp([string]$Method, $Parameters) {
    $script:CdpSequence++
    $identifier = $script:CdpSequence
    $request = ConvertTo-Json -Compress -Depth 20 -InputObject @{ id = $identifier; method = $Method; params = $Parameters }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($request)
    $deadline = New-Object System.Threading.CancellationTokenSource(60000)
    try {
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)
        $socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $deadline.Token).GetAwaiter().GetResult() | Out-Null
        do {
            $message = New-Object System.IO.MemoryStream
            try {
                do {
                    $buffer = New-Object byte[] 65536
                    $received = $socket.ReceiveAsync((New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$buffer)), $deadline.Token).GetAwaiter().GetResult()
                    if ($received.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'Browser closed the debugging connection' }
                    $message.Write($buffer, 0, $received.Count)
                } until ($received.EndOfMessage)
                $response = ConvertFrom-Json ([System.Text.Encoding]::UTF8.GetString($message.ToArray()))
            } finally { $message.Dispose() }
        } until ($response.PSObject.Properties['id'] -and $response.id -eq $identifier)
        if ($response.PSObject.Properties['error']) { throw (ConvertTo-Json $response.error -Compress) }
        return $response.result
    } finally { $deadline.Dispose() }
}

function Evaluate-Browser([string]$Expression) {
    $response = Invoke-Cdp 'Runtime.evaluate' @{ expression = $Expression; awaitPromise = $true; returnByValue = $true; timeout = 50000 }
    if ($response.PSObject.Properties['exceptionDetails']) { throw (ConvertTo-Json $response.exceptionDetails -Depth 10 -Compress) }
    if (-not $response.result.PSObject.Properties['value']) { throw 'Browser expression did not return a serializable value' }
    return $response.result.value
}

try {
    if (Test-Path -LiteralPath $EvidenceDirectory) { throw 'Refusing an existing runtime evidence directory' }
    New-Item -ItemType Directory -Path $EvidenceDirectory | Out-Null
    $evidenceCreated = $true
    foreach ($port in @($HttpPort, $AdminPort, $BrowserPort)) {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
        try { $listener.Start() } finally { $listener.Stop() }
    }
    New-Item -ItemType Directory -Path $ownedRoot | Out-Null
    $app = Join-Path $ownedRoot 'app'
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Package, $app)
    foreach ($directory in @('data/database', 'data/files', 'data/tmp', 'log')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $app $directory) | Out-Null
    }
    $launcher = Join-Path $ToolRoot 'runtime/launcher/runtimelauncher.jar'
    $java = Join-Path $JavaHome 'bin/java.exe'
    if (-not (Test-Path $launcher) -or -not (Test-Path $java)) { throw 'Native Runtime launcher or Java is missing' }
    $metadata = Get-Content -LiteralPath (Join-Path $app 'model/metadata.json') -Raw | ConvertFrom-Json
    $constants = @{}
    foreach ($constant in $metadata.Constants) {
        $constants[$constant.Name] = $constant.DefaultValue
    }
    $constantConfig = ConvertTo-Json -InputObject $constants -Compress
    $configuration = @"
admin { adminPassword = "$adminSecret", port = $AdminPort, addresses = [ "127.0.0.1" ] }
runtime {
  http { port = $HttpPort, addresses = [ "127.0.0.1" ] }
  adminUser.password = "$adminSecret"
  debugger.password = ""
  params {
    MicroflowConstants = $constantConfig
    DTAPMode = D
    DatabaseType = HSQLDB
    DatabaseName = default
    DatabaseJdbcUrl = "jdbc:hsqldb:file:app/data/database/default"
    ApplicationRootUrl = "http://127.0.0.1:$HttpPort/"
    ScheduledEventExecution = NONE
    HashAlgorithm = "BCRYPT:12"
  }
}
logging = [{ name = Console, type = console, autoSubscribe = INFO, levels {} }]
"@
    $configPath = Join-Path $ownedRoot 'runtime.conf'
    [System.IO.File]::WriteAllText($configPath, $configuration, (New-Object System.Text.UTF8Encoding($false)))
    $previousInstall = $env:MX_INSTALL_PATH
    $env:MX_INSTALL_PATH = $ToolRoot
    try {
        $arguments = @('-Dfile.encoding=UTF-8', '-jar', $launcher, ($app + '/.'), $configPath) | ForEach-Object { '"' + $_ + '"' }
        $runtimeProcess = Start-Process -FilePath $java -ArgumentList $arguments -WorkingDirectory $ownedRoot -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput (Join-Path $EvidenceDirectory 'runtime.stdout.log') -RedirectStandardError (Join-Path $EvidenceDirectory 'runtime.stderr.log')
    } finally { $env:MX_INSTALL_PATH = $previousInstall }
    $until = [DateTime]::UtcNow.AddSeconds(120)
    $ready = $false
    do {
        if ($runtimeProcess.HasExited) { throw "Native Runtime exited: $($runtimeProcess.ExitCode)" }
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$HttpPort/" -TimeoutSec 3
            $ready = $response.StatusCode -eq 200
        } catch { Start-Sleep -Milliseconds 500 }
    } until ($ready -or [DateTime]::UtcNow -gt $until)
    if (-not $ready) { throw 'Native Runtime did not become ready within 120 seconds' }
    $report['http_status'] = 200
    $edgeCandidates = @((Join-Path ${env:ProgramFiles(x86)} 'Microsoft/Edge/Application/msedge.exe'),
                        (Join-Path $env:ProgramFiles 'Microsoft/Edge/Application/msedge.exe'))
    $edge = $edgeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $edge) { throw 'Microsoft Edge is not installed' }
    $profile = Join-Path $ownedRoot 'browser-profile'
    $browserArguments = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
        '--remote-debugging-address=127.0.0.1', "--remote-debugging-port=$BrowserPort", ('--user-data-dir="' + $profile + '"'),
        "http://127.0.0.1:$HttpPort/")
    $browserProcess = Start-Process -FilePath $edge -ArgumentList $browserArguments -PassThru -WindowStyle Hidden
    $until = [DateTime]::UtcNow.AddSeconds(45)
    $target = $null
    do {
        try {
            $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$BrowserPort/json" -TimeoutSec 3
            $target = $targets | Where-Object { $_.type -eq 'page' } | Select-Object -First 1
        }
        catch { Start-Sleep -Milliseconds 300 }
    } until ($target -or [DateTime]::UtcNow -gt $until)
    if (-not $target) { throw 'Headless Edge debugging endpoint did not become ready' }
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $socket.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    $until = [DateTime]::UtcNow.AddSeconds(45)
    $pageReady = $false
    do {
        # The initial '/' redirect can destroy an execution context. Read-only
        # readiness probes may retry; the mutating CRUD scenario runs once.
        try { $pageReady = Evaluate-Browser "Boolean(window.mx && mx.data && document.querySelector('input'))" }
        catch { $pageReady = $false }
        if (-not $pageReady) { Start-Sleep -Milliseconds 300 }
    } until ($pageReady -or [DateTime]::UtcNow -gt $until)
    if (-not $pageReady) { throw 'Native page did not render its input widgets within 45 seconds' }
    $report['page_ready'] = $true
    $crudExpression = @'
(async()=>{const call=(method,args)=>new Promise((resolve,reject)=>{const timer=setTimeout(()=>reject(new Error(method+' timed out')),15000);mx.data[method]({...args,callback:value=>{clearTimeout(timer);resolve(value)},error:error=>{clearTimeout(timer);reject(error)},onValidation:()=>{clearTimeout(timer);reject(new Error('validation rejected '+method))}})});const marker='MXRB-native-'+Date.now();const result={steps:[]};let id;try{const object=await call('create',{entity:'Core.Item'});id=object.getGuid();object.set('Name',marker);object.set('Active',true);await call('commit',{mxobj:object});result.steps.push('create');const read=await call('get',{guid:id,noCache:true});if(read.get('Name')!==marker)throw new Error('Read mismatch');result.steps.push('read');read.set('Name',marker+'-updated');await call('commit',{mxobj:read});const changed=await call('get',{guid:id,noCache:true});if(changed.get('Name')!==marker+'-updated')throw new Error('Update mismatch');result.steps.push('update');await call('remove',{guid:id});const remaining=await call('get',{xpath:'//Core.Item[id='+id+']'});if(remaining.length)throw new Error('Delete did not persist');id=null;result.steps.push('delete');result.status='passed';return result;}finally{if(id)await call('remove',{guid:id});}})()
'@
    $scenarioKey = 'crud'
    if ($ScenarioPath) {
        $crudExpression = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $ScenarioPath).ProviderPath)
        $report['scenario_sha256'] = (Get-FileHash -LiteralPath $ScenarioPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $scenarioKey = 'acceptance'
    }
    $report[$scenarioKey] = Evaluate-Browser $crudExpression
    if ($report[$scenarioKey].status -ne 'passed') { throw 'Native browser scenario did not pass' }
    $screenshot = Invoke-Cdp 'Page.captureScreenshot' @{ format = 'png' }
    [System.IO.File]::WriteAllBytes((Join-Path $EvidenceDirectory 'native-page.png'), [Convert]::FromBase64String($screenshot.data))
    $report['status'] = 'passed'
} catch {
    $report['status'] = 'failed'
    $report['error'] = $_.Exception.Message
    $report['detail'] = ($_ | Out-String)
} finally {
    if ($socket) { $socket.Dispose() }
    if ($browserProcess -and -not $browserProcess.HasExited) {
        & "$env:SystemRoot/System32/taskkill.exe" /PID $browserProcess.Id /T /F | Out-Null
    }
    if ($runtimeProcess -and -not $runtimeProcess.HasExited) {
        try {
            $authentication = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($adminSecret))
            Invoke-RestMethod -Uri "http://127.0.0.1:$AdminPort/" -Method Post -ContentType 'application/json' `
                -Headers @{ 'X-M2EE-Authentication' = $authentication } -Body '{"action":"shutdown","params":{}}' -TimeoutSec 10 | Out-Null
        } catch { }
        if (-not $runtimeProcess.WaitForExit(15000)) {
            & "$env:SystemRoot/System32/taskkill.exe" /PID $runtimeProcess.Id /T /F | Out-Null
            $report['forced_runtime_shutdown'] = $true
            $report['status'] = 'failed'
        }
    }
    if (Test-Path -LiteralPath (Join-Path $ownedRoot 'runtime.conf')) { Remove-Item -LiteralPath (Join-Path $ownedRoot 'runtime.conf') }
    $report['finished_at'] = [DateTime]::UtcNow.ToString('o')
    if ($evidenceCreated) { Write-Evidence }
    if ($report.status -eq 'passed' -and (Test-Path -LiteralPath $ownedRoot)) { Remove-Item -LiteralPath $ownedRoot -Recurse -Force }
}
if ($report.status -eq 'passed') { exit 0 }
exit 1
