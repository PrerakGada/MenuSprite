# Connecting AI agents to MenuSprite

Any agent can build MenuSprite sprites (a menu-bar item and the board a click opens) from what the user types,
without anyone editing MenuSprite's code. There are two ways in, and both reach the running app the same way:

- **MCP**: `menusprite mcp` is an MCP server on stdio. Agents get fourteen tools (`get_guide`, `list_examples`,
  `get_example`, `list_readings`, `list_sprites`, `get_sprite`, `validate_sprite`, `apply_sprite`, `preview_sprite`,
  `test_command`, `refresh_sprite`, `set_sprite`, `remove_sprite`, `open_board`) and see preview images of what they
  built, in dark and light mode. The example sprites are compiled into the server, so no checkout is needed.
- **The command line**: any agent that can run shell commands can use `menusprite guide`, `menusprite apply` and
  the rest. The [Claude Code skill](claude-code/menusprite/SKILL.md) teaches that loop.

Either way the agent should read the authoring guide first (`get_guide` or `menusprite guide`). Ready-made specs
to start from are in [`examples/sprites/`](../examples/sprites/), and inside the command (`list_examples` /
`get_example`, or `menusprite examples [name]`).

## The command

The `menusprite` command ships inside the app at `MenuSprite.app/Contents/Helpers/menusprite`. A local build
(`scripts/build-native.sh --install`) links it as `~/.local/bin/menusprite`. Otherwise, link it yourself:

```sh
ln -s /Applications/MenuSprite.app/Contents/Helpers/menusprite ~/.local/bin/menusprite
menusprite version
```

The command starts MenuSprite in the background if it is not running. The app does every write itself, so specs
are applied exactly as the sprite studio would apply them; never edit `monitoring.json` or the `Sprites` folder
by hand, because the app rewrites them.

## Registering the MCP server

`menusprite setup <agent>` registers the server using the command inside the installed app, so moving a
build does not break it. It merges into existing config files, never replaces them, and copies the previous file
aside first. Add `--print` to see the change without making it.

| Agent | One command | By hand |
|---|---|---|
| Claude Code | `menusprite setup claude` | `claude mcp add --scope user menusprite -- <path to menusprite> mcp` |
| Codex | `menusprite setup codex` | add the TOML below to `~/.codex/config.toml` (or `$CODEX_HOME/config.toml`) |
| Cursor | `menusprite setup cursor` | merge the JSON below into `~/.cursor/mcp.json`, then reload in Settings → MCP |
| Claude Desktop | `menusprite setup claude-desktop` | merge the JSON below into `~/Library/Application Support/Claude/claude_desktop_config.json`, then quit and reopen |
| Antigravity | `menusprite setup antigravity` (prints what to paste) | agent panel → … → MCP Servers → Manage MCP Servers → View raw config (`~/.gemini/antigravity/mcp_config.json`), merge the JSON below, refresh |

Codex:

```toml
[mcp_servers.menusprite]
command = "/Applications/MenuSprite.app/Contents/Helpers/menusprite"
args = ["mcp"]
```

Cursor, Claude Desktop, Antigravity and most other MCP clients (keep any other servers under `mcpServers`):

```json
{
  "mcpServers": {
    "menusprite": {
      "command": "/Applications/MenuSprite.app/Contents/Helpers/menusprite",
      "args": ["mcp"]
    }
  }
}
```

Use `~/Applications/MenuSprite.app/…` instead when that is where the app is (a local build installs there);
`menusprite setup` finds the right one. Start a new session of the agent afterwards so it loads the server.

## Agents without MCP

- **Any shell-capable agent** (Claude Code without the server, Codex, Gemini CLI, Aider, a terminal agent of your
  own): tell it to run `menusprite guide` first and to follow its loop: `menusprite examples`, `menusprite readings`,
  `menusprite run` (with `--files spec.json` for a draft's scripts), write a spec file,
  `menusprite apply spec.json --preview <dir>`, look at the PNGs (dark and light), apply again. Every verb takes
  `--json`.
- **Claude Code skill**: copy [`claude-code/menusprite/`](claude-code/menusprite/) to `~/.claude/skills/menusprite/`
  (or a project's `.claude/skills/`). Claude Code then uses the command line whenever the user asks for a
  menu-bar item and the MCP tools are not loaded.
- **ChatGPT**: the desktop app accepts only remote connectors, and MenuSprite's server is local, so ChatGPT cannot
  reach it. Use Codex, or give ChatGPT the guide (`menusprite guide | pbcopy`), ask it for a spec, and apply what it
  writes with `menusprite apply -` (paste, then Ctrl-D).

## What to ask for

Plain requests work; the guide carries the format. For example:

- "Put my open GitHub pull requests in the menu bar, with a board listing the ones waiting for my review."
- "Show Docker's running containers, with a switch to start and stop each one."
- "A menu-bar item for my Claude and Codex limits: two lines, red when I'm over pace, gauges on the board."
- "Make a board for `kubectl get pods -A -o json`: pods by namespace, failing ones in red."
- "Change my System sprite's board to add a GPU chart."

The agent tests each command, applies the sprite, looks at the preview pictures in both appearances, draws the
states it cannot make happen with stand-in values (`values` / `--value id=v`), and refines. It asks before removing
a sprite.

A sprite's own scripts can tell MenuSprite when a long job is done: `menusprite refresh "<sprite>"` runs its
commands again at once, so the menu bar does not wait for the next scheduled run.
