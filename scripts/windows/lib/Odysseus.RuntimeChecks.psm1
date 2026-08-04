$script:OdysseusRuntimeChecksVersion = '0.1.0'

function Get-OdysseusRuntimeChecksVersion {
    return $script:OdysseusRuntimeChecksVersion
}

function Invoke-OdysseusWslCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslDistro,
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [switch]$LoginShell
    )

    if ([string]::IsNullOrWhiteSpace($WslDistro)) {
        return [PSCustomObject]@{
            ExitCode = 1
            Output = @()
        }
    }

    $shellFlag = if ($LoginShell) { '-lc' } else { '-c' }
    $output = & wsl.exe -d $WslDistro -- bash $shellFlag $Command 2>$null
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output = @($output)
    }
}

function Get-OdysseusInstalledWslDistros {
    $distros = & wsl.exe -l -q 2>$null
    return @($distros | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Resolve-OdysseusUbuntuDistro {
    param([string[]]$Distros)

    if (-not $Distros) {
        $Distros = Get-OdysseusInstalledWslDistros
    }

    if ($Distros -contains 'Ubuntu') {
        return 'Ubuntu'
    }

    return ($Distros | Where-Object { $_ -match '^Ubuntu(\-.*)?$' } | Select-Object -First 1)
}

function Test-OdysseusHttpEndpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [int]$TimeoutSec = 5
    )

    try {
        $resp = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
        return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
    }
    catch {
        $response = $_.Exception.Response
        if ($null -ne $response) {
            try {
                $statusCode = [int]$response.StatusCode
                if ($statusCode -ge 200 -and $statusCode -lt 400) {
                    return $true
                }
            }
            catch {
                # Fall through and report endpoint as unreachable.
            }
        }
        return $false
    }
}

function Get-OdysseusWslGatewayIp {
    param([Parameter(Mandatory = $true)][string]$WslDistro)

    $route = Invoke-OdysseusWslCommand -WslDistro $WslDistro -Command 'ip route show default 2>/dev/null | head -n 1'
    if ($route.ExitCode -ne 0) {
        return $null
    }

    $routeLine = (($route.Output | Select-Object -First 1) -as [string]).Trim()
    if ($routeLine -match 'default\s+via\s+(\S+)') {
        return $matches[1]
    }

    return $null
}

function Get-OdysseusDefaultRouteAdapterIpv4 {
    try {
        $route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Where-Object { $_.State -eq 'Alive' -and $_.NextHop -ne '0.0.0.0' } |
            Sort-Object -Property @{ Expression = 'RouteMetric'; Ascending = $true }, @{ Expression = 'InterfaceMetric'; Ascending = $true } |
            Select-Object -First 1

        if ($null -eq $route) {
            return $null
        }

        $ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex -ErrorAction Stop |
            Where-Object {
                $_.IPAddress -notmatch '^127\.' -and
                $_.IPAddress -notmatch '^169\.254\.' -and
                $_.PrefixOrigin -ne 'WellKnown'
            } |
            Sort-Object -Property SkipAsSource |
            Select-Object -First 1 -ExpandProperty IPAddress

        if ([string]::IsNullOrWhiteSpace($ip)) {
            return $null
        }

        return $ip.Trim()
    }
    catch {
        return $null
    }
}

