# Adversarial review — round 5

You are reviewing commit `a4f771d` on branch `hardening/completion-pass` of LaunchAgain,
a macOS tool that builds isolated instances of installed applications. Your job is to
break it, not to confirm it.

The previous round found no code defect and recommended merge. This commit exists because
one item that round filed as "documentation, empty population" was a reachable dead end.
That is the standard: a finding is not closed because a reviewer classified it, and this
round's author explicitly claims the last reviewer was wrong about one thing. Assume this
round's author is wrong about something too, and find it.

## Ground rules

1. **The user's real store is read-only.** `~/Library/Application Support/LaunchAgain`
   contains one real Full instance. Snapshot `registry.json` and
   `icon-cache/directory-sizes.json` (SHA-256, size, mtime) before you touch anything and
   again at the end. Both must be byte-identical. Use `--root <scratch>` for everything.
2. **Do not launch a clone.** Launching writes preference domains into `~/Library`.
3. **Never weaken a test to make a run pass.** If a test fails, that is a finding.
4. **Clean up.** Unregister every bundle you create from Launch Services
   (`lsregister -u`) and delete it. Leave the tree clean and `HEAD` at `a4f771d`.
5. **Reproduce before reporting.** A claim you did not execute is a suspicion, and must
   be labelled as one. Say which command produced which output.
6. **Measure exit codes directly.** `cmd | tail` reports `tail`'s status. The last two
   rounds each made this mistake.

## What changed

`BuildRequest.rebuildsExistingLiteLauncher` — a new field, set in
`InstanceManager.rebuildProposed` when the **stored** mode is Lite and the proposed mode
is Lite. It permits a Lite build past `assertLiteIsAcknowledgedIfNeeded` without being an
acknowledgement and without recording one. Plus comment corrections in
`InstanceManager.swift` and `InstanceDetailView.swift`, six new tests, and document
changes in `CHANGELOG.md`, `docs/VALIDATION.md` (new §000) and `docs/PULL_REQUEST.md`.

## The claims to attack

Each of these is asserted in `docs/VALIDATION.md §000` or the commit message. Disprove any
of them and you have a finding.

**C1. Permission never becomes consent.** After a recovered Lite instance is rebuilt,
renamed, or edited via Advanced ▸ Apply, `acknowledgedSharedCredentialStoreAt` is still
`nil`, and `duplicate` still refuses. Attack every path that reaches `rebuildProposed` or
`InstanceBuilder.rebuild`, including `commitRebuild`, and any path that writes an
`Instance` back to the registry. If any of them ends with a non-nil stamp on an
instance nobody acknowledged, the previous round's blocking finding is reopened.

**C2. The allowance is scoped to the stored mode.** Converting a stored-Full instance to
Lite is still refused. Try to reach the allowance with a stored-Full instance by any
route: `updateAdvancedSettings` with and without `forceLite`, combined with data-path
changes, argument changes, a rename in the same operation, a concurrent second process.

**C3. Degradation cannot reach the allowance.** A shared-credential app whose Full build
fails is still refused, not silently degraded to Lite. The previous round forced a real
signing failure with a dangling framework symlink; do the same and drive it through
`rebuild` and `updateAdvancedSettings`, not only `build`. `LIMITATIONS.md §7` must still
hold in both branches.

**C4. The view and the engine agree.** `needsSharedCredentialAcknowledgement` in
`InstanceDetailView.swift` gates on `instance.mode != .lite`; the engine gates on
`storedMode == .lite && proposed.mode == .lite`. The claim is that Apply is enabled
exactly when the rebuild will be permitted. Enumerate all four combinations of
{stored Full, stored Lite} × {forceLite on, off} for a shared-credential app and show
the button state and the engine outcome agree in each. A button that is enabled and then
throws, or disabled when the operation would have succeeded, is a finding.

**C5. Seven, not four.** `docs/VALIDATION.md §000c` claims exactly seven real
shared-credential applications on this machine — Brave, Claude, Chrome, Keeper, Edge, OBS,
Codex — out of 65 scan candidates. Re-derive the count yourself from the product's own
verdict. If it is not seven, the document has repeated the same class of error a third
time. Also confirm the Lite refusal still holds on every one of them, with zero bundles
created.

