# Technical Reference

This document describes the current installer pipeline and runtime behavior for this repository.

---

## Repository Structure

| File | Role |
|---|---|
| `installer/installer.iss` | Inno Setup script that builds the Windows installer and defines wizard logic |
| `scripts/windows/Launch-Odysseus.ps1` | Windows launcher/orchestration script |
| `scripts/wsl/run_odysseus.sh` | Linux bootstrap script executed in WSL Ubuntu |
| `scripts/windows/Audit-Odysseus.ps1` | Read-only health audit script for runtime diagnostics |

---

## 1. Inno Setup Wizard (`installer/installer.iss`)

### Wizard flow

The installer has five meaningful pages:

1. Licence agreement.
2. Deployment type (local vs remote, with optional host mode).
3. Odysseus version selection (`RepoRefPage`).
4. Container rebuild preference (`RebuildModePage`).
5. Host IP input (`IPPage`) for remote mode.

`ShouldSkipPage` conditionally skips pages depending on selected deployment mode:
- Remote install skips repo ref and rebuild pages.
- Local install skips remote host-IP page.

### Key functions

| Function | Purpose |
|---|---|
| `IsLocalInstallation` | True when local mode is selected |
| `IsRemoteInstallation` | True when remote mode is selected |
| `IsHostSelected` | True when local mode + host checkbox are selected |
| `GetSelectedRebuildMode` | Returns `ask`, `always`, or `never` |
| `GetRemoteIP` | Returns trimmed remote host IP, defaulting to `127.0.0.1` |
| `NextButtonClick` | Validates GPU warning path, remote IP, and repo ref inputs |
| `CurStepChanged` (`ssPostInstall`) | Writes installer sentinel files and performs WSL/Ubuntu readiness checks |

### Installer outputs and shortcuts

For local installs, the setup copies:
- `Launch-Odysseus.ps1`
- `run_odysseus.sh`
- `Audit-Odysseus.ps1`

Shortcuts created:
- `Launch Odysseus (Local)`
- `Odysseus Health Audit` (start menu)
- `Odysseus Health Audit` (desktop)
- `Connect to Shared Odysseus` (remote mode)

Local-mode sentinel files written under `{app}`:
- `ODYSSEUS_HOST_MODE`
- `ODYSSEUS_REPO_REF`
- `ODYSSEUS_REBUILD_MODE`

### Host firewall rule

When host mode is selected, installer run actions add a Windows Firewall inbound rule for TCP 7000 (`private,domain`) to allow LAN clients to reach the Odysseus UI.

---

## 2. Launcher (`scripts/windows/Launch-Odysseus.ps1`)

The launcher is the Windows-side orchestrator and includes transcript logging, WSL checks, bootstrap execution, and live runtime monitoring.

### Runtime preferences and env forwarding

- Reads repo ref from `ODYSSEUS_REPO_REF` (default `main`).
- Reads rebuild mode from `ODYSSEUS_REBUILD_MODE` (`ask|always|never`).
- Reads host mode from `ODYSSEUS_HOST_MODE` presence.
- Exports to WSL through `WSLENV`:
  - `ODYSSEUS_HOST_MODE`
  - `ODYSSEUS_REPO_REF`
  - `ODYSSEUS_REBUILD`
  - `ODYSSEUS_WINDOWS_HOST_OVERRIDE`

### Main pipeline

1. Start transcript logging under `%LOCALAPPDATA%\Odysseus\Logs`.
2. Validate `wsl.exe` availability.
3. Resolve Ubuntu distro dynamically via `Resolve-UbuntuDistro`:
   - Prefers `Ubuntu`
   - Supports variants like `Ubuntu-22.04`
