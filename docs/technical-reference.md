# Technical Reference

This document describes the complete installer pipeline — what each component does, how the pieces connect, and why the architecture is designed the way it is.

---

## Repository Structure

| File | Role |
|---|---|
| `installer.iss` | Inno Setup script — builds the Windows `.exe` installer |
| `Launch-Odysseus.ps1` | Windows orchestration layer — runs after install to set up WSL, Ollama, and wire up Docker networking |
| `run_odysseus.sh` | Linux bootstrap — runs inside WSL Ubuntu to install Docker, pull the Odysseus project, and start containers |

---

## 1. Inno Setup Wizard (`installer.iss`)

### Wizard flow

The installer presents three meaningful screens:

1. **Licence agreement** — with clickable links to upstream open-source licences (Apache 2.0, Ubuntu, Git GPL) added via `TNewLinkLabel` below the standard radio buttons.
2. **Deployment type** — a custom `TWizardPage` with:
   - `LocalInstallRadio` — run a local instance
   - `HostCheckBox` — sub-option: also act as a host for office network sharing (only enabled when local is selected)
   - `RemoteInstallRadio` — connect to a colleague's shared instance
3. **Host IP input** — a `TInputQueryWizardPage` that collects the IPv4 address of the host machine; skipped entirely (`ShouldSkipPage`) when local mode is selected.

### Key Pascal code functions

| Function | Purpose |
|---|---|
| `IsLocalInstallation` | Returns true when `LocalInstallRadio.Checked`; gates which files are installed and which shortcuts are created |
| `IsRemoteInstallation` | Returns true when `RemoteInstallRadio.Checked` |
| `IsHostSelected` | Returns true when local is selected *and* `HostCheckBox.Checked`; used to gate the firewall rule and the sentinel file |
| `IsNvidiaGpuPresent` | Walks `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968...}` registry subkeys, reading `DriverDesc` and checking for the string `NVIDIA`; triggers a confirmation dialog if no NVIDIA GPU is found during local install |
| `GetRemoteIP` | Returns the trimmed IP value from `IPPage.Values[0]`, defaulting to `127.0.0.1` if blank; interpolated into the remote shortcut's `explorer.exe` target URL |
| `CurStepChanged` (ssPostInstall) | Writes the `ODYSSEUS_HOST_MODE` sentinel file to `{app}` if host mode is selected; then runs a PowerShell one-liner via `Exec` to check WSL and Ubuntu readiness, showing an appropriate guidance dialog for each failure case (exit 10 = no WSL, exit 11 = no Ubuntu) |

### Files and shortcuts installed

- `Launch-Odysseus.ps1` and `run_odysseus.sh` are copied to `{app}` only when `IsLocalInstallation` is true.
- A **"Launch Odysseus (Local)"** desktop shortcut is created for local installs. It runs `powershell.exe -ExecutionPolicy Bypass` on `Launch-Odysseus.ps1` with `-NoExit` so the terminal stays visible.
- A **"Connect to Shared Odysseus"** desktop shortcut is created for remote installs. It opens `explorer.exe http://<host-ip>:7000` directly.

### Firewall rule

The `[Run]` section calls `netsh.exe advfirewall firewall add rule` to allow inbound TCP on port 7000 for the `private` and `domain` profiles. This only executes when `IsHostSelected` is true, and is what makes the Odysseus web interface reachable by other machines on the local network.

---

## 2. `Launch-Odysseus.ps1` — Windows Orchestration Layer

This script is the bridge between the Windows environment and the Linux Docker stack. It runs in a visible PowerShell window (so the user can see progress) via the desktop shortcut.

### Step-by-step

**1. WSL availability check**
`Get-Command wsl.exe` — if absent, throws a clear message instructing the user to run `wsl --install -d Ubuntu` in an elevated terminal.

**2. Ubuntu distribution check**
`wsl.exe -l -q` lists installed distributions. The script trims whitespace (WSL output contains null bytes / carriage returns) and checks for `Ubuntu` by exact name. A missing Ubuntu triggers a message to complete the first-launch Linux user setup before retrying.

**3. Ollama installation and endpoint binding (`Ensure-OllamaAvailable` + `Ensure-OllamaEndpoint`)**

Ollama must run on the Windows host (not inside Docker) so it can access the physical GPU through native Windows drivers. The script:
- Checks for `ollama.exe` via `Get-Command`; if absent, prompts to install via `winget install --id Ollama.Ollama`
- Sets `OLLAMA_HOST=0.0.0.0:11434` as a persistent User environment variable and in the current session
- Checks `Get-NetTCPConnection -LocalPort 11434` to detect whether Ollama is already listening on all interfaces (`::` or `0.0.0.0`) or only on loopback (`127.0.0.1`)
- If loopback-only: stops the process and restarts with `Start-Process ollama serve -WindowStyle Hidden`
- Polls `http://localhost:11434/api/tags` up to 20 times (500 ms apart) to confirm Ollama is ready

**4. `.env` patching inside WSL (`Configure-OdysseusModelEndpoints`)**

The Docker containers inside WSL need to reach Ollama on the Windows host. The WSL2-to-Windows bridge hostname is `host.docker.internal`. The script runs a `bash -lc` one-liner via `wsl.exe` that uses `grep`/`sed` to upsert these keys in `~/odysseus/.env`:

| Key | Value set |
|---|---|
| `LLM_HOST` | `host.docker.internal` |
| `LLM_HOSTS` | `host.docker.internal` |
| `OLLAMA_BASE_URL` | `http://host.docker.internal:11434/v1` |
| `EMBEDDING_URL` | `http://host.docker.internal:11434/v1/embeddings` |

