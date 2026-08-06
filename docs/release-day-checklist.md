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
- [ ] `OdysseusSetup-<version>.exe`
- [ ] `OdysseusSetup-<version>.exe.sha256`
- [ ] Run installer smoke test on a clean Windows machine/VM:
- [ ] Local mode install path
- [ ] WSL readiness guidance path (if WSL/Ubuntu missing)
- [ ] Launch script starts and reaches `http://localhost:7000` on prepared hosts

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
- [ ] Remote mode shortcut opens `http://<host-ip>:7000` as expected.
- [ ] Host mode firewall rule behavior validated.
- [ ] Audit shortcut runs and reports expected PASS/WARN output categories.

## 6) Wrap-up

- [ ] Record known issues and workarounds in release notes.
- [ ] Capture follow-up fixes in [future-work.md](../future-work.md).
