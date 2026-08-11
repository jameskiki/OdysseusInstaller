#Requires -Version 5.1
<#!
.SYNOPSIS
    End-to-end GPU diagnostics for Odysseus on Windows + WSL + Docker + Ollama.

.DESCRIPTION
    Verifies the complete acceleration chain:
      1) Windows NVIDIA driver visibility.
      2) WSL GPU passthrough (/dev/dxg + nvidia-smi).
      3) Docker GPU runtime inside WSL.
      4) Odysseus compose GPU profile and running container device requests.
      5) Odysseus container -> Ollama connectivity.
      6) Optional tiny inference probe + Ollama processor snapshot.

    This script is read-mostly and does not change project files. It can pull a
    CUDA test image when -RunDockerCudaProbe is enabled.

.PARAMETER WslDistro
    WSL distro name to use. Defaults to Ubuntu.

.PARAMETER RunDockerCudaProbe
    Runs: docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi

.PARAMETER RunOllamaInferenceProbe
    Sends a tiny chat-completions request to the Ollama endpoint reachable from
    the Odysseus container.

.PARAMETER Model
    Model name for the optional Ollama inference probe.

.PARAMETER StartCookbookMonitors
    Opens three monitor terminals for cookbook-time observation:
      - ollama ps (refresh loop)
      - nvidia-smi -l 1
      - wsl docker stats for odysseus-odysseus-1
#>
[CmdletBinding()]
param(
    [string]$WslDistro = 'Ubuntu',
    [switch]$RunDockerCudaProbe,
    [switch]$RunOllamaInferenceProbe,
    [string]$Model = 'glm4:9b-chat-q4_K_M',
    [switch]$StartCookbookMonitors
)

$ErrorActionPreference = 'Stop'

$script:PassCount = 0
$script:WarnCount = 0
$script:FailCount = 0
$script:Findings = [System.Collections.Generic.List[object]]::new()

function Write-Section {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Add-Finding {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARN', 'FAIL')][string]$Status,
        [string]$Detail = ''
    )

    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red' }[$Status]
    Write-Host ("[{0}] {1}" -f $Status, $Name) -ForegroundColor $color
    if ($Detail) {
        Write-Host ("    -> {0}" -f $Detail) -ForegroundColor DarkGray
    }

    $script:Findings.Add([PSCustomObject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    switch ($Status) {
        'PASS' { $script:PassCount++ }
        'WARN' { $script:WarnCount++ }
        'FAIL' { $script:FailCount++ }
    }
}

function Invoke-Wsl {
    param([Parameter(Mandatory = $true)][string]$Command)

    $output = & wsl.exe -d $WslDistro -- bash -lc $Command 2>&1
    return [PSCustomObject]@{
        ExitCode = [int]$LASTEXITCODE
        Output   = @($output)
        Text     = (@($output) -join "`n")
    }
}

function Require-Command {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Add-Finding -Name "Command available: $Name" -Status FAIL -Detail "$Name is not available in this PowerShell session."
        return $false
    }
    Add-Finding -Name "Command available: $Name" -Status PASS
    return $true
}

function Start-CookbookMonitorTerminals {
    param([string]$Distro)

    Write-Section -Title '6) Launching cookbook live monitors'

    $commands = @(
        @{
            Name = 'Ollama processor monitor'
            Cmd  = 'while ($true) { Clear-Host; Get-Date; ollama ps; Start-Sleep -Seconds 2 }'
        },
        @{
            Name = 'NVIDIA GPU monitor'
            Cmd  = 'nvidia-smi -l 1'
        },
        @{
            Name = 'Odysseus container resource monitor'
            Cmd  = ("wsl -d {0} -- sudo docker stats odysseus-odysseus-1" -f $Distro)
        }
    )

    foreach ($item in $commands) {
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit', '-Command', $item.Cmd) | Out-Null
            Add-Finding -Name ("Started monitor: {0}" -f $item.Name) -Status PASS -Detail $item.Cmd
        }
        catch {
            Add-Finding -Name ("Started monitor: {0}" -f $item.Name) -Status FAIL -Detail $_.Exception.Message
        }
    }

    Add-Finding -Name 'Interpretation rule' -Status PASS -Detail 'If container CPU spikes while ollama ps remains 100% GPU, the bottleneck is outside model inference.'
}

