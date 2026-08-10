#!/usr/bin/env bash
set -Ee -o pipefail

export DEBIAN_FRONTEND=noninteractive
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/false

RUNTIME_LOG_DIR="$HOME/.odysseus/logs"
mkdir -p "$RUNTIME_LOG_DIR"
BOOTSTRAP_LOG_FILE="${ODYSSEUS_BOOTSTRAP_LOG:-$RUNTIME_LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log}"
touch "$BOOTSTRAP_LOG_FILE" 2>/dev/null || true
ln -sfn "$BOOTSTRAP_LOG_FILE" "$RUNTIME_LOG_DIR/latest-bootstrap.log" 2>/dev/null || true
exec > >(tee -a "$BOOTSTRAP_LOG_FILE") 2>&1
echo "[INFO] Bootstrap log: $BOOTSTRAP_LOG_FILE"

print_step() { echo -e "\n\e[1;36m[INTENT] $1\e[0m"; }
print_ok()   { echo -e "\e[1;32m[SUCCESS] $1\e[0m"; }
print_fail() { echo -e "\e[1;31m[FAILED] $1\e[0m"; exit 1; }

TARGET_DIR_DEFAULT="$HOME/odysseus"
RUNTIME_DIR_DEFAULT="$HOME/.odysseus"
RUNTIME_ENV_DEFAULT="$RUNTIME_DIR_DEFAULT/runtime.env"

