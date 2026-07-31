# OdysseusInstaller

OdysseusInstaller is a Windows wizard that installs and launches the Odysseus AI Workspace on your machine.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows 10 / 11 (64-bit) | Required |
| WSL2 with Ubuntu | Required before running the Odysseus installer or launcher |
| NVIDIA GPU | Optional — improves response speed significantly; CPU-only mode also works |
| AMD GPU | Supported via CPU fallback path; GPU acceleration is not auto-detected by the installer |
| Ollama | Auto-installed by the launcher if not found |

Before launching Odysseus, install WSL2 with Ubuntu by running `wsl --install -d Ubuntu` in an elevated terminal. Reboot if Windows prompts you to do so. Then launch Ubuntu once and complete the Linux username/password setup. After that, launch Odysseus.

### Preinstall Checklist (WSL + Ubuntu)

1. Run `wsl --install -d Ubuntu` in an elevated terminal.
2. Reboot if prompted.
3. Launch Ubuntu once from the Start menu or by running `wsl -d Ubuntu`.
4. Complete Linux username/password creation.
5. Run the Odysseus installer, then launch Odysseus.

---

## Installation — 3 Steps

**1. Download the installer**

Download `Odysseus_Setup.exe` from the [Releases](../../releases) page.

**2. Run the installer**

Double-click `Odysseus_Setup.exe` and follow the wizard.

- Accept the licence agreement.
- Choose your **deployment mode** (see below).
- For local installs, pick a remote Odysseus branch from the dropdown (auto-loaded from GitHub).
- For remote installs, enter host IP and verify the shown URL preview (`http://<host-ip>:7000`).
- Review the pre-install summary grouped as: **Already present**, **Will be installed/configured**, and **Manual action required**.
- Click **Install**.

**3. Launch Odysseus**

Use the **Launch Odysseus (Local)** shortcut on your desktop. A terminal window will open, run the setup automatically, and then open your browser at `http://localhost:7000`.

> **First time only:** The terminal will display a randomly generated admin password before opening the browser. Copy it — you will need it to log in.

---

## Deployment Modes

| Mode | What happens |
|---|---|
| **Local** | Odysseus runs on your machine; only you can access it. |
| **Local + Host** | Odysseus runs on your machine; colleagues on the same network can also connect. |
| **Connect to shared instance** | You connect to a colleague's machine that is already running Odysseus as a host. Enter their IPv4 address in the wizard. |

---

## Accessing Odysseus

| Scenario | URL |
|---|---|
| Local or host machine | `http://localhost:7000` |
| Connecting remotely | `http://<host-ip>:7000` |

If launch fails during the Ollama reachability audit, run the **Odysseus Health Audit** shortcut. The audit now reports which WSL host candidates were tested for Ollama (`gateway`, `host.docker.internal`, or an explicit override), which helps diagnose Windows 10 host-routing edge cases quickly.

---

## CI Build and Release Workflow

GitHub Actions for this repository is handled by a single workflow: `.github/workflows/release-installer.yml`.

### Feature branch and PR testing (no release required)

- Trigger: push to any branch or update/open a pull request.
- Behavior: compiles the installer and uploads CI artifacts.
- Output artifact name: `odysseus-installer-<version>`
- Artifact contents:
	- `OdysseusSetup-<version>.exe`
	- `OdysseusSetup-<version>.exe.sha256`

How to test a feature branch:

1. Push your branch.
2. Open the Actions run named **Build and Release Installer**.
3. Download the uploaded artifact.
4. Unzip and run the `.exe`.

### Release builds (tag-driven)

- Trigger: push a tag matching `v*` (example: `v1.2.3` or `v1.2.3-rc.1`).
- Behavior: compiles installer, computes SHA256, and creates a GitHub Release with assets.
- Release assets:
	- `OdysseusSetup-<version>.exe`
	- `OdysseusSetup-<version>.exe.sha256`

### Manual runs

- Trigger: **Run workflow** (`workflow_dispatch`) from the Actions UI.
- Optional input: `version` (for non-tag/manual runs).
- If no manual version is provided and the run is not a tag release, CI uses an internal version format: `0.0.0-ci.<run_number>`.

---

## Repository Layout

| Path | Purpose |
|---|---|
| `installer/installer.iss` | Inno Setup project |
| `installer/Licenses.txt` | Installer licence text bundle |
| `scripts/windows/` | Windows launcher and audit scripts |
| `scripts/wsl/` | WSL bootstrap script |
| `docs/` | Documentation and release checklists |

---

## Further Reading

- [Odysseus AI Workspace Guide](docs/odysseus-workspace-guide.md) — What Odysseus is and how to use it
- [Technical Reference](docs/technical-reference.md) — How the installer works under the hood
- [Release Doc Parity Checklist](docs/release-doc-parity-checklist.md) — Pre-release checklist to keep docs aligned with code
- [Release Day Checklist](docs/release-day-checklist.md) — Step-by-step test and publish runbook
