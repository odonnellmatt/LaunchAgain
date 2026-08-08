# Changelog

## 0.1.2

### Hardened beta release

This beta packages the hardened LaunchAgain implementation for public evaluation. It
includes the disconnected-display window recovery shim, Swift 6 strict-concurrency
hardening, safer process and service lifetimes, deterministic uninstall recovery, and the
maintainer and validation documentation needed to operate the project safely. The app and
DMG identify this public beta as **0.1.2**; the implementation work is retained below as
the 1.3.0 engineering baseline in the private source history.

The artifact is ad-hoc signed and is not notarized. Existing instances should be rebuilt
from the source application after installing this beta so they receive the current
launcher shim.

## 1.3.0

### Display recovery, concurrency hardening, and a maintainable release surface

**Cloned Electron windows no longer reopen as an immovable remnant after a display
change.** The generated launch shim now recognises the small top-level
`window-state.json` schema used by applications such as Claude Desktop. Before it starts
the target application, it compares the saved title bar with every active display. If no
draggable part is reachable, it centres the saved window on the main display, preserves
unknown vendor keys, and keeps the first original file as
`window-state.json.launchagain-backup`. Recognised files that are already usable are left
byte-for-byte unchanged; malformed files, other schemas, large files, and symbolic links
are not edited. The repair lives in the generated launcher, so opening a clone from the
Dock or Finder follows the same path as opening it from LaunchAgain. Existing launchers
must be rebuilt once to receive the new shim.

**Concurrency defects found by the audit are fixed.** Logging no longer shares a mutable
`ISO8601DateFormatter` between writers. Process output is collected through synchronized
storage that satisfies Swift 6 sendability, and a process that fails to spawn can no
longer leave pipe-reader closures waiting for an EOF that will never arrive. Delete and
cleanup reports now cross the worker/main-thread boundary as returned values instead of a
mutable variable captured by both queues. The command-line `launch` and `quit` paths now
run their asynchronous work on an independent executor; under Swift 6 they previously
inherited the main actor and then blocked that same actor on a semaphore, so the command
could wait forever. AppKit timers, observers, and directory watchers now live in a small
locked lifetime owner, which guarantees cleanup without relying on the newer compiler's
`isolated deinit` feature and keeps the macOS 15 CI toolchain supported. The entire product
builds with warnings as errors and complete strict-concurrency checking. Creation progress
callbacks are explicitly sendable so the macOS 15 Swift compiler can prove that their
main-actor UI handoff cannot race with the background build queue. Window identity now
has one stable owner: the system title bar. The duplicate sidebar brand block and the
OS-dependent bridge that moved `NSWindow.titleVisibility` during sidebar changes were
removed after macOS 15 showed that SwiftUI can overwrite that state.

**The repository now has a durable maintainer contract.** `AGENTS.md`, the README,
contribution guidance, CI, pull-request templates, private vulnerability reporting
instructions, and a dedicated GitHub Pages site define how to inspect, test, document,
package, and release the application. Because the account plan cannot publish Pages from
a private repository, an exact-scope script mirrors only `site/` into a separate public
Pages repository; its workflow uploads only `public/`. Every patch must update the
changelog, README release summary, and Pages patch notes. Examples and current repository
content use only generic paths, labels, and addresses. CI concurrency is keyed by commit,
so a delayed push event for an older revision cannot cancel current release validation.
The source and Pages workflows use the current official Node 24 action majors, including
`actions/checkout@v7`.

## 1.2.5

### The three deferred findings: one rule for the mode, an honest date, two honest messages

Round 5 left three findings for a separate change because none is a safety property
and each is a different subsystem. This is that change.

**The interface predicted the mode; the builder resolved it.** They disagreed, and
the interface was the one that was wrong. A verdict degrades an application to Lite
for several reasons — unsigned, or it installs a privileged helper, which Chrome,
Brave and Edge all do — and when that happens a Full request produces a Lite
instance. The builder knew; the detail view read the stored mode instead. So for a
shared-credential application whose source had gained a privileged helper since the
instance was built, the view predicted Full, showed no acknowledgement checkbox, left
Apply enabled, and the build then refused. `Rebuild from Source App` had no gate at
all and threw "Lite mode cannot isolate X" at a user who never asked for Lite.

There is now one definition — `CompatibilityVerdict.effectiveMode(requesting:)` — and
the builder and the view both ask it. Rebuild is disabled when the engine would refuse
it, and says where the decision is made instead of failing at the end.

**A pending inspection no longer reads as "nothing to acknowledge".**
`verdict(forAppKey:)` returns `nil` on first call and inspects on a background queue.
The view treated unknown and none the same, so during that window Apply was enabled
for an application that might need the acknowledgement. It fails closed now.

**`createdAt` survives a rebuild.** It was restamped every time, so the field the
detail view labels "Created" actually answered "when did you last rebuild".

