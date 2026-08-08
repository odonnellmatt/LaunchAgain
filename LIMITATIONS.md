# Limitations

Everything here is stated in the interface before you create anything. It is repeated in
full because a limitation you find out about after signing in three times is not a
limitation, it is a bug report.

---

## 0. Some apps keep their session outside the profile, so instances are not separate accounts

This is the first limitation because it is the one that can make creating an instance
pointless, and because it has already cost a user their sign-ins.

LaunchAgain's isolation mechanism is `--user-data-dir`: it moves an application's
Chromium profile — cookies, local storage, IndexedDB, cache, the single-instance lock —
into a directory of its own. That is the whole mechanism. **If an application keeps its
signed-in session anywhere else, redirecting the profile does not separate anything the
user cares about.**

### The worked example: ChatGPT

Measured on the reporting machine, and the evidence is in docs/VALIDATION.md:

- A **Full** clone — a separate bundle, a new identifier, an ad-hoc signature, and every
  team-bound entitlement (`keychain-access-groups`,
  `com.apple.security.application-groups`, `com.apple.developer.team-identifier`)
  stripped — started **signed in**, and loaded the user's own conversation threads.
- The **same clone**, launched with `CODEX_HOME` pointing at an empty directory, started
  **signed out**: `hadToken=false`, `skipRetryReason=no_token_attached`, and no
  `auth.json` was created.

So for this application the session is not in the Keychain and not in the App Group
container. It is `$CODEX_HOME/auth.json` — default `~/.codex` — a plain file in the home
directory, read by the `codex` app-server the desktop app spawns, by absolute path,
regardless of bundle identity or signature. `--user-data-dir` does not touch it.

That is what the user observed: they signed out of an instance and every copy of ChatGPT
signed out, because there is only one file.

### What LaunchAgain does about it

**Detects.** Three signals, and their honesty differs:

| Signal | What it proves | Which modes it affects |
|---|---|---|
| `keychain-access-groups` entitlement | The app is designed to share Keychain items between the vendor's own binaries. A signal, not proof of where the session is. | **Lite only.** A Full clone is ad-hoc signed with the entitlement stripped and cannot read the vendor's items at all — that is §1, and it is the security model working. |
| `com.apple.security.application-groups` entitlement | The app has a container under `~/Library/Group Containers`. | **Lite only**, as far as has been established. macOS does not vend the container to a clone whose entitlement was stripped, and it was measured *not* to be the mechanism for the one app where a Full clone did inherit a session. The container is still an ordinary directory, so an app reaching it by absolute path would share it; that has not been ruled out for every app and the wording says so. |
| A measured configuration home | Proof, for the one application it has been measured on. Not a heuristic on identifiers — an app with a similar bundle identifier does not inherit it. | **Both.** A plain file in the home directory read by absolute path; no signature, identifier or entitlement is involved. |

That distinction is load-bearing rather than pedantic. Saying "instances of this app are
not separate accounts" of every signal made the compatibility card contradict its own
headline for Claude — which declares shared Keychain groups and nothing else, and whose
Full instances work correctly. The unqualified sentence now appears only where something
is shared by a Full clone too; everywhere else it is scoped to Lite.

**The refusal is not scoped.** Lite mode is gated for *any* of these signals, because
Lite runs the vendor-signed original and inherits all of them. Over-warning is the safe
direction there and under-warning is not.

**Discloses, before anything is created.** The compatibility card leads with the
consequence — "these will not be separate accounts" where a Full clone shares the store
too, and "a *Lite* instance of this app will not be a separate account" where only Lite
does — names it in the user's terms, and lists each store. The headline is computed from
the same fact, so it cannot claim separate accounts above a line denying them.

**Refuses Lite mode** unless you acknowledge the consequence explicitly. Lite runs the
vendor-signed original binary, so it has the original's Keychain identity, the original's
App Group containers and the original's home directory — it separates nothing such an app
cares about. `--acknowledge-shared-credentials`, or a checkbox in the create flow that
blocks Next. A Full build that falls back to Lite is refused on the same terms, because
degrading silently into the mode that was just refused is how the sessions were lost.

