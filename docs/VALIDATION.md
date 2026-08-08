# Validation — v0.1.2

What was checked, how, and what the check actually showed. Where something could not be
verified it says so and stops there; §8 is the list of what was not closed, longest-lived
first.

## v0.1.2 — beta packaging of the hardened implementation

**Date:** 7 August 2026. **Machine:** macOS 26.5.2 on Apple Silicon with one active
display. All destructive and creation tests used temporary stores and synthetic bundles;
the live LaunchAgain registry, source applications, and cloned profiles were not edited.

### Reproduction and repair boundary

The affected cloned profile had saved a 1,258×816 window at `(2234, 144)` on a
1,920×1,080 external display whose global origin was `(1800, 0)`. With only an 1,800-point
display active, the saved title bar had no reachable region. That is the reported thin or
absent visual remnant.

The generated shim now runs the schema-limited repair before `execv`. Seven pure tests
cover a disconnected display, an already reachable window, the thin-edge case, a still
attached saved display, malformed JSON, a symbolic link, repeated launch stability,
unknown-key preservation, the original backup, and permission preservation. A separate
process integration test executes the shipped shim and confirms it repairs before the
target executable starts.

Physical drag/disconnect/reconnect testing still requires two displays and was not
claimed here. The deterministic reproduction used the observed saved geometry, and the
manual two-display procedure is in `docs/manual-checklist.md`.

### Audit findings closed

- Shared mutable date formatting was replaced with a value-style ISO-8601 formatter.
- Process pipe data now crosses sendable closures through locked storage; readers begin
  only after a successful spawn, so a failed spawn cannot strand them.
- Delete/forget reports cross the worker-to-main boundary as returned sendable values,
  not shared captured mutation.
- CLI `launch` and `quit` use an independent executor. The integration gate exposed that
  a main-actor-inheriting task paired with a blocking semaphore could wait forever; a
  dedicated process-level test now requires the missing-launcher failure to return within
  five seconds.
- AppKit timers, notification observers, and directory watchers live in a locked lifetime
  owner. This preserves deterministic cleanup on both the local compiler and the older
  macOS 15 CI toolchain, without relying on the newer `isolated deinit` language feature.
- The creation-progress callback is explicitly sendable. The macOS 15 strict build found
  the missing boundary because its Swift compiler could not otherwise prove that the
  main-actor UI update was safe after the callback crossed the background build queue.
- Window identity has one stable owner: the system title bar. macOS 15 hosted runs proved
  that SwiftUI may overwrite `NSWindow.titleVisibility` after a representable applies it,
  so the dynamic AppKit bridge and duplicate sidebar brand block were removed. Hosted UI
  assertions wait for stable frames and sheet presentation instead of sampling a
  transient layout pass.
- CI concurrency is keyed by commit. GitHub delivered an older private-repository push
  event after a newer manual run and canceled the newer run under the former branch-level
  group; different revisions can no longer invalidate one another's evidence.

### Observed verification

| Gate | Result |
|---|---|
| `swift test` | **356 tests, 0 failures** in 175.254 seconds after the final toolchain-portability change |
| strict-concurrency warnings-as-errors build | **passed**, 0 warnings |
| `./Scripts/integration-test.sh` | **passed**, including concurrent create, failed-launch exit status, source immutability, signatures, rebuild and exact cleanup |
| `./Scripts/ui-regression-test.sh 3` | **3 consecutive passes**, 6 hosted dashboard tests per run |
| Pages preview | 1,440×900 and 390×844 passed with no horizontal overflow or browser warnings |
| GitHub Pages | separate de-identified public mirror deployed successfully with current Node 24 action releases (`checkout@v7`, `configure-pages@v6`, `upload-pages-artifact@v5`, `deploy-pages@v5`) |
| universal release | GUI, CLI and shim each report `x86_64 arm64` |
| app and DMG code-signature verification | `codesign --verify` passed |
| DMG checksum | `e739a9521873f401da6fa4f8d48917aa3bf9dc6b4e8b50a3d0910923f17afa4e` |
| read-only DMG mount | version 0.1.2 app, Applications link, and all seven documentation files present |

The release is intentionally ad-hoc signed because no Developer ID/notary profile was
provided. Gatekeeper assessment rejects both artifacts, as expected and as disclosed by
the package script and README. It is a verified local build, not a notarized public
distribution. The first checksum invocation was made from the repository root even
though the checksum records the DMG basename; it correctly failed to find the file. The
same check was rerun from `build/` and passed.

---

**Machine:** macOS 26.5.2, Apple Silicon. **Branch:** `hardening/completion-pass`.
**Baseline commit:** `496d032` — the end of the v1.1 pass.

§000 covers v1.2.3 through v1.2.5 — the stranded instance (§000a–e), what round 5 returned
against that fix (§000f), and the three findings it deferred (§000g). §00 is the v1.2.2
closing pass. §0 is the v1.2.1 remediation round. §§1–8 are the v1.2 evidence, corrected
where a later round proved it wrong — and two rounds proved gap 6 wrong, in different
directions.

| Commit | What |
|---|---|
| `bd903af` | **A1** — the two startup recovery writes take the registry lock |
| `82f465e` | **A2** — `doctor` stops reporting a destructive run it did not perform |
| `98f34a4` | **A3** — race real `create` processes in the integration suite |
| `7c04ac2` | **B1** — detect apps whose session lives outside the profile |
| `abc45bd` | **B3** — stop an instance updating itself out of its own identity |
| `f41445b` | **B4** — a second launcher home, in `/Applications` |
| `19de82b` | **B5** — measure what a clone leaves behind; widen the sweep |
| `4446e47` | **B2** — diagnose the missing badge; fix our half, name the other |
| `6dd33d2` | **C5** — the launcher's own icon |
| `1c38c3b` | **C1/C4** — delete confirmation, create-flow defaults and disk estimate |
| `ed0a249` | **C2/C3** — window identity, health rows |

---

## 000. v1.2.3 — the stranded instance

The fourth adversarial round found **no code defect** and recommended merge. It filed
four documentation inaccuracies, and dismissed one of them — "rows from older registries
are asked again" — as prose with an empty population, because nothing has shipped from
this branch and the only real instance is Full.

That reasoning is correct about *pre-gate registry rows* and wrong about the shape as a
whole, which is the one thing this round changes. The same round's implementer had
flagged the other half of it as a judgement call in their own notes — "recovered or
reconciled Lite instances now have no acknowledgement record" — and neither report joined
the two. This section is the join.

### 000a. What was actually broken

`LauncherReconciler`'s **legacy** path builds an `Instance` from the shim config of a
launcher found on disk (`LauncherReconciler.swift:231`). It takes the mode from that
config — a physical fact about the launcher — and records no acknowledgement, because
recovery has no evidence anyone was asked. Inventing one there would be the defect the
whole gate exists to prevent.

> **Corrected in v1.2.4 (round 5, F5).** This section originally said a shipped build
> mints such a row "every time it adopts a launcher". It does not. Every launcher this
> version builds carries a `LauncherRecoveryManifest` holding the whole `Instance`,
> acknowledgement included (`InstanceBuilder.swift:643`), and reconciliation prefers that
> manifest over the legacy path. Recovering a launcher this build produced **preserves the
> stamp** — measured: delete `registry.json` and `registry.json.bak`, and `ack` survives,
> and `duplicate` succeeds. The un-acknowledged shape comes only from launchers with no
> manifest, or whose manifest fails `LauncherIdentityVerifier.verify`: pre-manifest
> releases and bundles whose identity no longer matches. The population is real but
> narrower than claimed, and the prose generalised past its own fixture.

1.2.2 then gated every path through `rebuildProposed` on a recorded acknowledgement. For
a recovered Lite instance of a shared-credential application that produced:

| Command | 1.2.2 | 1.2.3 |
|---|---|---|
| `rebuild` | refused, exit 1 | rebuilds |
| `rename … --rebuild` | refused, exit 1 | renames |
| Advanced ▸ Apply | button enabled, then throws | applies |
| `duplicate` | refused, exit 1 | **still refused** |

