# v1.2.5 — isolation correctness, install location, and interface quality

**This is v1.2 plus four adversarial review rounds.** The first: one blocking finding,
seven majors and twelve minors. The second, a closing pass: two code defects, six minors,
and four documented statements that were false. The third found no code defect and
recommended merge; one item it filed as documentation turned out to be a real dead end,
and that is v1.2.3. The fourth found two code defects in that fix and four more sentences
that outran their measurement, and that is v1.2.4. Every finding in all four rounds was
reproduced in the code before it was fixed, and every fix carries a test that fails
against the shape it replaced. The header below describes the v1.2 body of work; the
remediation is summarised here and evidenced in
[VALIDATION §000, §00 and §0](VALIDATION.md).

v1.2.3–1.2.4 in one paragraph: a Lite instance recovered from a manifest-less launcher
carries no acknowledgement, because recovery has no evidence anyone was asked. v1.2.2
gated every rebuild on one, so those instances could not be rebuilt or renamed from the
command line, and the GUI enabled Apply and then threw. The gate now asks whether a build
*introduces* a shared session rather than whether one exists — read from the shim config
on the launcher itself, not from the registry row, because a row edited to say Lite over a
Full clone would otherwise convert that clone into one that shares the vendor's Keychain
items. The permission is a separate field from the acknowledgement, because folding them
together would stamp a consent date for a user who was never asked and reopen round 3's
blocking finding through `duplicate`. Eight documented statements were corrected across
the two versions, including the count of real shared-credential applications, which is
seven and was written as four.

**A reviewer should read [VALIDATION §000f](VALIDATION.md) first.** It records what round
5 found, including the two places the previous version's own documents were wrong about
the population they described, and the one place the brief written for that round steered
the reviewer away from the finding.

The closing round's two code defects are worth naming here. `duplicate` inferred the
shared-session acknowledgement from `mode == .lite` and so could mint a new Lite launcher
for a shared-credential application from consent nobody had given; the acknowledgement is
now stored as a fact about what the user was shown, not reconstructed from a state that
has several origins. And the updater record had started counting two keys it writes on
*every* clone as an updater found and disarmed, which put the marker back on every clone
— the failure the previous round had just removed.

Nothing safety-critical moved: the deletion boundary, the concurrency model, the Lite
refusal and the sweeper guards are untouched, and the reviewer's own empirical results
for all four still stand.

## The blocking one

Advanced ▸ Force Lite ▸ Apply converted a Full instance to Lite with **no warning card,
no acknowledgement and no refusal** — for an application the product had already detected
as keeping its signed-in session outside the redirected profile. `updateAdvancedSettings`
set `proposed.mode = .lite`, `InstanceBuilder.rebuild` derived the acknowledgement from
`instance.mode == .lite`, and the gate read back the flag the caller had just set. Three
clicks from the dashboard, and exactly the loss v1.2 exists to prevent.

Fixed so the shape cannot be written again rather than by adding a check: the
acknowledgement is an explicit parameter, and it is only ever inferred from the **stored**
record. The rule has one definition now —
`requiresSharedCredentialAcknowledgement(mode:)` — which the create flow, the instance
detail screen and the builder all consult. Seven tests at the API the interface calls;
against the pre-fix line, two fail with *"the instance was converted despite the refusal"*.

## The seven majors, briefly

- **Ma-1** The updater promise was false for the app this release is about. ChatGPT
  declares only `SUPublicEDKey`, so nothing was neutralised, the marker recorded `true`
  anyway and the UI promised otherwise. The marker records what was done and is absent
  when nothing was; Sparkle's installer chain is removed as Squirrel's `ShipIt` already
  was, verified on a real Codex clone that still signs and still launches; and the UI says
  what it actually did, including "we could not find one".
- **Ma-2** The disk estimate ignored the copy of the application, so the free-space
  warning could not fire at any count. Measured: 854 MB of real allocation for a 1.38 GB
  bundle. Fixed conservatively, and said so.
- **Ma-3** The 16×16 application icon drew an unstyled black blob — and shipped in the
  DMG. Every size is checked now, not just 512.
- **Ma-4** Collapsing the sidebar removed the window's name from the screen entirely.
- **Ma-5** Deleting a bundle's `_CodeSignature` made it *easier* to delete. A signature is
  now required and validated on the uninstall path, as the sweeper already did.
