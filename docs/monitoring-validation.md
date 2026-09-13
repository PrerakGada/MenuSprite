# Monitoring validation — 8 September 2026

## 0.3.3 paired readouts

The mixed Network sprite contained an extra CPU reading. That reading was removed,
Network was changed to upload above download in one column, and a Fan & CPU
temperature item was added with highest reported fan RPM above CPU temperature.
The existing CPU/RAM/PWR items were preserved. The personal configuration was
backed up as `monitoring.before-two-rows-20260909-083054.json` in Application Support.

**42 tests passed; one optional live-source probe skipped** (43 total). The new
geometry/persistence checks cover two rows, no overlap, shared right edge, bounds
at 22/24/28 points, and additional reading pairs in subsequent columns.
**14/14 installed-app checks passed**, including one CPU-usage instance, one Network
item, one Fan/CPU-temperature item, real readings and the fastest-fan calculation.
Observed fan readings were 2320 and 2497 rpm; the combined reading was 2497 rpm.
CPU temperature was 46.92°C at that sample. Zero RPM remains valid; unavailable
sensors are not manufactured as zero. The native renderer's images were reviewed.
The external UI driver could not attach to the settings window in this run, so
mouse interaction with the editor's new layout choice is not claimed as tested.

Five readouts at 2 seconds, settings and panels closed: **16.36 MiB physical
footprint, 73.20 MiB RSS, 0.540% of one core** over 15.53 seconds. This is a short
local observation, not a guaranteed budget. No process-list collector, fan-control
write or permission prompt was started. Evidence is in the ignored directory
`native/.build/validation/two-rows-033/` (`report.json`, `active-sprites.json`,
`readings.json` and the two renderer PNGs).

## 0.3.1 RAM panel

RAM now opens a dedicated Memory panel with its breakdown and ranked app/process
footprints. See `memory-panel.md` for attribution rules, native checks, collector
lifetime and new resource measurements. Other readout boards remain unchanged.

## 0.3.0 readability and power follow-up

The active configuration now has separate CPU/RAM/PWR items, no readout icons,
heavy white values and labels above them. It was applied to the installed app.
The prior combined configuration is backed up in Application Support. CoreText
glyph-bound fitting makes room for the full 14-point value rather than shrinking
it to fit a font's unused line spacing. Focused tests cover no-icon width, 14-point
fit, persistence/migration, white non-template rendering and whole-watt formatting.
See `power-validation.md` for native checks and a fresh three-readout measurement.

## 0.2.1 layout follow-up

Added the per-sprite **Labels above values** layout after the supplied compact
RAM/CPU reference. The native menu button and live editor preview use the same
AppKit text drawing. Geometry checks verify label/value separation, fitting within
22/24/28-point bars, and less width than the corresponding inline CPU/RAM example.
Migration and round-trip checks preserve old inline settings and persist the new mode.
The native UI was checked with live CPU/RAM values, saved as stacked, quit/reopened,
and confirmed still stacked; the existing System sprite was then restored to inline.
No new sampler or timer was introduced. The measurements below remain the earlier
0.2.0 monitoring baseline, not a new benchmark of the layout change.

MenuSprite **0.2.0 (2)** is a local development-signed arm64 app installed at
`~/Applications/MenuSprite.app`, using the existing `in.prerakgada.MenuSprite`
identity and signing requirement. Acceptance device: macOS 26.6.2 (25G83), macOS
SDK 26.5, Swift 6.3.3, Apple M5 Max, 18 logical cores and 36 GiB installed memory
(live OS values). The earlier foundation baseline is retained in `native-validation.md`.

## Functional evidence

The final installed-app acceptance runs use isolated configuration files under
`native/.build/validation/`, so test sprites do not overwrite normal user settings.
They make no permission requests, install no helpers and perform no hardware writes.

Verified in the native app and UI:

- Catalog covers CPU, memory, network, disk, GPU, battery, system state and available
  SMC readings. This Mac's captured catalog contains **728 entries: 56 basic, 672
  advanced**. That includes 18 individual CPU cores, per-interface counters and
  firmware keys. It does not mean 728 separate physical sensors.
- Readings, units, source details, search, category/Advanced filtering and native
  editor layout were inspected. Source values were queried by the signed installed
  app, separately from the earlier command-line source probe.
  A normal fresh launch was also checked for immediate Advanced `en0` search;
  full received/sent totals appeared without first opening the Network category.
- A real UI flow searched **Fan**, chose **+ → New sprite**, named it **Fans**,
  selected the fan icon, added Fan 2, changed refresh to **5 seconds**, and saved.
  The resulting sprite displayed both actual RPM values.
- Multiple native status items, menu-board opening, current readings and bounded
  history were exercised. Hiding an enabled sprite kept sampling; disabling it
  stopped its monitoring while allowing a visible Paused item.
- Closing the monitoring window released it and removed its visible-preview demand.
  All-disabled/window-closed held the sampler count constant. Re-enable re-primed
  delta readings instead of fabricating rates across the paused interval.
- Configuration round-trip preserved readings/order, appearance, units and interval.
  Cached dynamic sensor metadata was also tested: a separately loaded saved fan
  started reporting RPM **without opening or discovering the library**.
- Sleep/wake callbacks were exercised without putting the user's Mac to sleep.
  Histories remained bounded to 60 actual samples per reading.
