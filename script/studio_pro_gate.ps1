[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BatchDirectory,
    [string]$WorkspaceRoot = 'C:\mxrb-projects',
    [ValidatePattern('^[a-zA-Z0-9.-]+$')][string]$StudioVersion = '11.12.1',
    [string]$ToolRoot,
    [switch]$BuildToolsOnly,
    [ValidateRange(1,120)][int]$BuildTimeoutMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$batchName = Split-Path -Leaf $BatchDirectory
$workspace = Join-Path $WorkspaceRoot $batchName
$resultRoot = Join-Path $BatchDirectory 'results'
$reports = New-Object System.Collections.Generic.List[object]
$startedAt = [DateTime]::UtcNow.ToString('o')
$toolsReport = $null
$fatalError = $null

function Write-JsonFile($Value, [string]$Path) {
    $json = ConvertTo-Json -InputObject $Value -Depth 30
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-Progress([string]$State, [string]$Label = '', [string]$Message = '') {
    Write-JsonFile ([ordered]@{
        state = $State; label = $Label; message = $Message
        updated_at = [DateTime]::UtcNow.ToString('o'); results = $resultRoot
        completed_cases = $reports.Count
    }) (Join-Path $resultRoot 'progress.json')
    Write-Host ('[{0}] {1} {2} {3}' -f [DateTime]::UtcNow.ToString('o'), $State, $Label, $Message)
}

function Assert-Leaf([string]$Value, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -in @('.', '..') -or
        $Value.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $Value -ne [System.IO.Path]::GetFileName($Value) -or $Value.EndsWith('.') -or $Value.EndsWith(' ')) {
        throw "Invalid $Description in cases.json"
    }
}

function Assert-NoReparse([string]$Path, [switch]$Recursive) {
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Reparse point is not permitted: $Path"
    }
    if ($Recursive) {
        $links = @(Get-ChildItem -LiteralPath $Path -Force -Recurse | Where-Object {
            ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0
        })
        if ($links.Count -gt 0) { throw "Reparse point found under: $Path" }
    }
}

