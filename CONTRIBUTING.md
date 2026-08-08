# Contributing to LaunchAgain

LaunchAgain operates on application bundles and signed-in profile directories, so changes
are reviewed as safety-sensitive even when the visible feature is small. Read `AGENTS.md`
and `README.md` before starting.

## Change process

1. Open an issue or write a short problem statement with reproduction evidence.
2. Create a focused branch and keep unrelated changes out of the patch.
3. Add a regression test before or with the fix.
4. Run the focused test, full suite, strict-concurrency build, integration test, and UI
   regression suite as the change requires.
5. Update README, changelog, public Pages patch notes, and affected technical documents.
6. Package and inspect the DMG for release-affecting changes.
7. After the source commit is accepted, run `./Scripts/publish-pages.sh` and verify the
   public Pages deployment. The script publishes only the de-identified `site/` payload.
8. Open a draft pull request using the repository template. State what was not tested.

Use generic fixtures and paths. Never attach a real registry, profile, diagnostics file,
account label, absolute home path, signing identity, or credential to an issue or commit.

## Review priorities

Reviewers check, in order: source-app immutability; deletion ownership and path bounds;
profile/session isolation; downgrade and acknowledgement gates; persistence and recovery;
concurrency; privacy; user-facing truthfulness; test evidence; and packaging. A change that
weakens one of those boundaries needs an explicit design decision, not a quiet workaround.

Security issues should be reported through the repository's private security-advisory
feature, not a public issue.
