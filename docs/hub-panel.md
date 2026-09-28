# The hub panel — every MenuSprite page in one place

**Implemented 14 September 2026.** Clicking the MenuSprite brand item in the menu bar used to drop
a list of six text entries, each of which opened a *separate* window or panel. Nothing was in one
place, and one entry — Battery & Power — did not even open the dashboard unless a power sprite
happened to be showing in the menu bar. The hub replaces that list with a single panel under the
icon: brand header, an icon tab rail, the selected page, and one Settings / Quit footer.

## What opens it

| Gesture | Result |
| --- | --- |
| Left click on the brand item | Opens the hub at the last page you were on; clicking again closes it |
| Right click (or ⌃-click) on the brand item | The original menu of full windows, unchanged |
| App menu → Battery & Power (⌘B) | The power sprite's own dashboard when one is in the menu bar, otherwise the hub's Power page |
| ⌘W while it is showing | Closes the hub |

The hub dismisses the way the sprite boards do: an outside click, another app coming forward, sleep,
or a Space change. It never steals focus from the app you were working in.

## The pages

| Page | Content |
| --- | --- |
| System | CPU and GPU temperature, thermal pressure, CPU/GPU usage with history, the memory breakdown with its pressure pill, uptime |
| Apps | Per-app ranking by CPU, memory or CPU power, from the same process accounting the RAM/CPU/Power boards use |
| Network | Download and upload rates with history, lifetime counters, packet rates |
| Disk | Data-volume usage and capacity, block-device read/write rates and IOPS |
| Power | The existing Battery & Power dashboard itself — flow animation, charge-band editor, charge commands, per-app CPU energy — hosted inside the hub rather than linked to |
| AI | The AI Accounts board itself: live Claude and Codex limits, account switching, estimated spend |
| Sprites | Every sprite with its live readout, Enabled and In-menu-bar switches, and a way into its editor |
| Work | A way into Work & Clients, which needs a full window (local builds only) |
| Tools | Keep-awake, the fan and temperature sensors, and the two full pages — Power Controls and Permissions & Access |

Work & Clients, Monitoring & Sprites and Permissions & Access stay full windows: they are wider than
a menu-bar panel can be. Everything else lives in the hub.

## Cost

The hub asks the shared sampler for **only the visible page's readings** (`HubTab.metricIDs` →
`MonitoringStore.setHubMetrics`), and the per-process collector runs only on the two pages that show
a ranking. Switching pages stops the previous page's work immediately; closing the panel clears all
of it. So an open hub costs what one board costs today, not what nine would.

Each page is also sized to its own content, so a short page is not a tall box with a gap in it.

## Evidence

`--hub-validate <directory>` runs against the installed, signed app and writes its report there.
It opens the hub **by clicking the brand status item**, not through a private entry point, walks
every page, and checks what each one requests and releases. Last run, 14 September 2026, on Nebula:

- **42 checks, 0 failed.**
- Every page selected, rendered and requested exactly its own readings and nothing else.
- Live readings present on every page that has them: System 13/13, Apps 5/5, Network 6/6, Disk 9/9,
  Power 12/14 (two battery sensors are hardware-dependent), Tools 4/4.
- The process collector ran on Apps and Power only, and on no other page.
- Closing released the collector and every reading request; three open/close cycles left nothing
  running; ⌘W closed it.
- Footprint of a fresh process: **21.8 MiB with the hub closed, 61.5 MiB with the Apps page open**
  (per-process ranking plus its app icons), 57.8 MiB after closing — warmed caches, the same
  behaviour the memory board's own measurements record. CPU stayed between 1.3% and 3.0% of one core.

Per-page snapshots and `hub-tabs.json` are written beside the report.

## Two fixes this pulled in

- `AccountsStore` now counts its viewers. The accounts board can be on screen twice — its own panel
  and the hub's AI page — and the first one to close used to release the usage data under the other.
- `closeFrontWindow` compared `NSApp.keyWindow` against windows that may not exist, so when no window
  was focused `nil === nil` matched and ⌘W did nothing. Windows are now only matched when they exist.

## Still separate, deliberately

A power **sprite** keeps its own dashboard: clicking that sprite opens the panel it has always
opened, so the sprite's click and the hub's Power page do not fight over one window.
