#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallerScriptPath,
    [string]$InstallerOutputPath,
    [string]$IsccPath,
    [string]$TimeStampUrl = 'http://timestamp.digicert.com',
    [string]$CertThumbprint,
    [string]$PfxPath,
    [SecureString]$PfxPassword,
    [switch]$SkipCompile,
    [switch]$SkipSign
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}
else {
    (Get-Location).Path
}

$repoRoot = Resolve-Path (Join-Path $scriptRoot '..\..')

if ([string]::IsNullOrWhiteSpace($InstallerScriptPath)) {
    $InstallerScriptPath = Join-Path $repoRoot 'installer\installer.iss'
}
if ([string]::IsNullOrWhiteSpace($InstallerOutputPath)) {
    $InstallerOutputPath = Join-Path $repoRoot 'Output\Odysseus_Setup.exe'
}

function Resolve-Iscc {
    param([string]$Preferred)

    if (-not [string]::IsNullOrWhiteSpace($Preferred)) {
        $candidate = Resolve-Path -LiteralPath $Preferred -ErrorAction SilentlyContinue
        if ($candidate) { return $candidate.Path }
    }

    $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $registryKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Inno Setup 6_is1'
    )

    foreach ($key in $registryKeys) {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($props -and $props.InstallLocation) {
                $candidate = Join-Path $props.InstallLocation 'ISCC.exe'
                if (Test-Path -LiteralPath $candidate) {
                    return $candidate
                }
            }
        }
        catch {
            # Ignore missing keys.
        }
    }

    $common = @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    )

    foreach ($path in $common) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    return $null
}

$installerScriptResolved = (Resolve-Path -LiteralPath $InstallerScriptPath).Path

if (-not $SkipCompile) {
    $iscc = Resolve-Iscc -Preferred $IsccPath
    if (-not $iscc) {
        throw @'
Could not find ISCC.exe.
Install Inno Setup 6 or pass -IsccPath explicitly.
Example: -IsccPath "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
'@
    }

    Write-Host "[INFO] Compiling installer with: $iscc" -ForegroundColor Cyan
    $compileOutput = & $iscc /Qp $installerScriptResolved 2>&1
    if ($LASTEXITCODE -ne 0) {
        $compileOutput | Out-String | Write-Host
        throw "Installer compilation failed with exit code $LASTEXITCODE"
    }

    Write-Host '[SUCCESS] Installer compiled.' -ForegroundColor Green
}

$installerOutputResolved = Resolve-Path -LiteralPath $InstallerOutputPath -ErrorAction SilentlyContinue
if (-not $installerOutputResolved) {
    throw "Expected installer output not found: $InstallerOutputPath"
}
$installerOutputResolved = $installerOutputResolved.Path

if ($SkipSign) {
    Write-Host "[INFO] SkipSign enabled. Build output: $installerOutputResolved" -ForegroundColor Yellow
    return
}

if ([string]::IsNullOrWhiteSpace($CertThumbprint) -and [string]::IsNullOrWhiteSpace($PfxPath)) {
    throw 'Provide either -CertThumbprint or -PfxPath for signing.'
}

$signScriptPath = Join-Path $scriptRoot 'Sign-Installer.ps1'
if (-not (Test-Path -LiteralPath $signScriptPath)) {
    throw "Signing script not found: $signScriptPath"
}

$signParams = @{
    InstallerPath = $installerOutputResolved
    TimeStampUrl = $TimeStampUrl
}

if (-not [string]::IsNullOrWhiteSpace($CertThumbprint)) {
    $signParams.CertThumbprint = $CertThumbprint
}
else {
    $signParams.PfxPath = (Resolve-Path -LiteralPath $PfxPath).Path
    if ($PfxPassword) {
        $signParams.PfxPassword = $PfxPassword
    }
}

Write-Host '[INFO] Signing and verifying installer...' -ForegroundColor Cyan
& $signScriptPath @signParams
if ($LASTEXITCODE -ne 0) {
    throw "Signing workflow failed with exit code $LASTEXITCODE"
}

Write-Host '[SUCCESS] Build + sign workflow completed.' -ForegroundColor Green
