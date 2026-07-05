Clear-Host
$ErrorActionPreference = 'Stop'

# Capture a transcript of this launch to a per-user log for post-mortem debugging.
$LogDir = Join-Path $env:LOCALAPPDATA 'Odysseus\Logs'
try {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $LogFile = Join-Path $LogDir ("launch-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    Start-Transcript -Path $LogFile -Append -ErrorAction SilentlyContinue | Out-Null
    Write-Host "[LOG] Session transcript: $LogFile" -ForegroundColor DarkGray
}
catch {
    # Transcript is best-effort; continue if it can't be started.
}

$WslDistro = $null
$BootstrapScript = Join-Path $PSScriptRoot 'run_odysseus.sh'
if (-not (Test-Path $BootstrapScript)) {
    $BootstrapScript = Join-Path $PSScriptRoot '..\wsl\run_odysseus.sh'
}
$HostModeFile = Join-Path $PSScriptRoot 'ODYSSEUS_HOST_MODE'
$RepoRefFile = Join-Path $PSScriptRoot 'ODYSSEUS_REPO_REF'
$RebuildModeFile = Join-Path $PSScriptRoot 'ODYSSEUS_REBUILD_MODE'
$IsHostMode = Test-Path $HostModeFile
$env:ODYSSEUS_HOST_MODE = if ($IsHostMode) { '1' } else { '0' }
$repoRef = 'main'
if (Test-Path $RepoRefFile) {
    $rawRepoRef = (Get-Content -Path $RepoRefFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if (-not [string]::IsNullOrWhiteSpace($rawRepoRef)) {
        $repoRef = $rawRepoRef
    }
}

$rebuildMode = 'ask'
if (Test-Path $RebuildModeFile) {
    $rawRebuildMode = (Get-Content -Path $RebuildModeFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim().ToLowerInvariant()
    if ($rawRebuildMode -in @('ask', 'always', 'never')) {
        $rebuildMode = $rawRebuildMode
    }
}

$env:ODYSSEUS_REPO_REF = $repoRef
switch ($rebuildMode) {
    'always' { $env:ODYSSEUS_REBUILD = '1' }
    'never' { $env:ODYSSEUS_REBUILD = '0' }
    default {
        $choice = Read-Host "Rebuild Odysseus containers for this launch? [Y/N]"
        $env:ODYSSEUS_REBUILD = if ($choice -match '^(y|yes)$') { '1' } else { '0' }
    }
}

$wslEnvVars = @('ODYSSEUS_HOST_MODE', 'ODYSSEUS_REPO_REF', 'ODYSSEUS_REBUILD', 'ODYSSEUS_WINDOWS_HOST_OVERRIDE')
if ([string]::IsNullOrEmpty($env:WSLENV)) {
    $env:WSLENV = ($wslEnvVars -join ':')
}
else {
    $existing = @($env:WSLENV -split ':')
    foreach ($name in $wslEnvVars) {
        if ($existing -notcontains $name) {
            $existing += $name
        }
    }
    $env:WSLENV = ($existing -join ':')
}
$env:ODYSSEUS_WSL_RESTART_REQUIRED = '0'
$WatchdogMode = 'auto-heal-light'
$WatchdogIntervalSec = 10
$RequiredComposeServices = @('odysseus', 'chromadb', 'ntfy', 'searxng')

function Get-InstalledWslDistros {
    $distros = & wsl.exe -l -q 2>$null
    return @($distros | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Resolve-UbuntuDistro {
    $distros = Get-InstalledWslDistros

    if ($distros -contains 'Ubuntu') {
        return 'Ubuntu'
    }

    $ubuntuVariant = $distros | Where-Object { $_ -match '^Ubuntu(\-.*)?$' } | Select-Object -First 1
    if (-not $ubuntuVariant) {
        throw "No Ubuntu WSL distribution was found. Please re-run the Odysseus installer to set it up, reboot if prompted by Windows, then relaunch Odysseus."
    }

    return $ubuntuVariant
}

function Ensure-UbuntuInitialized {
    & wsl.exe -d $WslDistro -- bash -lc 'id -un >/dev/null 2>&1'
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host "`n[INFO] Ubuntu setup needs one-time Linux user creation." -ForegroundColor Yellow
    Write-Host "A Linux terminal will open now. Complete the username/password prompts, then close it." -ForegroundColor Yellow
    & wsl.exe -d $WslDistro

    & wsl.exe -d $WslDistro -- bash -lc 'id -un >/dev/null 2>&1'
    if ($LASTEXITCODE -ne 0) {
        throw "Ubuntu initialization is incomplete. Launch 'wsl -d $WslDistro' once, finish Linux user creation, then rerun Odysseus."
    }
}

function Ensure-WslSystemdEnabled {
    # Check first: is systemd=true already set under [boot] in /etc/wsl.conf?
    # We use a small, single-line bash invocation so nothing depends on stdin,
    # here-strings, base64, CRLF handling, or PowerShell native-exe arg quoting.
    & wsl.exe -d $WslDistro -u root -- bash -c "grep -qiE '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$' /etc/wsl.conf 2>/dev/null"
    if ($LASTEXITCODE -eq 0) {
        return
    }

    # Not enabled — write /etc/wsl.conf via a single-line awk pipeline that is
    # idempotent and handles all three cases (no file, [boot] present, [boot] absent).
    $awkScript = @'
BEGIN { in_boot = 0; boot_seen = 0; systemd_written = 0 }
/^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
  if (in_boot && !systemd_written) { print "systemd=true"; systemd_written = 1 }
  in_boot = ($0 ~ /^[[:space:]]*\[boot\][[:space:]]*$/) ? 1 : 0
  if (in_boot) boot_seen = 1
  print; next
}
in_boot && /^[[:space:]]*systemd[[:space:]]*=/ {
  if (!systemd_written) { print "systemd=true"; systemd_written = 1 }
  next
}
{ print }
END {
  if (in_boot && !systemd_written) { print "systemd=true"; systemd_written = 1 }
  if (!boot_seen) { print ""; print "[boot]"; print "systemd=true" }
}
'@
    $awkOneLine = ($awkScript -replace "`r`n", ' ' -replace "`r", ' ' -replace "`n", ' ').Trim()
    $bashCmd = "touch /etc/wsl.conf && awk '$awkOneLine' /etc/wsl.conf > /etc/wsl.conf.new && mv /etc/wsl.conf.new /etc/wsl.conf"

    & wsl.exe -d $WslDistro -u root -- bash -c $bashCmd
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update /etc/wsl.conf for systemd support (exit code $LASTEXITCODE)."
    }

    $env:ODYSSEUS_WSL_RESTART_REQUIRED = '1'
    & wsl.exe --shutdown | Out-Null
    Start-Sleep -Seconds 2
}

function Get-OllamaCommand {
    $ollama = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($null -ne $ollama) { return $ollama }

    # Ollama's per-user installer drops ollama.exe under %LOCALAPPDATA%\Programs\Ollama,
    # which is not on PATH in an already-running PowerShell session. Probe known locations.
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
        (Join-Path $env:ProgramFiles  'Ollama\ollama.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Ollama\ollama.exe')
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($candidates.Count -gt 0) {
        $path = $candidates[0]
        $dir = Split-Path -Parent $path
        if (-not (($env:Path -split ';') -contains $dir)) {
            $env:Path = "$env:Path;$dir"
        }
        return Get-Command $path -ErrorAction SilentlyContinue
    }

    return $null
}

function Get-LastNonEmptyLine {
    param ([string[]]$Paths)

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) {
            continue
        }

        $line = Get-Content $path -Tail 20 -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Last 1

        if (-not [string]::IsNullOrWhiteSpace($line)) {
            return $line.Trim()
        }
    }

    return $null
}

function Invoke-ProcessWithProgress {
    param (
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Activity,
        [string]$Status,
        [string]$StdOutPath,
        [string]$StdErrPath
    )

    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList `
        -NoNewWindow -PassThru `
        -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while (-not $proc.HasExited) {
            $statusLine = Get-LastNonEmptyLine -Paths @($StdErrPath, $StdOutPath)
            $elapsed = $stopwatch.Elapsed.ToString('mm\:ss')

            if ($statusLine) {
                Write-Progress -Activity $Activity -Status "$Status Elapsed: $elapsed" -CurrentOperation $statusLine
            }
            else {
                Write-Progress -Activity $Activity -Status "$Status Elapsed: $elapsed"
            }

            Start-Sleep -Milliseconds 500
            $proc.Refresh()
        }
    }
    finally {
        Write-Progress -Activity $Activity -Completed
        $stopwatch.Stop()
    }

    return $proc
}