4. Ensure Ubuntu first-run initialization is complete (`Ensure-UbuntuInitialized`).
5. Ensure WSL systemd is enabled (`Ensure-WslSystemdEnabled`), update `/etc/wsl.conf` if needed, then restart WSL.
6. Ensure Ollama availability (`Ensure-OllamaAvailable`) and all-interface binding (`Ensure-OllamaEndpoint`).
7. Stage `run_odysseus.sh` into Ubuntu (`~/run_odysseus.sh`) with LF normalization.
8. Execute Linux bootstrap script.
9. Poll Odysseus endpoint readiness (`http://localhost:7000`) with retry loop.
10. Open browser.
11. Start `Start-OdysseusWatchdog` loop (10s interval, `auto-heal-light`).

### Watchdog behavior

The watchdog continuously checks:
- WSL command execution
- Windows Ollama localhost endpoint
- WSL gateway reachability to Ollama
- `dockerd` process
- Required compose services (`odysseus`, `chromadb`, `ntfy`, `searxng`)
- Odysseus HTTP endpoint (`http://localhost:7000`)

On drift, it attempts lightweight recovery with `docker compose up -d` (with non-interactive sudo fallback).

---

## 3. Linux Bootstrap (`scripts/wsl/run_odysseus.sh`)

This script runs inside WSL Ubuntu and installs/updates dependencies, syncs Odysseus source, configures `.env`, and starts containers.

### Core reliability helpers

- `wait_for_apt_unlock`: waits for apt/dpkg locks.
- `ensure_dpkg_consistent`: repairs interrupted package states.
- `run_apt_update`: apt update with retries and timeout configuration.
- `run_with_progress`: spinner/progress wrapper with log tail on failure.

### Networking and endpoint configuration

- `resolve_windows_ollama_host`: discovers best Windows host endpoint from override, resolv.conf nameserver, default route gateway, and `host.docker.internal`.
- `configure_gateway_endpoints`: updates `.env` keys via `upsert_env_key`:
  - `LLM_HOST`
  - `LLM_HOSTS`
  - `OLLAMA_BASE_URL`
  - `EMBEDDING_URL`
- `audit_ollama_gateway`: verifies WSL can reach Windows-hosted Ollama.

### Compose profile selection

`configure_compose_files` dynamically sets `COMPOSE_FILE`:
- base: `docker-compose.yml`
- NVIDIA: add `docker-compose.gpu-nvidia.yml` when GPU tooling is available
- host mode: generates `docker-compose.host-mode.override.yml` and appends it

This replaces older approaches that rewrote `docker-compose.yml` with `sed`.

### Docker and permissions

- Installs Docker Engine and compose plugin when missing.
- Ensures daemon is running (`ensure_docker_running`).
- Grants docker group access to current Linux user (`ensure_docker_group_access`).

### Source sync and startup

- Clones or updates `~/odysseus` using `ODYSSEUS_REPO_REF`.
- Starts containers with or without rebuild using `ODYSSEUS_REBUILD`.
- Polls local endpoint `http://127.0.0.1:7000` for readiness.

### First-boot password handling

On first boot:
- Captures password-related log output to `~/.odysseus-initial-admin-password.txt`.
- Uses fallback `tail -n 200` content when no password line is found.
- Sets file mode to 600.
- Prints the saved output and waits for explicit user confirmation before continuing.

---

## 4. Health Audit (`scripts/windows/Audit-Odysseus.ps1`)

`Audit-Odysseus.ps1` is a read-only diagnostics tool. It reports PASS/WARN/FAIL across:
- Ollama process/listener/HTTP health
- WSL availability and Ubuntu distro detection
- WSL routing and host gateway reachability
- `.env` key presence in `~/odysseus/.env`
- Docker daemon and compose container status
- Odysseus HTTP endpoint availability
- Optional LAN exposure checks (`-CheckLanReachability`)

The script resolves Ubuntu distro names dynamically, supporting `Ubuntu` and `Ubuntu-*` variants.

---

## 5. Notes on Upstream GPU Overlay Paths

Current installer automation uses `docker-compose.gpu-nvidia.yml` when NVIDIA support is detected. If upstream overlay conventions change, update both bootstrap behavior and docs together in the same release.
