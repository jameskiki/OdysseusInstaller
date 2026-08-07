# Future Work

## Installer UX

- WSL onboarding: decide whether Ubuntu first-run login can be automated; if not, document the security and UX constraint explicitly.

## Launcher And Runtime Reliability

- Verify the `Enable-WslSystemd` path end-to-end on a machine where `/etc/wsl.conf` lacks `systemd=true`, and capture failure logs when the edit fails.
- Assess safe non-loopback Ollama binding guidance or remediation for WSL reachability.
- Add troubleshooting guidance or automatic remediation when WSL cannot reach Ollama from candidate Windows host endpoints.
- Investigate the remaining port `127.0.0.1:7000` bind conflict during compose startup and identify the owning process or namespace before adding a preflight or fallback.
- Fix LAN client URL rendering in host mode: `Launch-Odysseus.ps1` currently builds `"http://$lanIp:7000"`, which PowerShell parses as a scoped-variable token and can print as `http://` with no IP. Update to `"http://${lanIp}:7000"` (or format string) and add a fallback warning when LAN IP resolution fails.