detect_bootstrap_execution_context() {
    local script_path
    local script_dir

    script_path=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")
    script_dir=$(dirname "$script_path")

    BOOTSTRAP_SCRIPT_PATH="$script_path"
    BOOTSTRAP_SCRIPT_DIR="$script_dir"
    BOOTSTRAP_CONTEXT="ExternalCopy"

    if [ -d "$TARGET_DIR_DEFAULT/.git" ] && [ "$script_path" = "$TARGET_DIR_DEFAULT/scripts/wsl/run_odysseus.sh" ]; then
        BOOTSTRAP_CONTEXT="WorkspaceClone"
        return 0
    fi

    if [[ "$script_path" == /mnt/* ]]; then
        BOOTSTRAP_CONTEXT="WindowsMountedSource"
        return 0
    fi

    if [[ "$script_path" == "$HOME"/* ]]; then
        BOOTSTRAP_CONTEXT="LinuxHomeSource"
    fi
}

print_bootstrap_execution_context() {
    echo "[INFO] Bootstrap execution context: ${BOOTSTRAP_CONTEXT}"
    echo "[INFO] Bootstrap script path: ${BOOTSTRAP_SCRIPT_PATH}"
    echo "[INFO] Bootstrap script directory: ${BOOTSTRAP_SCRIPT_DIR}"
    echo "[INFO] Runtime env target: ${RUNTIME_ENV_DEFAULT}"
    echo "[INFO] Deployment mode input: ${ODYSSEUS_DEPLOYMENT_MODE:-auto}"
    echo "[INFO] Host mode input: ${ODYSSEUS_HOST_MODE:-0}"
    echo "[INFO] App bind host input: ${ODYSSEUS_APP_BIND_HOST:-auto}"
    echo "[INFO] Ollama host override input: ${ODYSSEUS_OLLAMA_HOST:-unset}"
    echo
}

handle_unexpected_error() {
    local exit_code="$1"
    local line_no="$2"
    local failed_command="$3"
    print_fail "Unexpected bootstrap error (exit ${exit_code}) at line ${line_no} while running: ${failed_command}"
}

trap 'handle_unexpected_error $? $LINENO "$BASH_COMMAND"' ERR

detect_bootstrap_execution_context
print_bootstrap_execution_context

run_with_progress() {
    local label="$1"
    shift

    local log_file
    log_file=$(mktemp /tmp/odysseus-progress.XXXXXX.log)
    "$@" >"$log_file" 2>&1 &
    local pid=$!
    local frames='|/-\\'
    local frame=0
    local elapsed=0
    local heartbeat_interval=15
    local last_reported_line=""
    local current_line=""

    while kill -0 "$pid" > /dev/null 2>&1; do
        printf '\r[WORKING] %s %s (%ss)' "$label" "${frames:frame:1}" "$elapsed"

        if [ "$elapsed" -gt 0 ] && [ $((elapsed % heartbeat_interval)) -eq 0 ]; then
            current_line=$(tail -n 1 "$log_file" 2>/dev/null | tr -d '\r')
            echo
            if [ -n "$current_line" ] && [ "$current_line" != "$last_reported_line" ]; then
                echo "[INFO] ${label}: still running (${elapsed}s). Last output: ${current_line}"
                last_reported_line="$current_line"
            else
                echo "[INFO] ${label}: still running (${elapsed}s)."
            fi
        fi

        sleep 1
        frame=$(((frame + 1) % 4))
        elapsed=$((elapsed + 1))
    done

    wait "$pid"
    local exit_code=$?
    printf '\r%-100s\r' ''

    if [ "$exit_code" -ne 0 ]; then
        echo "[INFO] Command failed: $*"
        echo "[INFO] Full command log: $log_file"
        echo "[INFO] Last installer output:"
        tail -n 40 "$log_file" || true
        return "$exit_code"
    fi

    rm -f "$log_file"
    return 0
}

wait_for_apt_unlock() {
    local locks=(
        /var/lib/apt/lists/lock
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/cache/apt/archives/lock
    )

    for _ in $(seq 1 60); do
        local locked=0
        for lock in "${locks[@]}"; do
            if sudo fuser "$lock" > /dev/null 2>&1; then
                locked=1
                break
            fi
        done

        if [ "$locked" -eq 0 ]; then
            return 0
        fi

        echo "[INFO] apt/dpkg lock detected. Waiting for other package operations to finish..."
        sleep 2
    done

    return 1
}

ensure_dpkg_consistent() {
    local audit_output
    audit_output=$(sudo dpkg --audit 2>&1 || true)

    if [ -z "$audit_output" ]; then
        return 0
    fi

    echo "[INFO] Detected an incomplete dpkg state. Repairing package configuration now..."

    # Use the same sequence a human operator would run for broken dependencies:
    # 1) configure unpacked packages, 2) fix missing deps, 3) configure again.
    if ! run_with_progress "Repairing interrupted dpkg state" sudo dpkg --configure -a; then
        echo "[WARN] Initial 'dpkg --configure -a' did not complete cleanly. Trying apt dependency repair..."

        local dep_fix_ok=0
        for attempt in 1 2; do
            if ! wait_for_apt_unlock; then
                echo "[WARN] apt/dpkg lock remained busy before dependency repair attempt ${attempt}."
            fi

            if run_with_progress "Fixing package dependencies (attempt ${attempt}/2)" sudo apt-get install -f -y -qq; then
                dep_fix_ok=1
                break
            fi

            if [ "$attempt" -eq 1 ]; then
                echo "[WARN] 'apt-get install -f' failed on attempt 1. Refreshing package indexes before retry..."
                run_with_progress "Refreshing package indexes for recovery" run_apt_update || true
                echo "[INFO] Waiting briefly before retrying dependency repair..."
                sleep 3
            fi
        done

        if [ "$dep_fix_ok" -ne 1 ]; then
            echo "[WARN] Dependency repair did not complete after retries. Continuing to final dpkg pass for best-effort recovery."
        fi

        wait_for_apt_unlock || true
        run_with_progress "Finalizing package configuration" sudo dpkg --configure -a || true
    fi

    local post_audit
    post_audit=$(sudo dpkg --audit 2>&1 || true)
    if [ -n "$post_audit" ]; then
        echo "[INFO] Package audit before repair:"
        echo "$audit_output"
        echo "[INFO] Package audit after repair attempts:"
        echo "$post_audit"
        print_fail "dpkg still reports unfinished package configuration after automatic repair. Run 'sudo dpkg --configure -a' and 'sudo apt-get install -f' inside Ubuntu, then rerun Odysseus."
    fi
}

audit_ollama_gateway() {
    local gateway_host="$1"
    local url="http://${gateway_host}:11434/api/tags"
    local curl_output
    local curl_exit

    echo "[INFO] Auditing Ollama reachability at ${url}"
    set +e
    curl_output=$(curl --noproxy '*' -sS --connect-timeout 2 --max-time 4 -w 'HTTP_STATUS:%{http_code}' "$url" 2>&1)
    curl_exit=$?
    set -e

    if [ "$curl_exit" -eq 0 ] && printf '%s' "$curl_output" | grep -q 'HTTP_STATUS:200'; then
        print_ok "Ollama is reachable from WSL at ${url}."
        return 0
    fi

    case "$curl_exit" in
        7)
            print_fail "Ollama is not accepting connections at ${url}. Check that Windows Ollama is running and bound to 0.0.0.0:11434."
            ;;
        28)
            print_fail "Ollama timed out at ${url}. Check Windows firewall rules and WSL-to-host connectivity."
            ;;
        *)
            print_fail "Ollama audit failed for ${url} (curl exit ${curl_exit}). Check Windows Ollama binding, firewall, and host networking."
            ;;
    esac
}

is_ollama_reachable() {
    local host="$1"
    local url="http://${host}:11434/api/tags"

    curl --noproxy '*' -sS --connect-timeout 2 --max-time 4 -f "$url" > /dev/null 2>&1
}

probe_ollama_host() {
    local host="$1"
    local url="http://${host}:11434/api/tags"
    local curl_output
    local curl_exit
    local http_status

    ODYSSEUS_OLLAMA_LAST_PROBE_REASON=""

    set +e
    curl_output=$(curl --noproxy '*' -sS --connect-timeout 2 --max-time 4 -w 'HTTP_STATUS:%{http_code}' "$url" 2>&1)
    curl_exit=$?
    set -e

    if [ "$curl_exit" -eq 0 ] && printf '%s' "$curl_output" | grep -q 'HTTP_STATUS:200'; then
        return 0
    fi

    http_status=$(printf '%s' "$curl_output" | sed -n 's/.*HTTP_STATUS:\([0-9][0-9][0-9]\).*/\1/p' | tail -n 1)
    case "$curl_exit" in
        7)
            ODYSSEUS_OLLAMA_LAST_PROBE_REASON="connection failed (curl exit 7)"
            ;;
        28)
            ODYSSEUS_OLLAMA_LAST_PROBE_REASON="timed out (curl exit 28)"
            ;;
        *)
            if [ -n "$http_status" ]; then
                ODYSSEUS_OLLAMA_LAST_PROBE_REASON="HTTP status ${http_status}"
            else
                ODYSSEUS_OLLAMA_LAST_PROBE_REASON="curl exit ${curl_exit}"
            fi
            ;;
    esac

    return 1
}