The GUI was worse than refusing: `needsSharedCredentialAcknowledgement` gated on
`instance.mode != .lite` while the engine gated on the stored acknowledgement, so Apply
was enabled and then failed.

One thing the review got wrong, checked because this document has repeated a reviewer's
claim before. It reported that the refusal "advises `--acknowledge-shared-credentials`, a
flag only `create` accepts". It does not. `MALError.sharedCredentialStoreNotAcknowledged`
returns `Compatibility.sharedCredentialLiteRefusal` verbatim, which names the consequence
and no remedy; the flag is appended only on the `create` path (`main.swift:360`). Measured
on the refused `duplicate`: zero occurrences of the flag name in the output. Round 5
re-checked this and agreed on the flag; it found two *other* surfaces that do name an
unreachable remedy, both pre-existing — see §000f.

> **Corrected in v1.2.4 (round 5, F6).** The sentence that followed said "the defect was
> that there was no route". There was no *command-line* route. There has always been a
> GUI one: for a stored-Lite instance `sharedCredentialVerdict` is non-nil, so the
> Advanced panel renders the acknowledgement checkbox, and `applyAdvanced` passes it to
> the engine, which records it. Measured: `updateAdvancedSettings(forceLite: true,
> acknowledgedSharedCredentialStore: true)` on a recovered row stamps the instance and
> `duplicate` then succeeds. The stranding was CLI-only, which is a smaller defect than
> the one this document claimed, and it weakens the design argument in §000b — see §000f.

### 000b. The fix, and the version of it that would have been wrong

The gate now asks whether a build **introduces** a shared session, not whether one
exists. `BuildRequest.rebuildsExistingLiteLauncher` is set when the launcher **on disk**
is Lite and the proposal is Lite, computed in `rebuildProposed` from
`BundleAssembler.readInstanceConfig` rather than from `proposed` — which on the Advanced
path is the proposal, with `forceLite` already applied to it.

*(In 1.2.3 this read the registry row instead of the disk. Round 5 reproduced the
consequence; corrected in 1.2.4, §000f F1.)*

The obvious one-line version is to OR the condition into
`acknowledgedSharedCredentialStore`. It was tried and it is wrong, which is recorded here
because the test that catches it looks redundant otherwise. That flag also *writes the
stamp* (`InstanceBuilder.swift:572`, the write at `:590`), so folding them together stamps
`createdAt` as the date the user accepted, for a user who was never asked — and
`duplicate` reads that stamp to authorise a new launcher. Measured against the one-line
version, in `SharedCredentialGateTests`:

```
:381  XCTAssertNil failed: "2026-07-27 12:29:38 +0000" — the rebuild minted a
      consent date for a user who was never asked
:385  XCTAssertThrowsError failed: did not throw an error
:391  XCTAssertEqual failed: ("2") is not equal to ("1")
:398  XCTAssertNil failed: "2026-07-27 12:29:40 +0000"
:406  XCTAssertNil failed: "2026-07-27 12:29:42 +0000"
```

**Five** assertions across two tests, not the three this section first listed — the
original run exercised only one of the two tests and the count was never corrected
(round 5, F9).

That is 1.2.2's blocking finding, reopened through a different door: rebuild once, and
`duplicate` stops refusing. The two are separate fields for that reason, and the
permission is read at the gate and nowhere else.

Degradation cannot reach the allowance either. It fires only when `effectiveMode == .full`
(`InstanceBuilder.swift:164`), and a rebuild of a stored-Lite instance never runs the Full
path, so a shared-credential app whose Full build fails is still refused rather than
quietly degraded. Round 5 confirmed this by forcing a real signing failure with a dangling
framework symlink and driving it through `rebuild` and `updateAdvancedSettings`: the
degradation branch **was** reached and refused there, rather than bypassed. LIMITATIONS §7
gained a qualifying paragraph in 1.2.4 covering the rebuild path itself.

### 000c. The app count

`VALIDATION.md` and `CHANGELOG.md` said the Lite refusal held on "all four" real
shared-credential applications. Re-counted by running `inspect` over every one of the 65
scan candidates: **seven**.

```
Brave Browser · Claude · Google Chrome · Keeper Password Manager
Microsoft Edge · OBS Studio · Codex
```

The refusal holds on all seven, so the property was right and only the number was false.
`PULL_REQUEST.md:21`'s "all four" and §00h's "the four false statements" are different
referents and are correct; they were checked and left alone.

### 000d. Driven through the CLI

An acknowledged Lite Codex instance in a throwaway `--root` store, with
`acknowledgedSharedCredentialStoreAt` then stripped from `registry.json` — which is what a
recovered row looks like:

```
create  … --lite --acknowledge-shared-credentials  → ack= 2026-07-27T12:37:19Z
                                        (field stripped by hand)
rebuild 1     → ✓ rebuilt #1 as lite; data preserved      exit 0
rename  1 …   → ✓ #1 is now "Renamed" (number unchanged)  exit 0
duplicate 1   → error: Lite mode cannot isolate Codex …   exit 1
```

Afterwards: one instance, `mode=lite`, `name=Renamed`, **`ack=None`**. The two successful
rebuilds recorded no acknowledgement, the refused `duplicate` created nothing, and the
refusal output contains the flag name zero times.

### 000e. Verification

* `swift build` from a deleted `.build`: **0 warnings**.
* `swift test`: **341 tests, 0 failures** (335 → 341), `git status` clean afterwards.
* `./Scripts/integration-test.sh`: **46 checks passed**, unchanged.
* **Five of the six** new tests fail against the pre-fix code. The sixth,
  `testTheAllowanceDoesNotExtendToConvertingAStoredFullInstance`, passes both before and
  after — it asserts that the gate still refuses a Full ▸ Lite conversion, which was true
  before the change too. It is a regression guard, not a demonstration of new behaviour,
  and this section originally claimed all six fail (round 5, F8). The five
  anti-fabrication assertions were additionally run against the one-line fix in §000b and
  fail there too.
* The user's store was not written: `registry.json` and `icon-cache/directory-sizes.json`
  carry the same modification times before and after.

### 000f. v1.2.4 — what round 5 returned

Round 5 recommended "merge the code; do not merge the documents as written". It found no
reachable state in which an instance carries an acknowledgement no user gave, and
confirmed C2, C3, C5 and C7 against its own measurements. It also found that four
sentences in §000 outran what had been measured — the fifth consecutive round to find at
least one. Every finding below was re-verified here before being acted on.

**F1 — the allowance read the registry, and its justification is about the disk.**
*Code, medium, introduced by 1.2.3, fixed here.* The brief for round 5 named this as an
untested judgement call and the round reproduced it: a row hand-edited to say Lite over a
Full clone let `rebuild` convert a 366 MB clone with its own ad-hoc identity into a 388 KB
launcher running the vendor-signed original, sharing its Keychain items — silently, exit
0. Sharing was introduced in the one case the gate exists for. The gate now reads the shim
config on disk, the same physical fact the reconciler reads, and fails closed when it
cannot. No non-tampering route to the divergent state was found by the reviewer or here,
which bounds the severity but does not excuse it.

**F3 — `renumber` re-dated the acknowledgement.** *Code, low, pre-existing, fixed here.*
It rebuilds the row field by field and omitted `acknowledgedSharedCredentialStoreAt`, so
the date survived as `nil` while the acknowledgement survived as `true` — and the build
fell through to `?? createdAt`, stamping the moment of the renumber. Measured:
`12:51:19Z → 12:51:44Z`. This falsified the comment two lines above the write. Fixed by
carrying the field, with a test that fails against the omission.

**F5 and F6 — the two load-bearing over-generalisations.** Corrected in place at §000a,
and at the four source and test comments that repeated them. Both are recorded rather than
quietly edited, because the pattern — a sentence that is true of the fixture and false of
the population — is the one this project keeps repeating.

**F8, F9, F10 — three counts and a line number.** Corrected at §000e, §000b and §000b
respectively.