The refusal is about *introducing* a shared session, so rebuilding a launcher that is
already Lite on disk — the same instance, at the same mode — proceeds without asking
again, and records no acknowledgement it was not given. Converting an existing Full
instance to Lite still asks. If the launcher on disk is not Lite, or cannot be read, the
rebuild is treated as introducing one and is refused.

**Never touches the Keychain.** Not to read it, not to copy it, not to partition it, not
to "fix" this.

### The route out, where there is one

For ChatGPT there is one, and it is yours to take rather than ours to apply: set
`CODEX_HOME` to the instance's own directory under **Advanced → environment variables**
on the instance detail screen. That gives the instance a genuinely separate session — it
is the mechanism the roadmap calls Provider B. LaunchAgain does not set it for you,
because moving where an application keeps its configuration relocates data you already
have, and that is a decision rather than a default.

For a Keychain-backed store there is no route out, and none is invented.

## 1. Keychain behavior depends on mode

macOS binds Keychain items to the signing identity of the app that created them. A clone
is signed ad-hoc, by this machine, with no Team ID — so it is a different identity, and it
**cannot read anything the original app saved**.

That describes Full mode. Lite mode launches the vendor-signed original app and therefore
shares its Keychain identity. LaunchAgain does not read, copy or partition those items;
only state inside the redirected Chromium profile is separate in Lite.

That is the security model working correctly, not something to route around. This project
never reads, copies, decrypts or migrates a credential, and it never will.

What it means in practice:

- A Full clone normally requires a fresh sign-in and separate Keychain setup.
- A Lite instance may see the original app's Keychain-backed state because its target
  process has the original vendor identity.
- An account app must keep the relevant session in its Chromium profile for Lite
  instances to remain distinct.

## 2. Only one instance can own a URL scheme

Custom schemes — `claude://`, `slack://` — are registered per bundle, and macOS gives the
scheme to one bundle at a time. A Full clone preserves the source schemes, so a browser
deep link returns to **whichever Full instance registered last**, not necessarily the one
you started from.

The workaround is simple and permanent:

1. Launch one instance on its own.
2. Sign in. Quit it.
3. Next instance.

After the first sign-in the session normally lives in that Full instance's own profile and
the collision stops mattering. Full instances have a **Claim URL Schemes** action, which
re-registers the selected clone as current owner.

A Lite launcher has no source-app URL schemes to claim. It opens the original app, so a
browser callback can return to the original/default app rather than the intended Lite
profile. Use an in-app, device-code or password sign-in when available. The interface
disables URL-scheme claiming for Lite.

## 3. Privacy-permission identity depends on mode

A Full clone's new bundle identifier means new TCC (privacy) records. Expect fresh prompts
for notifications, microphone, camera, screen recording, Accessibility, and Files and
Folders the first time each Full instance uses one.

This is deliberate and it is not suppressed. Any mechanism that carried the original app's
permissions across to a clone would be a mechanism for granting permissions the user never
gave.

Full instances also appear as separate apps in System Settings → Privacy & Security.
Removing one leaves its entry there; macOS does not offer an API to clean it up. A Lite
instance runs the original application and shares that application's TCC identity instead.

## 4. Your provider's rules still apply

This tool separates local profiles. It does not touch licensing, subscriptions,
authentication or any server-side limit. If a service allows one concurrent session per
account, you will still get one — signing into the same account twice locally does not
change what the server does.

Use it for accounts you already have: personal and work, two subscriptions, a client's
account and your own.

## 5. An instance does not update itself, and that is the trade

A clone is a separate bundle, so the *original* application's updater never reaches it.
The one that can reach it is the clone's own: it inherits the vendor's feed, fires on the
vendor's schedule, and when it applies an update it replaces the whole `Contents`
directory — the rewritten `Info.plist`, the numbered icon, the shim, the renamed
executable and our ad-hoc signature all go, and the instance rejoins the original's Dock
tile carrying someone else's identity.

