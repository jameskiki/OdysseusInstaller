# OdysseusInstaller

OdysseusInstaller is a Windows wizard that installs and launches the Odysseus AI Workspace on your machine.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Windows 10 / 11 (64-bit) | Required |
| WSL2 with Ubuntu | Run `wsl --install -d Ubuntu` in an elevated terminal if not already set up |
| NVIDIA GPU | Optional — improves response speed significantly; CPU-only mode also works |
| Ollama | Auto-installed by the launcher if not found |

---

## Installation — 3 Steps

**1. Download the installer**

Download `Odysseus_Setup.exe` from the [Releases](../../releases) page.

**2. Run the installer**

Double-click `Odysseus_Setup.exe` and follow the wizard.

- Accept the licence agreement.
- Choose your **deployment mode** (see below).
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
| **Connect to shared instance** | You connect to a colleague's machine that is already running Odysseus as a host. Enter their IP address in the wizard. |

---

## Accessing Odysseus

| Scenario | URL |
|---|---|
| Local or host machine | `http://localhost:7000` |
| Connecting remotely | `http://<host-ip>:7000` |

---

## Further Reading

- [Odysseus AI Workspace Guide](docs/odysseus-workspace-guide.md) — What Odysseus is and how to use it
- [Technical Reference](docs/technical-reference.md) — How the installer works under the hood
