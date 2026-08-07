# Release Day Checklist

Use this checklist when preparing and publishing a new installer version.

## 1) Pre-release readiness

- [ ] Confirm working tree is clean and branch is up to date.
- [ ] Confirm docs parity using [release-doc-parity-checklist.md](release-doc-parity-checklist.md).
- [ ] Confirm intended version number (example: `1.2.3` or `1.2.3-rc.1`).

## 2) Feature branch CI validation (no release)

- [ ] Push latest branch commits.
- [ ] Wait for **Build and Release Installer** workflow run to pass.
- [ ] Download CI artifact `odysseus-installer-<version>` from Actions.
- [ ] Verify artifact includes:
- [ ] `OdysseusSetup-<version>-<branch-slug>.exe` (non-tag CI builds)
- [ ] `OdysseusSetup-<version>-<branch-slug>.exe.sha256` (non-tag CI builds)
- [ ] Run installer smoke test on a clean Windows machine/VM:
- [ ] Local install path
- [ ] WSL readiness guidance path (if WSL/Ubuntu missing)
- [ ] Launch script starts and reaches `http://127.0.0.1:7000` on prepared hosts
- [ ] Host mode smoke test: client on same LAN can reach `http://<host-ip>:7000` when `ODYSSEUS_HOST_MODE=1` and bind host is non-loopback
- [ ] Health Audit shortcut runs and reports expected PASS/WARN output categories

## 3) Tag and publish release

- [ ] Create annotated tag on the release commit: `v<version>`.
- [ ] Push the tag to origin.
- [ ] Wait for tag-triggered **Build and Release Installer** workflow run to pass.

## 4) Verify release assets and metadata

- [ ] Open the GitHub Release created by CI.
- [ ] Confirm release assets are present:
- [ ] `OdysseusSetup-<version>.exe`
- [ ] `OdysseusSetup-<version>.exe.sha256`
- [ ] Verify SHA256 file matches the published `.exe`.
- [ ] Confirm pre-release flag behavior is correct (`-alpha`, `-beta`, `-rc` tags should be prerelease).

## 5) Post-release smoke checks

- [ ] Fresh install test (local mode) from release asset.
- [ ] Upgrade/repair path sanity check on a machine with prior install.
- [ ] Config override sanity checks:
- [ ] `ODYSSEUS_DEPLOYMENT_MODE`
- [ ] `ODYSSEUS_REPO_REF`
- [ ] `ODYSSEUS_REPO_SYNC_MODE`
- [ ] `ODYSSEUS_REBUILD_MODE`
- [ ] `ODYSSEUS_OPEN_BROWSER`
- [ ] `ODYSSEUS_APP_BIND_HOST`
- [ ] Optional host override path (`ODYSSEUS_WINDOWS_HOST_OVERRIDE`) validates as expected
- [ ] Optional host override path (`ODYSSEUS_OLLAMA_HOST`) validates as expected

## 6) Wrap-up

- [ ] Record known issues and workarounds in release notes.
- [ ] Capture follow-up fixes in [future-work.md](../future-work.md).