**F11 — `LIMITATIONS.md` §7 described a gate the product no longer has.** The three other
documents were corrected in 1.2.3 and the user-facing one was not. It now carries the
qualifying paragraph.

**F2, F4 and F7 were deferred here and closed in v1.2.5** — see §000g.

**Where the round-5 brief itself was wrong.** It told the reviewer that recovery "drops the
stamp by design, so `duplicate` should refuse", which is F5's error restated as an
instruction — it directed the reviewer to confirm a usability trap instead of testing the
premise underneath it. The reviewer tested the premise anyway and that is where the finding
was. A brief written by the author of the change inherits the author's errors; the next one
should be written to be falsified, not confirmed.

### 000g. v1.2.5 — the three deferred findings

**F2 — the interface predicted the mode, the builder resolved it.** A verdict degrades an
application to Lite for several reasons; a privileged helper is one, and Chrome, Brave and
Edge all install one. When that happens `effectiveMode` resolves a Full request to Lite,
and the gate then fires. The detail view read `instance.mode` instead, so for a
shared-credential application whose source had gained a helper since the instance was
built it predicted Full, rendered no checkbox, and left Apply enabled for a build that
would refuse. `Rebuild from Source App` had no gate in the view at all.

One definition now — `CompatibilityVerdict.effectiveMode(requesting:)` — consulted by
`InstanceBuilder.build` and by `InstanceDetailView.sharedCredentialVerdict`. Rebuild is
disabled when `rebuildWouldBeRefused`, with help text naming Advanced.

**The `verdict == nil` window**, which round 5 marked as read from code and not driven.
Confirmed by reading: `verdict(forAppKey:)` returns `nil` on the first call and inspects
on a background queue, and the view treated "not known yet" as "nothing to acknowledge".
`verdictIsPending` now blocks Apply until the inspection lands. It is one `codesign`.

**F4 — `createdAt` survived nothing.** `BuildRequest` carried no creation date, so both
build paths stamped `Date()` and `commitRebuild` wrote it. Now carried across a rebuild.

**F7 — two messages named a remedy their command cannot perform.** Both rewritten:
"use Rebuild after turning this off" cannot undo Force Lite, because `rebuild` builds at
the stored mode; and the `CODEX_HOME` route out is printed by the CLI, which has no
command that sets an environment variable on an instance.

**Honest test accounting**, since this is the thing the last three rounds each got wrong.
Three tests were added. `testRebuildingAnInstanceKeepsItsCreationDate` **fails** against
the pre-fix code. `testAFullRequestResolvesToLiteWhenTheVerdictOnlyRecommendsLite` pins a
rule that did not exist before, so it cannot be run against the pre-fix code at all.
`testAnInstanceOfAnAppThatBecameLiteOnlyIsRefusedNotSilentlyDegraded` **passes** against
the pre-fix code and is labelled in its own doc comment as a regression guard — the engine
always refused; F2 was that the view disagreed, and the view's half is a SwiftUI
expression this suite cannot reach.

**Verification.** `swift build` 0 warnings from a deleted `.build`; `swift test`
**347/347** (344 → 347), `git status` clean afterwards; `integration-test.sh` exit 0,
46 checks; the real store byte-identical.

---

## 00. v1.2.2 — the closing pass

A third adversarial round returned "merge with fixes": two code defects, six minors, and
four documented statements that were false. Nothing safety-critical was touched. The
reviewer had already confirmed, empirically, that the deletion boundary refused eight
attacks with no canary lost, that the registry stayed consistent at 2, 8 and 16
concurrent writers and against a live GUI, that the dashboard's destructive sequence
passed, that the Lite refusal held on every real shared-credential application installed
on this machine, that log redaction held, and that 9 of 10 mutants were killed — the
survivor being a mutation of a `repeat` loop that is not behaviour-changing. None of that
is refactored here.

That count was written as "all four" until v1.2.3 and was wrong. Inspecting all 65 scan
candidates gives **seven** — Brave, Claude, Chrome, Keeper, Edge, OBS and Codex — and the
refusal was re-confirmed on all seven, so the property held and only the number was
false. §00g records the correction.

Final state: `swift build` **0 warnings** from a deleted `.build`; `swift test`
**335 tests, 0 failures** (324 → 335), with **`git status` clean afterwards**;
`./Scripts/integration-test.sh` **46 checks passed** (38 → 46);
`build/LaunchAgain-1.2.2.dmg` rebuilt. The user's store was read only: 21 doctor
findings, one Full instance, and `registry.json` and `icon-cache/directory-sizes.json`
carry the same modification times before and after.

### 00a. B1 — `duplicate` minted a Lite launcher from an inferred acknowledgement

`acknowledgementAlreadyGiven` read `registry.instance(id)?.instance.mode == .lite`. That
is a state, not a record of consent: an instance is Lite if it was created Lite *and
acknowledged*, but also if it predates the gate, or if a registry says so for any other
reason. `duplicate` is a one-click menu item with no card
(`InstanceDetailView.swift:170`) and it produces a **new** launcher, so it was minting
Lite instances of shared-credential applications from an acknowledgement nobody had
given.

Severity, stated so it is not overread: this branch has never been released and the
user's only instance is Full, so there was no pre-gate population to exploit. It is fixed
because it is wrong before distribution.

The fix stores the acknowledgement instead of reconstructing it —
`Instance.acknowledgedSharedCredentialStoreAt`, written on the Lite build path at the
moment the user accepts, and read everywhere the mode used to be. The Full path never
writes it even when a caller passes an acknowledgement, so the Bl-1 failure — a caller
answering its own question — cannot come back through a Full instance that was later
converted. A rebuild carries the original date forward rather than re-dating it.

Six tests, in `SharedCredentialGateTests`:

| Test | What it pins |
|---|---|
| `testDuplicatingALiteInstanceWithNoRecordedAcknowledgementIsRefused` | the reproduction: a stored-Lite row with the record cleared is refused, and nothing is created |
| `testDuplicatingAnAcknowledgedLiteInstanceIsAllowed` | a real acknowledgement is copied, so this stays one click |
| `testRebuildingAnAcknowledgedInstanceKeepsTheAcknowledgementUnchanged` | rebuild does not re-prompt and does not re-date |
| `testAFullBuildRecordsNoAcknowledgementEvenWhenOneIsPassed` | Full cannot acquire consent it was not given |
| `testAnInstanceFromAnOlderRegistryDecodesAsUnacknowledged` | older registries decode to "no", not to a permissive default |
| `testRebuildingAnInstanceThatIsAlreadyLiteIsNotRefused` | the case the old shape got right, unchanged |

### 00b. Mi-a / Mi-b — the updater record was inaccurate

Writing `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` unconditionally is correct
and stays: ChatGPT declares only `SUPublicEDKey`, and Sparkle's default is to prompt on
first run. The consequence was that `changedKeys` was never empty, so the "nothing was
neutralised" branch was unreachable in the real pipeline and the marker went back onto
every clone — the exact thing Ma-1 had removed one release earlier. Separately, an app
that already declared both keys as `false` had each recorded twice, once by the removal
loop and once by the setter.

`Report` now separates `changedKeys` — an updater found and disarmed — from
`assertedKeys`, written on every clone regardless. `didAnything`, the marker and the
build note all follow the first. Each key is visited once. Three tests cover an app with
no Sparkle at all, an app with both keys already `false`, and an app with them switched
on.

### 00c. Mi-c — `create` exited 0 when every instance failed

Reproduced, then fixed and asserted through the CLI in `Scripts/integration-test.sh`
against a read-only install root, which fails every instance in a batch without needing
an unusual application:

```
✓ a create into a writable scratch root succeeds (control)
✓ a create where every instance failed exits non-zero (got 1)
✓ nothing was created by the failed batch (bundles=1, expected the 1 from the control)
✓ each failed instance is reported
```

1 is total failure and 2 is partial, so a caller can tell "none of them worked" from
"some of them did".

### 00d. Mi-d — degradation matched step names that do not exist

