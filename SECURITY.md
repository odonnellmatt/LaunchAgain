# Security

What this program signs, what it never touches, and what an ad-hoc signature actually
means for you.

---

## The short version

- The source application is opened **read-only**. It is never written to, moved, renamed,
  re-signed or updated. This is enforced by code, not by intent: the builder fingerprints
  `Contents/Info.plist` and `Contents/_CodeSignature/CodeResources` before and after every
  build, and refuses to report success if either changed.
- No SIP change, no Gatekeeper change, no root, no `sudo`, no privileged helper, no login
  item, no kernel extension, no launch daemon. `ProcessRunner.Tool` enumerates every
  executable LaunchAgain will ever launch, by absolute path, and they are all
  Apple-supplied. One error message — the one for an install directory that exists but is
  read-only — *suggests* `sudo chown -R $(whoami) …` for you to run yourself, and says in
  the same breath that LaunchAgain will not run it. Suggesting a command and executing
  one are different acts.
- No network access of any kind.
- No Keychain item is read, copied, exported, decrypted or migrated. Ever.
- The supported GUI creation and launch path never runs through a shell. Every external
  build command is invoked with an argument array.

## What gets signed, and with what

A Full clone is signed **ad-hoc** (`codesign --sign -`): a signature generated on this machine,
carrying no Team ID and impersonating nobody. It is not, and is never presented as, a
signature by the original developer. Each clone's `Info.plist` carries
`MALGeneratedBy = "LaunchAgain"` and `MALOriginalBundleIdentifier`, so anything
inspecting the bundle can see what it is.

A Lite launcher is also a small ad-hoc-signed bundle, but it contains none of the target
application. It asks Launch Services to open the untouched vendor-signed original with a
separate `--user-data-dir`. The running target therefore keeps the original app's
Keychain, TCC/privacy and URL-scheme identity.

Why sign at all: editing `Info.plist` inside a signed bundle invalidates the signature, and
macOS refuses to launch a Hardened Runtime binary whose signature does not verify. A clone
must therefore be re-signed, and we have no Developer ID for someone else's app — nor would
we use one if we had it.

Signing is **inside-out**: nested frameworks, dylibs, XPC services and helper apps are
signed deepest-first, then the outer bundle. `--deep` is not used for signing, because it
applies the outer entitlements to nested code, which is wrong; it is used only for
*verification*, where it is the right check.

### Entitlements

In a Full clone, each nested executable is signed with the patched version of **its own** original
entitlements, read from the corresponding path inside the untouched source app. Two cases
matter:

- The renamed main executable (`<Name>.real`). After the shim `execv`s it, that binary
  *is* the running application, so it carries the main entitlements. Signed as ordinary
  nested code with none, it enforces library validation and dyld refuses the
  vendor-signed frameworks with "different Team IDs".
- The Chromium helper apps. The renderer needs JIT and unsigned executable memory; without
  its own entitlements it starts and then dies the first time it allocates.

Readable original entitlement sets are patched as follows:

**Removed** — entitlements bound to a real Apple Team ID or provisioning profile, because
they cannot be satisfied by an ad-hoc signature and prevent the app from launching:

```
com.apple.application-identifier
com.apple.developer.team-identifier
keychain-access-groups
com.apple.security.application-groups
com.apple.developer.associated-domains
com.apple.developer.icloud-container-identifiers
com.apple.developer.icloud-services
com.apple.developer.ubiquity-kvstore-identifier
com.apple.developer.aps-environment
```

Dropping `keychain-access-groups` is why a Full instance cannot see credentials the
original app saved. A Lite target retains the original vendor signature and shares that
Keychain identity instead.

The removed keys from the Full app's main entitlement set are shown per instance and
included in diagnostics. Nested code is patched by the same rule; its individual removed
key lists are not currently expanded in the interface.

**Added to each readable original entitlement set** — one key:

```
com.apple.security.cs.disable-library-validation
```

Ad-hoc signing plus Hardened Runtime turns on library validation, which then refuses to
load the app's own vendor-signed frameworks because they carry a different Team ID from
the (team-less) outer signature. Without this key the clone builds cleanly and crashes
instantly on launch.

This is the narrowest change that works. Hardened Runtime stays **on**, which keeps JIT
restrictions, `DYLD_*` environment protections and library-injection defences in place
wherever the original app had them.

If a nested executable's own entitlements cannot be read, the conservative Chromium
helper fallback also grants `allow-jit`, `allow-unsigned-executable-memory` and
`allow-dyld-environment-variables`, plus disabled library validation. Those fallback keys
are limited to that nested executable and are required for Chromium renderer/helper code;
the main app never uses the fallback.

## What the shim does

Each generated bundle's `CFBundleExecutable` points at `mal-shim`, a small compiled binary
(no shell) that:

1. reads `Contents/Resources/MALInstance.conf`, a plain `key=value` file written by the
   builder;
2. creates the instance's data directory if it does not exist;
3. checks a recognised Electron `window-state.json` and, only when its title bar is not
   reachable on any active display, centres it on the main screen after preserving the
   original beside it;
4. exports `MAL_INSTANCE_DATA_DIR` as a breadcrumb;
5. in Full mode, `execv`s the renamed real binary with
   `--user-data-dir=<path>` prepended, preserving argv;
