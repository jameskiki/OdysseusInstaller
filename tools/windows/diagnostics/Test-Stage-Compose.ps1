#Requires -Version 5.1
<#!
.SYNOPSIS
    Stage 3 diagnostic: Docker compose config validation and container startup.

.DESCRIPTION
    Validates compose configuration, starts containers with a full rebuild
    (every run, per project convention for this diagnostic), and verifies
    required service state/health. Unlike the shared runtime-checks module,
    this script captures stderr so real docker/compose error output is
    surfaced instead of only an exit code.

.PARAMETER AsLibrary
    When set, only defines Invoke-DiagnosticStage without executing it.
#>
[CmdletBinding()]
param (
    [switch]$AsLibrary
)

$ErrorActionPreference = 'SilentlyContinue'

$ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
$RuntimeChecksModulePath = Join-Path $ScriptRoot '..\..\..\scripts\windows\lib\Odysseus.RuntimeChecks.psm1'
if (-not (Test-Path $RuntimeChecksModulePath)) {
    throw "Missing runtime checks module at '$RuntimeChecksModulePath'."
}
Import-Module $RuntimeChecksModulePath -Force -ErrorAction Stop

$script:RequiredComposeServices = @('odysseus', 'chromadb', 'ntfy', 'searxng')

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
    Write-Host "`n=== Stage 3: Compose config validation and container startup ===" -ForegroundColor Cyan

    $distros = @(Get-OdysseusInstalledWslDistros)
    $wslDistro = Resolve-OdysseusUbuntuDistro -Distros $distros
    if ([string]::IsNullOrWhiteSpace($wslDistro)) {
        Write-Check -Name 'Ubuntu distro detected' -Status FAIL -Detail 'No Ubuntu distro found. Run Test-Stage-Preflight.ps1 first.'
        return New-StageResult -Stage 'Compose'
    }

    $workspaceCheck = Invoke-OdysseusWslCommand -WslDistro $wslDistro -Command 'test -d ~/odysseus'
    if ($workspaceCheck.ExitCode -ne 0) {
        Write-Check -Name 'Odysseus workspace present' -Status FAIL -Detail '~/odysseus not found. Run Test-Stage-Bootstrap.ps1 or the launcher once first.'
        return New-StageResult -Stage 'Compose'
    }
    Write-Check -Name 'Odysseus workspace present' -Status PASS

    $sudoTicket = Invoke-OdysseusWslCommand -WslDistro $wslDistro -Command 'sudo -n true >/dev/null 2>&1'
    if ($sudoTicket.ExitCode -ne 0) {
        Write-Host '[INFO] Compose stage requires sudo access for docker on this machine.' -ForegroundColor Yellow
        Write-Host '[INFO] Watch for this exact prompt: [SUDO] Enter Ubuntu password for Odysseus compose diagnostics:' -ForegroundColor Yellow
        & wsl.exe -d $wslDistro --exec bash -lc "sudo -v -p '[SUDO] Enter Ubuntu password for Odysseus compose diagnostics: '"
        if ($LASTEXITCODE -ne 0) {
            Write-Check -Name 'Sudo authentication for compose' -Status FAIL -Detail 'Could not acquire sudo ticket for docker compose commands.'
            return New-StageResult -Stage 'Compose'
        }
    }
    Write-Check -Name 'Sudo authentication for compose' -Status PASS

    $configResult = Invoke-OdysseusWslComposeCaptured -WslDistro $wslDistro -ComposeArgs 'config -q'
    if ($configResult.ExitCode -ne 0) {
        $configResult = Invoke-OdysseusWslComposeCaptured -WslDistro $wslDistro -ComposeArgs 'config -q' -UseSudo
    }
    if ($configResult.ExitCode -ne 0) {
        $tail = ($configResult.Output | Select-Object -Last 30) -join "`n"
        Write-Check -Name 'Compose configuration valid' -Status FAIL -Detail "docker compose config failed:`n$tail"
        return New-StageResult -Stage 'Compose'
    }
    Write-Check -Name 'Compose configuration valid' -Status PASS

    Write-Host '[INFO] Starting containers with a full rebuild (docker compose up -d --build)... this can take several minutes on first run.' -ForegroundColor DarkGray
    $upResult = Invoke-OdysseusWslCompose -WslDistro $wslDistro -ComposeArgs 'up -d --build' -StreamOutput
    if ($upResult.ExitCode -ne 0) {
        $upResult = Invoke-OdysseusWslCompose -WslDistro $wslDistro -ComposeArgs 'up -d --build' -UseSudo -StreamOutput
    }
    if ($upResult.ExitCode -ne 0) {
        $upDetail = Invoke-OdysseusWslComposeCaptured -WslDistro $wslDistro -ComposeArgs 'ps --format "{{.Service}} {{.State}} {{.Health}}"'
        $tail = ($upDetail.Output | Select-Object -Last 40) -join "`n"
        Write-Check -Name 'Containers started (up -d --build)' -Status FAIL -Detail "docker compose up failed:`n$tail"
        return New-StageResult -Stage 'Compose'
    }
    Write-Check -Name 'Containers started (up -d --build)' -Status PASS

    $states = Get-OdysseusComposeServiceStates -WslDistro $wslDistro
    if ($states.Count -eq 0) {
        Write-Check -Name 'Compose service states' -Status WARN -Detail 'Container list unavailable (permissions or docker compose ps returned nothing).'
    }
    else {
        foreach ($service in $script:RequiredComposeServices) {
            if (-not $states.ContainsKey($service)) {
                Write-Check -Name "Service '$service'" -Status FAIL -Detail 'Missing from docker compose ps output.'
                continue
            }

            $state = $states[$service].State
            $health = $states[$service].Health
            if ($state -ne 'running') {
                Write-Check -Name "Service '$service'" -Status FAIL -Detail "State: $state"
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($health) -and $health -ne 'healthy') {
                Write-Check -Name "Service '$service'" -Status WARN -Detail "Running but health is '$health'"
                continue
            }
            Write-Check -Name "Service '$service'" -Status PASS -Detail 'Up'
        }
    }

    return New-StageResult -Stage 'Compose'
}

if (-not $AsLibrary) {
    Clear-Host
    $result = Invoke-DiagnosticStage
    Write-Host ("`nStage summary: {0} PASS / {1} WARN / {2} FAIL" -f $result.PassCount, $result.WarnCount, $result.FailCount) -ForegroundColor Cyan
    exit ([int]($result.FailCount -gt 0))
}
