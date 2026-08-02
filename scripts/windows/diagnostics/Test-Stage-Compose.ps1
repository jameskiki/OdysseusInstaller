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
$RuntimeChecksModulePath = Join-Path $ScriptRoot '..\lib\Odysseus.RuntimeChecks.psm1'
if (-not (Test-Path $RuntimeChecksModulePath)) {
    throw "Missing runtime checks module at '$RuntimeChecksModulePath'."
}
Import-Module $RuntimeChecksModulePath -Force -ErrorAction Stop

$script:RequiredComposeServices = @('odysseus', 'chromadb', 'ntfy', 'searxng')

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

# Same runtime.env -> COMPOSE_FILE resolution as Odysseus.RuntimeChecks.psm1's
# Invoke-OdysseusWslCompose, duplicated here (with 2>&1 merged) because that
# module helper discards stderr, which hides the real compose error text.
function Invoke-WslComposeCaptured {
    param(
        [Parameter(Mandatory = $true)][string]$WslDistro,
        [Parameter(Mandatory = $true)][string]$ComposeArgs,
        [switch]$UseSudo
    )

    $sudoPrefix = if ($UseSudo) { 'sudo -n ' } else { '' }
    $template = @'
cd ~/odysseus 2>/dev/null || exit 1
runtime_env="$HOME/.odysseus/runtime.env"
compose_args=()
if [ -f "$runtime_env" ]; then
  compose_args+=(--env-file "$runtime_env")
  compose_files=$(grep '^COMPOSE_FILE=' "$runtime_env" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  if [ -n "$compose_files" ]; then
    IFS=':' read -r -a cf <<< "$compose_files"
    for f in "${cf[@]}"; do
      [ -n "$f" ] && compose_args+=(-f "$f")
    done
  fi
fi
__SUDO__docker compose "${compose_args[@]}" __ARGS__ 2>&1
'@
    $command = $template.Replace('__SUDO__', $sudoPrefix).Replace('__ARGS__', $ComposeArgs)
    $output = & wsl.exe -d $WslDistro -- bash -lc $command
    return [PSCustomObject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
}

function Invoke-DiagnosticStage {
    Reset-DiagState
    Write-Host "`n=== Stage 3: Compose config validation and container startup ===" -ForegroundColor Cyan

    $distros = @(Get-OdysseusInstalledWslDistros)
    $wslDistro = Resolve-OdysseusUbuntuDistro -Distros $distros
    if ([string]::IsNullOrWhiteSpace($wslDistro)) {
        Write-Check -Name 'Ubuntu distro detected' -Status FAIL -Detail 'No Ubuntu distro found. Run Test-Stage-Preflight.ps1 first.'
        return [PSCustomObject]@{ Stage = 'Compose'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
    }

    $workspaceCheck = Invoke-OdysseusWslCommand -WslDistro $wslDistro -Command 'test -d ~/odysseus'
    if ($workspaceCheck.ExitCode -ne 0) {
        Write-Check -Name 'Odysseus workspace present' -Status FAIL -Detail '~/odysseus not found. Run Test-Stage-Bootstrap.ps1 or the launcher once first.'
        return [PSCustomObject]@{ Stage = 'Compose'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
    }
    Write-Check -Name 'Odysseus workspace present' -Status PASS

    $configResult = Invoke-WslComposeCaptured -WslDistro $wslDistro -ComposeArgs 'config -q'
    if ($configResult.ExitCode -ne 0) {
        $configResult = Invoke-WslComposeCaptured -WslDistro $wslDistro -ComposeArgs 'config -q' -UseSudo
    }
    if ($configResult.ExitCode -ne 0) {
        $tail = ($configResult.Output | Select-Object -Last 30) -join "`n"
        Write-Check -Name 'Compose configuration valid' -Status FAIL -Detail "docker compose config failed:`n$tail"
        return [PSCustomObject]@{ Stage = 'Compose'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
    }
    Write-Check -Name 'Compose configuration valid' -Status PASS

    Write-Host '[INFO] Starting containers with a full rebuild (docker compose up -d --build)...' -ForegroundColor DarkGray
    $upResult = Invoke-WslComposeCaptured -WslDistro $wslDistro -ComposeArgs 'up -d --build'
    if ($upResult.ExitCode -ne 0) {
        $upResult = Invoke-WslComposeCaptured -WslDistro $wslDistro -ComposeArgs 'up -d --build' -UseSudo
    }
    if ($upResult.ExitCode -ne 0) {
        $tail = ($upResult.Output | Select-Object -Last 40) -join "`n"
        Write-Check -Name 'Containers started (up -d --build)' -Status FAIL -Detail "docker compose up failed:`n$tail"
        return [PSCustomObject]@{ Stage = 'Compose'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
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

    return [PSCustomObject]@{ Stage = 'Compose'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
}

if (-not $AsLibrary) {
    Clear-Host
    $result = Invoke-DiagnosticStage
    Write-Host ("`nStage summary: {0} PASS / {1} WARN / {2} FAIL" -f $result.PassCount, $result.WarnCount, $result.FailCount) -ForegroundColor Cyan
    exit ([int]($result.FailCount -gt 0))
}