- Permissions & Access stayed separate and was not opened by monitoring validation.
  Its 36-category catalog and status mappings retain their existing unit checks.

**26 native acceptance checks and 16 source/unit tests passed.** Results are recorded in
`native/.build/validation/monitoring-02/report.json` and
`native/.build/validation/monitoring-tests-final.txt`. Native view renderings are in
the same run directory. Those PNGs render only MenuSprite's own views; they do not
capture the desktop. A real native-UI screenshot was also used to verify the editor,
because cached view renderings do not reproduce every system sheet material.

## Source correctness checks

- CPU tick arithmetic includes nice time, zero-length intervals and UInt32 wrap.
- Counter tests cover first samples, pauses, resets, zero activity and values above
  4 GiB. An independent `netstat`/native C-probe comparison caught narrowed totals
  from the routing-message path on this Mac. The implementation now uses **IFMIB
  IFDATA_GENERAL**, whose full-width absolute totals matched the OS tool between
  successive reads. Network membership changes clear the aggregate rate baseline.
- Mach VM counters use the actual page size. Speculative pages are already in
  `free_count` and are not double-counted. Memory classifications and formulas are
  described in `system-monitoring.md`; pressure is the kernel's reported level.
- GPU utilization and memory fields were confirmed in IOAccelerator statistics.
  Missing driver fields remain unavailable.
- Battery source/charging, estimates, signed current, voltage, temperature and
  capacity/design ratio use their distinct reported fields; adapter rating is not
  substituted for power draw.
- Read-only SMC discovery worked in the installed app: both fans, CPU/GPU temperature,
  `PSTR` system power and `PDTR` adapter input. Known float/fixed-point decoding and
  invalid-value handling have unit coverage. Firmware keys remain explicitly
  hardware-dependent; raw keys can be limits/reference values, not separate sensors.

## Resource measurements

Two kinds of runs are kept separate:

1. **After using the UI:** the acceptance harness opens the catalog, editor and board,
   renders diagnostic images, then closes them. This includes warmed AppKit/SwiftUI
   caches and diagnostic rendering overhead.
2. **Fresh resident host:** `--monitor-measure` never opens a window/editor/board or
   renders screenshots. It measures a login-like resident host with paused, CPU/RAM
   and eight-reading configurations.

Both use the installed release app's `TASK_VM_INFO` resident/physical-footprint values
and `getrusage` CPU-time deltas over approximately 30 seconds. CPU is a percentage
of one core. No helpers need to be added. Exact elapsed times and all samples live
in the run's `report.json`. Old planning figures are not acceptance budgets.

Final fresh-host run (`monitoring-fresh-04`, PID 58173):

| Configuration, no windows opened | Physical footprint | Resident memory | Average CPU / one core |
| --- | ---: | ---: | ---: |
| All sprites paused | 15.14 MiB | 64.59 MiB | 0.0073% |
| CPU + RAM, visible sprite, 2-second interval | 16.06 MiB | 68.30 MiB | 0.3281% |
| Eight readings, visible combined sprite, 2-second interval | 17.81 MiB | 70.95 MiB | 0.7950% |

The paused interval recorded **zero sampling calls** and zero requested readings.
All five fresh-host checks passed, including confirmation that no catalog-window
discovery ran during measurement. The diagnostic mode suppresses window-open
requests until measurement ends, so a LaunchServices reopen cannot contaminate this
case. It does not change normal app behavior.

After using and rendering the native catalog/editor/board (`monitoring-02`, PID 42570):

| Configuration after closing UI | Physical footprint | Resident memory | Average CPU / one core |
| --- | ---: | ---: | ---: |
| Paused after editor/board checks | 71.03 MiB | 146.95 MiB | 0.6645% |
| CPU + RAM visible, 2-second interval | 65.75 MiB | 114.88 MiB | 0.4226% |
| Eight readings sampled, sprite hidden, 2-second interval | 65.22 MiB | 114.56 MiB | 0.3371% |
| CPU + RAM after five reopen/close cycles | 67.77 MiB | 127.61 MiB | 1.0238% |

The post-UI samples include native framework caches and UI/snapshot cleanup; they
are not substituted for the fresh resident-host figures. Window objects were
released and sampler demand stopped correctly, but a multi-hour leak/idle guarantee
is not established. Resident memory includes shared mappings, so it differs from
physical footprint. These short samples are measured baselines, not accepted budgets.

## Remaining limits

- Actual sleep/wake, reboot/login, a multi-hour soak and other Macs/OS versions have
  not been accepted. Callback behavior and local persistence are tested separately.
- Some sensor/driver interfaces are firmware-dependent. CPU-temperature aggregation
  is mapped for the current M5 family; other machines can select readable raw keys
  without being shown an invented CPU mapping.
- The catalog is comprehensive for the implemented readers, not a claim to expose
  every private kernel counter. Per-process attribution, SMART health, clock-frequency
  estimation, privileged power sampling and controls are outside this step.
- The first System sprite is enabled on an ordinary first launch. Hidden enabled
  sprites still monitor; disable them to stop their work. Open library/editor views
  independently sample the readings being inspected.
- This remains a local development build, not a notarized public release. Existing
  signing, website and broader product-boundary limitations still apply.
