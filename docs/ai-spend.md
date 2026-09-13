# Estimated AI spend

Local native feature · 13 September 2026

MenuSprite estimates what the work recorded in Claude Code's and the Codex CLI's own session logs
would have cost at published API rates. **It is an estimate of API-rate cost, never money charged** —
Subscription billing is separate from this estimate. Account limits and their
percentages are a different feature (`docs/ai-usage.md`); this page covers dollars only.

## Where the numbers come from

| Provider | Logs | Billable record | Counted once by | Model from |
| --- | --- | --- | --- | --- |
| Claude | `~/.claude/projects/**/*.jsonl` | `type: "assistant"` lines carrying `message.usage` | `(message.id, requestId)` | `message.model` |
| Codex | `~/.codex/sessions/**/*.jsonl` | `type: "token_usage_record"` | `payload.response_id` | most recent `turn_context.model` in the file |

Three measured facts shape the arithmetic. Each was verified against the real logs on this Mac before
the scanner was written, because each would otherwise have produced a wrong number quietly:

- **Claude logs the same request more than once.** In a 220-file sample, 14,848 assistant records
  collapse to 6,868 distinct requests — about 2.2 records per request. Counting records rather than
  requests would inflate the figure roughly 2.2×.
- **Requests are replayed into other files when a session resumes.** One project's 120 files share 143
  request keys across files; another's 36 files share 205, which is 7% of its requests. Dedupe is
  therefore global — an ownership index decides which file counts a request — not per file.
- **Codex reports one per-request figure and two running totals.** `payload.usage` is that request's
  own usage, while `turn_token_usage` and `thread_token_usage` accumulate across the turn and thread
  (41k → 87k → 143k → 202k within a single turn). Only `payload.usage` is counted.

Claude's `cache_creation` split (`ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`) is read
where present; older lines report one aggregate, which is treated as a 5-minute write. Codex's
`cached_input_tokens` are reported inside `input_tokens`, so the remainder is billed at the input rate
and the cached part at the cache-read rate.

## Rates

Dollars per million tokens, from Anthropic's first-party API pricing as published in the bundled
`claude-api` skill model table, cached **2026-06-24**. `ModelPricing.rates` is the only place they live.

| Model | Input | Output |
| --- | --- | --- |
| Opus 5, Opus 4.8, Opus 4.7, Opus 4.6 | $5 | $25 |
| Sonnet 5 | $2 | $10 |
| Sonnet 4.6, Sonnet 4.5 | $3 | $15 |
| Haiku 4.5 | $1 | $5 |
| Fable 5, Fable 5.1 | $10 | $50 |

Cache writes bill above the input rate by TTL — **5-minute writes at 1.25×, 1-hour writes at 2×** — and
cache reads at **0.1×**, except Fable 5.1 (and Mythos 5.1), which read cache at 0.025× base input, the
published $0.25/MTok. Dated model ids (`claude-haiku-4-5-20251001`) resolve to their base model.

> **The 1-hour multiplier matters more here than any other rate.** One-hour cache writes dominate this
> corpus — 191M, 367M and 54M tokens across three project directories, against roughly 1M five-minute
> writes — so pricing both TTLs alike is not a rounding error. An earlier build of this scanner did
> exactly that at 1.25× and understated every Claude total; the value was corrected to 2× against
> Anthropic's published caching pricing on 13 September 2026. `ModelPricing.cacheWrite5mMultiplier` and
> `cacheWrite1hMultiplier` are the two constants that carry it, and `cacheWriteTTLsBillAtTheirOwnMultiples`
> in the tests pins both so the placeholder cannot creep back.

**No published rate exists in this environment for any Codex model** (`gpt-6-astra`, `gpt-5.6-sol`,
`gpt-5.6-terra`, `gpt-5.5`). Their tokens are counted and the model names are returned in
`unpricedModels`; the dollar readings then say so rather than report a total that silently ignores
part of the work. Adding a rate to the table is all that is needed to price them. Claude Code's local
`<synthetic>` work is counted at $0 — real tokens, no charge — and is not treated as unpriced.

## Readings

| ID | Reading |
| --- | --- |
| `ai.claude.spendToday` / `ai.codex.spendToday` | Estimated cost of today's sessions |
| `ai.claude.spend7d` / `ai.codex.spend7d` | Rolling seven local days |
| `ai.claude.spend30d` / `ai.codex.spend30d` | Rolling thirty local days |