So **instances are non-self-updating by default**, in two halves:

- **Squirrel and electron-updater.** `Squirrel.framework`'s `ShipIt` helper — the separate
  process Squirrel spawns to swap the bundle — and `Contents/Resources/app-update.yml` are
  removed from the clone. The framework itself stays, because the application links
  against it and removing it would stop the clone launching at all. Without `ShipIt` the
  download still happens and the install step fails, which Squirrel already has an error
  path for.
- **Sparkle, in Info.plist.** `SUFeedURL` is moved to `MALOriginalSUFeedURL` rather than
  discarded, and automatic checks and automatic install are set to `false` — always, not
  only when some other Sparkle key happened to be declared. Sparkle's default is to
  prompt, and a prompt is an update path.
- **Sparkle, on disk.** `Autoupdate`, `Updater.app` and the `Installer.xpc` and
  `Downloader.xpc` services are removed, versioned files and the symlinks that point at
  them. This is the same trade as `ShipIt`: the framework the application links against
  stays, so the clone still launches; what goes is the machinery that *applies* an
  update.

A clone carries `MALEmbeddedUpdaterNeutralised` listing what was actually neutralised —
and **not at all** when nothing was. The previous release wrote `true` unconditionally,
including for clones where nothing had been done.

### Where this still cannot reach

An application that sets its update feed from its own code rather than from `Info.plist`
is beyond a plist edit. ChatGPT is exactly that: it declares only `SUPublicEDKey` and
assigns the feed at runtime from `Contents/Resources/native/sparkle.node`. Such a clone
can still check for and download an update — it simply has nothing left to install it
with, because the installer chain above is gone. If an update ever does replace an
instance's identity, rebuild it; the profile is unaffected. The create flow says this
rather than promising otherwise.

**What this costs you.** An instance stays at the version it was built from until you
rebuild it. The dashboard still shows a "Rebuild available" chip when the source
application moves ahead, because that comes from comparing the instance's recorded source
version against the source app — both untouched. *Rebuild* regenerates the bundle from
the current source app and **keeps the profile and the sign-in inside it**.

**The opt-out.** `--allow-self-update`, and an advanced toggle on the create flow's review
step, restore the vendor's update path. Both default to off. The setting is not recorded
on the instance, so a later rebuild returns it to the default; if you want a
self-updating instance permanently you will need to say so each time you rebuild.

The original application is never updated, modified or interfered with by any of this, and
it keeps its own `ShipIt`, its own `app-update.yml` and its own Sparkle feed.

## 5a. Some apps refuse to run outside /Applications

LM Studio compares its install location against the literal prefix `/Applications/`. Run
from `~/Applications/LaunchAgain` it logs *"App is not running from /Applications. It is
running from …"* and then opens no window at all — the process stays alive and the
application never appears.

A clone one directory *inside* `/Applications` satisfies that test, so instances of such
an app are installed in **`/Applications/LaunchAgain/`** rather than in your own
Applications folder. That is a single owned directory, not launchers scattered loose in
`/Applications`, and it is what keeps the ownership boundary provable: LaunchAgain will
only ever delete inside one of its two named directories, and a bundle sitting beside
them in `/Applications` is refused.

`/Applications` is admin-writable rather than user-writable. LaunchAgain creates
`/Applications/LaunchAgain` on demand, and if it cannot, it names the directory and says
an administrator is usually needed — distinguishing "it does not exist and cannot be
created" from "it exists and is read-only", which are different problems with different
answers. It does not ask for administrator rights and does not install a helper tool.

It does **not** offer to install the instance somewhere else instead. There is no
user-facing choice of launcher root for it to point at, and for LM Studio — the one
application that needs this directory — your own Applications folder is the single place
it will not run.

Which applications need this comes from a small table of ones that have actually been
measured, because the check is inside the application's own code and there is no static
signal for it. Any other app can still be installed there deliberately.