function Get-TransportEvidence([string]$Directory, $Case) {
    $fileHashes = [ordered]@{}
    foreach ($entry in $Case.files.PSObject.Properties) {
        $relative = [string]$entry.Name
        foreach ($segment in $relative.Split('/')) { Assert-Leaf $segment 'transport path segment' }
        if ([string]$entry.Value -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid file checksum: $relative" }
        $filePath = Join-Path $Directory ($relative.Replace('/', '\'))
        $actual = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -cne ([string]$entry.Value).ToLowerInvariant()) { throw "Transported file SHA256 mismatch: $relative" }
        $fileHashes[$relative] = $actual
    }
    if ($fileHashes.Count -eq 0) { throw 'Transported file manifest is empty' }
    $mprPath = Join-Path $Directory ([string]$Case.mpr)
    if (-not (Test-Path -LiteralPath $mprPath -PathType Leaf)) { throw "Missing MPR: $mprPath" }
    $hash = (Get-FileHash -LiteralPath $mprPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne ([string]$Case.sha256).ToLowerInvariant()) { throw "MPR SHA256 mismatch: $mprPath" }
    $sidecar = Join-Path $Directory 'mprcontents'
    $count = 0
    $mprName = $null
    $storage = 'inline'
    if (Test-Path -LiteralPath $sidecar) {
        if (-not (Test-Path -LiteralPath $sidecar -PathType Container)) { throw "Invalid mprcontents: $sidecar" }
        $storage = 'external'
        $count = @(Get-ChildItem -LiteralPath $sidecar -Recurse -File -Filter '*.mxunit').Count
        $namePath = Join-Path $sidecar 'mprname'
        if (-not (Test-Path -LiteralPath $namePath -PathType Leaf)) { throw "Missing mprcontents/mprname: $Directory" }
        $mprName = [System.IO.File]::ReadAllText($namePath).Trim()
        if ($mprName -cne [string]$Case.mpr) { throw "mprcontents/mprname mismatch: $Directory" }
    }
    if ($count -ne [long]$Case.units) { throw "Physical .mxunit count mismatch: $Directory (found $count, expected $($Case.units))" }
    if ($storage -eq 'inline' -and [long]$Case.units -ne 0) { throw "Missing external units: $Directory" }
    return [ordered]@{
        directory = $Directory; mpr = $mprPath; sha256 = $hash
        mxunit_count = $count; mprname = $mprName; storage = $storage
        file_hashes = $fileHashes
    }
}

function Get-SignedStudioTool([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    $version = [string]$item.VersionInfo.ProductVersion
    $fileVersion = [string]$item.VersionInfo.FileVersion
    if ($version -notmatch ('^' + [regex]::Escape($StudioVersion) + '(?:\D|$)') -and $fileVersion -notmatch ('^' + [regex]::Escape($StudioVersion) + '(?:\D|$)')) {
        throw "Wrong Studio tool version: $Path ($version / $fileVersion)"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw "Invalid Studio tool signature: $Path ($($signature.Status))"
    }
    $signer = $signature.SignerCertificate.Subject
    if ($signer -notmatch '(?i)Mendix|Siemens') { throw "Unexpected Studio tool publisher: $Path ($signer)" }
    return [ordered]@{
        path = $item.FullName; product_version = $version; file_version = $fileVersion
        signature = [string]$signature.Status; signer = $signer
        sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function Find-StudioTools {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique
    $candidates = @()
    if ($ToolRoot) {
        $candidates = @(Get-ChildItem -LiteralPath $ToolRoot -Recurse -File -Filter 'mxbuild.exe')
        if ($candidates.Count -eq 0) { throw "MxBuild absent from explicit ToolRoot: $ToolRoot" }
    }
    $known = Join-Path $env:LOCALAPPDATA "Programs\Mendix\$StudioVersion\modeler\mxbuild.exe"
    if (-not $ToolRoot -and (Test-Path -LiteralPath $known -PathType Leaf)) { $candidates += Get-Item -LiteralPath $known }
    foreach ($root in $roots | Where-Object { $candidates.Count -eq 0 }) {
        $mendixRoots = @(Get-ChildItem -LiteralPath $root -Directory -Filter '*Mendix*' -ErrorAction SilentlyContinue)
        foreach ($mendixRoot in $mendixRoots) {
            $candidates += @(Get-ChildItem -LiteralPath $mendixRoot.FullName -Recurse -File -Filter 'MxBuild.exe' -ErrorAction SilentlyContinue)
        }
    }
    $rejections = New-Object System.Collections.Generic.List[object]
    foreach ($candidate in ($candidates | Sort-Object FullName)) {
        try {
            $mxbuild = Get-SignedStudioTool $candidate.FullName
            $studio = $null
            foreach ($name in @('studiopro.exe', 'modeler.exe')) {
                $studioPath = Join-Path $candidate.DirectoryName $name
                if (Test-Path -LiteralPath $studioPath -PathType Leaf) {
                    $studio = Get-SignedStudioTool $studioPath
                    break
                }
            }
            if ($null -eq $studio -and -not $BuildToolsOnly) { throw 'No signed Studio Pro/modeler executable alongside MxBuild' }
            return [ordered]@{ mxbuild = $mxbuild; studio = $studio; install_root = $candidate.Directory.Parent.FullName
                               oracle = $(if ($BuildToolsOnly) { 'mxbuild' } else { 'studio-pro-installation' }) }
        } catch {
            $rejections.Add([ordered]@{ path = $candidate.FullName; error = $_.Exception.Message })
        }
    }
    Write-JsonFile @($rejections.ToArray()) (Join-Path $resultRoot 'studio-tool-rejections.json')
    throw "No signed Mendix Studio Pro $StudioVersion installation with MxBuild was found"
}

function Quote-NativeArgument([string]$Value) {
    $quoted = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $quoted = [regex]::Replace($quoted, '(\\+)$', '$1$1')
    return '"' + $quoted + '"'
}

function Invoke-CapturedProcess([string]$Executable, [string[]]$Arguments, [string]$WorkingDirectory,
                                [string]$Stdout, [string]$Stderr, [int]$TimeoutMilliseconds = 0) {
    $argumentLine = ($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /s /c ""' + $Executable + '" ' + $argumentLine + ' 1>"' + $Stdout + '" 2>"' + $Stderr + '""'
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    # Redirect to files in cmd, not inherited pipes: Gradle daemons may outlive MxBuild.
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw "Could not start: $Executable" }
    try {
        if ($TimeoutMilliseconds -gt 0) {
            if (-not $process.WaitForExit($TimeoutMilliseconds)) {
                & "$env:SystemRoot\System32\taskkill.exe" /PID $process.Id /T /F | Out-Null
                $process.WaitForExit()
                throw "Timed out running executable: $Executable"
            }
        } else {
            $process.WaitForExit()
        }
        if ($null -eq $process.ExitCode) { throw "Missing process exit code: $Executable" }
        return [int]$process.ExitCode
    } finally {
        $process.Dispose()
    }
}

function Find-Java([string]$InstallRoot) {
    $candidates = New-Object System.Collections.Generic.List[string]
    $javaRoots = @($InstallRoot, (Join-Path (Split-Path -Parent $InstallRoot) 'jdk'),
                   (Join-Path (Split-Path -Parent $InstallRoot) 'runtime'))
    foreach ($root in $javaRoots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File -Filter 'java.exe' -ErrorAction SilentlyContinue)) {
                $candidates.Add($file.FullName)
            }
        }
    }
    if ($env:JAVA_HOME) { $candidates.Add((Join-Path $env:JAVA_HOME 'bin\java.exe')) }
    foreach ($command in @(Get-Command 'java.exe' -CommandType Application -All -ErrorAction SilentlyContinue)) {
        $candidates.Add($command.Source)
    }
    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ } | Select-Object -Unique) {
        $adoptium = Join-Path $programRoot 'Eclipse Adoptium'
        if (Test-Path -LiteralPath $adoptium -PathType Container) {
            foreach ($file in (Get-ChildItem -LiteralPath $adoptium -Recurse -File -Filter 'java.exe' -ErrorAction SilentlyContinue)) {
                $candidates.Add($file.FullName)
            }
        }
    }
    $attempts = New-Object System.Collections.Generic.List[object]
    $number = 0
    foreach ($java in ($candidates | Select-Object -Unique)) {
        $number++
        try {
            if (-not (Test-Path -LiteralPath $java -PathType Leaf)) { throw 'java.exe absent' }
            $bin = Split-Path -Parent $java
            $javac = Join-Path $bin 'javac.exe'
            if (-not (Test-Path -LiteralPath $javac -PathType Leaf)) { throw 'JDK compiler javac.exe absent' }
            $out = Join-Path $resultRoot "java-$number.stdout.log"
            $err = Join-Path $resultRoot "java-$number.stderr.log"
            $code = Invoke-CapturedProcess $java @('-version') $resultRoot $out $err 30000
            if ($code -ne 0) { throw "java -version returned $code" }
            $version = ([System.IO.File]::ReadAllText($out) + [System.IO.File]::ReadAllText($err)).Trim()
            $compilerOut = Join-Path $resultRoot "javac-$number.stdout.log"
            $compilerErr = Join-Path $resultRoot "javac-$number.stderr.log"
            $compilerCode = Invoke-CapturedProcess $javac @('-version') $resultRoot $compilerOut $compilerErr 30000
            if ($compilerCode -ne 0) { throw "javac -version returned $compilerCode" }
            Write-JsonFile @($attempts.ToArray()) (Join-Path $resultRoot 'java-rejected-candidates.json')
            return [ordered]@{
                executable = $java; home = (Split-Path -Parent $bin); compiler = $javac; version = $version
                compiler_version = ([System.IO.File]::ReadAllText($compilerOut) + [System.IO.File]::ReadAllText($compilerErr)).Trim()
            }
        } catch {
            $attempts.Add([ordered]@{ path = $java; error = $_.Exception.Message })
        }
    }
    Write-JsonFile @($attempts.ToArray()) (Join-Path $resultRoot 'java-rejected-candidates.json')
    throw 'No usable existing JDK found; nothing was installed'
}

