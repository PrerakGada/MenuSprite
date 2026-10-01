# Sprites made by agents

1 October 2026 · Prerak: let users *type* what they want and have Claude Code, Codex, Antigravity, Cursor or
any other agent build it — above all **the board a sprite opens**, fed by the user's own CLI tools. MenuSprite
supplies the structure (permissions, resource limits, readings, rendering); the user gets full freedom over
the design. "That is the most uniqueness about MenuSprite that can take it viral."

## The shape

```
 agent ──(shell)──► menusprite <verb> ─┐
 agent ──(MCP)────► menusprite mcp ────┤   one request per connection, newline-terminated JSON
                                        ▼
            ~/Library/Application Support/MenuSprite/agent.sock  (0600, peer uid checked)
                                        ▼
                    MenuSprite.app  ── AgentService ── MonitoringStore (the only writer of monitoring.json)
                                                   └─ SpriteSpec (compile / emit / validate)
                                                   └─ AgentRender (PNG of the face and the board, live values)
```

- **The app is the only writer.** `MonitoringStore` rewrites `monitoring.json` whole on every change, so an
  outside edit would be overwritten. Every change goes through the running app, which applies it exactly as the
  studio does (`store.save`). The CLI starts the app (`open -g -b in.prerakgada.MenuSprite`) when it is not
  running and waits for the socket.
- **Authoring format ≠ storage format.** The stored JSON is Swift-synthesised (`{"literal":{"_0":"Claude"}}`,
  random ids, a full style object per node, legacy fields), which agents write badly. Agents read and write the
  **sprite spec** below; the `SpriteSpec` module compiles it into `SpriteConfiguration` and emits a spec back
  from any saved sprite, including the studio's. The stored format is unchanged, so older builds still read it.
- **Previews are real.** `render` draws the face and the board, on a dark and/or light bar, through the same views
  the menu bar uses, after sampling the readings and running the commands once (`MENUSPRITE_TRIGGER=preview`), and
  returns PNG paths plus a text report of every value and every script-drawn block. `apply_sprite` and
  `apply --preview` draw both appearances unless asked otherwise. The MCP server returns the pictures as images, so
  an agent sees what it built and iterates. Stand-in `values` draw states the Mac is not in (see Previews below).
- **Examples ship inside the command.** `examples/sprites/*.json` are compiled into `AgentProtocol` as
  `AgentExamples` by `scripts/embed-agent-examples.py` (summaries from `examples/sprites/README.md`), so an agent with
  only the MCP server can read them (`list_examples`, `get_example`, `menusprite://examples/<name>`).
  `ExampleSpecsTests` fails when the generated file and the folder disagree, or an example compiles with any
  diagnostic.
- **Nothing new runs at rest.** The socket listener is idle until a connection arrives. Command values that only
  the board shows run only while the board is open (unless marked `background`).

Modules: `AgentProtocol` (Foundation only: transport, op types, `JSONValue`, the guide and schema text),
`SpriteSpec` (spec ↔ `SpriteConfiguration`, validation; depends on `SystemMonitoring`, `AgentProtocol`),
`MenuSpriteCLI` (the `menusprite` binary: CLI and MCP server; depends on `AgentProtocol` only), and in the app
`AgentServer.swift`, `AgentService.swift`, `AgentRender.swift`.

## The sprite spec, version 1

A sprite is one JSON object. Everything except `menusprite` and `name` is optional.

```jsonc
{
  "menusprite": 1,                 // format version; required
  "id": "…UUID…",                  // present on sprites read back; apply matches by it, else by name
  "name": "GitHub PRs",            // ≤ 40 characters (a longer one is cut, with a warning); apply matches by name, any case
  "icon": "arrow.triangle.pull",   // SF Symbol: the sprite's identity in lists and the board header
  "enabled": true,                 // values run and the item can show (default true)
  "menuBar": true,                 // shown in the menu bar (default true)
  "side": "right",                 // "left" puts it on the left strip (default "right")
  "every": 2,                      // seconds between reading samples: 1, 2, 5, 10, 30 or 60 (default 2)
  "values": [ … ],                 // named values: readings, commands, fixed text
  "face": { … },                   // what the menu bar draws (default: the icon alone)
  "rules": [ … ],                  // if / otherwise restyling of face pieces and board blocks
  "board": { … },                  // what a click opens; omitted or null = the classic panel
  "files": { "prs.py": "…" }       // scripts and data written to the sprite's own folder
}
```

