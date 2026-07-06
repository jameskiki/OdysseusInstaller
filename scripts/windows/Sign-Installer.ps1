#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallerPath,
    [string]$TimeStampUrl = 'http://timestamp.digicert.com',
    [string]$CertThumbprint,
    [string]$PfxPath,
    [SecureString]$PfxPassword
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

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path $scriptRoot '..\..\Output\Odysseus_Setup.exe'
}

function Resolve-SignTool {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @(
        'C:\Program Files (x86)\Windows Kits\10\bin',
        'C:\Program Files\Windows Kits\10\bin'
    )

    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }

        $candidate = Get-ChildItem -LiteralPath $root -Recurse -File -Filter signtool.exe -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1

        if ($candidate) {
            return $candidate.FullName
        }
    }

    return $null
}

$installerResolved = (Resolve-Path -LiteralPath $InstallerPath).Path
if (-not (Test-Path -LiteralPath $installerResolved)) {
    throw "Installer not found: $InstallerPath"
}

$signTool = Resolve-SignTool
if (-not $signTool) {
    throw 'signtool.exe not found. Install Windows SDK signing tools and retry.'
}

if ([string]::IsNullOrWhiteSpace($CertThumbprint) -and [string]::IsNullOrWhiteSpace($PfxPath)) {
    throw 'Provide either -CertThumbprint (cert in Windows cert store) or -PfxPath (PFX file).'
}

$signArgs = @('sign', '/fd', 'SHA256', '/td', 'SHA256', '/tr', $TimeStampUrl)

if (-not [string]::IsNullOrWhiteSpace($CertThumbprint)) {
    $signArgs += @('/sha1', $CertThumbprint)
}
else {
    $pfxResolved = (Resolve-Path -LiteralPath $PfxPath).Path
    $signArgs += @('/f', $pfxResolved)
    if ($PfxPassword) {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($PfxPassword)
        try {
            $plainPfxPassword = [Runtime.InteropServices.Marshal]::PtrToStringUni($bstr)
            $signArgs += @('/p', $plainPfxPassword)
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
    }
}

$signArgs += $installerResolved

Write-Host "[INFO] Signing $installerResolved" -ForegroundColor Cyan
$signOutput = & $signTool @signArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    $signOutput | Out-String | Write-Host
    throw "Signing failed with exit code $LASTEXITCODE"
}

$verifyOutput = & $signTool verify /pa /v $installerResolved 2>&1
if ($LASTEXITCODE -ne 0) {
    $verifyOutput | Out-String | Write-Host
    throw "Signature verification failed with exit code $LASTEXITCODE"
}

Write-Host '[SUCCESS] Installer signed and verified.' -ForegroundColor Green
