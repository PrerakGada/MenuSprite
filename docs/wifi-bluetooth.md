# Wi-Fi and Bluetooth sprites

Prerak, 1 October 2026: macOS 27 draws its own Wi-Fi, Bluetooth, Control Center and clock items through
`MenuBarAgent`, with 7–16 pt gaps that no setting reaches (`docs/menu-bar-spacing.md`). Bartender's tight
system icons were on macOS 26. **The way back to a tight menu bar is to hide Apple's Wi-Fi and Bluetooth items
(System Settings › Menu Bar) and use MenuSprite's, which sit at 0 pt like every other sprite.** He asked for
them to be better than Apple's: Wi-Fi inside the network-speed sprite as well as on its own, and a green dot
(or more) when AirPods are connected.

## Readings

Group **Wi-Fi** (`wifi.*`, CoreWLAN, `ConnectivityReader.wifi()`, about 25 ms a read):
`state` (Connected / Not connected / Off), `signal` (0–100: −90 dBm empty, −30 dBm full), `quality`
(Excellent ≥ −55, Good ≥ −67, Fair ≥ −75, else Weak), `rssi` and `noise` (dBm), `network`, `rate` (link Mb/s,
not traffic), `band`, `standard` (Wi-Fi 4–7, 6E on 6 GHz), `channel`, `security`, `address`, `router`.

Group **Bluetooth** (`bluetooth.*`, IOBluetooth, `ConnectivityReader.bluetooth()`): `state` (On/Off),
`connected` (count), `devices` (names), `audio` (the connected headphones or speaker), `audioKind`
(AirPods Pro / AirPods Max / AirPods / Beats / Headphones / Speaker: what rules compare to pick an icon),
`audioBattery` (the emptier bud, since it stops first), `batteryLeft`, `batteryRight`, `batteryCase`,
`lowestBattery` and `lowestBatteryDevice` (across every connected accessory).

Device kind: Apple product id first (a renamed pair is still AirPods Pro: 0x2027 is "Dhvani's AirPods Pro"),
then the name, then the Bluetooth class of device. Battery levels come from IOBluetooth's own getters
(`batteryPercentLeft/Right/Case/Single/Combined`, read through KVC only when the selector exists) and, for Apple
keyboards, mice and trackpads, `BatteryPercent` in `AppleDeviceManagementHIDEventService`. 0 means "not reported".

Pure mapping and tests: `SystemMonitoring/Connectivity.swift`, `Tests/SystemMonitoringTests/ConnectivityTests.swift`.

## Permissions — never asked for by a sprite

- **Network name (SSID):** macOS gives it only to apps with Location access. Everything else on Wi-Fi needs
  nothing. Without it `wifi.network` is unavailable and says why; the Wi-Fi board has the **Allow…** button
  (`requestWhenInUseAuthorization`). MenuSprite never asks for a location fix.
- **Bluetooth:** IOBluetooth runs through the Bluetooth permission (`NSBluetoothAlwaysUsageDescription`, added
  1 Oct). Nothing touches IOBluetooth until `CBManager.authorization` is `allowedAlways`, so a sprite or the
  reading library can never raise the prompt; every `bluetooth.*` reading is unavailable with the reason until
  the Bluetooth board's **Allow Bluetooth Access** (creating a `CBCentralManager` is what asks). Denied → the
  button opens Privacy & Security › Bluetooth. Nothing scans or advertises.

## Gallery templates (`SystemMonitoring/ConnectivityTemplates.swift`)

Hand-built designs (rules and an icon bound to a value), so every behaviour below is visible and editable in the studio.

| Template | Face |
|---|---|
| `wifi.icon` Wi-Fi | `wifi` bars filled by `wifi.signal`; Off → `wifi.slash` at 45%; Not connected → `wifi.exclamationmark`; signal < 25 → orange |
| `wifi.name` Wi-Fi and network | the bars + the network name (hidden while unknown) |
| `wifi.details` Wi-Fi signal and link | the bars + SIG dBm over LINK Mb/s |
| `network.wifi` Network with Wi-Fi | the Network template (↑ orange over ↓ green) with the bars in front |
| `bluetooth.status` Bluetooth | MenuSprite's Bluetooth mark; dot at its corner: green while headphones are connected, blue for anything else; dimmed and no dot when off |
| `bluetooth.headphones` Headphones | the mark, which becomes the AirPods / AirPods Max / Beats / headphones / speaker symbol when one connects, + its battery (red below 20%) |
| `bluetooth.buds` Earbuds left and right | the device icon + L and R levels |

Renders checked off-screen with live Wi-Fi values from Nebula (−26 dBm, 144 Mb/s, 2.4 GHz ch 10, Wi-Fi 4)
and stand-in Bluetooth values on 1 Oct.

## Two renderer additions (general, not Wi-Fi-specific)

- **An icon can be bound to a value** (`DesignNode.variable` on `.icon`; studio: Symbol › *Fills with*; spec:
  `{"icon": "wifi", "level": "signal"}`). The SF Symbol is drawn with `variableValue` = value ÷ `max`, so
  layered symbols (wifi, speaker.wave.3, cellularbars) fill as far as the value earns.
- **MenuSprite's own symbols** (`SpriteSymbols`): `menusprite.bluetooth`, drawn as a stroke since SF Symbols
  has no Bluetooth mark. Its slot is as wide as it draws (10:16), not square; SF Symbols keep their square
  slots so existing sprites do not move. The studio's picker and the agent spec accept it.

## Boards (`MenuSprite/ConnectivityBoards.swift`)

A sprite whose readings (shown, or compared by rules) are all `bluetooth.*` opens the **Bluetooth board**; all
`wifi.*`/`network.*` with at least one `wifi.*` opens the **Wi-Fi board** (`SpriteConfiguration.connectivityBoard`).
A studio-designed board still wins. Both read live only while open (2 s / 3 s); scans, joins and connects run off
the main thread.

- **Wi-Fi:** power switch; network, quality and dBm; link rate, band · channel · width, standard, security, noise
  and how far the signal stands above it, IP, router; live ↓/↑ traffic; networks in range (needs Location),
  known ones joinable with their saved password (`CWInterface.associate(to:password: nil)`), others pointed to
  Wi-Fi Settings.
- **Bluetooth:** permission flow; power switch (`IOBluetoothPreferenceSetControllerPowerState`); connected devices
  with their icon and L / R / Case or single battery and Disconnect; paired devices with Connect
  (`openConnection`, a few seconds' page timeout when the device is away).
- **Right-click:** Wi-Fi status + Turn Wi-Fi Off/On; Bluetooth: Disconnect <device · battery> per connected device
  + Turn Bluetooth Off/On (or Allow Bluetooth Access…).

## Not verified yet

Nothing here has been clicked on screen. Unexercised: the Location and Bluetooth prompts from an installed build,
AirPods battery values on real AirPods (the getters exist on macOS 27.0.1; values unseen), joining a known
network, connect/disconnect, the power switches. Wi-Fi readings were read live on Nebula.
