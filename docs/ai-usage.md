# AI usage readings — Claude and Codex limits

Local native feature · 11 September 2026

MenuSprite shows how much of Prerak's Claude and Codex subscription limits are used,
as ordinary readings in the **AI usage** category. They replace OpenUsage for the two
default logins on this Mac. Account switching lives in the Accounts board
(`docs/account-switching.md`); this page covers only the readings.

## Where the numbers come from

Nothing is estimated from local logs. Both providers are asked the same question their
own CLIs ask for their limit screens, which is also exactly what OpenUsage 0.7.10 does:

| Provider | Login read | Request | Mapped windows |
| --- | --- | --- | --- |
| Claude | Keychain item `Claude Code-credentials` (account `$USER`), email from `~/.claude.json` `oauthAccount` | `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20` | `five_hour` → Session, `seven_day` → Weekly, **every `limits[]` `weekly_scoped` entry** → a window named after its model, superseding the legacy `seven_day_<model>` key; `spend` → extra usage in dollars (falling back to `extra_usage`); `seven_day_breakdown` → the week's split across surfaces |
| Codex | `~/.codex/auth.json` (email and account ID from its id token) | `GET https://chatgpt.com/backend-api/wham/usage` with `ChatGPT-Account-Id` | `rate_limit` windows classified by `limit_window_seconds` (18 000 → 5-hour, 604 800 → weekly), slot order only as a fallback; header percentages as a fallback; `plan_type`; `additional_rate_limits` → Spark windows; `credits.balance` → credits and their value at Codex's own 4¢ each; reset credits from `wham/rate-limit-reset-credits` |

Keychain reads use the Security framework with UI disabled; they never prompt.

## Readings

| ID | Reading | Unit |
| --- | --- | --- |
| `ai.claude.session` / `ai.claude.weekly` | Claude 5-hour / weekly limit used | percent |
| `ai.claude.sonnet` / `ai.claude.fable` | Claude weekly Sonnet / Fable limit used | percent |
| `ai.claude.sessionReset` / `ai.claude.weeklyReset` | Time until those windows reset | seconds |
| `ai.claude.account` / `ai.claude.plan` | Signed-in email / plan (e.g. Max 20x) | text |
| `ai.codex.session` / `ai.codex.weekly` | Codex 5-hour / weekly limit used | percent |
| `ai.codex.sessionReset` / `ai.codex.weeklyReset` | Time until those windows reset | seconds |
| `ai.codex.account` / `ai.codex.plan` | Signed-in email / plan (e.g. Pro 20x) | text |
| `ai.claude.extraUsage` | Extra usage spent this month | dollars |
| `ai.claude.claudeCodeShare` | Share of the week that came from Claude Code | percent |
| `ai.codex.credits` / `ai.codex.creditsValue` | Flex credits left, and their value at 4¢ each | count / dollars |
| `ai.codex.resets` | Rate-limit reset credits available | count |
| `ai.codex.spark` / `ai.codex.sparkWeekly` | Model-specific Spark limits | percent |
| `ai.claude.spend*` / `ai.codex.spend*` | Estimated spend today / 7 days / 30 days | dollars |

A model-scoped limit the catalog never heard of — a new weekly Sonnet or Opus allowance — becomes a
reading of its own as soon as the provider sends it, so it can go in the menu bar like any other.

## What the providers report beyond percentages

- **Claude extra usage** comes from `spend` (`amount_minor` with its `exponent`), falling back to the
  older cents-based `extra_usage`. An allowance that is switched off reports a real **$0.00 with
  `enabled: false`**, which is what Prerak's account reports today — not a missing value.
- **The weekly breakdown** splits the current window across surfaces: on 13 September, Claude Code 98%,
  Chats 1%, Cowork 1%, Other 0%. The AI Accounts board shows the whole split.
- **Codex credits** are the balance plus its dollar value; **reset credits** are the on-demand
  allowances that clear the five-hour window, with each credit's expiry when the account holds any.
  MenuSprite reads them and never claims one. Both read 0 on this Mac today.
- **Estimated spend** is not provider data at all — it is reconstructed from local session logs at
  published API rates. See `docs/ai-spend.md`. Measured on this Mac on 13 September: Claude today
  $428.65, 7 days $2,367.72, 30 days $21,045.67 across 36.4B tokens and 235,906 requests, led by
  Opus 5 at $14,429.10. Codex reads $0.00 because no published rate covers `gpt-6-astra` or
  `gpt-5.6-sol`; its 1.64B tokens are counted and the models named rather than priced at a guess.
  A subscription already covers this work — the figure is a usage signal, not a bill.

