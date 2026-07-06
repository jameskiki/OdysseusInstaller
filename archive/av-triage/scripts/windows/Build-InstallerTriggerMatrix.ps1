#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InstallerSource,
    [string]$VariantRoot,
    [switch]$Compile,
    [string]$IsccPath
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

if ([string]::IsNullOrWhiteSpace($InstallerSource)) {
    $InstallerSource = Join-Path $scriptRoot '..\..\installer\installer.iss'
}

if ([string]::IsNullOrWhiteSpace($VariantRoot)) {
    $VariantRoot = Join-Path $scriptRoot '..\..\Output\trigger-matrix'
}

function Resolve-Iscc {
    param([string]$Preferred)

    if ($Preferred) {
        $candidate = (Resolve-Path -LiteralPath $Preferred -ErrorAction SilentlyContinue)
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
            # Ignore registry probes and continue with other discovery paths.
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

function New-VariantDefinition {
    param(
        [string]$Name,
        [string]$Description,
        [scriptblock]$Transform
    )

    return [PSCustomObject]@{
        Name = $Name
        Description = $Description
        Transform = $Transform
    }
}

function Remove-FirewallRuleCommands {
    param([string]$Text)

    $lines = $Text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'netsh\.exe advfirewall firewall add rule') {
            $lines[$i] = '; DISABLED FOR AV TRIAGE: host firewall add rule command removed'
        }

        $lines[$i] = $lines[$i] -replace 'netsh\.exe advfirewall firewall delete rule name=''''Odysseus AI Network Host'''' 1>\$null 2>\$null', 'Write-Host ''''Firewall rule cleanup disabled for AV triage build.'''''
    }

    return ($lines -join "`r`n")
}

function Ensure-SetupSourceDir {
    param(
        [string]$Text,
        [string]$SourceDirPath
    )

    $escaped = [Regex]::Escape($SourceDirPath)
    $sourceDirLine = "SourceDir=$SourceDirPath"

    if ($Text -match "(?im)^\s*SourceDir\s*=") {
        return ($Text -replace "(?im)^\s*SourceDir\s*=.*$", $sourceDirLine)
    }

    if ($Text -match "(?im)^\s*\[Setup\]\s*$") {
        return ($Text -replace "(?im)^\s*\[Setup\]\s*$", "[Setup]`r`n$sourceDirLine")
    }

    throw 'Could not find [Setup] section to inject SourceDir.'
}

$installerPath = (Resolve-Path -LiteralPath $InstallerSource).Path
if (-not (Test-Path -LiteralPath $installerPath)) {
    throw "Installer script not found: $InstallerSource"
}

if (-not (Test-Path -LiteralPath $VariantRoot)) {
    New-Item -ItemType Directory -Path $VariantRoot -Force | Out-Null
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path (Resolve-Path -LiteralPath $VariantRoot).Path "run-$timestamp"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$sourceText = Get-Content -LiteralPath $installerPath -Raw -Encoding UTF8
$installerDir = Split-Path -Parent $installerPath

$variants = @(
    (New-VariantDefinition -Name 'V00-Baseline' -Description 'Original installer script with current behavior chain.' -Transform { param($text) $text }),

    (New-VariantDefinition -Name 'V10-RemoteSigned' -Description 'Replace ExecutionPolicy Bypass with RemoteSigned in icon and helper invocations.' -Transform {
        param($text)
        $text -replace 'ExecutionPolicy Bypass', 'ExecutionPolicy RemoteSigned'
    }),

    (New-VariantDefinition -Name 'V20-VisiblePowerShell' -Description 'Replace hidden PowerShell window mode with shown-normal mode in installer code paths.' -Transform {
        param($text)
        $text -replace 'SW_HIDE', 'SW_SHOWNORMAL'
    }),

    (New-VariantDefinition -Name 'V30-NoFirewallRule' -Description 'Disable firewall add/delete rule commands in installer/uninstaller script.' -Transform {
        param($text)
        $updated = Remove-FirewallRuleCommands -Text $text
        return $updated
    }),

    (New-VariantDefinition -Name 'V40-CombinedSafer' -Description 'Apply RemoteSigned + visible PowerShell + no firewall rule modifications.' -Transform {
        param($text)
        $updated = $text -replace 'ExecutionPolicy Bypass', 'ExecutionPolicy RemoteSigned'
        $updated = $updated -replace 'SW_HIDE', 'SW_SHOWNORMAL'
        $updated = Remove-FirewallRuleCommands -Text $updated
        return $updated
    })
)

$matrix = New-Object System.Collections.Generic.List[object]
$iscc = $null
if ($Compile) {
    $iscc = Resolve-Iscc -Preferred $IsccPath
    if (-not $iscc) {
        throw @'
Compile mode was requested but ISCC.exe could not be found.

Try one of these:
1) Install Inno Setup 6 (compiler ISCC.exe)
2) Pass an explicit compiler path:
   -IsccPath "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
3) Run non-compile mode to generate variant .iss files only.
'@
    }
}

