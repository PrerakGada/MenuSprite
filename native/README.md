# MenuSprite native app

The native app includes its Permissions & Access page, read-only system monitoring
and configurable menu-bar sprites, first battery/sleep controls
(`../docs/power-controls.md`), and Claude/Codex usage readings with AI account switching
(see *AI usage and accounts* below). The website is independent. Monitoring coverage
and user flow: `../docs/system-monitoring.md`; checks: `../docs/monitoring-validation.md`.

Local 0.5.2 also includes **Work & Clients…** (⌘T), a native report over existing paneclock history
with client assignments, billable time/rates, manual entries and CSV export. Launch directly with
`open ~/Applications/MenuSprite.app --args --show-work`. Scope and verification:
`../docs/work-report-ui.md`. The native collector and project AI accounting have not been ported.

## Public preview

MenuSprite 0.5.5 Preview 1 is published for Apple Silicon / macOS 26+:

```sh
brew install --cask prerakgada/tap/menusprite
```

The public app is Developer ID-signed and notarized. Its Homebrew download,
quarantine/Gatekeeper assessment and native launch were verified. It excludes
the experimental privileged helper and hardware-control UI; the local development
build remains separate. See `../docs/release.md` for scope and evidence.

## Launch and build

Open the installed **`~/Applications/MenuSprite.app`**, or run from the repo:

```sh
./scripts/build-native.sh --install
open ~/Applications/MenuSprite.app
```

The MenuSprite icon opens **Monitoring & Sprites…** , **Power Controls…** or **Permissions & Access…**.
Command-comma opens Monitoring & Sprites,
Command-R refreshes, Command-W closes the window, and Command-Q quits the app.
Closing Permissions releases its view, store and location-manager instance. Closing
Monitoring releases its window and removes visible-preview sampling requests;
enabled sprites keep running. Regular launches open Monitoring. Launch-at-login activation
keeps settings closed (the actual logout/login path still needs manual verification).

The deployment floor for this personal foundation is macOS 26.0. This Mac uses
macOS 26.6.2, Xcode's macOS 26.5 SDK, Swift 6.3.3 and arm64. No external packages,
web views or shell-based monitoring collectors are used. A separately installed
signed power helper handles battery/closed-lid controls; ordinary keep-awake needs none. Open `Package.swift`
in Xcode to edit; use the build script for the correctly packaged and signed app.
Do not use `swift run` to validate permissions: it is not the installed app context.

## Identity

- Bundle ID: `in.prerakgada.MenuSprite`.
- Installed location: `~/Applications/MenuSprite.app`.
- App version/build: `0.5.5` (16), shared by local and public builds. Public packaging
  checks this against `distribution/version.json`; the signing identities remain separate.
- Local signing identity: `Apple Development: Prerak Gada (X38RF8Q3T4)`;
  the certificate's team is `RC63N3VU27` (MIND WEALTH).
- Hardened runtime; camera and audio-input signing entitlements; no App Sandbox.
  Runtime entitlements permit a capability but do not grant TCC access.
- The default local development build is not notarized; public packaging uses Developer ID and notarization.
  The current development certificate expires on 3 November 2026.

`MENUSPRITE_SIGNING_IDENTITY` can explicitly select another installed identity.
The power helper and installer pin team `RC63N3VU27`; a different team also requires
explicit review/update of both XPC requirements and installer verification.
The script never silently uses ad hoc signing and refuses an install whose
designated requirement differs from the previous installed app. A deliberate
identity change requires reviewing and revalidating grants; do not reset TCC to
make tests appear clean. Rebuilds preserve the requirement and signed app identity.
Quit before installing an update. The prior installed bundle is copied to
`.build/previous-install/MenuSprite.app`; build products and evidence are ignored.
Use only the installed app during permission review, not the backup/build copies.

