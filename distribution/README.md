# MenuSprite

A native macOS menu-bar monitor with customizable readouts and app/process detail
panels. This repository distributes public preview binaries; application source
and internal planning are not published here.

## Install

Requires **Apple Silicon and macOS 26 or newer**.

```sh
brew install --cask prerakgada/tap/menusprite
open -a MenuSprite
```

Or [download the signed, notarized DMG](https://github.com/PrerakGada/menusprite-releases/releases/download/v0.5.5-preview.1/MenuSprite-0.5.5-preview.1-arm64-installer3.dmg):

1. Open the downloaded disk image.
2. Drag **MenuSprite** onto the **Applications** shortcut in the installer window.
3. Open MenuSprite from Applications, then eject the installer disk.

When updating manually, quit MenuSprite first and choose **Replace** when Finder
asks. Your saved settings remain in place. Keep only one installed copy.
Use `brew upgrade --cask menusprite` for future updates; this preview has no in-app
updater.

The ZIP remains available for Homebrew and existing download links. Both formats
contain the same 0.5.5 (16) app.

## Public preview

- CPU, memory, network, disk, GPU, battery and available read-only hardware sensors.
- Configurable menu-bar items: labels above values, paired rows, editable labels, separate icon/text colors, units and refresh intervals.
- Claude and Codex limit readings, day/hour pace colors, a percent-symbol-only color option, and an AI Accounts board for their CLI logins.
- CPU/RAM/Power panels with ranked accessible apps/processes and helper grouping.
- A Permissions & Access page for MenuSprite's own access, with explicit requests and system-setting links.
- Keep-awake timers and automatic rules for power, displays and selected running apps.

Per-app Power is **CPU-energy-derived**, not total electrical draw. GPU, display
and other components are not assigned to individual apps. Sensors vary by Mac;
unavailable values remain unavailable. CPU-temperature mapping is currently
specific to the tested M5 family. Process lists update only while their panels
are open, and do not include every protected system process.

The preview excludes administrator helpers, battery charge control, closed-lid
sleep overrides, fan control, capture, clipboard history, marketplace and sharing.
It is an early public build, not a claim of complete replacement for other utilities.

## Privacy and settings

System monitoring stays on the Mac; no MenuSprite account or telemetry is required. Optional AI usage readings use your existing Claude Code/Codex login to contact the relevant provider for current limits, and may refresh an expiring login. The AI Accounts board shares saved logins with Claude Switcher. Switching a login changes the account used by the corresponding CLI; existing Codex sessions may retain their previous account. These features do not upload your project files or mail. Opening
Permissions & Access does not request permissions or capture private content.
Settings are stored under `~/Library/Application Support/MenuSprite` and the app's
`in.prerakgada.MenuSprite` preferences. Readouts can be hidden or disabled separately.

## Feedback

Report reproducible issues in this repository. Include the MenuSprite version,
macOS version and Mac model. Do not attach passwords, private process data or
personal diagnostic files without reviewing them first.
