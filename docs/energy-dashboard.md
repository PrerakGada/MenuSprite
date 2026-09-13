# Battery & Power dashboard — 10 September 2026

Implemented locally in MenuSprite **0.5.0 (9)**. Click the existing **PWR**
menu-bar readout, or choose **Battery & Power** from MenuSprite’s menu (Command-B).
The screenshot supplied by Prerak and AlDente’s documented Power Flow behavior
informed this dashboard. This is not a claim of complete AlDente Pro parity.

## Interface and behavior

- Limit, Discharge and Top Up controls above a live battery-level bar.
- The limit editor exposes both the charge ceiling and lower resume threshold.
  Dragging edits MenuSprite’s saved target; **Apply limit** is explicit. The bar
  and charge chart distinguish an unapplied target from active MenuSprite control.
- A live flow diagram with adapter DC input, battery discharge, system draw,
  battery charging, and an explicitly calculated difference. Moving markers show
  observed flow; unknown and zero-power branches do not animate.
- Power Consumption, Battery Temperature and Battery Level charts. The power
  chart shows its observed average; the battery chart marks MenuSprite’s limit
  or inactive target. Real sample counts are visible. No synthetic past is filled.
- Highest accessible app CPU-energy consumer, followed by the full ranked list
  of up to 30 apps/process groups. This is CPU energy, not Apple’s Energy Impact
  score or total per-app electrical power; GPU/display/other components are excluded.
- The grid button controls chart visibility and flow animation and exposes Refresh.
  Preferences persist. Customize opens the existing sprite editor; Power Controls
  opens helper setup and the existing keep-awake settings. Escape, Close and outside
  interaction dismiss the ordinary panel.

The screenshot’s exact numeric values, OS “significant energy” designation and CPU
component split are not reproduced as invented readings. Native macOS controls
and MenuSprite’s existing design are used; no AlDente assets or code are embedded.

## Data and resource scope

The dashboard uses the **existing shared SystemSampler** and MemoryBoardStore.
An enabled PWR sprite keeps bounded charge/temperature/power history using the
shared sampling schedule. Opening the panel adds demand for its additional
readings; closing removes that panel demand,
cancels process collection and releases interval baselines, app icons, observers
and animation objects. No extra permanent sampler runs for this dashboard.
Existing enabled menu-bar readouts retain their selected refresh intervals.

Energy histories are bounded to 900 real points per reading in memory (about
30 minutes at the default two-second interval). They begin when the Power sprite
is enabled, remain useful between panel openings, and stop when no feature needs
them. Other monitoring histories retain their existing 60-point limit.
Long gaps and recorded failed samples break the chart line. Missing, nonfinite,
out-of-range or stale readings remain unavailable rather than becoming zero.
The page does not collect screenshots, open private files or request permissions.

Power values come from the existing PSTR and PDTR firmware readings and signed
battery voltage × current. A positive difference is `adapter − system − battery`
and is labeled as unaccounted loads/losses. If inputs are missing or do not balance,
the difference is unavailable. Independent sensor observations are not a wall-meter
measurement and are not forced to add up.

Motion uses a native AppKit drawing surface, refreshed at 24 frames per second
only while needed. A cached static flow image avoids rerendering all labels on
every animation frame. It stops when the flow is offscreen,
the window is occluded, the sprite is paused, the panel closes, or Reduce Motion
is enabled. The scrolling document is drawn directly rather than backing its full length
with animated layers. Only the flow rectangle redraws for motion; metrics still
use their independent sampling schedule. App icons load only for visible rows.
A one-shot expiry also clears stale animation state if sampling stops.

## Charge controls and helper boundary

The buttons use the existing PowerStore / PowerController charge-band, top-up and
forced-discharge backend. Top Up returns to the selected band; cancelling Top Up or
Discharge returns to maintaining that band. No artificial load is used to discharge.
The helper’s watchdog, journal/recovery behavior and stop-on-sleep/unplug/exit rules
are unchanged. See [Power Controls](power-controls.md) for those limitations.