## 5b. An app that sets its own Dock icon keeps setting it

The numbered icon is generated, written into the clone as `MALAppIcon.icns`, declared as
`CFBundleIconFile`, and `CFBundleIconName` is removed so an asset catalogue cannot outrank
it. macOS resolves that icon for the clone — verified against a real ChatGPT clone and
rendered for inspection in `docs/evidence/`. Finder, Spotlight and Cmd-Tab show the
number.

**The Dock tile of a *running* application is a different thing.** An app can replace it
at any moment by setting `NSApplication.applicationIconImage`, or `app.dock.setIcon` in
Electron. ChatGPT does exactly this from its own code, driven by a dock-icon preference,
and on anything but the default it substitutes one of its own PNGs from
`Contents/Resources`.

LaunchAgain cannot override that without modifying the application's own code, which this
project does not do. So for an app in this class: the Finder, Spotlight and Cmd-Tab icon
carries the number, and the running Dock tile is whatever the application chose. There is
no fix for this that would work, and shipping one that did not would be worse than saying
so.

A second, separate cause is macOS caching icons by *path*: create an instance where a
previous one lived — delete "Claude 1 – Work" and make another with the same name — and
the Dock could show the old icon. That one is ours and is fixed: every install bumps the
modification date of the bundle, its `Info.plist` and its `.icns`, which are three
separate cache keys, and re-registers with Launch Services.

## 6. The internal name of a clone is left alone

Chromium and Electron locate their own child processes by concatenating `CFBundleName`
with " Helper": the renderer lives at
`Contents/Frameworks/<CFBundleName> Helper (Renderer).app`.

Rewriting `CFBundleName` therefore makes an app look for `Claude 2 – Work Helper.app`,
fail to find it, and abort at startup with `FATAL: Unable to find helper app`. So when a
bundle is laid out that way, the clone keeps the original `CFBundleName` and takes its
visible identity from `CFBundleDisplayName`, which is what Finder, the Dock, Spotlight and
Cmd-Tab actually display.

The one visible consequence: the **menu bar** may show the original app's name rather than
the instance name. The Dock icon still carries the number.

## 7. Lite mode isolates the profile, not the macOS app identity

If a clone cannot be built, signed or verified, the instance is **usually** rebuilt in
Lite mode: a small launcher that opens the *original* app with the instance's own
`--user-data-dir`. The build does not automate a live application launch, so a problem
that appears only when the target app starts is reported at launch rather than silently
triggering fallback.

The exception is an application whose signed-in session lives outside the profile — the
ones the compatibility card calls out. For those, Lite mode separates nothing that
matters, so a failed Full build is **refused** rather than quietly turned into a Lite
instance, unless you have already accepted the shared-session consequence for that
instance. Degradation is not a way around a gate you were shown.

- Chromium profile: separate. Cookies, local storage, IndexedDB, cache and the
  single-instance lock are routed to the instance directory.
- Dock: the instance shares the original app's tile and icon while running, so you cannot
  tell two running Lite instances apart from the Dock.
- Cmd-Tab: one entry.
- System identity: shared with the original app, including Keychain, TCC/privacy
  permissions and URL schemes.

Every instance shows its mode, and the compatibility card says up front when an app is
expected to need it.

## 8. GUI applications only

LaunchAgain accepts macOS `.app` bundles and launches GUI applications. It does not turn
`codex`, Claude Code or another command-line executable into a Terminal launcher.

Codex Desktop is supported through `/Applications/ChatGPT.app`, whose bundle identifier
is `com.openai.codex`; LaunchAgain labels it **Codex** in the chooser. The currently
inspected Codex build is classified Limited because Team-ID-bound capabilities must be
removed, but Full remains the recommended mode: it builds a GUI clone with a numbered
Dock icon. If a future build is recommended or degraded to Lite, the mode-specific shared
identity limits above apply.