function Ensure-OllamaAvailable {
    $ollama = Get-OllamaCommand
    if ($null -ne $ollama) {
        return $true
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw "Ollama is not installed and winget is unavailable. Install Ollama from https://ollama.com/download and rerun."
    }

    Write-Host "Ollama not found. Installing via winget (this may take a minute)..." -ForegroundColor Yellow

    # Non-interactive install. --silent and --disable-interactivity prevent winget from
    # blocking on TTY prompts (source agreement, progress UI) when launched from a shortcut.
    # Output is captured so we can surface it if the install fails.
    $wingetLog = Join-Path $LogDir ("winget-ollama-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    $wingetArgs = @(
        'install', '--id', 'Ollama.Ollama', '-e',
        '--accept-source-agreements', '--accept-package-agreements',
        '--silent', '--disable-interactivity',
        '--scope', 'user'
    )
    $wingetErrLog = "$wingetLog.err"

    $proc = Invoke-ProcessWithProgress `
        -FilePath $winget.Source `
        -ArgumentList $wingetArgs `
        -Activity 'Installing Ollama' `
        -Status 'Downloading and installing dependencies.' `
        -StdOutPath $wingetLog `
        -StdErrPath $wingetErrLog

    # winget returns Win32/HRESULT-style codes that may surface as signed or unsigned.
    # Normalize to UInt32 first to avoid false negatives on successful installs.
    # 0x00000000 = installed
    # 0x8A15002B = no applicable upgrade / already installed
    # 0x8A150109 = install succeeded, reboot recommended
    $exitCode = [uint32]$proc.ExitCode
    $successCodes = @([uint32]0x00000000, [uint32]0x8A15002B, [uint32]0x8A150109)
    if ($successCodes -notcontains $exitCode) {
        $tail = ''
        if (Test-Path $wingetLog) {
            $tail = (Get-Content $wingetLog -Tail 15 -ErrorAction SilentlyContinue) -join "`n"
        }
        throw "winget failed to install Ollama (exit code 0x$($exitCode.ToString('X8'))). See $wingetLog. Last output:`n$tail"
    }

    Write-Host "Ollama install completed." -ForegroundColor DarkGray

    $ollama = Get-OllamaCommand
    if ($null -eq $ollama) {
        throw "Ollama installation finished but ollama.exe was not found. Install manually from https://ollama.com/download and relaunch."
    }

    return $true
}

