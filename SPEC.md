# Multiple Apps Launcher — V1 Engineering Spec

**Status:** Draft 1 · **Target:** macOS 14+ (Apple Silicon first) · **Language:** Swift 6 / SwiftUI + AppKit

---

## 1. What we are building

A native macOS app that creates **numbered, isolated instances of Electron/Chromium desktop apps**, so a user with two or more legitimate accounts (personal + work, two subscriptions) can be signed into all of them at once, side by side, each with its own Dock icon.

**Concrete V1 success case:** the user picks Claude.app, asks for 3 instances, names them `Personal`, `Work`, `Research`, and ends up with three apps in `~/Applications/` whose icons carry a `1`, `2`, `3` badge; all three run simultaneously; each is signed into a different account; deleting #2 leaves #3 as #3; the original `/Applications/Claude.app` is byte-for-byte untouched.

### Explicit non-goals (do not build these; do not research them)

- No licence, DRM, subscription, authentication or server-side limit is bypassed. Each instance is a separate local profile for a separate account the user already owns. If a vendor limits concurrent sessions server-side, that limit stands and we surface it, we do not work around it.
- No SIP disabling, no Gatekeeper disabling, no permanent root, no privileged helper, no kernel extension.
- No VM / separate-macOS-user / Lima / Tart / QEMU isolation.
- No Keychain credential extraction, migration, decryption or copying — ever.
- No Mac App Store (sandboxed) app support in V1.
- No Intel-native support in V1 (Universal build, but only tested on Apple Silicon).
- No telemetry, no network calls of any kind in V1 except an explicit user-triggered "check source app version".

---

## 2. The one mechanism V1 uses

Research already done. Do not re-litigate this; validate it in Milestone 0 and build.

Isolation and Dock identity are **two separate problems** and V1 solves them with two separate, layered tricks.

### 2a. Isolation → `--user-data-dir` (no bundle modification)

Electron/Chromium honours `--user-data-dir=<path>`, which redirects *everything*: auth tokens, cookies, localStorage, IndexedDB, cache, config, Chromium `SingletonLock` (which is what enforces single-instance, so a distinct dir also removes the single-instance block). Verified working for Claude Desktop.

```bash
open -n -a "/Applications/Claude.app" --args --user-data-dir="$HOME/Library/Application Support/MultipleAppsLauncher/instances/<uuid>/userdata"
```

This is the *entire* isolation story for the V1 app class. It requires **zero** modification to the source app, zero re-signing, and cannot corrupt anything.

### 2b. Dock identity → cloned bundle with rewritten identity + ad-hoc re-sign

`--user-data-dir` alone gives every instance the same bundle path and same `CFBundleIdentifier`, so macOS groups them into one Dock tile with one icon. To get three distinct numbered Dock tiles we need three distinct bundles:

1. Clone with APFS copy-on-write: `cp -Rc <src>.app <dst>.app` — near-instant, ~0 extra disk until divergence.
2. Rewrite `Contents/Info.plist`:
   - `CFBundleIdentifier` → `<original>.mal.<uuid-short>` (mandatory for LaunchServices separation)
   - `CFBundleName`, `CFBundleDisplayName` → `Claude 2 – Work`
   - `CFBundleIconFile` → our generated badged `.icns`
   - Add `LSMultipleInstancesProhibited = false` if present as true
3. Write the badged `.icns` into `Contents/Resources/`.
4. Replace `Contents/MacOS/<exec>` with a tiny **compiled Swift shim** (not a shell script) that `execv`s the real binary with `--user-data-dir=<instance path>` prepended, preserving all other argv. Original binary renamed to `<exec>.real`.
5. Re-sign, **inside-out** (nested frameworks and helper apps first, then the outer bundle), ad-hoc:
   ```bash
   codesign --force --sign - --options runtime \
            --entitlements <patched.entitlements> <each nested item>
   codesign --force --sign - --options runtime \
            --entitlements <patched.entitlements> <bundle>.app
   ```
   Do **not** use `--deep` (Apple-deprecated, signs nested code wrong).
6. Register: `lsregister -f <bundle>.app`, then clear the icon cache for that path.
   *Caveat:* `lsregister` lives at an undocumented path inside `CoreServices.framework` and is not API. Prefer `LSRegisterURL` from the public Launch Services C API; keep `lsregister` as a fallback and probe for it rather than hard-coding. M0-4 must establish which of the two actually makes the new tile appear.