function Get-OdysseusOllamaCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslDistro,
        [string]$HostOverride
    )

    $candidates = [System.Collections.Generic.List[PSCustomObject]]::new()

    if (-not [string]::IsNullOrWhiteSpace($HostOverride)) {
        $candidates.Add([PSCustomObject]@{ Value = $HostOverride.Trim(); Source = 'override' })
    }

    $defaultRouteIpv4 = Get-OdysseusDefaultRouteAdapterIpv4
    if (-not [string]::IsNullOrWhiteSpace($defaultRouteIpv4)) {
        $candidates.Add([PSCustomObject]@{ Value = $defaultRouteIpv4; Source = 'windows-default-route-ipv4' })
    }

    $resolver = Invoke-OdysseusWslCommand -WslDistro $WslDistro -Command "grep -m1 '^nameserver[[:space:]]' /etc/resolv.conf 2>/dev/null | tr -s '[:space:]' ' ' | cut -d' ' -f2"
    if ($resolver.ExitCode -eq 0) {
        $resolverHost = (($resolver.Output | Select-Object -First 1) -as [string]).Trim()
        if (-not [string]::IsNullOrWhiteSpace($resolverHost)) {
            $candidates.Add([PSCustomObject]@{ Value = $resolverHost; Source = 'wsl-resolver-nameserver' })
        }
    }

    $gatewayIp = Get-OdysseusWslGatewayIp -WslDistro $WslDistro
    if (-not [string]::IsNullOrWhiteSpace($gatewayIp)) {
        $candidates.Add([PSCustomObject]@{ Value = $gatewayIp; Source = 'wsl-default-gateway' })
    }

    $candidates.Add([PSCustomObject]@{ Value = 'host.docker.internal'; Source = 'host-docker-internal' })

    $unique = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen = @{}
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate.Value)) { continue }
        if ($seen.ContainsKey($candidate.Value)) { continue }

        $seen[$candidate.Value] = $true
        $unique.Add($candidate)
    }

    return @($unique)
}

function Test-OdysseusWslOllamaCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslDistro,
        [Parameter(Mandatory = $true)]
        [string]$Host,
        [int]$TimeoutSec = 5
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $command = ('curl --noproxy "*" -sS -f --max-time {0} "http://{1}:11434/api/tags" >/dev/null 2>&1 && echo "OK|200" || echo "FAIL||1|curl_failed"' -f $TimeoutSec, $Host)
    $result = Invoke-OdysseusWslCommand -WslDistro $WslDistro -Command $command
    $stopwatch.Stop()

    $line = (($result.Output -join '') -as [string]).Trim()
    if ([string]::IsNullOrWhiteSpace($line)) {
        $line = 'FAIL||255|no_output'
    }

    $parts = $line -split '\|', 4
    return [PSCustomObject]@{
        Host = $Host
        Success = ($parts[0] -eq 'OK')
        HttpCode = if ($parts.Count -ge 2) { $parts[1] } else { '' }
        ExitCode = if ($parts.Count -ge 3) { $parts[2] } else { '' }
        Detail = if ($parts.Count -ge 4) { $parts[3] } else { '' }
        ElapsedMs = [int][math]::Round($stopwatch.Elapsed.TotalMilliseconds)
    }
}

function Invoke-OdysseusWslCompose {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WslDistro,
        [Parameter(Mandatory = $true)]
        [string]$ComposeArgs,
        [switch]$UseSudo,
        [switch]$StreamOutput
    )

    $sudoPrefix = if ($UseSudo) { 'sudo -n ' } else { '' }
    $script = @'
cd ~/odysseus 2>/dev/null || exit 1
runtime_env="$HOME/.odysseus/runtime.env"
compose_args=()
if [ -f "$runtime_env" ]; then
  compose_args+=(--env-file "$runtime_env")
  compose_files=$(grep '^COMPOSE_FILE=' "$runtime_env" 2>/dev/null | tail -n 1 | cut -d= -f2-)
  if [ -n "$compose_files" ]; then
    IFS=':' read -r -a cf <<< "$compose_files"
    for f in "${cf[@]}"; do
      [ -n "$f" ] && compose_args+=(-f "$f")
    done
  fi
fi
__SUDO__docker compose ${compose_args[@]} __ARGS__
'@

    $command = $script.Replace('__SUDO__', $sudoPrefix).Replace('__ARGS__', $ComposeArgs).Replace("`r`n", "`n")
    if ($StreamOutput) {
        & wsl.exe -d $WslDistro -- bash -lc $command
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output = @()
        }
    }

    return Invoke-OdysseusWslCommand -WslDistro $WslDistro -Command $command -LoginShell
}