The app/settings icon uses the existing Slim rail / Arranger artwork. The menu bar
uses `Resources/MenuBarArtwork.png`, an isolated sprite-and-rail PNG with a transparent
alpha channel, the original purple sprite, a light sky-blue rail and mint control for separation
at small sizes. It is downsampled without stretching or adding an app-icon tile;
its display height fills the menu bar with a two-point allowance, with the status
item widened to preserve the full composition. The 96-pixel export keeps it sharp
on Retina displays. The original raster masters and website assets are unchanged.

## Page and permission boundary

The 36 rows cover all categories in `../docs/permissions-page.md`, including
separate screen and audio-only modes and seven service/resource types. All rows
are initially visible. Search includes names, groups, purposes and explanations;
the optional Granted and Used by MenuSprite filters do not change system access.
Expand a row for scope, resource/target details, evidence API and timestamp.

Supported consent-only requests: Accessibility, Input Monitoring, screen recording,
Camera, Microphone, Speech Recognition, Contacts, Calendars (full), Reminders
(full), Photos (read/write), Location Services (when in use), and Notifications.
Requests do not start a capture session, recording, location update, data read or
notification delivery. Other categories use System Settings or explain why no
request is supported. Each request runs only from its explicit button.

Camera/microphone and other access changes can require a relaunch. A grant can
remain effective in the current process after its Settings toggle is turned off;
follow macOS's Quit & Reopen instruction. Boolean preflights do not distinguish
never requested from denied. `Unknown` is always rendered as **Check in System
Settings**. Unsupported values and unavailable capabilities never become denials.

Music and Focus use authorization-only queries without a request integration.
Bluetooth uses the static authorization property without creating a manager.
Clipboard reads only `accessBehavior`; it never reads clipboard content.
HealthKit checks service availability only. Native macOS ATT's placeholder
`notDetermined` result is not presented as a real pending consent state.
HomeKit and Motion & Fitness app APIs are unavailable to this native target;
browser passkey access is unavailable in this build.

Automation has **no configured targets**; no Finder or other target is invented.
Files & Folders shows the five named resource scopes as unknown without probing
them. Full Disk Access, Local Network, App Management, Developer Tools, Remote
Desktop and audio-only access have no general truthful preflight in this build.
No TCC database is read and no private resource is probed.

Launch at login uses `SMAppService.mainApp`. Register/unregister are explicit
actions; errors and approval requirements remain visible. Before first registration,
macOS can return `notFound`; the page preserves that and offers registration.
The owned power helper, administrator operations and hardware-control rows now
describe the optional helper without inventing a blanket grant. The remaining
resource rows stay **Not configured**; there are no selected-file bookmarks,
credential integrations or extensions.

Refresh runs on page open, app activation while the page is visible, explicit
Refresh and request completion. Location authorization changes use a delegate
after an explicit request. There is no repeating timer. Notification status reads
have a five-second one-shot timeout; failed refreshes retain previous evidence
and mark it stale. System Settings links are best-effort OS routes, not a public
stable deep-link contract. Every applicable row supplies the manual navigation
path, and a failed open falls back to the System Settings app.

## Compact paired readouts

The saved Network item shows upload above download. Fan & CPU temperature shows
highest reported fan RPM above the hottest mapped CPU temperature, in one item.
Choose **Two rows** in the sprite editor to use this layout for other reading pairs.
Only one CPU-usage reading remains in the personal configuration. New blank
sprites begin without a preselected CPU reading. Fan controls remain unchanged.

## CPU, RAM and Power panels

Click CPU or PWR for a ranked app/process list by recent CPU use or CPU-energy-derived
power. Power keeps the whole-Mac wattage separate from per-app CPU-only estimates.
See `../docs/cpu-power-panels.md`. Click RAM to open Memory: usage history, pressure, app/wired/compressed
memory, cached files, swap, and the top 30 apps/processes by memory footprint.
App helpers and known child processes are grouped. App collection runs every 5s
only while this panel is open and releases its data/icons when closed. See
`../docs/memory-panel.md` for attribution, checks and measurements.

