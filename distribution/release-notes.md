MenuSprite 0.5.8 Preview 1 for Apple Silicon Macs running macOS 26+.

## What changed

- **Ask an AI agent to build a sprite (new and early).** Describe what you want to Claude Code, Codex, Cursor, Claude Desktop, Antigravity or any agent that can run a command, and it designs the sprite and the board it opens, fed by your own command-line tools. MenuSprite now includes a `menusprite` command and an MCP server (`menusprite mcp`). Agents get a guide, eight example sprites and real previews of what they build, in dark and light mode. Run `menusprite setup claude` (or `codex`, `cursor`, `claude-desktop`, `antigravity`) to connect one. The app applies every change itself, exactly as the Sprite studio does. Homebrew puts `menusprite` on your PATH; with the DMG, link `/Applications/MenuSprite.app/Contents/Helpers/menusprite` yourself.
- **Power controls are now in the public build.** Charge limit, discharge, Low Power Mode, the MagSafe light, fan control and closed-lid keep-awake. They need MenuSprite's power helper, which ships inside the app and stays off until you choose it: open **Controls → Turn on power controls…**, then allow MenuSprite in **System Settings → General → Login Items & Extensions** (macOS asks for an administrator password once). The helper writes only the controls your Mac reports as writable. Without it, macOS's own 80–100% charge limit still works, and MenuSprite no longer takes over a limit you set in System Settings.
- **Fan control.** Click the fan sprite for Automatic, 80%, 90%, Full blast or a slider, as a share of each fan's maximum. The same choices are on right-click and in the hub's Tools. The fans go back to macOS on quit, sleep or high heat. Needs the power helper.
- **One MenuSprite window.** Sprites, Controls, Island, Work and Access are tabs of a single window, which appears in the Dock and ⌘-Tab while it is open and works with Stage Manager.
- **A gallery of ready-made sprites** in the Sprites tab, drawn live with your Mac's readings: add one as it is, then design it.
- **Left strip:** sprites take clicks and drags straight away; rest on the strip for a moment (1 s, adjustable) to see the app's menus. Holding ⌘ instead is still a choice in the hub's Sprites page.
- **AI usage refreshes itself:** it checks often while you are using your limits and backs off to once an hour when nothing changes. Each Claude row now names the login it actually reads.

## Install or update

[Download the signed, notarized DMG](https://github.com/PrerakGada/menusprite-releases/releases/download/v0.5.8-preview.1/MenuSprite-0.5.8-preview.1-arm64-installer3.dmg), open it, and drag **MenuSprite** onto **Applications**. Quit the old app before replacing it. Your saved settings remain in place.

Homebrew:

```sh
brew update
brew upgrade --cask prerakgada/tap/menusprite
```

For a first installation, use `brew install --cask prerakgada/tap/menusprite`.

The DMG and ZIP contain the same Developer ID signed and Apple-notarized 0.5.8 (19) app. The ZIP is used by Homebrew. Older releases remain available.

## Scope and privacy

Includes system monitoring, the Sprite studio and gallery, agent authoring, configurable readouts, the hub panel, native CPU/RAM/Power panels, power controls (with the helper turned on), Permissions & Access, keep-awake, the Dynamic Island (off until you turn it on) and optional Claude/Codex usage and account tools. AI readings contact the provider using its CLI login. Shell-command values run only the commands you or your agent put into a sprite, as you, at the refresh interval set. Agents reach MenuSprite through a socket only your user account can open. Claude Code session titles are read from Claude Code's local session files on this Mac. Island features ask for Calendar, Camera, Microphone or folder access only when you use them. There is no MenuSprite account or telemetry.

The experimental Work & Clients report stays excluded, as do capture, clipboard history, marketplace and sharing. Per-app Power is CPU-energy-derived, and hardware sensors vary by Mac. Account-limit percentages are not project AI costs.

Distributed through the `prerakgada/tap` tap, not the official Homebrew Cask catalog. This remains a public preview.
