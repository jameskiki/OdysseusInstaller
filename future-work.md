# Future Work

- Validate remote-host IP input in installer (`installer.iss`).
- Handle non-clean local git states more clearly in `run_odysseus.sh`.
- Limit first-boot log capture volume for password hints in `run_odysseus.sh`.
- Verify the systemd-enablement path in `Ensure-WslSystemdEnabled` end-to-end after the stdin-piping fix in `Launch-Odysseus.ps1`.
- Verify `ODYSSEUS_HOST_MODE` is correctly forwarded into WSL via `WSLENV` when host mode is selected (only relevant for host-mode installs).
