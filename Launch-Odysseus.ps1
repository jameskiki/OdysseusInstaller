Clear-Host
$ErrorActionPreference = 'Stop'

$WslDistro = 'Ubuntu'
$BootstrapScript = Join-Path $PSScriptRoot 'run_odysseus.sh'
$HostModeFile = Join-Path $PSScriptRoot 'ODYSSEUS_HOST_MODE'
$IsHostMode = Test-Path $HostModeFile
$env:ODYSSEUS_HOST_MODE = if ($IsHostMode) { '1' } else { '0' }

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

    # If Ollama is running but bound only to loopback, restart it so the new binding takes effect.
    $allInterfaces = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -in @('::', '0.0.0.0') }
    $loopbackOnly = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -eq '127.0.0.1' }

    if ($allInterfaces) {
        return  # Already listening on all interfaces.
    }

    if ($loopbackOnly) {
        # Running but loopback-only — stop so we can restart with the correct binding.
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

function Configure-OdysseusModelEndpoints {
    $commands = @(
        "cd ~/odysseus || exit 0",
        "if [ ! -f .env ]; then exit 0; fi",
        "if grep -q '^LLM_HOST=' .env; then sed -i 's/^LLM_HOST=.*/LLM_HOST=host.docker.internal/' .env; else echo 'LLM_HOST=host.docker.internal' >> .env; fi",
        "if grep -q '^LLM_HOSTS=' .env; then sed -i 's|^LLM_HOSTS=.*|LLM_HOSTS=host.docker.internal|' .env; else echo 'LLM_HOSTS=host.docker.internal' >> .env; fi",
        "if grep -q '^OLLAMA_BASE_URL=' .env; then sed -i 's|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=http://host.docker.internal:11434/v1|' .env; else echo 'OLLAMA_BASE_URL=http://host.docker.internal:11434/v1' >> .env; fi",
        "if grep -q '^EMBEDDING_URL=' .env; then sed -i 's|^EMBEDDING_URL=.*|EMBEDDING_URL=http://host.docker.internal:11434/v1/embeddings|' .env; else echo 'EMBEDDING_URL=http://host.docker.internal:11434/v1/embeddings' >> .env; fi"
    )

    $commandText = ($commands -join '; ')
    & wsl.exe -d $WslDistro -- bash -lc $commandText
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update model endpoint settings inside ~/odysseus/.env."
    }
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
    -Intent "Checking that the Ubuntu WSL distribution is installed..." `
    -Action {
        $distros = & wsl.exe -l -q 2>$null
        $trimmedDistros = @($distros | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if (-not $trimmedDistros) {
            throw "No WSL distributions are installed. Run 'wsl --install -d Ubuntu', complete the first-launch Linux user setup, and then retry."
        }
        if ($trimmedDistros -notcontains $WslDistro) {
            throw "Ubuntu is not installed in WSL. Run 'wsl --install -d Ubuntu', complete the first-launch Linux user setup, and then retry."
        }
    } `
    -FailMessage "Ubuntu is not installed in WSL."

Invoke-Step `
    -Intent "Checking local Ollama runtime for model discovery compatibility..." `
    -Action {
        Ensure-OllamaAvailable | Out-Null
        Ensure-OllamaEndpoint
    } `
    -FailMessage "Ollama is not available."

Invoke-Step `
    -Intent "Aligning Odysseus model endpoint settings for Docker-to-host connectivity..." `
    -Action {
        Configure-OdysseusModelEndpoints
    } `
    -FailMessage "Failed to apply model endpoint settings."

Invoke-Step `
    -Intent "Staging the Linux bootstrap script inside the Ubuntu workspace..." `
    -Action {
        if (-not (Test-Path $BootstrapScript)) {
            throw "The installer payload is incomplete. Missing bootstrap script at $BootstrapScript."
        }

        $linuxSourcePath = (& wsl.exe -d $WslDistro -- wslpath -a $BootstrapScript 2>$null).Trim()
        if ([string]::IsNullOrWhiteSpace($linuxSourcePath)) {
            throw "Unable to translate the installed bootstrap script path into WSL. If Ubuntu has not been initialized yet, run 'wsl -d Ubuntu' once and finish the Linux user setup first."
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
    -Intent "Opening the Odysseus web interface in the default browser..." `
    -Action { Start-Process 'http://localhost:7000' -ErrorAction Stop } `
    -FailMessage "Failed to start the default browser automatically. Navigate to http://localhost:7000 manually."

Read-Host 'Odysseus setup finished. This launcher keeps the local stack tied to this window; closing it will stop the session. Press Enter to close...'
