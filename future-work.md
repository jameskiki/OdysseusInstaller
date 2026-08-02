# Future Work

## Installer UX

- Remote install mode: show the expected reachable server IP or hostname during configuration and in the pre-install summary.
- Local install mode: replace free-text branch entry with a dropdown of selectable branches.
- Pre-install summary: report what is already present versus what still needs to be installed or configured.
- WSL onboarding: decide whether Ubuntu first-run login can be automated; if not, document the security and UX constraint explicitly.

## Launcher And Runtime Reliability

- Verify the `Ensure-WslSystemdEnabled` path end-to-end after the stdin-piping fix in `Launch-Odysseus.ps1`, and capture failure logs when `/etc/wsl.conf` edits fail.
- Assess safe non-loopback Ollama binding guidance or remediation for WSL reachability.
- Add troubleshooting guidance or automatic remediation when WSL cannot reach Ollama from candidate Windows host endpoints.
- Investigate the remaining port `127.0.0.1:7000` bind conflict during compose startup and identify the owning process or namespace before adding a preflight or fallback.