A JSON `null` anywhere counts as leaving the key out (`"board": null` on apply brings back the classic panel;
`"files": null` keeps the files). Limits: at most 100 values, and 500 face nodes and board blocks together.

### Values

```jsonc
{ "id": "cpu", "reading": "cpu.usage", "name": "CPU", "decimals": 0, "unit": true }
{ "id": "reset", "reading": "ai.claude.sessionReset", "clock": true }
{ "id": "prs", "command": "gh pr list --json number --jq length", "every": "5m", "timeout": 20,
  "parse": "number", "suffix": " open", "background": false }
{ "id": "repo", "command": "gh repo view --json name,stargazerCount", "parse": "json", "path": "stargazerCount" }
{ "id": "hello", "text": "Hi" }
```

- `id`: letters (any script), digits and `_` (a digit may lead: the studio makes ids such as `5h` and `7d`),
  ≤ 32 characters, unique in the sprite. Texts use it as `{id}`. `name` defaults to the reading's name or the id.
- Reading options: `decimals` (0–2), `unit` (show the unit, default true), `fahrenheit`, `bits`, `clock`.
  `"clock": true` writes a reading in seconds (a limit's reset, `battery.remaining`) as the clock time it ends, in
  the Mac's locale and 12/24-hour setting: `16:30` today, `Sat 4:30 PM` within six days, `8 Oct 4:30 PM` later, with
  the year when it differs. Rules still compare the seconds. It warns on readings in other units and on command or
  text values.
- Command options: `every` (seconds as a number, or `"30s"`, `"5m"`, `"1h"`, `"1d"`, `"2 days"`; 2 s – 1 day,
  default 60 s; read back as `"5m"`, `"1h"` or `"1d"` where exact, and always written), `timeout` (1–60 s, default 10), `parse` (`text` = first line ·
  `number` = first number · `json` + `path` = a dotted path such as `data.items.0.name`; default `text`), `suffix`,
  `decimals`, `background`. A text value keeps 500 characters (the first line, or a whole JSON string).
- Commands run in `/bin/zsh -f -c` with Homebrew, `~/.local/bin`, `~/bin`, `~/.cargo/bin`, `~/.bun/bin` and
  `~/go/bin` on `PATH`, in the sprite's folder (if it has `files`) with `SPRITE_DIR` set, else in the home
  folder, and with `MENUSPRITE_TRIGGER` saying why (below). A command is at most 16384 characters
  (`CommandSource.maximumCommandLength`); the compiler refuses a longer one. A value's command is stopped once its
  output passes 64 KiB. A command value runs while its sprite is enabled **if the face or a rule uses it**; one
  used only by the board runs only while the board is open, unless `"background": true` (needed for a chart's
  history).

**Shared runs.** Values, script rows and script blocks whose commands have the same text, `every`, timeout and
folder are one run: one process per tick, whose output each reads its own way (the JSON parsed once), while
results and chart history stay per value. Several fields of one API call are therefore several values with the
identical command and different `path`s, and a face value can read a number out of the board's own `blocks`
script (`"path": "0.value"`; examples `git-repo-status`, `homebrew-outdated`). A value that joins a command already
running (a board opening beside the face) shows its last output at once. A command never runs twice at once: a
scheduled run joins the one going; an asked-for run (Refresh, the re-run after an action, a switch re-reading its
value, Run now, `menusprite refresh`) waits for a run already started and then runs once more, shared by every
request made meanwhile.

**Triggers.** `MENUSPRITE_TRIGGER` is `open` (the first run of a schedule: a board opened, a sprite started or was
enabled, its command changed, an apply wrote its files, the app launched, the Mac woke), `tick` (every `every`),
`refresh` (asked for, as above), `action` (a button's, switch's or script row's own command) or `preview`
(`menusprite run`/`test_command`, a render). A script with its own cache skips it on `refresh`.

**Failures** back off: after n failures in a row the next run waits `every × 2ⁿ` (n up to 8), at most 10 minutes,
never less than `every`. A shared run fails when the command fails or none of the values sharing it can read
its output. A failed value's problem ends with the last three meaningful stderr lines.

### Face (the menu-bar item)

A tree of nodes. Each node is an object with exactly one kind key; a bare string is a text node and an array
is a row.

| Node | Meaning |
|---|---|
| `{"row": [ … ]}` / `{"column": [ … ]}` | side by side / stacked (the bar holds two lines) |
| `{"text": "CPU {cpu}"}` | fixed text mixed with `{value}` references (a reading carries its unit: `{cpu}` is `23%`) |
| `{"icon": "flame"}` | an SF Symbol |
| `{"bar": "cpu"}` | a vertical level bar as tall as the menu bar, filled by a value (of `max`, default 100); in a column it warns |
| `{"battery": "charge"}` | the battery glyph drawn from a value |

Properties: `id` (for rules), `name`, `color`, `size` (points), `weight` (`regular`, `medium`, `semibold`,
`bold`, `heavy`), `tabular` (fixed-width digits, default true), `opacity` (0–1), `align` (`leading`, `center`,
`trailing`), `gap`, `justify` (`start`, `center`, `end`, `spaceBetween`, `even`), `padding` (the root defaults
to 3), `hidden`, `shrink` (text gives up size before widening), `chargeInside`, `max`.

Colours: `"inherit"` (the parent's; the default), `"auto"` (follows the menu bar), `"#RRGGBB"` (fixed), or a name:
`red orange yellow green mint teal cyan blue indigo purple pink brown gray white black` (`grey` = gray), stored as
the name and drawn as Apple's adaptive system colour, a different shade on light and dark (`SpriteColors`). Read
back, names stay names and hex stays `"#RRGGBB"`. A row's or column's `opacity` dims everything inside it,
multiplying with the children's own.

### Rules

```jsonc
{ "name": "Busy", "when": "prs > 5", "then": [ { "target": "count", "color": "orange" } ],
  "else": [ { "target": "count", "color": "inherit" } ] }

{ "name": "Pace", "cases": [
    { "when": "claude.pace == 'over'", "then": [ { "target": "pct", "color": "red" } ] },
    { "when": "claude.pace == 'ahead'", "then": [ { "target": "pct", "color": "yellow" } ] } ],
  "else": [ { "target": "pct", "color": "green" } ] }
```

- `when`: `value[.pace] op operand`, joined by ` and ` or by ` or ` (not both). Operators: `>` `>=` `<` `<=`
  `==` `!=` `contains` `is missing` `is present`. The operand is a number, a quoted string (`'…'` or `"…"`) or a
  bare word. `.pace` reads a Claude/Codex limit's pace: `on track`, `ahead`, `over`; a numeric comparison on it,
  or a non-numeric operand on a numeric comparison, is an error (kept with a warning when the replaced sprite
  already has that exact condition). `1,000` warns that a comma is a decimal point here.
- `is missing` holds while a value has neither a number nor text: a reading with no value, or a command that
  failed, printed nothing or has not finished its first run. Every comparison except `!=` fails then. The guide
  teaches three looks: hide a count at zero, swap or dim the icon while it is missing.
- An action names a `target` (a face node's or board block's `id`) and one or more effects: `color`,
  `hide: true`, `show: true`, `icon`, `text` (a template), `opacity`.
- Rules run top to bottom; a later rule wins. `enabled: false` keeps a rule without running it.
- Also read: `&&` and `||` for `and` and `or`; `is unavailable` / `is available`; a single action object where a
  list is expected; `"match": "all"|"any"` on a rule or case (only needed for one condition stored as "any").
- A rule may carry an `id`; its branches, conditions and actions have none in the spec and keep the ids of the
  replaced sprite's rule with the same id, position by position (else `<ruleId>-c<k>`, `-w<j>`, `-a<m>`, `-e<m>`).
  A spec read back writes an `id` on every face node and board block a rule targets, so inserting a piece before
  it does not retarget the rule.

### Board (what a click opens)

```jsonc
"board": { "width": 360, "header": true, "blocks": [ … ] }
```

`width` 260–560 (default 360). `header` shows the icon, name and Configure… (default true). The board object
also takes its own top stack's properties (`id`, `name`, `spacing` (default 10), `padding`, `color`,
`background`, `align`, `hidden`, `opacity`, …). Each block is an object with exactly one kind key; a bare string
is a text block:

| Block | Meaning |
|---|---|
| `{"stack": [ … ]}` · `{"row": [ … ]}` · `{"card": [ … ], "title": "Open PRs"}` | layout (a row's blocks share its width equally, except those with `fit`) |
| `{"divider": true}` · `{"space": 12}` | a line · empty height |
| `{"text": "…{value}…", "font": "title", "icon": "bolt"}` | text; `font`: `huge` `title` `headline` `body` `caption` `mono`; `icon` draws an SF Symbol before it (a rule's `icon` replaces it) |
| `{"value": "cpu", "caption": "Now", "font": "huge"}` | one big value |
| `{"chart": "cpu", "caption": "…", "height": 40}` | a value's history (readings, or numeric command values) under a header of caption (or name) and current figure; 0–100 for a percentage, else 0 to its highest point (`max` warns) |
| `{"gauge": "cpu", "max": 100, "caption": "…", "detail": "{used} of {limit}"}` | a horizontal level bar |
| `{"stats": ["cpu", "uptime"]}` | name · value rows |
| `{"button": "Open", "icon": "safari", "open": "https://…"}` | one action: `run` (command), `open` (link), `app` (name, bundle id or path), `copy` (text template), `refresh: true`; `timeout` for `run` |
| `{"toggle": "Tailscale", "value": "ts", "on": "tailscale up", "off": "tailscale down"}` | a switch showing a value, running `on`/`off` (one `timeout` for both); drawn as a capsule filled with its `color` (else accent) when on |
| `{"output": "logs", "height": 120}` | a command value's raw output |
| `{"script": "cmd", "every": 30}` | SwiftBar rows: each output line is a row, `Text \| color=red sfimage=bolt href=… bash="…" size=13 font=Menlo weight=bold length=40 tooltip="…"`, `---` divides, leading `--` indents |
| `{"blocks": "python3 prs.py", "every": 60}` | the command prints blocks (this same vocabulary) as JSON, drawn in place |
| `{"image": "chart.png", "height": 120}` | a file (absolute, `~/…`, or in the sprite's folder) or an `https://` image |
| `{"processes": "cpu", "limit": 8}` · `{"energy": true}` · `{"accounts": true}` · `{"readings": true}` | MenuSprite's own panels: processes (`cpu`, `memory`, `power`), Battery & Power, AI accounts, readings with graphs |

Properties: `id`, `name`, `color`, `background` (`#RRGGBB` or a colour name: a rounded fill behind the block; text
on it without its own colour turns black or white), `align`, `spacing`, `padding`, `hidden`, `opacity`, `height`,
`max`, `limit`, `fit`. `color` fills a gauge's bar, a chart's line and a switch's on track (accent when unset) and
colours text elsewhere. Text, value and button blocks take `lines` (0 = unlimited, at most 100; the full text shows
on hover) and `truncate` (`tail`, `middle`, `head`; warns without `lines`). `"fit": true` gives a block inside a row
its natural width, the others sharing the rest (warns outside a row). A `script` or `blocks` block also takes
`timeout` (1–60 s). Toggles are on when their value is a non-zero number or one of `true on yes enabled active up
connected running`. A board taller than the screen (its visible height less 80 pt) scrolls.

**Clickable blocks.** A `text`, `value`, `stack`, `row`, `card`, `image` or `stats` block takes exactly one of
`run`, `open`, `app`, `copy` or `refresh: true` (two is an error; on other kinds they warn and are ignored), and is
then clickable anywhere on it: a hover fill, the pointing-hand cursor, a small ↗ for `open`. Printed blocks take
them too. Script rows, command output and the four panels never take a block-level click.

**Actions** (a button's or clickable block's `run`, a switch's `on`/`off`, a script row's `bash=`) run in the
sprite's folder with `SPRITE_DIR` and `MENUSPRITE_TRIGGER=action`, and stop after their `timeout` (1–600 s,
default 30; it warns where nothing runs). They are never stopped for output: past 64 KiB it is dropped and the
exit status decides. A `run` shows a spinner, then its output for about 3 s (a failure stays 10 s, in orange,
with the problem and the last three stderr lines). When any `run` finishes, every command the sprite draws from
runs again (`refresh`), so the face and board show what it changed; a switch holds its new position until then.
A process the action starts in the background (`nohup job >/dev/null 2>&1 &`) outlives it: only the action's own
zsh is stopped at its timeout. A long job should end with `menusprite refresh <sprite>`.

**Script-drawn blocks** (`blocks`): the command prints a JSON array of blocks, or `{"blocks": [ … ]}`, using
every kind above except `blocks`, `script` and the four premade panels (a block of those is reported and left
out; the rest still draw). Its text may use the sprite's `{values}`; an unknown `{word}` is drawn as written,
with a warning. Where the spec takes a value id, a script may print literal data instead, which becomes a fixed
value: `{"gauge": 45}`, `{"value": "12 GB"}` (or a number or true/false), `{"chart": [3, 5, 2]}`,
`{"stats": [{"name": "Open", "value": 12}]}`, a toggle's `"value": true`. Printed ids are ignored: blocks are
identified by position (`s.2.0`), so rules cannot target them. At most 200 blocks are read. A relative image path
is resolved against the sprite's folder. It runs when the board opens and every `every` seconds while it is
open; a parse error or warning is shown in place, with its path, and a failed run shows its problem and the last
three stderr lines. `{word}` in a printed text names a sprite value; a script escapes braces it did not mean in
each text string (`"{\u200b"`), never in the JSON it prints.
This is how any CLI draws its own dashboard: a tool can print MenuSprite blocks directly, or a few lines of
Python in `files` can turn its JSON into blocks.

### Files

`"files": {"prs.py": "#!/usr/bin/env python3\n…"}` writes each file into
`~/Library/Application Support/MenuSprite/Sprites/<sprite id>/`. Names are `[A-Za-z0-9._-]`, ≤ 64 characters, not
starting with a dot (no folders), at most 20 files of 256 KiB each, no two differing only by case; content
starting with `#!` is made executable. Every command of a sprite that has files runs in that folder with
`SPRITE_DIR` set, so `python3 prs.py` and `"$SPRITE_DIR/prs.py"` both work. Omitting `files` (or `null`) on apply
keeps the existing files; `"files": {}` removes the folder.

The folder keeps a manifest dotfile, `.menusprite-files.json`, of the files the last spec wrote (`SpriteFolders`).
Those are the spec's files: `get` carries them (reading at most 20 of at most 256 KiB), and an apply with `files`
replaces them and removes only spec files that left the spec. Anything else in the folder, which the sprite's
scripts wrote (a cache, a log, an image), is never carried and never removed by such an apply, nor is a spec file
a script has since made larger than 256 KiB or binary; `get` explains each in `notes`. A case-only rename
renames the file. A folder from before manifests counts its valid-named text files as spec files once. A spec
read back carries its files, so a spec is the whole sprite: it can be copied to another Mac or shared. When an
apply writes files, the sprite's running commands run again at once (`open`).

### Reading back

`emit` leaves defaults out (the studio's own defaults for a new piece: column gap 1.5, root padding 3, chart
height 44, output 90, image 120, space 12, process list 8 rows), except `every` on command values and on script
and blocks blocks, which it always writes so there is a key to edit, and uses shorthand only where it reads back
exactly. Ids appear only where they differ from the position-derived ones (`f-1-0`, `b-2`, `r0`) or where a rule
targets the piece. Validate and apply compile against the sprite being replaced, so `get` then `apply` of an
unchanged spec gives back the same sprite down to every id. A text may also be written as a list,
`["CPU ", {"value": "cpu"}]`, which emit uses only when the string form would not read back. Also accepted:
`"space": true` (12 pt) and a top-level `every` written as `"5s"`.

## Command line

```
menusprite guide                                  the authoring guide (Markdown) — start here
menusprite schema                                 JSON Schema of the spec
menusprite examples [name] [--json]               the built-in example sprites, or one example's spec
menusprite readings [search] [--sample]           reading ids, names, units and current values (or why none)
menusprite list                                   sprites, with id, side, board kind, values
menusprite get <sprite>                           a sprite as a spec (with its files; notes on stderr)
menusprite validate <file|->                      check a spec without saving it
menusprite apply <file|-> [--dry-run] [--preview <dir> [--dark|--light|--both] [--value id=v]…]   create or replace a sprite
menusprite preview <sprite|file|-> [--out <dir>] [--dark|--light|--both] [--no-board] [--no-face] [--value id=v]…   PNGs with live values
menusprite run '<command>' [--parse number|text|json] [--path p] [--timeout s] [--sprite <name> | --files <spec|->]   test a command as a value
menusprite refresh <sprite>                       run the sprite's commands again now; prints its values
menusprite remove <sprite>
menusprite enable|disable|show|hide <sprite> · menusprite side <sprite> left|right
menusprite open <sprite>                          pop its board open on screen
menusprite mcp                                    MCP server on stdio
menusprite setup <claude|codex|cursor|claude-desktop|antigravity> [--print]   register the MCP server
```

`<sprite>` is a name (case-insensitive), an id or an id prefix of at least 4 characters. Every verb takes
`--json` for machine output. The binary lives at `MenuSprite.app/Contents/Helpers/menusprite`; the local install
links it from `~/.local/bin/menusprite`.

Previews are written as `<name-slug>-face-<dark|light>.png` and `<name-slug>-board-<dark|light>.png`. `apply
--preview` draws both appearances unless `--dark` or `--light` says otherwise (those and `--value` without
`--preview` are a usage error); `preview` draws the Mac's current one unless told. `readings --sample` samples
local readings and shows each one's value or why it has none; AI limits are reported as last fetched (they come
from the Claude Code and Codex CLI logins). `run --files <spec>` runs the command in a temporary folder holding
that draft's `files` (`SPRITE_DIR` set, `#!` files executable, removed afterwards; its path is shown as
`$SPRITE_DIR`). `refresh` runs every command the sprite draws from (values, board-only values even with the board
closed, script rows, script blocks) side by side with `MENUSPRITE_TRIGGER=refresh`, refetches AI limits (at most
once a minute) when it reads them, and returns when all have finished: for a script that finished a long job.

### Previews

A render reports, besides the pictures: each value's state (and, for AI readings, why it has none); each `script`
or `blocks` block as a `BlockReport` (its spec path such as `board.blocks[4].card[0]`, command, problem, the last
six meaningful stderr lines with the run folder written as `$SPRITE_DIR`, and what it drew: rows with their
`href`/`bash`, or for printed blocks what each clickable block, button and switch does); and notes. Headlines say
"valid, but N board blocks failed to draw" when any did. Every render runs the sprite's commands fresh with
`MENUSPRITE_TRIGGER=preview` (a run an apply started in the last 30 s is waited for instead), so apply plus
preview runs each command once.

Stand-in values (`values` on render/preview/apply, `--value id=value`) draw a value as if the reading or command
had given it, formatted exactly like a live one (a reading's number in its own unit; a command's number with its
`decimals`, `suffix` and `clock`; text as written, with a command's `suffix`). Rules compare the stand-in's number,
or its text read as a number; `true`/`false` are the text `true`/`false` and the number 1/0. `id.pace` (`on track`,
`ahead`, `over`) sets only a Claude/Codex limit's pace. A value with a stand-in is not run for the picture. An
unknown id is noted and ignored; `null` draws the value as missing (a failed command, a signed-out or unread reading,
so the `is missing` branch shows); lists and objects are refused.

**Commands see the same environment however MenuSprite was started**: `HOME`, `USER`, `LOGNAME`, `SHELL`,
`TMPDIR`, the locale and `SSH_AUTH_SOCK` pass through, `PATH` is the preferred bins before
`/usr/bin:/bin:/usr/sbin:/sbin`, and nothing else from the launching process does. A preview made from a
terminal therefore succeeds or fails exactly as the menu bar will (a token exported in `~/.zshrc` is not
there in either).

**Sandbox for testing**: `MenuSprite --agent-sandbox <dir> [--socket <path>]` runs the agent server alone on
`<dir>/monitoring.json`, with sprite folders under `<dir>/Sprites`, no menu-bar items and AI limits offline.
Point the CLI at it with `MENUSPRITE_SOCKET=<path>` (which also stops the CLI starting the real app). A Unix
socket path holds at most 103 bytes, so use a short `--socket` path.

## MCP server

`menusprite mcp` speaks MCP over stdio (protocol 2025-06-18, negotiating down to 2024-11-05). Tools, in order:
`get_guide`, `list_examples`, `get_example`, `list_readings` (`sample`), `list_sprites`, `get_sprite`,
`validate_sprite`, `apply_sprite` (`dry_run`, `preview`, `appearance` default both, `values`; returns diagnostics,
the block reports and preview images), `preview_sprite` (a saved sprite or a draft spec; `appearance` dark, light,
both or system; `board`; `values`), `test_command` (`sprite` or a draft's `files`), `refresh_sprite`, `set_sprite`
(enabled, in menu bar, side), `remove_sprite` (its folder goes to the Trash; Undo in the Sprites window restores
it), `open_board`. Tools that run the user's commands are marked `openWorldHint` and not read-only. Resources:
`menusprite://guide`, `menusprite://schema` and `menusprite://examples/<name>`. Answers are written one whole
message at a time, so parallel calls never interleave. The server's `instructions` tell the agent to read the
guide first, start from an example, test draft scripts, look at both appearances and use stand-ins. Clients: Claude Code (`claude mcp add menusprite -- menusprite mcp`), Claude
Desktop, Codex (`[mcp_servers.menusprite]`), Cursor, Antigravity. ChatGPT's desktop app only accepts remote
connectors, so there it is the CLI or nothing.

## Socket protocol (AgentProtocol)

One request per connection: a compact JSON object and `\n`; one response the same way. Requests are
`{"v":1,"op":"…","args":{…}}`; responses `{"ok":true,"result":…}` or
`{"ok":false,"error":{"code":"…","message":"…","diagnostics":[…]}}`. Ops: `hello`, `readings`, `list`, `get`,
`validate`, `apply`, `remove`, `set`, `run`, `render`, `open`, `refresh` (`{sprite}` → `{values}`). Requests are capped
at 8 MiB. The socket is created
0600 and the server checks the peer's uid (`getpeereid`). Only the ordinary app launch serves it, never a
validation or render launch.

## Not in version 1

Text input fields on boards, one-shot rule actions (notify, run), sprite
sharing/marketplace beyond the spec file itself, and a remote MCP endpoint for ChatGPT.
