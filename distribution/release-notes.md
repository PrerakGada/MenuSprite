MenuSprite 0.5.6 Preview 1 for Apple Silicon Macs running macOS 26+.

## What changed

- **One panel for everything.** Clicking the MenuSprite icon opens a single panel with System, Apps, Network, Disk, Power, AI, Sprites and Tools pages. Right-click keeps the classic menu. Only the page you are looking at is sampled.
- **Quit apps from any process list.** Every row in the CPU, RAM and Power lists has a quit button: one click quits, a second click on the armed button force quits. The outcome is reported in the panel footer.
- **Clearer process lists.** Claude Code sessions collapse into one row that expands per session, titled from Claude Code's own session names. Arc expands into a row per tab with that tab's own memory, named from Arc's Task Manager (asks for Accessibility the first time you name tabs).
- **Dynamic Island (new and early, off by default).** A notch island with Now Playing, a volume mixer, clipboard, screen captures, files, calendar, notifications, timer, camera mirror, downloads, scratchpad and AI agents, plus a ⌘K command bar. Turn it on from **Dynamic Island…** in the menu. If you already run another notch app, switch one of them off.
- **Steadier menu bar.** Readouts keep a fixed width, numbers cap at three characters, and labels are a little larger. New **Level bar** layout for CPU, memory-pressure colors for RAM, power-draw colors for watts, and a battery item with the percentage inside the battery.
- **Monitoring & Sprites regrouped** into collapsible category cards, with search across every reading.
- **Menu bar spacing and Open at login** under Tools. Spacing applies after you log out and back in.
- **Battery & Power dashboard** restyled, with a power-flow diagram and apps using significant energy.
- **AI Accounts:** a compact board with auto-reload (1–30 min) and ⌘R. MenuSprite no longer refreshes the Claude Code or Codex CLI's own login; an expired login waits for the CLI to renew it, so it can never sign the CLI out.

## Install or update

[Download the signed, notarized DMG](https://github.com/PrerakGada/menusprite-releases/releases/download/v0.5.6-preview.1/MenuSprite-0.5.6-preview.1-arm64-installer3.dmg), open it, and drag **MenuSprite** onto **Applications**. Quit the old app before replacing it. Your saved settings remain in place.

Homebrew:

```sh
brew update
brew upgrade --cask prerakgada/tap/menusprite
```

For a first installation, use `brew install --cask prerakgada/tap/menusprite`.

The DMG and ZIP contain the same Developer ID signed and Apple-notarized 0.5.6 (17) app. The ZIP is used by Homebrew. Older releases remain available.

## Scope and privacy

Includes system monitoring, configurable readouts, the hub panel, native CPU/RAM/Power panels, Permissions & Access, ordinary keep-awake, the Dynamic Island (off until you turn it on) and optional Claude/Codex usage and account tools. AI readings contact the provider using its CLI login. Claude Code session titles are read from Claude Code's local session files on this Mac. Island features ask for Calendar, Camera, Microphone or folder access only when you use them. There is no MenuSprite account or telemetry.

The public preview excludes the privileged helper, and with it the charge limit, Low Power Mode switching and closed-lid controls, as well as the experimental Work & Clients report. Fan control, marketplace and sharing remain outside this build. Per-app Power is CPU-energy-derived, and hardware sensors vary by Mac. Account-limit percentages are not project AI costs.

Distributed through the `prerakgada/tap` tap, not the official Homebrew Cask catalog. This remains a public preview.
