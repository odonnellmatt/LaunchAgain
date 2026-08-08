# LaunchAgain maintainer contract

These instructions apply to every file in this repository. Human and AI maintainers must
read this file completely before making a change, then read `README.md`, the current entry
in `CHANGELOG.md`, and the security, privacy, limitation, specification, or validation
documents relevant to the task.

## Product boundary

LaunchAgain is a local-only macOS utility for creating isolated instances of compatible
GUI applications. Preserve these invariants:

- Never modify the source application. Full instances are copy-on-write clones; Lite
  instances open the vendor-signed original.
- Never send telemetry or make product network requests.
- Never read, copy, export, or infer credentials from an instance profile.
- Never build or execute shell command strings from user input.
- Never weaken exact-path deletion validation, instance identity verification, atomic
  registry writes, profile locks, or the shared-credential-store acknowledgement gate.
- Never silently turn an unsupported or unsafe state into a claim of full isolation.

## Required workflow

1. Reproduce or characterize the issue before editing. Separate observed evidence from
   inference and preserve a sanitized fixture when it adds regression value.
2. Work only in temporary stores for tests. Use `LAUNCHAGAIN_ROOT`, CLI `--root`, or the
   existing XCTest fixtures; never exercise create, delete, doctor-clean, migration, or
   rebuild tests against a real user store.
3. Implement the narrowest complete fix. Preserve unknown third-party metadata and fail
   closed at security or ownership boundaries.
4. Add a regression test that fails without the fix. Prefer pure `MALCore` tests, then a
   synthetic signed-bundle test when integration with the generated launcher matters.
5. Run, as applicable:

   ```bash
   swift test
   swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
   ./Scripts/integration-test.sh
   ./Scripts/ui-regression-test.sh 3
   ./Scripts/package-dmg.sh
   ./Scripts/publish-pages.sh
   ```

6. Verify the assembled app and DMG, not only SwiftPM products. Check the bundle signature,
   Info.plist version, universal architectures, packaged documents, DMG checksum, and a
   clean worktree apart from intended source changes.
7. Update documentation in the same patch. Every code or behaviour change must update:

   - the current-release summary in `README.md`;
   - `CHANGELOG.md`;
   - `site/patches.html`, which is the public GitHub Pages patch record;
   - any affected security, privacy, limitations, validation, or maintainer documentation.

8. Do not mark a check as passed unless its output was observed. Put hardware, permission,
   notarization, multi-display, or other manual gaps in the handoff explicitly.

## Repository and identity hygiene

- Keep source, history, artifacts, screenshots, workflow logs, and Pages content
  de-identified. Use `/Users/example`, `work@example.com`, and labels such as Personal,
  Work, Research, or Fixture.
- Never commit a real name, username, email address, machine name, home path, account
  label, diagnostics export, registry, profile, token, key, certificate, notary profile,
  local editor/agent settings, or build log.
- Keep generated output in ignored `.build/` or `build/`. Only release artifacts explicitly
  requested for distribution may be attached to a GitHub release; do not commit DMGs.
- The source repository must remain private. The Pages site is public by design, so only
  the de-identified `site/` directory may be uploaded by the Pages workflow.

## Architecture map

- `MALCore`: portable models, validation, compatibility rules, atomic persistence, and
  pure repair logic.
- `MALKit`: macOS scanning, cloning, signing, launch supervision, recovery, and cleanup.
- `MALShim`: executable planted in generated launchers; prepares the profile, repairs a
  recognized off-screen window state, then replaces itself with the target process.
- `MALApp`: SwiftUI dashboard. Published state is main-actor-only; filesystem operations
  run on its serial work queue and return Sendable values across the boundary.
- `MALCLI`: headless interface over the same engine.
- `Tests`: pure, engine, signed-bundle, reboot, concurrency, and hosted SwiftUI tests.
- `site`: the only source directory eligible for the separate public Pages repository;
  `Scripts/publish-pages.sh` copies its allow-listed files and no application source.

## Release discipline

Use semantic versioning. The first version heading in `CHANGELOG.md` is the version placed
in the app and DMG. Distribution builds are universal. Ad-hoc builds are valid local test
artifacts but are not notarized; never describe them as generally trusted downloads. A
public release requires Developer ID signing, Apple notarization, stapling, checksums, a
matching tag, and release notes copied from the verified changelog entry.