resolve_windows_ollama_host() {
    local candidate
    local windows_default_route_ipv4
    local candidates=()
    local failure_reason

    ODYSSEUS_WINDOWS_GATEWAY_IP=""
    ODYSSEUS_OLLAMA_CANDIDATES_ATTEMPTED=""
    ODYSSEUS_OLLAMA_CANDIDATE_FAILURES=""

    # Explicit ODYSSEUS_OLLAMA_HOST has the highest priority for hosted/remote setups.
    if [ -n "${ODYSSEUS_OLLAMA_HOST:-}" ]; then
        candidates+=("${ODYSSEUS_OLLAMA_HOST}")
    fi

    # Allow advanced users to force a known-good host endpoint explicitly.
    if [ -n "${ODYSSEUS_WINDOWS_HOST_OVERRIDE:-}" ]; then
        candidates+=("${ODYSSEUS_WINDOWS_HOST_OVERRIDE}")
    fi

    # Prefer the Windows adapter used for the default route when available.
    windows_default_route_ipv4=$(powershell.exe -NoProfile -Command "\
\$route = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |\
    Where-Object { \$_.State -eq 'Alive' -and \$_.NextHop -ne '0.0.0.0' } |\
    Sort-Object RouteMetric, InterfaceMetric |\
    Select-Object -First 1;\
if (\$route) {\
    Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex \$route.InterfaceIndex -ErrorAction SilentlyContinue |\
        Where-Object { \$_.IPAddress -notmatch '^127\\.' -and \$_.IPAddress -notmatch '^169\\.254\\.' -and \$_.PrefixOrigin -ne 'WellKnown' } |\
        Sort-Object SkipAsSource |\
        Select-Object -First 1 -ExpandProperty IPAddress\
}" 2>/dev/null | tr -d '\r' | head -n 1)
    if [ -n "$windows_default_route_ipv4" ]; then
        candidates+=("$windows_default_route_ipv4")
    fi

    # WSL's synthetic DNS server can be the right bridge on some setups.
    candidate=$(awk '/^nameserver[[:space:]]+/ {print $2; exit}' /etc/resolv.conf)
    if [ -n "$candidate" ]; then
        candidates+=("$candidate")
    fi

    # The default route gateway often maps to the Windows host in WSL NAT mode.
    candidate=$(ip route show default 2> /dev/null | awk '{print $3; exit}')
    if [ -n "$candidate" ]; then
        candidates+=("$candidate")
    fi

    # host.docker.internal can work across Docker/WSL setups and keeps .env portable.
    candidates+=("host.docker.internal")

    local attempted=""
    for candidate in "${candidates[@]}"; do
        if [ -z "$candidate" ]; then
            continue
        fi

        case "|${attempted}|" in
            *"|${candidate}|"*)
                continue
                ;;
        esac
        attempted="${attempted}|${candidate}"
        if [ -n "$ODYSSEUS_OLLAMA_CANDIDATES_ATTEMPTED" ]; then
            ODYSSEUS_OLLAMA_CANDIDATES_ATTEMPTED="${ODYSSEUS_OLLAMA_CANDIDATES_ATTEMPTED}, ${candidate}"
        else
            ODYSSEUS_OLLAMA_CANDIDATES_ATTEMPTED="${candidate}"
        fi

        if probe_ollama_host "$candidate"; then
            ODYSSEUS_WINDOWS_GATEWAY_IP="$candidate"
            return 0
        fi

        failure_reason="$ODYSSEUS_OLLAMA_LAST_PROBE_REASON"
        if [ -z "$failure_reason" ]; then
            failure_reason="probe failed"
        fi

        if [ -n "$ODYSSEUS_OLLAMA_CANDIDATE_FAILURES" ]; then
            ODYSSEUS_OLLAMA_CANDIDATE_FAILURES="${ODYSSEUS_OLLAMA_CANDIDATE_FAILURES}; ${candidate}: ${failure_reason}"
        else
            ODYSSEUS_OLLAMA_CANDIDATE_FAILURES="${candidate}: ${failure_reason}"
        fi
    done

    return 1
}

