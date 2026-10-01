/// The authoring guide agents read before writing a sprite spec (`menusprite guide`, the MCP `get_guide` tool).
/// It lands in the agent's context, so it stays compact and example-led, and every statement in it must be true of
/// the compiler (`SpriteSpec`) and the runtime. Its complete specs are compiled by `ExampleSpecsTests`, so an example
/// that stops compiling fails the build's tests rather than an agent. Spec: `docs/agent-authoring.md`.
public enum AgentGuide {
    public static let markdown = #"""
    # MenuSprite authoring guide

    Each menu-bar item is a **sprite**: a **face** (what the bar draws: an icon, a number, at most two short lines) and a **board** (the panel a click opens). Both draw from **values**: system readings, shell command output or fixed text. **Rules** restyle pieces while a condition holds. You write one JSON **spec**; MenuSprite schedules the commands, enforces timeouts and limits, and draws everything natively, in light and dark mode.

    ## MCP tools or the command line

    Use whichever you were given. MCP tools are tool calls, not shell commands: `test_command` runs a command as a sprite would, so never send `menusprite …` through it.

    | Step | MCP tool | Command line |
    |---|---|---|
    | Examples to start from | `list_examples`, `get_example` | `menusprite examples [name]` |
    | Reading ids and current values | `list_readings` (`sample: true`) | `menusprite readings [search] --sample` |
    | Try a command or a draft's script | `test_command` (`files`: the draft's files) | `menusprite run '<cmd>' [--parse number] [--files spec.json]` |
    | Check, save and draw | `apply_sprite` (`dry_run`, `values`) | `menusprite apply spec.json --preview <dir> [--dry-run] [--value id=v]` |
    | Draw without saving | `preview_sprite` (`sprite` or `spec`; `appearance: "both"`) | `menusprite preview <name or file> [--dark\|--light\|--both] [--no-board] [--out dir] [--value id=v]` |
    | Read saved sprites | `list_sprites`, `get_sprite` | `menusprite list`, `menusprite get <name>` |
    | Run a sprite's commands now | `refresh_sprite` | `menusprite refresh <name>` |
    | Show the user; delete (ask first) | `open_board`; `remove_sprite` | `menusprite open <name>`; `menusprite remove <name>` |

    ## The loop

    1. **Start from the closest example** (list at the end), and look up reading ids.
    2. **Test every command and script** before using it. It really runs: test only read-only ones, never the on/off/stop actions (and `gh api -f` sends a POST). `files` / `--files` runs a draft's scripts in a temporary folder.
    3. **Apply.** It validates first and saves nothing on errors; every problem comes back at once as `path: message — hint`. A spec replaces the sprite with the same `id`, else the same name (any case). `dry_run` / `--dry-run` saves nothing.
    4. **Look at every picture**: face and board, dark and light, drawn after running each command once. The text says what each value showed (or why not) and what each script block drew and does when clicked; a failed block comes with its path and the end of its stderr.
    5. **Draw every state** with stand-in `values` / `--value id=v`, which draw a rule's other branches without making them happen: `{"review": 0}`, `{"review": 12}`, `{"state": "Stopped"}`, `{"session.pace": "over"}`, and `null` for a failed command or signed-out reading (the `is missing` look).
    6. **Edit** a saved sprite from `get_sprite` / `menusprite get` (keep its `id`). Tell the user what each command runs and how often; `open_board` only if they want the board shown (not when they said no windows).

    ## The spec

    | Key | Meaning |
    |---|---|
    | `menusprite` | `1`, required |
    | `name` | required, ≤ 40 characters |
    | `id` | the UUID `get` prints; leave out for a new sprite |
    | `icon` | SF Symbol: the sprite's identity in lists and the board header |
    | `enabled` / `menuBar` | default `true`; `"menuBar": false` runs it unseen |
    | `side` | `"right"` (default) or `"left"`, the strip over the frontmost app's menus |
    | `every` | seconds between reading samples: 1, 2, 5, 10, 30 or 60 (default 2); commands have their own |
    | `values` `face` `rules` `board` `files` | below. No `face` = the icon alone; no `board` (or `null`) = the classic panel |

    ### Values

    ```json
    {"id": "cpu", "reading": "cpu.usage", "decimals": 1}
    {"id": "reset", "reading": "ai.claude.sessionReset", "clock": true}
    {"id": "prs", "command": "gh pr list --json number --jq length", "every": "5m", "timeout": 20, "parse": "number", "suffix": " PRs"}
    {"id": "state", "command": "tailscale status --json", "parse": "json", "path": "BackendState"}
    {"id": "label", "text": "Build"}
    ```

    - `id`: letters, digits, `_`; ≤ 32; unique. Texts write `{id}`, rules `id`. `name` defaults to the reading's name, else the id.
    - Readings take `decimals` (0–2), `unit` (default true), `fahrenheit`, `bits`, and show their unit: `{cpu}` is `23%`, a rate `1.2 MiB/s`, a duration `2h 14m`. `"clock": true` shows a duration as the time it ends (`16:30`, `Sat 4:30 PM`, `8 Oct 4:30 PM`, in the Mac's locale). Common: `cpu.usage` `cpu.load1` `memory.usage` `memory.pressure` (Normal/Warning/Critical) `network.download` `network.upload` `disk.usage` `disk.available` `battery.charge` `battery.state` `sensor.PSTR` (system watts) `sensor.cpuTemperature` `sensor.fanSpeed` `system.uptime` `ai.claude.session` `ai.claude.weekly` `ai.claude.sessionReset` `ai.claude.weeklyReset` `ai.codex.session` `ai.codex.weekly`. Not every Mac has every sensor or a battery.
    - **AI readings** (`ai.claude.*`, `ai.codex.*`) come from the user's Claude Code and Codex CLI logins, fetched every few minutes while a sprite shows them. Signed out, they have no value; a test sandbox has them offline. `value.pace` is `on track`, `ahead`, `over`, or empty when unknown (handle it with an otherwise); a stand-in number does not compute a pace, so set `id.pace` too.
    - Commands take `every` (2 s – 1 day: `30`, `"30s"`, `"5m"`, `"1h"`, `"1d"`; default 60 s), `timeout` (1–60 s, default 10), `parse` (`text`: the first line, up to 500 characters, the default · `number`: the first number printed · `json` + `path`: the value at a dotted path like `items.0.name`), `suffix`, `decimals` (default 0), `background`. No value (drawn `—`) when it exits non-zero, times out, prints nothing or prints over 64 KiB.
    - **One command, many values**: values with the same `command`, `every` and `timeout` share one process per run, and each reads the output its own way. Several fields of one API call are several values with the identical command and different `path`s: one request, no cache file. A `script` or `blocks` block with that command, `every` and `timeout` shares the run too (examples `git-repo-status`, `weather`).

    ### Face

    Nodes, each an object with one kind key; a bare string is text, a list is a row: `{"row": […]}` · `{"column": […]}` (the bar fits two lines) · `{"text": "CPU {cpu}"}` · `{"icon": "flame.fill"}` · `{"bar": "cpu", "max": 100}` (a vertical level bar as tall as the menu bar: put it beside a `column`, never in one) · `{"battery": "charge"}`.

    Properties: `id`, `color`, `size` (text 12, icon 14), `weight` (`regular medium semibold bold heavy`), `opacity`, `align` (`leading center trailing`), `gap`, `justify` (`start center end spaceBetween even`), `padding`, `hidden`, `shrink`, `tabular` (default true), `max`, `chargeInside`. Colour passes to children, and a row's or column's opacity dims everything in it; size and weight do not pass. Colours: the names `red orange yellow green mint teal cyan blue indigo purple pink brown gray white black` are Apple's adaptive colours (one shade for light, one for dark); `"#RRGGBB"` is fixed; `"inherit"` (default); `"auto"` follows the bar.

    ### Rules

    ```json
    {"name": "Hot", "when": "cpu > 80 and temp >= 90", "then": [{"target": "cpuText", "color": "red", "text": "CPU {cpu}!"}], "else": [{"target": "flame", "hide": true}]}
    {"name": "Pace", "cases": [
      {"when": "session.pace == over", "then": [{"target": "five", "color": "red"}]},
      {"when": "session.pace == ahead or weekly > 90", "then": [{"target": "five", "color": "orange"}]}]}
    ```

    - `when`: `value op operand`, joined by `and` or by `or`, not both (use `cases`). Operators `>` `>=` `<` `<=` `==` `!=` `contains`, `is missing`, `is present`. Operands: a number, `'quoted text'` or bare words; text compares ignore case. Numbers are raw: percent 0–100, bytes, bytes/s, seconds, °C. Compare `.pace` with `==` or `!=`.
    - `is missing` holds while a reading has no value, or a command failed, printed nothing or has not finished its first run. Then every comparison fails except `!=`, which holds, so test it first (example 1).
    - An action names a `target` (a face node's or board block's `id`) and effects: `color`, `hide: true`, `show: true`, `icon`, `text` (with `{values}`), `opacity`.
    - The first case that holds applies, else `else`. Effects last while their branch holds; a later rule wins. No one-shot actions (notify, run).

    ### Board

    `"board": {"width": 380, "header": true, "blocks": […]}`: width 260–560 (default 360); `header` shows icon, name and Configure…. A board taller than the screen scrolls. Each block has one kind key:

    | Block | Draws |
    |---|---|
    | `{"stack": […]}` `{"row": […]}` `{"card": […], "title": "…"}` | stacked; side by side in equal widths; a titled rounded panel |
    | `{"divider": true}` `{"space": 12}` | a line; empty height |
    | `{"text": "…{v}…", "font": "headline", "icon": "bolt"}` | fonts `huge title headline body caption mono`; `icon` draws an SF Symbol before it |
    | `{"value": "v", "caption": "…", "detail": "…"}` | a big figure (`"font": "huge"`: bigger) |
    | `{"gauge": "v", "max": 100, "caption": "…", "detail": "{v} of {cap}"}` | a level bar; `detail` replaces the figure |
    | `{"chart": "v", "caption": "…", "height": 44}` | recent history, headed by caption (or name) and current figure; scaled 0–100 for a percentage, else 0 to its peak |
    | `{"stats": ["a", "b"]}` | name · value rows |
    | `{"button": "Label", "icon": "…", "run": "cmd", "timeout": 120}` | or `"open": "https://…"`, `"app": "Name"`, `"copy": "{v}"`, `"refresh": true` |
    | `{"toggle": "Label", "value": "v", "on": "cmd", "off": "cmd"}` | a switch, on while `v` is a non-zero number or `true on yes enabled active up connected running` |
    | `{"output": "v", "height": 90}` | a command value's raw output |
    | `{"script": "cmd", "every": 60}` | rows a script prints (below) |
    | `{"blocks": "python3 board.py", "every": 60}` | blocks a script prints (below) |
    | `{"image": "chart.png", "height": 120}` | a file (absolute, `~/…`, in the sprite's folder) or `https://` |
    | `{"processes": "cpu", "limit": 8}` `{"energy": true}` `{"accounts": true}` `{"readings": true}` | MenuSprite's panels: processes (`cpu memory power`), Battery & Power, AI accounts, readings with graphs |

    - **Clickable blocks**: a `text`, `value`, `stack`, `row`, `card`, `image` or `stats` block with one of `run`, `open`, `app`, `copy`, `refresh` is clickable anywhere on it (hover fill, pointer, a ↗ for `open`). A card of stacks, each with `open`, is a list of links (example 1).
    - Properties: `id`, `name`, `color`, `background` (a rounded fill; text on it turns black or white), `align`, `spacing` (between children, default 8), `padding`, `hidden`, `opacity`, `height`, `max`, `limit`, `font`. `color` fills a gauge's bar, a chart's line and a switch when on; elsewhere it colours text. Text, value and button blocks take `lines` (a line limit, full text on hover) and `truncate` (`tail` `middle` `head`). In a `row`, `"fit": true` gives a block its natural width and the rest share what is left (a long name beside a short figure).
    - **Actions** (`run`, a switch's `on`/`off`, a script row's `bash=`) run in the sprite's folder, stop after their `timeout` (1–600 s, default 30), and show a spinner, then their output or error under the block. When one finishes, every command of the sprite runs again, so the face and board show what it changed.

    **Script rows** (`script`): each printed line is a row, `Text | sfimage=bolt color=orange href=https://… bash="cmd" size=11 weight=bold font=Menlo length=40 tooltip="…"`; `---` is a divider, a leading `--` indents; text cannot contain `|`. A click opens `href` or runs `bash`. Quick to write, but no cards or captions: for lists, prefer clickable blocks.

    ### Script blocks: any CLI draws its own dashboard

    A `blocks` command prints a JSON list of blocks (or `{"blocks": […]}`) in the vocabulary above minus `blocks`, `script` and the four panels. It runs when the board opens and every `every` while open (default 60 s, timeout 10 s). Problems are drawn in place with their path; a failed run shows its error and the last lines of its stderr, so prefer printing blocks that say what went wrong. Printed blocks may name the sprite's values or carry literal data: `{"value": 12}`, `{"value": "3.2 GB"}`, `{"gauge": 45, "max": 50}`, `{"chart": [3, 5, 2, 8]}`, `{"stats": [{"name": "Open", "value": 12}]}`, `{"toggle": "web", "value": true, "on": "…", "off": "…"}`. Printed ids are ignored (rules cannot target them); at most 200 blocks, counting every nested one (a row of three texts is four), so cap long lists and end with "and N more". Print with `json.dumps`, never by hand.

    ## Commands and files

    - Commands run in `/bin/zsh -f -c`: no `.zshrc`, aliases or exported variables, so a token your profile sets is absent (tools with their own login, like `gh`, work). `PATH` starts `/opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin ~/.local/bin ~/bin ~/.cargo/bin ~/.bun/bin ~/go/bin`; use absolute paths for anything else (nvm, pyenv). Standard input is empty: never prompt. At most 16384 characters; longer goes in `files`.
    - `MENUSPRITE_TRIGGER` says why a command runs: `open` (a board opened, the sprite started, the app launched, the Mac woke), `tick` (every `every`), `refresh` (a Refresh button, the re-run after an action, `refresh_sprite`), `action` (a click), `preview` (`test_command`, your pictures). A script that keeps its own cache should skip it on `refresh`.
    - **When**: a value the face or a rule uses runs every `every` while the sprite is enabled. Board-only values and `script`/`blocks` run only while the board is open, first as it opens; `"background": true` keeps a value running (a command's chart needs history). A command never runs twice at once: a Refresh during a run waits for it, then runs once more.
    - **Cost**: cheap local commands, and services on `127.0.0.1` (Docker, Ollama, a dev server), every 10–30 s; slow commands every 60 s or more; remote APIs and anything rate-limited every `"5m"` or more. Failures back off, doubling up to 10 minutes, never sooner than `every`.
    - **Long jobs**: start them in the background, `"run": "nohup ./job.sh >/dev/null 2>&1 &"`; the click returns at once and the job outlives it. End the job with `menusprite refresh <sprite>` (in `MenuSprite.app/Contents/Helpers/` when not on `PATH`) so the bar updates the moment it is done. Or open Terminal on a `.command` file from `files`.
    - **Files**: `"files": {"board.py": "…"}` writes into `~/Library/Application Support/MenuSprite/Sprites/<id>/` (names of letters, digits, `. _ -`; ≤ 20 files of 256 KiB; content starting `#!` is made executable). Every command of a sprite with files runs in that folder with `$SPRITE_DIR` set, so `python3 board.py` works. These are the spec's files: `get` carries them and an apply replaces them; omitting `files` keeps them, `{}` removes the folder. Whatever the scripts write there (a cache, a log, an image) is theirs: never carried, and left alone when an apply changes `files`.

    ## Design that looks good

    - **Face**: an icon and one short number, or two 9–10 pt lines in a `column`. Long text widens the item. `.fill` symbols read best.
    - **Zero, failed and fine are three looks.** Hide a count while it is zero; while it `is missing`, swap the icon for a warning glyph or dim it. Never hide on missing alone: a broken command would look like "nothing to do".
    - **Board**: width 340–400. A `row` of two or three `value` tiles first, then titled `card`s, then a `row` of buttons (three with icons need width 400+ or one-word labels: look for "…"). Gauges for limits, charts for what moves (a chart shows its own figure: no tile of the same value beside it), `stats` for name/value lists, `"font": "caption", "color": "gray"` for secondary lines. Long names: `"lines": 1` (`"truncate": "middle"` for ids), with `"fit": true` on the figure beside them.
    - **Colour means something**: orange and red for attention, green sparingly. Names adapt to light and dark; a hex chosen for one mode washes out in the other.

    ## Gotchas

    - **Texts and rules name values, not readings**: declare `{"id": "cpu", "reading": "cpu.usage"}`, write `{cpu}` and `cpu > 80`. `{cpu.usage}` is an error.
    - `{cpu}` already ends in `%`: `"{cpu}%"` shows `23%%` (or set `"unit": false`).
    - One kind key per piece: `{"text": "Hi"}`, never `{"type": "text"}`. Ids are unique across face and board; every piece a rule targets needs an `id`.
    - Commands are JSON strings: escape `\"` and `\\`, prefer single quotes inside (`jq -r '.name'`), put anything long in `files`.
    - Non-zero exit = no value: a `grep` that finds nothing exits 1, so add `|| true` where empty is fine. A pipeline's status is its last command's (`setopt pipefail` to catch the first), and `wc -l` prints `0` even when the command before it failed.
    - Rules compare the number as parsed: print full precision and let `decimals` round the display.
    - In printed blocks, `{word}` inside a text string names a sprite value. Escape braces you did not write in each text string (`title.replace("{", "{\u200b")`), never in the JSON you print.
    - `gh` lists stop at 30 unless given `--limit`. The bar holds two lines, never three.

    ## Complete examples

    ### 1. GitHub pull requests: clickable rows from `gh`, and a failure look

    ```json
    {
      "menusprite": 1,
      "name": "GitHub PRs",
      "icon": "arrow.triangle.pull",
      "values": [
        {"id": "review", "command": "gh search prs --review-requested=@me --state=open --limit 100 --json number --jq length",
         "every": "5m", "timeout": 20, "parse": "number"}
      ],
      "face": [{"icon": "arrow.triangle.pull", "id": "glyph"}, {"text": "{review}", "id": "count", "weight": "semibold"}],
      "rules": [{"name": "State", "cases": [
          {"when": "review is missing", "then": [{"target": "count", "hide": true}, {"target": "glyph", "icon": "exclamationmark.triangle", "opacity": 0.6}]},
          {"when": "review == 0", "then": [{"target": "count", "hide": true}]}],
        "else": [{"target": "count", "color": "orange"}]}],
      "board": {"width": 380, "blocks": [
        {"blocks": "python3 prs.py", "every": "2m", "timeout": 30},
        {"row": [{"button": "Review queue", "icon": "safari", "open": "https://github.com/pulls/review-requested"},
                 {"button": "Refresh", "icon": "arrow.clockwise", "refresh": true}]}
      ]},
      "files": {"prs.py": "#!/usr/bin/env python3\nimport json, subprocess\ndone = subprocess.run([\"gh\", \"search\", \"prs\", \"--review-requested=@me\", \"--state=open\", \"--limit=30\",\n                       \"--json\", \"number,title,repository,url\"], capture_output=True, text=True, timeout=25)\nif done.returncode:\n    raise SystemExit(done.stderr.strip() or \"gh failed\")  # the board shows the end of this\nprs = json.loads(done.stdout)\nrows = [{\"stack\": [{\"text\": p[\"title\"].replace(\"{\", \"{\\u200b\"), \"lines\": 1},\n                   {\"text\": \"%s #%d\" % (p[\"repository\"][\"nameWithOwner\"], p[\"number\"]), \"font\": \"caption\", \"color\": \"gray\"}],\n         \"spacing\": 2, \"open\": p[\"url\"]} for p in prs[:8]]\nprint(json.dumps([{\"card\": rows or [{\"text\": \"Nothing to review\", \"font\": \"caption\", \"color\": \"gray\"}],\n                   \"title\": \"Waiting for your review\"}]))\n"}
    }
    ```

    ### 2. AI usage limits: gauges, pace rules, reset times, a signed-out look

    ```json
    {
      "menusprite": 1,
      "name": "AI limits",
      "icon": "sparkles",
      "every": 60,
      "values": [
        {"id": "session", "reading": "ai.claude.session"},
        {"id": "sessionReset", "reading": "ai.claude.sessionReset", "clock": true},
        {"id": "weekly", "reading": "ai.claude.weekly"},
        {"id": "codex", "reading": "ai.codex.weekly"}
      ],
      "face": {"row": [
        {"icon": "exclamationmark.triangle", "id": "noData", "hidden": true, "opacity": 0.6},
        {"column": [{"text": "5h {session}", "id": "five", "size": 9, "weight": "semibold"},
                    {"text": "7d {weekly}", "size": 9, "weight": "semibold"}], "id": "lines"}]},
      "rules": [
        {"name": "Pace", "cases": [
          {"when": "session.pace == over", "then": [{"target": "five", "color": "red"}, {"target": "sessionGauge", "color": "red"}]},
          {"when": "session.pace == ahead", "then": [{"target": "five", "color": "orange"}, {"target": "sessionGauge", "color": "orange"}]}]},
        {"name": "Signed out", "when": "session is missing", "then": [{"target": "lines", "hide": true}, {"target": "noData", "show": true}]},
        {"name": "No Codex", "when": "codex is missing", "then": [{"target": "codexGauge", "hide": true}]}
      ],
      "board": {"width": 360, "blocks": [
        {"card": [
          {"gauge": "session", "id": "sessionGauge", "caption": "Session · 5 hours", "detail": "{session} · resets {sessionReset}"},
          {"gauge": "weekly", "caption": "Week · all models"},
          {"gauge": "codex", "id": "codexGauge", "caption": "Codex · week"}
        ], "title": "Usage limits"},
        {"button": "Claude usage", "icon": "safari", "open": "https://claude.ai/settings/usage"}
      ]}
    }
    ```

    ### More, complete with their scripts

    `list_examples` / `menusprite examples` describes them; `get_example` / `menusprite examples <name>` gives one: `ai-usage-board`, `docker-containers` (a switch per container), `git-repo-status` (one scan feeds face and board), `github-prs`, `homebrew-outdated` (a long-running button; a job that reports back), `network-switches`, `system-dashboard` (readings only), `weather` (two values, one request).
    """#
}
