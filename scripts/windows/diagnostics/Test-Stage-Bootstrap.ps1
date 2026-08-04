#Requires -Version 5.1
<#!
.SYNOPSIS
    Stage 2 diagnostic: WSL bootstrap prerequisites (sudo, docker, git, workspace).

.DESCRIPTION
    Runs a single interactive WSL session that authenticates sudo once and then
    performs read-only checks (docker CLI, dockerd process, docker group
    membership, git, workspace state, GitHub reachability). All checks run in
    the SAME wsl.exe invocation as the sudo prompt so the cached sudo ticket
    stays valid; sudo tickets do not reliably carry across separate wsl.exe
    invocations. No packages are installed and no containers are started.

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

# Names that must PASS for downstream stages to have any chance of succeeding.
$script:HardFailChecks = @('Sudo authentication', 'Docker CLI present', 'Git present', 'GitHub remote reachable')

$BootstrapDiagScript = @'
#!/usr/bin/env bash
set +e
mkdir -p ~/.odysseus/diag
results="$HOME/.odysseus/diag/results.txt"
: > "$results"

record() {
  local name="$1" code="$2" detail="$3"
  echo "CHECK|${name}|${code}|${detail}" >> "$results"
}

echo "[INFO] If prompted, enter your Ubuntu password (characters will not be shown)."
sudo -v -p '[SUDO] Enter Ubuntu password for Odysseus diagnostics: '
record "Sudo authentication" $? "Ubuntu sudo ticket"

command -v docker >/dev/null 2>&1
record "Docker CLI present" $? "docker command availability"

pgrep -x dockerd >/dev/null 2>&1
record "dockerd running" $? "Docker daemon process (starts during full bootstrap)"

id -nG | tr ' ' '\n' | grep -qx docker
record "Docker group membership" $? "non-root docker access (granted during full bootstrap)"

command -v git >/dev/null 2>&1
record "Git present" $? "git command availability"

if [ -d ~/odysseus ]; then
  cd ~/odysseus
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  dirty=$(git status --short 2>/dev/null)
  if [ -n "$dirty" ]; then
    record "Workspace clean" 1 "Branch ${branch} has local changes"
  else
    record "Workspace clean" 0 "Branch ${branch} has no local changes"
  fi
  timeout 15 git ls-remote --heads origin >/dev/null 2>&1
  record "GitHub remote reachable" $? "origin fetch probe"
else
  record "Odysseus workspace present" 1 "~/odysseus not found; run bootstrap once first"
fi

echo "[INFO] Bootstrap diagnostics complete."
'@

function Invoke-DiagnosticStage {
    Reset-DiagState
    Write-Host "`n=== Stage 2: Bootstrap (sudo, docker, git, workspace) ===" -ForegroundColor Cyan

    $distros = @(Get-OdysseusInstalledWslDistros)
    $wslDistro = Resolve-OdysseusUbuntuDistro -Distros $distros
    if ([string]::IsNullOrWhiteSpace($wslDistro)) {
        Write-Check -Name 'Ubuntu distro detected' -Status FAIL -Detail 'No Ubuntu distro found. Run Test-Stage-Preflight.ps1 first.'
        return [PSCustomObject]@{ Stage = 'Bootstrap'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
    }

    $tempScript = Join-Path $env:TEMP 'odysseus-diag-bootstrap.sh'
    Set-Content -Path $tempScript -Value ($BootstrapDiagScript -replace "`r`n", "`n") -NoNewline -Encoding ascii

    $normalizedPath = (Resolve-Path -Path $tempScript).Path -replace '\\', '/'
    $linuxSourcePath = (& wsl.exe -d $wslDistro -- wslpath -a $normalizedPath 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($linuxSourcePath) -and $normalizedPath -match '^([A-Za-z]):/(.*)$') {
        $linuxSourcePath = "/mnt/$($matches[1].ToLowerInvariant())/$($matches[2])"
    }

    Write-Host '[INFO] Watch for this exact prompt: [SUDO] Enter Ubuntu password for Odysseus diagnostics:' -ForegroundColor Yellow
    & wsl.exe -d $wslDistro -- bash -lc "mkdir -p ~/.odysseus/diag && tr -d '\r' < '$linuxSourcePath' > ~/.odysseus/diag/bootstrap-check.sh && chmod +x ~/.odysseus/diag/bootstrap-check.sh && ~/.odysseus/diag/bootstrap-check.sh"

    $resultsRaw = & wsl.exe -d $wslDistro -- bash -lc 'cat ~/.odysseus/diag/results.txt 2>/dev/null'
    if (-not $resultsRaw) {
        Write-Check -Name 'Bootstrap diagnostics execution' -Status FAIL -Detail 'No results were produced. The WSL session may have been interrupted before checks completed.'
        return [PSCustomObject]@{ Stage = 'Bootstrap'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
    }

    foreach ($line in $resultsRaw) {
        if ($line -notmatch '^CHECK\|') { continue }
        $parts = $line -split '\|', 4
        if ($parts.Count -lt 3) { continue }

        $name = $parts[1]
        $code = $parts[2]
        $detail = if ($parts.Count -ge 4) { $parts[3] } else { '' }

        if ($code -eq '0') {
            Write-Check -Name $name -Status PASS -Detail $detail
        }
        elseif ($script:HardFailChecks -contains $name) {
            Write-Check -Name $name -Status FAIL -Detail $detail
        }
        else {
            Write-Check -Name $name -Status WARN -Detail $detail
        }
    }

    return [PSCustomObject]@{ Stage = 'Bootstrap'; PassCount = $script:DiagPass; WarnCount = $script:DiagWarn; FailCount = $script:DiagFail; Results = @($script:DiagResults) }
}

if (-not $AsLibrary) {
    Clear-Host
    $result = Invoke-DiagnosticStage
    Write-Host ("`nStage summary: {0} PASS / {1} WARN / {2} FAIL" -f $result.PassCount, $result.WarnCount, $result.FailCount) -ForegroundColor Cyan
    exit ([int]($result.FailCount -gt 0))
}