**Two messages named a remedy their command cannot perform.** "Use Rebuild after
turning this off" does not undo Force Lite — `rebuild` builds at the stored mode, and
by then the stored mode is Lite. Nothing in the product converts Lite back to Full, so
the text now says what actually works: delete and recreate. And the `CODEX_HOME` route
out is printed by the command line, which has no way to set an environment variable on
an instance; it now names the app's Advanced panel and says there is no flag for it.

## 1.2.4

### The gate reads the disk, and four sentences come back to what was measured

Round 5 recommended merging the code and not the documents. It found no reachable
state in which an instance carries an acknowledgement no user gave — the separate
field introduced in 1.2.3 does what it claims — and four sentences that outran their
measurement. Two code defects came with it.

**The allowance read the registry, and its justification is about the disk.** 1.2.3
permitted a rebuild when the *stored* mode was Lite, while explaining itself with a
claim about the launcher on disk. Those are different objects. A registry row edited
to say Lite over a Full clone let `rebuild` convert a 366 MB clone that had its own
ad-hoc identity — and genuinely could not read the vendor's Keychain items — into a
388 KB launcher running the vendor-signed original and sharing them outright,
silently, exit 0. That is the sharing the gate exists to prevent, introduced through
the gate. It now reads the shim config with
`BundleAssembler.readInstanceConfig`, the same physical fact the reconciler reads, and
fails closed when the config is absent or unreadable — a stored-Lite instance whose
launcher is gone is not "already Lite on disk", and rebuilding it would put a shared
session where there currently is none. Reaching the divergent state needs a
hand-edited registry; no other route was found.

**`renumber` re-dated the acknowledgement.** It rebuilds the instance field by field
and omitted `acknowledgedSharedCredentialStoreAt`, so the date was dropped while the
acknowledgement itself still read `true` from the registry — and the build fell
through to `?? createdAt`, stamping the moment of the renumber as the moment the user
accepted. Pre-existing, and it falsified the comment two lines above the write.

**Four documents corrected, and recorded rather than quietly edited.** 1.2.3 claimed a
shipped build mints an un-acknowledged Lite row "every time it adopts a launcher": it
does not, because launchers built by this version carry the acknowledgement in their
recovery manifest and reconciliation prefers it, so the shape comes only from
manifest-less or identity-mismatched launchers. It claimed no route existed to
acknowledge an existing instance: Advanced ▸ Apply has always offered one, so the
stranding was CLI-only. It said all six new tests fail against the pre-fix code: five
do, and the sixth is a regression guard that passes either way. It cited three
assertions against the discarded one-line fix, and there are five.

`LIMITATIONS.md` §7 still described a gate the product no longer has and now carries
the qualifying paragraph — the three other documents were corrected in 1.2.3 and the
user-facing one was missed.

Left for a separate change, all pre-existing: the detail view enables Apply and leaves
Rebuild ungated when a source app gains a privileged helper and its recommended mode
flips to Lite; every rebuild resets `createdAt`, which the detail view shows as
"Created"; and two message surfaces name a remedy the receiving command cannot perform.

## 1.2.3

### One stranded instance, and four documents that outran the measurements

The fourth review round found no code defect and recommended merge. This closes
the one thing it filed as prose that is not: it dismissed an un-acknowledged Lite
row as an empty population, on the grounds that the pre-gate population is closed
and nothing has shipped. That is true of pre-gate rows and false of the shape as a
whole.

**A recovered Lite instance could not be rebuilt, renamed, or changed.**
`LauncherReconciler` reconstructs an instance from the shim config of a launcher it
finds on disk. It reads the mode from that config and records no acknowledgement,
because it has no evidence anyone was ever asked — which is right. But 1.2.2 gated
every rebuild on a recorded acknowledgement, so such an instance refused `rebuild`,
`duplicate`, and even `rename`, which changes nothing about the shared session. The
refusal named the consequence and no remedy, because for those commands there was
none. In the GUI, Advanced ▸ Apply was *enabled* and then failed, because the view
gated on the stored mode while the engine gated on the stored acknowledgement.

*(Corrected in 1.2.4: this said a shipped build mints such a row "every time it
adopts a launcher", and that no route existed to answer. Both overstated. Launchers
built by this version carry the acknowledgement in their recovery manifest and keep
it through recovery, so the un-acknowledged shape comes only from manifest-less or
identity-mismatched launchers; and Advanced ▸ Apply has always been able to record
an acknowledgement for an existing instance, so the stranding was CLI-only.)*

The gate now asks whether a build *introduces* a shared session rather than whether
one exists. Re-creating a launcher the store already holds as Lite, at the mode it
already has, is permitted — the sharing is already on disk, and refusing does not
undo it. Converting a stored-Full instance to Lite is still refused, and degradation
still cannot reach the allowance, because a rebuild of a Lite instance never runs the
Full path.