Older Terminal-based launchers made by an earlier build remain visible after upgrade so
they can have their LaunchAgain-owned files and data removed, but their launch, rebuild,
duplicate, renumber and URL-scheme actions are disabled. The code that built them has been
removed, not merely fenced off, so nothing can create another one.

One consequence is worth stating rather than leaving to be discovered: a launcher built by
the earlier release carries **that release's shim** inside its own bundle. LaunchAgain
refuses to launch it, and the current shim fails closed on a legacy configuration, but
double-clicking the old bundle in Finder still runs the old binary and would open Terminal.
Rewriting and re-signing a bundle you have not asked us to touch is not something this
project does, so the remedy is to uninstall the instance — which removes the launcher and
its session directory together.

## 9. What cannot be isolated at all, and why

| Kind | Why |
|---|---|
| **Sandboxed / Mac App Store apps** (WhatsApp, Telegram) | A sandboxed app's container is keyed to its signed identity, and re-creating that identity needs the original developer's Team ID — which we do not have and would not forge. |
| **Native macOS apps** (Office, Zoom, VLC, Docker, most menu-bar utilities) | State lives under a path derived from the bundle identifier, and nothing supported redirects it from outside the app. Cloning gives a new identifier and therefore an empty state, but also loses Keychain access and every Team-ID-bound entitlement — a broken copy, not a second account. |
| **Browser web apps** ("install as app" shortcuts for Gemini, YouTube, NotebookLM) | Not applications: the executable asks an installed browser to open one site. The session belongs to the browser. Isolate the browser instead — Chrome, Brave and Edge are all supported, and each instance has its own web apps. |
| **Command-line executables** | LaunchAgain's contract is GUI applications and numbered app launchers. Executables are rejected instead of opening Terminal. |

`launchagain inspect <name>` gives the specific reason for any individual app.

## 10. Gatekeeper, quarantine and the clones

A clone is signed ad-hoc, so it is not notarised and `spctl` rejects it. That is expected
and is recorded in the diagnostics rather than hidden.

It does not stop the clone running, because the clone is produced locally by copying an
app you already have. The builder strips `com.apple.quarantine` from only the clone it
just created, so a stale attribute inherited from the source cannot produce a misleading
"downloaded from the internet" prompt for a file nobody downloaded. Nothing else on the
system is touched, and Gatekeeper is not disabled or weakened.

## 11. Disk

A clone uses APFS copy-on-write, so it costs close to zero extra space until the app
updates. `du` will still *report* the full size against the clone, because it counts
shared blocks — the free space on the volume is the honest measure.

Profiles are the real cost. An Electron profile is a few hundred megabytes after normal
use; Claude Desktop bootstraps a local runtime and can reach a couple of gigabytes. The
review screen estimates this before you commit, and the dashboard shows an approximate,
cached allocated size per instance.

If the destination is not on an APFS volume, cloning falls back to a real copy and the
build says so.

## 12. Things this deliberately does not do

- No automatic relaunch of account apps after login. Their profiles and LaunchAgain
  metadata persist across reboot; you choose when to start each instance again.
- No VM, no second macOS user account, no container runtime.
- No SIP or Gatekeeper changes, no root, no privileged helper, no kernel extension.
- No `HOME` redirection: it breaks Keychain, TCC and sandbox lookups, so the launcher
  refuses it as an environment variable even when asked directly.
- No network access. Nothing is sent anywhere, including crash reports.
- No Keychain reading, copying, migration or decryption.
- No profile copying between instances. Duplicating an instance copies its *settings* and
  gives it an empty profile, because copying a profile would copy a signed-in session into
  a second place — the opposite of the point.

### What uninstall deliberately leaves behind

Uninstalling an instance removes an exact allow-list of paths keyed to that instance's
*generated* identifier — its preferences, caches, HTTP storage, saved state, WebKit data,
containers and group container. Measured against a real ChatGPT clone: it wrote four such
paths and all four were removed.

Three things are left, on purpose, and a disk cleaner may notice them:

