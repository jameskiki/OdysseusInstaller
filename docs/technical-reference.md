# Technical Reference

This document describes current local-installer pipeline and runtime behavior.

---

## Repository Structure

| File | Role |
|---|---|
| `installer/installer.iss` | Inno Setup script and local installer wizard logic |
| `scripts/windows/Launch-Odysseus.ps1` | Windows launcher/orchestration script |
| `scripts/windows/Prepare-WslForOdysseus.ps1` | WSL and Ubuntu preparation helper |
| `scripts/wsl/run_odysseus.sh` | Linux bootstrap script executed in WSL Ubuntu |
| `scripts/windows/Audit-Odysseus.ps1` | Read-only health audit script |
| `scripts/windows/lib/Odysseus.RuntimeChecks.psm1` | Shared runtime checks used by launcher/audit/diagnostics |
| `tools/windows/diagnostics/` | Maintainer-only staged diagnostics scripts |
| `tools/windows/` | Maintainer-only build/sign tooling |

---

## 1. Installer (`installer/installer.iss`)

### Wizard flow

The installer is local/LAN-host capable and keeps a minimal flow:

1. Licence agreement.
2. Deployment mode selection page (Local or LAN Host).
3. Installation info page.
4. Ready/summary page.

There is no internet/shared-instance wizard mode and no branch-selection page.

### Installer outputs and shortcuts

Setup copies:

- `Launch-Odysseus.ps1`
- `Prepare-WslForOdysseus.ps1`
- `run_odysseus.sh`
- `Audit-Odysseus.ps1`
- `lib/Odysseus.RuntimeChecks.psm1`

Shortcuts created:

- `Launch Odysseus`
- `Prepare WSL for Odysseus` (Start menu + desktop)
- `Odysseus Health Audit` (Start menu + desktop)

### Launcher config seed

Installer writes one local config file under `{app}`:

- `odysseus-launcher.config`

Default values are seeded from the selected installer mode.

Local mode defaults:

- `ODYSSEUS_DEPLOYMENT_MODE=local`
- `ODYSSEUS_HOST_MODE=0`
- `ODYSSEUS_APP_BIND_HOST=127.0.0.1`
- `ODYSSEUS_OPEN_BROWSER=1`

LAN Host mode defaults:

- `ODYSSEUS_DEPLOYMENT_MODE=lan-host`
- `ODYSSEUS_HOST_MODE=1`
- `ODYSSEUS_APP_BIND_HOST=0.0.0.0`
- `ODYSSEUS_OPEN_BROWSER=1`

Shared defaults in both modes:

- `ODYSSEUS_REPO_REF=dev`
- `ODYSSEUS_REPO_SYNC_MODE=managed-clean`
- `ODYSSEUS_REBUILD_MODE=ask`

Important: LAN Host mode is intended for trusted private networks only. TLS/auth hardening is not enabled by default in this release.

Legacy marker files are removed during install.

### WSL readiness behavior

Installer performs readiness checks only:

- It does not run `wsl --install` automatically.
- If WSL/Ubuntu is missing, it prompts user to run the prep shortcut.

### Firewall behavior

Installer configures inbound TCP `11434` rule (`Odysseus Ollama WSL Bridge`) for WSL-to-Windows Ollama traffic.

Launcher additionally ensures inbound TCP `7000` rule (`Odysseus AI Network Host`, Private profile) when host mode is enabled with non-loopback bind host.

---

## 2. Launcher (`scripts/windows/Launch-Odysseus.ps1`)

Launcher responsibilities:

1. Start transcript logging under `%LOCALAPPDATA%\Odysseus\Logs`.
2. Verify WSL and resolve Ubuntu distro (`Ubuntu` / `Ubuntu-*`).
3. Ensure Ubuntu first-run init is complete.
4. Ensure systemd setup required for runtime.
5. Ensure Ollama availability and reachability setup.
6. Stage and run WSL bootstrap (`run_odysseus.sh`).
7. Poll app endpoint readiness (`http://127.0.0.1:7000`).
8. Print host-local and LAN client URLs (when host mode is enabled).
9. Open browser (unless `ODYSSEUS_OPEN_BROWSER=0`).
10. Start watchdog monitoring loop.

### Runtime preferences and forwarding

Launcher reads `odysseus-launcher.config` and supports config/env override behavior:

- `ODYSSEUS_DEPLOYMENT_MODE` (`local|lan-host`)
- `ODYSSEUS_REPO_REF`
- `ODYSSEUS_REPO_SYNC_MODE` (`managed-clean|managed-ff|unmanaged`)
- `ODYSSEUS_REBUILD_MODE` (`ask|always|never`)
- `ODYSSEUS_HOST_MODE` (legacy fallback if deployment mode key is absent)
- `ODYSSEUS_OPEN_BROWSER`
- `ODYSSEUS_APP_BIND_HOST`
- `ODYSSEUS_WINDOWS_HOST_OVERRIDE`
- `ODYSSEUS_OLLAMA_HOST`
- `ODYSSEUS_TEST_MODE`

Precedence note: `ODYSSEUS_DEPLOYMENT_MODE` is authoritative when set; `ODYSSEUS_HOST_MODE` is retained as a backward-compatible fallback.

Forwarded into WSL via `WSLENV`:

- `ODYSSEUS_DEPLOYMENT_MODE`
- `ODYSSEUS_HOST_MODE`
- `ODYSSEUS_REPO_REF`
- `ODYSSEUS_REPO_SYNC_MODE`
- `ODYSSEUS_REBUILD`
- `ODYSSEUS_WINDOWS_HOST_OVERRIDE`
- `ODYSSEUS_OLLAMA_HOST`
- `ODYSSEUS_APP_BIND_HOST`
- `ODYSSEUS_TEST_MODE`

### Test mode

`-TestMode` or `ODYSSEUS_TEST_MODE=1` causes preflight-only behavior:

- No bootstrap run
- No browser launch
- No watchdog startup

---

## 3. Linux Bootstrap (`scripts/wsl/run_odysseus.sh`)

Bootstrap handles dependency readiness, source sync, runtime env generation, compose startup, and endpoint checks.

### Runtime state location

- `~/.odysseus/runtime.env`
- `~/.odysseus/docker-compose.host-mode.override.yml` (when host mode enabled)

### Endpoint and host discovery

`resolve_windows_ollama_host` probes candidates in order:

1. Explicit override (`ODYSSEUS_OLLAMA_HOST`)
2. Explicit override (`ODYSSEUS_WINDOWS_HOST_OVERRIDE`)
3. Windows default-route IPv4
4. WSL resolver nameserver
5. WSL default gateway
6. `host.docker.internal`

### Repo sync behavior

Uses `ODYSSEUS_REPO_REF` and `ODYSSEUS_REPO_SYNC_MODE`:

- `managed-clean`
- `managed-ff`
- `unmanaged`

### Compose behavior

Compose invocation is built from runtime profile (`--env-file` plus resolved compose files).

`ODYSSEUS_APP_BIND_HOST` controls whether a host-mode compose override is generated:

- `127.0.0.1` keeps local-only binding.
- Any other IPv4 host value publishes `7000` on that interface.

`ODYSSEUS_DEPLOYMENT_MODE` drives the default bind behavior when `ODYSSEUS_APP_BIND_HOST` is not set:

- `local` defaults to `127.0.0.1`
- `lan-host` defaults to `0.0.0.0`

---

## 4. Health Audit (`scripts/windows/Audit-Odysseus.ps1`)

Read-only audit reports PASS/WARN/FAIL across:

- Ollama process/listener/HTTP
- WSL and Ubuntu detection
- WSL-to-host reachability
- Runtime env keys
- Docker daemon + compose services
- Odysseus endpoint

The audit is profile-driven and prompts the user to select a profile when run interactively:

- `Quick`
- `Network`
- `Containers`
- `Consistency`
- `Full`

For non-interactive invocations, pass `-CheckProfile` explicitly to avoid prompts.

Consistency profile checks are WARN-only and focus on launcher intent vs runtime mapping parity (host mode intent, runtime endpoint keys, and compose file references).

`Full` and `Consistency` also print an informational service endpoint summary with IPv4 listener/bind mappings, Windows listener process ownership, compose published/internal ports, and runtime dependency targets.

Optional switch for extra troubleshooting detail:

- `-IncludeFailureLogHints`: adds last compose log lines for services that are not running or unhealthy (informational only).

Legacy `-CheckLanReachability` remains supported for compatibility and enables LAN checks even when the selected profile would otherwise skip them.

---

## 5. Maintainer-Only Diagnostics

The staged scripts in `tools/windows/diagnostics/` are maintainer/support tools and are not part of the normal end-user launch flow.

---

## 6. Maintainer Release Tooling

- CI workflow: `.github/workflows/release-installer.yml`
- Build/sign scripts: `tools/windows/*.ps1`

These are maintainer-only and separate from end-user runtime behavior.