The permission is a separate field from the acknowledgement
(`BuildRequest.rebuildsExistingLiteLauncher`), read at the gate and nowhere else.
Folding it into `acknowledgedSharedCredentialStore` — the obvious one-line version —
would have stamped a consent date for a user who was never asked, and `duplicate`
reads that stamp to authorise a **new** launcher, reopening 1.2.2's blocking finding
through a different door. A test asserts exactly that: after a recovered instance is
rebuilt, `duplicate` still refuses.

**Four documents corrected.** The Lite refusal held on **seven** real
shared-credential applications, not four — Brave, Claude, Chrome, Keeper, Edge, OBS
and Codex, from all 65 scan candidates. The property was right and the count was not.
"Rows from older registries are asked again" described a re-prompt that does not
happen. A comment in `InstanceDetailView` justified the view's gate with a premise
that stopped being true in 1.2.2. `VALIDATION.md` gap 15 duplicated gap 11.

## 1.2.2

### Closing pass: two code defects, six minors, four false statements

A third adversarial review returned "merge with fixes". Everything
safety-critical was confirmed empirically and none of it is touched here: the
deletion boundary refused eight attacks with no canary lost, the registry stayed
consistent at 2, 8 and 16 concurrent writers and against a live GUI, the Lite
refusal held on every real shared-credential application on the test machine, log
redaction held, and 9 of 10 mutants were killed. Four of the eleven findings below
are documents that claimed more than the measurements supported.

*(Corrected in 1.2.3: that count was written here as "all four" and there are
seven. The refusal held on all seven; only the number was wrong.)*

**B1 — `duplicate` minted a Lite launcher from an acknowledgement nobody gave.**
The shared-session acknowledgement was inferred from `mode == .lite`, which is a
state with several origins and not a record that anyone was asked. Duplicate is a
one-click menu item with no card in front of it and it produces a *new* launcher,
so the inference authorised a fresh Lite instance of a shared-credential app for
any Lite row in the store — one created before the gate existed, one a
hand-edited registry claims is Lite. The acknowledgement is now stored as what it
is: `Instance.acknowledgedSharedCredentialStoreAt`, written at the moment the
user accepts, on the Lite build path only. Rows from older registries decode as
un-acknowledged; rebuilding an acknowledged instance still
does not re-prompt, and does not re-date the acknowledgement either. A Full build
records nothing even if a caller passes an acknowledgement, so converting it to
Lite later cannot read its own flag back. Nothing had shipped from this branch and
the only real instance is Full, so no one was exposed; it is fixed because it is
wrong before distribution.

**Mi-a / Mi-b — the updater record counted work it had not done.**
`SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` are written on every clone,
which is correct and stays — Sparkle's default is to prompt, and a prompt is an
update path. But writing them made `changedKeys` never empty, so "nothing was
neutralised" became unreachable and the marker went back on every clone, which is
the exact failure Ma-1 had just removed. Keys asserted defensively are now
recorded separately from an updater actually found and disarmed, and each key is
recorded once instead of twice for an app that already declares both as `false`.

**Mi-c — `create` exited 0 when every instance failed.** It printed ✗ for each
one, created nothing, and returned success. Total failure now exits 1 and partial
success exits 2.

**Mi-d — degradation matched step names that do not exist.** `isDegradable`
tested `hasPrefix` against `["sign", "verify", "icon", "shim"]` while the build
steps are verb phrases: only `"verify signature"` and the hand-thrown `"shim"`
ever matched, so a wrapped signing or icon failure failed the build instead of
degrading. Fail-safe, and unnoticed because the unwrapped `MALError` cases still
degraded. The steps are now matched exactly, from a list next to the error, and
tested against the strings the builder really throws — the old test asserted
`"sign clone"`, a step that has never existed.

**Mi-e — `inspect` still printed the pre-Ma-2 estimate.** 367 MB "per instance"
for an application whose Full clone is 1.75 GB. All three surfaces now call
`estimatedBytesPerInstance`.

**Mi-g — the suite wrote into the working tree, and one render was not
reproducible.** Six PNGs were written into `docs/evidence/` on every `swift test`,
and `c3-health-list.png` embedded fresh UUIDs, so it differed every run — three
different sizes across three runs. Renders go to `.build/screen-renders/`; copying
into `docs/evidence/` needs `MAL_WRITE_EVIDENCE=1`, which `Scripts/render-evidence.sh`
sets. Every identifier the screens display is fixed, so two runs now produce
identical checksums for all six, and `git status` is clean after the suite.

**Mi-h — dead code.** A `readOnlyCommands` set nothing read; the real wiring is
four explicit `makeManager(readOnly:)` calls. Removed, with its reasoning kept
where the decision is made.