`isDegradable` tested `hasPrefix` against `["sign", "verify", "icon", "shim"]`. The code
throws two different vocabularies — the hand-thrown short names `"shim"`, `"clone"`,
`"move"`, `"integrity check"`, and the `tx.add` labels `Transaction` wraps failures in,
which are verb phrases. Only `"verify signature"` and `"shim"` matched. A signing failure
wrapped as `buildFailed("re-sign clone", …)` failed the build instead of degrading.

It was fail-safe rather than harmful, and it survived because the unwrapped `MALError`
cases still degraded — `Transaction` rethrows those as they are. The existing test
asserted `"sign clone"`, a step name that has never existed, so the test and the
predicate agreed with each other about a build that does not happen.

Now an exact-match set next to the error, and
`testDegradationMatchesTheStepNamesTheBuilderActuallyUses` checks every label in the Full
build path verbatim, both ways, plus the hand-thrown names and two near-misses a prefix
test would have accepted.

### 00e. Mi-e — `inspect` printed the pre-Ma-2 estimate

See §0c: `inspect` said 367 MB "per instance" for an application whose Full clone
estimate is 1.75 GB. Ma-2 had landed in the create sheet and in the plan, but not here.
All three surfaces now call `estimatedBytesPerInstance`.

### 00f. Mi-g — the suite wrote into the working tree

Six PNGs were written into `docs/evidence/` on every `swift test`, and one of them was
not reproducible. Both are fixed; see gap 1. Two consecutive renders:

```
9604b010…  c1-delete-confirmation.png
01a56a2b…  c2-window-sidebar-hidden-minimum-size.png
dcf68066…  c2-window-sidebar-shown.png
365f0541…  c3-health-list.png
c59126b9…  c4-compatibility-card-ordinary.png
8c2a4b67…  c4-compatibility-card-shared-session.png
```

identical across both runs, and `git status` clean after a full `swift test`.

### 00g. Mi-h — dead code

`readOnlyCommands` was never read. Removed; the reasoning it carried now sits on
`makeManager`, where the decision is actually made by four explicit call sites.

### 00h. B2, Ma-A, Ma-B, Mi-f — the four false statements

Each is corrected where it was made: §4 and gap 7 for the `sudo` claim, §0c and gap 6 for
the disk figures, gap 1 and `PULL_REQUEST.md` for the screen renders, and `LIMITATIONS.md`
§7 for degradation. The rule applied to all four: every number in this round was produced
by running the product and pasting its output.

---

## 0. v1.2.1 — the adversarial review round

One blocking finding, seven majors, twelve minors. Every one was reproduced in the code
first, and every fix has a test that **fails against the shape it replaced** — shown
below rather than asserted.

Final state: `swift build` **0 warnings** from a deleted `.build`; `swift test`
**324 tests, 0 failures, 0 warnings** (283 → 324); `./Scripts/integration-test.sh`
**38 checks passed**; `build/LaunchAgain-1.2.1.dmg` rebuilt.

### 0a. Bl-1 — Advanced ▸ Force Lite bypassed the gate

`updateAdvancedSettings` set `proposed.mode = .lite`; `InstanceBuilder.rebuild` derived
the acknowledgement from `instance.mode == .lite`. The gate read back its own input.

Closed at the `InstanceManager` API the interface calls:

```
testConvertingAFullInstanceToLiteIsRefusedWithoutAcknowledgement   passed
testConvertingToLiteProceedsWhenTheConsequenceIsAcknowledged       passed
```

With the pre-fix line restored (`let acknowledged = proposed.mode == .lite`), two of the
seven fail:

```
XCTAssertThrowsError failed: did not throw an error
XCTAssertEqual failed: ("lite") is not equal to ("full") — the instance was converted
                       despite the refusal
```

The fixture is **ad-hoc signed with `keychain-access-groups`**, not merely carrying it in
an `AppFacts` struct. `updateAdvancedSettings` re-scans the source with `codesign`, so a
struct-only fixture exercises nothing — the first version of this test passed against the
unfixed code for that reason, and is noted here because it is the trap.

The interface half: the detail screen shows the same warning card the create flow shows
and disables Apply until the consequence is accepted, using
`CompatibilityVerdict.requiresSharedCredentialAcknowledgement(mode:)` — now the single
definition of the rule, consulted by the create flow, the detail screen and the builder.

### 0b. Ma-1 — the updater, against a real Codex clone

```
SOURCE  /Applications/ChatGPT.app          CLONE
  Sparkle.framework/Versions/B/
    Autoupdate                  present      REMOVED
    Updater.app                 present      REMOVED
    XPCServices/Installer.xpc   present      REMOVED
    XPCServices/Downloader.xpc  present      REMOVED
    Sparkle                     present      present   (the app links against it)

clone MALEmbeddedUpdaterNeutralised:
  SUAutomaticallyUpdate, SUEnableAutomaticChecks,
  …/Sparkle.framework/Autoupdate, …/Updater.app,
  …/Versions/Current/Autoupdate, …/Versions/Current/Updater.app,
  …/Versions/Current/XPCServices/Downloader.xpc,
  …/Versions/Current/XPCServices/Installer.xpc
clone SUEnableAutomaticChecks: false
clone SUAutomaticallyUpdate:   false
clone SUPublicEDKey:           preserved

$ codesign --verify --deep --strict "<clone>"     OK
```

And it still runs: launched, still alive after 35 s, present in the window server's
foreground list, and its own log says
`[legacy-chatgpt-sparkle-updater] Finished disarming legacy ChatGPT Sparkle updater` —
it carries on rather than failing.

**What the UI now says for this application**, which is the honest half:

> LaunchAgain could not find an updater to disable in Codex. Automatic update checks are
> switched off in the copy, but some applications set their update feed from their own
> code rather than from Info.plist, and that cannot be reached from outside. If an update
> does replace an instance's numbered identity, rebuild it — the profile and the sign-in
> inside it are not affected.

That text appears because `plannedNeutralisations` inspects the *source*: ChatGPT
declares no `SUFeedURL`, so the plan does not claim one. For an application that does,
the box lists what will be removed instead.

### 0c. Ma-2 — the disk estimate

`inspect /Applications/ChatGPT.app` reports a **1.38 GB** bundle. The sheet said
"Estimated 367 MB".

Measured allocation for one real Codex clone, free space before and after, before first
run:

```
free before : 90751 MB
free after  : 89897 MB
consumed    :   854 MB
du of clone : 1.3G      du of source: 1.3G
```

So neither zero nor the full bundle. The estimate uses the **full bundle size** and says
why: APFS sharing decays as the clone is re-signed and as either copy changes, and on a
volume without cloning the build falls back to a real copy and costs all of it. For a
"will this fit" warning the conservative number is the useful one.

Both figures below are the product's own output, pasted verbatim. The previous version of
this section had them computed by hand — first 23 GB, then 1.72 GB and 110.19 GB — and
both attempts were wrong, the second one contradicting the CLI line printed four lines
further down its own page. The `create` runs were pointed at a throwaway `--root` whose
`bundles` directory had been made read-only, so the review block prints and every build
then fails: nothing was created, and the exit status was 1.

```
$ launchagain --root <throwaway> inspect /Applications/ChatGPT.app
    size           1.38 GB
  Estimated first-run disk use per Full instance: 1.75 GB

$ launchagain --root <throwaway> create /Applications/ChatGPT.app --count 1
  disk (est.)     1.75 GB after first run

$ launchagain --root <throwaway> create /Applications/ChatGPT.app --count 64
  disk (est.)     112.03 GB after first run
```

Against **90 GB** free on this volume (`df -k /`: 90,749,056 KB available), 64 instances
do not fit and the create sheet's warning fires; one instance does and it does not. The
threshold itself is asserted by `DiskEstimateTests`, not seen on screen — see gap 6.

The per-instance figure comes from `estimatedBytesPerInstance(mode:sourceBundleBytes:)`,
which all three surfaces now call: the create sheet, the create command's review line and
`inspect`. Until Mi-e, `inspect` printed the profile-only `estimatedFirstRunBytes` under
the words "per instance" — **367 MB** for the application whose clone is measured above at
1.3 GB. Ma-2 had been fixed in two places out of three.

