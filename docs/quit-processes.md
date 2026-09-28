# Quitting an app from a process panel — 14 September 2026

Prerak's request: an option button to quit a running program while looking at it in
the **CPU**, **Power** or **RAM** board. Each process row now carries a trailing
button beside the reading: **one click quits it, and the button then becomes a
force-quit button for that row.** The RAM and CPU boards use `MemoryDocumentView`; the Power sprite opens the
[battery and power dashboard](energy-dashboard.md), whose `Apps & processes · CPU
power` list gained the same button. The [hub panel](hub-panel.md) landed the same
day: its **Power** page hosts that same dashboard, so it inherits the button, and its
**Apps** page draws its own SwiftUI list, which gained the equivalent button. All
four surfaces share one action and one set of words. Nothing else about sampling,
grouping, attribution or the panels' existing controls changed.

## What a click actually does

There is **no menu and no dialog**. One click quits. Prerak's reason, 14 September:
quitting is rarely one app — a dialog per row turns four or five quits into a chore.
So the escalation lives in the button instead:

1. **First click** asks the row to quit, immediately.
2. The button then **arms**: it becomes a filled orange `xmark.octagon.fill`, and
   its tooltip reads `Force quit <name> — it was asked to quit and is still
   running.` A row that quits disappears from the list at the next sample, taking
   the armed button with it, so an armed button means *it did not go*.
3. **Second click on that same armed button force quits**, immediately.

Force quit therefore still costs two deliberate acts, but both are the same click
in the same place, and neither interrupts the run down a list. Two guards keep the
second click honest: a click within **0.75 s** of the first is treated as an
impatient double-click on "quit" and ignored, and the armed state lapses after
**two minutes**, after which the row is ordinary again.

A panel row is a **consumer**, not a process: an application plus the helpers
attributed to it, or a runtime process with its observed children
([process context](process-context.md)). `ProcessTermination.plan(for:)` turns the
row back into the set of PIDs behind it, each carrying the birth stamp
(`ri_proc_start_abstime`) the sampler grouped it by, and a flag for whether this
user owns it.

- **Quit** — if any PID in the row is a registered running application, that
  application is asked through `NSRunningApplication.terminate()`, exactly as ⌘Q
  would: macOS ends its helpers with it, and the app may still prompt to save or
  refuse. Only when no PID is a registered application (a `node` job, a Gradle
  daemon, a stray tool) is `SIGTERM` sent to the row's own processes directly.
- **Force quit** — `forceTerminate()` or `SIGKILL` on the same targets.
- The MenuSprite row offers only **Quit MenuSprite**, which is the app's ordinary
  termination, never a signal to itself, and never arms.

This is an ordinary user action. There is no privileged helper, no `task_for_pid`,
no new permission, no root path, and nothing is installed.

## Why a quit can look like it did nothing (15 September)

Prerak: "One click quit does not quit most of the time, I have to do force quit."
Measured rather than assumed. A signed bundle with MenuSprite's own identity and
Info.plist, launched as a real app, asked TextEdit to quit: **gone in 0.13 s**,
repeatably. `AEDeterminePermissionToAutomateTarget` reports `-1744` (consent not
given) for that same bundle, and termination still works — macOS does not gate
application termination behind Automation consent, so the missing
`NSAppleEventsUsageDescription` is not the cause and no permission is needed.

The fault was the **five-second sampling interval**. The app died in a tenth of a
second and the row it was drawn on stayed on screen, unchanged, with an armed orange
button inviting a second click, for up to five seconds. A working quit was
indistinguishable from a click that did nothing.

Three changes, all feedback rather than force:

- `MemoryBoardStore.resample()` cuts the interval short; a quit request calls it
  immediately and again at 0.4 s, 1.2 s and 3.0 s, so a row that went leaves the list
  in well under a second.
- The asked row shows **quitting…** in place of its reading, in orange, on all four
  surfaces — so the half-second before it disappears is not silent.
