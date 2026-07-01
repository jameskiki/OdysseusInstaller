Clear-Host
$ErrorActionPreference = 'Stop'

$WslDistro = $null
$BootstrapScript = Join-Path $PSScriptRoot 'run_odysseus.sh'
$HostModeFile = Join-Path $PSScriptRoot 'ODYSSEUS_HOST_MODE'
$IsHostMode = Test-Path $HostModeFile
$env:ODYSSEUS_HOST_MODE = if ($IsHostMode) { '1' } else { '0' }
$env:ODYSSEUS_WSL_RESTART_REQUIRED = '0'

function Get-InstalledWslDistros {
    $distros = & wsl.exe -l -q 2>$null
    return @($distros | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Resolve-UbuntuDistro {
    $distros = Get-InstalledWslDistros
    if (-not $distros) {
        throw "No WSL distributions are installed. Run 'wsl --install -d Ubuntu', complete the first-launch Linux user setup, and then retry."
    }

    if ($distros -contains 'Ubuntu') {
        return 'Ubuntu'
    }

    $ubuntuVariant = $distros | Where-Object { $_ -match '^Ubuntu(\-.*)?$' } | Select-Object -First 1
    if (-not $ubuntuVariant) {
        throw "No Ubuntu WSL distribution was found. Install Ubuntu with 'wsl --install -d Ubuntu' and retry."
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
    $command = @'
if [ -f /etc/wsl.conf ] && grep -qi "^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true[[:space:]]*$" /etc/wsl.conf; then
  exit 0
fi

if [ -f /etc/wsl.conf ] && grep -qi "^[[:space:]]*\[boot\][[:space:]]*$" /etc/wsl.conf; then
  if grep -qi "^[[:space:]]*systemd[[:space:]]*=" /etc/wsl.conf; then
    sed -i -E "s|^[[:space:]]*systemd[[:space:]]*=.*$|systemd=true|I" /etc/wsl.conf
  else
    printf "\nsystemd=true\n" >> /etc/wsl.conf
  fi
else
  printf "\n[boot]\nsystemd=true\n" >> /etc/wsl.conf
fi

exit 3
'@

    & wsl.exe -d $WslDistro -u root -- bash -lc $command
    if ($LASTEXITCODE -eq 3) {
        $env:ODYSSEUS_WSL_RESTART_REQUIRED = '1'
        & wsl.exe --shutdown
        Start-Sleep -Seconds 2
        return
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to verify or update /etc/wsl.conf for systemd support."
    }
}

function Ensure-OllamaAvailable {
    $ollama = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($null -ne $ollama) {
        return $true
    }

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw "Ollama is not installed and winget is unavailable. Install Ollama from https://ollama.com/download and rerun."
    }

    $choice = Read-Host "Ollama is required for local model discovery. Install it now with winget? [Y/N]"
    if ($choice -notmatch '^(y|yes)$') {
        throw "Ollama installation declined. Install it from https://ollama.com/download and rerun."
    }

    & winget install --id Ollama.Ollama -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install Ollama (exit code $LASTEXITCODE)."
    }

    $ollama = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($null -eq $ollama) {
        throw "Ollama installation finished but ollama.exe was not found in PATH. Open a new terminal/session and retry."
    }

    return $true
}

function Ensure-OllamaEndpoint {
    [Environment]::SetEnvironmentVariable('OLLAMA_HOST', '0.0.0.0:11434', 'User')
    $env:OLLAMA_HOST = '0.0.0.0:11434'

    $ollama = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($null -eq $ollama) {
        throw "ollama.exe was not found after installation step."
    }

    $allInterfaces = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('::', '0.0.0.0') }
    $loopbackOnly = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' }

    if ($allInterfaces) {
        return
    }

    if ($loopbackOnly) {
        Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }

    Start-Process -FilePath $ollama.Source -ArgumentList 'serve' -WindowStyle Hidden -ErrorAction Stop

    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $probe = Invoke-WebRequest -Uri 'http://localhost:11434/api/tags' -UseBasicParsing -TimeoutSec 3 -ErrorAction Stop
            if ($probe.StatusCode -eq 200) {
                return
            }
        }
        catch {
        }
    }

    throw "Ollama did not become reachable on http://localhost:11434. Start it manually with: `"$($ollama.Source)`" serve"
}

function Invoke-Step {
    param ([string]$Intent, [scriptblock]$Action, [string]$FailMessage)
    Write-Host "`n[INTENT] $Intent" -ForegroundColor Cyan
    try {
        & $Action
        Write-Host "[SUCCESS] Step completed cleanly." -ForegroundColor Green
    }
    catch {
        $details = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($details)) {
            Write-Host "[FAILED] $FailMessage" -ForegroundColor Red
        }
        else {
            Write-Host "[FAILED] $details" -ForegroundColor Red
        }
        Read-Host 'Press Enter to close...'
        exit 1
    }
}