function Ensure-OllamaEndpoint {
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0:11434', 'User')
    $env:OLLAMA_HOST = '0.0.0.0:11434'

    $ollama = Get-OllamaCommand
    if ($null -eq $ollama) {
        throw "ollama.exe was not found after installation step."
    }

    $allInterfaces = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('::', '0.0.0.0') }
    $loopbackOnly = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' }

    if ($allInterfaces) {
        Write-Host "[INFO] Ollama is already listening on all interfaces for this session." -ForegroundColor DarkGray
        return
    }

    if ($loopbackOnly) {
        Write-Host "[INFO] Ollama is running but only bound to loopback; restarting it with host-wide binding." -ForegroundColor Yellow
        Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }

    Start-Process -FilePath $ollama.Source -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction Stop

    for ($i = 0; $i -lt 20; $i++) {
        Write-Progress -Activity 'Starting Ollama service' -Status 'Waiting for http://localhost:11434 to respond.' -PercentComplete (($i / 20) * 100)
        Start-Sleep -Milliseconds 500
        $probe = Invoke-WebRequest -Uri 'http://localhost:11434/api/tags' -UseBasicParsing -TimeoutSec 2 -ErrorAction SilentlyContinue
        if ($probe -and $probe.StatusCode -eq 200) {
            Write-Host "[INFO] Ollama localhost audit passed: http://localhost:11434/api/tags is reachable." -ForegroundColor DarkGray
            Write-Progress -Activity 'Starting Ollama service' -Completed
            return
        }
    }

    Write-Progress -Activity 'Starting Ollama service' -Completed

    throw "Ollama did not become reachable on http://localhost:11434/api/tags. Start it manually with: `"$($ollama.Source)`" serve, then verify it is bound to 0.0.0.0:11434 rather than only 127.0.0.1:11434."
}

function Invoke-WslCommand {
    param([string]$Command)

    $output = & wsl.exe -d $WslDistro -- bash -lc $Command 2>$null
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
    }
}

function Test-HttpEndpoint {
    param(
        [string]$Uri,
        [int]$TimeoutSec = 3
    )

    try {
        $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
    }
    catch {
        return $false
    }
}

function Get-WslGatewayIp {
    $route = Invoke-WslCommand -Command "ip route show default 2>/dev/null | head -n 1"
    if ($route.ExitCode -ne 0) {
        return $null
    }

    $routeLine = ($route.Output | Select-Object -First 1).Trim()
    if ($routeLine -match 'default\s+via\s+(\S+)') {
        return $matches[1]
    }

    return $null
}

function Get-ComposeServiceStates {
    $result = Invoke-WslCommand -Command "cd ~/odysseus 2>/dev/null && docker compose ps --format '{{.Service}}|{{.State}}|{{.Health}}' 2>/dev/null"
    if ($result.ExitCode -ne 0) {
        # Fallback for environments that still require sudo, but keep it non-interactive.
        $result = Invoke-WslCommand -Command "cd ~/odysseus 2>/dev/null && sudo -n docker compose ps --format '{{.Service}}|{{.State}}|{{.Health}}' 2>/dev/null"
    }
    if ($result.ExitCode -ne 0) {
        return @{}
    }

    $states = @{}
    foreach ($line in $result.Output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split '\|', 3
        if ($parts.Count -lt 2) { continue }

        $service = $parts[0].Trim()
        $state = $parts[1].Trim().ToLowerInvariant()
        $health = if ($parts.Count -ge 3) { $parts[2].Trim().ToLowerInvariant() } else { '' }

        if (-not [string]::IsNullOrWhiteSpace($service)) {
            $states[$service] = [PSCustomObject]@{
                State = $state
                Health = $health
            }
        }
    }

    return $states
}

function Test-OdysseusRuntimeHealth {
    param([string[]]$RequiredServices)

    $issues = [System.Collections.Generic.List[string]]::new()

    $wslCheck = Invoke-WslCommand -Command "id -un >/dev/null 2>&1"
    if ($wslCheck.ExitCode -ne 0) {
        $issues.Add('WSL command execution failed.')
    }

    if (-not (Test-HttpEndpoint -Uri 'http://localhost:11434/api/tags' -TimeoutSec 2)) {
        $issues.Add('Windows Ollama endpoint is down (http://localhost:11434/api/tags).')
    }

    $gatewayIp = Get-WslGatewayIp
    if ([string]::IsNullOrWhiteSpace($gatewayIp)) {
        $issues.Add('WSL default gateway could not be resolved.')
    }
    else {
        $gatewayReach = Invoke-WslCommand -Command "curl -sf --max-time 3 http://${gatewayIp}:11434/api/tags >/dev/null 2>&1"
        if ($gatewayReach.ExitCode -ne 0) {
            $issues.Add("WSL cannot reach Ollama via gateway ${gatewayIp}:11434.")
        }
    }

    $dockerdCheck = Invoke-WslCommand -Command "pgrep -x dockerd >/dev/null 2>&1"
    if ($dockerdCheck.ExitCode -ne 0) {
        $issues.Add('dockerd is not running in WSL.')
    }

    $serviceStates = Get-ComposeServiceStates
    if ($serviceStates.Count -eq 0) {
        $issues.Add('Compose service state cannot be read (sudo prompt, permissions, or missing ~/odysseus).')
    }
    else {
        foreach ($service in $RequiredServices) {
            if (-not $serviceStates.ContainsKey($service)) {
                $issues.Add("Required service '$service' is missing from docker compose ps output.")
                continue
            }

            $state = $serviceStates[$service].State
            $health = $serviceStates[$service].Health
            if ($state -ne 'running') {
                $issues.Add("Required service '$service' is not running (state=$state).")
            }
            if (-not [string]::IsNullOrWhiteSpace($health) -and $health -ne 'healthy') {
                $issues.Add("Required service '$service' reports health '$health'.")
            }
        }
    }

    if (-not (Test-HttpEndpoint -Uri 'http://localhost:7000' -TimeoutSec 3)) {
        $issues.Add('Odysseus app endpoint is down (http://localhost:7000).')
    }

    return [PSCustomObject]@{
        Healthy = ($issues.Count -eq 0)
        Issues = @($issues)
        Summary = if ($issues.Count -eq 0) { 'HEALTHY' } else { ($issues -join ' ') }
    }
}

function Invoke-WatchdogAutoHealLight {
    Write-Host "[WATCHDOG][WARN] Runtime drift detected. Attempting lightweight recovery with 'docker compose up -d'." -ForegroundColor Yellow
    $heal = Invoke-WslCommand -Command "cd ~/odysseus 2>/dev/null && docker compose up -d"
    if ($heal.ExitCode -ne 0) {
        # Fallback without password prompt when sudo is required.
        $heal = Invoke-WslCommand -Command "cd ~/odysseus 2>/dev/null && sudo -n docker compose up -d"
    }
    return ($heal.ExitCode -eq 0)
}

function Test-EnterPressed {
    try {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            return ($key.Key -eq [ConsoleKey]::Enter)
        }
    }
    catch {
        return $false
    }

    return $false
}

function Start-OdysseusWatchdog {
    param(
        [int]$IntervalSec,
        [string]$Mode,
        [string[]]$RequiredServices
    )

    Write-Host "[WATCHDOG] Mode: $Mode | Interval: ${IntervalSec}s" -ForegroundColor DarkGray
    Write-Host "[WATCHDOG] Monitoring: WSL, Ollama (Windows+WSL gateway), dockerd, compose services ($($RequiredServices -join ', ')), app endpoint." -ForegroundColor DarkGray
    Write-Host "[WATCHDOG] Press Enter at any time to close this launcher window." -ForegroundColor DarkGray

    $lastStatus = ''
    $healedCurrentIncident = $false
    $lastRun = [datetime]::MinValue

    while ($true) {
        if (Test-EnterPressed) {
            break
        }

        if (((Get-Date) - $lastRun).TotalSeconds -lt $IntervalSec) {
            Start-Sleep -Milliseconds 300
            continue
        }

        $health = Test-OdysseusRuntimeHealth -RequiredServices $RequiredServices

        if ($health.Healthy) {
            if ($lastStatus -ne 'HEALTHY') {
                Write-Host "[WATCHDOG][PASS] Runtime health is stable." -ForegroundColor Green
            }
            $lastStatus = 'HEALTHY'
            $healedCurrentIncident = $false
            $lastRun = Get-Date
            continue
        }

        $statusText = $health.Summary
        if ($lastStatus -ne $statusText) {
            Write-Host "[WATCHDOG][FAIL] $statusText" -ForegroundColor Red
            $lastStatus = $statusText
        }

        if ($Mode -eq 'auto-heal-light' -and -not $healedCurrentIncident) {
            $healedCurrentIncident = $true
            if (Invoke-WatchdogAutoHealLight) {
                Start-Sleep -Seconds 4
                $postHeal = Test-OdysseusRuntimeHealth -RequiredServices $RequiredServices
                if ($postHeal.Healthy) {
                    Write-Host "[WATCHDOG][PASS] Lightweight recovery succeeded." -ForegroundColor Green
                    $lastStatus = 'HEALTHY'
                    $healedCurrentIncident = $false
                }
                else {
                    Write-Host "[WATCHDOG][WARN] Lightweight recovery attempted, but runtime is still degraded." -ForegroundColor Yellow
                    $lastStatus = $postHeal.Summary
                }
            }
            else {
                Write-Host "[WATCHDOG][WARN] Lightweight recovery command failed. Manual inspection required." -ForegroundColor Yellow
            }
        }

        $lastRun = Get-Date
    }
}

function Invoke-Step {
    param ([string]$Intent, [scriptblock]$Action)
    Write-Host "`n[INTENT] $Intent" -ForegroundColor Cyan
    try {
        & $Action
        Write-Host "[SUCCESS] Step completed cleanly." -ForegroundColor Green
    }
    catch {
        $details = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($details)) {
            $details = "The step failed without an explicit error message."
        }
        Write-Host "[FAILED] $details" -ForegroundColor Red
        if ($LogFile) {
            Write-Host "Full log: $LogFile" -ForegroundColor DarkGray
        }
        try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
        Read-Host 'Press Enter to close...'
        exit 1
    }
}