- **Ma-6** Three mutants survived all 283 tests. Each now fails, with the failure shown.
- **Ma-7** The compatibility card claimed and denied separate accounts on one screen for
  Claude. Each signal is qualified by the mode it actually bites in.

## What a reviewer should check first

[VALIDATION §8](VALIDATION.md). **Gap 6 was wrong last round** — it argued the disk
warning was untriggerable, reasoning from the very number Ma-2 was about — and it is
struck through and corrected rather than quietly rewritten. Gap 1 is closed: the screens
are files now. Three new gaps are recorded, including a pre-existing flaky test that was
deliberately **not** touched.

---

# v1.2 — isolation correctness, install location, and interface quality

**Branch:** `hardening/completion-pass` → `main`
**Baseline for this pass:** `496d032`, the end of the v1.1 hardening pass.
`git log --oneline 496d032..HEAD` is the change set. There is no git remote on this
machine, so this file stands in for the PR description.

| Commit | What |
|---|---|
| `bd903af` | **A1** — the two startup recovery writes take the registry lock |
| `82f465e` | **A2** — `doctor` stops reporting a destructive run it did not perform |
| `98f34a4` | **A3** — race real `create` processes in the integration suite |
| `7c04ac2` | **B1** — detect apps whose session lives outside the profile |
| `abc45bd` | **B3** — stop an instance updating itself out of its own identity |
| `f41445b` | **B4** — a second launcher home, in `/Applications` |
| `19de82b` | **B5** — measure what a clone leaves behind; widen the sweep |
| `4446e47` | **B2** — diagnose the missing badge |
| `6dd33d2` | **C5** — the launcher's own icon |
| `1c38c3b` | **C1/C4** — delete confirmation, create-flow defaults and disk estimate |
| `ed0a249` | **C2/C3** — window identity, health rows |

**Verification (v1.2.5):** `swift build` **0 warnings** from a deleted `.build`;
`swift test` **347/347, 0 warnings** (241 → 283 → 324 → 335 → 341 → 344 → 347), with **`git status`
clean afterwards** — the suite no longer writes into the working tree;
`./Scripts/integration-test.sh` **46 checks**, unchanged;
`build/LaunchAgain-1.2.5.dmg` rebuilt. The user's store was read only: `registry.json`
and `icon-cache/directory-sizes.json` are byte-identical before and after, with unchanged
modification times. The v1.2.3 behaviour was additionally driven end-to-end through the
CLI against a throwaway `--root` store — see [VALIDATION §000d](VALIDATION.md).

---

## The one that matters

A user created a ChatGPT instance, it came up already signed in, they signed out of it,
and **every copy of ChatGPT on the machine signed out, including the original.**

The measurement is in [VALIDATION §1](VALIDATION.md). Briefly: their instances were Full
clones. A Full clone with every team-bound entitlement stripped and an ad-hoc signature
*still* started signed in and loaded their own conversation threads — and the same clone
started signed out when `CODEX_HOME` pointed at an empty directory. So the session is not
in the Keychain and not in the App Group container, which is where the brief expected it.
It is `$CODEX_HOME/auth.json`, a plain file in the home directory read by the bundled
`codex` app-server by absolute path, which `--user-data-dir` does not touch.

The product now detects that class of application, leads the compatibility card with
**"these will not be separate accounts"**, names the consequence, points at the one route
out that was measured — set `CODEX_HOME` per instance — and **refuses Lite mode** unless
you acknowledge the consequence in words. Automatic degradation from a failed Full build
is refused on the same terms, because degrading silently into the mode that was just
refused is how the sessions were lost. Nothing reads, copies or writes the Keychain.

## What else changed

**Instances no longer update themselves out of their own identity.** A clone's own
Squirrel or Sparkle updater replaced `Contents` wholesale and took the numbered identity,
the icon, the shim and the signature with it. `ShipIt`, `app-update.yml` and Sparkle's
feed are removed from the clone by default; Rebuild remains the only update path and still
keeps the profile. Verified against a real LM Studio clone, which still passes
`codesign --verify --deep --strict` and still launches.

**Launchers can live in `/Applications/LaunchAgain` when an app demands it.** LM Studio
tests its install location against the literal prefix `/Applications/` and opens no window
when the test fails — measured, both ways. There are now exactly **two** named launcher
roots and every ownership question answers from that fixed list; `assertDeletable` widened
by one directory and did not become a rule about `/Applications`. A bundle sitting beside
our directory is refused three ways, with a test for each.

