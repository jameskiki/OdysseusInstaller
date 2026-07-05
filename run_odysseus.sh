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
    # Add Docker's official apt repository
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    sudo apt-get update -y -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
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

if [ ! -d "$TARGET_DIR" ]; then
    FIRST_BOOT=true
    git clone https://github.com/pewdiepie-archdaemon/odysseus.git "$TARGET_DIR" && cd "$TARGET_DIR"
    # Set GPU profile mappings inside .env if NVIDIA core layer is present
    if command -v nvidia-smi &> /dev/null; then
        cp .env.example .env
        printf '\nCOMPOSE_FILE=docker-compose.yml:docker-compose.gpu-nvidia.yml\n' >> .env
    else
        cp .env.example .env
    fi
    # If host mode, bind to all interfaces instead of localhost only
    if [ "$ODYSSEUS_HOST_MODE" = "1" ]; then
        sed -i 's/127\.0\.0\.1/0.0.0.0/g' docker-compose.yml
        print_ok "Odysseus workspace initialized (host mode: bound to 0.0.0.0)."
    else
        print_ok "Odysseus workspace initialized."
    fi
else
    cd "$TARGET_DIR"
    git pull --ff-only && print_ok "Odysseus workspace updated."
    if [ ! -f .env ]; then
        if command -v nvidia-smi &> /dev/null; then
            cp .env.example .env
            printf '\nCOMPOSE_FILE=docker-compose.yml:docker-compose.gpu-nvidia.yml\n' >> .env
        else
            cp .env.example .env
        fi
        print_ok "Environment file created from the current template."
    fi
    # If host mode and not already bound to 0.0.0.0, update it
    if [ "$ODYSSEUS_HOST_MODE" = "1" ] && ! grep -q '0\.0\.0\.0:7000' docker-compose.yml 2>/dev/null; then
        sed -i 's/127\.0\.0\.1/0.0.0.0/g' docker-compose.yml
    fi
fi

print_step "Deploying application containers..."
sudo docker compose up -d --build && print_ok "Containers active in background."

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

# If this is the first deployment, extract the randomly generated administrative password
if [ "$FIRST_BOOT" = true ]; then
    echo -e "\n\e[1;33m===================================================="
    echo "FIRST TIME INITIALIZATION COMPLETED"
    echo "===================================================="
    echo "Your unique generated admin password should appear in the lines below:"
    echo "----------------------------------------------------"
    sudo docker compose logs odysseus | grep -i "password" || sudo docker compose logs
    echo "----------------------------------------------------"
    echo "If the password scrolls by too quickly, rerun:"
    echo "  sudo docker compose logs odysseus | grep -i password"
    echo "Copy that password. You will need it to log in now!"
    echo -e "====================================================\e[0m\n"
    read -p "Press [Enter] once you have copied your password to launch Edge..."
fi

trap - EXIT