function Invoke-OdysseusWslComposeCaptured {
        param(
                [Parameter(Mandatory = $true)]
                [string]$WslDistro,
                [Parameter(Mandatory = $true)]
                [string]$ComposeArgs,
                [switch]$UseSudo
        )

        $sudoPrefix = if ($UseSudo) { 'sudo -n ' } else { '' }
        $script = @'
cd ~/odysseus 2>/dev/null || exit 1
runtime_env="$HOME/.odysseus/runtime.env"
compose_args=()
if [ -f "$runtime_env" ]; then
    compose_args+=(--env-file "$runtime_env")
    compose_files=$(grep '^COMPOSE_FILE=' "$runtime_env" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    if [ -n "$compose_files" ]; then
        IFS=':' read -r -a cf <<< "$compose_files"
        for f in "${cf[@]}"; do
            [ -n "$f" ] && compose_args+=(-f "$f")
        done
    fi
fi
__SUDO__docker compose ${compose_args[@]} __ARGS__ 2>&1
'@

        $command = $script.Replace('__SUDO__', $sudoPrefix).Replace('__ARGS__', $ComposeArgs).Replace("`r`n", "`n")
        $output = & wsl.exe -d $WslDistro -- bash -lc $command
        return [PSCustomObject]@{
                ExitCode = $LASTEXITCODE
                Output = @($output)
        }
}

function Get-OdysseusComposeServiceStates {
    param([Parameter(Mandatory = $true)][string]$WslDistro)

    $result = Invoke-OdysseusWslCompose -WslDistro $WslDistro -ComposeArgs "ps --format '{{.Service}}|{{.State}}|{{.Health}}'"
    if ($result.ExitCode -ne 0) {
        $result = Invoke-OdysseusWslCompose -WslDistro $WslDistro -ComposeArgs "ps --format '{{.Service}}|{{.State}}|{{.Health}}'" -UseSudo
    }
    if ($result.ExitCode -ne 0) {
        return @{}
    }

    $states = @{}
    foreach ($line in $result.Output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split '\|', 3
        if ($parts.Count -lt 2) { continue }

        $service = $parts[0].Trim()
        $state = $parts[1].Trim().ToLowerInvariant()
        $health = if ($parts.Count -ge 3) { $parts[2].Trim().ToLowerInvariant() } else { '' }
        if ([string]::IsNullOrWhiteSpace($service)) { continue }

        $states[$service] = [PSCustomObject]@{
            State = $state
            Health = $health
        }
    }

    return $states
}

function Get-OdysseusFirewallRuleStatus {
    param([Parameter(Mandatory = $true)][string]$DisplayName)

    try {
        $rule = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match 'Access is denied|Windows System Error 5') {
            return [PSCustomObject]@{
                Status = 'AccessDenied'
                Exists = $false
                Enabled = $false
                Detail = 'Access denied while reading firewall rules. Re-run in an elevated terminal.'
            }
        }

        return [PSCustomObject]@{
            Status = 'Error'
            Exists = $false
            Enabled = $false
            Detail = $message
        }
    }

    if ($null -eq $rule) {
        return [PSCustomObject]@{
            Status = 'NotFound'
            Exists = $false
            Enabled = $false
            Detail = 'Rule not found.'
        }
    }

    $isEnabled = ($rule.Enabled -eq 'True')
    return [PSCustomObject]@{
        Status = if ($isEnabled) { 'Enabled' } else { 'Disabled' }
        Exists = $true
        Enabled = $isEnabled
        Detail = if ($isEnabled) { 'Rule exists and is enabled.' } else { 'Rule exists but is disabled.' }
    }
}

Export-ModuleMember -Function @(
    'Get-OdysseusRuntimeChecksVersion',
    'Invoke-OdysseusWslCommand',
    'Get-OdysseusInstalledWslDistros',
    'Resolve-OdysseusUbuntuDistro',
    'Test-OdysseusHttpEndpoint',
    'Get-OdysseusWslGatewayIp',
    'Get-OdysseusDefaultRouteAdapterIpv4',
    'Get-OdysseusOllamaCandidates',
    'Test-OdysseusWslOllamaCandidate',
    'Invoke-OdysseusWslCompose',
    'Invoke-OdysseusWslComposeCaptured',
    'Get-OdysseusComposeServiceStates',
    'Get-OdysseusFirewallRuleStatus'
)
