# Manual checklist

The things a test suite cannot decide. Everything here is a judgement about what a human
sees, or a claim that only holds across a reboot or a real sign-in.

Run through it before shipping a build. Record the date and the macOS version.

---

## Setup

```bash
./Scripts/build-app.sh
open "build/LaunchAgain.app"
```

Create three instances of an Electron app (Claude is the reference case), named
*Personal*, *Work* and *Research*.

For destructive dashboard checks, launch against a throwaway root instead:

```bash
LAUNCHAGAIN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launchagain-manual.XXXXXX")" \
  "build/LaunchAgain.app/Contents/MacOS/LaunchAgainGUI"
```

Never use the real support directory for destructive UI testing.

---

## Reboot retention

Use a throwaway root and throwaway source app for the first pass. For the final non-
destructive check, only observe an existing real instance; do not rebuild, rename or
delete it.

- [ ] Create a throwaway instance, write a recognizable file inside its profile, and
      record its UUID, permanent number, name and launcher path
- [ ] Restart the Mac normally
- [ ] Open LaunchAgain and confirm the same UUID/number/name and launcher are present
- [ ] Launch the throwaway instance and confirm the recognizable profile data remains
- [ ] Confirm a pre-existing orphan profile is still reported by Health and was not
      removed during startup
- [ ] Quit LaunchAgain, reopen it, and confirm the result is unchanged

---

## Badge legibility

The number is the identifier, so this is the most important visual check.

- [ ] Dock, default size — each number is readable at a glance, not just "a coloured dot"
- [ ] Dock, smallest size — still readable
- [ ] Dock magnification on — the badge does not clip against the tile's rounding
- [ ] Finder icon view at 64 px and at 512 px
- [ ] Cmd-Tab switcher
- [ ] Launchpad
- [ ] Mission Control
- [ ] Spotlight result
- [ ] Two-digit and three-digit numbers: create instance #10 and #100 (or renumber) and
      repeat the Dock check. The badge should widen into a pill rather than shrink.
- [ ] Light and dark menu bar / wallpaper — the white ring should keep the badge visible
      against a same-coloured icon

### Per app family

How an application publishes its icon changes which of the checks above can fail, and
they fail in different places. Run the Dock check *and* the Finder check for one app of
each kind, because an app can be right in one and wrong in the other.

- [ ] **Classic `.icns` only** (Kimi, most Electron apps) — `CFBundleIconFile` and
      nothing else. Badge should appear everywhere. This is the easy case.
- [ ] **Asset catalogue** (ChatGPT: `Assets.car` + `CFBundleIconName`) — the clone
      removes `CFBundleIconName` so the catalogue cannot outrank the generated `.icns`.
      Check Finder, Spotlight and Cmd-Tab first; if the badge is right there and wrong
      in the Dock, it is the next case, not this one.
- [ ] **Sets its own Dock icon at runtime** (ChatGPT calls `app.dock.setIcon` from its
      own code, driven by a Dock-icon preference) — LaunchAgain cannot override this
      without modifying the application's own code, which it does not do. Expect the
      Finder/Spotlight/Cmd-Tab icon to be badged and the *running* Dock tile to be
      whatever the app chose. Record which you see; do not treat a correct Finder icon
      as proof the Dock is correct.
- [ ] **A reused path** — delete an instance and create another with the same number and
      name, so the new bundle lands where the old one was. The new badge must appear
      immediately. A stale icon here is IconServices caching by path; the build bumps
      the modification date of the bundle, the `Info.plist` and the `.icns` to defeat it.

## Identity

- [ ] Three separate Dock tiles while all three run
- [ ] Three separate Cmd-Tab entries
- [ ] Clicking each Dock tile raises that instance's own window
- [ ] Finder shows the instance name (`Claude 2 – Work`), not the original app name
- [ ] Spotlight finds an instance by its name
- [ ] The menu bar may show the original app's name — expected, see LIMITATIONS.md §6

## Display changes

Use a newly created or rebuilt 0.1.2 Full instance whose application writes the recognized
top-level `window-state.json`. Do not inspect any profile content beyond that geometry file.

- [ ] Open the instance on a larger external display, quit normally, disconnect that
      display, and relaunch from the Dock. The window appears fully on the laptop display
      with a draggable title bar.
- [ ] Repeat by dragging the running window from the large display to the smaller display;
      no immovable edge or stale visual remnant remains after relaunch.
- [ ] Confirm the first repair created `window-state.json.launchagain-backup` and preserved
      unrelated keys from the original state object.
- [ ] Relaunch again with the window already reachable. Its position stays unchanged and
      the original backup is not overwritten.
- [ ] Repeat with a malformed or different-shaped `window-state.json`. The launcher opens
      the app without editing that file.

## Accounts

- [ ] Sign into a different account in each instance, one at a time
- [ ] All three stay signed in with all three running at once
- [ ] Quit everything, relaunch — each is still signed into its own account
- [ ] Reboot — numbers, names, icons and sign-ins all survive
- [ ] The original app, launched normally, is still signed into its original account and
      is unaffected

