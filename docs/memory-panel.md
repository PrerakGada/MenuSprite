# Memory panel — 8 September 2026

Local **0.5.1** now adds [process context labels](process-context.md): working
folders, runtimes, worktree names and PIDs, plus evidence-based VM host hints.
The accounting/grouping described below remains unchanged.

Implemented in MenuSprite **0.3.1 (5)** after Prerak supplied Vorssaint's Memory
panel as the reference. Click the existing RAM menu-bar readout; no setup change
is needed. All-memory sprites use this panel; mixed/other sprites retain their
existing configurable boards. The accepted readout appearance stays unchanged.

CPU and Power gained matching panels in 0.3.2; see `cpu-power-panels.md`.
Their shared collector now uses V6 accounting with a V4 fallback. RAM retains
its footprint-based ranking and original layout.

## What it shows

A compact native 350-point-wide panel with a large usage percentage and recent
history, followed by memory used/installed, kernel pressure, app memory, wired,
compressed, cached files and swap used. The app list ranks the **top 30** consumers,
with real application icons, names and memory values; scroll for lower entries.
Hover an app for its contributing process names/PIDs and memory amounts. Activity
Monitor opens from the panel header. Settings opens this RAM sprite's editor;
Close dismisses the panel, and Quit quits MenuSprite.

The layout follows the supplied dense panel reference, using a single AppKit
scrolling drawing surface with native buttons and accessible text rows, system type,
quiet grouped surfaces and a teal history trace. It adapts to macOS appearance.
Binary sizes are explicitly labelled GiB/MiB, including the machine's 36 GiB RAM.
The history shows up to 60 samples; there are no continuous animations.

## Where the numbers come from

System memory remains the existing shared Mach/sysctl sampler. Used memory is
anonymous pages minus purgeable pages, plus wired and physical compressor pages.
Cached files are file-backed plus purgeable pages; these classifications overlap
other memory rows and should not all be added together. Pressure comes from the
kernel's pressure level; swap comes from `vm.swapusage`. Missing values stay unknown.

The app list uses **`proc_pid_rusage` / `ri_phys_footprint`** from the running native
app, not RSS or a guessed share of total memory. It includes compressed allocation
accounting, so app footprints do not add up to the system's physical used-RAM total.
The snapshot also reads identity, parent, user, name, executable path, selected
runtime working-directory metadata and bounded VM resource-path metadata.
It never requests `task_for_pid`, reads process memory contents, command-line
arguments or environments, or launches `ps`, a helper or a shell collector.

Attribution is explicit:

- Processes inside the same outer `.app` bundle, including embedded helper apps,
  are grouped under that application.
- Other child processes follow their observed live parent chain to an app. For
  example, a terminal's shell and tool children can contribute to the terminal.
- An executable belonging to another app keeps its own identity even if launched
  from Terminal. Shared/reparented/unattributed services stay separate.
- Identity is checked across accounting/metadata reads. Parent links cannot cross
  users or point at a newer process, and cycles/duplicate PIDs cannot double-count.
- Exited or inaccessible processes are omitted with a coverage count, never shown
  as zero. This is the accessible process set, not a claim of complete visibility
  into every protected process.

This uses observable bundle/parent relationships rather than Vorssaint's private
responsibility API. Some attribution can therefore differ from Vorssaint or Activity
Monitor. The totals and tooltip membership make that difference inspectable. The
reference screenshot's values were not hardcoded, and no third-party implementation
was copied.

## Resource lifetime

The process sampler is created only for an open Memory panel, refreshes immediately
then every **5 seconds**, and is cancelled on close, sprite removal, disabling or
app exit. The board discards process records and its small, bounded icon cache on
close. Path metadata is retained only by that panel's sampler and keyed by PID/start
identity. Existing readout sampling continues at the user's chosen interval.

Opening Memory adds the breakdown/history readings to the shared memory demand;
closing it removes that demand. The anchored panel dismisses on an outside click, Escape, Command-W, app/space
switch or sleep. Temporary mouse-click dismissal monitors are removed on close;
no global key events or event contents are recorded. No process-list polling or permanent second timer
is added to the closed-panel resident app. A manual Refresh also restarts the app
snapshot. The disabled-sprite view starts no process collection.

## Checks and evidence

Attribution tests cover helper/terminal grouping, conservation of totals, app
identity boundaries, reused/missing parent PIDs, different users, parent cycles,
duplicate PIDs, and executable name collisions. Full test run: **36 passed, one
optional live-source test skipped** (37 total).

The installed-app acceptance mode is:

```sh
# Quit the existing instance first. Requires a visible, enabled RAM sprite.
open ~/Applications/MenuSprite.app --args --memory-validate "$PWD/native/.build/validation/memory"
```

It preserves the saved configuration, reads the actual app/process and system
memory state, opens the real panel anchored to the RAM status item, renders only that native
view, checks grouping/ranking and collector cleanup, and measures the resident
app before/during/after the panel. It leaves the Memory panel open for review.
The debug output includes process names/PIDs/paths and stays local in ignored
build artifacts; ordinary use writes none of that information to disk.

Local evidence for this build is under `native/.build/validation/memory-031/`.
The final run is `native/.build/validation/memory-031-reviewed/`.
Earlier experimental rendering runs are retained separately; they are not the
final memory benchmark.

Primary API references:
[Apple rusage_info_v4](https://developer.apple.com/documentation/kernel/rusage_info_v4),
[Apple memory-accounting example](https://developer.apple.com/la/videos/play/wwdc2022/10106/),
and the installed SDK's `libproc.h`, `sys/proc_info.h` and `sys/resource.h`.

## Final native results

**16/16 native checks passed** in the installed, signed app: the actual RAM click
path, live breakdown, sorted consumers, one attribution per readable PID, exact
member sums, live refresh, immediate cancellation/data cleanup, collector release,
removed sampling demand, repeated open/close and the Command-W close path.
The native panel was also visually reviewed on screen; Refresh, scrolling through
the lower-ranked list, Settings opening the existing RAM editor, and Cancel
preserving the configuration were exercised through native UI automation. Protected/exited processes
remain excluded and counted; this is not a complete protected-process inventory.

Actual short samples with the saved CPU/RAM/PWR readouts at 2s:

| State | Physical footprint | RSS | CPU, one core |
| --- | ---: | ---: | ---: |
| Fresh app, Memory closed | 13.61 MiB | 69.23 MiB | 0.286% |
| Memory open, app list every 5s | 30.86 MiB | 107.38 MiB | 1.391% |
| After closing Memory | 22.16 MiB | 84.36 MiB | 0.264% |

Each phase was approximately 20–21 seconds. The open-panel measurement preceded
the diagnostic render; the after-close measurement includes warmed AppKit/icon
caches. The process collector, its snapshot and icon cache were released. These
are observations on this busy Mac, not an overnight guarantee or a universal
resource budget. Earlier experiments with the system popover incurred over 200 MiB
in graphics accounting; the final opaque anchored NSPanel avoids that container.
No privilege or permission request was needed.
