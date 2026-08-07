#Requires -Version 5.1
<#!
.SYNOPSIS
    Read-only health audit for the Odysseus AI environment.

.DESCRIPTION
    Checks key runtime layers and reports PASS/WARN/FAIL status:
    - Ollama process, listener, and localhost endpoint
    - WSL availability and host routing
    - Runtime model endpoint keys in ~/.odysseus/runtime.env (fallback: ~/odysseus/.env)
    - Docker daemon and compose container status
    - Odysseus HTTP endpoint on port 7000

    This script is diagnostic-only and does not modify configuration.

.PARAMETER CheckLanReachability
    Also evaluates LAN exposure for port 7000 and firewall rule state.

.PARAMETER CheckProfile
    Selects which audit profile to run:
    - Quick: core host + WSL + endpoint checks
    - Network: host + WSL + endpoint + LAN checks
    - Containers: runtime env + container + endpoint checks
    - Consistency: launcher intent vs runtime consistency checks
    - Full: all checks

.PARAMETER IncludeFailureLogHints
    Adds an informational table with the last compose log lines for services
    that are not running or unhealthy. Off by default to keep normal audit
    output concise.
#>
[CmdletBinding()]
param (
    [switch]$CheckLanReachability,
    [ValidateSet('Quick', 'Network', 'Containers', 'Consistency', 'Full')]
    [string]$CheckProfile,
    [switch]$IncludeFailureLogHints
)

$ErrorActionPreference = 'SilentlyContinue'
$WslDistro = $null

$ScriptRoot = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { $PSScriptRoot }
$script:ExecutionContextInfo = $null
$RuntimeChecksModulePath = Join-Path $ScriptRoot 'lib\Odysseus.RuntimeChecks.psm1'
if (-not (Test-Path $RuntimeChecksModulePath)) {
    throw "Missing runtime checks module at '$RuntimeChecksModulePath'. Reinstall Odysseus to restore required audit files."
}
try {
    Import-Module $RuntimeChecksModulePath -Force -ErrorAction Stop
}
catch {
    throw "Missing runtime checks module at '$RuntimeChecksModulePath'. Reinstall Odysseus to restore required audit files."
}

$script:CheckContext = New-OdysseusCheckContext

function Write-Check {
    param(
        [string]$Name,
        [ValidateSet('PASS', 'WARN', 'FAIL')]
        [string]$Status,
        [string]$Detail = ''
    )

    Write-OdysseusCheck -Context $script:CheckContext -Name $Name -Status $Status -Detail $Detail
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ([string]::new('-', $Title.Length)) -ForegroundColor DarkCyan
}

function Invoke-Wsl {
    param([string]$Command)

    $result = Invoke-OdysseusWslCommand -WslDistro $WslDistro -Command $Command
    return @($result.Output)
}

function Test-HttpOk {
    param(
        [string]$Uri,
        [int]$TimeoutSec = 5
    )

    return (Test-OdysseusHttpEndpoint -Uri $Uri -TimeoutSec $TimeoutSec)
}

function Get-KeyValueMapFromLines {
    param([string[]]$Lines)

    $map = @{}
    foreach ($line in @($Lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith('#')) { continue }
        if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
            $map[$matches[1]] = $matches[2].Trim()
        }
    }

    return $map
}

function Get-RuntimeEnvLines {
    if (-not $script:HasWsl -or [string]::IsNullOrWhiteSpace($script:WslDistro)) {
        return @()
    }

    return @(Invoke-Wsl 'if [ -f ~/.odysseus/runtime.env ]; then cat ~/.odysseus/runtime.env; else cat ~/odysseus/.env 2>/dev/null; fi')
}

function Get-LauncherConfigMap {
    $configPath = if ($null -ne $script:ExecutionContextInfo -and -not [string]::IsNullOrWhiteSpace($script:ExecutionContextInfo.LauncherConfigPath)) {
        $script:ExecutionContextInfo.LauncherConfigPath
    }
    else {
        Join-Path $ScriptRoot 'odysseus-launcher.config'
    }

    if (-not (Test-Path $configPath)) {
        return @{}
    }

    return Get-KeyValueMapFromLines -Lines (Get-Content -Path $configPath -ErrorAction SilentlyContinue)
}

function Resolve-UriInfo {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        $uri = [Uri]$Value
        return [PSCustomObject]@{
            Host = $uri.Host
            Path = $uri.AbsolutePath
        }
    }
    catch {
        return $null
    }
}

function Get-ComposePsEntries {
    if (-not $script:HasWsl -or [string]::IsNullOrWhiteSpace($script:WslDistro)) {
        return @()
    }

    $result = Invoke-OdysseusWslComposeCaptured -WslDistro $script:WslDistro -ComposeArgs 'ps --format json'
    if ($result.ExitCode -ne 0) {
        $result = Invoke-OdysseusWslComposeCaptured -WslDistro $script:WslDistro -ComposeArgs 'ps --format json' -UseSudo
    }
    if ($result.ExitCode -ne 0) {
        return @()
    }

    $entries = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($line in @($result.Output)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $trimmed = $line.Trim()
        if (-not ($trimmed.StartsWith('{') -or $trimmed.StartsWith('['))) {
            continue
        }

        try {
            $parsed = $trimmed | ConvertFrom-Json -ErrorAction Stop
            if ($parsed -is [System.Array]) {
                foreach ($item in $parsed) {
                    if ($null -ne $item) { $entries.Add($item) }
                }
            }
            elseif ($null -ne $parsed) {
                $entries.Add($parsed)
            }
        }
        catch {
            # Ignore non-JSON warning lines and malformed records.
        }
    }

    return @($entries)
}

function Add-SummaryRow {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Rows,
        [string]$Level,
        [string]$Service,
        [string]$HostContext,
        [string]$BindIp,
        [string]$PublishedPort,
        [string]$InternalPort,
        [string]$Protocol,
        [string]$Process = '',
        [string]$Health = '',
        [string]$Uptime = '',
        [string]$Source,
        [string]$Note
    )

    $Rows.Add([PSCustomObject]@{
            Level = $Level
            Service = $Service
            Host = $HostContext
            BindIp = $BindIp
            PublishedPort = $PublishedPort
            InternalPort = $InternalPort
            Protocol = $Protocol
            Process = $Process
            Health = $Health
            Uptime = $Uptime
            Source = $Source
            Note = $Note
        })
}

function Get-ListenerProcessLabel {
    param($Listener)

    if ($null -eq $Listener) {
        return 'n/a'
    }

    $processId = $Listener.OwningProcess
    if ($null -eq $processId -or $processId -le 0) {
        return 'n/a'
    }

    try {
        $proc = Get-Process -Id $processId -ErrorAction Stop
        return ('{0} ({1})' -f $proc.ProcessName, $processId)
    }
    catch {
        return ('pid {0}' -f $processId)
    }
}