**B2 — the documents denied a message the product prints.** VALIDATION said the
unwritable-install-directory message never says `sudo`. That was true only of the
not-exists branch; the exists-but-read-only branch — the likelier real case for
`/Applications/LaunchAgain` — suggests `sudo chown -R $(whoami) …`. The
suggestion is kept and the documents now describe it: printing a command for
someone to run is not the product escalating, and `ProcessRunner.Tool` enumerates
every executable LaunchAgain launches, none of which is `sudo`. Both branches are
asserted by unit test, and `Scripts/integration-test.sh` — which had no check here
at all — now provokes the failure through the CLI against a real read-only root.

**Ma-A — PULL_REQUEST contradicted VALIDATION** under "Read this before
approving", still calling the unseen C1–C4 screens the largest unclosed item
after six PNGs had been committed. Rewritten, including the honest residual: the
renders cannot show the title bar, so Ma-4's evidence is its four assertions.

**Ma-B — the corrected disk figures were wrong too.** Gap 6 replaced 23 GB with
1.72 GB and 110.19 GB, worked out by hand, and contradicted the CLI line quoted
on the same page. The product's own output is 1.75 GB at count 1 and 112.03 GB at
count 64; both are now pasted verbatim, along with how they were produced.

**Mi-f — LIMITATIONS §7 overstated degradation**, saying unconditionally that a
clone that cannot be built is rebuilt in Lite mode. It is refused for
shared-credential apps without an acknowledgement. Qualified.

## 1.2.1

### Adversarial review remediation

One blocking finding, seven majors and twelve minors, all reproduced in the code
before being fixed.

**Blocking — Advanced ▸ Force Lite bypassed the shared-credential gate.**
`updateAdvancedSettings` set `proposed.mode = .lite` and `InstanceBuilder.rebuild`
derived the acknowledgement from `instance.mode == .lite`, so the gate read back
the flag the caller had just set. Three clicks converted a Full instance of a
shared-credential-store app to Lite with no warning card, no acknowledgement and
no refusal. The acknowledgement is now an explicit parameter through every layer
and is only ever inferred from the **stored** record, never from a proposed
change; the rule itself has one definition,
`CompatibilityVerdict.requiresSharedCredentialAcknowledgement(mode:)`, which the
create flow, the detail screen and the builder all consult. The detail screen
shows the same warning card and gates Apply on it.

**Ma-1 — the updater promise was false for ChatGPT.** The marker was written
unconditionally, automatic checks were only disabled when some other key was
already present, and Sparkle's installer chain survived in the clone. ChatGPT
declares only `SUPublicEDKey`, so nothing was neutralised and the interface
promised otherwise. The marker now records what was actually done and is absent
when nothing was; automatic checks are set regardless; `Autoupdate`,
`Updater.app` and the Installer and Downloader XPC services are removed as
Squirrel's `ShipIt` already was; and the Updates box states what will happen to
*this* application, including "we could not find one" where that is the truth.

**Ma-2 — the disk estimate omitted the clone.** It multiplied the profile
estimate by the count and ignored the copy of the application, so ChatGPT read
"367 MB" for a 1.38 GB bundle and the free-space warning could not fire at any
count. It now includes the bundle for Full and excludes it for Lite, from one
shared definition, with the APFS sharing explained rather than implied.

**Ma-3 — the 16×16 application icon drew a black blob.** `while size > 1`
never entered its body at that size, so the numeral was drawn with the unstyled
system fallback: 16 opaque near-black pixels of 256, shipped in the DMG. The
loop always picks a font now, and skips the numeral rather than drawing it
unstyled. Every size in the iconset is checked, not just 512.

**Ma-4 — collapsing the sidebar removed the window's identity.** C2 moved the
name into the sidebar and switched the title bar off permanently. Title
visibility now follows the sidebar: exactly one of the two carries the identity,
never both and never neither.

**Ma-5 — deleting a bundle's signature made it easier to delete.** The uninstall
path verified a signature only if one happened to be present. It is now required
and validated unconditionally, as the sweeper already did.

**Ma-6 — three mutants survived the whole suite** and now each fail: the
`MALGeneratedBy` ownership guard, `refreshIconCaches`, and the silent deletion of
an empty pre-rename store that v1.1 claimed to have removed.

**Ma-7 — the compatibility card contradicted itself.** For Claude it printed
"Full profile isolation — separate accounts" four lines above "Instances of this
app are not separate accounts". Each signal is now qualified by the mode it
actually bites in, and the headline is computed from that rather than before it.

**The minors**, all twelve: create-flow state surviving an application change;
purge wording; a command-line verb for stale removal markers; size-scan noise; a
permission message that blamed the wrong thing and offered a choice that does not
exist; a misnamed predicate; a stray attribute warning on every build; a raw
`NSError` dump; a clipped button label; read-only commands writing the store; and
sizes below a megabyte reported as "0 MB".

