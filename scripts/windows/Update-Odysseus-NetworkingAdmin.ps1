param(
    [Parameter(Mandatory = $true)]
    [string]$WindowsIpAddress,
    [Parameter(Mandatory = $true)]
    [string]$WslIpAddress,
    [int]$Port = 7000,
    [switch]$EnsureHostFirewallRule
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    throw 'This helper must be run as Administrator.'
}

if ([string]::IsNullOrWhiteSpace($WindowsIpAddress) -or [string]::IsNullOrWhiteSpace($WslIpAddress)) {
    throw 'Windows and WSL IP addresses are required.'
}

if ($EnsureHostFirewallRule) {
    $ruleName = 'Odysseus AI Network Host'
    & netsh.exe advfirewall firewall delete rule name="$ruleName" dir=in 2>&1 | Out-Null
    & netsh.exe advfirewall firewall add rule name="$ruleName" dir=in action=allow protocol=TCP localport=$Port profile=private enable=yes 2>&1 | Out-Null
}

& netsh.exe interface portproxy delete v4tov4 listenport=$Port listenaddress=$WindowsIpAddress 2>&1 | Out-Null
& netsh.exe interface portproxy add v4tov4 listenport=$Port listenaddress=$WindowsIpAddress connectport=$Port connectaddress=$WslIpAddress protocol=tcp 2>&1 | Out-Null

if ($LASTEXITCODE -ne 0) {
    throw "netsh portproxy command failed with exit code $LASTEXITCODE."
}

Write-Host "[INFO] Elevated network configuration updated: ${WindowsIpAddress}:${Port} -> ${WslIpAddress}:${Port}" -ForegroundColor DarkGray