function Get-ComposeServiceLogTail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Service,
        [int]$Tail = 10
    )

    if (-not $script:HasWsl -or [string]::IsNullOrWhiteSpace($script:WslDistro)) {
        return $null
    }

    $logArgs = ('logs --tail {0} {1}' -f $Tail, $Service)
    $result = Invoke-OdysseusWslComposeCaptured -WslDistro $script:WslDistro -ComposeArgs $logArgs
    if ($result.ExitCode -ne 0) {
        $result = Invoke-OdysseusWslComposeCaptured -WslDistro $script:WslDistro -ComposeArgs $logArgs -UseSudo
    }
    if ($result.ExitCode -ne 0) {
        return $null
    }

    $tailLines = @($result.Output | Select-Object -Last $Tail)
    if ($tailLines.Count -eq 0) {
        return '(no log lines returned)'
    }

    return (($tailLines -join ' | ') -replace '\s+', ' ').Trim()
}

function Add-TargetRow {
    param(
        [System.Collections.Generic.List[PSCustomObject]]$Rows,
        [string]$Level,
        [string]$Consumer,
        [string]$TargetHost,
        [string]$Port,
        [string]$Path,
        [string]$Source,
        [string]$Note
    )

    $Rows.Add([PSCustomObject]@{
            Level = $Level
            Consumer = $Consumer
            TargetHost = $TargetHost
            Port = $Port
            Path = $Path
            Source = $Source
            Note = $Note
        })
}

function Write-SummaryTable {
    param(
        [string]$Title,
        [object[]]$Rows
    )

    Write-Host ''
    Write-Host $Title -ForegroundColor DarkCyan
    if ($null -eq $Rows -or $Rows.Count -eq 0) {
        Write-Host '[WARN] No data available.' -ForegroundColor Yellow
        return
    }

    $table = $Rows | Format-Table -AutoSize | Out-String -Width 320
    Write-Host $table.TrimEnd()
}

function Get-AuditExecutionContextInfo {
    param([string]$ScriptRootPath)

    $programFiles = [Environment]::GetFolderPath('ProgramFiles')
    $programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    $installRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($programFiles)) {
        $installRoots += (Join-Path $programFiles 'Odysseus')
    }
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $installRoots += (Join-Path $programFilesX86 'Odysseus')
    }

    $normalizedRoot = [IO.Path]::GetFullPath($ScriptRootPath)
    $context = 'ExternalCopy'
    foreach ($installRoot in $installRoots) {
        $normalizedInstall = [IO.Path]::GetFullPath($installRoot)
        if ($normalizedRoot.StartsWith($normalizedInstall, [StringComparison]::OrdinalIgnoreCase)) {
            $context = 'InstalledDefaultPath'
            break
        }
    }

    if ($context -eq 'ExternalCopy') {
        $repoMarker = Join-Path $ScriptRootPath '..\..\installer\installer.iss'
        if (Test-Path $repoMarker) {
            $context = 'WorkspaceSource'
        }
    }

    $configPath = Join-Path $ScriptRootPath 'odysseus-launcher.config'
    return [PSCustomObject]@{
        Context = $context
        ScriptRoot = $ScriptRootPath
        LauncherConfigPath = $configPath
        LauncherConfigPresent = (Test-Path $configPath)
    }
}

function Write-ExecutionContextBanner {
    param([PSCustomObject]$ContextInfo)

    Write-Host ("Execution context: {0}" -f $ContextInfo.Context) -ForegroundColor DarkGray
    Write-Host ("Script root: {0}" -f $ContextInfo.ScriptRoot) -ForegroundColor DarkGray
    Write-Host ("Launcher config: {0}" -f $ContextInfo.LauncherConfigPath) -ForegroundColor DarkGray
    Write-Host ("Launcher config present: {0}" -f $(if ($ContextInfo.LauncherConfigPresent) { 'yes' } else { 'no' })) -ForegroundColor DarkGray
    Write-Host ''
}

function Test-CanPrompt {
    if (-not [string]::IsNullOrWhiteSpace($env:CI)) {
        return $false
    }

    if (-not [Environment]::UserInteractive) {
        return $false
    }

    try {
        return (-not [Console]::IsInputRedirected) -and (-not [Console]::IsOutputRedirected)
    }
    catch {
        return $true
    }
}

function Select-CheckProfile {
    Write-Host ''
    Write-Host 'Select audit profile:' -ForegroundColor Cyan
    Write-Host '  1) Quick        - Host + WSL + endpoint checks' -ForegroundColor DarkCyan
    Write-Host '  2) Network      - Quick + LAN checks' -ForegroundColor DarkCyan
    Write-Host '  3) Containers   - Runtime env + containers + endpoint checks' -ForegroundColor DarkCyan
    Write-Host '  4) Consistency  - Launcher intent vs runtime mapping checks' -ForegroundColor DarkCyan
    Write-Host '  5) Full         - All checks' -ForegroundColor DarkCyan

    while ($true) {
        $choice = Read-Host 'Enter choice [1-5] (default 5)'
        if ([string]::IsNullOrWhiteSpace($choice)) { return 'Full' }

        switch ($choice.Trim()) {
            '1' { return 'Quick' }
            '2' { return 'Network' }
            '3' { return 'Containers' }
            '4' { return 'Consistency' }
            '5' { return 'Full' }
            default {
                Write-Host "Invalid choice '$choice'. Please enter 1, 2, 3, 4, or 5." -ForegroundColor Yellow
            }
        }
    }
}

Clear-Host
Write-Host "Odysseus Environment Health Audit" -ForegroundColor Cyan
Write-Host ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray
$script:ExecutionContextInfo = Get-AuditExecutionContextInfo -ScriptRootPath $ScriptRoot
Write-ExecutionContextBanner -ContextInfo $script:ExecutionContextInfo

$script:HasWsl = $null -ne (Get-Command wsl.exe -ErrorAction SilentlyContinue)
$script:WslDistro = $null
if ($script:HasWsl) {
    $distros = @(Get-OdysseusInstalledWslDistros)
    $script:WslDistro = Resolve-OdysseusUbuntuDistro -Distros $distros
}