**Uninstall completeness, re-measured** against a real ChatGPT clone. Four real-Library
artifacts, all keyed to the generated identifier, all removed, nothing left naming it —
and the things that are deliberately *not* removed (`~/Library/Logs/<vendor-id>`,
`~/.codex`) are now stated rather than an unexplained absence, because removing the second
would sign the user out of every copy.

**The badge** was diagnosed rather than guessed at. The generated icon, the plist rewrite
and Launch Services resolution are all correct for an asset-catalogue app — rendered in
`docs/evidence/`. Of the two remaining causes, the one that is ours (IconServices caching
by path) is fixed; the one that is not (ChatGPT calling `app.dock.setIcon` from its own
code) is documented as a limitation instead of being papered over with a fix that would
not work.

**Interface**: the delete confirmation, the create flow's default of one instance and its
disk estimate, the window's identity, one action per health row, and the application icon.

## Read this before approving

[VALIDATION §8, *Known gaps and residual risk*](VALIDATION.md).

**Gap 1 is closed.** The C1–C4 screens are rendered to PNGs and committed under
`docs/evidence/` — six of them, from `ScreenRenderingTests`, which mounts each view in an
offscreen `NSHostingView` and needs no Screen Recording permission. They are byte-stable:
every identifier a screen displays is fixed, so two runs produce identical files, and
`Scripts/render-evidence.sh` regenerates them. `swift test` writes only to
`.build/screen-renders/` and leaves the working tree clean.

**The residual, stated plainly.** The renders cannot show the title bar. `NSHostingView`
renders a *content* view, and the window title belongs to the window frame — so the C2
images show what the sidebar does and nothing about what the title bar does. Ma-4 —
"exactly one of the sidebar and the title bar carries the window's identity, never both
and never neither" — is evidenced by its four assertions in
`SidebarToggleRegressionTests`, not by these PNGs. Anyone reviewing that behaviour should
read the assertions; anyone reviewing the layout can look at the images.

---

## Appendix — the v1.1 pass, unchanged

## Task 1 — the command-line-tool subsystem: **removed** (option a)

Both options were viable and the choice was close. The reasoning, in full, because the
brief asked for it explicitly:

**What the state actually was.** `InstanceBuilder.buildTool` was *already* unreachable —
`attemptBuild` switches on `.full`/`.lite` and nothing calls it. `InstanceManager.inspect`
already required a `.app`. `LaunchSupervisor` already refused `configEnvironment`
instances, and the shim already failed closed on `kind=tool`, both with tests. What
remained wired was `ToolScanner` (public, could still produce tool `AppFacts`),
`CommandLineToolProfile.known` (public), and `Compatibility.evaluate`, which still answered
*"Supported — full isolation, each instance in its own Terminal session"* for a request
every other layer refused.

**Why removal rather than containment.** Option (b) would have made the boundary a
property of access control plus a guard clause. Both are maintainable-away: a future edit
to `attemptBuild` could reach `buildTool` again, and `@_spi`-style narrowing is not a
barrier so much as a speed bump. Removal makes the boundary a property of the codebase —
there is no code that can build a Terminal launcher, which a reviewer can confirm with
`grep` rather than by reasoning about visibility.

It also deletes `BundleAssembler.writeToolScript`, the only place in the project that
generated shell text. Hard rule 4 exists to fence exactly that; deleting the generator
retires the fence.

**What was kept, so 1.0 instances still work.** `IsolationMechanism.configEnvironment`,
`InstanceKind.tool` and the shim's fail-closed branch all remain as legacy markers.
`LauncherReconciler` no longer consults a table of tools to recognise a legacy launcher —
it recovers the registry key from the generated bundle identifier
(`com.…tool.<key>.mal.<n>.<uuid>`), which is strictly more robust: a legacy instance for a
tool key the product never shipped is now recoverable, where before it was silently
dropped.

**New test, as required.**
`testALegacyTerminalInstanceIsVisibleUnlaunchableAndFullyUninstallable` builds a real
pre-boundary launcher — shim, `kind=tool` config, `.command` script, tool-shaped clone
identifier — deletes the registry, and asserts the whole contract end to end: recovered
into the dashboard, refused by the supervisor, refused by renumber, then fully uninstalled
(launcher, profile, registry entry) and not resurrected on the next launch. A second test
covers the same when the launcher has already been dragged to the Trash.

### Tests removed, and why — please read this one

