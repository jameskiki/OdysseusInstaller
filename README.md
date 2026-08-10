# OdysseusInstaller

OdysseusInstaller is a Windows wizard that installs and launches an Odysseus AI Workspace instance on your machine, with optional LAN hosting for browser clients on the same network.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows 10 / 11 (64-bit) | Required |
| WSL2 with Ubuntu | Required before running the Odysseus launcher |
| NVIDIA GPU | Optional; CPU-only mode also works |
| Ollama | Auto-installed by the launcher if not found |

Before launching Odysseus, install WSL2 with Ubuntu by running `wsl --install -d Ubuntu` in an elevated terminal. Reboot if prompted. Then launch Ubuntu once and complete Linux username/password setup.

### Preinstall Checklist (WSL + Ubuntu)

1. Run `wsl --install -d Ubuntu` in an elevated terminal.
2. Reboot if prompted.
3. Launch Ubuntu once (`wsl -d Ubuntu` also works).
4. Complete Linux username/password creation.
5. Run the Odysseus installer, then launch Odysseus.

---

## Installation - 3 Steps

**1. Download the installer**

Download the latest Windows installer from the [Releases](../../releases) page.

**2. Run the installer**

Double-click the downloaded installer and follow the wizard.

- Accept the licence agreement.
- Choose deployment mode:
	- Local mode (loopback-only)
	- LAN Host mode (network browser access)
- Review the preflight summary in the Ready page.
- Click **Install**.

**3. Launch Odysseus**

Use the **Launch Odysseus** shortcut on your desktop. A terminal window opens, performs setup checks, runs bootstrap in WSL, and opens your browser.

When LAN Host mode is selected during install, the launcher also prints a client-access URL for other machines on the same network.

> **First time only:** the terminal displays generated admin credential output before browser launch.

For repeatable launcher-only validation without prompts, installs, browser launch, or watchdog startup, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Launch-Odysseus.ps1 -TestMode
```

The launcher also enables the same preflight-only mode when `ODYSSEUS_TEST_MODE=1` is set in `odysseus-launcher.config` beside `Launch-Odysseus.ps1` or when `ODYSSEUS_TEST_MODE=1` is set in the environment.

---

## Advanced Overrides (Config-Only)

The installer seeds mode-specific defaults into `{app}\odysseus-launcher.config`.

Default keys by selected installer mode:

| Installer mode | ODYSSEUS_DEPLOYMENT_MODE | ODYSSEUS_HOST_MODE | ODYSSEUS_APP_BIND_HOST | ODYSSEUS_OPEN_BROWSER |
|---|---|---|---|---|
| Local | `local` | `0` | `127.0.0.1` | `1` |
| LAN Host | `lan-host` | `1` | `0.0.0.0` | `1` |

Other seeded defaults are shared across both modes:

- `ODYSSEUS_REPO_REF=dev`
- `ODYSSEUS_REPO_SYNC_MODE=managed-clean`
- `ODYSSEUS_REBUILD_MODE=ask`

Advanced users can edit this config to override runtime behavior without installer UI:

- Deployment mode: `ODYSSEUS_DEPLOYMENT_MODE` (`local|lan-host`)
- Repo/version source: `ODYSSEUS_REPO_REF`
- Repo update strategy: `ODYSSEUS_REPO_SYNC_MODE` (`managed-clean|managed-ff|unmanaged`)
- Rebuild behavior: `ODYSSEUS_REBUILD_MODE` (`ask|always|never`)
- Legacy app exposure mode: `ODYSSEUS_HOST_MODE` (`0|1`) (fallback when `ODYSSEUS_DEPLOYMENT_MODE` is not set)
- Browser auto-open behavior: `ODYSSEUS_OPEN_BROWSER` (`1|0`)
- App bind host for port 7000 publish: `ODYSSEUS_APP_BIND_HOST` (default `127.0.0.1`)
- Windows host endpoint override for WSL reachability: `ODYSSEUS_WINDOWS_HOST_OVERRIDE`
- Explicit Ollama host override for WSL reachability: `ODYSSEUS_OLLAMA_HOST`

---

## Accessing Odysseus

| Scenario | URL |
|---|---|
| Local machine | `http://127.0.0.1:7000` |
| Same-LAN client (host mode enabled) | `http://<host-ip>:7000` |

LAN host mode quick-start:

1. Set `ODYSSEUS_DEPLOYMENT_MODE=lan-host` in `odysseus-launcher.config`.
2. Set `ODYSSEUS_APP_BIND_HOST=0.0.0.0` (or a specific host IP) in `odysseus-launcher.config`.
3. Optional for headless hosts: set `ODYSSEUS_OPEN_BROWSER=0`.
4. Launch Odysseus and use the client URL printed by the launcher.
5. The launcher attempts to ensure Windows Firewall has an inbound private-profile rule for TCP 7000 (`Odysseus AI Network Host`).

Important: LAN Host mode is intended for trusted private networks only. TLS/auth hardening is not enabled by default in this release.

Recommended modern setting for LAN mode:

- Prefer `ODYSSEUS_DEPLOYMENT_MODE=lan-host` and keep `ODYSSEUS_HOST_MODE` only for backward compatibility.

If launch fails during Ollama reachability checks, run the **Odysseus Health Audit** shortcut. The audit reports which WSL host candidates were tested for Ollama in priority order: explicit override, Windows default-route IPv4, WSL resolver nameserver, WSL default gateway, and `host.docker.internal`.

By default, the audit now prompts you to choose a profile:

- `Quick` - host + WSL + endpoint checks
- `Network` - `Quick` plus LAN exposure checks
- `Containers` - runtime env + container + endpoint checks
- `Consistency` - launcher intent vs runtime mapping consistency checks
- `Full` - all checks

For non-interactive runs (CI/support scripts), select a profile explicitly:

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\windows\Audit-Odysseus.ps1 -CheckProfile Full
```

`Full` and `Consistency` include an informational endpoint summary table with:

- IPv4 bind/listen rows
- Host process ownership for Windows listeners
- Container published/internal ports plus health/uptime
- Runtime dependency targets from `runtime.env`

Optional deep-dive hints for unhealthy/down compose services:

```powershell
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\scripts\windows\Audit-Odysseus.ps1 -CheckProfile Full -IncludeFailureLogHints
```

---

## Further Reading

- [Odysseus AI Workspace Guide](docs/odysseus-workspace-guide.md) - User guide for local workspace usage
- [Technical Reference](docs/technical-reference.md) - Installer and runtime behavior details
- [Release Doc Parity Checklist](docs/release-doc-parity-checklist.md) - Maintainer checklist to keep docs aligned with code
- [Release Day Checklist](docs/release-day-checklist.md) - Maintainer release runbook
