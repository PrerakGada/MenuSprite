# Process context labels — 10 September 2026

Implemented locally in **MenuSprite 0.5.1 (10)** after Prerak asked why the RAM
list contained several indistinguishable Node, Dart and Java rows.

Those were real independent processes whose executable names identified only
the runtime. The existing attribution uses app bundles and observed ancestry;
a detached job or a broken/reparented ancestor chain cannot always be assigned
to a GUI app. This update improves the presentation without changing ownership,
merging jobs by name, or altering any memory/CPU/power totals.

## What is shown

RAM, CPU and Power share `ProcessPresentation`:

- Recognized runtimes show their observed working folder, runtime and PID.
  Worktrees show their worktree name separately from the main project/folder.
- Flutter SDK Dart processes are identified as Flutter / Dart; a shared Gradle
  daemon is labeled as Gradle, with its version and PID, rather than assigned to
  whichever project might have launched it earlier.
- A macOS Virtualization worker can be labeled as a Docker VM when accessible
  open descriptor metadata identifies Docker's LinuxKit resources or VM disk.
  Without evidence, it remains “Virtual machine service”. It stays a separate
  accounting group from Docker itself.
- Existing app/bundle groups retain their names and icons. Runtime rows get a
  second line; hover details explain the evidence and show the executable path.
  The native accessibility labels contain the same context.

Illustrative context labels (synthetic project names):

| Runtime | Context label |
| --- | --- |
| Node | ExampleApp / backend, worktree `feature-example` |
| dartaotruntime | ExampleApp / app, Flutter / Dart |
| Virtualization service | Docker virtual machine, when supporting evidence exists |
| Java | Gradle daemon and its detected version |

Working-directory context is not proof of GUI ownership. Private process snapshots
and project names used during local validation are not included in the source repository.

## Metadata and lifecycle

The native collector reads current-directory metadata with
`proc_pidinfo(PROC_PIDVNODEPATHINFO)` only for recognized runtimes/VM workers owned
by the current user. For VM workers it examines at most 256 file-descriptor
metadata records and retains only recognized host-resource evidence. VM hints
are cached for up to 30 seconds by PID/start identity; runtime cwd is refreshed
with the panel's existing five-second collection. Identity is confirmed again
after metadata reads so reused PIDs do not acquire another process's context.

No command-line arguments, environments, process-memory contents, filesystem
traversal or file contents are read. No helper, root command or shell collector
runs inside the app. Context and caches live only with the open panel's sampler.
Ordinary use writes no process metadata to disk; explicit developer diagnostics
remain local under ignored `native/.build/validation/`.

## Verification

- **54 automated tests passed; one optional live probe skipped** (55 total).
  New tests cover project/worktree context, Flutter, shared Gradle, unknown context,
  unchanged bundle ownership and totals, VM evidence and older snapshot decoding.
- **20 native checks passed**, including live cwd hints and VM evidence, PID
  uniqueness, exact totals, existing RAM breakdown, refresh, and cleanup.
- Native label evidence and the rendered RAM panel are in
  `native/.build/validation/process-context-051/`.
- Short observations: 19.16 MiB / 1.24% of one CPU core closed; 41.64 MiB / 2.33%
  open; 37.42 MiB / 1.23% after close. Each sample was about 20 seconds. These are
  local observations, not guarantees or claims about another application's memory.

The public Homebrew/DMG release is unchanged by this local feature update.