Rule 5 says not to weaken tests, and to say so explicitly if a test is changed. Four were
removed and one materially rewritten:

- `ToolScannerTests` (4 tests) — covered `ToolScanner`, which is deleted. Replaced by
  `LegacyTerminalInstanceTests` (4 tests) covering legacy-key recovery, unknown-key
  recovery, non-mistaking an ordinary clone identifier, and that `configEnvironment` still
  decodes out of an existing registry.
- `testAKnownCommandLineToolIsSupportedThroughItsConfigVariable`,
  `testToolVerdictStatesWhatIsStillShared`, `testToolProfilesAreLookedUpByExecutableName` —
  these asserted the verdict this change deliberately removes. Replaced by three tests
  that assert the opposite and more: a command-line executable is `.notSupported`; **no**
  verdict, over every combination of runtime × sandboxed × signed, can select the legacy
  mechanism; and the refusal names "GUI applications".
- **`testGeneratedScriptSurvivesAHostilePath` and `testGeneratedScriptRemovesItsLockOnExit`
  are a real loss.** They executed a generated script through a path containing an
  apostrophe, quotes and `$(…)`, and they were the only executable proof of the project's
  shell-quoting discipline. Their subject no longer exists. The replacement,
  `testNoGeneratedLauncherContainsAShellScript`, walks a freshly built launcher and asserts
  no `.command`, no `.sh` and no file beginning `#!` — a stronger guarantee for the shipping
  product, but **not** a re-proof of the quoting logic, because there is no quoting logic
  left. If a generator is ever reintroduced, those two tests should come back with it.
  This is recorded as gap 8 in VALIDATION.md.
- The two builder-boundary tests were rewritten, not weakened: same assertions (a
  command-line executable is refused; no bundle and no profile are left behind), restated
  now that no `AppFacts` shape says "tool". The first now uses the *most* creatable facts
  possible — a signed Electron app — so the refusal is proven to come from the source path
  rather than from the facts happening to be unsupported.

`Sources/MALCLI/MilestoneZero.swift` was also deleted. It was excluded from every target
in `Package.swift`, referenced the deleted symbols so it no longer compiled, and by its own
comment "intentionally opens Terminal". Its results are committed in `research/M0-*.md` and
are untouched.

## Task 3 — the dashboard container: **HSplitView kept, sidebar collapse restored**

**The blank window was not caused by what the code said it was.** It was caused by
presenting `.sheet` from a view whose identity belonged to the dynamic part of the
navigation tree: when that identity changed while a dismissal was in flight — deleting the
selected row — the sidebar and content subtrees were torn down and not rebuilt.
`PresentationHost`, a 1×1 sibling *outside* the container whose identity never changes, is
the fix. Replacing `NavigationSplitView` with `HSplitView` was a second change made at the
same moment and credited with the result.

**So the container was tested rather than assumed.** `NavigationSplitView` was put back
with `PresentationHost` in place and the suite re-run. All 40 failures were the same
structural probe; **every behavioural assertion passed**, including
`testSheetDismissalThenDeletionKeepsDashboardStateCoherent`, which is the exact
reproduction. An AppKit tree dump explains the probe: it requires an `NSSplitView` with
exactly three non-divider subviews, and `NavigationSplitView` here produces four (three
`_NSSplitViewItemViewWrapper`s plus a `_NSSplitViewShadowView`, which the name filter does
not exclude).

**Conclusion, stated as what it is.** `NavigationSplitView` is *not* known to be unsafe.
It is not restored because restoring it means rewriting that probe, and this pass was
required to leave `DashboardUIRegressionTests` unchanged. That is a process constraint,
not a technical verdict, and LIMITATIONS.md §13 says exactly that rather than implying the
container was found at fault. If a later change may touch the suite, the probe in
`assertDashboardColumnsVisible` is the only thing in the way.

**The capability it was costing is now implemented.** Sidebar collapse: toolbar button,
**View ▸ Hide/Show Sidebar**, ⌃⌘S, remembered between launches. Hiding the sidebar is the
only structural change this container makes to its own child list — the same class of
operation as the original bug — so `SidebarToggleRegressionTests` covers repeated toggling
and toggling *around* the sheet-dismissal-then-deletion sequence. The unified
toolbar/sidebar integration is still absent; that trade is documented.

## Task 2 — uninstall completeness

