#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [string]$OutputRoot,

    [int]$EventLookbackHours = 24
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

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $scriptRoot '..\..\Output\forensics'
}

function Get-ShannonEntropy {
    param([byte[]]$Bytes)

    if (-not $Bytes -or $Bytes.Length -eq 0) {
        return 0.0
    }

    $counts = New-Object 'int[]' 256
    foreach ($b in $Bytes) {
        $counts[$b]++
    }

    $entropy = 0.0
    $len = [double]$Bytes.Length
    foreach ($count in $counts) {
        if ($count -le 0) { continue }
        $p = $count / $len
        $entropy -= $p * ([Math]::Log($p, 2))
    }

    return [Math]::Round($entropy, 6)
}

function Read-ZoneIdentifier {
    param([string]$Path)

    $streamPath = "$Path`:Zone.Identifier"
    if (-not (Test-Path -LiteralPath $streamPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $streamPath -ErrorAction Stop
    }
    catch {
        return @('Failed to read Zone.Identifier stream.')
    }
}

function Get-DefenderEvents {
    param(
        [datetime]$StartTime,
        [string]$PathHint,
        [string]$HashHint
    )

    $logName = 'Microsoft-Windows-Windows Defender/Operational'
    try {
        $records = Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $StartTime } -ErrorAction Stop
    }
    catch {
        return @()
    }

    $needleA = if ($PathHint) { $PathHint.ToLowerInvariant() } else { '' }
    $needleB = if ($HashHint) { $HashHint.ToLowerInvariant() } else { '' }

    $hitEvents = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $records) {
        $message = [string]$entry.Message
        $mLower = $message.ToLowerInvariant()
        if (($needleA -and $mLower.Contains($needleA)) -or ($needleB -and $mLower.Contains($needleB))) {
            $hitEvents.Add([PSCustomObject]@{
                TimeCreated = $entry.TimeCreated
                Id = $entry.Id
                LevelDisplayName = $entry.LevelDisplayName
                ProviderName = $entry.ProviderName
                Message = $message
            }) | Out-Null
        }
    }

    return @($hitEvents)
}

$resolvedExe = (Resolve-Path -LiteralPath $ExePath).Path
if (-not (Test-Path -LiteralPath $resolvedExe)) {
    throw "Installer file not found: $ExePath"
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

$outputRootResolved = (Resolve-Path -LiteralPath $OutputRoot).Path
$outputDir = Join-Path $outputRootResolved "forensics-$timestamp"
if (-not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

Write-Host "[INFO] Collecting forensic evidence for: $resolvedExe" -ForegroundColor Cyan
Write-Host "[INFO] Output folder: $outputDir" -ForegroundColor DarkGray

$file = Get-Item -LiteralPath $resolvedExe
$hash = Get-FileHash -LiteralPath $resolvedExe -Algorithm SHA256
$signature = Get-AuthenticodeSignature -LiteralPath $resolvedExe
$versionInfo = $file.VersionInfo
$zoneIdentifier = Read-ZoneIdentifier -Path $resolvedExe

$sampleLength = [Math]::Min($file.Length, 8MB)
$buffer = New-Object byte[] $sampleLength
$fs = [System.IO.File]::Open($resolvedExe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
try {
    [void]$fs.Read($buffer, 0, $sampleLength)
}
finally {
    $fs.Dispose()
}
$entropy = Get-ShannonEntropy -Bytes $buffer

$start = (Get-Date).AddHours(-[Math]::Abs($EventLookbackHours))
$defenderEvents = @(Get-DefenderEvents -StartTime $start -PathHint $resolvedExe -HashHint $hash.Hash)

$report = [PSCustomObject]@{
    CollectedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Hostname = $env:COMPUTERNAME
    Username = "$env:USERDOMAIN\$env:USERNAME"
    Exe = [PSCustomObject]@{
        Path = $resolvedExe
        LengthBytes = $file.Length
        LastWriteTimeUtc = $file.LastWriteTimeUtc
        SHA256 = $hash.Hash
        EntropyFirst8MB = $entropy
    }
    Signature = [PSCustomObject]@{
        Status = [string]$signature.Status
        StatusMessage = $signature.StatusMessage
        SignerCertificateSubject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null }
        SignerCertificateIssuer = if ($signature.SignerCertificate) { $signature.SignerCertificate.Issuer } else { $null }
        SignerCertificateThumbprint = if ($signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { $null }
        TimeStamperCertificateSubject = if ($signature.TimeStamperCertificate) { $signature.TimeStamperCertificate.Subject } else { $null }
    }
    VersionInfo = [PSCustomObject]@{
        FileVersion = $versionInfo.FileVersion
        ProductVersion = $versionInfo.ProductVersion
        CompanyName = $versionInfo.CompanyName
        ProductName = $versionInfo.ProductName
        OriginalFilename = $versionInfo.OriginalFilename
        FileDescription = $versionInfo.FileDescription
        LegalCopyright = $versionInfo.LegalCopyright
    }
    ZoneIdentifier = @($zoneIdentifier)
    DefenderEvents = @($defenderEvents)
}

$jsonPath = Join-Path $outputDir 'forensics-report.json'
$txtPath = Join-Path $outputDir 'forensics-summary.txt'
$defenderPath = Join-Path $outputDir 'defender-events.txt'

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$summary = @(
    "Odysseus Installer Forensics Summary"
    "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    ""
    "File: $resolvedExe"
    "SHA-256: $($hash.Hash)"
    "Size: $($file.Length) bytes"
    "Entropy (first 8MB): $entropy"
    ""
    "Signature status: $($signature.Status)"
    "Signature message: $($signature.StatusMessage)"
    "Signer subject: $($report.Signature.SignerCertificateSubject)"
    ""
    "Version info:"
    "  Product: $($versionInfo.ProductName)"
    "  Company: $($versionInfo.CompanyName)"
    "  FileVersion: $($versionInfo.FileVersion)"
    ""
    "Defender event hits (lookback ${EventLookbackHours}h): $($defenderEvents.Count)"
    ""
    "Artifacts:"
    "  $jsonPath"
    "  $txtPath"
    "  $defenderPath"
)
$summary | Set-Content -LiteralPath $txtPath -Encoding UTF8

if ($defenderEvents.Count -gt 0) {
    $defenderEvents |
        Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
        Format-List |
        Out-String |
        Set-Content -LiteralPath $defenderPath -Encoding UTF8
}
else {
    'No matching Windows Defender events found in selected lookback window.' |
        Set-Content -LiteralPath $defenderPath -Encoding UTF8
}

Write-Host "[SUCCESS] Forensic report generated." -ForegroundColor Green
Write-Host "[INFO] Summary: $txtPath" -ForegroundColor DarkGray
Write-Host "[INFO] JSON: $jsonPath" -ForegroundColor DarkGray
Write-Host "[INFO] Defender events: $defenderPath" -ForegroundColor DarkGray
