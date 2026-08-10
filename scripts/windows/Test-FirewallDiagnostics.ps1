param([switch]$AsAdmin)

Clear-Host
Write-Host "=== Odysseus Firewall Diagnostics ===" -ForegroundColor Cyan
Write-Host ""

# Check elevation
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]$identity
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "Running as Admin: $isAdmin" -ForegroundColor $(if ($isAdmin) { "Green" } else { "Yellow" })
if (-not $isAdmin) {
    Write-Host "NOTE: Re-run this script with 'Run as administrator' for full access." -ForegroundColor Yellow
}
Write-Host ""

# Check firewall service
Write-Host "--- Firewall Service Status ---" -ForegroundColor Cyan
$fwService = Get-Service -Name MpsSvc -ErrorAction SilentlyContinue
if ($fwService) {
    Write-Host "Service Name: $($fwService.Name)"
    Write-Host "Status: $($fwService.Status)" -ForegroundColor $(if ($fwService.Status -eq 'Running') { "Green" } else { "Red" })
}
else {
    Write-Host "Windows Defender Firewall service (MpsSvc) not found!" -ForegroundColor Red
}
Write-Host ""

# Try netsh to list rules
Write-Host "--- Existing Firewall Rules (via netsh) ---" -ForegroundColor Cyan
$netshResult = & netsh.exe advfirewall firewall show rule name=all 2>&1 | Select-Object -First 20
if ($LASTEXITCODE -eq 0) {
    Write-Host "netsh succeeded (exit code 0)" -ForegroundColor Green
    $netshResult | ForEach-Object { Write-Host $_ }
}
else {
    Write-Host "netsh failed (exit code $LASTEXITCODE)" -ForegroundColor Red
    $netshResult | ForEach-Object { Write-Host $_ }
}
Write-Host ""

# Try Get-NetFirewallRule
Write-Host "--- Existing Rules (via PowerShell Get-NetFirewallRule) ---" -ForegroundColor Cyan
try {
    $rules = Get-NetFirewallRule -ErrorAction Stop | Select-Object -First 10
    if ($rules.Count -gt 0) {
        Write-Host "Successfully queried firewall rules (found $($rules.Count) sample rules)" -ForegroundColor Green
        $rules | ForEach-Object { Write-Host "  - $($_.DisplayName)" }
    }
    else {
        Write-Host "No rules found." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Failed to query rules: $_" -ForegroundColor Red
}
Write-Host ""

# Test creating a rule
Write-Host "--- Test: Creating Temporary Rule ---" -ForegroundColor Cyan
$testRuleName = "Odysseus Test $(Get-Random)"
Write-Host "Attempting to create rule: '$testRuleName'" -ForegroundColor Yellow

$createOutput = & netsh.exe advfirewall firewall add rule name="$testRuleName" dir=in action=allow protocol=TCP localport=9999 profile=private enable=yes 2>&1
$createExitCode = $LASTEXITCODE
Write-Host "Exit Code: $createExitCode" -ForegroundColor $(if ($createExitCode -eq 0) { "Green" } else { "Red" })
Write-Host "Output:"
$createOutput | ForEach-Object { Write-Host "  $_" }
Write-Host ""

if ($createExitCode -eq 0) {
    # Try to query it immediately
    Write-Host "Querying the rule immediately after creation..." -ForegroundColor Yellow
    Start-Sleep -Milliseconds 500
    
    try {
        $queryResult = Get-NetFirewallRule -DisplayName $testRuleName -ErrorAction Stop
        if ($queryResult) {
            Write-Host "SUCCESS: Rule found via Get-NetFirewallRule!" -ForegroundColor Green
            Write-Host "  DisplayName: $($queryResult.DisplayName)"
            Write-Host "  Enabled: $($queryResult.Enabled)"
            Write-Host "  Direction: $($queryResult.Direction)"
        }
    }
    catch {
        Write-Host "FAILED: Rule not found via Get-NetFirewallRule: $_" -ForegroundColor Red
        Write-Host "Trying netsh query..." -ForegroundColor Yellow
        $netshQuery = & netsh.exe advfirewall firewall show rule name="$testRuleName" 2>&1
        $netshQuery | ForEach-Object { Write-Host "  $_" }
    }
    
    # Clean up
    Write-Host ""
    Write-Host "Cleaning up test rule..." -ForegroundColor Yellow
    $deleteOutput = & netsh.exe advfirewall firewall delete rule name="$testRuleName" 2>&1
    Write-Host "Delete exit code: $LASTEXITCODE"
}
else {
    Write-Host "FAILED: Could not create test rule. This is the core issue." -ForegroundColor Red
}
Write-Host ""

# Check for Odysseus rules
Write-Host "--- Checking for Existing Odysseus Rules ---" -ForegroundColor Cyan
$odysseusRules = Get-NetFirewallRule -DisplayName "*Odysseus*" -ErrorAction SilentlyContinue
if ($odysseusRules) {
    Write-Host "Found $($odysseusRules.Count) Odysseus rules:" -ForegroundColor Green
    $odysseusRules | ForEach-Object {
        Write-Host "  - DisplayName: $($_.DisplayName)"
        Write-Host "    Enabled: $($_.Enabled)"
        Write-Host "    Direction: $($_.Direction)"
    }
}
else {
    Write-Host "No Odysseus firewall rules found." -ForegroundColor Yellow
}
Write-Host ""

# Summary
Write-Host "=== Summary ===" -ForegroundColor Cyan
if ($isAdmin) {
    Write-Host "✓ Running as admin" -ForegroundColor Green
}
else {
    Write-Host "✗ NOT running as admin - this is why netsh silently fails!" -ForegroundColor Red
    Write-Host "  SOLUTION: Right-click the launcher shortcut and select 'Run as administrator'" -ForegroundColor Yellow
}

if ($fwService -and $fwService.Status -eq 'Running') {
    Write-Host "✓ Firewall service is running" -ForegroundColor Green
}
else {
    Write-Host "✗ Firewall service may not be running" -ForegroundColor Red
}