### 0d. Ma-3 — the 16-pixel icon

`docs/evidence/ma3-near-black-pixel-counts.txt`, from the iconset extracted out of the
**shipped** `LaunchAgain.app`:

```
icon_16x16.png:       0 near-black of 256
icon_16x16@2x.png:    0 near-black of 1024
icon_32x32.png:       0 near-black of 1024
…
icon_512x512@2x.png:  0 near-black of 1048576
```

Against the previous `while size > 1` loop the test fails with
`22 opaque near-black pixels at 16px`.

### 0e. Ma-4 — the window's identity

Four assertions in `SidebarToggleRegressionTests`, against the real `RootView` in a real
`NSWindow`: named with the sidebar hidden; exactly one of title bar and sidebar carrying
it across hide/show/hide; a window restored from a persisted collapsed state coming up
named; and the same at the 960×600 minimum. Pinned to the scene-level "always hidden"
shape, three fail.

### 0f. Ma-5 and Ma-6 — the three mutations, re-run

Each mutation was re-applied to the fixed code and the suite re-run:

```
### MUTANT 1 — MALGeneratedBy guard removed
InstallLocationTests: testABundleWithoutTheGeneratedByMarkerIsRefusedEvenWhenEverythingElseMatches
    Executed 1 test, with 5 failures

### MUTANT 2 — refreshIconCaches made a no-op
BadgedIconResolutionTests: testRefreshIconCachesBumpsAllThreeCacheKeys
    Executed 5 tests, with 3 failures

### MUTANT 3 — silent deletion of an empty legacy store reintroduced
MigrationTests: testAnEmptyPreRenameStoreIsLeftInPlaceRatherThanSilentlyDeleted
                testConstructingAManagerDoesNotDeleteAnEmptyPreRenameStore
    Executed 13 tests, with 5 failures
```

Ma-5 separately: stripping a genuine launcher's `Contents/_CodeSignature` turns an
accepted uninstall into a refusal naming the missing signature — and the test asserts the
*accepted* case first, so it cannot pass vacuously. Against the `if hasSignature` shape it
fails with "did not throw an error".

### 0g. Ma-7 — the two applications, side by side

```
--- Claude.app
  ● supported  Full profile isolation — separate accounts and a separate numbered Dock icon per instance.
  first limitation: A Lite instance of this app will not be a separate account: it runs
                    the vendor-signed original, so it shares the credentials below with
                    every other copy. A Full clone has a new ad-hoc identity and does not.

--- ChatGPT.app
  ● limited  Separate profile and numbered Dock icon — but not a separate account: this
             app keeps its signed-in session outside the profile.
  first limitation: Instances of this app are not separate accounts. It keeps its
                    signed-in session outside the profile LaunchAgain redirects, so
                    signing out of one instance may sign you out of all of them,
                    including the original application.
```

Rendered: `docs/evidence/c4-compatibility-card-ordinary.png` and
`c4-compatibility-card-shared-session.png`.

### 0h. Mi-11 — read-only commands are read-only

The reviewer's own check, against the real store:

```
$ stat -f %m .../icon-cache/directory-sizes.json     1785132080
$ launchagain doctor ; launchagain scan
$ launchagain inspect /Applications/Claude.app ; launchagain list
$ stat -f %m .../icon-cache/directory-sizes.json     1785132080     UNCHANGED
```

`doctor` is included: a run with no action flag is a report, and measuring profile sizes
was persisting the cache on every one. `doctor --clean`, `--purge-profiles`,
`--retire-legacy-store` and `--clear-stale-markers` still write.

### 0i. The evidence gap, closed

`Tests/MALAppTests/ScreenRenderingTests.swift` writes six PNGs into `docs/evidence/` —
`NSHostingView` offscreen, `bitmapImageRepForCachingDisplay`, no Screen Recording
permission, reproducible anywhere the suite runs. It asserts the view mounts, lays out and
renders non-blank (counted, not assumed), and leaves the design judgement to a person.

Producing them immediately caught a defect this round introduced: the longer Ma-7 headline
truncated to "…this app keeps its sign…". Fixed, which is the argument for files over
descriptions.

**They do not show the title bar.** `NSHostingView` renders a content view and the title
belongs to the window frame, so Ma-4's evidence is §0e's assertions, not the `c2` PNGs.

### 0j. The user's store

```
$ launchagain doctor          21 findings — 5 orphaned profiles, 16 preference domains
$ launchagain list            Claude 1.24012.9 · ○ #1 Personal full 12.65 GB
$ ls ~/Applications/LaunchAgain/       Claude 1 – Personal.app
$ ls -d /Applications/LaunchAgain      No such file or directory
$ stat registry.json                   2026-07-26 21:15:54
```

Unchanged, and the registry's modification time still predates the v1.2 session.

---

## 1. B1 — an instance inherited the original's signed-in session

### 1a. Which mode the user's instance was: **Full**

From the user's own log, read but not modified:

```
2026-07-26T00:43:23Z INFO  signing 84 nested items inside 562D3068-…-ChatGPT 1.app
2026-07-26T00:43:42Z INFO  built instance #1 ChatGPT 1 at ~/Applications/LaunchAgain/ChatGPT 1.app
2026-07-26T08:23:05Z INFO  signing 84 nested items inside D564BEDC-…-ChatGPT 1.app
2026-07-26T08:32:11Z INFO  signing 84 nested items inside BF4C8F18-…-ChatGPT 1 – d.app
```

84 nested items is a cloned Electron bundle; a Lite launcher has none. Three ChatGPT
instances, all Full.

### 1b. Does a Full clone start signed in? **Yes.**

Built into a throwaway root. The clone's entitlements were verified stripped first —
no `keychain-access-groups`, no `com.apple.security.application-groups`, no
`com.apple.developer.team-identifier`, `Signature=adhoc`, `TeamIdentifier=not set`. Then
run with its own `--user-data-dir`:

```
[chatgpt-account-lookup] completed authenticatedAccountPresent=true authMethod=chatgpt
                         result=succeeded
[AppServerConnection] method=thread/read conversationId=019e28df-7cb5-7340-be1e-43e424110495
[AppServerConnection] method=thread/read conversationId=019df134-f83d-7a20-8e88-0afc85bb9aa1
```

Signed in, with the user's own conversation threads.

The profile redirect itself works — the clone logged
`Requested '…/Application Support/Codex', selected '<instance>/userdata'` — so the
Chromium profile *is* separate. The session simply is not in it.

### 1c. Where the session actually is: `$CODEX_HOME`, not the Keychain

`lsof` on the running clone showed it holding `~/.codex/state_5.sqlite`,
`~/.codex/memories_1.sqlite`, `~/.codex/goals_1.sqlite` and `~/.codex/sqlite/codex-dev.db`
— all under the real home directory, none under the instance.

The decisive test. The **same clone**, same `--user-data-dir`, launched with
`CODEX_HOME` pointing at an empty scratch directory:

```
[electron-fetch-wrapper] desktop_fetch_auth_401 hadToken=false
                         skipRetryReason=no_token_attached tokenSource=cached
                         target="GET https://chatgpt.com/backend-api/wham/tasks/list"
```

Signed **out**. No `auth.json` was created in the scratch home. The real
`~/.codex/auth.json` was untouched throughout — mtime `Jul 26 21:17`, before this work
started.

So the mechanism is `$CODEX_HOME/auth.json`, read by the bundled `codex` app-server by
absolute path. Not the Keychain and not the App Group container, which is a **correction
to the brief's premise** and is why the detection covers three signals rather than two.

### 1d. Lite mode

Not tested by launching, and deliberately. A Lite launcher runs
`/Applications/ChatGPT.app` itself — the vendor-signed binary, with the vendor's Keychain
groups, the vendor's App Group containers and the same `$CODEX_HOME`. That it shares the
session is a property of the binary's signature and of the path it reads, both established
above; running a second copy of the user's signed-in ChatGPT to confirm it risked exactly
the loss this task exists to prevent, and the brief said to stop rather than take that
risk. **Lite is refused for these apps**, which is the outcome either way.

