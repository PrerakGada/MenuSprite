MenuSprite 0.5.5 Preview 1 for Apple Silicon Macs running macOS 26+.

## What changed

- Claude and Codex usage readings with cumulative daily weekly budgets and hourly five-hour budgets. Choose whole-text pace colors or white numbers with only the percent symbol colored.
- Combine readings into two rows, edit their labels, and configure icon and text colors independently.
- A filled fan icon and small left/right margins make menu-bar readouts easier to distinguish.
- Bold applies to both labels and values when enabled. Existing saved settings are preserved; system readouts start at normal weight on new installs.
- AI Accounts brings the existing CLI logins and Claude Switcher saved accounts into one board. Switching is an explicit account action, separate from viewing a limit.
- Updated native process details and monitoring views from the recent local builds.

## Install or update

[Download the signed, notarized DMG](https://github.com/PrerakGada/menusprite-releases/releases/download/v0.5.5-preview.1/MenuSprite-0.5.5-preview.1-arm64-installer3.dmg), open it, and drag **MenuSprite** onto **Applications**. Quit the old app before replacing it. Your saved settings remain in place.

Homebrew:

```sh
brew update
brew upgrade --cask prerakgada/tap/menusprite
```

For a first installation, use `brew install --cask prerakgada/tap/menusprite`.

The DMG and ZIP contain the same Developer ID signed and Apple-notarized 0.5.5 (16) app. The ZIP is used by Homebrew. Older releases remain available.

## Scope and privacy

Includes system monitoring, configurable readouts, native CPU/RAM/Power panels, Permissions & Access, ordinary keep-awake, and optional Claude/Codex usage and account tools. AI readings contact the provider using its CLI login; they may refresh an expiring token. Saved accounts share Claude Switcher storage. There is no MenuSprite account or telemetry.

The public preview excludes privileged helpers, charging and closed-lid controls, and the experimental Work & Clients report. Charge limiting is not only a build exclusion: it needs firmware that publishes a writable charge-inhibit key, and recent Apple Silicon publishes none, so it cannot be held on that hardware in any build. Fan control, capture, clipboard history, marketplace and sharing remain outside this build. Per-app Power is CPU-energy-derived, and hardware sensors vary by Mac. Account-limit percentages are not project AI costs.

Distributed through the `prerakgada/tap` tap, not the official Homebrew Cask catalog. This remains a public preview.
