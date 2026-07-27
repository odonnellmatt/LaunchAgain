# LaunchAgain — Beta v0.1

**Run two copies of the same Mac app at the same time, each signed into a different account.**

### [⬇ Download the beta](https://github.com/odonnellmatt/LaunchAgain/releases/latest)

macOS 13 or later · Apple Silicon and Intel · ~5 MB download · free, no account needed

---

## The problem

macOS lets you run one copy of an app. One Claude. One ChatGPT. One Chrome profile in the Dock.
So if you have a work account and a personal account, you spend your day signing out and back
in, or living in a browser tab because at least tabs can be two things at once.

LaunchAgain gives you a second copy. And a third. Each one is a real application with its own
icon in the Dock, its own window, its own login — and they run **at the same time**.

<br>

|  | Before | With LaunchAgain |
|---|---|---|
| **Claude** | one account, sign in and out | Claude 1 (work) and Claude 2 (personal), both open |
| **Chrome** | profile switcher, one Dock icon | separate apps, separate Dock icons, ⌘-Tab between them |
| **VS Code** | one set of settings and extensions | one per project or client |

<br>

## Who this is for

**Work and personal, side by side.** The obvious one. Your work Claude and your personal Claude
open together, in separate windows, with separate histories. Nothing leaks between them — each
instance has its own profile directory, its own cookies, its own local storage. No more signing
out at 6pm.

**Several personal accounts.** Just as common and just as supported. A main account and a
throwaway. One per side project. A shared family account and your own. Separate accounts for
separate hobbies. There's nothing "work" about it — LaunchAgain doesn't know or care what the
accounts are for, and you can make up to 64 of them.

**Client separation.** If you consult, each client can have its own instance with its own
sign-in, its own extensions and its own settings, so nothing bleeds across engagements.

> **One thing to be clear about:** this separates local profiles for accounts you already have.
> It does not bypass licensing, subscriptions or authentication. If a service limits how many
> sessions you can run on one account, that limit still applies — you'd use it with two accounts
> you're already entitled to.

<br>

## What works

LaunchAgain handles **Electron and Chromium desktop apps**, which covers most of the AI and
developer tools people want two of. It scans what you have installed and tells you, per app,
exactly what it can and can't do — before you create anything.

Verified in this beta:

| App | Result |
|---|---|
| **Claude** | ✅ Separate accounts, separate Dock icons |
| **Google Chrome** · **Brave** · **Microsoft Edge** | ✅ Separate profiles and Dock icons |
| **VS Code** | ✅ Separate settings, extensions and windows |
| **LM Studio** · **RStudio** · **OBS Studio** · **jamovi** · **Kimi** · **Tad** · **Antigravity** | ✅ Separate profiles |
| **ChatGPT** | ⚠️ Works, but needs one extra step — see below |

Anything else Electron- or Chromium-based will most likely work too. Native macOS apps, Mac App
Store apps and sandboxed apps **won't** — LaunchAgain tells you so rather than making a broken
copy. It also only handles GUI applications: command-line tools like the `claude` CLI aren't
something it can duplicate, since they don't have an app bundle to clone.

### ⚠️ ChatGPT needs one extra step

The ChatGPT desktop app stores your sign-in at `~/.codex`, a fixed path in your home folder —
not inside the profile LaunchAgain redirects. So out of the box, every ChatGPT instance shares
one session, and signing out of one signs out all of them, including the original.

There's a fix, and it takes about ten seconds per instance: open the instance in LaunchAgain,
go to **Advanced → environment variables**, and set `CODEX_HOME` to a folder of its own. That
instance then gets a genuinely separate session.

LaunchAgain shows you this warning before you create anything, and it won't set the variable for
you — where an app keeps your data is your call, not a default someone else picks.

<br>

## Installing

The beta is **not signed with an Apple Developer certificate**, so macOS will refuse to open it
on the first try. This is expected and it's a one-time step:

1. Download and open the `.dmg`, drag **LaunchAgain** to Applications
2. **Right-click** the app in Applications and choose **Open**
3. Click **Open** in the dialog that appears

Double-clicking won't work the first time — it has to be right-click → Open. After that it opens
normally. If macOS still refuses, run this in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/LaunchAgain.app
```

You're right to be cautious about that step in general. Signing is on the list for a later
release.

<br>

## How it works

Two modes. LaunchAgain picks the right one and tells you which you're getting.

**Full** — makes a real copy of the app with its own identity, its own numbered Dock icon and its
own profile. Genuinely separate accounts. Costs disk space: roughly 740 MB for a Claude instance,
1.75 GB for ChatGPT.

**Lite** — runs the original app pointed at a separate profile. Nearly no disk space, but it
shares the original's identity, so for some apps it will also share the sign-in. LaunchAgain
refuses to create a Lite instance of an app where that would silently share your account, unless
you tell it you understand.

Your original app is never modified. Your existing profile is never touched, moved or copied —
new instances start signed out and empty, which is the point.

<br>

## Known limits in this beta

- **Unsigned**, so the install has the extra step above
- **ChatGPT** needs the `CODEX_HOME` step for separate accounts
- Sign-in links that bounce through a browser may return you to the original app rather than the
  instance you started from; use in-app or device-code sign-in where offered
- Apps that update themselves may replace an instance's identity — rebuild it from the source app
  if that happens
- Deleting an instance removes its profile, and that's permanent

<br>

## Feedback

This is a beta and the whole point is finding what breaks. Please
[open an issue](https://github.com/odonnellmatt/LaunchAgain/issues) with:

- Which app, and which macOS version
- What you expected and what happened
- Whether it was a Full or Lite instance (LaunchAgain shows this on the instance)

Reports that an app *works* are useful too — the compatibility list above grows from what people
actually try.

<br>

## Privacy

LaunchAgain runs entirely on your Mac. No telemetry, no analytics, no network calls of its own,
no account. It never reads, copies or moves your Keychain, and it doesn't touch your existing
profiles. Instances are ordinary apps in a folder you can inspect.

<br>

---

## Screenshots

<img width="990" height="671" alt="Screenshot 2026-07-28 at 7 59 02 am" src="https://github.com/user-attachments/assets/db134483-f02a-4d60-bc24-b51ff859e657" />


<br>
