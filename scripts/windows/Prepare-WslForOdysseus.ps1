Clear-Host
$ErrorActionPreference = 'Stop'

$ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
$RuntimeChecksModulePath = Join-Path $ScriptRoot 'lib\Odysseus.RuntimeChecks.psm1'
if (-not (Test-Path $RuntimeChecksModulePath)) {
    throw "Missing runtime checks module at '$RuntimeChecksModulePath'. Reinstall Odysseus to restore required files."
}
Import-Module $RuntimeChecksModulePath -Force -ErrorAction Stop

function Invoke-UbuntuInstall {
    Write-Host "[INFO] Installing WSL2 with Ubuntu using: wsl --install -d Ubuntu" -ForegroundColor Yellow
    & wsl.exe --install -d Ubuntu

    if ($LASTEXITCODE -ne 0) {
        throw "The command 'wsl --install -d Ubuntu' failed (exit code $LASTEXITCODE). Run it manually in an elevated terminal, reboot if prompted, then rerun this shortcut."
    }

    Write-Host "" 
    Write-Host "[NEXT STEP] WSL/Ubuntu installation command completed." -ForegroundColor Green
    Write-Host "If Windows asks you to reboot, reboot now." -ForegroundColor Yellow
    Write-Host "After reboot, launch Ubuntu once and complete Linux username/password setup, or rerun this shortcut." -ForegroundColor Yellow
}

Write-Host "Preparing WSL for Odysseus..." -ForegroundColor Cyan

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe is not available on this machine. In an elevated terminal, run 'wsl --install -d Ubuntu'. Reboot if prompted, then rerun this shortcut."
}

$ubuntuDistro = Resolve-OdysseusUbuntuDistro -Distros (Get-OdysseusInstalledWslDistros)
if (-not $ubuntuDistro) {
    Invoke-UbuntuInstall

    $ubuntuDistro = Resolve-OdysseusUbuntuDistro -Distros (Get-OdysseusInstalledWslDistros)
    if (-not $ubuntuDistro) {
        Write-Host "" 
        Write-Host "[NEXT STEP] Ubuntu was not detected yet. This usually means a reboot is required." -ForegroundColor Yellow
        Write-Host "Reboot if prompted, then run this shortcut again." -ForegroundColor Yellow
        exit 0
    }
}

if (-not (Test-OdysseusUbuntuInitialized -WslDistro $ubuntuDistro)) {
    Write-Host "" 
    Write-Host "[INFO] Ubuntu first-run setup is not complete." -ForegroundColor Yellow
    Write-Host "A Linux terminal will open now. Complete Linux username/password setup, then close it." -ForegroundColor Yellow
    & wsl.exe -d $ubuntuDistro

    if (-not (Test-OdysseusUbuntuInitialized -WslDistro $ubuntuDistro)) {
        throw "Ubuntu first-run setup is still incomplete. Launch 'wsl -d $ubuntuDistro' again, finish Linux username/password creation, then rerun this shortcut."
    }
}

Write-Host "" 
Write-Host "WSL is ready. You can now launch Odysseus." -ForegroundColor Green
