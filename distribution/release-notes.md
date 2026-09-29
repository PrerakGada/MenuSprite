MenuSprite 0.5.7 Preview 1 for Apple Silicon Macs running macOS 26+.

## What changed

- **Sprite studio (new and early).** A sprite is now a design you build: rows and columns of text, icons, level bars and batteries, where text mixes your own words with `{values}`. Values can be any reading, the output of a shell command, or fixed text, and If / Otherwise rules restyle pieces as values change. The Sprites list draws each sprite exactly as your menu bar does; click one to open it in the studio. What a click on a sprite opens is designable too — blocks, buttons, script rows and MenuSprite's own panels — or keep the classic panel. **Your existing sprites are converted automatically the first time 0.5.7 opens**, and a backup of your previous settings is kept next to them.
- **Sprites on the left of the menu bar.** Right-click any sprite and choose **Move to left side**: it joins a strip over the frontmost app's menus, leaving the right side to macOS and other apps. Point at the strip and hold ⌘ to reach the app's own menus. Nothing moves unless you move it.
- **Keep Awake, fuller.** Right-click the MenuSprite icon to toggle Keep Awake; while it is on, the icon changes to the active icon and colour you choose. The Tools page adds a saved default length, what right-click does, start on open, a battery floor and an optional pointer nudge.
- **Choose MenuSprite's own menu-bar icon** from 18 designs under Tools.
- **Where the power goes.** The Battery & Power flow now splits app power by category — Development, Browsing, Work & chat, Media & design, Background — with any app drawing 2 W or more shown on its own, then Display & system. The apps list is grouped the same way.
- **Dynamic Island:** System cards can show any reading (with a bar or a second reading, up to 12 in any order), and Tools are editable in the Island settings. The Island stays off until you switch it on.
- The hub panel's footer now opens every full window: Sprites, Keep Awake, Island, Access and Quit.

## Install or update

[Download the signed, notarized DMG](https://github.com/PrerakGada/menusprite-releases/releases/download/v0.5.7-preview.1/MenuSprite-0.5.7-preview.1-arm64-installer3.dmg), open it, and drag **MenuSprite** onto **Applications**. Quit the old app before replacing it. Your saved settings remain in place.

Homebrew:

```sh
brew update
brew upgrade --cask prerakgada/tap/menusprite
```

For a first installation, use `brew install --cask prerakgada/tap/menusprite`.

The DMG and ZIP contain the same Developer ID signed and Apple-notarized 0.5.7 (18) app. The ZIP is used by Homebrew. Older releases remain available.

## Scope and privacy

Includes system monitoring, the Sprite studio, configurable readouts, the hub panel, native CPU/RAM/Power panels, Permissions & Access, ordinary keep-awake, the Dynamic Island (off until you turn it on) and optional Claude/Codex usage and account tools. AI readings contact the provider using its CLI login. Shell-command values run only the commands you type into a sprite, as you, at the refresh interval you choose. Claude Code session titles are read from Claude Code's local session files on this Mac. Island features ask for Calendar, Camera, Microphone or folder access only when you use them. There is no MenuSprite account or telemetry.

The public preview excludes the privileged helper, and with it the charge limit, Low Power Mode switching and closed-lid controls, as well as the experimental Work & Clients report. Fan control, marketplace and sharing remain outside this build. Per-app Power is CPU-energy-derived, and hardware sensors vary by Mac. Account-limit percentages are not project AI costs.

Distributed through the `prerakgada/tap` tap, not the official Homebrew Cask catalog. This remains a public preview.