**Evidence.** The changed screens are rendered to `docs/evidence/` from a test —
`NSHostingView` offscreen, no Screen Recording permission — instead of existing
only in a conversation. (The claim made here that they were "reproducible
anywhere the suite runs" was not true of `c3-health-list.png`, whose fixture
generated fresh UUIDs into the rendered text; corrected in 1.2.2.)

## 1.2

### Isolation correctness, install location, and interface quality

#### An instance is not always a separate account, and now says so

- **Apps whose signed-in session lives outside the profile are detected and disclosed.**
  A ChatGPT instance came up already signed in, and signing out of it signed the user out
  of every copy including the original. Measured on the reporting machine: a Full clone
  with every team-bound entitlement stripped and an ad-hoc signature still started signed
  in and loaded the user's own threads, and the same clone started signed out when
  `CODEX_HOME` pointed at an empty directory. For this app the session is not in the
  Keychain and not in the App Group container — it is `$CODEX_HOME/auth.json`, a plain
  file in the home directory read by the bundled `codex` app-server, which
  `--user-data-dir` does not touch.
- `Compatibility.sharedCredentialStores` reports three signals: the
  `keychain-access-groups` entitlement, the `com.apple.security.application-groups`
  entitlement, and a small table of applications whose configuration home has actually
  been measured. The compatibility card leads with **"these will not be separate
  accounts"**, names the observable consequence, and where a route out was measured says
  what it is — set `CODEX_HOME` per instance — and why LaunchAgain does not set it for you.
- **Lite mode is refused for these apps** unless an acknowledgement naming the consequence
  is given: `--acknowledge-shared-credentials`, or a checkbox that blocks Next in the
  create flow. Automatic degradation from a failed Full build is refused on the same
  terms. Nothing reads, copies or writes the Keychain.

#### Instances no longer update themselves out of their own identity

- A clone's own Squirrel or Sparkle updater replaced `Contents` wholesale and took the
  rewritten identity, the numbered icon, the shim and the signature with it. Instances are
  now non-self-updating by default: Squirrel's `ShipIt` helper and electron-updater's
  `app-update.yml` are removed from the clone, and Sparkle's feed is moved to
  `MALOriginalSUFeedURL` with automatic checks and automatic install set to false. The
  Squirrel framework itself stays, because the application links against it.
- Rebuild remains the only update path and still preserves the profile;
  "rebuild available" detection is unchanged. `--allow-self-update`, and an advanced
  toggle on the review step, restore the vendor's update path. Both default to off.

#### Launchers can live in /Applications when an app demands it

- LM Studio refuses to run from `~/Applications/LaunchAgain`: it tests its install
  location against the literal prefix `/Applications/` and opens no window when the test
  fails. A clone in `/Applications/LaunchAgain/` satisfies it.
- `MALPaths` therefore has exactly two launcher roots, and every ownership question
  answers from that fixed list. `assertDeletable` widened by one named directory; it did
  not become a rule about `/Applications`, and a bundle beside our directory is still
  refused. Reconciliation, Health, uninstall, migration, the recovery manifests, the
  filename-collision check and the directory watchers all cover both roots.
- `/Applications/LaunchAgain` is created on demand, and a permission failure names the
  directory and says an administrator is usually needed. No privilege escalation, no
  helper tool. (The "install in your own Applications folder instead" fallback this
  originally offered was removed in 1.2.1 — see Mi-6.)

#### Uninstall completeness

- Re-measured against a real ChatGPT clone: created, run, uninstalled. Its four
  real-Library artifacts all keyed to the generated identifier, all removed, nothing left
  naming that identifier.
- The allow-list gains `Group Containers/<clone-id>`, `WebKit/WebsiteData/<clone-id>`,
  `CrashReporter/<clone-id>` and three more, all keyed to the generated identifier only.
- What is deliberately **not** removed is now stated rather than an unexplained absence:
  `~/Library/Logs/<vendor-id>` and `~/.codex` are shared with the original application,
  and removing the second on uninstall would sign the user out of every copy.

#### The numbered badge

- Diagnosed with evidence rather than guessed. The generated icon, the `Info.plist`
  rewrite and Launch Services resolution are all correct for an asset-catalogue app
  (`docs/evidence/b2-*.png`). Two causes remained: IconServices caching by path, which is
  fixed — every install now bumps the modification date of the bundle, its `Info.plist`
  and its `.icns`, which are three separate cache keys — and ChatGPT setting its own Dock
  icon from its own code, which LaunchAgain cannot override without modifying that code.
  The second is stated as a limitation instead of being papered over.

#### Interface

- The delete confirmation is redesigned: what goes is three rows each naming one thing
  with its size, the recoverability promise has its own line, and what stays untouched is
  a separate list. Every fact and the typed confirmation are unchanged.
- The create flow defaults to **one** instance rather than two. 1 / 2 / 3 plus Custom, and
  Custom shows the estimated total and the free space on the destination volume next to
  the control that changes them, warning before a choice that would not fit.
