Clear-Host
$ErrorActionPreference = 'Stop'

$WslDistro = 'Ubuntu'
$BootstrapScript = Join-Path $PSScriptRoot 'run_odysseus.sh'
$HostModeFile = Join-Path $PSScriptRoot 'ODYSSEUS_HOST_MODE'
$IsHostMode = Test-Path $HostModeFile
$env:ODYSSEUS_HOST_MODE = if ($IsHostMode) { '1' } else { '0' }

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

Read-Host 'Odysseus setup finished. Press Enter to close...'
