# Work and client tracking — what each client costs

Decision record · 12 September 2026 · **report UI implemented; native collection and AI accounting pending**

MenuSprite becomes the home for Prerak's per-client work accounting: how many hours a client
actually took, and how much AI was spent on their repositories. The local native **Work & Clients**
report now reads the existing paneclock database, with client assignment, billable projects,
hourly rates, manual time and CSV export. See [report UI](work-report-ui.md) for the implemented
boundary and validation. The rest of this page records the intended collector and AI scope;
those have not been ported. paneclock remains the writer, and history has not been imported.

## Intended use

Personal work accounting should make client hours and project AI usage reviewable.
Historical client records, commercial details and internal migration notes stay local.

## What it collects

All on this Mac, for Prerak only. No employee, no server, no upload.

| Signal | Source | Permission |
| --- | --- | --- |
| Terminal pane focus and the directory each pane is in | iTerm2's own API (pane/tab/window focus, `path`, `jobName`) | Automation prompt for iTerm2, once |
| Front application focus intervals | `NSWorkspace` frontmost application | none |
| Input presence (present vs away) | `CGEventSource` idle seconds | none |
| Claude Code and Codex usage per project | the CLIs' own local session logs (`~/.claude/projects/**.jsonl`, `~/.codex/sessions/**`) — counters, model names, cwd and git remote only | none |

Window titles and browser URLs are **not** collected. They need Accessibility or a browser
extension, and are outside this personal accounting scope.

## How it runs — the exception this feature needs

Every existing MenuSprite reading is sampled on demand: `MonitoringStore.demand()` collects what
enabled sprites and open panels ask for, and the sampler suspends when nothing is visible. **This
feature cannot work that way.** If collection stops while no window is open, the hours are not late,
they are gone.

So work tracking gets an always-on collector, separate from the shared sampler, and the
low-footprint rule applies to it directly:

- Baselines to protect: **15.14 MiB physical / 0.0073% of one core** with all sprites paused, and
  16–17.8 MiB while sampling (`docs/monitoring-validation.md`).
- Outside bound to beat: paneclock's Python daemon does the same terminal accounting in **~14 MB RSS
  at no measurable CPU**. A native collector should cost less.
- Write to disk in bounded batches, never a row per tick per pane.
- Survive sleep and wake, quit cleanly, and lose at most one tick to a crash.

## Attribution

A rules file maps evidence to a project and client, longest path prefix first, as paneclock does
today: path prefix, then git remote, then git root name, then directory name. Front-app time uses a
second rule set mapping an application to a client, only where that is unambiguous. Time that cannot
be attributed is shown as unattributed and never spread across clients.

Meetings and calls are added by hand from the board. Inferring them from a calendar or a microphone
is the wrong trade for this tool.

## AI usage: three numbers, and Prerak picks

Each client's AI usage is shown three ways, because they answer different questions:

1. **Tokens** — the raw share of consumption.
2. **API list-price equivalent** — what those tokens would cost on the API.
3. **Share of the real bill** — the actual monthly Claude and Codex plan cost, split by token share.
   Plan prices are entered once.

Only (3) represents actual spending. API-equivalent estimates must stay separate from
subscription charges. Use explicit calendar-day boundaries for comparisons.

The export step is where Prerak chooses which of the three, if any, a client sees.

## Storage and surfaces

- A SQLite database in Application Support, one row per focus interval. paneclock's schema is the
  known-good starting shape (`start_ts`, `end_ts`, `active_seconds`, `path`, `project`, `client`,
  `git_root`, `git_remote`, `attribution`, `job_name`).
- **Preserve existing paneclock history before importing it.** Validate every source interval
  and retain a private backup; never put a real work database in Git.
- A menu-bar sprite for the live number (today's hours, or today's top client).
- A board for the report: per client and project over a date range, with hours, AI and CSV export.

## Collector implementation

The native collector and project AI accounting remain unimplemented. Any future reuse
from another codebase needs its ownership and license checked before incorporation.

## Boundaries

- **Local build only.** Not in the public Homebrew/DMG release. Billing data and a continuously
  running collector are not part of what was published as 0.4.0.
- **No employee anything.** No consent flow, no surveillance receipt, no manager view, no backend,
  no dashboard server. Watching someone else's Mac would be a different product and a new decision.
- Nothing leaves this Mac.

## Open

- **The name.** Deferred on 12 September. `work.*` metric IDs and "Work and clients" are working
  labels, not a decision. Every dictionary word for reckoning is already accounting software:
  Hisaab, Lekha, Daybook, Tithe and Almanac all resolve to existing products.
- Whether paneclock's daemon is retired at import or kept running for a week as a cross-check.
- The per-client rate and currency for the billing view (paneclock's is INR, editable).
- Validate usefulness through actual user-reviewed reports before expanding the scope.