- The window title no longer straddles the sidebar divider: the title bar shows no title
  text and the name, icon and version are in the sidebar header.
- Health rows are one line each — what it is, how big, and the single action that resolves
  it — with the explanation as a tooltip. **Delete All Safe Items** says how many and how
  much first. Every protection is unchanged: confirmation naming each item, leftover
  profiles excluded, recovery records excluded, everything to the Trash.
- The application icon sits on an opaque near-white tile instead of on transparency, which
  read as grey in the Dock; the three coloured tiles are larger and all three numerals are
  visible.

#### Carry-over

- `Registry`'s corrupt-file and `.bak` recovery writes now take the same advisory lock
  every other write takes.
- `doctor --purge-profiles` no longer prints a green tick over a run in which every
  removal failed, and exits non-zero on total or partial failure. `--clean` likewise.
- The integration suite races eight real `create` processes against a scratch root and
  asserts registry rows, launcher bundles, profiles and distinct numbers all agree.

## 1.1

### Completion and hardening pass

- Removed the command-line-tool subsystem outright rather than leaving it half-wired.
  `CommandLineToolProfile`, `ToolScanner`, `InstanceBuilder.buildTool`,
  `BundleAssembler.writeToolScript`, `RuntimeKind.commandLineTool` and Compatibility's
  tool branch are gone, so nothing can build a Terminal launcher and no verdict can claim
  one. Instances created before this boundary stay visible, refuse to launch and uninstall
  completely; their registry key is now recovered from the generated bundle identifier
  rather than from a table of tools the product no longer ships.
- The sidebar can be collapsed again: toolbar button, **View ▸ Hide/Show Sidebar** and
  ⌃⌘S, remembered between launches. LIMITATIONS.md section 13 records why the dashboard
  uses `HSplitView` rather than `NavigationSplitView`, including the measurement showing
  the container was never the cause of the blank window.
- `launchagain doctor` reports orphaned clone preference domains —
  `~/Library/Preferences/<clone-id>.plist` left behind when a launcher was dragged to the
  Trash instead of uninstalled — with the exact `defaults delete` command. Reported, never
  deleted: a filename pattern shows LaunchAgain generated the file but not which instance
  owned it.
- `launchagain doctor --retire-legacy-store` moves the pre-rename
  `MultipleAppsLauncher` directory to the Trash after an explicit typed confirmation.
  Migration never merges a profile that exists on both sides, so until now that directory
  had no route out. The targets are the exact paths `MALPaths.legacy()` names and items go
  to the Trash, not `unlink`, because a legacy profile may hold a live session.
- `launchagain list` and `AppScanner.fullFacts` route their directory-size walks through
  the shared cache instead of re-measuring gigabyte profiles and source bundles on every
  invocation.
- Added `docs/VALIDATION.md`: what was verified on a real machine, the commands and their
  real output, and a separate section listing what could not be verified.
- Fixed a cross-process race in the registry. `registry.json` had no lock between
  processes, so the interface and the command line could each be issued the same instance
  number, and the loser became a signed, installed launcher whose profile could never be
  recovered. Every read-modify-write now runs under an advisory lock and re-reads the
  document inside it, and a number drawn for a build in progress is held under its own
  lock — durable, visible to other processes, and released on commit, on failure, or by
  the kernel if the process dies.
- Logging no longer re-reads and re-matches the whole log on every write. That cost
  switched on permanently the first time an instance was uninstalled; a `doctor` run on an
  18,000-record log went from 0.00s to 0.27s. Scrubbing now happens at rotation and at
  uninstall, and each write checks only the record it is about to append.
- **Remove Cleanable Items** now asks first, names everything it will take, and moves it
  to the Trash. It also no longer offers a launcher whose profile is still on disk: that
  launcher is the only record of which instance the profile belongs to.
- `doctor` reports a removal marker left by an earlier version that nothing could act on,
  with a route to clear it. It previously warned on every launch with no remedy.
- Migration no longer deletes an empty pre-rename directory silently. Those paths sit
  outside the two directories LaunchAgain may delete inside, so retiring them is an
  explicit choice — `doctor --retire-legacy-store`.
- The suite is now 241 tests.

### Recovery, progress and stability

- Replaced the remaining dynamic navigation `List`/`NavigationSplitView` stack with
  three permanently mounted, resizable columns and a presentation host whose identity
  does not depend on the selected row. Dismissing a create/delete sheet can no longer
  detach the sidebar and dashboard while leaving stale detail visible.
- Added **Refresh Installed Launchers** to the toolbar, menu and empty dashboard.
  Startup and directory-change reconciliation also scan the launchers already installed
  under `~/Applications/LaunchAgain`.
- Every new launcher now carries a small signed `LaunchAgainInstance.json` recovery
  record. A fresh LaunchAgain installation can reconstruct app identity, instance
  number/name, profile path, mode, badge, account label and advanced settings from the
  launcher without copying or touching the profile. Launchers made by 1.0 are recovered
  from their existing sealed Info.plist and `MALInstance.conf`.
