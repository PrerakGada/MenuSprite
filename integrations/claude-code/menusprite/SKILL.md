---
name: menusprite
description: Create, change or remove MenuSprite sprites (macOS menu-bar items) and the board a click opens, from what the user describes, using the menusprite command. Use when the user asks for something in their menu bar (a status item, a dashboard or panel fed by a CLI tool or script, usage limits, a switch) or to change a MenuSprite sprite, and the menusprite MCP tools (get_guide, apply_sprite…) are not loaded. If they are loaded, use them instead.
---

# Building MenuSprite sprites from the command line

MenuSprite draws each menu-bar item (a **sprite**) and the **board** a click opens from a JSON spec. You write the
spec; the running app validates it, saves it and draws it. Never edit MenuSprite's code, `monitoring.json` or its
`Sprites` folder: the app rewrites them, so every change goes through `menusprite`.

## 1. Find the command and read the guide

```sh
command -v menusprite || ls ~/Applications/MenuSprite.app/Contents/Helpers/menusprite /Applications/MenuSprite.app/Contents/Helpers/menusprite
menusprite guide
```

Read the whole guide once per session before writing a spec: it is the format, with complete examples. If the
command is missing, MenuSprite is not installed (or too old for agents): tell the user rather than guessing.
`menusprite` starts the app in the background when it is not running.

## 2. Look before you write

```sh
menusprite examples                      # built-in example sprites; menusprite examples <name> prints one to start from
menusprite list                          # existing sprites: is there one to change rather than add?
menusprite readings battery --sample     # reading ids, units and current values (or why a reading has none)
menusprite run 'gh pr list --json number --jq length' --parse number   # every command, exactly as a value runs it
menusprite run 'python3 board.py' --files <scratch>/sprite.json        # a draft's script, before saving anything
```

To change a sprite, start from its spec: `menusprite get "<name>" > <scratch>/sprite.json`, edit, keep its `id`.

## 3. Apply, look, refine

Write the spec to a scratch file (not into the user's project), then:

```sh
menusprite apply <scratch>/sprite.json --preview <scratch>/preview
```

Apply validates first and saves nothing if there are errors; fix every diagnostic it lists (each has a path and
a hint) and apply again. `--dry-run` checks and draws without saving. When it draws, open every PNG it lists with
the Read tool: the face and the board, in dark and in light mode. Check the face fits, the board is laid out well,
values are not `—`, and colours read in both modes. A value showing `—` is a failing command: the output says why,
and `menusprite run` tests it. A failed script block comes with its spec path and the end of its stderr.

Draw the states you cannot make happen with stand-ins, so every rule branch is seen:
`--value review=0`, `--value state=Stopped`, `--value session.pace=over` (with `apply --preview` or
`menusprite preview "<name>" --both`). For the failure look, preview a copy whose command is `exit 1`.

Finish with `menusprite open "<name>"` so the user sees the board, and tell them what it shows and how often
each command runs.

## Rules

- Ask before `menusprite remove`. Do not run a switch's `on`/`off` commands or other state-changing commands to
  test them unless the user agrees; test the read-only ones.
- Keep it light: local commands and services on 127.0.0.1 every 10–30 s; slow commands 60 s or more; remote APIs
  `"every": "5m"` or more. Values with the identical command, `every` and `timeout` share one run, so read several
  fields of one call with several values and different `path`s rather than a cache file.
- Zero, failed and fine look different: hide a count at zero, but show a warning glyph (or dim the icon) while the
  value `is missing`.
- Commands run in `zsh -f` without the user's profile: use absolute paths for tools outside Homebrew and
  `~/.local/bin`, and do not rely on exported tokens.
- Put scripts longer than a line in the spec's `files`; they run in the sprite's folder. A job longer than a
  button's timeout runs in the background (`nohup ./job.sh >/dev/null 2>&1 &`) and ends with
  `menusprite refresh "<name>"`.
- `--json` gives machine-readable output for any verb.