- If the row is still listed 3.5 s later, the footer says so plainly: *"X has not
  quit — it may be asking you to save, or something restarts it. Click again to force
  quit."*

Two causes remain, and both are correct behaviour rather than defects. **An
application can refuse a quit request** — unsaved documents, a confirmation, running
jobs — exactly as ⌘Q can be refused, and its dialog may be behind other windows;
force quit is then the honest answer. And **a helper process that is signalled can be
restarted by whatever supervises it**, so the row returns with a new PID.

## Refusals, and why they are honest

- **PID reuse.** Every signal re-reads the PID's birth stamp and compares it to the
  sampled one; a mismatch signals nothing and reports `a PID had already been
  reused`. The remaining window between check and `kill` is microseconds wide and
  additionally requires the PID to be recycled inside it — macOS offers no atomic
  form. Application termination is checked the same way before asking.
- **Another user's process.** Rows whose processes all belong to root or another
  user get a disabled button whose tooltip says so, rather than a button that fails.
  `launchd` (PID 1) is never offered at all.
- **Partial results.** A row can end with some processes gone and some refused. The
  footer line states what happened — `Asked 1 of 2 processes in node to quit; some
  had already exited.` — and never claims an application has quit, because an app
  asked to terminate can decline. After a successful ask it adds `Click again to
  force quit.`

Outcomes appear as a coloured line in the panel footer for ten seconds, not in an
alert, so the board stays open and legible. Closing the board clears it.

## Rows are live, so the button remembers its row

The list re-ranks every five seconds. A button records the **consumer id** it was
laid out for and resolves that id at click time, so a row that moved between the
layout and the click is still the row that is acted on — never whatever has since
scrolled into that position. The armed state is keyed by that same consumer id, so it
follows the row as it re-ranks, and is dropped as soon as the row leaves the list.

## Board dismissal

The panels close on any click outside them, on another app activating, and on space
changes. Quitting an app makes macOS hand activation to another one, which would read
as "the user left" — and the board closing after every quit would defeat the point of
removing the dialog. `PanelInteraction` suspends those monitors for two seconds after
a quit request, so a run down the list survives each handover.

## Evidence

`--process-panels-validate <dir>` in the installed signed app: **42 checks, 0
failed**, with the existing ranking, attribution and collector-release checks
unchanged by the new column. Twelve of those are new and matter more now that a
click acts immediately — for each of the three boards: one control per listed row,
**each control's accessibility label contains the title of the row it sits on**
(the binding, checked against live data rather than only in tests), quit enabled
exactly when the row is one this user can quit, and every control inside the list's
trailing area. It now also writes `<kind>-list.png` beside each
`<kind>-panel.png` — the whole scrolling document rather than the part that fits —
because the Power board's process list sits below the charts and never appeared in
the panel-sized render. Those renders show the button on every row of the Memory,
CPU and Power lists against live data.

`swift test --package-path native` — `ProcessTerminationTests` covers the planning
rules (grouped helpers listed once, ownership marked, PID 1 excluded, MenuSprite
recognised) and the summary wording, and exercises the real signal path against a
live `/bin/sleep`: a stale birth stamp is refused and the process survives, an
unowned target is refused before any signal, the correct target is delivered and the
process exits, and the same target then reports an exit rather than acting again. A
second test covers the escalation itself against a process that ignores `SIGTERM`: it
survives the first click's signal and is ended by the second's `SIGKILL`.

Layout changed only in the rows' trailing 24 points: the value column moved left to
make room, and the per-row buttons are real `NSButton`s, so they keep keyboard and
VoiceOver behaviour. `MemoryDocumentView.accessibilityChildren()` now returns its
drawn text elements **and** its control subviews; the power dashboard already
included subviews.

**Not yet exercised live:** a real click. `NSButton.performClick` → action →
`NSRunningApplication.terminate()` is the one link neither the tests nor the panel
validation cover; the tests cover everything below it, including the escalation
(a process that ignores `SIGTERM` survives the first click and dies on the second),
and the validation covers the wiring above it.