Invoke-Step `
    -Intent "Applying local runtime preferences (branch/ref '$repoRef', rebuild mode '$rebuildMode')..." `
    -Action {
        if ($env:ODYSSEUS_REBUILD -eq '1') {
            Write-Host "[INFO] This launch will rebuild container images." -ForegroundColor Yellow
        }
        else {
            Write-Host "[INFO] This launch will skip container rebuilds." -ForegroundColor Yellow
        }
    }

Invoke-Step `
    -Intent "Verifying local computer configuration for WSL availability..." `
    -Action {
        if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            throw "WSL is not installed. Please re-run the Odysseus installer to set it up, reboot if Windows requests it, then relaunch Odysseus."
        }
    }

Invoke-Step `
    -Intent "Selecting the Ubuntu WSL distribution for Odysseus..." `
    -Action {
        $script:WslDistro = Resolve-UbuntuDistro
        Write-Host "Using WSL distro: $script:WslDistro" -ForegroundColor DarkGray
    }

Invoke-Step `
    -Intent "Ensuring Ubuntu initialization is complete (Linux user created)..." `
    -Action {
        Ensure-UbuntuInitialized
    }

Invoke-Step `
    -Intent "Enforcing WSL systemd support for reliable Docker daemon management..." `
    -Action {
        Ensure-WslSystemdEnabled
        if ($env:ODYSSEUS_WSL_RESTART_REQUIRED -eq '1') {
            Write-Host "WSL systemd was enabled and WSL was restarted." -ForegroundColor DarkGray
        }
    }

