# Future Work

- Verify the systemd-enablement path in `Ensure-WslSystemdEnabled` end-to-end after the stdin-piping fix in `Launch-Odysseus.ps1`.

- Release publishing runbook: [docs/release-day-checklist.md](docs/release-day-checklist.md)

- Launcher installer UX feedback from testing (2026-07-31):
	- Remote install mode: show the expected reachable server IP (or hostname) during configuration and in the pre-install summary.
	- Local install mode branch selection: replace free-text branch entry with a dropdown/selectable list of branches.
	- Clarify GPU support matrix in installer/docs: explicitly answer whether AMD GPUs are supported, and under what constraints.
	- Improve the pre-install summary with a true preflight result (what is already present vs what must be installed), similar to the end-of-install readiness output.
	- Investigate launcher failure updating /etc/wsl.conf for systemd:
		- Observed error: awk syntax error in the command used to modify [boot] and systemd=true.
		- User-visible failure: "[FAILED] Failed to update /etc/wsl.conf for systemd support (exit code 1)."
		- Action: harden the text-edit implementation and add tests/log capture for this path.
	- Evaluate whether WSL/Ubuntu login can be automated (or document security/UX reasons if not possible).

- Health check findings from testing session (2026-07-31):
	- Ollama bind scope failed: currently loopback-only (127.0.0.1/::1); assess safe non-loopback binding guidance/setup for WSL reachability.
	- WSL reachability failed: curl to Ollama /api/tags from WSL failed for 172.29.112.1 and host.docker.internal.
	- Odysseus endpoint failed: 127.0.0.1:7000 not reachable after launch.
	- Follow-up: add troubleshooting guidance and/or automatic remediation for the three failures above.