6. in Lite mode, `execv`s `/usr/bin/open -n -a <original.app> --args ...`, asking Launch
   Services for a new GUI process of the untouched original app with that data directory.

In Full mode it `execv`s rather than forking, so the process becomes the target binary in
place. In Lite mode `/usr/bin/open` launches the original application; the target keeps
the vendor's signing and system identity. Neither path composes a command string or runs
a shell. Foundation and AppKit are loaded only in the short-lived shim so it can inspect
active displays; `execv` replaces that address space completely before the target runs.

LaunchAgain's supported product path never opens Terminal: candidates must be macOS
`.app` bundles and the manager refuses command-line executables. The engine can still
decode old Terminal-launcher records so an upgrade can display and uninstall them safely,
but it refuses to launch or rebuild those legacy instances.

## Argument and path handling

No supported GUI creation or launch component builds a shell command from a user-supplied
string. Every external build tool is run through `Process` with an argument array and an
absolute executable path (`/usr/bin/codesign`, `/usr/bin/iconutil`, `/bin/cp`, …) rather
than via `PATH`, so a modified environment cannot substitute a different binary. The
decoder retains compatibility with legacy Terminal-launcher records solely so they remain
visible and uninstallable; all launch and rebuild routes for them fail closed.

Instance names and paths are validated at the point of entry: null bytes and newlines are
rejected (the shim's config is line-based), path separators and colons are stripped from
names, and leading dots are removed. Names containing `$(…)`, backticks, quotes, emoji or
right-to-left text are kept as-is and treated as text, because nothing interprets them.

Two arguments are refused if a user tries to set them by hand: `--user-data-dir` and
`--profile-directory`, both of which would defeat the isolation the instance exists to
provide. `HOME` is refused as an environment variable, because redirecting it breaks
Keychain, TCC and sandbox lookups.

## Deletion safety

A normal current-instance uninstall first resolves an authoritative registry row. If its
launcher exists, LaunchAgain validates any signature present and binds the generated
metadata, sealed config, clone identifier, UUID and permanent number before the first
mutation. Launcher, profile, log, lock and recovery-marker paths must then be an exact
immediate child or UUID-derived path inside one of two directories this program owns:

```
~/Library/Application Support/LaunchAgain
~/Applications/LaunchAgain
```

The roots themselves, nested launcher paths, symlinks, caller-supplied paths, another
instance's paths and damaged registry paths are refused. A confirmed instance uninstall
removes the launcher and that UUID's complete owned instance directory, including profile,
caches, logs and lock, then clears its registry entry from both synchronized registry
copies, temporary recovery marker and size-cache keys.

macOS and the launched third-party app can create additional per-app files elsewhere in
the user's Library. These are handled by a separate exact allow-list derived only from
the validated clone identifier and UUID. It covers the clone's preference domains,
ByHost and synced preferences, ordinary and updater caches, URL-session downloads,
Application Support, saved state, HTTP storage, WebKit, cookies, logs, containers,
application scripts, LaunchAgent, the UUID cache mirror, and tightly bounded Darwin
cache/temp names. Source identifiers, display-name globs and vendor directories are never
deletion inputs. LaunchAgain asks Launch Services to unregister the exact launcher but
never purges or resets its shared database; shared TCC and Keychain state are not edited.

A profile you relocated to a directory of your own is never deleted — the uninstall
removes our own files, leaves yours, and says which. A user-confirmed uninstall writes a
structured recovery journal before moving anything; startup resumes that exact operation
after an interruption even if its registry row is already gone, revalidating the same
exact instance identity before continuing, and clears the journal only after
registry/cache cleanup commits. Explicit orphan-profile deletion is a separate
user-confirmed path restricted to one immediate UUID child of the instances directory.

The startup sweep reports orphans and never deletes them on its own. An orphaned profile
is somebody's signed-in session. An unregistered `.app` is also report-only unless its
signed LaunchAgain manifest proves ownership. Age alone never authorizes removal of a
staging item, because another process may still be building it.

## Restart and power-transition durability

Registry and generated-config updates are written to a same-volume temporary file,
disk-synchronized, atomically renamed and followed by a containing-directory sync. On
macOS the writer additionally requests `F_FULLFSYNC`; `registry.json.bak` remains the
redundant parseable copy of the same committed document. After a reboot the app
reconstructs state from these
files and never treats a missing in-memory session as permission to remove a profile.

LaunchAgain can make its own metadata durable, but it cannot force a third-party account
app to commit data that the third-party app still holds only in memory. A normal reboot
gives applications an orderly termination; sudden power loss may still lose the last
uncommitted actions inside that external app.

## Gatekeeper

An ad-hoc signed clone is not notarised, so `spctl --assess` rejects it. That result is
captured in the diagnostics rather than hidden. It does not prevent the clone from
running, because the clone is created locally from an app already on the machine and the
builder clears quarantine on the generated copy.

The builder removes `com.apple.quarantine` from the clone it has just created — and only
from that clone — so a stale attribute inherited from the source cannot produce a
misleading "downloaded from the internet" warning for a file nobody downloaded. Gatekeeper
itself is not disabled, weakened, or configured in any way.

## Reporting a problem

`launchagain diagnostics` (or **Export Diagnostics…** in the app) writes a report containing the
registry, logs, `codesign` verification output and system facts. It contains **no**
contents of any instance profile — no cookies, no tokens, no history. The file is plain
text you can read before sending it anywhere.