### 1e. The refusal and the acknowledgement, exercised

```
$ launchagain --root "$R" create /Applications/ChatGPT.app --count 1 --lite --names LiteProbe
error: Lite mode cannot isolate Codex. A Lite launcher runs the vendor-signed original
application, so it has the original's Keychain identity, the original's App Group
containers and the original's home-directory configuration — every place this app's
session actually lives. The likely result is an instance that is already signed in, and
signing out of it signs out every copy including the original. Detected:
keychain-access-groups, com.apple.security.application-groups (~/Library/Group Containers),
~/.codex.

Create it in Full mode instead, or pass --acknowledge-shared-credentials to accept that
consequence.
$ echo $?
1
$ ls "$R/bundles"          # empty — nothing was created

$ launchagain --root "$R" create /Applications/ChatGPT.app --count 1 --lite \
      --acknowledge-shared-credentials --names Acked
  ✓ #1 Acked [lite]
```

### 1f. The card changes

`launchagain inspect /Applications/ChatGPT.app`, first three limitations, in order:

```
· Instances of this app are not separate accounts. It keeps its signed-in session outside
  the profile LaunchAgain redirects, so signing out of one instance may sign you out of
  all of them, including the original application.
· keychain-access-groups — Credentials this app saves in the Keychain belong to the
  vendor's signing identity, not to the profile. …
· com.apple.security.application-groups (~/Library/Group Containers) — An App Group
  container is an ordinary directory in your Library. macOS only restricts it for
  sandboxed apps …
· ~/.codex — This app reads its signed-in session from ~/.codex by absolute path. …
· There is a route out for this one: set CODEX_HOME to this instance's own directory …
```

Tests: `SharedCredentialStoreTests` (9), `CompatibilityCardTests` (3), and four in
`BuildPipelineTests` covering the refusal, the acknowledgement, that Full is *not*
refused, and that automatic degradation cannot become a silent Lite build.

---

## 2. B2 — the numbered badge

Four candidate causes, taken in turn against a real ChatGPT clone.

| Candidate | Verdict |
|---|---|
| The asset catalogue still supplying the icon | **No.** The clone declares `CFBundleIconFile = MALAppIcon` with `CFBundleIconName` removed; `Assets.car` is still present and does not win. |
| The generated `.icns` written but not referenced | **No.** `docs/evidence/b2-chatgpt-clone-generated-icns.png` — correct at every size. |
| Launch Services resolving the wrong icon | **No.** `docs/evidence/b2-chatgpt-clone-icon-as-macos-resolves-it.png` is what `NSWorkspace.icon(forFile:)` returns for the clone: the badge is there. `NSRunningApplication.icon` for the live clone agrees. |
| The app setting its own Dock icon at runtime | **Yes, and it is not fixable from outside.** `app.asar` contains `… l.app.dock?.setIcon(s)`, driven by a `DOCK_ICON_PREFERENCE` setting, resolving a resource name like `icon-chatgpt`. |

A fifth cause is real and *is* ours: IconServices caches by path, so an instance created
where a previous one lived could show the old icon. Fixed — every install now goes through
`refreshIconCaches`, which bumps the modification date of the bundle, its `Info.plist`
and its `.icns` (three separate cache keys) and re-registers.

### Confirmed in the Dock

A Codex instance was created through the GUI, launched, and the Dock was looked at.

**The running instance's Dock tile is the vendor's own icon, with no number on it** — a
purple Codex mark, not the ChatGPT flower the bundle carries and not the badged icon
LaunchAgain generated. Beside it, LaunchAgain's own tile shows the new v1.2 icon
correctly, which rules out "the Dock is not showing anyone's icon properly".

So the diagnosis is complete and matches the source reading exactly: the app replaces its
own Dock icon after launch, and nothing outside the app can stop it. Meanwhile the same
instance's icon **in the list, in Finder and in Spotlight is badged** — visible in the
dashboard screenshots, where the Codex row and the two Kimi rows all carry their numbers.

That is the honest end state, and LIMITATIONS §5b states it: the file icon is ours and is
correct, the running Dock tile belongs to the application.

Tests: `BadgedIconResolutionTests` (3). One reuses a bundle path with a different badge
colour and asserts the new icon wins. One asserts a real asset-catalogue app's clone does
not resolve to the *vendor's* icon. Neither claims "resolves to exactly the generated
`.icns`": macOS composites an ad-hoc-signed clone onto a different backdrop from a
notarised application, two earlier versions of that assertion measured the compositing
rather than the badge and failed against a clone whose icon was correct, and the rendered
comparison is in `docs/evidence/` where a human can judge it instead.

---

## 3. B3 — instances do not update themselves

Against a **real** Squirrel application, not a fixture:

```
$ launchagain --root "$R" create "/Applications/LM Studio.app" --count 1 --names NoSelfUpdate
  ✓ #1 NoSelfUpdate [full]

source  Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt   present
source  Contents/Resources/app-update.yml                                    present
clone   Contents/Frameworks/Squirrel.framework/Versions/A/Resources/ShipIt   ABSENT
clone   Contents/Resources/app-update.yml                                    ABSENT
clone   Contents/Frameworks/Squirrel.framework                               present
clone   MALEmbeddedUpdaterNeutralised                                        true

$ codesign --verify --deep --strict "<clone>"   →  codesign OK
```

And it still launches: run from `/Applications/LaunchAgain`, still running after 30 s,
normal startup log, no updater complaint, no missing-`ShipIt` error.

Tests: 6 in `BuildPipelineTests` — ShipIt and `app-update.yml` removed from a bundle while
the framework stays; a no-updater bundle unchanged; an electron-updater clone losing its
config while the source keeps it; a Sparkle clone with no feed, automatic checks false and
the feed preserved under `MALOriginalSUFeedURL` while the source keeps its own; the opt-out
restoring both shapes; and rebuild-available detection plus profile preservation surviving
neutralisation.

---

## 4. B4 — /Applications

### 4a. What LM Studio actually checks

Read out of its own bundle: `if (!0x0 !== this['installLocation']['startsWith']('/Applications/')) throw …`
in `ChipmunkUpdater.installStagedUpdate`, and a separate launch-time check behind the
string `App is not running from /Applications. It is running from `.

Measured, not inferred. A clone in a scratch directory:

```
22:18:45 › App is not running from /Applications. It is running from
           /private/tmp/…/bundles/LM Studio 1 – LocTest.app/Contents/Resources/app
```

…and 0 windows. The process stays alive and the application never appears — which is what
"refuses to run" looks like.

The **same clone** copied to `/Applications/LaunchAgain/`:

```
[CachedFileDataProvider] Watching file at /Users/…/.lmstudio/settings.json
[VersionMigrationProvider] Current app version: v0.4.19-b2
[FindExistingServer] …
```

No location complaint. So the check is a literal `/Applications/` prefix and one owned
subdirectory satisfies it — which is why the design is a single owned directory rather
than launchers loose in `/Applications`.

### 4b. End to end, through the tool

`--system-bundles-dir` is a testing facility that only applies with `--root`, so it can
never change where the shipping configuration installs anything. It is what made this
runnable without writing into the user's store:

```
$ launchagain --root "$R" --system-bundles-dir /Applications/LaunchAgain \
      create "/Applications/LM Studio.app" --count 1 --names AppsFolder
  install to      /Applications/LaunchAgain
  ✓ #1 AppsFolder [full]

$ ls -d /Applications/LaunchAgain/*.app
/Applications/LaunchAgain/LM Studio 1 – AppsFolder.app

$ launchagain … launch 1        ✓ launched #1 AppsFolder (pid 44925)
   still running after 35 s, and present in the window server's foreground list

$ launchagain … list            ○ #1  AppsFolder  full
$ launchagain … doctor          ✓ Everything is consistent.
$ launchagain … delete 1        ✓ uninstalled #1 and all LaunchAgain-owned data
   /Applications/LaunchAgain afterwards: empty
```

