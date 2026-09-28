# AI account switching

Local, 11 September 2026. MenuSprite switches Claude Code and Codex CLI accounts the way
Claude Switcher (`Symbioose/claude-account-switcher` 0.4.3, installed as the `claude-switcher`
cask) does, on the switcher's own storage. Saved accounts work in both apps without signing in
again, and Claude Switcher can be quit whenever. Usage numbers come from `UsageService`
(`docs/ai-usage.md`); this document covers accounts only.

## Where it is

- Click any sprite whose readings are all AI usage readings (`ai.*`), or choose
  **AI Accounts…** from the MenuSprite status menu or app menu.
- The board has a Claude and a Codex section. Each saved account shows its plan, an Active
  marker, Session and Weekly bars with reset countdowns, and any usage error. Buttons:
  **Switch**, **Remove…** (with inline confirmation; disabled for the signed-in account),
  **Save current login** (prominent when the signed-in login is not saved), **Add account…**
  and an **Auto-switch** toggle. Refresh forces a usage fetch.
- Usage loads only while the board is open. Closing it releases the panel, view and usage.

## Storage shared with Claude Switcher

| What | Where |
| --- | --- |
| Live Claude login | Keychain `Claude Code-credentials`, account `$USER` (as Claude Code reads it) |
| Claude profile | `oauthAccount` in `~/.claude.json` |
| Live Codex login | `~/.codex/auth.json` (file storage mode only) |
| Saved copies | Keychain `claude-switcher:<email>` and `codex-switcher:<email>` |
| Account list, auto-switch flags and threshold | `~/.config/claude-switcher/accounts.json` version 2 (directory 0700, file 0600) |

`accounts.json` keeps the switcher's field names (`email`, `subscription_type`, `org_name`,
`active`, `keychain_account`, `oauth_account`, `provider`). Unknown top-level keys, settings,
account fields and entries for providers MenuSprite does not model are preserved on save. A
damaged file is reported and never overwritten.

## What a switch does

Every mutation runs inside `CredentialGate.shared`, so a token write-back from usage
collection can never land in an item a switch just replaced.

**Claude.** Nothing is touched until the target's list entry and a parseable saved copy exist.
The signed-in login is identified by an identical saved copy (exact tokens). Otherwise MenuSprite
asks Anthropic's OAuth profile endpoint (`GET api.anthropic.com/api/oauth/profile`, `account.email`)
whose login it is, because `~/.claude.json` can still name a previous account after Claude Code
rotates its tokens. A rejected access token is never refreshed from here (the CLI owns the live
login); it is left unconfirmed until Claude Code renews it, and a login Anthropic reports as
expired is not saved and the switch proceeds; no answer at all (offline, server error) changes
nothing. The login is saved under the confirmed account — with
`mcpOAuth` and every other key intact. An unsaved signed-in login is added to the list first. The target copy is then
written through `security -i` over stdin for commands up to 4032 bytes, and through the
Security framework for larger payloads, then read back. Tokens never enter process arguments.
Existing keychain access lists are preserved; new large items trust the app and `/usr/bin/security`. Only the bytes of the `oauthAccount`
value in `~/.claude.json` are replaced, re-read immediately before, indented like the file,
validated, and written atomically with the file's mode. If that step throws, the previous live
login is restored and the error reported. A missing or unparsable state file, or an account
without a saved profile, leaves the file unchanged with a note. Active flags change for Claude only.

**Codex.** Refused in keyring mode (`cli_auth_credentials_store = "keyring"`). The target's saved
token is first passed through `UsageService.savedUsage(force: true)`, which rotates and persists it
if it is near expiry; an expired session refuses the switch. That call runs outside the gate
because the service writes under the same non-reentrant gate. The signed-in `auth.json` is saved
under its id-token email, then the target copy is written to `~/.codex/auth.json` pretty-printed,
atomically, mode 0600.

**Already signed in.** Switching to the live account refreshes its saved copy from the live
login (which may hold newer rotated tokens) instead of overwriting the live login.

