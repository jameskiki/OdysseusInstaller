# Odysseus AI Workspace Guide

## What is Odysseus?

Odysseus is a self-hosted AI assistant platform that runs on your own machine. Conversations and documents stay local to your environment.

You can chat with models, attach files, search documents, and switch models from a web browser.

---

## How it Works

```mermaid
graph LR
    A[Browser (local or LAN client)] -->|http://host-or-local:7000| B[Odysseus Containers]
    B -->|resolved host endpoint:11434| C[Ollama on Windows]
    C --> D[Local AI Models]
```

| Component | What it does |
|---|---|
| Browser | User interface |
| Odysseus containers | App layer, storage, account/session logic |
| Ollama | Runs AI models on local hardware |
| Models | Local model artifacts |

---

## First-Time Login

On first launch, Odysseus writes credential-related startup output in the launcher terminal.

1. Watch terminal output during initial bootstrap.
2. Copy the generated credential output shown.
3. Continue when prompted.
4. Browser opens to `http://127.0.0.1:7000` by default, or use the launcher-printed LAN URL when host mode is enabled.
5. Log in and rotate credentials as needed.

---

## Using the Workspace

### Start a conversation

1. Open `http://127.0.0.1:7000` (or your host LAN URL in host mode).
2. Click **New Chat**.
3. Type your message and press **Enter**.

### Pick a model

1. Open/start a chat.
2. Click the current model selector.
3. Choose another model.

If no model is available, run `ollama pull llama3` (or another model name).

### Attach documents

1. Click the attachment icon in chat input.
2. Select a file.
3. Ask your question in the same message.

### Manage history

- Browse past chats in the sidebar.
- Rename chats.
- Delete chats from menu actions.

---

## GPU vs CPU Mode

| | GPU (NVIDIA) | CPU only |
|---|---|---|
| Response speed | Faster | Slower |
| Model size | Larger models practical | Smaller/quantized models recommended |
| Setup | Auto-detected where available | Automatic fallback |

AMD note: installer does not auto-detect AMD acceleration paths. Expect CPU fallback unless manually configured.

---

## Advanced Runtime Overrides (Config-Only)

The installer does not expose advanced runtime options in wizard pages. Use `odysseus-launcher.config` for advanced behavior:

- `ODYSSEUS_DEPLOYMENT_MODE`
- `ODYSSEUS_REPO_REF`
- `ODYSSEUS_REPO_SYNC_MODE`
- `ODYSSEUS_REBUILD_MODE`
- `ODYSSEUS_HOST_MODE`
- `ODYSSEUS_APP_BIND_HOST`
- `ODYSSEUS_OPEN_BROWSER`
- `ODYSSEUS_WINDOWS_HOST_OVERRIDE`
- `ODYSSEUS_OLLAMA_HOST`

Recommended approach:

1. Keep defaults unless needed.
2. Change one key at a time.
3. Relaunch and validate behavior.