$launcherConfig = Get-LauncherConfigMap
$runtimeEnvLines = Get-RuntimeEnvLines
$runtimeEnvMap = Get-KeyValueMapFromLines -Lines $runtimeEnvLines
$script:OllamaHostOverride = if (-not [string]::IsNullOrWhiteSpace($env:ODYSSEUS_OLLAMA_HOST)) {
    $env:ODYSSEUS_OLLAMA_HOST
}
elseif (-not [string]::IsNullOrWhiteSpace($env:ODYSSEUS_WINDOWS_HOST_OVERRIDE)) {
    $env:ODYSSEUS_WINDOWS_HOST_OVERRIDE
}
else {
    ''
}

if ([string]::IsNullOrWhiteSpace($CheckProfile)) {
    if (Test-CanPrompt) {
        $CheckProfile = Select-CheckProfile
    }
    else {
        $CheckProfile = 'Full'
        Write-Host '[INFO] Non-interactive session detected. Defaulting to Full profile.' -ForegroundColor DarkGray
    }
}

$runOllama = $false
$runWsl = $false
$runEnvContainers = $false
$runEndpoint = $false
$runLan = $false
$runConsistency = $false

switch ($CheckProfile) {
    'Quick' {
        $runOllama = $true
        $runWsl = $true
        $runEndpoint = $true
    }
    'Network' {
        $runOllama = $true
        $runWsl = $true
        $runEndpoint = $true
        $runLan = $true
    }
    'Containers' {
        $runWsl = $true
        $runEnvContainers = $true
        $runEndpoint = $true
    }
    'Consistency' {
        $runWsl = $true
        $runConsistency = $true
    }
    default {
        $runOllama = $true
        $runWsl = $true
        $runEnvContainers = $true
        $runEndpoint = $true
        $runLan = $true
        $runConsistency = $true
    }
}

if ($CheckLanReachability) {
    $runLan = $true
}

Write-Host ("Profile: {0}" -f $CheckProfile) -ForegroundColor DarkGray

if ($runOllama) {
    Write-Section '1) Ollama (Windows host)'

    $ollamaProc = Get-Process -Name ollama -ErrorAction SilentlyContinue
    if ($ollamaProc) {
        Write-Check -Name 'ollama.exe process' -Status PASS -Detail ('PID {0}' -f $ollamaProc.Id)
    }
    else {
        Write-Check -Name 'ollama.exe process' -Status WARN -Detail 'Process not found. Ollama may not be running.'
    }

    if (Test-HttpOk -Uri 'http://localhost:11434/api/tags') {
        Write-Check -Name 'Ollama HTTP localhost' -Status PASS
    }
    else {
        Write-Check -Name 'Ollama HTTP localhost' -Status FAIL -Detail 'Cannot reach http://localhost:11434/api/tags'
    }

    $listeners = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue
    $allIface = $listeners | Where-Object { $_.LocalAddress -in @('::', '0.0.0.0') }
    $loopbackOnly = $listeners | Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1') }

    if ($allIface) {
        Write-Check -Name 'Ollama bind scope' -Status PASS -Detail 'Listening on all interfaces'
    }
    elseif ($loopbackOnly) {
        Write-Check -Name 'Ollama bind scope' -Status FAIL -Detail 'Bound to loopback only (127.0.0.1/::1).'
    }
    else {
        Write-Check -Name 'Ollama bind scope' -Status WARN -Detail 'No listener detected on port 11434.'
    }

    $bridgeRule = Get-OdysseusFirewallRuleStatus -DisplayName 'Odysseus Ollama WSL Bridge'
    switch ($bridgeRule.Status) {
        'Enabled' {
            Write-Check -Name 'Ollama WSL firewall bridge rule' -Status PASS
        }
        'Disabled' {
            Write-Check -Name 'Ollama WSL firewall bridge rule' -Status WARN -Detail 'Rule exists but is disabled.'
        }
        'AccessDenied' {
            Write-Check -Name 'Ollama WSL firewall bridge rule' -Status WARN -Detail $bridgeRule.Detail
        }
        'NotFound' {
            Write-Check -Name 'Ollama WSL firewall bridge rule' -Status WARN -Detail 'Rule not found. WSL -> Windows host traffic on 11434 may be blocked.'
        }
        default {
            Write-Check -Name 'Ollama WSL firewall bridge rule' -Status WARN -Detail ("Firewall rule state could not be verified: {0}" -f $bridgeRule.Detail)
        }
    }
}

if ($runWsl) {
    Write-Section '2) WSL routing and host reachability'

    if (-not $script:HasWsl) {
        Write-Check -Name 'WSL available' -Status FAIL -Detail 'wsl.exe not found in PATH.'
    }
    else {
        Write-Check -Name 'WSL available' -Status PASS

        if (-not [string]::IsNullOrWhiteSpace($script:WslDistro)) {
            Write-Check -Name 'Ubuntu distro present' -Status PASS -Detail ("Using distro '{0}'" -f $script:WslDistro)

            $defaultRoute = ((Invoke-Wsl 'ip route show default 2>/dev/null') | Select-Object -First 1).Trim()
            $gatewayIp = $null
            if ($defaultRoute -match 'default\s+via\s+(\S+)') {
                $gatewayIp = $matches[1]
            }

            if ([string]::IsNullOrWhiteSpace($gatewayIp)) {
                Write-Check -Name 'WSL host gateway' -Status WARN -Detail 'Could not resolve default gateway from WSL.'
            }
            else {
                Write-Check -Name 'WSL host gateway' -Status PASS -Detail ("{0} (from '{1}')" -f $gatewayIp, $defaultRoute)

                $reach = Test-OdysseusWslOllamaReachability -WslDistro $script:WslDistro -HostOverride $script:OllamaHostOverride -TimeoutSec 5
                if ($reach.Success) {
                    Write-Check -Name 'Ollama reachable from WSL' -Status PASS -Detail ("Reachable via {0}" -f $reach.ReachableVia)
                }
                else {
                    Write-Check -Name 'Ollama reachable from WSL' -Status FAIL -Detail ("curl to /api/tags failed from WSL. Attempts: {0}" -f $reach.AttemptSummary)
                }
            }
        }
        else {
            Write-Check -Name 'Ubuntu distro present' -Status FAIL -Detail 'Ubuntu WSL distro not found.'
        }
    }
}

