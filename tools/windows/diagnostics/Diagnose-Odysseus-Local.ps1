#Requires -Version 5.1
<#!
.SYNOPSIS
    Runs all Odysseus local-install diagnostic stages in sequence.

.DESCRIPTION
    Executes, in order: Preflight, Bootstrap, Compose, Endpoint. Each stage is
    also independently runnable (Test-Stage-*.ps1). Only a FAIL in a stage
    stops the run; WARN results are reported but do not halt execution.

.PARAMETER StartAt
    Optional stage name to begin from (Preflight, Bootstrap, Compose, Endpoint),
    useful for re-running only the remaining stages after a fix.
#>
[CmdletBinding()]
param (
    [ValidateSet('Preflight', 'Bootstrap', 'Compose', 'Endpoint')]
    [string]$StartAt = 'Preflight'
)

$ErrorActionPreference = 'SilentlyContinue'
Clear-Host

$ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }

$LogDir = Join-Path $env:LOCALAPPDATA 'Odysseus\Logs'
try {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $LogFile = Join-Path $LogDir ("diagnose-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    Start-Transcript -Path $LogFile -Append -ErrorAction SilentlyContinue | Out-Null
    Write-Host "[LOG] Session transcript: $LogFile" -ForegroundColor DarkGray
}
catch {
    # Transcript is best-effort.
}

$stages = @(
    @{ Name = 'Preflight'; Path = Join-Path $ScriptRoot 'Test-Stage-Preflight.ps1' },
    @{ Name = 'Bootstrap'; Path = Join-Path $ScriptRoot 'Test-Stage-Bootstrap.ps1' },
    @{ Name = 'Compose'; Path = Join-Path $ScriptRoot 'Test-Stage-Compose.ps1' },
    @{ Name = 'Endpoint'; Path = Join-Path $ScriptRoot 'Test-Stage-Endpoint.ps1' }
)

$startIndex = [array]::IndexOf(($stages | ForEach-Object { $_.Name }), $StartAt)
if ($startIndex -lt 0) { $startIndex = 0 }

Write-Host "Odysseus Local Diagnostics" -ForegroundColor Cyan
Write-Host ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

$totalPass = 0
$totalWarn = 0
$totalFail = 0
$stoppedAt = $null

for ($i = $startIndex; $i -lt $stages.Count; $i++) {
    $stage = $stages[$i]
    if (-not (Test-Path $stage.Path)) {
        Write-Host "[FAIL] Missing diagnostic stage script: $($stage.Path)" -ForegroundColor Red
        $totalFail++
        $stoppedAt = $stage.Name
        break
    }

    . $stage.Path -AsLibrary
    $result = Invoke-DiagnosticStage

    $totalPass += $result.PassCount
    $totalWarn += $result.WarnCount
    $totalFail += $result.FailCount

    Write-Host ("`nStage '{0}' summary: {1} PASS / {2} WARN / {3} FAIL" -f $result.Stage, $result.PassCount, $result.WarnCount, $result.FailCount) -ForegroundColor Cyan

    if ($result.FailCount -gt 0) {
        $stoppedAt = $stage.Name
        Write-Host "`n[STOPPED] Stage '$($stage.Name)' reported a FAIL. Fix the issue above, then rerun with -StartAt $($stage.Name)." -ForegroundColor Red
        break
    }
}

Write-Host "`n===================================================="  -ForegroundColor Cyan
Write-Host ("Overall: {0} PASS / {1} WARN / {2} FAIL" -f $totalPass, $totalWarn, $totalFail) -ForegroundColor Cyan
if ($stoppedAt) {
    Write-Host "Result: STOPPED at stage '$stoppedAt'." -ForegroundColor Red
}
elseif ($totalWarn -gt 0) {
    Write-Host 'Result: COMPLETED with warnings.' -ForegroundColor Yellow
}
else {
    Write-Host 'Result: COMPLETED cleanly.' -ForegroundColor Green
}
Write-Host "====================================================" -ForegroundColor Cyan

try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}

exit ([int]($totalFail -gt 0))