foreach ($variant in $variants) {
    $variantDir = Join-Path $runDir $variant.Name
    New-Item -ItemType Directory -Path $variantDir -Force | Out-Null

    $transformed = & $variant.Transform $sourceText
    $transformed = Ensure-SetupSourceDir -Text $transformed -SourceDirPath $installerDir
    $variantIss = Join-Path $variantDir 'installer.iss'
    Set-Content -LiteralPath $variantIss -Value $transformed -Encoding UTF8

    $compileExit = $null
    $compileOutput = @()

    if ($Compile) {
        Write-Host "[INFO] Compiling $($variant.Name)..." -ForegroundColor Cyan
        $argList = @("/Qp", "/O$variantDir", "/F$($variant.Name)-Odysseus_Setup", $variantIss)
        $compileOutput = & $iscc @argList 2>&1
        $compileExit = $LASTEXITCODE

        $compileLog = Join-Path $variantDir 'compile.log'
        $compileOutput | Set-Content -LiteralPath $compileLog -Encoding UTF8
    }

    $matrix.Add([PSCustomObject]@{
        Variant = $variant.Name
        Description = $variant.Description
        InstallerScript = $variantIss
        Compiled = [bool]$Compile
        CompileExitCode = $compileExit
        VariantFolder = $variantDir
    })
}

$matrixPath = Join-Path $runDir 'trigger-matrix.json'
$matrixTxtPath = Join-Path $runDir 'trigger-matrix.txt'

$matrix | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $matrixPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('Odysseus Installer Trigger Matrix')
$lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("")
$lines.Add("Installer source: $installerPath")
$lines.Add("Compile enabled: $Compile")
if ($Compile) {
    $lines.Add("ISCC: $iscc")
}
$lines.Add("")

foreach ($row in $matrix) {
    $lines.Add("Variant: $($row.Variant)")
    $lines.Add("Description: $($row.Description)")
    $lines.Add("Script: $($row.InstallerScript)")
    $lines.Add("Compiled: $($row.Compiled)")
    if ($Compile) {
        $lines.Add("CompileExitCode: $($row.CompileExitCode)")
    }
    $lines.Add("Folder: $($row.VariantFolder)")
    $lines.Add('')
}

$lines | Set-Content -LiteralPath $matrixTxtPath -Encoding UTF8

Write-Host '[SUCCESS] Trigger matrix generated.' -ForegroundColor Green
Write-Host "[INFO] JSON: $matrixPath" -ForegroundColor DarkGray
Write-Host "[INFO] Summary: $matrixTxtPath" -ForegroundColor DarkGray
if (-not $Compile) {
    Write-Host '[INFO] Re-run with -Compile once ISCC is available to build all variants.' -ForegroundColor DarkGray
    Write-Host '[INFO] If ISCC is not in PATH, pass -IsccPath "C:\Program Files (x86)\Inno Setup 6\ISCC.exe".' -ForegroundColor DarkGray
}
