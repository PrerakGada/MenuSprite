MenuSprite 0.5.9 Preview 1 for Apple Silicon Macs running macOS 26+.

## What changed

- **Report a Problem… and Send Feedback…** Open the MenuSprite hub, choose **Tools**, and tell Prerak, who makes MenuSprite, what went wrong or what you would like. The message goes with only what you type (name and email are optional; add your email if you would like a reply) plus MenuSprite's version and build, your macOS version and your Mac model, and the form lists exactly that. **Nothing is sent until you press Send**, and nothing is sent at launch or in the background.
- **Wi-Fi and Bluetooth sprites.** macOS 27 draws its own Wi-Fi and Bluetooth items with wide gaps that no setting removes. Hide them in **System Settings → Menu Bar** and use MenuSprite's, which sit as tight as any sprite. New gallery sprites: Wi-Fi bars, Wi-Fi with the network name, Wi-Fi signal and link, Network with Wi-Fi, Bluetooth (a green dot when headphones are connected), Headphones with their battery, and Earbuds left and right. Click one for its board: turn Wi-Fi or Bluetooth on or off, see the details, join a network, connect or disconnect a device. Right-click turns it on or off.
- **Icons that follow a value**, such as Wi-Fi bars that fill with the signal, in the Sprite studio and for agents.
- **Permissions only when you ask.** macOS shows Wi-Fi network names only to apps with Location access; MenuSprite asks for it only from the Wi-Fi board's **Allow…** and never reads where you are. Bluetooth is not touched until you choose **Allow Bluetooth Access** on the Bluetooth board, so no sprite raises a prompt. If macOS shows no prompt, the board says so and opens the right Privacy pane.

## Install or update

[Download the signed, notarized DMG](https://github.com/PrerakGada/menusprite-releases/releases/download/v0.5.9-preview.1/MenuSprite-0.5.9-preview.1-arm64-installer3.dmg), open it, and drag **MenuSprite** onto **Applications**. Quit the old app before replacing it. Your saved settings remain in place.

Homebrew:

```sh
brew update
brew upgrade --cask prerakgada/tap/menusprite
```

For a first installation, use `brew install --cask prerakgada/tap/menusprite`.

The DMG and ZIP contain the same Developer ID signed and Apple-notarized 0.5.9 (20) app. The ZIP is used by Homebrew. Older releases remain available.

## Scope and privacy

Includes system monitoring, the Sprite studio and gallery, Wi-Fi and Bluetooth sprites, agent authoring, configurable readouts, the hub panel, native CPU/RAM/Power panels, power controls (with the helper turned on), Permissions & Access, keep-awake, the Dynamic Island (off until you turn it on) and optional Claude/Codex usage and account tools. AI readings contact the provider using its CLI login. Shell-command values run only the commands you or your agent put into a sprite, as you, at the refresh interval set. Agents reach MenuSprite through a socket only your user account can open. Claude Code session titles are read from Claude Code's local session files on this Mac. Island features ask for Calendar, Camera, Microphone or folder access only when you use them; the Wi-Fi name needs Location and Bluetooth readings need Bluetooth access, each asked for only from its board. There is no MenuSprite account or telemetry. The only thing MenuSprite sends of its own is a message you write in Report a Problem… or Send Feedback…, when you press Send, to Prerak's feedback service at api.prerakgada.in.

The experimental Work & Clients report stays excluded, as do capture, clipboard history, marketplace and sharing. Per-app Power is CPU-energy-derived, and hardware sensors vary by Mac. Account-limit percentages are not project AI costs.

Distributed through the `prerakgada/tap` tap, not the official Homebrew Cask catalog. This remains a public preview.