Invoke-Step `
    -Intent "Verifying local computer configuration for WSL availability..." `
    -Action {
        if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
            throw "WSL is not installed. Run 'wsl --install -d Ubuntu' in an elevated PowerShell window and reboot if prompted."
        }
    } `
    -FailMessage "WSL is not installed."

Invoke-Step `
    -Intent "Selecting the Ubuntu WSL distribution for Odysseus..." `
    -Action {
        $script:WslDistro = Resolve-UbuntuDistro
        Write-Host "Using WSL distro: $script:WslDistro" -ForegroundColor DarkGray
    } `
    -FailMessage "Ubuntu WSL distribution lookup failed."

Invoke-Step `
    -Intent "Ensuring Ubuntu initialization is complete (Linux user created)..." `
    -Action {
        Ensure-UbuntuInitialized
    } `
    -FailMessage "Ubuntu user initialization is incomplete."

Invoke-Step `
    -Intent "Enforcing WSL systemd support for reliable Docker daemon management..." `
    -Action {
        Ensure-WslSystemdEnabled
        if ($env:ODYSSEUS_WSL_RESTART_REQUIRED -eq '1') {
            Write-Host "WSL systemd was enabled and WSL was restarted." -ForegroundColor DarkGray
        }
    } `
    -FailMessage "Failed to enforce WSL systemd support."

Invoke-Step `
    -Intent "Checking local Ollama runtime for model discovery compatibility..." `
    -Action {
        Ensure-OllamaAvailable | Out-Null
        Ensure-OllamaEndpoint
    } `
    -FailMessage "Ollama is not available."

Invoke-Step `
    -Intent "Staging the Linux bootstrap script inside the Ubuntu workspace..." `
    -Action {
        if (-not (Test-Path $BootstrapScript)) {
            throw "The installer payload is incomplete. Missing bootstrap script at $BootstrapScript."
        }

        $linuxSourcePath = (& wsl.exe -d $WslDistro -- wslpath -a $BootstrapScript 2>$null).Trim()
        if ([string]::IsNullOrWhiteSpace($linuxSourcePath)) {
            throw "Unable to translate the installed bootstrap script path into WSL. Run 'wsl -d $WslDistro' once and retry."
        }

        & wsl.exe -d $WslDistro -- bash -lc "tr -d '\r' < '$linuxSourcePath' > ~/run_odysseus.sh && chmod +x ~/run_odysseus.sh"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to copy run_odysseus.sh into the Ubuntu home directory."
        }
    } `
    -FailMessage "Failed to stage the Linux bootstrap script."

Invoke-Step `
    -Intent "Crossing OS boundary to trigger the Linux Environment Automator..." `
    -Action {
        & wsl.exe -d $WslDistro -- bash -lc '~/run_odysseus.sh'
        if ($LASTEXITCODE -ne 0) {
            throw "The Linux bootstrap script exited with code $LASTEXITCODE."
        }
    } `
    -FailMessage "The Linux initialization script encountered a breaking error during setup."

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
    } `
    -FailMessage "Odysseus endpoint check failed."

Invoke-Step `
    -Intent "Opening the Odysseus web interface in the default browser..." `
    -Action { Start-Process 'http://localhost:7000' -ErrorAction Stop } `
    -FailMessage "Failed to start the default browser automatically. Navigate to http://localhost:7000 manually."

Read-Host 'Odysseus setup finished. Press Enter to close...'
