#Requires -Version 5.1
<#!
.SYNOPSIS
    Stage 1 diagnostic: Windows-side prerequisites for local Odysseus.

.DESCRIPTION
    Read-only checks: WSL availability, Ubuntu distro auto-detection,
    Windows Ollama localhost endpoint, and WSL -> Windows Ollama bridge
    reachability. No install/mutating actions are performed.

.PARAMETER AsLibrary
    When set, only defines Invoke-DiagnosticStage without executing it.
    Used by Diagnose-Odysseus-Local.ps1 to run this stage in sequence.
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
    Write-Host "`n=== Stage 1: Preflight (Windows + WSL prerequisites) ===" -ForegroundColor Cyan

    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        Write-Check -Name 'WSL available' -Status PASS
    }
    else {
        Write-Check -Name 'WSL available' -Status FAIL -Detail "wsl.exe not found. Run the 'Prepare WSL for Odysseus' shortcut."
        return New-StageResult -Stage 'Preflight'
    }

    $distros = @(Get-OdysseusInstalledWslDistros)
    $wslDistro = Resolve-OdysseusUbuntuDistro -Distros $distros
    if ([string]::IsNullOrWhiteSpace($wslDistro)) {
        Write-Check -Name 'Ubuntu distro detected' -Status FAIL -Detail "No Ubuntu distro found among: $($distros -join ', ')"
        return New-StageResult -Stage 'Preflight'
    }
    Write-Check -Name 'Ubuntu distro detected' -Status PASS -Detail "Using distro '$wslDistro'"

    if (Test-OdysseusHttpEndpoint -Uri 'http://localhost:11434/api/tags' -TimeoutSec 3) {
        Write-Check -Name 'Ollama localhost endpoint' -Status PASS
    }
    else {
        Write-Check -Name 'Ollama localhost endpoint' -Status FAIL -Detail 'http://localhost:11434/api/tags is not reachable. Start Ollama and rerun.'
    }

    $reach = Test-OdysseusWslOllamaReachability -WslDistro $wslDistro -HostOverride $env:ODYSSEUS_WINDOWS_HOST_OVERRIDE -TimeoutSec 3
    if ($reach.Success) {
        Write-Check -Name 'WSL -> Windows Ollama bridge' -Status PASS -Detail "Reachable via $($reach.ReachableVia)"
    }
    else {
        Write-Check -Name 'WSL -> Windows Ollama bridge' -Status FAIL -Detail "No candidate host reachable from WSL. Attempts: $($reach.AttemptSummary)"
    }

    $bridgeRule = Get-OdysseusFirewallRuleStatus -DisplayName 'Odysseus Ollama WSL Bridge'
    if ($bridgeRule.Status -eq 'Enabled') {
        Write-Check -Name 'Ollama WSL firewall bridge rule' -Status PASS
    }
    else {
        Write-Check -Name 'Ollama WSL firewall bridge rule' -Status WARN -Detail $bridgeRule.Detail
    }

    return New-StageResult -Stage 'Preflight'
}

if (-not $AsLibrary) {
    Clear-Host
    $result = Invoke-DiagnosticStage
    Write-Host ("`nStage summary: {0} PASS / {1} WARN / {2} FAIL" -f $result.PassCount, $result.WarnCount, $result.FailCount) -ForegroundColor Cyan
    exit ([int]($result.FailCount -gt 0))
}