- Explicit removals write per-instance tombstones before the registry row is removed, so
  reconciliation never resurrects an intentionally deleted launcher during a delayed
  filesystem event. The marker records the authoritative instance and selected deletion
  scope, so an interrupted uninstall resumes on startup. The marker is cleared after a
  completed uninstall, leaving no per-instance recovery residue.
- If both registry copies are unreadable, their original bytes are preserved under
  timestamped names before the registry is rebuilt from installed launchers.
- The create sheet now has an in-sheet, non-dismissible progress screen with per-stage
  and overall progress. Large Electron clones visibly report cloning, patching,
  nested-code signing, verification and installation instead of appearing frozen.
- App discovery and instance selection use lazy, explicit button rows. Candidate icons
  load only for visible rows rather than retaining an `NSImage` for every installed app.
- Running directly from a mounted DMG now shows a persistent warning and offers to open
  the installed Applications copy, preventing old mounted builds from being mistaken for
  the current installation.
- LaunchAgain now creates and opens GUI applications only. The Codex desktop bundle at
  `/Applications/ChatGPT.app` is shown as **Codex**; command-line executables are rejected.
  Older Terminal-based instances remain visible for safe cleanup but cannot launch,
  rebuild, duplicate or claim URL schemes.
- Lite mode now states its narrower boundary exactly: the Chromium profile is separate,
  while the vendor-signed original app's Dock, Keychain, privacy-permission and URL-scheme
  identity are shared. URL-scheme claiming is disabled for Lite at both UI and manager
  boundaries.
- Deleting an instance is now a complete uninstall of exactly that UUID's owned
  footprint: launcher, profile, caches, logs, lock, registry entry, temporary recovery
  marker and size-cache key. Exact clone-identifier preferences, HTTP storage, WebKit,
  synced preferences, saved state, URL-session downloads, updater caches and bounded
  Darwin cache/temp items are also removed; LaunchAgain asks macOS to clear the exact
  preference domain and removes its exact plist when present. Complete records carrying
  that UUID or generated clone identifier are atomically removed from LaunchAgain's
  shared log under a cross-process lock while unrelated log records remain. A bounded
  non-plaintext suppression fingerprint prevents a queued current-version writer from
  putting the identity back; concurrent logger startup uses non-truncating creation.
  The source application, other instances and external user-selected profile directories
  remain untouched.
- Registry mutations, create/rebuild replacement and renumber operations now roll back
  coherently if persistence or a later build step fails. The primary registry and backup
  contain the same committed document, so a completed deletion cannot be resurrected by
  backup recovery.
- Recovery and deletion now share a strict launcher-identity verifier binding the bundle,
  manifest, sealed config, clone identifier, UUID and number. Duplicate UUID launchers,
  roots, sibling instances, arbitrary `.app` files and damaged registry paths are never
  silently adopted or removed. Filesystem aliases that resolve to one launcher (notably
  `/tmp` and `/private/tmp`) are recognised as one identity rather than a duplicate.
- Profile-size walks release Foundation objects in bounded batches, candidate icons load
  lazily, and repeated Health scans reuse a bounded persistent cache.
- Added recovery, corrupt-registry, complete-uninstall, GUI-only, mode-boundary,
  watcher-driven refresh, distinct-app preservation and sheet-dismissal regressions;
  the suite contained 204 tests at that point.

## 1.0

First working version. Milestone 0 passed on Claude and on a second, unrelated Electron
app (Kimi) with no app-specific code, so full mode ships: numbered Dock icons, not just
isolation. See [research/M0-gate.md](research/M0-gate.md) for the recorded decision.

### What it does

- Creates numbered, isolated instances of Electron and Chromium apps: APFS clone,
  rewritten identity, generated badged icon, launcher shim, ad-hoc inside-out re-signing.
- Creates instances of command line tools whose whole session lives in one directory —
  Codex and Claude Code — by pointing that tool's config variable at a per-instance
  directory and opening a terminal session.
- Falls back to Lite mode automatically when cloning, signing or verification fails in a
  way Lite can avoid. Runtime-only target-app launch failures are reported.
- Stable existing numbers: deleting #2 leaves #3 as #3; ordinary creation then fills the
  lowest free positive number, so the next instance is #2.
- Transactional builds: any failure rolls back completely, leaving no bundle, no profile
  and no registry entry.
- SwiftUI interface (dashboard, create flow, instance detail) and a headless `launchagain` CLI
  over the same engine.
- Orphan sweep, diagnostics export, rebuild-after-update, duplicate, renumber.

### Production hardening