Invoke-Step `
    -Intent "Checking local Ollama runtime for model discovery compatibility..." `
    -Action {
        Ensure-OllamaAvailable | Out-Null
        Ensure-OllamaEndpoint
    }

Invoke-Step `
    -Intent "Staging the Linux bootstrap script inside the Ubuntu workspace..." `
    -Action {
        if (-not (Test-Path $BootstrapScript)) {
            throw "The installer payload is incomplete. Missing bootstrap script at $BootstrapScript."
        }

        $resolvedBootstrapPath = (Resolve-Path -Path $BootstrapScript -ErrorAction Stop).Path
        $normalizedBootstrapPath = $resolvedBootstrapPath -replace '\\', '/'
        $linuxSourcePath = (& wsl.exe -d $WslDistro -- wslpath -a $normalizedBootstrapPath 2>$null).Trim()

        if ([string]::IsNullOrWhiteSpace($linuxSourcePath)) {
            # Fallback conversion in case wslpath cannot translate this Windows path format.
            if ($resolvedBootstrapPath -match '^([A-Za-z]):\\(.*)$') {
                $drive = $matches[1].ToLowerInvariant()
                $suffix = ($matches[2] -replace '\\', '/')
                $linuxSourcePath = "/mnt/$drive/$suffix"
            }
        }

        if ([string]::IsNullOrWhiteSpace($linuxSourcePath)) {
            throw "Unable to translate the installed bootstrap script path into WSL. Run 'wsl -d $WslDistro' once and retry."
        }

        & wsl.exe -d $WslDistro -- bash -lc "tr -d '\r' < '$linuxSourcePath' > ~/run_odysseus.sh && chmod +x ~/run_odysseus.sh"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to copy run_odysseus.sh into the Ubuntu home directory."
        }
    }