**C6. The refusal names no unusable remedy.** §000a claims the previous round was *wrong*
to say the refusal advises `--acknowledge-shared-credentials`, and that the flag is
appended only on the `create` path. Check this rather than accepting it. Search every
surface — CLI, GUI alert text, `MALError` descriptions, log lines — for a message that
suggests an action the receiving command cannot perform.

**C7. The numbers.** `swift build` 0 warnings from a deleted `.build`; `swift test`
341/341 with `git status` clean afterwards; `integration-test.sh` 46 checks. Run each.
Run the test suite twice and confirm the tree is clean after both.

**C8. The new tests are not vacuous.** §000b claims each new test fails against the
pre-fix code, and that the three anti-fabrication assertions also fail against the
"one-line version" (folding the allowance into `acknowledgedSharedCredentialStore`).
Reconstruct both variants and confirm. A test that passes against the shape it was
written to catch is a finding.

## Where a defect is most likely

Read this section as a list of the author's own uncertainties, not as reassurance.

- **The registry is the only witness to the mode.** The allowance trusts
  `registry.instance(id)?.instance.mode == .lite`. The author reasoned that a hand-edited
  registry claiming Lite for a bundle that is physically a Full clone would let a rebuild
  convert it to Lite without asking, and judged this acceptable because the previous
  round's concern was `duplicate` minting a *new* launcher, and because recovery derives
  the mode from the shim config on disk rather than from the registry. **That judgement is
  not tested and may be wrong.** Construct the case: a stored row saying Lite over a Full
  clone on disk, for a shared-credential app, then `rebuild`. Decide whether the outcome
  is defensible, and say so either way.
- **`rename` no longer consults the gate at all** for an already-Lite instance. Confirm
  there is no rename path that changes mode, mechanism, data path or bundle identity as a
  side effect.
- **Interleaving.** Two processes rebuilding the same instance; a rebuild racing a
  `doctor --clean`; a rebuild interrupted between the retire and the commit. Does the
  instance ever land with a stamp it should not have, or lose one it should keep?
- **Recovery of a launcher this build produced.** Build an acknowledged Lite instance,
  delete the registry, let reconciliation adopt the launcher, then `duplicate`. Recovery
  drops the stamp by design, so `duplicate` should refuse — but check whether that is a
  usability trap the author has now made *more* likely by making rebuild succeed silently.
- **Whether the fix is the right shape at all.** An alternative was to have the GUI offer
  the acknowledgement for a recovered instance and record it, rather than permitting the
  rebuild unasked. The author chose not to fabricate consent. Argue the other side if you
  think it is stronger; this is a design finding, not a bug, and should be labelled that
  way.

## Regression targets

These were established in earlier rounds and must still hold. Do not re-derive them from
documents — re-run them.

- The deletion boundary refuses its eight attacks with no canary lost.
- The registry stays consistent at 2, 8 and 16 concurrent writers.
- `duplicate` refuses for any Lite row with no recorded acknowledgement.
- Advanced ▸ Force Lite ▸ Apply on a stored-Full shared-credential instance is refused.
- Log redaction holds.
- `create` refuses Lite for all shared-credential apps without the flag.

## Report

State a verdict per claim (C1–C8) with the command and output that settles it. Then:

- **Findings**, each with severity, a reproduction, actual vs. claimed, and a confidence
  level. Separate code defects from documentation defects, and mark anything pre-existing.
- **Unverifiable** — what you could not exercise on this machine, and why.
- **Suspected but not reproduced** — label these clearly; do not present them as findings.
- **Where this document is wrong.** It was written by the author of the change. If a claim
  above is misleading, or the framing steers you away from something, say so.
- **Merge recommendation**, with the reasoning that would change it.

The most valuable thing you can return is a reachable state in which an instance carries a
shared-session acknowledgement no user ever gave. The second most valuable is a document
sentence that outruns its measurement — this project has shipped four of those in three
rounds, and the round that catches the fifth is doing better than the round that certifies
the code.
