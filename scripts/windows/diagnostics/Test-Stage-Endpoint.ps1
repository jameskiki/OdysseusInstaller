#Requires -Version 5.1
<#!
.SYNOPSIS
    Stage 4 diagnostic: Odysseus app endpoint readiness.

.DESCRIPTION
    Polls http://localhost:7000 for up to 30 seconds total. On failure,
    reports current compose service states (informational) to help pinpoint
    why the endpoint is not responding.

.PARAMETER AsLibrary
    When set, only defines Invoke-DiagnosticStage without executing it.
#>
[CmdletBinding()]
param (
    [switch]$AsLibrary
)

$ErrorActionPreference = 'SilentlyContinue'

$ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
$RuntimeChecksModulePath = Join-Path $ScriptRoot '..\lib\Odysseus.RuntimeChecks.psm1'
if (-not (Test-Path $RuntimeChecksModulePath)) {
    throw "Missing runtime checks module at '$RuntimeChecksModulePath'."
}
Import-Module $RuntimeChecksModulePath -Force -ErrorAction Stop

$script:RequiredComposeServices = @('odysseus', 'chromadb', 'ntfy', 'searxng')
$script:EndpointTimeoutSec = 90

function Reset-DiagState {
    $script:Diag = New-OdysseusCheckContext
}

function Write-Check {
    param(
        [string]$Name,
        [ValidateSet('PASS', 'WARN', 'FAIL')]
        [string]$Status,
        [string]$Detail = ''
    )

    Write-OdysseusCheck -Context $script:Diag -Name $Name -Status $Status -Detail $Detail
}

function New-StageResult {
    param([string]$Stage)

    return [PSCustomObject]@{ Stage = $Stage; PassCount = $script:Diag.PassCount; WarnCount = $script:Diag.WarnCount; FailCount = $script:Diag.FailCount; Results = @($script:Diag.Results) }
}

function Invoke-DiagnosticStage {
    Reset-DiagState
    Write-Host "`n=== Stage 4: Application endpoint readiness ===" -ForegroundColor Cyan

    $deadline = (Get-Date).AddSeconds($script:EndpointTimeoutSec)
    $reachable = $false
    $attempts = 0
    do {
        $attempts++
        if (Test-OdysseusHttpEndpoint -Uri 'http://localhost:7000' -TimeoutSec 5) {
            $reachable = $true
            break
        }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    if ($reachable) {
        Write-Check -Name 'Odysseus HTTP endpoint (localhost:7000)' -Status PASS -Detail "Reachable after $attempts attempt(s)."
    }
    else {
        Write-Check -Name 'Odysseus HTTP endpoint (localhost:7000)' -Status FAIL -Detail "Not reachable within $($script:EndpointTimeoutSec)s."
    }

    $distros = @(Get-OdysseusInstalledWslDistros)
    $wslDistro = Resolve-OdysseusUbuntuDistro -Distros $distros
    if (-not [string]::IsNullOrWhiteSpace($wslDistro)) {
        $states = Get-OdysseusComposeServiceStates -WslDistro $wslDistro
        foreach ($service in $script:RequiredComposeServices) {
            if (-not $states.ContainsKey($service)) {
                Write-Check -Name "Service '$service' (context)" -Status WARN -Detail 'Missing from docker compose ps output.'
                continue
            }
            $state = $states[$service].State
            $health = $states[$service].Health
            if ($state -ne 'running') {
                Write-Check -Name "Service '$service' (context)" -Status WARN -Detail "State: $state"
            }
            elseif (-not [string]::IsNullOrWhiteSpace($health) -and $health -ne 'healthy') {
                Write-Check -Name "Service '$service' (context)" -Status WARN -Detail "Running but health is '$health'"
            }
            else {
                Write-Check -Name "Service '$service' (context)" -Status PASS -Detail 'Up'
            }
        }
    }

    return New-StageResult -Stage 'Endpoint'
}

if (-not $AsLibrary) {
    Clear-Host
    $result = Invoke-DiagnosticStage
    Write-Host ("`nStage summary: {0} PASS / {1} WARN / {2} FAIL" -f $result.PassCount, $result.WarnCount, $result.FailCount) -ForegroundColor Cyan
    exit ([int]($result.FailCount -gt 0))
}