run_apt_update() {
    local apt_args=(
        -o Acquire::Retries=3
        -o Acquire::http::Timeout=30
        -o Acquire::https::Timeout=30
    )

    if command -v timeout > /dev/null 2>&1; then
        sudo timeout 600 apt-get update "${apt_args[@]}"
    else
        sudo apt-get update "${apt_args[@]}"
    fi
}

run_git_command() {
    local operation_label="$1"
    shift

    local git_output
    local exit_code

    if command -v timeout > /dev/null 2>&1; then
        if git_output=$(timeout 180 git "$@" 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
    else
        if git_output=$(git "$@" 2>&1); then
            exit_code=0
        else
            exit_code=$?
        fi
    fi

    if [ "$exit_code" -eq 0 ]; then
        return 0
    fi

    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
        print_fail "${operation_label} timed out after 180 seconds. Check network/VPN/proxy access to github.com and rerun."
    fi

    local tail_output
    tail_output=$(printf '%s\n' "$git_output" | tail -n 30)
    print_fail "${operation_label} failed. Git output: ${tail_output}"
}

wait_for_docker() {
    for _ in $(seq 1 20); do
        if sudo docker info > /dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

ensure_docker_running() {
    if sudo docker info > /dev/null 2>&1; then
        return 0
    fi

    if command -v systemctl > /dev/null 2>&1 && [ "$(ps -o comm= 1 2> /dev/null)" = "systemd" ]; then
        sudo systemctl enable docker > /dev/null 2>&1 || true
        sudo systemctl start docker > /dev/null 2>&1 || true
    elif command -v service > /dev/null 2>&1; then
        sudo service docker start > /dev/null 2>&1 || true
    fi

    if sudo docker info > /dev/null 2>&1; then
        return 0
    fi

    if ! pgrep -x dockerd > /dev/null 2>&1; then
        sudo nohup dockerd > /tmp/odysseus-dockerd.log 2>&1 &
    fi

    wait_for_docker
}

ensure_docker_group_access() {
    local linux_user
    linux_user=$(id -un)

    sudo groupadd -f docker

    if id -nG "$linux_user" | tr ' ' '\n' | grep -qx docker; then
        print_ok "Linux user '$linux_user' already has docker-group access."
        return 0
    fi

    if sudo usermod -aG docker "$linux_user"; then
        print_ok "Added Linux user '$linux_user' to docker group."
        echo "[INFO] Docker group membership applies to new shells. If you still see docker permission issues, restart WSL (wsl --shutdown) and relaunch Odysseus."
        return 0
    fi

    print_fail "Failed to grant docker-group access to Linux user '$linux_user'."
}

upsert_env_key() {
    local key="$1"
    local value="$2"
    local env_file="$3"

    if grep -q "^${key}=" "$env_file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$env_file"
    fi
}

compose_args_from_runtime() {
    local env_file="$1"
    local target_dir="$2"
    local compose_files
    local compose_file
    local args=(--env-file "$env_file")

    compose_files=$(grep '^COMPOSE_FILE=' "$env_file" 2>/dev/null | tail -n 1 | cut -d= -f2-)
    if [ -z "$compose_files" ]; then
        args+=(-f "$target_dir/docker-compose.yml")
        printf '%s\n' "${args[@]}"
        return 0
    fi

    IFS=':' read -r -a compose_file_list <<< "$compose_files"
    for compose_file in "${compose_file_list[@]}"; do
        if [ -n "$compose_file" ]; then
            args+=(-f "$compose_file")
        fi
    done

    printf '%s\n' "${args[@]}"
}

configure_compose_files_runtime() {
    local env_file="$1"
    local target_dir="$2"
    local compose_files="$target_dir/docker-compose.yml"
    local bind_host="${ODYSSEUS_APP_BIND_HOST:-}"

    if command -v nvidia-smi > /dev/null 2>&1; then
        compose_files="${compose_files}:$target_dir/docker-compose.gpu-nvidia.yml"
    fi

    if [ -z "$bind_host" ]; then
        if [ "${ODYSSEUS_DEPLOYMENT_MODE:-local}" = "lan-host" ]; then
            bind_host="0.0.0.0"
        else
            bind_host="127.0.0.1"
        fi
    fi

    if [ "$bind_host" = "localhost" ]; then
        bind_host="127.0.0.1"
    fi

    if [[ "$bind_host" == *:* ]]; then
        print_fail "ODYSSEUS_APP_BIND_HOST='${bind_host}' is not supported with current compose port syntax. Use an IPv4 address or hostname without ':'."
    fi

    export ODYSSEUS_APP_BIND_HOST="$bind_host"
    upsert_env_key "ODYSSEUS_DEPLOYMENT_MODE" "${ODYSSEUS_DEPLOYMENT_MODE:-local}" "$env_file"
    upsert_env_key "ODYSSEUS_APP_BIND_HOST" "$bind_host" "$env_file"
    upsert_env_key "APP_BIND" "$bind_host" "$env_file"
    upsert_env_key "COMPOSE_FILE" "$compose_files" "$env_file"
}

configure_gateway_endpoints_runtime() {
    local env_file="$1"
    local gateway_host

    if ! resolve_windows_ollama_host; then
        print_fail "Unable to resolve a reachable Windows host endpoint for Ollama. Candidates: ${ODYSSEUS_OLLAMA_CANDIDATES_ATTEMPTED:-none}. Probe results: ${ODYSSEUS_OLLAMA_CANDIDATE_FAILURES:-none}. Verify Windows Ollama binding/firewall or set ODYSSEUS_OLLAMA_HOST/ODYSSEUS_WINDOWS_HOST_OVERRIDE, then rerun."
        return 1
    fi

    gateway_host="$ODYSSEUS_WINDOWS_GATEWAY_IP"
    if [ -z "$gateway_host" ]; then
        print_fail "Resolved Windows host endpoint is empty after successful probe. This is unexpected; rerun and capture logs."
        return 1
    fi

    upsert_env_key "LLM_HOST" "$gateway_host" "$env_file"
    upsert_env_key "LLM_HOSTS" "$gateway_host" "$env_file"
    upsert_env_key "OLLAMA_BASE_URL" "http://${gateway_host}:11434/v1" "$env_file"
    upsert_env_key "EMBEDDING_URL" "http://${gateway_host}:11434/v1/embeddings" "$env_file"

    export ODYSSEUS_WINDOWS_GATEWAY_IP="$gateway_host"
}

get_port_7000_listeners() {
    if command -v ss > /dev/null 2>&1; then
        sudo ss -H -ltnp 'sport = :7000' 2>/dev/null || true
        return 0
    fi

    if command -v lsof > /dev/null 2>&1; then
        sudo lsof -nP -iTCP:7000 -sTCP:LISTEN 2>/dev/null || true
        return 0
    fi

    echo "Listener diagnostics unavailable (neither 'ss' nor 'lsof' found)."
    return 0
}

ensure_port_7000_available_for_compose() {
    local listeners
    listeners="$(get_port_7000_listeners)"

    if [ -z "$listeners" ]; then
        return 0
    fi

    # Allow an existing healthy Odysseus service for idempotent relaunches.
    if sudo docker compose "${COMPOSE_RUNTIME_ARGS[@]}" ps --services --filter status=running 2>/dev/null | grep -qx 'odysseus'; then
        echo "[INFO] Port 7000 is already bound by a running Odysseus service for this compose profile."
        return 0
    fi

    echo "[INFO] Port 7000 listener snapshot:"
    printf '%s\n' "$listeners"
    print_fail "Port 7000 is already in use by another process. Stop the conflicting listener and rerun. Helpful commands: 'sudo ss -ltnp \'sport = :7000\'' and 'sudo docker ps --format \"table {{.Names}}\\t{{.Ports}}\"'."
}

print_step "Refreshing sudo credentials for package management..."
echo "[INFO] If prompted, enter your Ubuntu password and press Enter (characters will not be shown)."
if ! sudo -v -p '[SUDO] Enter Ubuntu password for Odysseus bootstrap: '; then
    print_fail "Sudo authentication failed. Verify your Ubuntu password and rerun the launcher."
fi
print_ok "Sudo credential ticket is active."

print_step "Waiting for package manager locks to clear..."
wait_for_apt_unlock || print_fail "Timed out waiting for apt/dpkg lock files."

print_step "Checking Ubuntu package manager health..."
ensure_dpkg_consistent
print_ok "Package manager is healthy."

print_step "Updating Linux package indexes..."
run_apt_update && print_ok "Repositories updated."

print_step "Verifying system core utility dependencies..."
if run_with_progress "Installing core Linux utilities" sudo apt-get install -y -qq ca-certificates curl git gnupg lsb-release; then
    print_ok "Core utilities verified."
else
    print_fail "Failed to install required Linux utilities."
fi

print_step "Validating enterprise-compliant open-source Docker Engine..."
if ! command -v docker &> /dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    if ! run_with_progress "Refreshing package indexes for Docker" run_apt_update; then
        print_fail "Failed to refresh Docker package indexes."
    fi
    if ! run_with_progress "Installing Docker Engine packages" sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        print_fail "Failed to install Docker Engine packages."
    fi
    print_ok "Open-source Docker Engine deployed."
else
    print_ok "Docker Engine verified."
fi

print_step "Ensuring background Docker daemon service is active..."
if ensure_docker_running; then
    print_ok "Docker daemon activated."
else
    print_fail "Docker daemon could not be started. Verify Docker Desktop/Engine state and rerun."
fi

print_step "Aligning Linux user permissions for non-root Docker usage..."
ensure_docker_group_access

print_step "Validating graphics card passthrough configurations..."
if ! command -v nvidia-smi &> /dev/null; then
    print_ok "Host has no NVIDIA graphics pipelines. Proceeding with CPU-Fallback path."
else
    if ! command -v nvidia-ctk &> /dev/null; then
        gpu_setup_failed=0
        had_daemon_backup=0
        daemon_backup_file="/tmp/odysseus-daemon-json.backup"

        if sudo test -f /etc/docker/daemon.json; then
            sudo cp /etc/docker/daemon.json "$daemon_backup_file"
            had_daemon_backup=1
        fi

        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
        run_with_progress "Refreshing package indexes for NVIDIA toolkit" run_apt_update
        run_with_progress "Installing NVIDIA container toolkit" sudo apt-get install -y nvidia-container-toolkit -qq

        if ! sudo nvidia-ctk runtime configure --runtime=docker > /dev/null; then
            gpu_setup_failed=1
        fi

        if command -v systemctl > /dev/null 2>&1 && [ "$(ps -o comm= 1 2> /dev/null)" = "systemd" ]; then
            sudo systemctl restart docker > /dev/null 2>&1 || true
        elif command -v service > /dev/null 2>&1; then
            sudo service docker restart > /dev/null 2>&1 || true
        fi

        if ! ensure_docker_running; then
            gpu_setup_failed=1
        fi

        if [ "$gpu_setup_failed" -eq 1 ]; then
            echo "[WARN] NVIDIA runtime setup failed; restoring Docker config and continuing in CPU mode."
            if [ "$had_daemon_backup" -eq 1 ]; then
                sudo cp "$daemon_backup_file" /etc/docker/daemon.json
            else
                sudo rm -f /etc/docker/daemon.json
            fi

            if command -v systemctl > /dev/null 2>&1 && [ "$(ps -o comm= 1 2> /dev/null)" = "systemd" ]; then
                sudo systemctl restart docker > /dev/null 2>&1 || true
            elif command -v service > /dev/null 2>&1; then
                sudo service docker restart > /dev/null 2>&1 || true
            fi

            ensure_docker_running || print_fail "Docker daemon failed after NVIDIA rollback. Check /etc/docker/daemon.json and rerun."
            print_ok "Continuing with CPU-Fallback path."
        else
            print_ok "NVIDIA Container Toolkit linked successfully."
        fi

        rm -f "$daemon_backup_file" || true
    else
        print_ok "NVIDIA runtime hooks verified."
    fi
fi

print_step "Synchronizing the Odysseus project source workspace..."
TARGET_DIR="$TARGET_DIR_DEFAULT"
RUNTIME_DIR="$RUNTIME_DIR_DEFAULT"
RUNTIME_ENV="$RUNTIME_ENV_DEFAULT"
FIRST_BOOT=false
ODYSSEUS_DEPLOYMENT_MODE=${ODYSSEUS_DEPLOYMENT_MODE:-}
ODYSSEUS_HOST_MODE=${ODYSSEUS_HOST_MODE:-0}
ODYSSEUS_REPO_REF=${ODYSSEUS_REPO_REF:-dev}
ODYSSEUS_REPO_SYNC_MODE=${ODYSSEUS_REPO_SYNC_MODE:-managed-clean}
ODYSSEUS_REBUILD=${ODYSSEUS_REBUILD:-1}

if [ -z "$ODYSSEUS_DEPLOYMENT_MODE" ]; then
    if [ "$ODYSSEUS_HOST_MODE" = "1" ]; then
        ODYSSEUS_DEPLOYMENT_MODE="lan-host"
    else
        ODYSSEUS_DEPLOYMENT_MODE="local"
    fi
fi

case "$ODYSSEUS_DEPLOYMENT_MODE" in
    local|lan-host)
        ;;
    *)
        echo "[WARN] Unknown ODYSSEUS_DEPLOYMENT_MODE='${ODYSSEUS_DEPLOYMENT_MODE}'. Falling back from ODYSSEUS_HOST_MODE."
        if [ "$ODYSSEUS_HOST_MODE" = "1" ]; then
            ODYSSEUS_DEPLOYMENT_MODE="lan-host"
        else
            ODYSSEUS_DEPLOYMENT_MODE="local"
        fi
        ;;