- Replaced the dynamic selectable dashboard `List` with an explicitly selected
  `ScrollView`/`LazyVStack`, mutually exclusive row click handling, independent action
  buttons, keyboard movement and VoiceOver metadata. Dynamic 1→2→1 row changes no longer
  enter the SwiftUI focus/key-view invalidation loop.
- Publishes one coherent dashboard snapshot, debounces filesystem events and coalesces
  equivalent running/profile/Health work. No-op source refreshes no longer rewrite the
  registry.
- Prunes empty managed-app records and restarts ordinary numbering at #1 when a source is
  genuinely rediscovered.
- Records duplicate legacy/current profile UUIDs as durable Health conflicts without
  merging, moving, replacing or deleting either profile. Orphan profiles remain
  report-only unless explicitly purged.
- Added a bounded, persistent profile-size cache so repeated Health/doctor scans avoid
  walking large Chromium profiles. CLI doctor reports progress immediately.
- Strengthened restart durability: registry/config writes are synchronized, atomically
  renamed, directory-synchronized and request `F_FULLFSYNC` on macOS. A dedicated
  process-boundary reboot test proves the registry, launcher, profile, orphan and conflict
  marker survive repeated reconstruction.
- Added a hosted shipping-UI regression harness and expanded the suite to 172 tests.
- The app bundle now uses distinct `LaunchAgainGUI` and `launchagain` executables, guarded
  against case-insensitive filesystem collisions.

### Defects found and fixed while getting there

Four bugs, all found by building real clones and watching them die rather than by reading
the code:

- **Renamed main executable was signed without entitlements.** After the shim `execv`s
  `<Name>.real`, that binary *is* the app, so it needs the main entitlements. Signed as
  ordinary nested code it enforced library validation and dyld refused the vendor-signed
  Electron framework: *"mapping process and mapped file (non-platform) have different Team
  IDs"*. Nested executables are now signed with the patched version of their own
  entitlements, read from the untouched source app.
- **Rewriting `CFBundleName` broke Chromium's helper lookup.** Electron builds the path to
  its renderer as `Contents/Frameworks/<CFBundleName> Helper (Renderer).app`, so a renamed
  clone aborted at startup with *"FATAL: Unable to find helper app"*. Clones whose helpers
  are named that way now keep `CFBundleName` and take their visible identity from
  `CFBundleDisplayName`.
- **A lock file written with pid `-1` made an instance permanently unlaunchable.**
  `kill(-1, 0)` signals every process the user owns and returns success, so the stale lock
  always looked alive. Non-positive pids are no longer written or trusted.
- **"Remove the launcher and its data" silently kept a relocated profile.** It deleted our
  own directory for the instance, which is not where the data was. It now removes what it
  owns, leaves what it does not, and says which.

Four more came out of watching someone actually use it:

- **Deleting an instance left its profile behind with no way to remove it.** "Remove the
  launcher only" is the right default — the profile is a signed-in session — but once the
  registry entry was gone the health check reported the leftover as "needs attention"
  forever and refused to clean it, so the only remedy was Finder. Health now offers an
  explicit, per-item **Delete…** with a typed confirmation, and the CLI has
  `launchagain doctor --purge-profiles`. The guard is unchanged: it still refuses anything outside
  the launcher's own two directories.
- **An instance launched seconds earlier read as "not running".** Electron takes a few
  seconds to register with Launch Services, and the running check only asked NSWorkspace —
  so deleting an instance you had just opened removed the bundle out from under a live
  process and left a Dock tile with nothing behind it. The lock file, written at launch,
  now closes that gap.
- **Clicking an instance in the list did nothing.** A row containing a control does not
  initiate List selection on macOS, so the detail pane never filled in. Selection is now
  set explicitly by the row.
- **Health said "Everything is consistent" before it had checked anything.** It now sweeps
  once at startup and distinguishes "not checked yet" from "checked, all good", with the
  time it last looked.

Two were about honesty rather than crashes:

- A browse list is built from `Info.plist` alone. Treating "we have not run `codesign`
  yet" as "this app is unsigned" downgraded every app on the machine to Limited. Verdicts
  from a browse list are now marked provisional and labelled "likely supported".
- Chromium forks nest their helpers inside the versioned framework, so looking only in
  `Contents/Frameworks` classified Chrome, Brave and Edge as plain native apps and refused
  to isolate any of them. Detection now looks inside the framework, and browser "install
  as app" shortcuts are recognised as what they are and point the user at the browser.

The M0 harness had the same class of problem — it reproduced the pipeline by hand, drifted
out of step with the builder, and reported failures the shipped product did not have. It
now calls `InstanceBuilder` directly, so the experiments test what ships.

### Known limitations

Full clones have a new Keychain/TCC identity; Lite shares the original's. Full URL
schemes belong to one clone at a time; Lite cannot claim them. Self-updaters can overwrite
a Full clone's identity until you rebuild it. These limits are stated in the interface
before creation and in [LIMITATIONS.md](LIMITATIONS.md).