Write-Host "Odysseus GPU Path Diagnostic" -ForegroundColor Magenta
Write-Host ("Date: {0}" -f (Get-Date)) -ForegroundColor DarkGray
Write-Host ("WSL distro: {0}" -f $WslDistro) -ForegroundColor DarkGray

Write-Section -Title '1) Windows GPU baseline'

if (Require-Command -Name 'nvidia-smi') {
    try {
        $winSmi = & nvidia-smi 2>&1
        if ($LASTEXITCODE -eq 0) {
            $top = ($winSmi | Select-Object -First 3) -join ' '
            Add-Finding -Name 'Windows nvidia-smi' -Status PASS -Detail $top
        }
        else {
            Add-Finding -Name 'Windows nvidia-smi' -Status FAIL -Detail (($winSmi | Select-Object -First 8) -join ' | ')
        }
    }
    catch {
        Add-Finding -Name 'Windows nvidia-smi' -Status FAIL -Detail $_.Exception.Message
    }
}

Write-Section -Title '2) WSL GPU passthrough'

if (Require-Command -Name 'wsl.exe') {
    $distros = & wsl.exe -l -v 2>&1
    if ($LASTEXITCODE -ne 0) {
        Add-Finding -Name 'WSL distro list' -Status FAIL -Detail (($distros | Select-Object -First 8) -join ' | ')
    }
    else {
        $distroProbe = & wsl.exe -d $WslDistro -- bash -lc 'echo ok' 2>&1
        if ($LASTEXITCODE -eq 0) {
            $distroLine = $distros | Select-Object -First 6
            Add-Finding -Name 'WSL distro present' -Status PASS -Detail (($distroLine -join ' | '))
        }
        else {
            Add-Finding -Name 'WSL distro present' -Status FAIL -Detail "Distro '$WslDistro' could not be started. Probe: $((@($distroProbe) | Select-Object -First 3) -join ' | ')"
        }
    }

    $wslDxg = Invoke-Wsl -Command 'test -e /dev/dxg'
    if ($wslDxg.ExitCode -eq 0) {
        Add-Finding -Name 'WSL /dev/dxg' -Status PASS
    }
    else {
        Add-Finding -Name 'WSL /dev/dxg' -Status FAIL -Detail 'Missing /dev/dxg, GPU passthrough is not active in WSL.'
    }

    $wslSmi = Invoke-Wsl -Command 'nvidia-smi'
    if ($wslSmi.ExitCode -eq 0) {
        $line = ($wslSmi.Output | Select-Object -First 3) -join ' '
        Add-Finding -Name 'WSL nvidia-smi' -Status PASS -Detail $line
    }
    else {
        Add-Finding -Name 'WSL nvidia-smi' -Status FAIL -Detail (($wslSmi.Output | Select-Object -First 10) -join ' | ')
    }
}

Write-Section -Title '3) Docker GPU runtime in WSL'

$sudoTicket = Invoke-Wsl -Command 'sudo -n true >/dev/null 2>&1'
if ($sudoTicket.ExitCode -ne 0) {
    Add-Finding -Name 'Sudo ticket' -Status WARN -Detail 'No cached sudo ticket. Prompting for WSL sudo password now.'
    & wsl.exe -d $WslDistro -- bash -lc "sudo -v -p '[SUDO] Enter Ubuntu password for Odysseus GPU diagnostics: '"
    if ($LASTEXITCODE -eq 0) {
        Add-Finding -Name 'Sudo authentication' -Status PASS
    }
    else {
        Add-Finding -Name 'Sudo authentication' -Status FAIL -Detail 'Could not acquire sudo ticket; Docker GPU checks cannot proceed.'
        Write-Section -Title 'Summary'
        Write-Host ("PASS: {0} | WARN: {1} | FAIL: {2}" -f $script:PassCount, $script:WarnCount, $script:FailCount) -ForegroundColor White
        Write-Host 'Result: One or more GPU path checks failed. Review FAIL items above.' -ForegroundColor Red
        exit 1
    }
}
else {
    Add-Finding -Name 'Sudo ticket' -Status PASS
}

