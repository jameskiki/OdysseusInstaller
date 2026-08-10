# Release Documentation Parity Checklist

Use this checklist before creating or publishing a release tag.

## Installer flow parity (`installer/installer.iss`)

- Verify wizard screen count/order matches docs:
  - Licence
  - Deployment mode selection
  - Installation info
  - Ready/summary
- Verify there is no internet/shared-instance installer wizard path documented.
- Verify launcher config output is documented:
  - mode-specific defaults seeded from installer selection (Local vs LAN Host)
  - single `odysseus-launcher.config` file with `ODYSSEUS_DEPLOYMENT_MODE`, `ODYSSEUS_HOST_MODE`, `ODYSSEUS_REPO_REF`, `ODYSSEUS_REPO_SYNC_MODE`, `ODYSSEUS_REBUILD_MODE`, `ODYSSEUS_OPEN_BROWSER`, `ODYSSEUS_APP_BIND_HOST`
  - legacy marker file cleanup during install
- Verify launch shortcut label is documented as `Launch Odysseus`.
- Verify bridge firewall rule behavior is documented for TCP 11434.
- Verify launcher-managed host firewall behavior is documented for TCP 7000 in host mode.

## Launcher parity (`scripts/windows/Launch-Odysseus.ps1`)

- Verify docs include:
  - transcript logging path under `%LOCALAPPDATA%\Odysseus\Logs`
  - dynamic Ubuntu distro resolution (`Ubuntu`, `Ubuntu-XX.XX`)
  - Ubuntu first-run initialization path
  - WSL systemd enforcement and restart behavior
  - TestMode activation paths (`-TestMode`, config key, env variable)
  - TestMode behavior (non-interactive, rebuild forced to never, preflight-only stop)
  - `ODYSSEUS_TEST_MODE` forwarding via `WSLENV`
  - deployment mode precedence (`ODYSSEUS_DEPLOYMENT_MODE` over legacy host mode)
  - `ODYSSEUS_APP_BIND_HOST` and `ODYSSEUS_OLLAMA_HOST` forwarding via `WSLENV`
  - endpoint readiness poll before browser launch
  - browser launch override support (`ODYSSEUS_OPEN_BROWSER=0`)
  - host-mode client URL output guidance
  - watchdog mode and healing behavior

## Linux bootstrap parity (`scripts/wsl/run_odysseus.sh`)

- Verify docs cover current env/compose behavior:
  - deployment mode mapping (`local` vs `lan-host`) with host-mode fallback
  - dynamic Windows host endpoint resolution with explicit Ollama host override precedence
  - runtime env path `~/.odysseus/runtime.env`
  - `COMPOSE_FILE` written to runtime env with absolute compose paths
  - host-mode override compose file generation at `~/.odysseus/docker-compose.host-mode.override.yml` when bind host is not loopback
  - `ODYSSEUS_APP_BIND_HOST` persistence in runtime env
  - compose invocation using explicit `--env-file` and `-f` args from runtime profile
  - first-boot password capture file and fallback handling
- Verify docs mention dirty-working-tree protection before git sync in `~/odysseus`.
- Verify apt update strategy is represented accurately (retry/timeouts wrapper).
- Verify documented helper functions exist and are current.

## Support tooling parity

- Verify `scripts/windows/Audit-Odysseus.ps1` is listed and documented.
- Verify staged diagnostics scripts under `tools/windows/diagnostics/` are labeled maintainer-only.
- Verify audit docs mention runtime key checks from `~/.odysseus/runtime.env` with fallback to `~/odysseus/.env`.

## Documentation hygiene

- Check README links are valid and in-repo docs paths exist.
- Remove or update stale references to removed installer modes.
- Confirm `future-work.md` reflects actual completion state.
