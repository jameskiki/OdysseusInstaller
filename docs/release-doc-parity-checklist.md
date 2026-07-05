# Release Documentation Parity Checklist

Use this checklist before creating or publishing a release tag.

## Installer flow parity (`installer/installer.iss`)

- Verify wizard screen count and order match docs:
  - Licence
  - Deployment type
  - Odysseus version selection
  - Container rebuild preference
  - Host IP input
- Verify `ShouldSkipPage` behavior is documented correctly.
- Verify output sentinel files are documented:
  - `ODYSSEUS_HOST_MODE`
  - `ODYSSEUS_REPO_REF`
  - `ODYSSEUS_REBUILD_MODE`

## Launcher parity (`scripts/windows/Launch-Odysseus.ps1`)

- Verify docs include:
  - transcript logging path under `%LOCALAPPDATA%\Odysseus\Logs`
  - dynamic Ubuntu distro resolution (`Ubuntu`, `Ubuntu-XX.XX`)
  - Ubuntu first-run initialization path
  - WSL systemd enforcement and restart behavior
  - endpoint readiness poll before browser launch
  - watchdog mode and healing behavior

## Linux bootstrap parity (`scripts/wsl/run_odysseus.sh`)

- Verify docs cover current env/compose behavior:
  - dynamic Windows host endpoint resolution
  - `.env` upsert helper approach
  - host-mode override compose file generation
  - first-boot password capture file and fallback handling
- Verify apt update strategy is represented accurately (retry/timeouts wrapper).
- Verify documented helper functions exist and are current.

## Support tooling parity

- Verify `scripts/windows/Audit-Odysseus.ps1` is listed and documented.
- Verify audit behavior around Ubuntu distro detection reflects current script.

## Documentation hygiene

- Check README links are valid and in-repo docs paths exist.
- Remove or update stale references to removed symbols.
- Confirm `future-work.md` reflects actual completion state.