$dockerInfo = Invoke-Wsl -Command "sudo docker info 2>/dev/null | sed -n '1,140p' | grep '^ Runtimes:'; sudo docker info 2>/dev/null | sed -n '1,140p' | grep '^ Default Runtime:'"
if ($dockerInfo.ExitCode -eq 0) {
    if ($dockerInfo.Text -match 'nvidia') {
        Add-Finding -Name 'Docker runtime includes nvidia' -Status PASS -Detail $dockerInfo.Text
    }
    else {
        Add-Finding -Name 'Docker runtime includes nvidia' -Status WARN -Detail $dockerInfo.Text
    }
}
else {
    Add-Finding -Name 'Docker info query' -Status FAIL -Detail (($dockerInfo.Output | Select-Object -First 15) -join ' | ')
}

$ctk = Invoke-Wsl -Command 'nvidia-ctk --version'
if ($ctk.ExitCode -eq 0) {
    Add-Finding -Name 'NVIDIA container toolkit' -Status PASS -Detail (($ctk.Output | Select-Object -First 1) -join '')
}
else {
    Add-Finding -Name 'NVIDIA container toolkit' -Status WARN -Detail 'nvidia-ctk not found in WSL path.'
}

if ($RunDockerCudaProbe) {
    $probeCmd = 'sudo docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi'
    $cudaProbe = Invoke-Wsl -Command $probeCmd
    if ($cudaProbe.ExitCode -eq 0) {
        Add-Finding -Name 'Docker CUDA probe container' -Status PASS -Detail 'CUDA probe succeeded with --gpus all.'
    }
    else {
        Add-Finding -Name 'Docker CUDA probe container' -Status FAIL -Detail (($cudaProbe.Output | Select-Object -Last 20) -join ' | ')
    }
}
else {
    Add-Finding -Name 'Docker CUDA probe container' -Status WARN -Detail 'Skipped. Re-run with -RunDockerCudaProbe to verify with a CUDA test image.'
}

Write-Section -Title '4) Odysseus compose + container GPU wiring'

$runtimeEnvCheck = Invoke-Wsl -Command 'test -f ~/.odysseus/runtime.env'
if ($runtimeEnvCheck.ExitCode -ne 0) {
    Add-Finding -Name 'Runtime env file' -Status FAIL -Detail '~/.odysseus/runtime.env not found.'
}
else {
    Add-Finding -Name 'Runtime env file' -Status PASS

    $composeLineResult = Invoke-Wsl -Command 'grep -E "^COMPOSE_FILE=" ~/.odysseus/runtime.env | tail -n 1'
    $composeLine = ($composeLineResult.Output | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($composeLine)) {
        Add-Finding -Name 'COMPOSE_FILE in runtime env' -Status FAIL -Detail 'COMPOSE_FILE key is missing in ~/.odysseus/runtime.env.'
    }
    else {
        Add-Finding -Name 'COMPOSE_FILE in runtime env' -Status PASS -Detail $composeLine

        if ($composeLine -match 'docker-compose.gpu-nvidia.yml') {
            Add-Finding -Name 'GPU compose overlay selected' -Status PASS
        }
        else {
            Add-Finding -Name 'GPU compose overlay selected' -Status WARN -Detail 'GPU overlay not present in COMPOSE_FILE.'
        }
    }
}

$inspect = Invoke-Wsl -Command 'sudo docker inspect odysseus-odysseus-1 2>/dev/null | grep -E -i "runtime|devicerequests|nvidia|capabilities|gpu" | head -n 60'
if ($inspect.ExitCode -eq 0) {
    $hasGpuRequest = $inspect.Text -match 'nvidia' -or $inspect.Text -match 'gpu'
    if ($hasGpuRequest) {
        Add-Finding -Name 'Odysseus container GPU device request' -Status PASS -Detail $inspect.Text
    }
    else {
        Add-Finding -Name 'Odysseus container GPU device request' -Status WARN -Detail $inspect.Text
    }
}
else {
    Add-Finding -Name 'Odysseus container present' -Status FAIL -Detail 'Container odysseus-odysseus-1 not found or not inspectable.'
}

$insideGpu = Invoke-Wsl -Command 'sudo docker exec odysseus-odysseus-1 bash -lc "nvidia-smi"'
if ($insideGpu.ExitCode -eq 0) {
    Add-Finding -Name 'nvidia-smi inside odysseus container' -Status PASS -Detail (($insideGpu.Output | Select-Object -First 3) -join ' ')
}
else {
    Add-Finding -Name 'nvidia-smi inside odysseus container' -Status FAIL -Detail (($insideGpu.Output | Select-Object -Last 20) -join ' | ')
}

Write-Section -Title '5) Odysseus -> Ollama endpoint path'