if ($runEnvContainers) {
    Write-Section '3) Environment and containers'

    if ($script:HasWsl -and -not [string]::IsNullOrWhiteSpace($script:WslDistro)) {
        if ($null -eq $runtimeEnvLines -or ($runtimeEnvLines -join '').Trim().Length -eq 0) {
            Write-Check -Name 'Runtime env present' -Status WARN -Detail 'Neither ~/.odysseus/runtime.env nor ~/odysseus/.env was found with content.'
        }
        else {
            Write-Check -Name 'Runtime env present' -Status PASS

            $requiredKeys = @('LLM_HOST', 'LLM_HOSTS', 'OLLAMA_BASE_URL', 'EMBEDDING_URL', 'COMPOSE_FILE')
            foreach ($key in $requiredKeys) {
                if ($runtimeEnvMap.ContainsKey($key) -and -not [string]::IsNullOrWhiteSpace($runtimeEnvMap[$key])) {
                    Write-Check -Name ("Runtime key {0}" -f $key) -Status PASS
                }
                else {
                    Write-Check -Name ("Runtime key {0}" -f $key) -Status WARN -Detail 'Key is missing.'
                }
            }
        }

        # Keep this check side-effect free: do not call docker CLI here because it can
        # trigger socket activation and start dockerd on some systems.
        $dockerRunning = ((Invoke-Wsl 'if pgrep -x dockerd >/dev/null 2>&1; then echo RUNNING; else echo STOPPED; fi') -join '').Trim()
        if ($dockerRunning -eq 'RUNNING') {
            Write-Check -Name 'Docker daemon (WSL)' -Status PASS

            $states = Get-OdysseusComposeServiceStates -WslDistro $script:WslDistro
            if ($states.Count -eq 0) {
                Write-Check -Name 'Odysseus containers' -Status WARN -Detail 'Container list unavailable (docker permissions or no compose services under ~/odysseus).'
            }
            else {
                foreach ($container in ($states.Keys | Sort-Object)) {
                    $state = $states[$container].State
                    $health = $states[$container].Health

                    if ($state -ne 'running') {
                        Write-Check -Name ("Container {0}" -f $container) -Status FAIL -Detail ("State: {0}" -f $state)
                        continue
                    }

                    if (-not [string]::IsNullOrWhiteSpace($health) -and $health -ne 'healthy') {
                        Write-Check -Name ("Container {0}" -f $container) -Status WARN -Detail ("Running but health is '{0}'" -f $health)
                        continue
                    }

                    Write-Check -Name ("Container {0}" -f $container) -Status PASS -Detail 'Up'
                }
            }
        }
        else {
            Write-Check -Name 'Docker daemon (WSL)' -Status FAIL -Detail 'dockerd process is not running in WSL.'
        }
    }
    else {
        Write-Check -Name 'WSL container checks' -Status WARN -Detail 'Skipped because Ubuntu WSL is unavailable.'
    }
}

if ($runEndpoint) {
    Write-Section '4) Odysseus application endpoint'
    if (Test-HttpOk -Uri 'http://127.0.0.1:7000' -TimeoutSec 10) {
        Write-Check -Name 'Odysseus HTTP 127.0.0.1:7000' -Status PASS
    }
    else {
        Write-Check -Name 'Odysseus HTTP 127.0.0.1:7000' -Status FAIL -Detail 'Endpoint is not reachable.'
    }
}

if ($runLan) {
    Write-Section '5) LAN exposure checks'

    $listen7000 = Get-NetTCPConnection -LocalPort 7000 -State Listen -ErrorAction SilentlyContinue
    $lanBind = $listen7000 | Where-Object { $_.LocalAddress -in @('::', '0.0.0.0') }
    $loopBind = $listen7000 | Where-Object { $_.LocalAddress -eq '127.0.0.1' }

    if ($lanBind) {
        Write-Check -Name "Port 7000 LAN bind" -Status PASS -Detail "Listening on all interfaces"
    }
    elseif ($loopBind) {
        Write-Check -Name "Port 7000 LAN bind" -Status WARN -Detail "Loopback-only bind."
    }
    else {
        Write-Check -Name "Port 7000 LAN bind" -Status WARN -Detail "No listener on port 7000."
    }

    $fw = Get-OdysseusFirewallRuleStatus -DisplayName 'Odysseus AI Network Host'
    switch ($fw.Status) {
        'Enabled' {
            Write-Check -Name "Firewall rule for port 7000" -Status PASS
        }
        'Disabled' {
            Write-Check -Name "Firewall rule for port 7000" -Status WARN -Detail "Rule exists but is disabled."
        }
        'AccessDenied' {
            Write-Check -Name "Firewall rule for port 7000" -Status WARN -Detail $fw.Detail
        }
        'NotFound' {
            Write-Check -Name "Firewall rule for port 7000" -Status WARN -Detail "Rule not found."
        }
        default {
            Write-Check -Name "Firewall rule for port 7000" -Status WARN -Detail "Firewall rule state could not be verified: $($fw.Detail)"
        }
    }
}