`/Applications/LaunchAgain` was removed afterwards and is absent on this machine.

### 4c. The boundary did not widen further than one directory

`InstallLocationTests`, 13 tests. The ones that matter to a reviewer:

- a `.app` in the **parent** of the system root — i.e. loose in `/Applications` — is
  refused by `assertDeletable`, by `assertLauncherBundlePath`, and by the sweeper's own
  removal path, and is still on disk afterwards;
- neither root is itself deletable;
- a launcher nested one directory deeper than an immediate child is refused;
- an `installRoot` that is not one of the two owned roots is refused and the directory is
  not written to;
- reconciliation recovers instances from **both** roots after a lost registry;
- the health check sees a stranded launcher in the system root;
- an instance in the system root uninstalls completely;
- a rebuild keeps an instance in the root it is already in;
- an existing instance keeps working with **no system root on disk at all**;
- an unwritable system root fails with a message that names the directory and says who
  can grant access, and never offers the fallback the interface does not provide.

**On the word `sudo`, which this section used to claim never appeared.** It does, in one
of the two branches, and the claim was false as written. The branch matters:

- **`/Applications/LaunchAgain` does not exist and cannot be created** — the message asks
  for an administrator to create it. No command is suggested and `sudo` does not appear.
  `InstallLocationTests.testAnUnwritableSystemRootFailsWithAnActionableMessage` asserts
  its absence here.
- **`/Applications/LaunchAgain` exists and is read-only** — the likelier real case, and
  the one the earlier claim overlooked. The message suggests
  `` `sudo chown -R $(whoami) /Applications/LaunchAgain` ``.

That suggestion is kept, and the documents now describe it accurately instead of denying
it. Printing a command for someone to read and decide about is not the same act as
running one. LaunchAgain does not escalate: `ProcessRunner.Tool` enumerates every
executable it will ever launch, by absolute path, and `sudo` is not among them — asserted
by `InstallLocationTests.testTheProductNeverRunsAPrivilegedTool`. The message says so in
its own words: *"LaunchAgain does not ask for administrator rights, does not install a
helper tool and does not run any command for you."*

`InstallLocationTests.testAnExistingReadOnlyRootSuggestsACommandAndSaysItWillNotRunIt`
asserts the exact command, that `sudo` occurs exactly once and only inside it, and that
the disclaimer is present. `Scripts/integration-test.sh` — which had no check here at all
— now provokes the same failure through the CLI, against a real read-only install root,
and asserts the same four properties.

---

## 5. B5 — uninstall completeness, re-measured

A real ChatGPT clone: created, run for a minute, uninstalled. `--user-library` (a testing
facility, gated on `--root` like the one above) put the artifact cleaner in scope of the
real Library while the store stayed in a throwaway root.

**What it wrote outside its profile — four paths, all keyed to the generated identifier:**

```
~/Library/Preferences/com.openai.codex.mal1-1bb5ece1.plist
~/Library/Caches/com.openai.codex.mal1-1bb5ece1
~/Library/HTTPStorages/com.openai.codex.mal1-1bb5ece1
~/Library/HTTPStorages/com.openai.codex.mal1-1bb5ece1.binarycookies
```

**After `delete`:**

```
removed: …/Preferences/com.openai.codex.mal1-1bb5ece1.plist
removed: …/Caches/com.openai.codex.mal1-1bb5ece1
removed: …/HTTPStorages/com.openai.codex.mal1-1bb5ece1
removed: …/HTTPStorages/com.openai.codex.mal1-1bb5ece1.binarycookies
removed=4 left=0
```

A sweep of every Library subdirectory the cleaner knows about found nothing else naming
that identifier, and the scratch root had no launcher, no profile and no registry row left
(`doctor`: *Everything is consistent*).

**What survived, correctly:** `~/Library/Logs/com.openai.codex` — the **vendor's**
directory, shared with the original application. Deleting it would have removed the
original's logs. `~/.codex` likewise, and removing that would have signed the user out of
every copy. Both are now documented in LIMITATIONS rather than being an unexplained
absence, and both have tests: one builds both families of artifact and asserts the sweep
takes exactly the instance's own, the other walks the whole candidate list and asserts no
vendor group container can appear in it.

---

## 6. A1–A3

**A1.** Two tests hold an exclusive `flock` on `registry.json.lock` from a separate file
descriptor — which is what a different process looks like to the kernel — and assert the
corrupt-recovery and `.bak`-recovery writes block until it is released. Both **fail
against the previous code** (`success` where `timedOut` was required) and pass against
this one.

**A2.** With every removal made to fail:

```
  ✗ …/instances/7B96347A-…: couldn't be removed because you don't have permission
  ✗ …/instances/15693A4E-…: couldn't be removed because you don't have permission

✗ nothing was removed: all 2 profile(s) failed. Nothing was freed.
$ echo $?
1
```

and on success, `✓ removed 2 profile(s)`, exit 0, with the "run `--purge-profiles`" hint
no longer printed after a `--purge-profiles` run.

**A3.** Eight real `create` processes against a scratch root:

```
✓ every concurrent create process reports success (8/8)
✓ registry rows, launcher bundles and profiles all agree (rows=8 bundles=8 profiles=8)
✓ every concurrently created instance has a distinct number (distinct=8 of 8: 1 2 3 4 5 6 7 8)
✓ no number reservation is left held after the race
```

The writers spin on a barrier file rather than being started in a plain loop, and that is
the difference between a check that passes and a check that means something. Against a
build with the cross-process lock, the disk reload and the durable reservations removed,
the staggered form still reported 8 rows and 8 bundles — while the barrier form produced
**8 launchers, 8 profiles, 1 registry row and eight instances all numbered #1**, which is
the original failure exactly.

---

## 7. Build, tests, and the user's store

```
$ rm -rf .build && swift build
Build complete!            0 warnings

$ swift test
Executed 283 tests, with 0 failures        (241 before this pass)
  new suites: SharedCredentialStoreTests, InstallLocationTests,
              BadgedIconResolutionTests, CompatibilityCardTests

$ ./Scripts/integration-test.sh
All integration checks passed.             38 checks (34 before this pass)
```

### The user's store — read-only, and it stayed that way

```
$ ls -la ~/Library/Application\ Support/LaunchAgain/registry.json
-rw-r--r--  2776  Jul 26 21:15
```

**21:15, before this session began.** Nothing in this pass wrote to it.

```
$ launchagain list
Claude  1.24012.9
  ○ #1  Personal  full  12.65 GB

$ ls ~/Applications/LaunchAgain/
Claude 1 – Personal.app

$ ls -d /Applications/LaunchAgain
No such file or directory
```

`doctor` reports **21 findings: 5 orphaned profiles and 16 stranded preference domains,
and no stale removal marker.**

The brief expected 24 — 8 profiles, 15 domains, 1 marker. **That is not this pass's
doing, and the difference is worth stating precisely rather than glossing.** The user's
own log shows three ChatGPT instances created on 26 July at 00:43, 08:23 and 08:32, after
the v1.1 validation was written; those account for domains appearing, and the marker and
three profiles going are consistent with the user acting on `doctor`'s own advice. The
registry's modification time of 21:15 that same day, before this session, is the
independent check: whatever changed, this pass did not change it.

**What this pass *did* add to the user's Library, and removed again.** Four probe
instances ran under the real `HOME` from throwaway roots, which is the documented
`--root` leak (§8.4). They left four preference domains — mtimes 22:19, 22:29, 23:11,
23:21, all after this session began — and one clone's caches. Every one is named here and
every one was removed afterwards with `defaults delete` and an exact `rm`:

```
ai.elementlabs.lmstudio.mal1-129aec27      ai.elementlabs.lmstudio.mal1-bacc20ba
ai.elementlabs.lmstudio.mal1-55b64519      com.openai.codex.mal1-09994784
```

The 21 findings above are the count *after* that cleanup.

---

## 7a. The interface, driven

