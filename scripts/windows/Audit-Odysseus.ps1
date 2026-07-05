#Requires -Version 5.1
<#!
.SYNOPSIS
    Read-only health audit for the Odysseus AI environment.

.DESCRIPTION
    Checks key runtime layers and reports PASS/WARN/FAIL status:
    - Ollama process, listener, and localhost endpoint
    - WSL availability and host routing
    - .env model endpoint keys in ~/odysseus/.env
    - Docker daemon and compose container status
    - Odysseus HTTP endpoint on port 7000

    This script is diagnostic-only and does not modify configuration.

.PARAMETER CheckLanReachability
    Also evaluates LAN exposure for port 7000 and firewall rule state.
#>
[CmdletBinding()]
param (
    [switch]$CheckLanReachability
)

$ErrorActionPreference = 'SilentlyContinue'
$WslDistro = $null

$script:results = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:failCount = 0
$script:warnCount = 0

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

    $script:results.Add([PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    if ($Status -eq 'FAIL') { $script:failCount++ }
    elseif ($Status -eq 'WARN') { $script:warnCount++ }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ([string]::new('-', $Title.Length)) -ForegroundColor DarkCyan
}

function Invoke-Wsl {
    param([string]$Command)
    & wsl.exe -d $WslDistro -- bash -c $Command 2>$null
}

function Get-InstalledWslDistros {
    $distros = (& wsl.exe -l -q 2>$null)
    return @($distros | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Resolve-UbuntuDistro {
    param([string[]]$Distros)

    if ($Distros -contains 'Ubuntu') {
        return 'Ubuntu'
    }

    return ($Distros | Where-Object { $_ -match '^Ubuntu(-.*)?$' } | Select-Object -First 1)
}

function Test-HttpOk {
    param(
        [string]$Uri,
        [int]$TimeoutSec = 5
    )

    try {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
    }
    catch {
        return $false
    }
}

Clear-Host
Write-Host "Odysseus Environment Health Audit" -ForegroundColor Cyan
Write-Host ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

Write-Section "1) Ollama (Windows host)"

$ollamaProc = Get-Process -Name ollama -ErrorAction SilentlyContinue
if ($ollamaProc) {
    Write-Check -Name "ollama.exe process" -Status PASS -Detail ("PID {0}" -f $ollamaProc.Id)
}
else {
    Write-Check -Name "ollama.exe process" -Status WARN -Detail "Process not found. Ollama may not be running."
}

if (Test-HttpOk -Uri 'http://localhost:11434/api/tags') {
    Write-Check -Name "Ollama HTTP localhost" -Status PASS
}
else {
    Write-Check -Name "Ollama HTTP localhost" -Status FAIL -Detail "Cannot reach http://localhost:11434/api/tags"
}

$listeners = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue
$allIface = $listeners | Where-Object { $_.LocalAddress -in @('::', '0.0.0.0') }
$loopbackOnly = $listeners | Where-Object { $_.LocalAddress -eq '127.0.0.1' }

if ($allIface) {
    Write-Check -Name "Ollama bind scope" -Status PASS -Detail "Listening on all interfaces"
}
elseif ($loopbackOnly) {
    Write-Check -Name "Ollama bind scope" -Status FAIL -Detail "Bound to loopback only (127.0.0.1)."
}
else {
    Write-Check -Name "Ollama bind scope" -Status WARN -Detail "No listener detected on port 11434."
}

Write-Section "2) WSL routing and host reachability"

$hasWsl = $null -ne (Get-Command wsl.exe -ErrorAction SilentlyContinue)
if (-not $hasWsl) {
    Write-Check -Name "WSL available" -Status FAIL -Detail "wsl.exe not found in PATH."
}
else {
    Write-Check -Name "WSL available" -Status PASS

    $distros = Get-InstalledWslDistros
    $WslDistro = Resolve-UbuntuDistro -Distros $distros
    if (-not [string]::IsNullOrWhiteSpace($WslDistro)) {
        Write-Check -Name "Ubuntu distro present" -Status PASS -Detail ("Using distro '{0}'" -f $WslDistro)

        $defaultRoute = ((Invoke-Wsl 'ip route show default 2>/dev/null') | Select-Object -First 1).Trim()
        $gatewayIp = $null
        if ($defaultRoute -match 'default\s+via\s+(\S+)') {
            $gatewayIp = $matches[1]
        }

        if ([string]::IsNullOrWhiteSpace($gatewayIp)) {
            Write-Check -Name "WSL host gateway" -Status WARN -Detail "Could not resolve default gateway from WSL."
        }
        else {
            Write-Check -Name "WSL host gateway" -Status PASS -Detail ("{0} (from '{1}')" -f $gatewayIp, $defaultRoute)

            $reach = Invoke-Wsl "if curl -sf --max-time 5 http://${gatewayIp}:11434/api/tags >/dev/null 2>&1; then echo OK; else echo FAIL; fi"
            if (($reach -join '').Trim() -eq 'OK') {
                Write-Check -Name "Ollama reachable from WSL" -Status PASS
            }
            else {
                Write-Check -Name "Ollama reachable from WSL" -Status FAIL -Detail ("curl http://{0}:11434/api/tags failed from WSL." -f $gatewayIp)
            }
        }
    }
    else {
        Write-Check -Name "Ubuntu distro present" -Status FAIL -Detail "Ubuntu WSL distro not found."
    }
}

Write-Section "3) Environment and containers"

if ($hasWsl -and -not [string]::IsNullOrWhiteSpace($WslDistro)) {
    $envLines = Invoke-Wsl 'cat ~/odysseus/.env 2>/dev/null'
    if ($null -eq $envLines -or ($envLines -join '').Trim().Length -eq 0) {
        Write-Check -Name ".env present" -Status WARN -Detail "~/odysseus/.env not found or empty."
    }
    else {
        Write-Check -Name ".env present" -Status PASS

        $requiredKeys = @('LLM_HOST', 'LLM_HOSTS', 'OLLAMA_BASE_URL', 'EMBEDDING_URL')
        foreach ($key in $requiredKeys) {
            $line = $envLines | Where-Object { $_ -match ("^{0}=" -f [regex]::Escape($key)) } | Select-Object -Last 1
            if ($line) {
                Write-Check -Name (".env key {0}" -f $key) -Status PASS
            }
            else {
                Write-Check -Name (".env key {0}" -f $key) -Status WARN -Detail "Key is missing."
            }
        }
    }

    # Keep this check side-effect free: do not call docker CLI here because it can
    # trigger socket activation and start dockerd on some systems.
    $dockerRunning = ((Invoke-Wsl 'if pgrep -x dockerd >/dev/null 2>&1; then echo RUNNING; else echo STOPPED; fi') -join '').Trim()
    if ($dockerRunning -eq 'RUNNING') {
        Write-Check -Name "Docker daemon (WSL)" -Status PASS

        $composePs = Invoke-Wsl 'cd ~/odysseus 2>/dev/null; docker compose ps -a 2>/dev/null'
        if (-not $composePs -or ($composePs -join '').Trim().Length -eq 0) {
            # Fallback for environments where docker requires sudo. Use -n to avoid
            # interactive password prompts during health checks.
            $composePs = Invoke-Wsl 'cd ~/odysseus 2>/dev/null; sudo -n docker compose ps -a 2>/dev/null'
        }

        $rows = @($composePs | Select-Object -Skip 1 | Where-Object { $_.Trim() -ne '' })
        if ($rows.Count -gt 0) {
            foreach ($row in $rows) {
                $container = ($row.Trim() -split '\s+')[0]
                if ($row -match '\bExit') {
                    Write-Check -Name ("Container {0}" -f $container) -Status FAIL -Detail "Exited"
                }
                elseif ($row -match '\(unhealthy\)') {
                    Write-Check -Name ("Container {0}" -f $container) -Status WARN -Detail "Up (unhealthy)"
                }
                elseif ($row -match '\bUp\b') {
                    Write-Check -Name ("Container {0}" -f $container) -Status PASS -Detail "Up"
                }
                else {
                    Write-Check -Name ("Container {0}" -f $container) -Status WARN -Detail "Unknown status"
                }
            }
        }
        else {
            Write-Check -Name "Odysseus containers" -Status WARN -Detail "Container list unavailable (docker permissions or no compose services under ~/odysseus)."
        }
    }
    else {
        Write-Check -Name "Docker daemon (WSL)" -Status FAIL -Detail "dockerd process is not running in WSL."
    }
}
else {
    Write-Check -Name "WSL container checks" -Status WARN -Detail "Skipped because Ubuntu WSL is unavailable."
}

Write-Section "4) Odysseus application endpoint"
if (Test-HttpOk -Uri 'http://127.0.0.1:7000' -TimeoutSec 10) {
    Write-Check -Name "Odysseus HTTP 127.0.0.1:7000" -Status PASS
}
else {
    Write-Check -Name "Odysseus HTTP 127.0.0.1:7000" -Status FAIL -Detail "Endpoint is not reachable."
}

if ($CheckLanReachability) {
    Write-Section "5) Optional LAN exposure checks"

    $listen7000 = Get-NetTCPConnection -LocalPort 7000 -State Listen -ErrorAction SilentlyContinue
    $lanBind = $listen7000 | Where-Object { $_.LocalAddress -in @('::', '0.0.0.0') }
    $loopBind = $listen7000 | Where-Object { $_.LocalAddress -eq '127.0.0.1' }

    if ($lanBind) {
        Write-Check -Name "Port 7000 LAN bind" -Status PASS -Detail "Listening on all interfaces"
    }
    elseif ($loopBind) {
        Write-Check -Name "Port 7000 LAN bind" -Status WARN -Detail "Loopback-only bind."
    }
    else {
        Write-Check -Name "Port 7000 LAN bind" -Status WARN -Detail "No listener on port 7000."
    }

    $fw = Get-NetFirewallRule -DisplayName 'Odysseus AI Network Host' -ErrorAction SilentlyContinue
    if ($fw -and $fw.Enabled -eq 'True') {
        Write-Check -Name "Firewall rule for port 7000" -Status PASS
    }
    elseif ($fw) {
        Write-Check -Name "Firewall rule for port 7000" -Status WARN -Detail "Rule exists but is disabled."
    }
    else {
        Write-Check -Name "Firewall rule for port 7000" -Status WARN -Detail "Rule not found."
    }
}

Write-Host ""
$verdict = if ($script:failCount -gt 0) { 'DOWN' } elseif ($script:warnCount -gt 0) { 'DEGRADED' } else { 'READY' }
$verdictColor = @{ READY = 'Green'; DEGRADED = 'Yellow'; DOWN = 'Red' }[$verdict]
$passCount = ($script:results | Where-Object { $_.Status -eq 'PASS' }).Count
$totalCount = $script:results.Count

Write-Host ("Verdict: {0}" -f $verdict) -ForegroundColor $verdictColor
Write-Host ("Checks: {0}/{1} passed, {2} warning(s), {3} failure(s)" -f $passCount, $totalCount, $script:warnCount, $script:failCount)

if ($script:failCount -gt 0) { exit 1 }
exit 0
