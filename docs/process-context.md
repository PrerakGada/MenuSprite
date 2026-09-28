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

## Claude Code sessions — 24 September 2026

Prerak asked for a way to tell Claude Code sessions apart in the RAM list and to see
their combined cost at a glance. Each session appeared as its own row named after its
executable (`~/.local/share/claude/versions/2.1.281`, so the row read "2.1.281"), and
each of its MCP `node` servers as another row. Ancestry could not help: a terminal
session's chain runs through `/usr/bin/login`, which is root-owned and unreadable, so
nothing reached iTerm. On the day it was built this Mac had **23 sessions, 107
processes, about 8.3 GiB**, spread over roughly 90 rows.

**What is shown.** RAM, CPU and Power (panels, hub, and the Battery & Power dashboard)
now have one **Claude Code** row with the combined reading, captioned "23 sessions ·
2 working". It gathers every Claude Code process (the native installer's versioned
binaries and the editor extensions' `claude` binary) and everything each one started
(MCP servers, tool shells) through live ancestry. This applies in any terminal or editor, so
a session inside VS Code joins it too. A child that is itself an app bundle (for example a
Chromium launched by a tool) stays that app's row. Clicking the row, or its chevron,
expands it into one row per session:

- **Title**: your rename if you gave one, otherwise Claude Code's own auto title
  ("TB Stores physical stock reconciliation"), otherwise the project folder.
- **Caption**: project · `working` / `idle 2 d` / Claude Code's own status word ·
  `background` for daemon-hosted sessions · PID.
- **Reading**: the session's own process plus its MCP servers and tools.
- **Quit** on each session row, same one-click / second-click-forces behaviour as
  every other row. The hover text gives `claude --resume <session id>` to reopen it.

The daemon and its spare processes, which have no session, form one "Claude Code
background service" member. **The group row has no quit.** One click would end every
session, including busy ones and the one doing the asking. Its trailing control opens
the group instead.

Members partition the group's processes; totals are never counted twice. An npm-installed
Claude Code runs as `node` and is not recognised, because telling it apart would need its command line.

**Files read: a deliberate, scoped exception to "no file contents".** For a
Claude Code process owned by this user only:

- `~/.claude/sessions/<pid>.json` (Claude Code's own registry: session id, cwd,
  status, last activity, name). It is rejected when its `pid` differs or its `startedAt`
  is more than 10 minutes from the live process's start, so a reused PID never takes a
  dead session's label. Re-read only when its modification date changes.
- The last 64 KiB (at most 256 KiB) of that session's transcript
  `~/.claude/projects/<folder>/<session>.jsonl`, for the `custom-title` / `ai-title`
  lines only. Other lines are skipped without being parsed unless they contain one of
  those type names, and anything parsed that is not a title is discarded. The title is
  kept in memory. It is re-checked at most every 30 seconds, and only when the file has
  grown.

No prompt, message or tool text is kept. Nothing is written. Caches live with the
open panel's sampler and are pruned to live PIDs every sample.

**Verification.** `ClaudeCodeTests` (8 tests) covers grouping and partition, editor
and app-bundle children, wording, the group's refusal to quit, member ranking, the
reader's rename precedence, reused-PID rejection, the "mentions ai-title" false
positive, and old snapshots decoding. All 89 package tests pass. The live probe
(`MENUSPRITE_LIVE_PROBE=1 swift test --filter liveClaudeSessionsProbe`, which prints
private titles) matched every running session to its title. The panel itself has
**not** been checked by eye yet.
