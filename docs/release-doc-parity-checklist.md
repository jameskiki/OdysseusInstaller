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
- Verify launcher config output is documented:
  - single `odysseus-launcher.config` file with `ODYSSEUS_HOST_MODE`, `ODYSSEUS_REPO_REF`, `ODYSSEUS_REPO_SYNC_MODE`, `ODYSSEUS_REBUILD_MODE`
  - legacy marker file cleanup during install
- Verify hardcoded repo URL (`pewdiepie-archdaemon/odysseus`) is consistent between `installer.iss` and `run_odysseus.sh`.

## Launcher parity (`scripts/windows/Launch-Odysseus.ps1`)

- Verify docs include:
  - transcript logging path under `%LOCALAPPDATA%\Odysseus\Logs`
  - dynamic Ubuntu distro resolution (`Ubuntu`, `Ubuntu-XX.XX`)
  - Ubuntu first-run initialization path
  - WSL systemd enforcement and restart behavior
  - TestMode activation paths (`-TestMode`, config key, env variable)
  - TestMode behavior (non-interactive, rebuild forced to never, preflight-only stop)
  - `ODYSSEUS_TEST_MODE` forwarding via `WSLENV`
  - endpoint readiness poll before browser launch
  - watchdog mode and healing behavior

## Linux bootstrap parity (`scripts/wsl/run_odysseus.sh`)

- Verify docs cover current env/compose behavior:
  - dynamic Windows host endpoint resolution
  - runtime env path `~/.odysseus/runtime.env`
  - `COMPOSE_FILE` written to runtime env with absolute compose paths
  - host-mode override compose file generation at `~/.odysseus/docker-compose.host-mode.override.yml`
  - compose invocation using explicit `--env-file` and `-f` args from runtime profile
  - first-boot password capture file and fallback handling
- Verify docs mention dirty-working-tree protection before git sync in `~/odysseus`.
- Verify apt update strategy is represented accurately (retry/timeouts wrapper).
- Verify documented helper functions exist and are current.

## Support tooling parity

- Verify `scripts/windows/Audit-Odysseus.ps1` is listed and documented.
- Verify audit behavior around Ubuntu distro detection reflects current script.
- Verify audit docs mention runtime key checks from `~/.odysseus/runtime.env` with fallback to `~/odysseus/.env`.

## Documentation hygiene

- Check README links are valid and in-repo docs paths exist.
- Remove or update stale references to removed symbols.
- Confirm `future-work.md` reflects actual completion state.