Invoke-Step `
    -Intent "Crossing OS boundary to trigger the Linux Environment Automator..." `
    -Action {
        & wsl.exe -d $WslDistro -- bash -lc '~/run_odysseus.sh'
        if ($LASTEXITCODE -ne 0) {
            throw "The Linux bootstrap script exited with code $LASTEXITCODE."
        }
    }

Invoke-Step `
    -Intent "Verifying Odysseus web endpoint responsiveness before launch..." `
    -Action {
        $reachable = $false
        for ($i = 0; $i -lt 6; $i++) {
            try {
                Invoke-WebRequest -Uri 'http://localhost:7000' -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
                $reachable = $true
                break
            }
            catch {
                Start-Sleep -Seconds 5
            }
        }
        if (-not $reachable) {
            throw "Odysseus did not become reachable on http://localhost:7000."
        }
    }

Invoke-Step `
    -Intent "Opening the Odysseus web interface in the default browser..." `
    -Action { Start-Process 'http://localhost:7000' -ErrorAction Stop }

Invoke-Step `
    -Intent "Starting live health watchdog (auto-heal light, 10s interval) while this window stays open..." `
    -Action {
        Start-OdysseusWatchdog -IntervalSec $WatchdogIntervalSec -Mode $WatchdogMode -RequiredServices $RequiredComposeServices
    }

try { Stop-Transcript -ErrorAction SilentlyContinue | Out-Null } catch {}
Write-Host 'Odysseus setup finished. Launcher exiting after watchdog stop request.' -ForegroundColor DarkGray
