# Execute the real selector with controlled Java probes; no Pester or installed JDK is required.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$gate = Join-Path $PSScriptRoot 'studio_pro_gate.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($gate, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw ($parseErrors | Out-String) }
foreach ($name in @('Write-JsonFile', 'Assert-JavaMajor', 'Find-Java')) {
    $definition = $ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if ($null -eq $definition) { throw "Missing gate function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}

$JavaMajorVersion = 21
$root = Join-Path ([System.IO.Path]::GetTempPath()) ('mxrb-jdk-test-' + [Guid]::NewGuid().ToString('N'))
$resultRoot = Join-Path $root 'results'
$primary = Join-Path $root 'jdk21'
$fallback = Join-Path $root 'jdk17'
$previousJavaHome = $env:JAVA_HOME
$script:probes = New-Object System.Collections.Generic.List[string]
$script:mode = 'valid'

function Invoke-CapturedProcess($Executable, $Arguments, $WorkingDirectory, $Stdout, $Stderr, $TimeoutMilliseconds) {
    $script:probes.Add($Executable)
    if ($TimeoutMilliseconds -lt 120000) { throw 'Cold-start probe timeout is too short' }
    if ($script:mode -eq 'timeout') { throw 'Timed out running executable' }
    if ($script:mode -eq 'exit') { return 7 }
    $compiler = [System.IO.Path]::GetFileName($Executable) -eq 'javac.exe'
    $major = if ($Executable.StartsWith($fallback) -or $script:mode -eq 'runtime17' -or
        ($compiler -and $script:mode -eq 'compiler17')) { 17 } else { 21 }
    $version = if ($compiler) { "javac $major.0.13" } else { "openjdk version `"$major.0.13`" 2026-10-20" }
    [System.IO.File]::WriteAllText($Stdout, $version)
    [System.IO.File]::WriteAllText($Stderr, '')
    return 0
}

try {
    New-Item -ItemType Directory -Path $resultRoot -Force | Out-Null
    foreach ($jdkRoot in @($primary, $fallback)) {
        $bin = Join-Path $jdkRoot 'bin'
        New-Item -ItemType Directory -Path $bin -Force | Out-Null
        foreach ($file in @('java.exe', 'javac.exe')) {
            [System.IO.File]::WriteAllText((Join-Path $bin $file), '')
        }
    }
    $env:JAVA_HOME = $fallback
    $selected = Find-Java $root $primary
    if ($selected.home -ne $primary -or $selected.required_major_version -ne 21 -or $script:probes.Count -ne 2) {
        throw 'Explicit JDK 21 was not selected and checked with its compiler'
    }
    foreach ($mode in @('timeout', 'runtime17', 'compiler17', 'exit')) {
        $script:mode = $mode
        $script:probes.Clear()
        $rejected = $false
        try { Find-Java $root $primary | Out-Null } catch { $rejected = $true }
        if (-not $rejected) { throw "Accepted invalid JDK: $mode" }
        if (@($script:probes | Where-Object { -not $_.StartsWith($primary) }).Count -ne 0) {
            throw "Explicit JDK silently fell back: $mode"
        }
        $attempts = @(Get-Content -Raw (Join-Path $resultRoot 'java-rejected-candidates.json') | ConvertFrom-Json)
        if ($attempts.Count -ne 1) { throw "Missing single-candidate diagnostic: $mode" }
    }
    foreach ($bad in @('openjdk version "17.0.1"', 'not a Java version', 'openjdk version "121.0.1"')) {
        $rejected = $false
        try { Assert-JavaMajor $bad 'java' } catch { $rejected = $true }
        if (-not $rejected) { throw "Accepted invalid version: $bad" }
    }
    Write-Host 'PASS: explicit JDK selection, timeout, wrong runtime/compiler, nonzero exit and malformed versions'
} finally {
    $env:JAVA_HOME = $previousJavaHome
    Remove-Item -LiteralPath $root -Recurse -Force
}