Days are **local** days, bucketed from each event's own timestamp. `Calendar.ordinality(of: .day,
in: .era,)` looks like the primitive for that and is not: measured with an Asia/Kolkata calendar it
put two instants on the same local day in different buckets, and two instants on different local days
in the same one. Buckets are counted from `startOfDay`, which does respect the time zone.

## Cache

Two files in `~/Library/Application Support/MenuSprite/`, mode 0600, deliberately split by what the app
must hold: **`ai-spend-summary.plist`** (kilobytes — the per-day, per-model aggregate, the only thing
kept in memory between scans) and **`ai-spend-scan-state.bin`** (megabytes — per-file records and the
request-ownership index, in a fixed-width binary format, opened only inside a scan and released with it).

- **Per file:** path, size, modification date, and per-day per-model token totals. No per-request rows,
  no prompts, no log text — the only per-request artefact anywhere is a 64-bit hash.
- **Ownership index:** one `(hash, owning file, day)` row per request inside the retained window, so a
  replayed request is counted once across files.
- **Retention:** 35 days. The readings report today, 7 days and 30 days; the extra days absorb
  time-zone edges without keeping a year of history.
- **Reuse:** a file whose path, size and modification date are unchanged is never reopened. A file
  whose modification date predates the window is never opened at all.
- **Invalidation:** bumping `SpendCacheData.parserVersion` discards every record, which is how a parser
  fix ships. An unreadable cache is rebuilt rather than trusted.
- **Deletion:** if a previously-scanned file has disappeared, the provider's cache is rebuilt from
  scratch. A deleted file may have owned requests that also live in a file whose cached totals excluded
  them, and patching that up would undercount silently.

## Behaviour

Scanning runs off the main actor at utility priority and is cancellable between files. `summary(_:force:)`
returns what is already known and refreshes in the background; it never makes the UI wait for a scan,
and marks its figures `partial` while one is in flight. Lines larger than 2 MB are skipped without
being parsed and are counted in the scan statistics.

## Limits

- An estimate at API rates, not billing, and not a claim about what Anthropic or OpenAI charged.
- Codex dollars are unavailable until a rate exists for its models; its tokens are still counted.
- The 1-hour cache-write multiplier dominates the Claude figure. It was confirmed at 2× against
  Anthropic's published caching pricing on 13 September 2026, having shipped briefly at a placeholder
  1.25×, which understated every total by roughly $1,000 over thirty days.
- Only the default log locations are read: `CLAUDE_CONFIG_DIR` and `CODEX_HOME` overrides are not followed.
- Work done outside these CLIs — claude.ai, Claude Desktop, the Codex web app — leaves no local log and
  is not counted.
- A first scan of a large history is expensive; see the measured cost below.

## Turning it on

**Estimates are off until the user enables them**, through *Estimate spend* in the AI Accounts board.
A first pass reads every session log on the Mac — minutes of work, hundreds of megabytes of parsing —
and a board opening is not consent for that. The setting is `MenuSprite.SpendEstimatesEnabled`; with it
off, neither the board nor a spend sprite asks the service for anything. Once on, refreshes are
incremental and cost about a second.

## Measured cost, 13 September 2026

Each provider was scanned in its own process against the real corpus, read-only. A process-wide
high-water mark cannot be attributed to one scan when two run together, so each figure below comes
from its own run, each starting at 24 MiB resident.

| | Claude | Codex |
| --- | --- | --- |
| Files considered | 16,112 | 557 |
| Files read (inside the 35-day window) | 11,222 | 155 |
| Files skipped by age | 4,890 | 402 |
| Requests counted | 235,798 | 6,577 |
| Replays skipped (same request in another file) | 708 | 0 |
| Oversized lines skipped | 33 | 123 |
| Cold scan | 174.6 s | 13.4 s |
| Warm re-scan | 0.89 s (read 5 changed files) | 0.02 s (read 1) |
| Peak resident during cold scan | 224 MiB | 273 MiB |

A later Claude run, taken while the machine was busy with other builds, read 313.4 s and peaked at
253 MiB — the timing moves with contention, the memory does not.

**Resting cost is the figure that decides whether this belongs in a menu-bar app, and it is 2 MiB.**
A fresh process that loads the aggregate and never scans sits at 26 MiB against a 24 MiB launch
baseline, and answers a summary in 6 ms. That is measured in a process that has scanned nothing:
resident memory inside a process which has just parsed gigabytes says nothing about what the app
holds, because freed pages stay with the allocator. An earlier reading of "297 MiB idle" was exactly
that mistake. On disk the split shows the same shape — an 788-byte summary against a 216 KB scan
state for Codex.

The corpus is 16,128 files / 11.11 GB for Claude, of which 11,222 files / 8.27 GB fall inside the
window, and 557 files / 1.89 GB for Codex, of which 155 / 1.27 GB. Roughly three quarters of the bytes
are parsed on a first run, which is what makes it minutes rather than seconds.

An earlier build peaked at **4,305 MiB** and took 641 s. Three changes account for the difference:
each chunk and each file is parsed inside an autorelease pool, so Foundation's temporaries from
millions of JSON lines drain as the scan proceeds; consumed bytes are dropped once per chunk rather
than once per line, removing an O(n²) recopy of the read buffer; and the per-file records and
ownership index moved out of memory into the binary scan-state file.

Personal usage totals, per-model costs and account-specific readings are retained
only in private validation records. Synthetic accounting cases live in the test suite.
