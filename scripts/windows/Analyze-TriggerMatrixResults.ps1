#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$MatrixJsonPath,
    [string]$OutputPath
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

if ([string]::IsNullOrWhiteSpace($MatrixJsonPath)) {
    $base = Join-Path $scriptRoot '..\..\Output\trigger-matrix'
    if (-not (Test-Path -LiteralPath $base)) {
        throw 'No trigger-matrix output folder exists yet.'
    }

    $latestRun = Get-ChildItem -LiteralPath $base -Directory |
        Sort-Object LastWriteTimeUtc -Descending |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'trigger-matrix.json') } |
        Select-Object -First 1

    if (-not $latestRun) {
        throw 'No trigger-matrix run directory with trigger-matrix.json was found.'
    }

    $MatrixJsonPath = Join-Path $latestRun.FullName 'trigger-matrix.json'
}

$resolvedMatrix = (Resolve-Path -LiteralPath $MatrixJsonPath).Path
if (-not (Test-Path -LiteralPath $resolvedMatrix)) {
    throw "Matrix JSON not found: $MatrixJsonPath"
}

$matrix = Get-Content -LiteralPath $resolvedMatrix -Raw -Encoding UTF8 | ConvertFrom-Json
$rows = @($matrix)

if ($rows.Count -eq 0) {
    throw 'Matrix JSON contained no variants.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $resolvedMatrix) 'trigger-matrix-results-template.csv'
}

$template = foreach ($row in $rows) {
    [PSCustomObject]@{
        Variant = $row.Variant
        Description = $row.Description
        VariantFolder = $row.VariantFolder
        ExePath = ''
        SHA256 = ''
        TrellixOutcome = ''
        Stage = ''
        DetectionLabel = ''
        Notes = ''
    }
}

$template | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host '[SUCCESS] Trigger matrix results template generated.' -ForegroundColor Green
Write-Host "[INFO] Matrix source: $resolvedMatrix" -ForegroundColor DarkGray
Write-Host "[INFO] CSV template: $OutputPath" -ForegroundColor DarkGray
Write-Host '[INFO] Fill TrellixOutcome as BLOCKED or ALLOWED, then share the CSV for root-cause scoring.' -ForegroundColor DarkGray