A window the account does not have (for example a Codex plan that reports only a weekly
window) reads as unavailable rather than 0%. Quick start offers **Claude usage** and
**Codex usage** sprites. The metric IDs are the contract with the Accounts board, which
opens for sprites whose readings start with `ai.`.

## Menu-bar pace colors (13 September, local 0.5.3)

The sprite editor now has **Color rule → AI usage pace**, saved per sprite. Fixed color
remains the default for existing configurations. Prerak's two existing items use the
pace rule with no icons. In local 0.5.4, **Weekly AI usage** pairs GPT (Codex) weekly
on top and Claude weekly beneath it; the paired weekly item shows **percentages only**
(labels hidden by Prerak's follow-up). **Claude session** is a separate percentage with
only the small label **Claude** above it; it still reads the five-hour usage window.
Per-reading labels are editable under “Readings in this sprite” and persist with the
sprite. Empty labels fall back to the reading's standard label; source names/IDs stay intact.
As of build 15, **only Prerak's Claude/Codex usage items are bold**. Their numbers and
the small Claude label are white; only each **%** symbol carries the pace color.
This is the saved **AI usage pace (% only)** rule. The whole-reading pace option remains
available, and the base text color is selectable. CPU/RAM/power/network/fan-temperature
readouts were restored exactly to the pre-bold settings. The Bold setting covers small
labels as well as values when enabled.
The same rule supports Codex's 5-hour window if an account reports it and it is selected.

Each reading's pace is independent, including inline text, two-row items, labels
above values and their editor previews. In the % only mode, a hidden unit leaves the
whole value in its base text color. Percentages mean **used**, not remaining.

| Window | Current cumulative allowance | Green | Amber | Red |
| --- | --- | --- | --- | --- |
| Weekly | Current day × 100/7 (14.2857% per day) | At or below allowance | Above allowance, up to one extra day | More than one extra day ahead |
| Five-hour | Current hour × 20% | At or below allowance | Above allowance, up to one extra hour | More than one extra hour ahead |

Day/hour 1 starts at the provider's reset time minus its window duration. These are
whole 24-hour/1-hour buckets anchored to that reset, not calendar days or a continuously
moving hourly weekly budget. On day 1 the thresholds are 14.2857% and 28.5714%; on day 2
they are 28.5714% and 42.8571%. Exactly 100% used is always red, even in the final bucket.
Calculations use the raw percentage; display rounding does not move a threshold.

Missing/expired reset times, unsupported durations, invalid percentages and snapshots
served with a stale-data notice use gray for the rule color (only the % in % only mode).
An unavailable value without a % stays in the base text color. There is no inferred reset or assumed zero.
Rule colors are green `34C759`, amber `FFCC00`, red `FF453A`, unknown `A0A0A0`.
Non-percentage readings retain the sprite's selected fixed color.

Color evaluation reuses the existing usage snapshots and refresh loop. It adds no
network requests, polling task or history. The render signature includes per-reading
colors, so a day/hour transition repaints even if the percentage is unchanged.

Verified in the signed installed app on 13 September: 125 unit tests passed, including
bucket boundaries, exhausted/invalid windows, legacy setting decoding and actual
multicolor image pixels. `--usage-validate <directory>` produced 8 passing checks over
the real saved sprites and live readings, plus the actual status-button images.
The menu-bar screenshot was also inspected: Claude 5h 12% green (hour 5), Claude weekly
49% red (day 2; allowance 28.5714%, amber ceiling 42.8571%), Codex weekly 12% green (day 1).
Evidence: `native/.build/validation/usage-pace-2026-09-13/`. The prior personal config
is preserved in `Application Support/MenuSprite/monitoring.before-usage-pace-20260913-003401.json`.

The later grouping adjustment is 0.5.4 (13); its before-config is
`Application Support/MenuSprite/monitoring.before-weekly-grouping-20260913-004000.json`.
All 125 tests still pass. The installed grouping validation passed 10/10 checks, including
the exact row order and the standalone "Claude" label. Actual menu-bar screenshot inspected
at `native/.build/validation/usage-grouping-2026-09-13/menu-bar.png`; the earlier screenshot
above records the previous arrangement. Existing pace colors and non-AI sprites were preserved.

Build 15 verification: 126 tests passed, including white digits/labels with a colored
percent suffix in inline and both image layouts, plus persistence of the new rule.
Installed validation passed 12/12 checks. The actual menu-bar screenshot shows all three
suffix colors together, white bold usage numbers and restored normal-weight other readouts:
`native/.build/validation/percent-colors-2026-09-13/menu-bar.png`. Backup:
`Application Support/MenuSprite/monitoring.before-percent-colors-20260913-010257.json`.

## Refresh, caching and cost

- Only enabled AI sprites, visible library rows, editor previews and open boards request
  these readings, through the same demand model as every other reading.
- AI usage runs in its own task, apart from the local sampler, so a slow response never
  delays CPU, memory or power readings.
- The live login is checked at most every 30 seconds (Claude Code's own keychain cache
  lifetime). The network is used at most once per **refresh interval** per login — 5
  minutes unless changed; shorter sprite intervals only re-render cached values and the
  reset countdowns.
- **Which account the live login is** (29 September): `UsageService` names the CLI's login by an
  identical saved copy first (token fingerprint, the switcher's rule) and by `~/.claude.json` only when
  no copy matches (Claude Code rotated its tokens) by Anthropic's `oauth/profile` answer, cached by
  token fingerprint in `VerifiedClaudeLogins` and shared with the board's Active marker. The state
  file is the last resort only: the Claude desktop app (prerak) writes its own account there while
  the CLI's keychain login is hemali's, so it once made both rows read hemali's usage.
- **Auto is the default refresh interval** (29 September; `UsageAutoPacer`, saved as
  `MenuSprite.AIUsageRefreshSeconds` = 0). The wait after each answer is decided from the answers:
  2 → 5 → 10 → 15 → 30 → 60 minutes, one rung up for every answer identical to the last; a jump of
  2+ points in any limit, a window reset or a different account goes back to 2 minutes; a 1-point
  drift holds. While the 5-hour session is ≥ 95% the waits start at 1 minute (five quiet answers,
  then 2, then 5) so auto-switching sees the limit in time; ≥ 90% starts at 2 minutes. If the session
  resets before the planned check, the check moves to 5 s after the reset. Never under 30 s. **⌘R
  (board, hub, refresh button) restarts the ladder at 2 minutes.** The menu-bar readings and the
  board share it, because the pacing lives in `UsageService`; the open board asks the service when
  the next check is due (`nextRefreshDate`). A 429 cooldown still overrides everything. Fixed
  choices (1–30 m) behave as before; an interval saved before this stays as chosen.
- **The refresh interval is chosen in the AI Accounts board** (15 September): 1, 2, 5, 10,
  15 or 30 minutes, saved as `MenuSprite.AIUsageRefreshSeconds`. The board and the
  menu-bar readings follow the same value, and a change applies to the snapshot already
  cached, not only to the next fetch. Below 5 minutes is Prerak's call against the Claude
  endpoint's rate limit; a 429 still becomes a cooldown with the last good values shown.
  Cooldowns and the 60-second connection retry keep their own fixed lengths.
- **While the board is open it reloads on its own** as soon as the first figure on it
  reaches the interval, and shows *Updated … ago* (the oldest figure on the board, never
  the time of the request) and a *Next in m:ss* countdown. The countdown redraws once a
  second only while the board is visible; closing it cancels the scheduled reload.
  **⌘R reloads the open board** (standalone panel and the hub's AI tab; also the hub's
  other tabs and the CPU/RAM/Power panels) — these borderless panels have no menu, so
  each panel answers the shortcut itself.
- A changed login — an account switch, or a CLI rotating its own token — is detected by
  the token fingerprint and fetched immediately, so readings follow a switch within about
  30 seconds without waiting for the 5-minute interval.
- **Refresh** (⌘R, window activation, and the Accounts board after a switch) bypasses the
  5-minute cache at most once a minute, because the Claude endpoint rate-limits repeated
  fetches.
- On HTTP 429 the Retry-After time (default 5 minutes) becomes a cooldown during which no
  request is sent and the last good values are served with a notice.
- Transport failures, server errors and malformed responses keep the last good values
  for the same account (never another account's). A request that never reached the
  server is retried after 60 seconds; other failures after 5 minutes.
- Sleep suspends the task; wake resumes it and reuses fresh cached values.

## Token rotation

**The login the Claude Code and Codex CLIs are signed in with is read-only.** MenuSprite reads
its access token and uses it as is. It never refreshes it and never writes it back — to the
keychain item or to `~/.codex/auth.json`. Changed 21 September 2026 after a failed write-back
left Claude Code signed out: a refresh token is single-use, so refreshing it and then failing
to store the new pair leaves the CLI holding a dead one; and an item MenuSprite creates in the
keychain is locked to MenuSprite's team, which makes every other tool that reads it (Claude
Code's `security` calls) show a keychain password prompt each time.

- The live Claude login is **read through `/usr/bin/security`**, not the Security framework. Claude
  Code writes that item with the `apple-tool:` partition, so a direct read from MenuSprite (team
  partition) is a mismatch and macOS shows a keychain password dialog on every read, even with
  `kSecUseAuthenticationUIFail` set (seen 21 Sep 2026, macOS 27). The tool's read matches and is
  silent; it is the same call Claude Code makes.
- A live token that is already expired is reported as `awaitingCLIRenewal` with no network
  request: "Login token expired. The CLI renews it the next time it runs." The board keeps its
  last figures with that notice and reads the login again on every refresh, so it picks up the
  CLI's renewed token as soon as one exists.
- A live token the provider rejects with 401/403 gets the same answer after that one usage
  request; the refresh token is never spent.
- A live token within 5 minutes of expiry but still valid is simply used.

Only a **saved copy of an account the CLI is not using** is rotated, and only into its own saved
copy, as OpenUsage does — an access token within 5 minutes of expiry, or rejected with 401/403,
is refreshed once:

- Claude: `POST https://platform.claude.com/v1/oauth/token` (JSON, Claude Code's client ID
  and scopes). `invalid_grant` → "Session expired"; other 400/401 → request failed.
- Codex: the auth file is re-read first and a newer pair adopted; then
  `POST https://auth.openai.com/oauth/token` (form, Codex's client ID).
  `refresh_token_expired/reused/invalidated` → "Session expired".

A saved copy's rejected refresh is only reported as an expired session when the saved item still
holds the pair MenuSprite read; if something else rotated it first, MenuSprite reloads that copy.

The rotated pair is written back only inside the shared credential gate, and only if the
saved item still holds the exact pair that was refreshed. If a switch changed it meanwhile,
the write is dropped and the new copy is read instead. Saved-copy writes use `security -i`
over stdin for short commands and the Security framework for larger payloads; tokens never
enter process arguments. Provider HTTP redirects are
refused, including redirects carrying refresh bodies. Saved copies keep
their existing account attribute. Every key MenuSprite does not model (such as `mcpOAuth`) is
preserved.

`savedUsage` for the account the CLI is currently using always reads the **live** login:
the saved copy of the active account can hold a refresh token the CLI already rotated,
and spending it could revoke the live session.

## What was verified

- `swift test --package-path native --filter AIAccountsTests`: mapping fixtures shaped like
  live responses, header/URL/body contracts, a live login that is expired or rejected never
  producing a token request or a keychain/`auth.json` write (both providers), the board keeping
  its last figures until the CLI renews, saved-copy refresh with compare-and-swap write-back,
  `refresh_token_reused` on a saved Codex copy, 429 cooldown with last-good values,
  unknown-key preservation, Codex window classification including a sole weekly window in the
  primary slot, connection failure retry cadence and request coalescing. All network and
  keychain access in these tests is faked and sandboxed.
- A gated live check (`MENUSPRITE_LIVE_USAGE=1 … --filter liveReadOnlyUsage`) reads the
  real logins through a keychain that refuses writes and a transport that refuses POSTs,
  performs one GET per provider and prints the values beside OpenUsage's local API
  (`http://127.0.0.1:6736/v1/limits`).

A read-only comparison with OpenUsage was performed locally on 11 September.
Neither token needed refreshing. Window classification and reset times agreed;
fetch-time differences explained changing utilization. Account identities, plan
information and personal usage readings remain in private validation records.

## Limits

- Only the default homes are read (`~/.claude.json` + `Claude Code-credentials`,
  `~/.codex/auth.json`). `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, Claude Desktop logins and
  Codex keyring-mode logins are not read.
- Running Codex sessions keep the account they started with after a switch (Codex skips
  reloading auth for a different account ID); the Codex readings show the new login.
- Reset credits are read, never claimed. The dedicated endpoint is requested **only when the usage
  body already reports a credit**, because all it adds is the expiry list; a failure there never fails
  a refresh, and the count still comes through.
- The currency code is not modelled: `spend` is converted with its reported exponent and labelled in
  dollars. A non-USD allowance would read as dollars. This account reports USD.
- `limits[]` entries of kind `session` / `weekly_all` are ignored — they repeat `five_hour` and
  `seven_day` — and `spend`'s `severity`, `cap`, `balance` and `auto_reload` are not surfaced.
- Provider fixture tests do not prove installed behavior; the 13 September pace-color
  validation above exercised the actual installed menu-bar items with live readings.
