#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Write-Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail = ''
    )

    if ($Passed) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
    }

    if ($Detail) {
        Write-Host "    -> $Detail" -ForegroundColor DarkGray
    }
}

function Invoke-PowerShellFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @()
    )

    $psExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($psExe)) {
        $psExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    $stdoutPath = Join-Path $env:TEMP ("odysseus-regression-out-{0}.log" -f ([guid]::NewGuid().ToString('N')))
    $stderrPath = Join-Path $env:TEMP ("odysseus-regression-err-{0}.log" -f ([guid]::NewGuid().ToString('N')))

    try {
        $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath)
        if ($ArgumentList) {
            $args += $ArgumentList
        }

        $proc = Start-Process -FilePath $psExe -ArgumentList $args -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

        $stdout = if (Test-Path $stdoutPath) { Get-Content -Path $stdoutPath -Raw -ErrorAction SilentlyContinue } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content -Path $stderrPath -Raw -ErrorAction SilentlyContinue } else { '' }

        return [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Output = (($stdout + "`n" + $stderr).Trim())
        }
    }
    finally {
        Remove-Item -Path $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir '..\..')
$launchPath = Join-Path $scriptDir 'Launch-Odysseus.ps1'
$auditPath = Join-Path $scriptDir 'Audit-Odysseus.ps1'
$modulePath = Join-Path $scriptDir 'lib\Odysseus.RuntimeChecks.psm1'

$failures = 0

Write-Host 'Launcher/Audit module-layout regression checks' -ForegroundColor Cyan
Write-Host ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

$layoutOk = (Test-Path $launchPath) -and (Test-Path $auditPath) -and (Test-Path $modulePath)
Write-Result -Name 'Installed-layout pathing files exist in workspace tree' -Passed:$layoutOk -Detail "Launch=$launchPath | Audit=$auditPath | Module=$modulePath"
if (-not $layoutOk) { $failures++ }

try {
    $launchRun = Invoke-PowerShellFile -FilePath $launchPath -ArgumentList @('-TestMode')
    $launchOk = ($launchRun.ExitCode -eq 0)
}
catch {
    $launchOk = $false
}
Write-Result -Name 'Launcher preflight executes with module present' -Passed:$launchOk
if (-not $launchOk) { $failures++ }

$launchScriptText = Get-Content -Path $launchPath -Raw -ErrorAction SilentlyContinue
$auditScriptText = Get-Content -Path $auditPath -Raw -ErrorAction SilentlyContinue

$launchGuardPresent = ($launchScriptText -match 'Missing runtime checks module') -and ($launchScriptText -match 'Reinstall Odysseus to restore required launcher files')
Write-Result -Name 'Launcher contains explicit missing-module fail-fast guard' -Passed:$launchGuardPresent
if (-not $launchGuardPresent) { $failures++ }

$auditGuardPresent = ($auditScriptText -match 'Missing runtime checks module') -and ($auditScriptText -match 'Reinstall Odysseus to restore required audit files')
Write-Result -Name 'Audit contains explicit missing-module fail-fast guard' -Passed:$auditGuardPresent
if (-not $auditGuardPresent) { $failures++ }

Write-Host ''
if ($failures -gt 0) {
    Write-Host "Regression checks failed: $failures" -ForegroundColor Red
    exit 1
}

Write-Host 'All regression checks passed.' -ForegroundColor Green
exit 0
