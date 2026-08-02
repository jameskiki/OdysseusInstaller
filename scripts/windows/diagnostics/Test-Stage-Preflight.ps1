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
    $script:DiagResults = [System.Collections.Generic.List[PSCustomObject]]::new()
    $script:DiagPass = 0
    $script:DiagWarn = 0
    $script:DiagFail = 0
}

function Write-Check {
    param(
        [string]$Name,
        [ValidateSet('PASS', 'WARN', 'FAIL')]
        [string]$Status,
        [string]$Detail = ''
    )

    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Status]
    Write-Host ("[{0}] {1}" -f $Status, $Name) -ForegroundColor $color
    if ($Detail) {
        Write-Host ("    -> {0}" -f $Detail) -ForegroundColor DarkGray
    }

    $script:DiagResults.Add([PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    switch ($Status) { 'FAIL' { $script:DiagFail++ }; 'WARN' { $script:DiagWarn++ }; 'PASS' { $script:DiagPass++ } }
}

function Invoke-DiagnosticStage {
    Reset-DiagState
    Write-Host "`n=== Stage 1: Preflight (Windows + WSL prerequisites) ===" -ForegroundColor Cyan

    if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
        Write-Check -Name 'WSL available' -Status PASS
    }
    else {
        Write-Check -Name 'WSL available' -Status FAIL -Detail "wsl.exe not found. Run the 'Prepare WSL for Odysseus' shortcut."
        return [PSCustomObject]@{ Stage = 'Preflight'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
    }

    $distros = @(Get-OdysseusInstalledWslDistros)
    $wslDistro = Resolve-OdysseusUbuntuDistro -Distros $distros
    if ([string]::IsNullOrWhiteSpace($wslDistro)) {
        Write-Check -Name 'Ubuntu distro detected' -Status FAIL -Detail "No Ubuntu distro found among: $($distros -join ', ')"
        return [PSCustomObject]@{ Stage = 'Preflight'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
    }
    Write-Check -Name 'Ubuntu distro detected' -Status PASS -Detail "Using distro '$wslDistro'"

    if (Test-OdysseusHttpEndpoint -Uri 'http://localhost:11434/api/tags' -TimeoutSec 3) {
        Write-Check -Name 'Ollama localhost endpoint' -Status PASS
    }
    else {
        Write-Check -Name 'Ollama localhost endpoint' -Status FAIL -Detail 'http://localhost:11434/api/tags is not reachable. Start Ollama and rerun.'
    }

    $candidates = @(Get-OdysseusOllamaCandidates -WslDistro $wslDistro -HostOverride $env:ODYSSEUS_WINDOWS_HOST_OVERRIDE)
    $reachableVia = $null
    $attempts = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) { continue }
        $probe = Test-OdysseusWslOllamaCandidate -WslDistro $wslDistro -Host $candidate.Value -TimeoutSec 3
        if ($probe.Success) {
            $reachableVia = ("{0} [{1}]" -f $candidate.Value, $candidate.Source)
            break
        }
        $attempts.Add(("{0} [{1}] (http={2}, curl_exit={3})" -f $candidate.Value, $candidate.Source, $probe.HttpCode, $probe.ExitCode))
    }

    if ($reachableVia) {
        Write-Check -Name 'WSL -> Windows Ollama bridge' -Status PASS -Detail "Reachable via $reachableVia"
    }
    else {
        $attemptText = if ($attempts.Count -gt 0) { $attempts -join '; ' } else { 'no candidates available' }
        Write-Check -Name 'WSL -> Windows Ollama bridge' -Status FAIL -Detail "No candidate host reachable from WSL. Attempts: $attemptText"
    }

    $bridgeRule = Get-OdysseusFirewallRuleStatus -DisplayName 'Odysseus Ollama WSL Bridge'
    if ($bridgeRule.Status -eq 'Enabled') {
        Write-Check -Name 'Ollama WSL firewall bridge rule' -Status PASS
    }
    else {
        Write-Check -Name 'Ollama WSL firewall bridge rule' -Status WARN -Detail $bridgeRule.Detail
    }

    return [PSCustomObject]@{ Stage = 'Preflight'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
}

if (-not $AsLibrary) {
    Clear-Host
    $result = Invoke-DiagnosticStage
    Write-Host ("`nStage summary: {0} PASS / {1} WARN / {2} FAIL" -f $result.PassCount, $result.WarnCount, $result.FailCount) -ForegroundColor Cyan
    exit ([int]($result.FailCount -gt 0))
}