> **Critical gotcha, already identified:** ad-hoc signing (`-`) plus hardened runtime enables **library validation**, which rejects the pre-signed Electron frameworks because they carry the vendor's Team ID and the outer bundle now carries none. The patched entitlements file **must** add `com.apple.security.cs.disable-library-validation`. Extract the originals first with `codesign -d --entitlements :- --xml <src>.app`, add that one key, keep everything else. Do not disable hardened runtime wholesale.

### 2c. Graceful degradation — this is what makes the product "robust and stable"

If step 2b fails for a given app (signature won't validate, app crashes on launch, entitlement requires a real Team ID), **the instance is not lost.** The Instance Manager falls back to **Lite mode**: no clone, a small generated launcher `.app` that `open -n -a`'s the *original* bundle with `--user-data-dir`. Isolation still works perfectly; the Dock tile is shared and unbadged while running. The UI states this plainly per instance.

Every instance therefore has a `mode` of `full` or `lite`, and the app can promote/demote between them without touching user data.

### Known limitation to design around, not hide: URL scheme collision

Only one bundle can win registration of `claude://` (or any custom scheme). SSO sign-in that round-trips through a deep link will land in whichever instance registered last. **V1 must ship a guided first-login flow**: "Sign in to instances one at a time. Launch instance N alone, complete sign-in, quit, next." Once a session token is written to that instance's `--user-data-dir` it persists independently and the collision no longer matters. Add a `Claim URL scheme` button per instance that re-runs `lsregister -f` on that bundle.

---

## 3. Milestone 0 — falsifiable experiments (≈2 days, no UI, no Swift app)

Nothing else gets built until these pass. Each produces a one-page result in `research/M0-<n>.md` with the actual commands and output.

| # | Experiment | Pass condition |
|---|---|---|
| M0-1 | Launch Claude.app twice with two `--user-data-dir` values | Both run; sign in to two different accounts; both stay signed in after quit/relaunch |
| M0-2 | Confirm each instance's data lives only under its own dir | `fs_usage`/`lsof` shows no writes to `~/Library/Application Support/Claude` from an instanced process |
| M0-3 | `cp -Rc` clone + Info.plist rewrite + ad-hoc re-sign with `disable-library-validation` | `codesign --verify --deep --strict` passes; `spctl -a -vv` result recorded; app launches without crash |
| M0-4 | Two clones with different `CFBundleIdentifier` running at once | Two **separate** Dock tiles, two separate Cmd-Tab entries, clicking each raises the correct window |
| M0-5 | Badged `.icns` generated from source icon | Badge legible at 32px Dock size and 512px Finder; icon appears in Dock, Finder, Cmd-Tab, Spotlight |
| M0-6 | Executable shim `execv`s with injected arg | `ps -Ao args` shows `--user-data-dir`; app behaves normally. **Also check:** after `execv` the real binary sees itself at `<exec>.real` — confirm Electron's `process.execPath` / helper-process spawning still resolves correctly. If it does not, fall back to declaring the args in the clone's `Info.plist` or to Lite mode |
| M0-7 | Repeat M0-3/M0-4 on a second Electron app (Slack **or** Discord) | Same results, no app-specific code |
| M0-8 | Disk cost of a clone + a fresh instance profile | Actual MB recorded (expect clone ≈0 MB, Claude profile 1–2 GB after VM bootstrap) |
| M0-9 | Identify what "Codex" is on this machine | Written finding: if it is a CLI, its isolation is `CODEX_HOME`, which is **Provider B / not V1** — say so and move on |
| M0-10 | Source app self-update behaviour | Does the clone's Squirrel/Sparkle updater fire? Does it break the signature? Record the failure mode |

**Gate:** if M0-3 or M0-4 fails across both test apps, V1 ships Lite-mode only (isolation without numbered Dock icons) and full mode moves to V1.1. That is an acceptable outcome, not a project failure — decide it here, in writing, before any UI exists.

---

## 4. Data model

Single source of truth: `~/Library/Application Support/MultipleAppsLauncher/registry.json`, written **atomically** (write temp → `rename(2)`), with a `.bak` of the previous good version.

```jsonc
{
  "schemaVersion": 1,
  "apps": [{
    "appKey": "com.anthropic.claudefordesktop",
    "sourcePath": "/Applications/Claude.app",
    "sourceBookmark": "<base64 security-scoped bookmark>",
    "sourceVersion": "1.4.2",
    "nextInstanceNumber": 4,          // monotonic, never decremented
    "instances": [{
      "id": "6f1c…",                  // UUID, immutable
      "number": 2,                    // immutable, unique per app, never reused
      "name": "Work",
      "accountLabel": "work@example.com",
      "mode": "full",                 // full | lite
      "bundlePath": "~/Applications/Multiple Apps Launcher/Claude 2 – Work.app",
      "dataPath": "…/instances/6f1c…/userdata",
      "badge": { "position": "bottomTrailing", "color": "#1B6EF3", "style": "numberOnly" },
      "builtFromSourceVersion": "1.4.2",
      "createdAt": "…", "lastLaunchedAt": "…",
      "lastKnownPID": null
    }]
  }]
}
```

**Numbering rule (hard requirement):** `number` comes from `nextInstanceNumber++` and is never recomputed. Deleting #2 leaves #3 as #3 and the next new instance is #4. A separate, explicit **Renumber…** command is the only thing that may change numbers, and it rebuilds icons and bundle names as a single transaction.

---

## 5. Components (five, not eight)

| Component | Responsibility | Explicitly not its job |
|---|---|---|
| **AppScanner** | Enumerate `/Applications`, `~/Applications`, user-picked folders. Read `Info.plist`, version, arch, entitlements, code-sign info. Detect Electron (`Contents/Frameworks/Electron Framework.framework`), Squirrel/Sparkle, MAS receipt, sandbox entitlement. | Deciding policy |
| **CompatibilityAnalyser** | Map scan output → one of three tiers (§6) + a plain-English limitations list shown *before* creation | Guessing; unknown ⇒ `Untested` |
| **InstanceBuilder** | The whole §2b pipeline as a **transaction**: stage into a temp dir, verify, then atomically move into place. Any failure ⇒ full rollback ⇒ retry as Lite ⇒ report | Launching |
| **IconFactory** | Extract source `.icns` → render badge with Core Graphics → emit full `.iconset` (16–1024 @1x/2x) → `iconutil -c icns`. Auto-shrink font and widen the badge pill for 2- and 3-digit numbers. Preview before build. Cache by (sourceIconHash, number, style) | Touching the source app's icon |
| **LaunchSupervisor** | Launch via `NSWorkspace.openApplication(at:configuration:)` with the instance's arguments. Track PID, detect crash-on-launch (<3 s exit), capture stderr to `instances/<id>/logs/`. Refuse to launch two processes against the same `dataPath` | Shelling out |

**Hard rule:** no component constructs a shell command string from a user-supplied path or name. Use `Process` with an argument array, or POSIX APIs, everywhere. Paths with spaces, `'`, `"`, `$`, and non-ASCII names are in the test matrix.

---

## 6. Compatibility tiers (three, not six)

Shown to the user *before* they create anything.

| Tier | Meaning | Shown as |
|---|---|---|
| **Supported** | Electron/Chromium, not sandboxed, not MAS, entitlements re-signable | "Full isolation — separate accounts, separate numbered Dock icons" |
| **Limited** | Electron but re-signing failed or entitlements need a real Team ID | "Separate accounts and data. Instances share one Dock icon while running." |
| **Not supported** | Sandboxed / MAS / non-Electron native / no known profile mechanism | "Can't isolate this app safely yet." + one-line reason |

Every tier card additionally states, always: **Keychain is not isolated in V1**, and **your vendor's own concurrent-session rules still apply.**

---

## 7. Interface — one window, three screens

**Dashboard** — list of instances grouped by source app. Each row: badged icon, `#2`, name, account label, tier chip, `full`/`lite` chip, running dot, disk used, "source updated — rebuild available" chip. Actions: Launch · Quit · Rename · Edit badge · Reveal in Finder · Open data folder · View logs · Rebuild · Duplicate · Delete.

**Create flow** — pick app (browse/search/drag-drop `.app`) → compatibility card with limitations → how many (1/2/3/custom) → per-instance name + account label + live badge preview → review (numbers assigned, disk estimate, install location, what stays unchanged) → build with per-step progress → summary including the *guided first-login instructions* from §2.

**Instance detail** — everything in the row, plus advanced (collapsed, with warnings): extra CLI args, extra env vars, custom data dir, force Lite mode.

V1 accepts **`.app` only** as a source. DMG/PKG/ZIP import is V1.1 — mounting and extracting installers is a separate risk surface and is not required by the success case.

---

## 8. Safety rules (non-negotiable)

1. The source app is opened read-only. It is never written to, moved, renamed, re-signed or updated by us. Verify by hashing `Contents/Info.plist` + `_CodeSignature/CodeResources` before and after every build.
2. Build, rebuild, repair and renumber are staged in a temp dir and moved into place with `rename(2)`. A crash mid-operation leaves either the old state or the new one, never a half-written bundle.
3. Deleting an instance offers three choices, never assumed: *remove launcher only* / *remove launcher + data* / *cancel*. Data deletion requires typing the instance name.
4. Rebuild-after-update **never** touches `dataPath`. Only the bundle is regenerated.
5. Startup runs an orphan sweep: registry entries whose bundle is gone, bundles with no registry entry, data dirs with no owner. Report; never auto-delete.
6. Diagnostics export includes logs, registry, `codesign -dvvv` output — and never the contents of any `dataPath`.

---

## 9. Test matrix

**Unit:** number allocation across create/delete/renumber · atomic registry write under simulated crash · Info.plist patching · entitlement patching · icon layout for 1/2/9/10/99/100 · argv construction with adversarial paths (spaces, quotes, `$(…)`, emoji, RTL) · rollback.

**Integration (scripted, real apps):** create 1/2/3/5 instances · launch all simultaneously · verify distinct PIDs and distinct Dock tiles · verify no cross-writes with `fs_usage` · quit and relaunch, sessions persist · delete #2, confirm #3 stays #3 · reboot, confirm numbers and icons survive · update source app, rebuild, confirm number + name + badge + data survive · force a signing failure, confirm automatic Lite fallback and no orphan bundle · run with the source app on an external volume.

**Manual checklist:** badge legibility at every Dock size · Cmd-Tab · Spotlight · Launchpad · Mission Control · Finder icon · Gatekeeper first-launch behaviour on a clone · TCC prompts (each clone is a new bundle ID, so it will re-prompt for screen recording / mic / notifications — this must be documented for the user, not suppressed).

---

## 10. V1 acceptance criteria

1. User selects an installed Electron app and creates 3 instances in under 2 minutes.
2. Instances are permanently numbered 1, 2, 3; numbers survive quit, reboot, rename and rebuild.
3. Deleting #2 leaves #3 as #3; the next instance is #4.
4. Each instance's icon shows its number, legibly, in the Dock.
5. All 3 run simultaneously with 3 separate Dock tiles (Supported tier) — or 1 shared tile with a clearly-labelled Limited tier.
6. Three different accounts stay signed in across restarts.
7. `/Applications/Claude.app` is provably unmodified (hash check in the test suite).
8. Any failed build rolls back completely: no orphan bundle, no orphan data dir, no broken LaunchServices entry.
9. No SIP change, no Gatekeeper change, no root, no privileged helper, no network traffic.
10. Unsupported apps are refused with a specific reason, never silently half-supported.
11. Keychain-sharing and concurrent-session limitations are stated in the UI before creation.

---

## 11. Deliverables (11, not 27)

1. `research/M0-*.md` — the ten experiment results
2. Swift package + Xcode project, building on Apple Silicon
3. `AppScanner`, `CompatibilityAnalyser`, `InstanceBuilder`, `IconFactory`, `LaunchSupervisor`
4. SwiftUI interface (three screens)
5. Unit + integration test suites, plus the manual checklist
6. `README.md` — build and run
7. `LIMITATIONS.md` — Keychain, URL schemes, TCC re-prompts, self-updaters, server-side session caps
8. `SECURITY.md` — exactly what we sign, what ad-hoc signing means, what we never touch
9. `PRIVACY.md` — local-only, list of files written, no telemetry
10. `NOTICE` — third-party licences and attribution
11. DMG packaging + Developer ID signing/notarisation script for the launcher itself

---

## 12. Roadmap (deliberately out of V1)

| Version | Adds |
|---|---|
| V1.1 | DMG / PKG / ZIP import; export/import instance configs; auto-detect source updates |
| V1.2 | **Provider B — config-dir env vars** (`CODEX_HOME`, `XDG_CONFIG_HOME`, app-specific `HOME`-style redirection) for CLI-backed and native apps |
| V1.3 | Declarative JSON adapter format + adapters for apps needing per-app quirks |
| V2 | Sandboxed / Mac App Store apps (bundle-ID-keyed containers give free isolation *if* signing can be solved); native AppKit/SwiftUI apps via `NSUserDefaults` suite redirection |
| Never | VM-based and separate-macOS-user isolation; Keychain credential handling |

---

## 13. Build order

**M0** experiments → gate decision · **M1** headless `InstanceBuilder` + `IconFactory` + CLI harness that creates and launches 3 badged Claude instances · **M2** registry, numbering, atomic transactions, rollback, orphan sweep · **M3** SwiftUI dashboard + create flow · **M4** rebuild-after-update, repair, diagnostics, Lite fallback polish · **M5** tests green, docs, DMG, notarisation.

Do not start M3 until M1's three badged instances are demonstrably running side by side with three different accounts signed in.
