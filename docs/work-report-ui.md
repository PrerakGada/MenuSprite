# Work & Clients — native report

Implemented locally on 12 September 2026, version 0.5.2 (11). Open **MenuSprite → Work & Clients…**
(⌘T), or use the Work & Clients button in Monitoring & Sprites. This is a native, resizable Mac
window, not the old the earlier work-tracking exploration dashboard or a webpage.

## What is usable

- Client sidebar, an explicit Needs a client filter, project search, Today / This week / This month /
  All history / custom dates. All dates use Asia/Kolkata, with Monday as the start of the week.
- Recorded time, separately marked billable time, and billing estimates grouped by currency.
  A static native activity histogram and project table lead into a source-interval inspector.
- Assign a project to a client and mark it billable. Enter a client-wide hourly rate in INR, USD,
  EUR, GBP, AED, CAD or AUD. Defaults are non-billable with no rate. An unset rate is not zero;
  a deliberately entered zero rate is valid. Client/rate changes apply to all report history.
- Add calls, meetings and other work as manual intervals, including projects absent from the source.
  Times must be in the past and no longer than 24 hours per entry. Potential overlaps need an
  explicit acknowledgement. Manual entries can be removed and that removal undone.
- Export the filtered project summary or its time entries to CSV. Hours retain precision in the
  export; display times round to minutes and durations below a minute say `<1m`. Quotes and
  multiline descriptions are preserved; source/user text cannot become spreadsheet formulas.
- Data & coverage explains source health and accounting limits, with a real database chooser.
  The AI accounting page explains what is missing and the distinction between tokens, API price
  equivalent and share of a subscription bill. It does not show invented costs or enabled dead controls.

## Source and accounting

The default source is `~/.local/share/paneclock/paneclock.db`. SQLite opens it **read-only**, including
the live WAL. No migration, writer lock, source-rule edit or source-history import takes place.
Only columns needed for the report are read; terminal contents, window titles and URLs are not.

Local edits live separately in `~/Library/Application Support/MenuSprite/work-report.json`, saved
atomically. A damaged settings file is preserved and reported, not reset. Source errors retain the
last successfully loaded report with a visible error. Closing the window cancels its refresh task,
releases its loaded rows and removes the window/store from the app delegate. No work-report store
or refresh task is created during an ordinary background launch.

The board refreshes every 30 seconds **only while open**. The last-recorded timestamp is evidence
from the latest source interval, not a claim that paneclock is currently healthy. paneclock remains
responsible for recording. Active terminal time is not an entire working day; unknown client time
is never apportioned to clients. Manual overlaps may need human judgment because paneclock stores
aggregate active seconds within a wall-time interval.

Rows intersect date ranges by overlap, then prorate their active seconds at the boundaries. The
histogram splits crossing intervals at IST midnight using the same calculation. Zero-active
intervals remain counted in source coverage but do not add report rows or CSV activity. Billing
uses unrounded active hours × the entered rate, rounds each project amount to two decimal places,
and sums amounts separately by currency. These are estimates, not issued invoices or a billing ledger.

## Implementation

- `native/Sources/WorkTracking`: SQLite reader, report grouping, IST boundaries, settings, manual
  validation and CSV encoding; no AppKit or continuously running watcher.
- `native/Sources/MenuSprite/WorkStore.swift`: window-scoped state and working actions.
- `WorkBoard.swift`: report, inspector, billing/manual sheets and coverage pages.
- `WorkActivityChart.swift`: small AppKit histogram, no chart framework or animation timer.
- `MenuSpriteApp.swift`: menu/keyboard entry and lifecycle. Public-preview builds expose no work UI.

## Validation

`swift test --package-path native`: **119 tests passed**, including seven new accounting tests.
Coverage includes IST midnight, range clipping, future-time exclusion, unknown rates, identity
separation, manual input, settings persistence/corruption, CSV quoting/formulas and reading a live
WAL without modifying the database or WAL bytes.

Native validation runs in the signed installed bundle with a consistent SQLite backup and isolated
settings. Test client names, rates and manual entries never enter normal user settings.
Evidence: `native/.build/work-validation-2026-09-12/` (ignored; contains real private project data).
Project totals, nonzero intervals and daily bars reconciled independently to the
native CSV via `scripts/validate-work-report.py`. Personal work totals and database
contents are retained privately. Source rows are not assumed correct merely because
the screen looks plausible.

All **21 native checks passed**. The diagnostic checks real source loading, filters, saved billing calculations, manual add/remove/
undo, opening the native sheet, release of window state, reloading, and the installed app's ability
to read the live paneclock WAL. Light/dark, minimum-window and form renders are reviewed locally.

To repeat, make a SQLite **backup** (not a bare copy while its writer runs) at
`<evidence>/paneclock.snapshot.db`; switch the backup alone to `PRAGMA journal_mode=DELETE` so it
is self-contained. The Mac SQLite reader cannot always open a detached WAL-mode backup read-only
before its sidecar exists. Then quit the app and run:

```sh
open ~/Applications/MenuSprite.app --args --work-validate <absolute-evidence-directory>
python3 scripts/validate-work-report.py <evidence-directory>
```

`--work-measure` added to that invocation skips screenshots and mutations for a cleaner
before/open/closed measurement. The normal diagnostic also records short process CPU/physical
footprint samples; those include existing configured monitoring sprites and rendering overhead,
so they are not a paused-collector baseline or a long-duration leak test.

The clean no-screenshot run in `native/.build/work-measure-2026-09-12/report.json` measured:

| Phase | Physical footprint | CPU, one core |
| --- | ---: | ---: |
| Before the work window | 18.58 MiB | 1.51% |
| Work window open | 51.38 MiB | 1.29% |
| Ten seconds after close and release | 43.49 MiB | 0.89% |

The process does **not** return to its fresh-launch footprint after loading native UI; these figures
must not be described as the older 15.14 MiB fully paused baseline. Work rows and refresh tasks are
released, but some process memory remains; this diagnostic does not attribute that memory. These are short observations with the existing
monitoring sprites active, not evidence of long-term stability.

## Still separate work

The always-on Swift collector, paneclock history import/retirement, front-app/input-presence
attribution, project AI log accounting and configurable `work.*` reading sprites remain pending.
Existing Claude/Codex account-limit sprites do not supply project token counts or costs. AI costs
are explicitly excluded from estimates and exports. No actual client rate was inferred or entered.
The public 0.4.0 download is unchanged.
