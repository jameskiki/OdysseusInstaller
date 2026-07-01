#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive

print_step() { echo -e "\n\e[1;36m[INTENT] $1\e[0m"; }
print_ok()   { echo -e "\e[1;32m[SUCCESS] $1\e[0m"; }
print_fail() { echo -e "\e[1;31m[FAILED] $1\e[0m"; exit 1; }

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

print_step "Updating Linux package indexes..."
run_apt_update && print_ok "Repositories updated."

print_step "Verifying system core utility dependencies..."
sudo apt-get install -y -qq ca-certificates curl git gnupg lsb-release && print_ok "Core utilities verified."

print_step "Validating enterprise-compliant open-source Docker Engine..."
if ! command -v docker &> /dev/null; then
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -y -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    print_ok "Open-source Docker Engine deployed."
else
    print_ok "Docker Engine verified."
fi

print_step "Ensuring background Docker daemon service is active..."
ensure_docker_running && print_ok "Docker daemon activated."

print_step "Validating graphics card passthrough configurations..."
if ! command -v nvidia-smi &> /dev/null; then
    print_ok "Host has no NVIDIA graphics pipelines. Proceeding with CPU-Fallback path."
else
    if ! command -v nvidia-ctk &> /dev/null; then
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
        sudo apt-get update -y -qq && sudo apt-get install -y nvidia-container-toolkit -qq
        sudo nvidia-ctk runtime configure --runtime=docker > /dev/null
        if command -v systemctl > /dev/null 2>&1 && [ "$(ps -o comm= 1 2> /dev/null)" = "systemd" ]; then
            sudo systemctl restart docker > /dev/null 2>&1 || true
        elif command -v service > /dev/null 2>&1; then
            sudo service docker restart > /dev/null 2>&1 || true
        fi
        ensure_docker_running
        print_ok "NVIDIA Container Toolkit linked successfully."
    else
        print_ok "NVIDIA runtime hooks verified."
    fi
fi

print_step "Synchronizing the Odysseus project source workspace..."
TARGET_DIR="$HOME/odysseus"
FIRST_BOOT=false
ODYSSEUS_HOST_MODE=${ODYSSEUS_HOST_MODE:-0}
ODYSSEUS_REPO_REF=${ODYSSEUS_REPO_REF:-main}

if [ ! -d "$TARGET_DIR" ]; then
    FIRST_BOOT=true
    git clone --branch "$ODYSSEUS_REPO_REF" --single-branch https://github.com/pewdiepie-archdaemon/odysseus.git "$TARGET_DIR" && cd "$TARGET_DIR"
    cp .env.example .env
    print_ok "Odysseus workspace initialized."
else
    cd "$TARGET_DIR"
    git fetch origin "$ODYSSEUS_REPO_REF"
    git checkout "$ODYSSEUS_REPO_REF"
    git pull --ff-only origin "$ODYSSEUS_REPO_REF" && print_ok "Odysseus workspace updated."
    if [ ! -f .env ]; then
        cp .env.example .env
        print_ok "Environment file created from the current template."
    fi
fi

print_step "Applying host connectivity and compose profile settings..."
configure_compose_files ".env"
configure_gateway_endpoints ".env"
print_ok "Environment endpoints and compose profiles aligned."

print_step "Checking reachability of Windows-hosted Ollama from WSL..."
wait_for_ollama_gateway "$ODYSSEUS_WINDOWS_GATEWAY_IP" || print_fail "Cannot reach Ollama at http://${ODYSSEUS_WINDOWS_GATEWAY_IP}:11434 from WSL. Ensure Ollama is running on Windows ('ollama serve') and local firewall policy allows port 11434."
print_ok "Ollama endpoint reachable from WSL."

print_step "Deploying application containers..."
sudo docker compose up -d --build && print_ok "Containers active in background."

print_step "Polling local network port 7000 to verify runtime status..."
TIMEOUT=45; COUNT=0
until curl -s -f http://127.0.0.1:7000 > /dev/null; do
    printf '.'; sleep 2; COUNT=$((COUNT+2))
    if [ $COUNT -ge $TIMEOUT ]; then echo ""; print_fail "Network handshake timeout."; fi
done
echo ""; print_ok "Application socket online."

if [ "$FIRST_BOOT" = true ]; then
    password_log="$HOME/.odysseus-initial-admin-password.txt"
    sudo docker compose logs odysseus | grep -i "password" > "$password_log" || sudo docker compose logs odysseus > "$password_log"
    chmod 600 "$password_log" || true

    echo -e "\n\e[1;33m===================================================="
    echo "FIRST TIME INITIALIZATION COMPLETED"
    echo "===================================================="
    echo "Initial credential output was saved to: $password_log"
    echo "Review and store it securely before allowing additional users or remote clients to access this host."
    echo -e "====================================================\e[0m\n"
fi

trap - EXIT