## Numbering

- [ ] Delete #2 and type `delete`. Its launcher and complete
      `Application Support/LaunchAgain/instances/<uuid>` directory are gone; #3 is still #3
- [ ] Create another instance. It fills the lowest free number, #2
- [ ] Rename #3. Its number does not change
- [ ] Renumber… explicitly. Numbers become 1…n, icons and names are rebuilt to match
- [ ] Reboot and confirm the numbering survived

## Dashboard dynamics

- [ ] Start a deliberately slow clone or non-APFS copy. The create sheet immediately
      changes to a non-dismissible progress screen and updates the current stage and
      overall progress until installation completes or reports an actionable failure
- [ ] In the isolated root, change one row to two rows in the same grouped section. The
      sidebar, content and detail columns remain visible and clicks respond immediately
- [ ] Change those two rows back to one, both with the removed row selected and unselected
- [ ] Exercise deletion from the toolbar/menu, row trash button and context menu; every
      route presents confirmation and the launch/trash controls do not select or launch
      the row accidentally
- [ ] After deletion, confirm there is no UUID tombstone or size-cache key for that
      instance; the source app and every other instance are unchanged
- [ ] Update the isolated registry from `launchagain --root <root>` while the window is
      open; the row appears after the debounced filesystem refresh
- [ ] Repeat 1→2→1 several times and confirm arrow-key navigation and VoiceOver labels
      still identify each row and its independent controls

## Rebuild after an update

- [ ] Wait for (or force) an update of the source app
- [ ] The dashboard shows "Rebuild available" on the affected instances
- [ ] Rebuild one. It launches, it is still numbered, and it is still signed in
- [ ] Its profile size is unchanged — the data was not touched

## Failure and recovery

- [ ] Force a signing failure (e.g. point at an app that cannot be re-signed). The
      instance is created in Lite mode, is labelled as such, and no orphan bundle is left
- [ ] Temporarily move aside an isolated test root's `registry.json` and `.bak`, reopen
      LaunchAgain, and click **Refresh Installed Launchers**. Signed launchers are
      reconstructed without copying, deleting or replacing their profiles
- [ ] Delete an instance's launcher by hand in Finder. **Check for Problems** reports it
      as "no launcher on disk"; uninstalling the entry removes the remaining owned profile
- [ ] Put a stray `.app` in `~/Applications/LaunchAgain/`. It is reported as
      unproven and report-only; **Remove Cleanable Items** leaves it untouched
- [ ] Put an old-looking item in `.staging` while a second process holds it. Health
      reports it but neither automatic nor explicit cleanup removes it without a
      cross-process lease
- [ ] Truncate `registry.json` by hand. The app reopens, recovers from `.bak`, and the
      instance numbers are intact
- [ ] Kill an instance mid-launch, then launch it again. No "already running" deadlock

## Codex GUI and GUI-only boundary

- [ ] The chooser labels `/Applications/ChatGPT.app` (`com.openai.codex`) as **Codex**
- [ ] Create two Codex instances and open each; both are GUI applications and neither
      action opens Terminal. Follow the inspected mode: Full must show numbered Dock
      icons; Lite may share the original Dock icon and must display its shared
      Keychain/TCC/URL-scheme limitations
- [ ] Passing `/usr/bin/env` or another executable to the CLI `inspect`/`create` path is
      refused with a GUI-only explanation
- [ ] An older Terminal-based Codex instance appears as disabled and offers migration
      guidance plus complete uninstall, but cannot launch or rebuild

## Storage and permissions

- [ ] Disk usage shown per instance roughly matches Finder's Get Info on the profile
- [ ] The first time an instance uses notifications / microphone / screen recording, macOS
      prompts — expected, see LIMITATIONS.md §3
- [ ] Each Full instance appears separately in System Settings → Privacy & Security;
      Lite instances share the vendor-signed original application's privacy identity

## Awkward inputs

- [ ] Name an instance with an apostrophe, an emoji, and right-to-left text. It builds,
      the Finder name is sensible, and it launches
- [ ] Point an instance's profile at a directory with spaces and an apostrophe in the path
- [ ] Create an instance of an app installed on an external volume
- [ ] Create an instance while the destination volume is nearly full — the failure is
      reported and nothing is left behind

## Uninstall

- [ ] Delete one isolated test instance with data. Scan every exact clone-identifier and
      UUID path listed in PRIVACY.md; none remains at its original location, while the
      source app, another instance and an external profile remain byte-for-byte present
- [ ] Confirm both registry copies, the removal-journal directory and directory-size
      cache contain no row or key for the removed UUID
- [ ] Confirm the launcher-owned items are in the Trash where supported, and empty the
      Trash only if unrecoverable deletion is intentionally required
- [ ] macOS's shared TCC, LaunchServices and Keychain records may remain; that boundary is
      stated and no shared database was edited
