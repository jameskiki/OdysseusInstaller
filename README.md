# OdysseusInstaller

OdysseusInstaller is a Windows wizard that installs and launches a local Odysseus AI Workspace instance on your machine.

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
- Review local preflight summary in the Ready page.
- Click **Install**.

**3. Launch Odysseus**

Use the **Launch Odysseus (Local)** shortcut on your desktop. A terminal window opens, performs setup checks, runs bootstrap in WSL, and opens your browser at `http://localhost:7000`.

> **First time only:** the terminal displays generated admin credential output before browser launch.

For repeatable launcher-only validation without prompts, installs, browser launch, or watchdog startup, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\windows\Launch-Odysseus.ps1 -TestMode
```

The launcher also enables the same preflight-only mode when `ODYSSEUS_TEST_MODE=1` is set in `odysseus-launcher.config` beside `Launch-Odysseus.ps1` or when `ODYSSEUS_TEST_MODE=1` is set in the environment.

---

## Advanced Overrides (Config-Only)

The installer seeds defaults into `{app}\odysseus-launcher.config`.

Default keys:

- `ODYSSEUS_REPO_REF=dev`
- `ODYSSEUS_REPO_SYNC_MODE=managed-clean`
- `ODYSSEUS_REBUILD_MODE=ask`

Advanced users can edit this config to override runtime behavior without installer UI:

- Repo/version source: `ODYSSEUS_REPO_REF`
- Repo update strategy: `ODYSSEUS_REPO_SYNC_MODE` (`managed-clean|managed-ff|unmanaged`)
- Rebuild behavior: `ODYSSEUS_REBUILD_MODE` (`ask|always|never`)
- Windows host endpoint override for WSL reachability: `ODYSSEUS_WINDOWS_HOST_OVERRIDE`

---

## Accessing Odysseus

| Scenario | URL |
|---|---|
| Local machine | `http://localhost:7000` |

If launch fails during Ollama reachability checks, run the **Odysseus Health Audit** shortcut. The audit reports which WSL host candidates were tested for Ollama in priority order: explicit override, Windows default-route IPv4, WSL resolver nameserver, WSL default gateway, and `host.docker.internal`.

---

## Further Reading

- [Odysseus AI Workspace Guide](docs/odysseus-workspace-guide.md) - User guide for local workspace usage
- [Technical Reference](docs/technical-reference.md) - Installer and runtime behavior details
- [Release Doc Parity Checklist](docs/release-doc-parity-checklist.md) - Maintainer checklist to keep docs aligned with code
- [Release Day Checklist](docs/release-day-checklist.md) - Maintainer release runbook
