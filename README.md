# LaunchAgain

Run two or more accounts of the same compatible Mac app at the same time. Full-compatible
apps get their own numbered Dock icon; Lite-compatible apps keep separate profiles while
sharing the original app's Dock icon.

You pick Claude, ask for three instances, name them *Personal*, *Work* and *Research*, and
end up with three apps in `~/Applications/LaunchAgain/` whose icons carry a
**1**, **2** and **3** badge. All three run at once. Each is signed into a different
account. Deleting #2 leaves #3 as #3. `/Applications/Claude.app` is never touched.

LaunchAgain creates and opens GUI applications only. Codex Desktop is supported through
its installed GUI bundle (`/Applications/ChatGPT.app`, bundle identifier
`com.openai.codex`) and is shown as **Codex** in the chooser. It never substitutes the
embedded `codex` command-line executable or opens a Terminal window.

**This does not bypass anything.** Each instance is a separate local profile for a
separate account you already have. If a service limits concurrent sessions, that limit
still applies. No SIP change, no Gatekeeper change, no root, no helper tool, no network
access of any kind.

---

## Project status and documentation

**Current beta release: 0.1.2.** This beta packages the hardened implementation that repairs cloned Electron windows whose saved title
bar is stranded on a disconnected or differently sized display, and hardens all queue and
logging code for Swift 6 strict concurrency, including sendable progress reporting and
service cleanup that remain portable across supported Swift toolchains. Window identity
now stays in the system title bar across sidebar changes instead of relying on an
OS-dependent AppKit bridge, and hosted CI is isolated by commit so delayed events cannot
cancel evidence for a newer revision. Repository workflows use the current official
Node 24 action majors, including `actions/checkout@v7`. If an
instance was created with an older release, install 0.1.2 and choose **Rebuild from Source
App** once; its number, name, and profile are preserved while the launcher receives the new shim.