Every changed screen was operated against a **throwaway store**
(`LAUNCHAGAIN_ROOT`), seeded with two Kimi instances, a 320 MB profile, two orphan
profiles and a duplicate launcher. The user's own store was never opened by the GUI.

| Screen | What was observed |
|---|---|
| **C2** — window identity | No title text in the title bar. The icon, "LaunchAgain" and "1.2" at the top of the sidebar. Three columns reading as one window, with the sidebar shown. |
| **C1** — delete confirmation | Title, "What this removes" as three rows with the profile's 320.1 MB against its own row, the Trash promise on its own line, "What stays exactly as it is", the typed field, and **Uninstall Instance disabled** until `delete` is typed. Cancelled; nothing was deleted. |
| **C3** — health | One line per finding with a short summary, size, a single action and the path as secondary text. Footer: "1 item can be removed safely — 1.04 GB" and **Delete All Safe Items…**. |
| **C4** — create flow | All five steps. Default is **1**, highlighted. "Estimated 367 MB · Free on Macintosh HD 111.77 GB" under the control. Custom reveals the stepper. The review step carries the new **Updates** group box and its advanced opt-out, off. |
| **B1 gate, live** | Ticking *Force Lite mode* on ChatGPT revealed the warning and **disabled Continue**; ticking the acknowledgement re-enabled it. |
| **C5** — app icon | Verified **in the real Dock**, not only as a rendering. |

Two things this closed that were open in v1.1:

- **The create sheet was driven through a real clone** for the first time — a ChatGPT
  instance, ten stages, a determinate bar, and no Cancel button while building. v1.1
  gap 6 said this was verified by reading the view; it is now verified by operating it.
  (Ten stages, not nine: the tenth is B3's *stop this instance updating itself*.)
- **The conflict path fired for real.** The duplicate launcher seeded for the health
  screen produced *"Multiple verified launchers claim instance 65F1AF1C-…. None was
  used."* — reconciliation refusing to adopt an ambiguous duplicate, in the product
  rather than in a test.

The screenshots live in the session transcript. They could **not** be written into
`docs/evidence/` — this process has no Screen Recording permission, so `screencapture`
fails, and the capture surface that does work does not expose a file path. The generated
icon is the exception and its renderings are committed.

---

## 8. Known gaps and residual risk

1. ~~**The C1–C4 screenshots are not files in the repository.**~~ **Closed in v1.2.1.**
   `ScreenRenderingTests` renders them with no permission required. What those renders do
   *not* contain is the window's title bar — `NSHostingView` renders a content view — so
   Ma-4's evidence is its four assertions in `SidebarToggleRegressionTests` rather than an
   image (§0e).

   Two things about them changed in 1.2.2. They are written to `.build/screen-renders/`
   and copied into `docs/evidence/` only under `MAL_WRITE_EVIDENCE=1`
   (`Scripts/render-evidence.sh`), because a suite that dirties the working tree as a
   side effect of passing makes a stale committed image indistinguishable from a fresh
   one. And `c3-health-list.png` is byte-stable now: its fixture used `UUID()`, which was
   rendered into the findings, so the image came out a different size on every run —
   which made the 1.2.1 claim that these renders are "reproducible anywhere the suite
   runs" untrue of that one file. Two consecutive runs now produce identical checksums
   for all six.

1a. **The interface has still only been *driven* by hand once**, in the v1.2 session
   (§7a). The v1.2.1 changes to the create flow, the detail screen and the health footer
   are covered by tests and by rendered stills, not by someone clicking through them.

2. **Reboot persistence is still NOT VERIFIED.** The machine was not restarted. Unchanged
   from v1.1, and unchanged for the same reason.

3. **Lite mode against ChatGPT was reasoned about, not run.** §1d. The conclusion — that a
   Lite launcher shares the session — follows from the binary's signature and from the
   `CODEX_HOME` measurement, and Lite is refused for such apps either way, but no Lite
   ChatGPT instance was launched.

4. **A `--root` instance still leaks its preference domain**, and this pass demonstrated
   it five times before cleaning up — four probes plus the Codex instance created through
   the GUI for the screenshots, whose domain and caches were removed the same way. Unchanged from v1.1 gap 2, still a testing-facility
   problem rather than a normal-use one.

5. **`--system-bundles-dir` and `--user-library` are new testing facilities.** Both are
   refused without `--root`, so neither can alter the shipping configuration, but they are
   two more flags that exist for this document's benefit and a reviewer is entitled to
   count that as surface.

6. ~~**The create flow's disk warning was never seen** … no count available in the
   interface can trigger it here.~~ **This was wrong, and it was wrong because of a bug
   it was reasoning from.** The 23 GB figure came from multiplying the *profile*
   estimate by 64 while ignoring the copy of the application — the Ma-2 defect. With the
   clone included, 64 instances of ChatGPT come to **112.03 GB** against 90 GB free and
   the warning fires; one comes to **1.75 GB** and it does not. §0c has both figures as
   the product printed them, and the measured allocation.

   The correction itself then had to be corrected: the first rewrite of §0c said 1.72 GB
   and 110.19 GB, worked out by hand, and contradicted the CLI line quoted on the same
   page. Every number in that section is now generated by running the product and pasted
   verbatim. The warning has still not been *seen on screen*: the threshold is asserted
   by `DiskEstimateTests`, not rendered.

7. **The `/Applications` permission failure was tested against a synthetic unwritable
   path, not against a Mac where the user is not an admin.** The account here is an
   admin, so the real failure was never provoked. Both branches of the message are now
   asserted — by unit test and by `Scripts/integration-test.sh` against a real read-only
   install root — including the `sudo chown` suggestion in the exists-but-read-only
   branch, which §4 previously and wrongly said never appeared.

8. **The measured tables have one entry each.** `knownConfigHomes` names ChatGPT;
   `knownSystemApplicationsRequirements` names LM Studio. Both are honest — each was
   measured — and both are narrow. An app with the same problem and a different
   identifier gets nothing, and there is no generic detection for either because both
   checks live inside the applications' own code.

9. **The badge is confirmed absent from a running ChatGPT instance's Dock tile**, which
   is the expected outcome rather than an open question — §2. It is listed here because it
   is a limitation a user will notice: for an app that sets its own Dock icon, the number
   appears everywhere except the tile of the running app.

10. **The B2 automated test asserts "not the vendor's icon", not "exactly the generated
   icon".** §2, with the reason. The stronger claim rests on a rendered image in
   `docs/evidence/`, judged by eye.

11. **Rebuild resets `--allow-self-update`.** The opt-out is not recorded on the instance,
    so a rebuild returns it to the non-self-updating default. Documented in LIMITATIONS §5;
    it is a deliberate choice to keep the model unchanged, not an oversight, but it is a
    wart.

12. **The DMG is ad-hoc signed and not notarised.** Unchanged, and stated by the packaging
    script itself.

13. **Two tests were deleted with the code they covered in v1.1** and have not come back.
    Unchanged from that pass's gap 8.

14. **A pre-existing test is intermittently flaky.**
    `BuildPipelineTests.testLockFileRequiresTheExpectedProfileAndClearsAReusedPID` failed
    once in a full-class run during this round and passed on six subsequent runs, three
    in isolation and three in class context. It detects PID reuse, which is inherently
    timing-sensitive. It was **not** touched — weakening a test to make a run green is
    exactly what the rules forbid — so a reviewer may see it fail once.

15. **Withdrawn as a duplicate of gap 11**, which states the same `--allow-self-update`
    limitation. The number is kept so the surrounding references do not shift.

16. **The App Group signal is classified from an absence of evidence.** It is marked as
    not affecting Full mode because macOS does not vend the container to a clone whose
    entitlement was stripped, and because it was measured not to be the mechanism for
    ChatGPT. Neither of those proves that no application reaches its group container by
    absolute path. The consequence text says so; the classification could still be wrong
    for an app nobody has tested.

17. **`doctor`'s finding count is 21 here, not the 24 the brief expected.** §7 explains
    why and shows the registry mtime that rules this pass out as the cause. A reviewer
    checking for "unchanged at 24" will see 21.