**Save current login** stores the live login and its profile (Claude) or plan (Codex) and marks
it active. **Remove** deletes the saved keychain copy and list entry; the signed-in account is
refused. **Add account…** saves the current login, opens Terminal running `claude auth login`
or `codex login -c 'cli_auth_credentials_store="file"'`, polls the live store every 2 s for up to
5 minutes (cancellable) and saves the new login once a different token appears. Nothing is logged
out or deleted first; for Claude, a same-email change waits 10 s for the profile to follow.

## Running sessions after a switch

- **Claude Code** caches its keychain read for 30 seconds (`ltn=30000` beside the credential
  cache in 2.1.268), so running sessions pick up the switched account within about 30 seconds.
- **Codex CLI** 0.154.0 reloads `auth.json` only for the same account id; its auth manager logs
  "Skipping auth reload due to account id mismatch". Running Codex sessions keep the previous
  account; new sessions use the switched one. Both findings come from the binaries' strings,
  not a live test.

## Auto-switch

Same rules as the switcher: when a provider's flag is on and the active account's session or
weekly window reaches `auto_switch_threshold` (100%), switch to the first other saved account
whose usage is known and below it, else one whose usage is unknown. Model-scoped limits (Sonnet,
Fable, Spark) never trigger it. Checks run every 300 s with a 60 s cooldown, read cached usage, and
fetch other accounts only after the active one is exhausted. The flag is the shared one in
`accounts.json`. **While Claude Switcher is running MenuSprite never auto-switches**, so the two
apps cannot both switch; the board says so. Outcomes appear in the board, without notifications.
Validation and measurement launches do not start the check.

Auto-switch cannot tell a lapsed subscription from an account whose usage simply failed to load:
both count as "unknown", and an unknown account is still a valid target (the switcher's rule). With
Claude auto-switch on and only an inactive second account saved — the state on 11 September — reaching
100% would move Claude Code onto the inactive account, whichever app performs the switch.

## Differences from Claude Switcher

- The replaced login is saved under the account it actually belongs to, not whichever entry is
  flagged active, so a stale flag cannot overwrite another account's saved copy.
- For Claude that account is confirmed with Anthropic (the profile endpoint), not read from
  `~/.claude.json`, which can lag behind a token rotation. **Save current login** uses the same check.
- Tokens are written over stdin like Claude Code, not on the `security` command line, and each
  write is read back (a `security -i` line over 4032 bytes is truncated silently).
- `~/.claude.json` is not re-serialized; only the `oauthAccount` value changes.
- An unreadable live login (for example an API-key `auth.json`) is refused rather than overwritten.
- A failed profile step restores the live login.

## Validation

```sh
swift test --package-path native --filter AIAccountsTests
# Read-only decode of the real accounts.json; prints counts only.
MENUSPRITE_LIVE_SWITCHER_READ=1 swift test --package-path native --filter switcherConfigDecodesRealFile
```

Switching tests use `AIAccountPaths.sandbox` and `InMemoryKeychain`; no real login is read or
written. `SwitchIdentityTests` cover a stale state file naming the switch target, an unreachable
profile endpoint (nothing changes) and an expired live login (not saved, switch proceeds). **No live switch has been accepted as validated.** The gated round-trip test must only
be run with the account owner's explicit consent and two working saved accounts.

Live switch checklist (use your own two test accounts):

1. Quit Claude Switcher or leave its auto-switch alone; note `claude auth status --json`.
2. Switch from the board. Check: `claude-switcher:<previous>` now matches the previous live
   tokens (fingerprint, not printed); `Claude Code-credentials` (account `$USER`) matches the
   target copy; `claude auth status --json` names the target; `~/.claude.json` differs from a
   pre-switch copy only inside `oauthAccount`; `accounts.json` active flags flipped for Claude only.
3. Within ~30 s a running Claude Code session answers as the target account (`/status`).
4. Claude Switcher, relaunched, shows the same active account and can switch back.
5. Switch back from MenuSprite and confirm the original login still works without signing in.

## Limits

- Default homes only: `CLAUDE_CONFIG_DIR` and `CODEX_HOME` overrides are not followed, matching the switcher.
- Codex keyring storage is unsupported.
- Claude Code rewrites `~/.claude.json` often; the read-to-rename window is small but not locked.