esac

if [ "$ODYSSEUS_DEPLOYMENT_MODE" = "lan-host" ]; then
    ODYSSEUS_HOST_MODE=1
else
    ODYSSEUS_HOST_MODE=0
fi

export ODYSSEUS_DEPLOYMENT_MODE
export ODYSSEUS_HOST_MODE

case "$ODYSSEUS_REPO_SYNC_MODE" in
    managed-clean|managed-ff|unmanaged)
        ;;
    *)
        echo "[WARN] Unknown ODYSSEUS_REPO_SYNC_MODE='${ODYSSEUS_REPO_SYNC_MODE}'. Falling back to managed-clean."
        ODYSSEUS_REPO_SYNC_MODE="managed-clean"
        ;;
esac

if [ ! -d "$TARGET_DIR" ]; then
    FIRST_BOOT=true
    if run_with_progress "Cloning Odysseus branch ${ODYSSEUS_REPO_REF}" git clone --branch "$ODYSSEUS_REPO_REF" https://github.com/pewdiepie-archdaemon/odysseus.git "$TARGET_DIR"; then
        cd "$TARGET_DIR"
    else
        print_fail "Failed to clone Odysseus branch '$ODYSSEUS_REPO_REF'. Verify the branch exists and rerun."
    fi
    print_ok "Odysseus workspace initialized."
