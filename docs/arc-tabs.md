# Arc tabs in the process lists — 24 September 2026

Prerak asked which Arc tabs were using the memory Arc showed as one large row, with
the heavy ones (over 500 MB) listed under Arc. Closing tabs stays in Arc; he asked to
see the numbers first.

## Why this needs Arc's Task Manager

Arc runs every page in an anonymous `Browser Helper (Renderer)` process. Nothing that
MenuSprite can read about a process says which tab it renders. Each route was checked
on Nebula:

- **Arguments** carry handles and `--renderer-client-id`, never a URL.
- **Sockets** are held by Chromium's network service, not by renderers.
- **Remote debugging** is refused on the default profile since Chromium 136.
- **Arc's AppleScript** gives each tab's id, title, URL, and select, close and JavaScript
  commands, but no PID or memory. JavaScript only sees the page's own heap, and it needs
  "Allow JavaScript from Apple Events" turned on.
- **Arc's Task Manager** (Chromium's, compiled into Arc) lists each task with its
  **Process ID**. It is the only place the link exists, and it is readable through
  Accessibility as an `AXTable` whose rows are `Task · Memory footprint · CPU · Network ·
  Process ID`.

Arc keeps the command at **Help › Troubleshooting › Open Task Manager**, a hidden item
that the command bar finds with "Task Manager / CPU / Memory". Arc enables the item only
while one of its browser windows is in front. With the WhatsApp window on another Space
it stayed disabled, and pressing it did nothing.

## What is shown

The Arc row in RAM, CPU and Power (panels and hub) expands like the Claude Code row:

- **One row per page process, titled with its tab.** Its reading is MenuSprite's own
  measurement of that process, so the members sum exactly to Arc's total. When
  several same-site tabs share a process, the caption reads "+N more tabs in this
  process" and the hover text lists them.
- **Embedded frames, extensions and workers**: renderers the Task Manager lists without a
  tab (cross-site iframes, extensions, service workers, the spare renderer).
- **Pages not named yet**: renderers with no name. Its tag button names them.
- **Arc browser and services**: the main process with its GPU, network and utility
  helpers. Quitting this row quits Arc. The group row itself only opens and closes.

The group caption reads "N tabs named · K pages unnamed". **Tab rows have no quit
button**, because ending a renderer crashes the tab instead of closing it. Close the tab
in Arc.

## How names are read

- **On request:** the tag button activates Arc, raises a browser window if the menu item
  is disabled, presses Open Task Manager, switches it to *All tasks*, reads the table,
  closes the window and reactivates the previous app. That takes about a second, and
  `PanelInteraction.hold` keeps the board open meanwhile. The first press asks for
  Accessibility access. Opening a board never asks.
- **Opportunistically:** while any process board samples and Arc's Task Manager is open
  (because the user opened it), every sample re-reads it. When it isn't open, each sample
  costs a single Accessibility query.

Only the PID → task-name link is kept (`BrowserTabNames`, in memory, shared by all
boards), tied to each process's birth stamp, so a reused PID never takes a closed
tab's name. A reading replaces the previous one; exited processes are pruned every
sample. A tab keeps its process while it stays on the same site, so its name stays
right after the Task Manager closes. Tabs opened or navigated to another site since the
reading fall into "Pages not named yet". Nothing is written to disk. Every Accessibility
call has a 0.5 s timeout.

## Limits

- Arc only. Chrome, Brave and Edge have the same Task Manager, but their menus differ.
- English window and menu titles ("Task Manager", "Open Task Manager").
- The Process ID column must be visible, which it is by default. If it isn't, the board
  says how to turn it on.
- Titles are from the moment of reading. An unread-count prefix such as "(5)" can go stale.

## Verification

- `BrowserTabsTests`: partition, naming and captions, no quit on tab rows, Arc quit
  from its browser row, PID-reuse rejection, reading replacement, label kinds and old
  snapshots decoding. The live probe is `MENUSPRITE_LIVE_PROBE=1 ARC_PID=<pid> swift test
  --filter liveArcTaskManagerProbe`, with the Task Manager open; it prints private titles.
- Checked by hand on Nebula before the code was written: an Accessibility dump of the
  open Task Manager gave every row with its PID (for example "Tab: (5) Messaging |
  LinkedIn · 744 MB · 17142"); the menu item was disabled with no browser window in front
  and enabled with one; pressing it opened the window.