if ($runConsistency) {
    Write-Section '6) Consistency checks (WARN-only)'

    $hostModeIntent = $null
    $deploymentModeIntent = $null
    $bindHostIntent = ''
    if ($launcherConfig.Count -eq 0) {
        $missingReason = if ($script:ExecutionContextInfo.Context -eq 'WorkspaceSource') {
            'This is expected when running from the source workspace (installer seeds this file only in the installed app folder).'
        }
        else {
            'Host mode intent cannot be confirmed from launcher configuration.'
        }
        Write-Check -Name 'Launcher config present' -Status WARN -Detail (("odysseus-launcher.config not found at '{0}'. Context={1}. {2}" -f $script:ExecutionContextInfo.LauncherConfigPath, $script:ExecutionContextInfo.Context, $missingReason))
    }
    else {
        Write-Check -Name 'Launcher config present' -Status PASS
        if ($launcherConfig.ContainsKey('ODYSSEUS_DEPLOYMENT_MODE') -and $launcherConfig['ODYSSEUS_DEPLOYMENT_MODE'] -match '^(local|lan-host)$') {
            $deploymentModeIntent = $launcherConfig['ODYSSEUS_DEPLOYMENT_MODE'].ToLowerInvariant()
            Write-Check -Name 'Launcher key ODYSSEUS_DEPLOYMENT_MODE' -Status PASS -Detail ("Configured value: {0}" -f $deploymentModeIntent)
        }
        else {
            Write-Check -Name 'Launcher key ODYSSEUS_DEPLOYMENT_MODE' -Status WARN -Detail 'Missing or unparseable. Expected one of: local, lan-host.'
        }

        if ($launcherConfig.ContainsKey('ODYSSEUS_HOST_MODE') -and $launcherConfig['ODYSSEUS_HOST_MODE'] -match '^(1|true|yes|0|false|no)$') {
            $hostModeIntent = ($launcherConfig['ODYSSEUS_HOST_MODE'] -match '^(1|true|yes)$')
            Write-Check -Name 'Launcher key ODYSSEUS_HOST_MODE' -Status PASS -Detail ("Configured value: {0}" -f $launcherConfig['ODYSSEUS_HOST_MODE'])
        }
        else {
            Write-Check -Name 'Launcher key ODYSSEUS_HOST_MODE' -Status WARN -Detail 'Missing or unparseable. Expected one of: 1, true, yes, 0, false, no.'
        }

        if ($launcherConfig.ContainsKey('ODYSSEUS_OPEN_BROWSER') -and $launcherConfig['ODYSSEUS_OPEN_BROWSER'] -match '^(1|true|yes|0|false|no)$') {
            Write-Check -Name 'Launcher key ODYSSEUS_OPEN_BROWSER' -Status PASS -Detail ("Configured value: {0}" -f $launcherConfig['ODYSSEUS_OPEN_BROWSER'])
        }
        else {
            Write-Check -Name 'Launcher key ODYSSEUS_OPEN_BROWSER' -Status WARN -Detail 'Missing or unparseable. Expected one of: 1, true, yes, 0, false, no.'
        }

        if ($launcherConfig.ContainsKey('ODYSSEUS_APP_BIND_HOST') -and -not [string]::IsNullOrWhiteSpace($launcherConfig['ODYSSEUS_APP_BIND_HOST'])) {
            $bindHostIntent = $launcherConfig['ODYSSEUS_APP_BIND_HOST'].Trim()
            if ($bindHostIntent -eq 'localhost') { $bindHostIntent = '127.0.0.1' }
            Write-Check -Name 'Launcher key ODYSSEUS_APP_BIND_HOST' -Status PASS -Detail ("Configured value: {0}" -f $bindHostIntent)
        }
        else {
            Write-Check -Name 'Launcher key ODYSSEUS_APP_BIND_HOST' -Status WARN -Detail 'Missing or empty. Expected loopback (127.0.0.1) or explicit LAN bind host.'
        }

        if ($launcherConfig.ContainsKey('ODYSSEUS_OLLAMA_HOST') -and -not [string]::IsNullOrWhiteSpace($launcherConfig['ODYSSEUS_OLLAMA_HOST'])) {
            Write-Check -Name 'Launcher key ODYSSEUS_OLLAMA_HOST' -Status PASS -Detail ("Configured value: {0}" -f $launcherConfig['ODYSSEUS_OLLAMA_HOST'])
        }
        else {
            Write-Check -Name 'Launcher key ODYSSEUS_OLLAMA_HOST' -Status WARN -Detail 'Not set. Auto-discovery/ODYSSEUS_WINDOWS_HOST_OVERRIDE will be used.'
        }

        if ($null -ne $deploymentModeIntent -and $null -ne $hostModeIntent) {
            $hostModeFromDeployment = ($deploymentModeIntent -eq 'lan-host')
            if ($hostModeFromDeployment -ne $hostModeIntent) {
                Write-Check -Name 'Deployment mode parity (ODYSSEUS_DEPLOYMENT_MODE vs ODYSSEUS_HOST_MODE)' -Status WARN -Detail ("Deployment mode '{0}' implies host mode={1}, but ODYSSEUS_HOST_MODE is {2}." -f $deploymentModeIntent, $hostModeFromDeployment, $hostModeIntent)
            }
            else {
                Write-Check -Name 'Deployment mode parity (ODYSSEUS_DEPLOYMENT_MODE vs ODYSSEUS_HOST_MODE)' -Status PASS
            }
        }
    }

    if ($runtimeEnvMap.Count -eq 0) {
        Write-Check -Name 'Runtime env map available' -Status WARN -Detail 'Runtime env is missing or empty; endpoint/compose consistency could not be verified.'
    }
    else {
        Write-Check -Name 'Runtime env map available' -Status PASS

        $llmHost = if ($runtimeEnvMap.ContainsKey('LLM_HOST')) { $runtimeEnvMap['LLM_HOST'] } else { '' }
        $llmHosts = if ($runtimeEnvMap.ContainsKey('LLM_HOSTS')) { $runtimeEnvMap['LLM_HOSTS'] } else { '' }
        $ollamaBaseUrl = if ($runtimeEnvMap.ContainsKey('OLLAMA_BASE_URL')) { $runtimeEnvMap['OLLAMA_BASE_URL'] } else { '' }
        $embeddingUrl = if ($runtimeEnvMap.ContainsKey('EMBEDDING_URL')) { $runtimeEnvMap['EMBEDDING_URL'] } else { '' }
        $composeFile = if ($runtimeEnvMap.ContainsKey('COMPOSE_FILE')) { $runtimeEnvMap['COMPOSE_FILE'] } else { '' }
        $runtimeDeploymentMode = if ($runtimeEnvMap.ContainsKey('ODYSSEUS_DEPLOYMENT_MODE')) { $runtimeEnvMap['ODYSSEUS_DEPLOYMENT_MODE'] } else { '' }
        $runtimeBindHost = if ($runtimeEnvMap.ContainsKey('ODYSSEUS_APP_BIND_HOST')) { $runtimeEnvMap['ODYSSEUS_APP_BIND_HOST'] } else { '' }

        if ([string]::IsNullOrWhiteSpace($llmHost) -or [string]::IsNullOrWhiteSpace($llmHosts)) {
            Write-Check -Name 'LLM host pair consistency' -Status WARN -Detail 'LLM_HOST and/or LLM_HOSTS missing.'
        }
        elseif ($llmHost -ne $llmHosts) {
            Write-Check -Name 'LLM host pair consistency' -Status WARN -Detail ("LLM_HOST='{0}' but LLM_HOSTS='{1}'." -f $llmHost, $llmHosts)
        }
        else {
            Write-Check -Name 'LLM host pair consistency' -Status PASS -Detail ("Host: {0}" -f $llmHost)
        }

        $ollamaUriInfo = Resolve-UriInfo -Value $ollamaBaseUrl
        if ($null -eq $ollamaUriInfo) {
            Write-Check -Name 'OLLAMA_BASE_URL format' -Status WARN -Detail 'Value missing or not a valid URI.'
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($llmHost) -and $ollamaUriInfo.Host -ne $llmHost) {
                Write-Check -Name 'OLLAMA_BASE_URL host parity' -Status WARN -Detail ("Host '{0}' does not match LLM_HOST '{1}'." -f $ollamaUriInfo.Host, $llmHost)
            }
            else {
                Write-Check -Name 'OLLAMA_BASE_URL host parity' -Status PASS -Detail ("Host: {0}" -f $ollamaUriInfo.Host)
            }

            if ($ollamaUriInfo.Path -ne '/v1') {
                Write-Check -Name 'OLLAMA_BASE_URL path parity' -Status WARN -Detail ("Path '{0}' does not match expected '/v1'." -f $ollamaUriInfo.Path)
            }
            else {
                Write-Check -Name 'OLLAMA_BASE_URL path parity' -Status PASS
            }
        }

        $embeddingUriInfo = Resolve-UriInfo -Value $embeddingUrl
        if ($null -eq $embeddingUriInfo) {
            Write-Check -Name 'EMBEDDING_URL format' -Status WARN -Detail 'Value missing or not a valid URI.'
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace($llmHost) -and $embeddingUriInfo.Host -ne $llmHost) {
                Write-Check -Name 'EMBEDDING_URL host parity' -Status WARN -Detail ("Host '{0}' does not match LLM_HOST '{1}'." -f $embeddingUriInfo.Host, $llmHost)
            }
            else {
                Write-Check -Name 'EMBEDDING_URL host parity' -Status PASS -Detail ("Host: {0}" -f $embeddingUriInfo.Host)
            }

            if ($embeddingUriInfo.Path -ne '/v1/embeddings') {
                Write-Check -Name 'EMBEDDING_URL path parity' -Status WARN -Detail ("Path '{0}' does not match expected '/v1/embeddings'." -f $embeddingUriInfo.Path)
            }
            else {
                Write-Check -Name 'EMBEDDING_URL path parity' -Status PASS
            }
        }

        if ([string]::IsNullOrWhiteSpace($composeFile)) {
            Write-Check -Name 'COMPOSE_FILE presence' -Status WARN -Detail 'COMPOSE_FILE missing from runtime env.'
        }
        else {
            Write-Check -Name 'COMPOSE_FILE presence' -Status PASS -Detail $composeFile
            $composeFiles = @($composeFile -split ':') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            foreach ($entry in $composeFiles) {
                if (-not $script:HasWsl -or [string]::IsNullOrWhiteSpace($script:WslDistro)) {
                    Write-Check -Name ("Compose file {0}" -f $entry) -Status WARN -Detail 'WSL unavailable; file existence could not be verified.'
                    continue
                }

                $escapedEntry = $entry.Replace('"', '\"')
                $existsOutput = @(Invoke-Wsl (('if [ -f "{0}" ]; then echo FOUND; else echo MISSING; fi' -f $escapedEntry)))
                $exists = (($existsOutput -join '') -as [string]).Trim()
                if ($exists -eq 'FOUND') {
                    Write-Check -Name ("Compose file {0}" -f $entry) -Status PASS
                }
                else {
                    Write-Check -Name ("Compose file {0}" -f $entry) -Status WARN -Detail 'File referenced by COMPOSE_FILE does not exist.'
                }
            }

            if ([string]::IsNullOrWhiteSpace($runtimeBindHost)) {
                Write-Check -Name 'Runtime key ODYSSEUS_APP_BIND_HOST' -Status WARN -Detail 'Key is missing.'
            }
            else {
                Write-Check -Name 'Runtime key ODYSSEUS_APP_BIND_HOST' -Status PASS -Detail ("Value: {0}" -f $runtimeBindHost)
            }

            if ([string]::IsNullOrWhiteSpace($runtimeDeploymentMode)) {
                Write-Check -Name 'Runtime key ODYSSEUS_DEPLOYMENT_MODE' -Status WARN -Detail 'Key is missing.'
            }
            elseif ($runtimeDeploymentMode -notmatch '^(local|lan-host)$') {
                Write-Check -Name 'Runtime key ODYSSEUS_DEPLOYMENT_MODE' -Status WARN -Detail ("Unparseable value: {0}" -f $runtimeDeploymentMode)
            }
            else {
                Write-Check -Name 'Runtime key ODYSSEUS_DEPLOYMENT_MODE' -Status PASS -Detail ("Value: {0}" -f $runtimeDeploymentMode)
            }

            $hasHostModeOverride = $composeFiles | Where-Object { $_ -match 'docker-compose\.host-mode\.override\.yml$' } | Select-Object -First 1
            if ($null -ne $hostModeIntent) {
                if ($hostModeIntent -and -not $hasHostModeOverride) {
                    Write-Check -Name 'Host mode parity (config vs COMPOSE_FILE)' -Status WARN -Detail 'Launcher intent is host mode ON, but COMPOSE_FILE has no host-mode override file.'
                }
                elseif ((-not $hostModeIntent) -and $hasHostModeOverride) {
                    Write-Check -Name 'Host mode parity (config vs COMPOSE_FILE)' -Status WARN -Detail 'Launcher intent is host mode OFF, but COMPOSE_FILE includes host-mode override file.'
                }
                else {
                    Write-Check -Name 'Host mode parity (config vs COMPOSE_FILE)' -Status PASS
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($bindHostIntent) -and -not [string]::IsNullOrWhiteSpace($runtimeBindHost) -and $bindHostIntent -ne $runtimeBindHost) {
                Write-Check -Name 'Bind host parity (launcher vs runtime.env)' -Status WARN -Detail ("Launcher value '{0}' does not match runtime.env value '{1}'." -f $bindHostIntent, $runtimeBindHost)
            }
            elseif (-not [string]::IsNullOrWhiteSpace($bindHostIntent) -and -not [string]::IsNullOrWhiteSpace($runtimeBindHost)) {
                Write-Check -Name 'Bind host parity (launcher vs runtime.env)' -Status PASS
            }

            if (-not [string]::IsNullOrWhiteSpace($runtimeDeploymentMode) -and $runtimeDeploymentMode -match '^(local|lan-host)$' -and $null -ne $deploymentModeIntent) {
                if ($runtimeDeploymentMode -ne $deploymentModeIntent) {
                    Write-Check -Name 'Deployment mode parity (launcher vs runtime.env)' -Status WARN -Detail ("Launcher mode '{0}' differs from runtime.env mode '{1}'." -f $deploymentModeIntent, $runtimeDeploymentMode)
                }
                else {
                    Write-Check -Name 'Deployment mode parity (launcher vs runtime.env)' -Status PASS
                }
            }
        }

        $listen7000Consistency = Get-NetTCPConnection -LocalPort 7000 -State Listen -ErrorAction SilentlyContinue
        $lanBindConsistency = $listen7000Consistency | Where-Object { $_.LocalAddress -in @('::', '0.0.0.0') }
        $loopBindConsistency = $listen7000Consistency | Where-Object { $_.LocalAddress -in @('127.0.0.1', '::1') }
        $specificBindConsistency = $listen7000Consistency | Where-Object { $_.LocalAddress -notin @('::', '0.0.0.0', '127.0.0.1', '::1') }
        if ($null -ne $hostModeIntent) {
            if ($hostModeIntent -and $loopBindConsistency) {
                Write-Check -Name 'Host mode parity (config vs port 7000 bind)' -Status WARN -Detail 'Host mode is ON but listener appears loopback-only.'
            }
            elseif ((-not $hostModeIntent) -and $lanBindConsistency) {
                Write-Check -Name 'Host mode parity (config vs port 7000 bind)' -Status WARN -Detail 'Host mode is OFF but listener appears exposed on all interfaces.'
            }
            elseif ($listen7000Consistency) {
                Write-Check -Name 'Host mode parity (config vs port 7000 bind)' -Status PASS
            }
            else {
                Write-Check -Name 'Host mode parity (config vs port 7000 bind)' -Status WARN -Detail 'No active listener on port 7000; parity cannot be fully confirmed.'
            }
        }

        $expectedBindHost = ''
        if (-not [string]::IsNullOrWhiteSpace($bindHostIntent)) {
            $expectedBindHost = $bindHostIntent
        }
        elseif ($null -ne $deploymentModeIntent) {
            $expectedBindHost = if ($deploymentModeIntent -eq 'lan-host') { '0.0.0.0' } else { '127.0.0.1' }
        }

        if (-not [string]::IsNullOrWhiteSpace($expectedBindHost)) {
            if ($expectedBindHost -eq '127.0.0.1') {
                if ($lanBindConsistency -or $specificBindConsistency) {
                    Write-Check -Name 'Bind host parity (intent vs port 7000 bind)' -Status WARN -Detail 'Intent is loopback-only, but listener appears exposed beyond loopback.'
                }
                elseif ($loopBindConsistency) {
                    Write-Check -Name 'Bind host parity (intent vs port 7000 bind)' -Status PASS
                }
            }
            else {
                $matchingSpecific = $listen7000Consistency | Where-Object { $_.LocalAddress -eq $expectedBindHost }
                if (-not $listen7000Consistency) {
                    Write-Check -Name 'Bind host parity (intent vs port 7000 bind)' -Status WARN -Detail 'No active listener on port 7000; parity cannot be confirmed.'
                }
                elseif (-not $lanBindConsistency -and -not $matchingSpecific) {
                    Write-Check -Name 'Bind host parity (intent vs port 7000 bind)' -Status WARN -Detail ("Listener is not bound to intended host '{0}' (and no wildcard bind detected)." -f $expectedBindHost)
                }
                else {
                    Write-Check -Name 'Bind host parity (intent vs port 7000 bind)' -Status PASS
                }
            }
        }
    }
}