| Left behind | Why |
|---|---|
| `~/Library/Logs/<vendor-id>/` | Written under the **vendor's** identifier and shared with the original application and every other instance. Removing it when one instance goes would delete the original's logs. |
| `~/.codex`, and any other home-directory configuration | The same store the original reads (see §0). Removing it on uninstall would sign you out of every copy of the application — the exact failure this release exists to prevent. |
| `~/Library/Group Containers/<TEAMID>.<vendor>` | Shared between the vendor's own binaries. Only a group container keyed to the generated identifier is ever a candidate. |

An uninstaller that removes files it cannot prove it owns is a worse product than one that
leaves something behind and tells you what.

## 13. The dashboard uses HSplitView, not NavigationSplitView

The window's three columns are an `HSplitView` rather than the platform-standard
`NavigationSplitView`. This is a deliberate trade and it costs something, so here is what
happened and what was measured rather than a one-line assertion.

**The failure.** Deleting an instance could leave the window blank: the detail pane kept
showing a stale instance while the sidebar and dashboard columns disappeared and never
came back. The reproduction is: select a row, open the delete confirmation sheet, dismiss
it, then remove that selected row. The cause was **not** the container and not an implicit
animation. It was that `.sheet` was presented from a view whose identity belonged to the
dynamic part of the navigation tree. When the presenting view's identity changed while the
dismissal was still in flight, the sidebar and content subtrees were torn down and not
rebuilt.

**The fix that mattered** is `PresentationHost`: a 1×1 `Color.clear` sibling *outside* the
split container owns every sheet, and its identity never changes. Replacing
`NavigationSplitView` with `HSplitView` was a second change made at the same time.

**What was measured, honestly.** With `PresentationHost` in place, `NavigationSplitView`
was put back and the dashboard regression suite re-run. Every behavioural assertion
passed — responsiveness, selection repair, external-watcher refresh, and
`testSheetDismissalThenDeletionKeepsDashboardStateCoherent`, which is the exact
reproduction above. The only failures were the suite's structural probe, which requires an
`NSSplitView` with exactly three non-divider subviews; `NavigationSplitView` on this macOS
produces four (three `_NSSplitViewItemViewWrapper`s plus a `_NSSplitViewShadowView`).

So `NavigationSplitView` is **not** known to be unsafe here. It is not shipped because
restoring it would require rewriting that regression probe, and this release was required
to leave that suite untouched. That is a process constraint, not a technical verdict, and
it is recorded here rather than dressed up as one.

**What the trade costs.** The unified toolbar/sidebar integration `NavigationSplitView`
provides — the translucent sidebar running under the title bar, and the system-managed
column-visibility animation — is not present. Sidebar collapse is no longer missing: it is
implemented directly, with a toolbar button, a **View ▸ Hide/Show Sidebar** menu item and
⌃⌘S, and the choice is remembered between launches. Hiding the sidebar is the only
structural change this container makes to its own child list, so it has its own regression
tests covering repeated toggling and toggling around the sheet-dismissal sequence above.

## 14. Display recovery is deliberately schema-limited

Some Electron applications store their last window in a top-level `window-state.json`.
When a large display is disconnected, that file can still place the title bar completely
outside the smaller display. The only visible result may be a thin, immovable edge until
the application is quit.

New or rebuilt LaunchAgain launchers recognise the common object containing numeric
`x`, `y`, `width`, `height`, and `displayBounds`. If a draggable portion of the saved title
bar intersects no active display, the launcher centres the window inside the main
display's usable frame and saves the first original as
`window-state.json.launchagain-backup`. It leaves an already reachable window byte-for-byte
unchanged and refuses malformed, oversized, symbolic-link, or unfamiliar files.

This is not a general-purpose preference editor. Applications that persist geometry under
another filename or schema remain the vendor application's responsibility. The repair
runs immediately before launch; it cannot move a window whose application is already
running. A launcher built before beta 0.1.2 must be rebuilt once to receive this behaviour.
