# CPU and Power process panels — 9 September 2026

Local 0.5.1 uses the shared [process context labels](process-context.md) to make
runtime and VM rows identifiable without changing their totals or attribution.

Implemented in MenuSprite **0.3.2 (6)** by Prerak's request to extend the RAM panel
with CPU and Power process lists. Click the existing **CPU** or **PWR** readout.
The saved readout configuration, native identity and website are preserved.

Both use the same compact AppKit panel, app icons, helper grouping, scrolling,
Refresh, Settings, Activity Monitor and close behavior as Memory. Their process
lists show the top 30 accessible consumers, sample an initial one-second interval,
then update every five seconds only while open. Closing releases the collector,
interval baselines, records and icon cache. There is no privileged helper or new
permission request. RAM continues to show memory footprints.

## CPU

The headline and graph show **whole-Mac CPU usage**, averaged across logical cores,
with user/system/idle time, load averages and logical core count beneath.

Rows rank recent process CPU time. **100% means one occupied core**, so a
multithreaded app can exceed 100%. The meaning is stated directly above the list.
CPU deltas use `ri_user_time + ri_system_time` from `proc_pid_rusage`, converted
from Mach absolute-time units using `mach_timebase_info`, then divided by actual
elapsed sample time. They are not lifetime CPU averages or clamped to 100%.

## Power

The headline remains the actual **PSTR whole-Mac power sensor**. Other rows show
adapter input (PDTR), signed battery flow, power source, battery charge, Low Power
Mode and whole-Mac CPU activity. Adapter wattage rating is not substituted for
measured draw.

The process list is explicitly **CPU power**, derived from the kernel's
`RUSAGE_INFO_V6.ri_energy_nj` CPU-energy accounting: delta nanojoules divided by
elapsed seconds, converted to watts/milliwatts. The visible note calls it a CPU
energy estimate and excludes GPU, display and other components. These values
are not each application's total electrical draw and do not sum to PSTR. They
are not a fabricated allocation of whole-Mac watts or Activity Monitor's Energy
Impact score. The current Mac exposes nonzero energy counters; that capability
is verified again in the actual native app.

## Truthfulness and attribution

A first sample, reused PID, missing/zero-only energy counter, counter reset or
invalid time interval does not become a fake zero. Once an energy counter has
actually reported a positive cumulative value, an unchanged value can produce a
valid idle zero. If CPU energy is not exposed, Power retains the system readings
and explains that the per-app list is unavailable. V4 fallback preserves memory
and CPU without treating its absent energy fields as measurements.

Grouping uses the existing [Memory panel](memory-panel.md) rules: outer app bundle
and observed parent chain, with separate shared/unattributed processes. Known
per-process rates are summed; **≥** marks a partial app subtotal when some members
lack comparable readings. Hover shows member values and explains missing members.
Protected, exited and not-yet-comparable processes are counted in the coverage
note. Short-lived tasks that exit between snapshots cannot be fully attributed.

## Validation

`swift test --package-path native` covers Mach time conversion, multicore values,
elapsed-time normalization, PID reuse, counter resets, absent energy, valid idle
zero, grouping and partial subtotals, in addition to the previous memory/permission/
power-policy checks.

The installed-app validation command is:

```sh
# Quit the existing app before launching the validation mode.
open ~/Applications/MenuSprite.app --args --process-panels-validate "$PWD/native/.build/validation/process-panels"
```

It uses the actual saved CPU/RAM/PWR setup, verifies sorted live rows and exact
member sums, native CPU-energy availability, CPU Mach-time conversion against
independent `getrusage`, refresh and close cleanup, and renders the panels. It
measures the app with panels closed, CPU open, Power open and after closing.
Raw process accounting and ranked values are written only to the explicit local,
ignored evidence directory; normal use does not persist process activity.

**41 automated tests passed; one optional live-source test was skipped.**
**30/30 native checks passed** in the installed app, including the RAM regression
checks, live CPU and CPU-energy rankings, exact member sums, refresh, collector
release and independent CPU-timebase verification. CPU and Power views were
rendered and visually reviewed; CPU Refresh was also exercised through native UI
automation. No hardware control or privileged installation was performed.

| State | Physical footprint | RSS | CPU, one core |
| --- | ---: | ---: | ---: |
| Fresh host, panels closed | 14.56 MiB | 70.55 MiB | 0.599% |
| CPU panel open | 47.44 MiB | 100.69 MiB | 1.942% |
| Power panel open | 47.78 MiB | 104.39 MiB | 1.821% |
| All panels closed after review | 42.74 MiB | 103.84 MiB | 0.556% |

Each phase lasted about 15 seconds. These are short observations on this Mac,
not guaranteed budgets. Later phases include warmed AppKit/icon caches. App-list
collectors and their interval baselines were released on close. Protected-process
coverage, helper attribution and CPU-only energy scope remain the limits described
above; GPU or complete per-app electrical draw is not claimed.
Evidence: `native/.build/validation/process-panels-032/`.

Primary sources: Apple's [rusage structure](https://developer.apple.com/documentation/kernel/rusage_info_current),
[kernel rusage mapping](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c),
[task power accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c)
and [CPU recount energy](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/recount.c),
plus the installed macOS 26.5 SDK headers. The kernel uses Mach units for CPU time
and CPU recount energy for the nanojoule fields; their different units are preserved.