## Power controls

Open **Power Controls** from the menu or Monitoring (Command-P). Ordinary keep-awake
is ready to use. Battery/closed-lid controls need the bundled developer helper
installer and administrator authorization; use Copy install command, then Refresh.
No privileged controls were activated during the build session. AlDente/Vorssaint
handover and real hardware acceptance remain manual. See `../docs/power-controls.md`
for installation, removal, recovery and exact limitations.

## Validation

```sh
swift test --package-path native

# Requires an enabled, visible RAM sprite; keeps your saved setup unchanged.
open ~/Applications/MenuSprite.app --args --memory-validate "$PWD/native/.build/validation/memory"

# Uses your active readouts, creates/releases only this app's idle-sleep assertions.
open ~/Applications/MenuSprite.app --args --power-validate "$PWD/native/.build/validation/power"

# Quit between modes; use a new evidence directory for each acceptance run.
open ~/Applications/MenuSprite.app --args --monitor-validate "$PWD/native/.build/validation/monitoring"
open ~/Applications/MenuSprite.app --args --monitor-measure "$PWD/native/.build/validation/monitoring-fresh"
```

Both monitoring modes use an isolated configuration file under their output folder.
The first exercises the UI, saved metadata, status items, boards, pause/re-enable,
counter re-priming and resource use. The second opens no windows and measures the
fresh resident host with paused, CPU/RAM and eight-reading configurations. It leaves
the host running; relaunch normally to review your own saved sprites.
During `--monitor-measure`, window-open requests are deferred until measurement
finishes so the benchmark remains a window-free resident-host run.

The earlier `--validate` and `--measure` modes remain for the Permissions page.
Use each launch mode separately, after quitting the previous instance. `--validate`
checks the real app bundle, complete catalog, search/filter/detail states, settings
handoff/activation, refresh and release on close, and renders only its own NSView
to PNG. It does not capture the screen. `--measure` skips that rendering and UI
driver entirely for an unwarmed baseline. Both record process RSS, physical
footprint and CPU-time deltas in three approximately 30-second phases, including
ten close/reopen cycles. They make no consent requests or registration changes.
There is no diagnostic work during an ordinary launch; only requested monitoring runs.

`report.json`, `observations.json` and `complete.txt` are written only to the explicit
directory; a failure writes `failure.txt`. Grant/deny/revoke and login-registration
checks are separate interactive tests. See `../docs/native-validation.md` for
actual observations, results and remaining system interactions.

## Source map

- `Sources/PermissionModel`: complete catalog, states, request eligibility, pure
  SDK mappings and stale-evidence behavior.
- `Sources/SystemMonitoring`: typed readings/catalog, Mach/IFMIB/IOKit samplers and
  read-only SMC decoding. No shell collectors, sensor writes or privileged helper.
- `MonitoringStore.swift`, `MonitoringView.swift`, `SpriteMenuBar.swift`: saved
  visual configuration, demand scheduling, menu-bar readouts and short history boards.
- `Sources/MenuSprite/MemoryBoard.swift`, `MemoryBoardController.swift`: on-demand
  app-memory collector lifetime and compact AppKit RAM panel.
- `Sources/SystemMonitoring/ProcessActivity.swift`: CPU Mach-time and CPU-energy
  interval calculations and rankings shared by the process panels.
- `Sources/SystemMonitoring/ProcessMemory.swift`: kernel process accounting and
  explicit app/helper/parent attribution, without a privileged helper.
- `Sources/MenuSprite/PermissionStore.swift`: public status reads, explicit consent,
  System Settings and service-registration operations.
- `Sources/MenuSprite/PermissionsView.swift`: native scrollable grouped page.
- `Sources/MenuSprite/MenuSpriteApp.swift`: menu icon, settings lifecycle and launch.
- `Sources/MenuSprite/NativeValidation.swift`: explicit local acceptance/measurement.
- `Sources/PowerControl`, `Sources/MenuSpritePowerHelper`: charge policy, scoped
  firmware controls, recovery journal and authenticated XPC service.