Assert-NoReparse $BatchDirectory
$lockPath = Join-Path $BatchDirectory 'gate.lock'
$lock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew,
    [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    New-Item -ItemType Directory -Path $resultRoot -ErrorAction Stop | Out-Null
} catch {
    $lock.Dispose()
    Remove-Item -LiteralPath $lockPath
    throw
}
try {
    Set-Progress 'preflight' '' 'Reading cases and checking signed Studio tools'
    $casesPath = Join-Path $BatchDirectory 'cases.json'
    $rawCases = [System.IO.File]::ReadAllText($casesPath)
    if (-not $rawCases.TrimStart().StartsWith('[')) { throw 'cases.json must be a JSON array' }
    $cases = @(ConvertFrom-Json -InputObject $rawCases)
    if ($cases.Count -eq 0) { throw 'cases.json is empty' }
    $labels = @{}
    foreach ($case in $cases) {
        Assert-Leaf ([string]$case.label) 'label'
        Assert-Leaf ([string]$case.directory) 'directory'
        Assert-Leaf ([string]$case.mpr) 'MPR name'
        if ([string]$case.label -notmatch '^[a-z0-9][a-z0-9-]*$') { throw 'Invalid case label' }
        if ([System.IO.Path]::GetExtension([string]$case.mpr) -ine '.mpr') { throw 'Expected .mpr filename' }
        if ([string]$case.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid expected SHA256' }
        if ([string]$case.units -notmatch '^\d+$') { throw 'Invalid physical .mxunit count' }
        if ($labels.ContainsKey([string]$case.label)) { throw 'Duplicate case label' }
        $labels[[string]$case.label] = $true
        if (Test-Path -LiteralPath (Join-Path $workspace ([string]$case.label))) { throw "Refusing existing destination: $($case.label)" }
    }
    $orderedCases = @($cases)
    $toolsReport = Find-StudioTools
    $toolsReport['java'] = Find-Java $toolsReport.install_root
    Write-JsonFile $toolsReport (Join-Path $resultRoot 'tools.json')
    foreach ($parent in @($WorkspaceRoot, $workspace)) {
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
        Assert-NoReparse $parent
    }
    $inputs = Join-Path $BatchDirectory 'inputs'
    Assert-NoReparse $inputs
    foreach ($case in $orderedCases) {
        $label = [string]$case.label
        $caseResults = Join-Path $resultRoot $label
        New-Item -ItemType Directory -Path $caseResults | Out-Null
        $source = Join-Path $inputs ([string]$case.directory)
        $destination = Join-Path $workspace $label
        $report = [ordered]@{
            label = $label; started_at = [DateTime]::UtcNow.ToString('o'); status = 'running'
            source = $source; destination = $destination; result_directory = $caseResults
            expected_sha256 = [string]$case.sha256; expected_mxunit_count = [long]$case.units
            mxbuild_exit_code = $null; error = $null
        }
        try {
            Set-Progress 'copying' $label
            Assert-NoReparse $source -Recursive
            $report['source_before'] = Get-TransportEvidence $source $case
            if (Test-Path -LiteralPath $destination) { throw "Refusing existing destination: $destination" }
            Copy-Item -LiteralPath $source -Destination $destination -Recurse
            $report['copy_before'] = Get-TransportEvidence $destination $case
            $stdout = Join-Path $caseResults 'mxbuild.stdout.log'
            $stderr = Join-Path $caseResults 'mxbuild.stderr.log'
            $errors = Join-Path $caseResults 'errors.json'
            $package = Join-Path $caseResults ($label + '.mda')
            $mpr = Join-Path $destination ([string]$case.mpr)
            $arguments = @("--java-home=$($toolsReport.java.home)", "--java-exe-path=$($toolsReport.java.executable)",
                           '--target=package', "--output=$package", "--write-errors=$errors", $mpr)
            $report['command'] = [ordered]@{ executable = $toolsReport.mxbuild.path; arguments = $arguments; working_directory = $destination }
            Write-JsonFile $report (Join-Path $caseResults 'result.json')
            Set-Progress 'building' $label
            $report['mxbuild_exit_code'] = Invoke-CapturedProcess $toolsReport.mxbuild.path $arguments $destination $stdout $stderr ($BuildTimeoutMinutes * 60000)
            $report['stdout'] = $stdout
            $report['stderr'] = $stderr
            $report['errors_path'] = $errors
            $report['errors_present'] = Test-Path -LiteralPath $errors -PathType Leaf
            $report['package_path'] = $package
            $report['package_present'] = Test-Path -LiteralPath $package -PathType Leaf
            if ($report['package_present']) {
                $report['package_sha256'] = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            $report['copy_after'] = Get-TransportEvidence $destination $case
            $report['source_after'] = Get-TransportEvidence $source $case
            $report['status'] = if ($report['mxbuild_exit_code'] -eq 0 -and $report['package_present']) { 'completed' } else { 'build_failed' }
        } catch {
            $report['status'] = 'infrastructure_error'
            $report['error'] = $_.Exception.Message
            $report['error_detail'] = ($_ | Out-String)
        } finally {
            foreach ($entry in @(@('source', $source), @('copy', $destination))) {
                $mprPath = Join-Path $entry[1] ([string]$case.mpr)
                if (Test-Path -LiteralPath $mprPath -PathType Leaf) {
                    $report[($entry[0] + '_final_sha256')] = (Get-FileHash -LiteralPath $mprPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
            $report['finished_at'] = [DateTime]::UtcNow.ToString('o')
            Write-JsonFile $report (Join-Path $caseResults 'result.json')
            $reports.Add($report)
            Set-Progress 'case-finished' $label $report.status
        }
    }
} catch {
    $fatalError = [ordered]@{ message = $_.Exception.Message; detail = ($_ | Out-String) }
    Write-JsonFile $fatalError (Join-Path $resultRoot 'fatal-error.json')
} finally {
    $infrastructureErrors = @($reports | Where-Object { $_.status -eq 'infrastructure_error' }).Count
    $failedCases = @($reports | Where-Object { $_.status -ne 'completed' }).Count
    $status = if ($null -ne $fatalError) { 'fatal_error' } elseif ($failedCases -gt 0) { 'case_errors' } else { 'completed' }
    $summary = [ordered]@{
        status = $status; started_at = $startedAt; finished_at = [DateTime]::UtcNow.ToString('o')
        results = $resultRoot; workspace = $workspace; case_count = $reports.Count
        infrastructure_error_count = $infrastructureErrors; fatal_error = $fatalError
        failed_case_count = $failedCases
        tools = $toolsReport; cases = @($reports.ToArray())
        note = 'Nonzero MxBuild exits or missing packages fail the gate. mxunit_count is a physical transport count, not a SQL unit count.'
    }
    Write-JsonFile $summary (Join-Path $resultRoot 'summary.json')
    Set-Progress $status '' 'Batch finished; inspect summary.json and per-case evidence'
    $lock.Dispose()
    Remove-Item -LiteralPath $lockPath
}
if ($status -eq 'completed') { exit 0 }
exit 1