else
    cd "$TARGET_DIR"

    if [ "$ODYSSEUS_REPO_SYNC_MODE" = "unmanaged" ]; then
        echo "[INFO] Repo sync mode is unmanaged; keeping existing ~/odysseus state without fetch/pull."
    else
        echo "[INFO] Fetching latest metadata for origin/${ODYSSEUS_REPO_REF}..."
        run_git_command "Fetch from origin/${ODYSSEUS_REPO_REF}" fetch origin "$ODYSSEUS_REPO_REF"

        if [ "$ODYSSEUS_REPO_SYNC_MODE" = "managed-clean" ]; then
            echo "[INFO] Repo sync mode is managed-clean; resetting ~/odysseus to origin/${ODYSSEUS_REPO_REF}."
            run_git_command "Checkout branch ${ODYSSEUS_REPO_REF} from origin" checkout -B "$ODYSSEUS_REPO_REF" "origin/$ODYSSEUS_REPO_REF"
            run_git_command "Hard reset branch ${ODYSSEUS_REPO_REF} to origin" reset --hard "origin/$ODYSSEUS_REPO_REF"
            run_git_command "Clean untracked files from ~/odysseus" clean -fd
            print_ok "Odysseus workspace force-synced to origin/${ODYSSEUS_REPO_REF}."
        else
            if ! git diff --quiet || ! git diff --cached --quiet; then
                local_changes=$(git status --short | head -n 20)
                print_fail "Odysseus workspace has local changes in ~/odysseus. Commit/stash/discard local changes before relaunching so branch sync can run safely. Current changes: ${local_changes}"
            fi

            run_git_command "Checkout branch ${ODYSSEUS_REPO_REF}" checkout "$ODYSSEUS_REPO_REF"

            echo "[INFO] Fast-forwarding local workspace from origin/${ODYSSEUS_REPO_REF}..."
            run_git_command "Fast-forward pull from origin/${ODYSSEUS_REPO_REF}" pull --ff-only origin "$ODYSSEUS_REPO_REF"
            print_ok "Odysseus workspace updated."
        fi
    fi
