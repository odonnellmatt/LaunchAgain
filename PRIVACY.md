# Privacy

This application makes no network requests. There is no telemetry, no analytics, no crash
reporting, no update check, no "anonymous usage statistics", and no server to switch them
back on from.

Everything below happens on your Mac and stays on your Mac.

---

## What is stored, and where

```
~/Applications/LaunchAgain/
    <Name> <n> – <label>.app              one launcher bundle per instance
    .staging/                             build work; interrupted residue is report-only

~/Library/Application Support/LaunchAgain/
    registry.json                         the instance list (see below for contents)
    registry.json.bak                     redundant copy of the same committed registry
    registry.json.corrupt-*               preserved bytes if both copies were unreadable
    instances/<uuid>/userdata/            the instance's own profile — the app's data
    instances/<uuid>/logs/                per-instance logs
    instances/<uuid>/instance.lock        the pid of the running session, if any
    removed-instances/<uuid>.removed      interrupted-uninstall journal; absent when complete
    icon-cache/                           generated icons and bounded directory-size cache
    migration-conflicts/                  markers when legacy/current profile UUIDs collide
    logs/launchagain.log                  the launcher's own log, truncated to 512 KB
    logs/launchagain.log.redactions       bounded non-plaintext log suppression keys
```

That is the complete list of state LaunchAgain itself creates directly, except when you
explicitly choose a different profile location or export a diagnostics file to a path
you pick.

While a Full instance runs, macOS or the third-party application may create support items
keyed to the instance's generated bundle identifier in standard user-Library domains:
Preferences/ByHost, SyncedPreferences, Caches, updater data, URL-session downloads,
Application Support, Saved Application State, HTTPStorages, WebKit, Cookies, Logs,
Containers, Application Scripts and LaunchAgents. Chromium can also create the instance
UUID's mirrored cache and tightly named items in the current user's Darwin cache/temp
directories. LaunchAgain never searches by vendor or display name. A confirmed instance
uninstall removes only the allow-listed exact paths for that validated
`<source-id>.mal<number>-<uuid-fragment>` identity and UUID.

A Lite instance runs the vendor-signed original app with a separate Chromium profile.
Its Keychain, TCC, URL-scheme and any non-profile vendor support items therefore remain
part of the original app's shared system identity. LaunchAgain neither attributes those
shared records to one Lite profile nor deletes them during Lite-launcher removal.

## What is in `registry.json`

Per instance: a UUID, its permanent number, the name and account label **you typed**, the
mode, the bundle and profile paths, the badge colour and shape, the source app version it
was built from, any extra arguments or environment variables you set, timestamps, and any
notes the build produced.

The account label is a free-text reminder — "work", "matt@company.com" — that is displayed
in the interface and never used to authenticate anything. Leave it blank if you would
rather it did not exist.

LaunchAgain does not capture the third-party application's credentials. Advanced
environment-variable values are user-supplied and are persisted verbatim in the registry
and generated launcher metadata, so do not place passwords, tokens or other secrets
there.

## What is in an instance profile

Whatever the app puts there. That is the point of it — cookies, tokens, local storage,
caches, and the app's own settings for that account.

The launcher writes the directory and then leaves the profile bytes alone. LaunchAgain
enumerates filesystem metadata to show profile size, but it does not open profile files,
copy a profile to another instance or upload anything. Duplicating an instance copies its
*settings* and starts with an empty profile, precisely so a signed-in session is not
silently cloned into a second place.

Profiles and the registry are stored in persistent user directories and remain after
LaunchAgain quits, after logout and after reboot. Registry/config writes are atomic and
disk-synchronized. LaunchAgain does not automatically purge profiles at startup; an
orphan remains present until you explicitly choose to remove it.

## What the logs contain

Timestamps, build steps, instance numbers, file paths, and error text from `codesign` and
friends. Enough to reconstruct what the launcher did; nothing about what you did inside an
instance. The launcher's own log is truncated to the most recent 512 KB at startup so it
cannot grow without bound. When an instance is uninstalled, complete records carrying
its UUID or generated clone identifier are removed. The small `.redactions` sidecar
contains at most 4,096 fixed-width fingerprints—not the UUID, bundle identifier, path,
name or profile contents—so a concurrent current-version process cannot write the
deleted identity back after cleanup.

## The diagnostics export

**Export Diagnostics…** (or `launchagain diagnostics`) writes a single Markdown file containing:

- macOS version, hardware model, architecture, memory
- which system tools were found
- your managed apps and instances, with paths, modes, versions and build notes
- `codesign` verification output for each instance
- the tail of the launcher's log

It **excludes** the contents of every instance profile: no cookies, no tokens, no
browsing or chat history. It is a plain text file written to a location you choose, and
nothing sends it anywhere — read it before you share it.

## The Keychain

Not read. Not written. Not copied, exported, decrypted or migrated. A Full clone has a new
ad-hoc signing identity and cannot see items the original app created. A Lite instance
runs the vendor-signed original and shares its Keychain identity. See
[SECURITY.md](SECURITY.md) for the mechanism.

## Uninstalling

Deleting one instance inside LaunchAgain moves its launcher, its complete owned UUID
directory and its exact bundle-identifier support items to the Trash where macOS supports
it, asks macOS to clear the exact preference domain and removes its exact plist when
present, then removes its registry record, temporary recovery marker and cached size key.
The source app, other instances and an external profile directory you chose are not
touched.

Deletion is a normal macOS uninstall, not secure erasure: items moved to the Trash remain
recoverable until the Trash is emptied. LaunchAgain asks Launch Services to unregister
the exact launcher but does not purge or reset its shared database. Shared macOS TCC and
Keychain databases are not edited.

To uninstall LaunchAgain itself and every remaining managed instance, first uninstall
those instances in the app, then delete the two top-level LaunchAgain directories listed
above.

macOS keeps its own privacy (TCC) records for each Full instance because each Full clone
has a separate app identifier. Those entries remain in System Settings → Privacy &
Security after removal; macOS provides no supported way for LaunchAgain to delete them.
Lite instances share the original application's TCC identity instead of creating a
separate target-app permission identity.