if ($runConsistency) {
    Write-Section '7) Service endpoint summary (informational)'

    $serviceRows = [System.Collections.Generic.List[PSCustomObject]]::new()
    $targetRows = [System.Collections.Generic.List[PSCustomObject]]::new()

    $ollamaListeners = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -match '^(\d{1,3}\.){3}\d{1,3}$' -or $_.LocalAddress -eq '0.0.0.0' }
    if ($null -eq $ollamaListeners -or $ollamaListeners.Count -eq 0) {
        Add-SummaryRow -Rows $serviceRows -Level 'WARN' -Service 'ollama' -HostContext 'Windows' -BindIp 'n/a' -PublishedPort 'n/a' -InternalPort '11434' -Protocol 'tcp' -Source 'Get-NetTCPConnection' -Note 'No IPv4 listener found on 11434.'
    }
    else {
        foreach ($listener in $ollamaListeners) {
            $processLabel = Get-ListenerProcessLabel -Listener $listener
            Add-SummaryRow -Rows $serviceRows -Level 'INFO' -Service 'ollama' -HostContext 'Windows' -BindIp $listener.LocalAddress -PublishedPort '11434' -InternalPort '11434' -Protocol 'tcp' -Process $processLabel -Health 'n/a' -Uptime 'n/a' -Source 'Get-NetTCPConnection' -Note 'Host listener'
        }
    }

    $odysseusListeners = Get-NetTCPConnection -LocalPort 7000 -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalAddress -match '^(\d{1,3}\.){3}\d{1,3}$' -or $_.LocalAddress -eq '0.0.0.0' }
    if ($null -eq $odysseusListeners -or $odysseusListeners.Count -eq 0) {
        Add-SummaryRow -Rows $serviceRows -Level 'WARN' -Service 'odysseus-http' -HostContext 'Windows' -BindIp 'n/a' -PublishedPort 'n/a' -InternalPort '7000' -Protocol 'tcp' -Source 'Get-NetTCPConnection' -Note 'No IPv4 listener found on 7000.'
    }
    else {
        foreach ($listener in $odysseusListeners) {
            $processLabel = Get-ListenerProcessLabel -Listener $listener
            Add-SummaryRow -Rows $serviceRows -Level 'INFO' -Service 'odysseus-http' -HostContext 'Windows' -BindIp $listener.LocalAddress -PublishedPort '7000' -InternalPort '7000' -Protocol 'tcp' -Process $processLabel -Health 'n/a' -Uptime 'n/a' -Source 'Get-NetTCPConnection' -Note 'Host listener'
        }
    }

    $composeEntries = @(Get-ComposePsEntries)
    if ($composeEntries.Count -eq 0) {
        Add-SummaryRow -Rows $serviceRows -Level 'WARN' -Service 'compose-services' -HostContext 'WSL' -BindIp 'n/a' -PublishedPort 'n/a' -InternalPort 'n/a' -Protocol 'n/a' -Source 'docker compose ps --format json' -Note 'Compose service/port data unavailable.'
    }
    else {
        foreach ($entry in $composeEntries) {
            $serviceName = if ($null -ne $entry.Service) { [string]$entry.Service } else { [string]$entry.Name }
            $serviceState = if ($null -ne $entry.State) { [string]$entry.State } else { 'unknown' }
            $serviceHealth = if ($null -ne $entry.Health -and -not [string]::IsNullOrWhiteSpace([string]$entry.Health)) { [string]$entry.Health } else { 'n/a' }
            $serviceUptime = if ($null -ne $entry.RunningFor -and -not [string]::IsNullOrWhiteSpace([string]$entry.RunningFor)) { [string]$entry.RunningFor } elseif ($null -ne $entry.Status) { [string]$entry.Status } else { 'n/a' }
            $publishers = @()
            if ($null -ne $entry.Publishers) {
                $publishers = @($entry.Publishers)
            }

            if ($publishers.Count -gt 0) {
                foreach ($publisher in $publishers) {
                    $url = if ($null -ne $publisher.URL) { [string]$publisher.URL } else { '' }
                    if ([string]::IsNullOrWhiteSpace($url)) {
                        $url = '0.0.0.0'
                    }
                    if ($url -eq '::' -or $url -eq '::1' -or $url -match ':') {
                        continue
                    }

                    $publishedPort = if ($null -ne $publisher.PublishedPort) { [string]$publisher.PublishedPort } else { 'n/a' }
                    $targetPort = if ($null -ne $publisher.TargetPort) { [string]$publisher.TargetPort } else { 'n/a' }
                    $protocol = if ($null -ne $publisher.Protocol) { [string]$publisher.Protocol } else { 'tcp' }
                    Add-SummaryRow -Rows $serviceRows -Level 'INFO' -Service $serviceName -HostContext 'WSL container -> host' -BindIp $url -PublishedPort $publishedPort -InternalPort $targetPort -Protocol $protocol -Process 'container' -Health $serviceHealth -Uptime $serviceUptime -Source 'docker compose ps --format json' -Note $serviceState
                }
            }
            else {
                $internalPort = 'n/a'
                if ($null -ne $entry.Ports -and ([string]$entry.Ports) -match '->(\d+)/') {
                    $internalPort = $matches[1]
                }
                elseif ($null -ne $entry.Ports -and ([string]$entry.Ports) -match '(\d+)/(tcp|udp)') {
                    $internalPort = $matches[1]
                }

                Add-SummaryRow -Rows $serviceRows -Level 'WARN' -Service $serviceName -HostContext 'WSL container' -BindIp 'n/a' -PublishedPort 'n/a' -InternalPort $internalPort -Protocol 'n/a' -Process 'container' -Health $serviceHealth -Uptime $serviceUptime -Source 'docker compose ps --format json' -Note 'No published IPv4 host port found.'
            }
        }
    }

    $llmHostValue = if ($runtimeEnvMap.ContainsKey('LLM_HOST')) { $runtimeEnvMap['LLM_HOST'] } else { '' }
    $ollamaBaseUrlValue = if ($runtimeEnvMap.ContainsKey('OLLAMA_BASE_URL')) { $runtimeEnvMap['OLLAMA_BASE_URL'] } else { '' }
    $embeddingUrlValue = if ($runtimeEnvMap.ContainsKey('EMBEDDING_URL')) { $runtimeEnvMap['EMBEDDING_URL'] } else { '' }

    $ollamaTarget = Resolve-UriInfo -Value $ollamaBaseUrlValue
    if ($null -eq $ollamaTarget) {
        Add-TargetRow -Rows $targetRows -Level 'WARN' -Consumer 'odysseus.llm' -TargetHost 'n/a' -Port 'n/a' -Path 'n/a' -Source 'runtime.env' -Note 'OLLAMA_BASE_URL missing or invalid.'
    }
    else {
        $llmTargetPort = if ($ollamaBaseUrlValue -match ':(\d+)') { $matches[1] } else { '80' }
        Add-TargetRow -Rows $targetRows -Level 'INFO' -Consumer 'odysseus.llm' -TargetHost $ollamaTarget.Host -Port $llmTargetPort -Path $ollamaTarget.Path -Source 'runtime.env' -Note 'Runtime target'
    }

    $embeddingTarget = Resolve-UriInfo -Value $embeddingUrlValue
    if ($null -eq $embeddingTarget) {
        Add-TargetRow -Rows $targetRows -Level 'WARN' -Consumer 'odysseus.embedding' -TargetHost 'n/a' -Port 'n/a' -Path 'n/a' -Source 'runtime.env' -Note 'EMBEDDING_URL missing or invalid.'
    }
    else {
        $embeddingTargetPort = if ($embeddingUrlValue -match ':(\d+)') { $matches[1] } else { '80' }
        Add-TargetRow -Rows $targetRows -Level 'INFO' -Consumer 'odysseus.embedding' -TargetHost $embeddingTarget.Host -Port $embeddingTargetPort -Path $embeddingTarget.Path -Source 'runtime.env' -Note 'Runtime target'
    }

    if ([string]::IsNullOrWhiteSpace($llmHostValue)) {
        Add-TargetRow -Rows $targetRows -Level 'WARN' -Consumer 'runtime.LLM_HOST' -TargetHost 'n/a' -Port '11434' -Path '/api/tags probe' -Source 'runtime.env' -Note 'LLM_HOST is missing.'
    }
    else {
        Add-TargetRow -Rows $targetRows -Level 'INFO' -Consumer 'runtime.LLM_HOST' -TargetHost $llmHostValue -Port '11434' -Path '/api/tags probe' -Source 'runtime.env' -Note 'Configured host candidate'
    }

    Write-SummaryTable -Title 'Bind/listen view (IPv4 only)' -Rows @($serviceRows)
    Write-SummaryTable -Title 'Runtime dependency targets' -Rows @($targetRows)

    if ($IncludeFailureLogHints) {
        $failureRows = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($entry in $composeEntries) {
            $serviceName = if ($null -ne $entry.Service) { [string]$entry.Service } else { [string]$entry.Name }
            if ([string]::IsNullOrWhiteSpace($serviceName)) { continue }

            $state = if ($null -ne $entry.State) { [string]$entry.State } else { '' }
            $health = if ($null -ne $entry.Health) { [string]$entry.Health } else { '' }
            $isProblematic = ($state -ne 'running') -or ((-not [string]::IsNullOrWhiteSpace($health)) -and ($health -ne 'healthy'))
            if (-not $isProblematic) { continue }

            $hint = Get-ComposeServiceLogTail -Service $serviceName -Tail 10
            if ([string]::IsNullOrWhiteSpace($hint)) {
                $hint = '(log hint unavailable)'
            }

            $failureRows.Add([PSCustomObject]@{
                    Service = $serviceName
                    State = if ([string]::IsNullOrWhiteSpace($state)) { 'unknown' } else { $state }
                    Health = if ([string]::IsNullOrWhiteSpace($health)) { 'n/a' } else { $health }
                    LogTail = $hint
                })
        }

        Write-SummaryTable -Title 'Failure log hints (optional)' -Rows @($failureRows)
    }

    Write-Host '[INFO] Summary section is informational only and does not change PASS/WARN/FAIL totals.' -ForegroundColor DarkGray
}

Write-Host ""
$verdict = if ($script:CheckContext.FailCount -gt 0) { 'DOWN' } elseif ($script:CheckContext.WarnCount -gt 0) { 'DEGRADED' } else { 'READY' }
$verdictColor = @{ READY = 'Green'; DEGRADED = 'Yellow'; DOWN = 'Red' }[$verdict]

Write-Host ("Verdict: {0}" -f $verdict) -ForegroundColor $verdictColor
Write-Host ("Checks: {0}/{1} passed, {2} warning(s), {3} failure(s)" -f $script:CheckContext.PassCount, $script:CheckContext.Results.Count, $script:CheckContext.WarnCount, $script:CheckContext.FailCount)

if ($script:CheckContext.FailCount -gt 0) { exit 1 }
exit 0