fi

mkdir -p "$RUNTIME_DIR"
if [ ! -f "$RUNTIME_ENV" ]; then
    if [ -f "$TARGET_DIR/.env.example" ]; then
        cp "$TARGET_DIR/.env.example" "$RUNTIME_ENV"
        print_ok "Runtime environment initialized at $RUNTIME_ENV from .env.example."
    else
        : > "$RUNTIME_ENV"
        print_ok "Runtime environment initialized at $RUNTIME_ENV."
    fi
fi

print_step "Applying host connectivity and compose profile settings..."
configure_compose_files_runtime "$RUNTIME_ENV" "$TARGET_DIR"
configure_gateway_endpoints_runtime "$RUNTIME_ENV"
print_ok "Environment endpoints and compose profiles aligned."
echo "[INFO] Effective deployment mode: ${ODYSSEUS_DEPLOYMENT_MODE}"
echo "[INFO] Effective Odysseus app bind host: ${ODYSSEUS_APP_BIND_HOST}"

print_step "Auditing Windows-hosted Ollama reachability from WSL..."
audit_ollama_gateway "$ODYSSEUS_WINDOWS_GATEWAY_IP"

print_step "Deploying application containers..."
mapfile -t COMPOSE_RUNTIME_ARGS < <(compose_args_from_runtime "$RUNTIME_ENV" "$TARGET_DIR")