- `Sources/MenuSprite/PowerStore.swift`, `PowerView.swift`: native sleep assertions,
  event-based automation and controls UI.
- `Sources/AIAccounts`: Claude/Codex credentials (native keychain reads, Claude Code–style
  writes), the usage service (`Usage/`) and Claude Switcher–compatible switching (`Switching/`).
- `Sources/MenuSprite/AccountsStore.swift`, `AccountsBoard.swift`: AI Accounts board, its
  actions and the auto-switch loop.
- `Resources`: app declarations and hardened-runtime entitlements.
- `Tests/PermissionModelTests`: safety-critical status/level/category tests.

Framework boundaries were checked against the installed SDK and Apple's
[privacy category reference](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac),
[media consent guidance](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos),
[Full Disk Access guidance](https://developer.apple.com/forums/thread/835851),
[Service Management](https://developer.apple.com/documentation/servicemanagement/smappservice),
[pasteboard behavior](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum),
and [Local Network guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

## AI usage and accounts (local, 11 September)

Claude and Codex limits are ordinary readings in the **AI usage** category (`ai.*`), fetched
from the providers' own usage endpoints with the CLIs' logins — the source OpenUsage uses.
Quick start offers Claude usage and Codex usage sprites. Clicking a sprite made only of AI
readings, or choosing **AI Accounts…** from either menu, opens the AI Accounts board: saved
Claude and Codex accounts with Session/Weekly usage, Switch, Save current login, Add account…,
Remove and Auto-switch. Saved accounts are Claude Switcher's own (`claude-switcher:<email>` /
`codex-switcher:<email>` keychain items and `~/.config/claude-switcher/accounts.json`).

- The network is used at most every 5 minutes per login, sooner after a login change or Refresh.
  Keychain reads are native and never prompt; rotated tokens are written back only through the
  credential gate, and only if the store still holds the pair that was refreshed.
- A Claude switch writes the live item the way Claude Code does and confirms the replaced
  login's account with Anthropic before saving it. Running Claude Code sessions follow within
  about 30 seconds; running Codex sessions keep their account.
- MenuSprite never auto-switches while Claude Switcher is running.

`open ~/Applications/MenuSprite.app --args --background --show-accounts` opens the board at launch.
The sprite editor's **Color rule → AI usage pace** colors each limit independently:
weekly in 14.3% daily steps, five-hour in 20% hourly steps; green within the allowance,
amber up to one extra step, red beyond it or at 100%, gray for unknown/stale timing.
Choose **AI usage pace (% only)** to apply those colors only to the percent symbol;
the numbers and labels use the selected text color. This is Prerak's current setting.
Run `open ~/Applications/MenuSprite.app --args --background --usage-validate <directory>`
after quitting to capture live installed status-item evidence (35 seconds, no auto-switch).
Details: [AI usage](../docs/ai-usage.md) and [account switching](../docs/account-switching.md).
Tests: `swift test --package-path native --filter AIAccountsTests` (sandboxed). Live checks are
opt-in: `MENUSPRITE_LIVE_USAGE=1` (read-only usage) and `MENUSPRITE_KEYCHAIN_TESTS=1`
(throwaway keychain item).

## Battery & Power dashboard (local 0.5.0)

Click PWR or use MenuSprite’s **Battery & Power** menu item. To launch directly:

```sh
open ~/Applications/MenuSprite.app --args --background --show-energy
```

The dashboard contains animated power flow, battery graphs, an editable charge
band, Top Up / Discharge actions and CPU-energy app ranking. Charge actions require
the developer build’s installed helper and no competing charge controller. Opening
it does not change charging. Details and validation: [energy dashboard](../docs/energy-dashboard.md).