**The shipping uninstall path is clean.** Verified end to end with a real Kimi instance in
the user's own store: the clone's `~/Library/Preferences/<clone-id>.plist` was present
before uninstall and gone after, and the user's registry compared byte-equivalent
afterwards. The two-step in `InstanceArtifactCleaner` — `defaults delete` *then* remove the
file — is what makes it work; doing only the first leaves the file, which was confirmed
separately.

**A full `~/Library` before/after diff** (456,696 → 456,719 paths, three snapshots) found
exactly one path attributable to the instance out of 25 that appeared while it ran; the
other 24 were the user's own OneDrive, Outlook, Chrome, Claude and Codex background churn.

**The residue the user is actually seeing** comes from paths where that cleanup never runs:
a launcher dragged to the Trash instead of uninstalled, an instance created under `--root`
(whose cleanup is scoped to that root's library while the clone writes to the real one),
or a removal interrupted before the domain was cleared. This machine has 15 such stranded
domains. `doctor` now reports each with its exact `defaults delete` command — **report
only**, because the filename shows LaunchAgain generated the file but not which instance
owned it, and a name pattern is not ownership. `OrphanSweeper.remove` refuses the kind
outright and the file is outside both directories `assertDeletable` permits.

**The legacy directory now has a route out.** `doctor --retire-legacy-store` lists what is
there, names the profiles inside, requires typing `retire`, and moves to the **Trash**
rather than unlinking, because a legacy profile may hold a live session. Targets are
compared against the exact paths `MALPaths.legacy()` names — never derived from a registry
value — and it refuses to run against the store in use. Two tests cover both refusals.

**Nothing on this machine was deleted for the user by this work.** The 8 orphaned profiles
(~371 MB) are still there and the route exists; it was not run. The legacy directory is
**not** there — an earlier version of this document said it was, and that was false. See
VALIDATION.md gap 9: `Migration.migrateIfNeeded` was silently removing it whenever it was
"effectively empty", on every `InstanceManager` construction, logging below the configured
level so no record survives. That behaviour is removed.

**The removal journal genuinely resumes.** A delete was `SIGKILL`ed the instant its journal
record appeared, leaving launcher, profile and registry entry all intact. Starting a fresh
process — a plain `launchagain list` — completed the uninstall and cleared the record, with
`resumed and completed uninstall for instance #1` in the log.

## Task 4 — cleanups

- The `.overlay` comment in `RootView` blamed `.animation(value:)`. It now describes the
  real mechanism.
- `launchagain list` used `FSOps.directorySize` directly, re-walking a 12.65 GB profile on
  every invocation; it now uses the shared cache.
- The audit found one more: `AppScanner.fullFacts` measured the whole **source** bundle
  uncached, so inspecting or rebuilding an Electron app re-walked ~1 GB each time.
  `AppScanner` now takes an optional `DirectorySizeCache`. The two other `AppScanner`
  constructions call only `readEntitlements` and `quickFacts`, neither of which measures.

## Task 5 — the previously-asserted claims

| Claim | Result |
|---|---|
| Reboot persistence | **NOT VERIFIED.** The Mac was not restarted. Not claimed. |
| Memory | Measured. GUI idle 94.2 MB RSS / 30 MB footprint (empty store), 104.9 MB / 38 MB (real store, 12.65 GB profile), both flat. Builder peak 108.9 MB while cloning and re-signing a 992 MB Electron app. |
| Progress feedback | Engine emits 9 named stages (observed); forwarding and non-dismissibility verified in the code. **The sheet itself was not driven.** |
| Rediscovery | Verified — entire 12 GB store moved aside, every registry field recovered identically, then restored. **Caveat:** this launcher predates `LaunchAgainInstance.json`, so it proves the *legacy* path, not the manifest path. |
| GUI-only | Verified. `ChatGPT.real` runs as a foreground GUI app; Terminal never started; `kind=app`; no `.command` anywhere. |

## What a reviewer should push on

- **Reboot persistence is unverified** and is the largest open item. One restart plus
  `launchagain list` closes it.
- **Gap 8** — the two deleted shell-quoting tests. That is a genuine reduction in coverage
  of a security-relevant behaviour, accepted because the behaviour itself is gone.
- **Gap 5** — the artifact sweep was measured against a ~45-second run that produced only a
  preference domain. `Saved Application State`, `HTTPStorages`, `WebKit` and `Containers`
  are in the cleaner and unit-tested, but were never exercised against a real app that had
  actually created them.
- **Gap 2** — `--root` instances leak their preference domain by design. Documented, not
  fixed.