$ollamaVars = Invoke-Wsl -Command 'sudo docker exec odysseus-odysseus-1 env | grep -E "^OLLAMA_BASE_URL=|^LLM_HOST=|^EMBEDDING_URL="'
if ($ollamaVars.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($ollamaVars.Text)) {
    Add-Finding -Name 'Ollama endpoint env vars in container' -Status PASS -Detail (($ollamaVars.Output -join ' | '))
}
else {
    Add-Finding -Name 'Ollama endpoint env vars in container' -Status WARN -Detail 'Could not read OLLAMA_BASE_URL/LLM_HOST/EMBEDDING_URL from container env.'
}

$ollamaModels = Invoke-Wsl -Command 'sudo docker exec odysseus-odysseus-1 bash -lc "curl -sS --max-time 8 ${OLLAMA_BASE_URL:-http://host.docker.internal:11434/v1}/models | head -c 350"'
if ($ollamaModels.ExitCode -eq 0 -and $ollamaModels.Text -match '"object"\s*:\s*"list"') {
    Add-Finding -Name 'Container can query Ollama models endpoint' -Status PASS -Detail $ollamaModels.Text
}
else {
    Add-Finding -Name 'Container can query Ollama models endpoint' -Status FAIL -Detail (($ollamaModels.Output | Select-Object -Last 20) -join ' | ')
}

if ($RunOllamaInferenceProbe) {
    $probePayload = '{"model":"' + $Model + '","messages":[{"role":"user","content":"Say hi in three words"}],"max_tokens":16}'
    $probeCmd = 'sudo docker exec odysseus-odysseus-1 bash -lc ''curl -sS --max-time 20 ${OLLAMA_BASE_URL:-http://host.docker.internal:11434/v1}/chat/completions -H "Content-Type: application/json" -d ''''' + $probePayload + ''''' | head -c 280'''
    $inferenceProbe = Invoke-Wsl -Command $probeCmd
    if ($inferenceProbe.ExitCode -eq 0 -and $inferenceProbe.Text -match '"chat.completion"') {
        Add-Finding -Name 'Ollama inference probe from container' -Status PASS -Detail $inferenceProbe.Text
    }
    else {
        Add-Finding -Name 'Ollama inference probe from container' -Status FAIL -Detail (($inferenceProbe.Output | Select-Object -Last 20) -join ' | ')
    }

    if (Get-Command ollama -ErrorAction SilentlyContinue) {
        $ps = & ollama ps 2>&1
        if ($LASTEXITCODE -eq 0) {
            $processorLine = ($ps | Where-Object { $_ -match '^\S+\s+\S+\s+\S+\s+(\d+%\s+GPU|CPU|\d+%\s+CPU)' } | Select-Object -First 1)
            if ($processorLine) {
                Add-Finding -Name 'Windows ollama processor snapshot' -Status PASS -Detail $processorLine
            }
            else {
                Add-Finding -Name 'Windows ollama processor snapshot' -Status WARN -Detail (($ps | Select-Object -First 6) -join ' | ')
            }
        }
        else {
            Add-Finding -Name 'Windows ollama processor snapshot' -Status WARN -Detail (($ps | Select-Object -First 6) -join ' | ')
        }
    }
    else {
        Add-Finding -Name 'Windows ollama processor snapshot' -Status WARN -Detail 'ollama CLI not found on Windows PATH.'
    }
}
else {
    Add-Finding -Name 'Ollama inference probe from container' -Status WARN -Detail 'Skipped. Re-run with -RunOllamaInferenceProbe to confirm live inference path.'
}

if ($StartCookbookMonitors) {
    Start-CookbookMonitorTerminals -Distro $WslDistro
}
else {
    Add-Finding -Name 'Cookbook live monitors' -Status WARN -Detail 'Not started. Re-run with -StartCookbookMonitors to launch ollama ps, nvidia-smi, and docker stats monitors.'
}

Write-Section -Title 'Summary'
Write-Host ("PASS: {0} | WARN: {1} | FAIL: {2}" -f $script:PassCount, $script:WarnCount, $script:FailCount) -ForegroundColor White

if ($script:FailCount -eq 0) {
    Write-Host 'Result: GPU path is operational, with any warnings shown above.' -ForegroundColor Green
    exit 0
}
else {
    Write-Host 'Result: One or more GPU path checks failed. Review FAIL items above.' -ForegroundColor Red
    exit 1
}