This step is idempotent — it uses `sed -i` to replace existing values and `echo >>` to append missing ones.

**5. Bootstrap script staging**
`run_odysseus.sh` exists on the Windows filesystem. The script uses `wsl.exe wslpath -a` to translate the Windows path to its Linux equivalent, then runs:
```
tr -d '\r' < '<linux-path>' > ~/run_odysseus.sh && chmod +x ~/run_odysseus.sh
```
The `tr -d '\r'` strips Windows line endings (CRLF → LF) before execution.

**6. Linux bootstrap execution**
```
wsl.exe -d Ubuntu -- bash -lc '~/run_odysseus.sh'
```
`bash -lc` loads the full login environment (including `PATH` entries from `/etc/profile.d/`), which ensures Docker and other tools installed by the script are immediately available.

**7. Browser launch**
`Start-Process 'http://localhost:7000'` — opens in the default browser once the bootstrap reports success.

---

## 3. `run_odysseus.sh` — Linux Bootstrap

Runs inside WSL Ubuntu. Uses `set -e` so any unhandled error aborts the script and triggers the `EXIT` trap, which prints a failure message.

### apt lock polling (`wait_for_apt_unlock`)

Cloud VMs and freshly-provisioned Ubuntu instances frequently have background `apt` processes (e.g., `unattended-upgrades`) holding the dpkg/apt lock files. The function polls all four lock paths every 2 seconds for up to 2 minutes before giving up. This prevents spurious installation failures during first boot.

### Docker Engine installation

Checks `command -v docker`. If absent:
1. Installs `ca-certificates curl git gnupg lsb-release` (core utilities needed for the key import).
2. Adds Docker's official GPG key to `/etc/apt/keyrings/docker.gpg`.
3. Writes the Docker apt repository to `/etc/apt/sources.list.d/docker.list` using `lsb_release -cs` to pin to the current Ubuntu codename.
4. Installs `docker-ce docker-ce-cli containerd.io docker-compose-plugin`.

### Docker daemon management (`ensure_docker_running`)

Tries three strategies in order:
1. `systemctl start docker` if systemd is PID 1 (standard Ubuntu with systemd).
2. `service docker start` for SysV-style init.
3. Direct `nohup dockerd &` as a last resort (non-systemd containers or CI environments).

Polls `docker info` up to 20 times (2 s apart) after each attempt.

### NVIDIA Container Toolkit path

Detects `nvidia-smi` to confirm a CUDA-capable GPU is present on the host. If found but `nvidia-ctk` is not yet installed:
1. Imports the NVIDIA container toolkit GPG key.
2. Adds the toolkit apt repository.
3. Installs `nvidia-container-toolkit`.
4. Runs `nvidia-ctk runtime configure --runtime=docker` to register the NVIDIA OCI runtime with Docker.
5. Restarts the Docker daemon.

### Odysseus project sync

- **First run** (`~/odysseus` does not exist): `git clone https://github.com/pewdiepie-archdaemon/odysseus.git ~/odysseus`, copies `.env.example` → `.env`, appends `COMPOSE_FILE=docker-compose.yml:docker-compose.gpu-nvidia.yml` if NVIDIA is present, rewrites `127.0.0.1 → 0.0.0.0` in `docker-compose.yml` if `ODYSSEUS_HOST_MODE=1`.
- **Subsequent runs** (`~/odysseus` exists): `git pull --ff-only` to update, creates `.env` from template if missing, applies host mode binding if needed.

### Container startup and health check

`docker compose up -d --build` builds any changed images and starts all services in the background.

The script then polls `http://127.0.0.1:7000` with `curl -s -f` every 2 seconds for up to 45 seconds, printing dots to show progress. A timeout triggers `print_fail`.

### First-boot password extraction

When `FIRST_BOOT=true`, the script runs:
```bash
sudo docker compose logs odysseus | grep -i "password"
```
and prints the result in a highlighted box. The user must press Enter to continue; the `read -p` acts as a deliberate pause so the password is visible before the browser opens.

---

## Why This Architecture

### Ollama on the Windows host, not in Docker

WSL2 Docker containers cannot pass through to the Windows GPU directly via the standard Linux NVIDIA Container Toolkit path — that toolkit works for native Linux and WSL2 bare processes, but the Docker-inside-WSL2 context requires Ollama to run as a native Windows process that has direct driver access. The `host.docker.internal` hostname is how Docker containers reach back to the Windows host over the internal WSL2 virtual network, making this the only reliable bridge for GPU-accelerated model inference in this deployment topology.

### Host mode: `0.0.0.0` binding + firewall rule

By default, `docker-compose.yml` binds port 7000 to `127.0.0.1`, meaning it is only reachable from the local machine. When `ODYSSEUS_HOST_MODE=1`, `sed` rewrites every `127.0.0.1` binding to `0.0.0.0` in `docker-compose.yml`, exposing the port on all network interfaces. The Inno Setup `[Run]` firewall rule is the Windows-side complement — without it, the Windows Firewall blocks inbound connections on port 7000 even though Docker is now listening on all interfaces.

### `COMPOSE_FILE` override for GPU compose profile

Docker Compose supports layered overrides via the `COMPOSE_FILE` environment variable. Setting it to `docker-compose.yml:docker-compose.gpu-nvidia.yml` merges the GPU-specific service definitions (NVIDIA runtime, device reservations) on top of the base configuration. Without this override, the NVIDIA runtime is not passed into the containers, and even though Ollama on the host has GPU access, the Odysseus containers themselves cannot use the GPU for any GPU-accelerated work they do internally. The `.env` file is the right place to set this because `docker compose` automatically reads it before resolving `COMPOSE_FILE`.