On this Mac, AlDente was running and MenuSprite’s administrator helper was absent
when development began. Charge actions are disabled with the reason visible.
The dashboard does not quit AlDente, install a helper, or activate charging controls
on opening. A handover was requested separately for live hardware acceptance.
Neither a disabled button nor a passing policy test proves a hardware write.

The existing public preview build still excludes privileged charging/lid control.
This dashboard is installed in the local development build; the public 0.4.0
release and website download have not been replaced by this native feature work.

## Validation

```sh
swift test --package-path native
./scripts/build-native.sh --install
open ~/Applications/MenuSprite.app --args --energy-validate "$PWD/native/.build/validation/energy-review"
```

The explicit validation mode uses isolated configuration and power preferences,
checks the actual signed app’s readings, ranking, control availability, animation,
Reduce Motion, Refresh, release of collectors and demand, and RAM/CPU regressions.
It measures physical footprint, RSS and process CPU with the panel closed/open.
Its panel stays visible during profiling so unrelated user activity cannot turn
an “open” measurement into a closed-panel sample; normal outside-dismiss behavior
is checked separately. CPU percentages are for one core and exclude WindowServer’s
compositor work. These are short observations, not battery-life guarantees.

AlDente’s feature reference: [Power Flow and charge controls](https://apphousekitchen.com/aldente-overview/features/).

Rendering reference: [Apple NSView layer ownership](https://developer.apple.com/documentation/appkit/nsview/wantslayer).

## Current verification and measured cost

- 49 automated tests passed; one optional live-source probe skipped (50 total).
- 20 native checks passed in `native/.build/validation/energy-050-final-acceptance/`:
  real readings and CPU-energy ranking, disabled controls with reasons, motion /
  Reduce Motion, Refresh, cleanup, demand release, and RAM/CPU panel regressions.
- Native AppleScript UI checks exercised opening through the app menu, the target
  editor, the enabled target slider, disabled Apply/Stop actions, grid options,
  toggling Power Flow off/on and restoring it, Refresh, and outside-app dismissal.
  Accessibility exposes the actual slider, stepper, checkbox and button roles.
- The existing monitoring configuration hash remains unchanged:
  `8f44bdc30a4d8135d1fe3913741d3b851e4a3f8132aeb425e5c439d9e9cf20cb`.
- The installed app is still development-signed under the same designated
  requirement. AlDente was not quit and no privileged helper was installed.

Final native observation with the default five readouts (nine requested metrics,
including bounded battery history):

| State | Physical footprint | RSS | CPU, one core | Sample |
| --- | ---: | ---: | ---: | ---: |
| Fresh process, panel closed | 19.00 MiB | 67.61 MiB | 1.77% | 12.1 s |
| Dashboard open with motion | 230.72 MiB | 101.41 MiB | 6.29% | 15.0 s |
| Dashboard with motion paused | 57.66 MiB | 101.91 MiB | 1.62% | 10.2 s |
| Closed after review | 62.83 MiB | 106.19 MiB | 1.37% | 12.1 s |

**Open-panel graphics memory remains above the project's desired footprint.**
This is a known limitation, not a completed performance target. Reversed-order
measurements also showed an initial peak with motion disabled, so the entire
increase cannot honestly be attributed to the animation alone. Closing releases
the dashboard/collector and returns to ordinary menu-bar sampling; warmed system
and drawing caches mean footprint does not immediately return to the cold value.
Earlier experimental renderers are retained only in ignored diagnostic folders;
the figures above describe the final AppKit renderer.

Charge-control write/readback, a full charge/top-up/discharge cycle and root XPC
acceptance still require the user's approved handover from AlDente and administrator
installation. Calibration, scheduling, heat-protection and complete AlDente Pro
feature parity are not claimed by this dashboard slice.