print_step "Validating Docker compose runtime configuration..."
compose_config_log=$(mktemp /tmp/odysseus-compose-config.XXXXXX.log)
if sudo docker compose "${COMPOSE_RUNTIME_ARGS[@]}" config -q >"$compose_config_log" 2>&1; then
    rm -f "$compose_config_log"
    print_ok "Compose configuration is valid."
else
    echo "[INFO] docker compose config validation output:"
    cat "$compose_config_log" || true
    print_fail "Compose configuration validation failed. Fix the compose/env configuration shown above and rerun."
fi

print_step "Preflight-checking local port 7000 availability before container startup..."
ensure_port_7000_available_for_compose
print_ok "Port 7000 preflight check passed."

if [ "$ODYSSEUS_REBUILD" = "1" ]; then
    if run_with_progress "Building and starting application containers" sudo docker compose "${COMPOSE_RUNTIME_ARGS[@]}" up -d --build; then
        print_ok "Containers rebuilt and active in background."
    else
        compose_state=$(sudo docker compose "${COMPOSE_RUNTIME_ARGS[@]}" ps 2>&1 || true)
        print_fail "docker compose up --build failed. Review command log output above and compose state: ${compose_state}"
    fi
else
    if run_with_progress "Starting application containers" sudo docker compose "${COMPOSE_RUNTIME_ARGS[@]}" up -d; then
        print_ok "Containers active in background (rebuild skipped)."
    else
        compose_state=$(sudo docker compose "${COMPOSE_RUNTIME_ARGS[@]}" ps 2>&1 || true)
        print_fail "docker compose up -d failed. Review command log output above and compose state: ${compose_state}"
    fi
fi

print_step "Polling local network port 7000 to verify runtime status..."
TIMEOUT=90
COUNT=0
until curl -sS --connect-timeout 2 --max-time 4 -f http://127.0.0.1:7000 > /dev/null; do
    COUNT=$((COUNT+2))
    printf '.'
    if [ $((COUNT % 10)) -eq 0 ]; then
        printf " %ss/%ss" "$COUNT" "$TIMEOUT"
    fi
    if [ $COUNT -ge $TIMEOUT ]; then
        echo ""
        print_fail "Network handshake timeout after ${TIMEOUT}s. Check Odysseus container logs from ~/odysseus using your runtime compose profile."
    fi
    sleep 2
done
echo ""
print_ok "Application socket online after ${COUNT}s."
if [ "$ODYSSEUS_APP_BIND_HOST" != "127.0.0.1" ]; then
    echo "[INFO] Odysseus is published for client access on ${ODYSSEUS_APP_BIND_HOST}:7000 (subject to Windows firewall/network rules)."
fi

if [ "$FIRST_BOOT" = true ]; then
    password_log="$HOME/.odysseus-initial-admin-password.txt"
    odysseus_logs="$(sudo docker compose "${COMPOSE_RUNTIME_ARGS[@]}" logs odysseus)"
    if ! printf '%s\n' "$odysseus_logs" | grep -i "password" > "$password_log"; then
        {
            echo "No explicit password line was found in odysseus logs. Recent startup logs are included below:"
            echo
            printf '%s\n' "$odysseus_logs" | tail -n 200
        } > "$password_log"
    fi
    chmod 600 "$password_log" || true

    echo -e "\n\e[1;33m===================================================="
    echo "FIRST TIME INITIALIZATION COMPLETED"
    echo "===================================================="
    echo "Initial credential output was saved to: $password_log"
    echo "The extracted password line is shown below:"
    echo "----------------------------------------------------"
    cat "$password_log"
    echo "----------------------------------------------------"
    echo "If you want to re-open it later:"
    echo "  cat \"$password_log\""
    echo "Copy that password. You will need it to log in now!"
    echo -e "====================================================\e[0m\n"
    read -p "Press [Enter] once you have copied your password to launch Edge..."
fi

