# Native foundation validation — 8 September 2026

The first native MenuSprite app is implemented and installed at
`~/Applications/MenuSprite.app`. This is a local review build of the
foundation and Permissions & Access page. No utility tools or website changes
are included. Existing repository changes and the broader planning pack were preserved.

## Build and identity

- Swift 6.3.3, AppKit lifecycle, SwiftUI view; no external runtime dependencies.
- macOS 26.0 minimum; tested on macOS 26.6.2 (25G83), arm64, macOS SDK 26.5.
- `in.prerakgada.MenuSprite`, version 0.1.0 (1), development-signed with
  `Apple Development: Prerak Gada (X38RF8Q3T4)`, team `RC63N3VU27`.
- Hardened runtime with camera/audio-input capability declarations. No App Sandbox,
  privileged helper, system extension, capture session or background collector.
- `codesign --verify --strict` and Info.plist validation passed on the installed app.
  Rebuilds/install preserved the designated signing requirement. App bundle: 2.6 MB.

Launch with `open ~/Applications/MenuSprite.app`. Build/review commands are in
[`native/README.md`](../native/README.md). Local evidence is deliberately ignored
under `native/.build/validation/`; ordinary app launches write no diagnostic files.

## Verified behavior

- All **36 categories/access rows** are present. All is the initial filter; unused
  and unavailable entries remain discoverable. Search, filters, expansion, empty
  results, light/dark rendering and scope details were checked in the native view.
  Final UI review also scrolled to the bottom service rows, closed the window with
  Command-W and reopened it from the resident host with Command-comma. Reopening
  restored All and a fresh check time.
- The installed app itself queried authorization, not a Terminal process or
  unsigned Swift executable. Initial Camera, Microphone, Speech, Contacts,
  Calendars, Reminders, Photos, Bluetooth, Music, Focus, Location and Notifications
  all reported Not requested. Clipboard reported Always allow through its
  dedicated behavior API; this was not inferred from clipboard contents.
- Accessibility/input/screen preflights reported Not granted without inventing
  request history. Full Disk Access and the other unqueryable categories stayed
  Check in System Settings. HealthKit reported unavailable on this Mac.
- Native evidence captured **17 passing lifecycle/page checks** in the initial
  run: complete catalog, identity, no explicit requests on open, unknown handling,
  separate audio mode, search, five file scopes, feature-use separation, empty
  search, explicit refresh, settings opening, return refresh, closed window/store
  release and fresh checks after reopening.
- **10 unit tests passed**, including restricted/limited/write-only/provisional
  states, unknown SDK values, request eligibility, complete catalog, clipboard
  semantics and stale-evidence preservation. Synthetic cross-platform enum values
  in tests do not imply those consent options are available on this Mac.
- Source review found no capture, recording, private-data probe, Bluetooth scan,
  location update, clipboard-content read, Apple event to another app, TCC database
  read or repeating permission timer. The opening sequence made status-only calls.

## Real system interactions

**Camera:** the explicit Request Access button moved the app from Not requested
to Granted. The Camera settings route opened the actual Camera pane, where
MenuSprite had its own entry. Turning that entry off produced macOS's sheet
explaining that access persists until the app quits. After quitting/relaunching,
MenuSprite reported **Not granted** and no longer offered another first-request
button. The test grant was left off. No camera or capture session was started.

An early generic accessibility-script toggle did not complete the macOS interaction;
it was not accepted as evidence. Native UI interaction and a fresh app process
established the result. The UI automation service crashed once during settings
inspection; it recovered, and there was no MenuSprite crash report.

**Launch at login:** macOS initially returned Service not found before a service
record existed. Explicit registration succeeded and the app showed Enabled.
Explicit unregister succeeded; a later fresh launch confirmed **Not registered**.
It was left disabled. No helper was installed.

**Settings handoff:** Full Disk Access and Camera panes were verified by their
actual system window titles. The page refreshed on return/activation, and explicit
Refresh advanced the check timestamp. Other section links are best effort, with
a visible manual path and generic System Settings fallback; they are not claimed
as individually verified deep links.

## Resource measurements

The resource-only native run launches the installed release app without rendering
diagnostic screenshots or attaching a UI driver. It reads its own `TASK_VM_INFO`
(resident bytes and physical footprint) and `getrusage` CPU-time deltas. Each phase
is approximately 30 seconds; actual elapsed time is recorded because macOS can
coalesce the sleep. CPU is expressed as a percentage of **one core**. There are
no owned helper processes to add.

| Phase | Elapsed | Resident memory | Physical footprint | Average CPU / one core |
| --- | ---: | ---: | ---: | ---: |
| Page open after fresh launch | 31.96 s | 94.92 MiB | 36.16 MiB | 0.5729% |
| Page closed | 31.46 s | 94.75 MiB | 33.44 MiB | 0.0041% |
| Closed after ten reopen cycles | 31.87 s | 97.72 MiB | 34.30 MiB | 0.1413% |

All ten resource-run identity/catalog/release checks passed. Evidence:
`native/.build/validation/resources/report.json`, `observations.json` and
`complete.txt` (PID 65583). Physical footprint rose 0.86 MiB between the first
closed measurement and the post-cycle measurement; the test does not establish
a multi-hour leak guarantee. Resident memory includes shared mapped pages and
framework caches that do not disappear merely because the window closes. The
first open interval includes post-launch settling; it is not a steady-state
zero-CPU claim. These are observations of this foundation, not an accepted
performance budget or measurements of future tools. The old planning numbers
were not used as benchmarks.

An additional external `top` sample from 09:43:54 to 09:44:24 observed the warmed,
open page at **0.0% CPU at top's displayed precision**, 38M in its memory column,
three threads and unchanged displayed cumulative CPU time (1.68 seconds). This
supports low steady idle work but does not assert literally zero CPU. Evidence:
`native/.build/validation/resources/steady-open-top.txt`.

## Remaining system/manual acceptance

- Other permission consent sheets, denial/revocation paths and notifications
  delivery options have not all been exercised. No blanket request/reset was used.
- Managed restrictions, limited photo/contact access, write-only calendars,
  global Location Services off and notification-service timeout were not induced
  on this Mac; mappings/stale behavior are covered by unit checks where applicable.
- Actual logout/login, OS reboot, sleep/wake, additional displays and a multi-hour
  session remain untested. Registration/unregistration is verified; startup at a
  real login is not claimed.
- MenuSprite relies on public per-app APIs and honest unknowns. It cannot grant or
  revoke system access itself; it cannot establish a universal Full Disk Access,
  folder, Automation or Keychain grant. No other application's grants are modeled.
- This arm64 development build is for local review. Notarization, distribution,
  Intel and older macOS support have not been validated. The signing certificate
  expires on 3 November 2026 and needs deliberate renewal/identity review then.

Apple's [media authorization guidance](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos),
[Full Disk Access guidance](https://developer.apple.com/forums/thread/835851) and
[Service Management reference](https://developer.apple.com/documentation/servicemanagement/smappservice)
informed the implementation; SDK headers supplied exact native-platform availability.
