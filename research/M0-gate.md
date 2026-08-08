# Milestone 0 — gate decision

**Run:** 2026-07-25T16:34:03Z
**Machine:** Mac16,8 · arm64 · Version 26.5.2 (Build 25F84)
**Primary application:** Claude 1.24012.9
**Second application:** Kimi.app

The gate in SPEC.md §3: *if M0-3 or M0-4 fails across both test apps, V1 ships
Lite-mode only and full mode moves to V1.1.*

## Outcomes

| # | Experiment | Outcome |
|---|---|---|
| M0-1 | Two instances with separate --user-data-dir | NEEDS HUMAN CONFIRMATION |
| M0-2 | Instance data stays inside its own directory | NEEDS HUMAN CONFIRMATION |
| M0-3 | Clone, rewrite identity, ad-hoc re-sign | PASS |
| M0-4 | Two clones with different CFBundleIdentifier running at once | NEEDS HUMAN CONFIRMATION |
| M0-5 | Badged .icns generated from the source icon | NEEDS HUMAN CONFIRMATION |
| M0-6 | Executable shim execv's with the injected argument | PASS |
| M0-7 | Repeat M0-3 and M0-4 on a second Electron app | PASS |
| M0-8 | Disk cost of a clone and of a fresh profile | PASS |
| M0-9 | Identify what "Codex" is on this machine | PASS |
| M0-10 | Source application self-update behaviour | NEEDS HUMAN CONFIRMATION |

## Decision

**Full mode ships in V1.**

The clone-and-re-sign path produced verified, launchable bundles with distinct
Launch Services identities, on Claude and Kimi. Nothing here is app-specific.

Lite mode remains in the product as the automatic fallback, not as a plan B for
the whole release: any individual instance whose signing or launch fails is
rebuilt in Lite mode without losing the instance.

## What the automated harness cannot decide

Four pass conditions are visual or account-level and are marked `needs-human` on
purpose rather than being asserted:

- two accounts genuinely signed in and staying signed in (M0-1)
- two Dock tiles and two Cmd-Tab entries, seen (M0-4)
- badge legibility at 32 px (M0-5)
- an updater firing in the wild (M0-10)

Run `mal m0 --keep` and work through the `What a human must confirm` section of each
report. A pass is not recorded here for anything that was not observed.