- [Project site and release notes](https://odonnellmatt.github.io/LaunchAgain-site/)
- [Patch history](https://odonnellmatt.github.io/LaunchAgain-site/patches.html)
- [Maintainer guide](https://odonnellmatt.github.io/LaunchAgain-site/maintainers.html)
- [Download beta v0.1.2](https://github.com/odonnellmatt/LaunchAgain/releases/tag/v0.1.2)

This public repository is a de-identified beta snapshot. Maintainers use a separate private
source repository for day-to-day development, while GitHub Pages is deployed from a public
mirror containing only the intentionally public files in `site/`; it does not publish
diagnostics, local profiles or maintainer identity. After a documented patch, an
authenticated maintainer runs `./Scripts/publish-pages.sh`; the mirror's Pages workflow then
deploys only its `public/` directory.

### Installing the beta

Download the `LaunchAgain-0.1.2.dmg` asset from the release, open it, and drag
**LaunchAgain** to Applications. The beta is ad-hoc signed rather than notarized, so the
first launch may require Control-clicking the Applications copy and choosing **Open**, then
confirming **Open**. Existing clones should be rebuilt from their source application once
after installation so they receive the current launcher shim.

## Requirements

- macOS 13 or later (built and tested on Apple Silicon; the release build is universal)
- Xcode command line tools, for `swift build`, `codesign` and `iconutil`

## Build and run

```bash
./Scripts/build-app.sh --debug --run
```

That produces `build/LaunchAgain.app` and opens it. For a universal release
build, drop `--debug`. `./Scripts/package-dmg.sh` builds the release, assembles a DMG with
the documentation alongside it, and — if you set `MAL_SIGN_IDENTITY` and
`MAL_NOTARY_PROFILE` — signs with your Developer ID, notarises and staples. Neither an
Apple Developer account nor notarisation is needed to build or run it locally.

To work on it in Xcode, open `Package.swift` directly. There is no separate `.xcodeproj`:
the package *is* the project, and keeping one source of truth means the command line build
and the IDE build cannot drift apart.

The same engine is available headlessly:

```bash
swift build
.build/debug/launchagain scan
```

## The command line

```
launchagain scan                        List candidates and their compatibility tier
launchagain inspect <app>               Full report on one GUI application, with the reasons
launchagain create <app> --count N      Create N isolated GUI application instances
                                [--names "A,B,C"] [--lite]
launchagain list                        Show all managed instances
launchagain launch <selector>           Launch an instance
launchagain quit <selector>             Ask an instance to quit
launchagain rebuild <selector>          Rebuild from the current source app; data is preserved
launchagain rename <selector> <name>    Rename (the number never changes)
launchagain duplicate <selector>        New instance, same settings, empty profile
launchagain delete <selector>           Remove one LaunchAgain-owned instance and its data
launchagain renumber <app>              Explicitly renumber to 1…n
launchagain doctor                      Find orphans, stale builds and source updates
                                [--clean] [--purge-profiles] [--retire-legacy-store]
launchagain diagnostics [path]          Write a report you can attach to a bug
```

A selector is a UUID, an instance number (`2`), or `AppName#2`.

`--root <dir>` points the whole thing at an isolated data store, which is how the
integration tests run without touching your real instances. One caveat if you use it by
hand: an instance created under `--root` still runs under your real home directory, so it
writes `~/Library/Preferences/<clone-id>.plist` there, and uninstalling it cannot clean
that up — the cleanup is scoped to the alternate root's library. `launchagain doctor`
reports the leftover.

## What it does, mechanically

Two separate problems, two separate mechanisms.

**Isolation** is `--user-data-dir`. Electron and Chromium honour it, and it redirects
profile-resident state: auth tokens, cookies, local storage, IndexedDB, cache, and the
`SingletonLock` that otherwise enforces one-instance-per-app. Keychain and system privacy
records are separate limitations. This needs no modification to the source app at all.

**A separate Dock icon** needs a separate bundle, because macOS groups apps by bundle
identifier. So each instance is:

1. an APFS copy-on-write clone of the app (`cp -Rpc` — normally near-instant and
   initially close to zero additional disk blocks),
2. with a rewritten `CFBundleIdentifier` and `CFBundleDisplayName`,
3. a generated badged `.icns`,
4. a small compiled shim in place of the main executable, which `execv`s the real binary
   with `--user-data-dir` prepended and rescues a recognised off-screen Electron window
   state before launch,
5. re-signed ad-hoc, inside-out, with `com.apple.security.cs.disable-library-validation`
   added to the app's own entitlements.

Copying is only one stage. Patching and re-signing nested Electron code can take a while,
so the creation sheet switches immediately to a non-dismissible, step-level progress
screen. If cloning, patching, signing or verifying the Full launcher fails in a way Lite
mode can avoid, the instance is **not lost**. It falls back to Lite mode: no clone, a
small launcher that opens the original app with its own `--user-data-dir`. Isolation is
limited to profile-resident state; the original app's Dock, Keychain, privacy-permission
and URL-scheme identity are shared. A failure that occurs only when the target app itself
starts is reported at launch; the builder does not automate a live sign-in/launch probe.

## What works

| Kind | Examples on a typical Mac | Result |
|---|---|---|
| Electron apps | Claude, VS Code, LM Studio, Kimi, RStudio, Antigravity, jamovi, Tad, Keeper | Full when inspection reports it — numbered Dock icons |
| Chromium browsers | Google Chrome, Brave, Microsoft Edge | Full — numbered Dock icons |
| Codex Desktop | `/Applications/ChatGPT.app` (`com.openai.codex`) | Limited/Full in the current inspection — GUI clone and numbered Dock icon; listed Team-ID capabilities are removed |
| Command-line executables | `codex`, Claude Code | Refused — LaunchAgain launches GUI apps only |
| Sandboxed / App Store apps | WhatsApp, Telegram | Refused, with the reason |
| Native macOS apps | Microsoft Office, Zoom, VLC, Docker | Refused, with the reason |
| Browser web apps | "Install as app" shortcuts for Gemini, YouTube, NotebookLM | Refused — isolate the browser instead |

`launchagain scan --all` lists everything and `launchagain inspect <name>` explains any individual
verdict. [LIMITATIONS.md](LIMITATIONS.md) covers the why in full.

## Where things live

```
~/Applications/LaunchAgain/                   the numbered launcher apps
/Applications/LaunchAgain/                    the same, for apps that refuse to run
                                              anywhere but /Applications (LM Studio).
                                              Created only when one needs it.
~/Library/Application Support/LaunchAgain/
    registry.json                             instances and their permanent numbers
    registry.json.bak                         redundant copy of the same committed registry
    instances/<uuid>/userdata                 one profile per instance
    instances/<uuid>/logs                     per-instance logs
    logs/launchagain.log                      the launcher's own log
```

Those are LaunchAgain's own managed-state locations, and nothing leaves the machine.
While a generated application runs, macOS or that third-party application can also write
files under standard per-user Library and Darwin cache locations using the generated
clone identifier. LaunchAgain records no vendor-wide path and never searches by app name;
uninstall cleanup is restricted to an exact UUID and exact generated clone identifier.

Deleting an installed instance performs complete LaunchAgain-owned removal: its launcher
and entire `instances/<uuid>` directory (profile, cookies, local storage, cache, logs and
lock) are each moved to the Trash under a durable uninstall journal, its registry entry
and recovery marker are removed, and the shared size cache is invalidated. If interrupted,
that confirmed operation resumes on next launch. LaunchAgain asks macOS to clear the exact
generated preference domain and removes its exact plist when present. Exact clone-scoped
Preferences/ByHost, SyncedPreferences, Caches, updater, URL-session download,
Application Support, Saved Application State, HTTP storage, WebKit, Cookies, Logs,
Containers, Application Scripts, LaunchAgent and bounded Darwin cache/temp paths are
also removed when present. The original source app, other instances and any profile
directory the user explicitly placed outside LaunchAgain's folders are never deleted.
Items in the Trash remain recoverable until it is emptied. LaunchAgain asks Launch
Services to unregister only that exact launcher; it does not purge the shared
LaunchServices database. Shared macOS TCC and Keychain records are intentionally outside
this cleanup boundary.

That cleanup only runs when you uninstall through LaunchAgain. Dragging a launcher to the
Trash in Finder skips it, and what usually survives is one small file:
`~/Library/Preferences/<generated-clone-id>.plist`. `launchagain doctor` lists any it
finds, with the exact `defaults delete` command for each. It reports them and never
deletes them: the filename shows LaunchAgain generated the file, but not which instance
owned it, and a name pattern is not ownership.

If you upgraded from the first release, `launchagain doctor --retire-legacy-store` moves
the old `MultipleAppsLauncher` directory to the Trash after you type `retire` to confirm.
Read what it lists first — a profile in there may still hold a signed-in session.

## Persistence across restarts

Instance identity, permanent numbering, launcher paths and profile paths are committed to
`registry.json` with an atomic rename, a synchronized file, a redundant parseable copy and
a synchronized containing directory. Every read-modify-write of that file happens under an
advisory lock, and a number drawn for a build in progress is held under its own lock until
the build commits — so the interface and the command line can run at the same time without
issuing the same number twice or losing each other's writes. On macOS, LaunchAgain also requests a full storage
cache flush. A normal reboot therefore does not depend on any in-memory application state.

The numbered launcher bundles and each profile live in persistent user directories, not
temporary storage. Reopening LaunchAgain after login reconstructs the dashboard from disk.
The registry is atomically persisted in Application Support, and every newly built
launcher also carries a signed recovery record so **Refresh Installed Launchers** can
rebuild a missing entry after an uninstall/reinstall, provided the intact verifiable
launcher remains as an immediate `.app` child of one of the two launcher directories —
`~/Applications/LaunchAgain` or `/Applications/LaunchAgain`. The
profile must also remain for its signed-in session data to survive. Launchers made by the
first release are recognised from their generated Info.plist and instance configuration.
Damaged, duplicated or ambiguous launchers are reported rather than silently adopted.
LaunchAgain never removes an orphan profile
during startup. LaunchAgain does not automatically
relaunch account apps after login — launch the instance when you want it — but its existing
session data remains in that instance's profile.

## Signing in the first time

If an app signs in through a custom URL scheme — `claude://…` — only one Full launcher can
own that scheme at a time, so a sign-in link comes back to whichever Full launcher
registered last. Sign in one at a time; a Full instance has a **Claim URL Schemes**
action if ownership must be changed. A Lite launcher intentionally declares none of the
source app's schemes because it opens the vendor-signed original. Its browser callback may
therefore return to the original/default app rather than the intended profile; use an
in-app, device-code or password sign-in when the app offers one.

## Tests

```bash
swift test                          # 356 tests: core, engine, recovery, reboot, migration and hosted SwiftUI
swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete
./Scripts/integration-test.sh       # end-to-end against a synthetic app, in a scratch store
./Scripts/ui-regression-test.sh 3   # repeated 1→2→1 dashboard view-graph regression
./Scripts/publish-pages.sh          # publish the allow-listed de-identified Pages payload
```

`docs/VALIDATION.md` records what was verified on a real machine, with the commands and
their output, and a separate section listing what could not be verified.

The unit suite covers the parts that would be expensive to get wrong: number allocation
across create/delete/renumber, atomic registry writes, reboot reconstruction and backup
recovery, Info.plist and entitlement patching, argv construction with adversarial paths,
transaction rollback, and icon layout for 1, 2, 9, 10, 99 and 100. The macOS suite builds real clones of a synthetic
app and verifies the signature. The integration suite also proves that command-line
executables are rejected and that completed owned removal leaves no per-instance
directory or recovery marker at its original location.

`docs/manual-checklist.md` lists the things a human still has to look at, such as badge
legibility in the Dock.

## AI and maintainer instructions

Every human or AI maintainer must read this README, `AGENTS.md`, `CHANGELOG.md`, and the
documents relevant to the proposed change before editing code. `AGENTS.md` is the
authoritative operational contract. In particular:

1. Never test destructive operations against a real profile or source application. Use
   `--root`, temporary fixtures, and the synthetic integration application.
2. Do not weaken the exact-path deletion boundary, profile isolation, source-app
   immutability, local-only privacy model, or fail-closed shared-credential gate.
3. Add a regression test that fails for each fixed defect, then run the focused test, the
   full suite, strict-concurrency build, integration test, and package verification in
   proportion to the change.
4. Every patch or fix must update the current-release summary in this README,
   `CHANGELOG.md`, and `site/patches.html`. Update the Pages maintainer guide when the
   workflow, architecture, or release process changes, then run
   `./Scripts/publish-pages.sh` after the source change is committed.
5. Keep the repository de-identified: use `/Users/example`, `work@example.com`, and generic
   labels; never commit real names, usernames, email addresses, home paths, diagnostics,
   credentials, local settings, or user profiles.
6. Do not claim a check passed unless its output was observed. Record remaining manual or
   environment-dependent checks explicitly.

## Documents

- [LIMITATIONS.md](LIMITATIONS.md) — what does not work and why, in detail
- [SECURITY.md](SECURITY.md) — exactly what is signed, what ad-hoc signing means
- [PRIVACY.md](PRIVACY.md) — every file written, and the absence of telemetry
- [SPEC.md](SPEC.md) — the original engineering specification
- [research/](research/) — the Milestone 0 experiments and their results
- [AGENTS.md](AGENTS.md) — mandatory operating instructions for AI and human maintainers
- [CONTRIBUTING.md](CONTRIBUTING.md) — change, review, validation and release workflow
- [NOTICE](NOTICE) — third-party attribution
