#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive

print_step() { echo -e "\n\e[1;36m[INTENT] $1\e[0m"; }
print_ok()   { echo -e "\e[1;32m[SUCCESS] $1\e[0m"; }
print_fail() { echo -e "\e[1;31m[FAILED] $1\e[0m"; exit 1; }

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

    while kill -0 "$pid" > /dev/null 2>&1; do
        printf '\r[WORKING] %s %s (%ss)' "$label" "${frames:frame:1}" "$elapsed"
        sleep 1
        frame=$(((frame + 1) % 4))
        elapsed=$((elapsed + 1))
    done

    wait "$pid"
    local exit_code=$?
    printf '\r%-100s\r' ''

    if [ "$exit_code" -ne 0 ]; then
        echo "[INFO] Last installer output:"
        tail -n 20 "$log_file" || true
        rm -f "$log_file"
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
    if ! run_with_progress "Repairing interrupted dpkg state" sudo dpkg --configure -a; then
        echo "$audit_output"
        print_fail "dpkg repair failed. Run 'sudo dpkg --configure -a' inside Ubuntu, then rerun Odysseus."
    fi

    if [ -n "$(sudo dpkg --audit 2>&1 || true)" ]; then
        print_fail "dpkg still reports unfinished package configuration after repair."
    fi
}

audit_ollama_gateway() {
    local gateway_ip="$1"
    local url="http://${gateway_ip}:11434/api/tags"
    local curl_output
    local curl_exit

    echo "[INFO] Auditing Ollama reachability at ${url}"
    set +e
    curl_output=$(curl -sS --connect-timeout 2 --max-time 4 -w 'HTTP_STATUS:%{http_code}' "$url" 2>&1)
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

configure_compose_files() {
    local env_file="$1"
    local compose_files="docker-compose.yml"

    if command -v nvidia-smi > /dev/null 2>&1; then
        compose_files="${compose_files}:docker-compose.gpu-nvidia.yml"
    fi

    if [ "${ODYSSEUS_HOST_MODE:-0}" = "1" ]; then
        cat > docker-compose.host-mode.override.yml <<'HOSTEOF'
services:
  odysseus:
    ports:
      - "0.0.0.0:7000:7000"
HOSTEOF
        compose_files="${compose_files}:docker-compose.host-mode.override.yml"
    fi

    upsert_env_key "COMPOSE_FILE" "$compose_files" "$env_file"
}

configure_gateway_endpoints() {
    local env_file="$1"
    local gateway_ip

    gateway_ip=$(awk '/^nameserver[[:space:]]+/ {print $2; exit}' /etc/resolv.conf)
    if [ -z "$gateway_ip" ]; then
        print_fail "Unable to detect Windows host gateway IP from /etc/resolv.conf. Verify WSL networking is active and rerun."
        return 1
    fi

    upsert_env_key "LLM_HOST" "$gateway_ip" "$env_file"
    upsert_env_key "LLM_HOSTS" "$gateway_ip" "$env_file"
    upsert_env_key "OLLAMA_BASE_URL" "http://${gateway_ip}:11434/v1" "$env_file"
    upsert_env_key "EMBEDDING_URL" "http://${gateway_ip}:11434/v1/embeddings" "$env_file"

    export ODYSSEUS_WINDOWS_GATEWAY_IP="$gateway_ip"
}

wait_for_ollama_gateway() {
    local gateway_ip="$1"
    # Poll for ~50s (25 attempts * 2s) to allow Ollama startup after Windows session changes.
    for _ in $(seq 1 25); do
        if curl -s -f "http://${gateway_ip}:11434/api/tags" > /dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

trap 'if [ $? -ne 0 ]; then print_fail "Pipeline broken on the last task."; fi' EXIT

print_step "Refreshing sudo credentials for package management..."
sudo -v || print_fail "Sudo authentication failed."

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

    if ! run_with_progress "Refreshing package indexes for Docker" sudo apt-get update -y -qq; then
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
        run_with_progress "Refreshing package indexes for NVIDIA toolkit" sudo apt-get update -y -qq
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
TARGET_DIR="$HOME/odysseus"
FIRST_BOOT=false
ODYSSEUS_HOST_MODE=${ODYSSEUS_HOST_MODE:-0}
ODYSSEUS_REPO_REF=${ODYSSEUS_REPO_REF:-main}
ODYSSEUS_REBUILD=${ODYSSEUS_REBUILD:-1}

if [ ! -d "$TARGET_DIR" ]; then
    FIRST_BOOT=true
    if git clone --branch "$ODYSSEUS_REPO_REF" https://github.com/pewdiepie-archdaemon/odysseus.git "$TARGET_DIR"; then
        cd "$TARGET_DIR"
    else
        print_fail "Failed to clone Odysseus branch '$ODYSSEUS_REPO_REF'. Verify the branch exists and rerun."
    fi
    cp .env.example .env
    print_ok "Odysseus workspace initialized."
else
    cd "$TARGET_DIR"
    git fetch origin "$ODYSSEUS_REPO_REF"
    git checkout "$ODYSSEUS_REPO_REF"
    if git pull --ff-only origin "$ODYSSEUS_REPO_REF"; then
        print_ok "Odysseus workspace updated."
    else
        print_fail "Odysseus workspace update failed because local checkout diverged from origin/$ODYSSEUS_REPO_REF. Resolve git state in ~/odysseus and rerun."
    fi
    if [ ! -f .env ]; then
        cp .env.example .env
        print_ok "Environment file created from the current template."
    fi
fi

print_step "Applying host connectivity and compose profile settings..."
configure_compose_files ".env"
configure_gateway_endpoints ".env"
print_ok "Environment endpoints and compose profiles aligned."

print_step "Auditing Windows-hosted Ollama reachability from WSL..."
audit_ollama_gateway "$ODYSSEUS_WINDOWS_GATEWAY_IP"

print_step "Deploying application containers..."
if [ "$ODYSSEUS_REBUILD" = "1" ]; then
    run_with_progress "Building and starting application containers" sudo docker compose up -d --build && print_ok "Containers rebuilt and active in background."
else
    run_with_progress "Starting application containers" sudo docker compose up -d && print_ok "Containers active in background (rebuild skipped)."
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
        print_fail "Network handshake timeout after ${TIMEOUT}s. Check the Odysseus container logs with: sudo docker compose logs -f odysseus"
    fi
    sleep 2
done
echo ""
print_ok "Application socket online after ${COUNT}s."

if [ "$FIRST_BOOT" = true ]; then
    password_log="$HOME/.odysseus-initial-admin-password.txt"
    odysseus_logs="$(sudo docker compose logs odysseus)"
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

trap - EXIT
