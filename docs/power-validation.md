# Power-control validation — 8 September 2026

Installed MenuSprite **0.3.0 (4)**, `in.prerakgada.MenuSprite`, unchanged development
signer/team and designated requirement. ARM64, macOS 26.6.2 (25G83), macOS 26.5 SDK.
This records the first control implementation, with privileged acceptance pending.

## Verified

- **31 automated tests passed; one optional live-source test skipped** (32 total).
  Coverage includes permission-state preservation, monitoring math, stacked/no-icon
  layout, old-config migration, whole-watt formatting, charge hysteresis, top-up,
  discharge cutoff, invalid requests, partial writes, failure while updating an
  already-owned value, crash recovery, unknown original firmware state, corrupt
  journals, watchdog/unplug restoration and preserving a pre-existing sleep override.
  Hardware writes/pmset in these recovery tests use injected fakes.
- **11/11 native checks passed** inside the installed, signed app. Actual saved
  configuration has separate CPU/RAM/PWR items, stacked labels, heavy white values
  and no readout glyph. PSTR produced real system watts. On launch, battery/lid/
  keep-awake controls were off. Native idle-system and display assertions were
  created, independently found under MenuSprite's PID by IOPMCopyAssertionsByProcess,
  released by Stop, and released after a timed session expired.
- App and helper compile in release mode; bundle/embedded-helper signature checks
  and exact expected helper requirement passed. Installer/removal scripts pass bash
  syntax checks. Packaged helper/install/removal entry points correctly reject
  execution without administrator privilege; the read-only helper probe works.
  Main app identity stays unchanged. This does **not** verify root
  XPC authentication/rejection or administrator installation.
- Native Power Controls view rendered from the installed app and visually reviewed.
  It showed actual battery level/source, AlDente conflict, helper not installed,
  disabled dependent actions, and system sleep already disabled outside MenuSprite.
  App-owned diagnostics report its window visible. The external native UI driver
  could not attach (`cgWindowNotFound`), so mouse/keyboard interaction through that
  driver is not claimed. No screenshots of other applications or private content
  were captured; the diagnostic render is MenuSprite's own NSView.
- Read-only capability probe from the actual app: CHTE/CHIE supported sizes,
  battery 81% on battery at the measurement end, charge allowed, adapter enabled.
  Those changing values are observations, not saved assumptions. Key detection
  does not prove write support. AlDente and Vorssaint continued running.
- `pmset -g` showed SleepDisabled 1 before and after checks, with Vorssaint's
  existing sleep assertion. MenuSprite made no global sleep-setting writes and
  installed no root helper. No TCC prompts or permission changes were triggered.

## Measured resource use

Fresh installed process, current three readouts at **2-second intervals**, no
windows opened during measurement. TASK_VM_INFO physical footprint/RSS and
getrusage CPU-time deltas; each phase roughly 25–26 seconds. CPU is percentage
of one logical core, not whole-machine utilization.

| Phase | Physical footprint | RSS | CPU, one core |
| --- | ---: | ---: | ---: |
| CPU + RAM + PWR, controls off | 14.11 MiB | 69.42 MiB | 0.348% |
| Same readings, system + display keep-awake | 14.61 MiB | 70.14 MiB | 0.446% |
| Same readings after stopping keep-awake | 14.69 MiB | 70.22 MiB | 0.377% |

These are short local observations, not guaranteed budgets or overnight results.
Opening the UI warms SwiftUI/AppKit caches and increases footprint. The privileged
helper was not installed/running, so **no actual active-helper resource benchmark**
is claimed. Later recovery hardening and diagnostic-render changes do not add a
resident timer to the GUI. The historical monitoring benchmarks are retained in
`monitoring-validation.md`, not substituted for these measurements.

Local evidence (ignored build artifacts):

- `native/.build/validation/power-030/report.json`
- `native/.build/validation/power-030/native-power-probe.json`
- `native/.build/validation/power-030/active-readouts.json`
- `native/.build/validation/power-030-ui/power-controls.png`
- `native/.build/validation/power-030-ui/ui-state.json`
- `native/.build/validation/power-030-ui/readout-{CPU,RAM,Power}.png`

## Still manual / unverified

Administrator install/upgrade/uninstall, root XPC peer enforcement, hardware
write/readback on this Mac, a complete charge-band/top-up/discharge cycle, hardware
recovery after helper/app crash, physical lid closure, AC removal, thermal stop,
real sleep/wake and lock/selected-app/display automation. The existing battery and
sleep utilities must be explicitly handed over before those tests. Ordinary
keep-awake and automatic assertion expiry have native proof; these other paths do
not. Charge limits stop at system sleep in this first version.

Installation, removal, firmware limitations and recovery instructions are in
[Power Controls](power-controls.md). This is a local developer build, not a
notarized distribution or a claim of complete AlDente/Vorssaint parity.

## Rule-review findings from the subsequent review

The keep-awake rules remain a first implementation. Review identified that manual
timer expiry pauses automatic rules, the pending expiry is not cancelled on system
sleep, and session switching does not maintain an explicit inactive-session state.
The timer and session-state fixes were implemented during 10 September public-release
preparation and verified in the signed public bundle (see `release.md`). Physical
lock, display and sleep/wake acceptance remains separate; hardware-control validation
is still pending and the public preview excludes the privileged helper.
