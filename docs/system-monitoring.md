# System monitoring and configurable sprites

Implemented by Prerak's explicit follow-up request on 8 September 2026. Native app
version **0.3.3 (7)**. The accepted purple-sprite/light-blue-rail app identity remains.

## Use it

Open `~/Applications/MenuSprite.app`, or choose **Monitoring & Sprites…** from its
menu-bar icon. The first run creates one **System** sprite with CPU and RAM usage.
Subsequent launches restore your configuration. Prerak's current saved setup has
separate CPU, RAM and PWR sprites, with small labels above heavy white values and
no readout glyphs. Network is one two-row item (upload above download). Fan & CPU
temperature is another two-row item (highest reported fan RPM above CPU temperature). PWR uses actual PSTR system power. The main app icon stays available.

1. Find a reading by name/category. Advanced includes individual cores, interfaces
   and firmware keys.
2. Click its **+** and choose **New sprite with this reading…** or an existing sprite.
3. Configure name, icon, selected readings/order, refresh interval, text size/weight,
   color, Show icon in menu bar, labels, units, decimal places, Celsius/Fahrenheit and network bytes/bits.
   **Layout → Labels above values** puts each small label above its own value
   (for example CPU above 13%, RAM above 85%) to reduce width. The preview uses
   the same native drawing as the menu bar. Text fits within the bar's height;
   **Two rows** puts each consecutive pair of readings in one column, first on top
   and second beneath, with compact labels beside their values. **Inline labels**
   preserves the original arrangement. Existing saved sprites
   preserve their saved layout until changed. The requested personal setup is already
   applied and live; it is not just an editor option.
4. Save. Each sprite supports up to eight readings; create separate sprites when useful.
5. Click its menu-bar readout for the latest values and up to 60 history samples.
   RAM/memory-only sprites open a dedicated Memory panel with pressure, app/wired/
   compressed memory, cached files, swap and ranked app/process memory. See
   `memory-panel.md`. CPU and Power have matching ranked process panels;
   `cpu-power-panels.md` defines their percentage and CPU-power scope. Other/mixed
   sprites retain their configured reading boards.

Quick-start choices cover CPU, Memory, Network, Battery, and Power & temperature.
**Enabled** controls monitoring. **Show in menu bar** controls visibility. A hidden
enabled sprite continues monitoring; a visible disabled sprite reads Paused. The
library and editor request live data for visible readings/previews. When all sprites
are disabled and the windows/boards are closed, sampling stops. Menu-bar positions
remain under macOS control; Command-drag them to reorder.

## Available readings

The initial monitoring acceptance exposed **56 basic readings** and an Advanced catalog of individual
core/interface/firmware variables. The complete count is device- and interface-dependent;
the app displays its current count. See `monitoring-validation.md` for the measured census.

| Category | Coverage |
| --- | --- |
| CPU | Total/user/system/idle usage, per-logical-core usage, 1/5/15-minute load averages, logical and performance/efficiency core counts |
| Memory | Usage/used/installed, anonymous/app, wired, physical compression, cache/purgeable/free, active/inactive/file-backed, pressure, swap allocated/used/free, page/swap rates |
| Network | Hardware-interface receive/send rates and totals, packet rates, separate per-interface byte rates/totals including virtual interfaces in Advanced |
| Disk | Data-volume total/used/free/available/percentage, aggregate block-driver read/write rates and read/write operations per second |
| GPU | Device, renderer and tiler utilization; reported system memory in use and allocated |
| Battery | Charge, AC/charging state, remaining/time-to-full estimates, temperature, cycles, condition, capacity/design ratio, voltage/current/power flow, negotiated adapter limit |
| System | Uptime including sleep, thermal pressure, Low Power Mode |
| Sensors & power | System power, adapter DC input, mapped CPU/GPU temperatures, both fan speeds and reported limits/targets; readable temperature, power, voltage and current firmware keys in Advanced |

## What the numbers mean

- CPU usage is a delta over an interval. It initially says Measuring interval,
  including after re-enabling or wake. Counts are read from this Mac, not its profile.
- Memory used is `(anonymous − purgeable) + wired + physical compressor storage`.
  File cache is excluded. The active/inactive/file-backed rows overlap other
  classifications and must not all be added together. Pressure is the kernel's state.
- Network uses **IFMIB IFDATA_GENERAL full-width counters**. The default aggregate
  includes up/running `en*` hardware interfaces, excluding VPN/bridge/loopback
  duplicates. It includes local traffic and is not an internet speed test. Interface
  reset/removal re-primes rates; totals describe the current counters, usually since boot.
- Disk activity sums block-storage drivers, including mounted disk-image drivers;
  it is not a claim of isolated physical-media throughput or per-process I/O.
  APFS volume capacities are shared-container figures, not a file-size scan.
- GPU readings are driver-reported and hardware-dependent. Apple-silicon GPU
  memory is shared system RAM; it is not presented as dedicated VRAM.
- Battery power is signed voltage × current, not whole-Mac consumption. System
  power (`PSTR`), adapter input (`PDTR`) and adapter rated/negotiated wattage are
  separate. None is a wall-meter measurement. Missing time estimates remain unavailable.
- The CPU-temperature aggregate has a checked M5-family key map. Other chip
  families can use individual sensor keys; a CPU label is not guessed. GPU temperature
  uses reported `Tg*` keys. Raw keys retain their names where a component name is unverified.
- SMC/IORegistry sensor fields are firmware-dependent interfaces, not a stable
  public cross-Mac contract. Only recognized numeric types and plausible values
  are accepted. Zero/inactive temperature slots are excluded; a stopped fan can
  legitimately report zero RPM. No key is written.

Unavailable, warming and failed readings show text/`—`, never a made-up zero. Each
library row expands to its meaning, source and last sample time. Histories contain
only actual samples and are bounded to 60 per reading, in memory only.

## Native implementation and persistence

One actor owns the samplers. A shared scheduler chooses the fastest requested
interval per source group; visible catalog rows and editor/board previews add demand.
The catalog discovers interface names and firmware readings when opened, so Advanced
search works before visiting a specific category. Interface discovery does not prime
or reset the traffic-rate counters.
It stops when demand is empty, clears deltas on stop/sleep, and releases unused SMC
connections. Menu items do not render faster than their own configured interval;
OS scheduling and shared sampling can delay an update. There are no continuous animations,
shell polling loops, `powermetrics` processes, installed helpers or automatic grants.

`~/Library/Application Support/MenuSprite/monitoring.json` stores versioned settings
and the definitions of referenced dynamic readings. This lets a saved sensor or
interface start correctly without reopening the catalog. Writes are atomic; unreadable
configuration bytes are backed up before replacement. Removing a sprite has Undo.
Missing device/readings keep their saved references and display unavailable.

This is the first visual configuration slice, not the full Scratch-like builder.
Fan controls, general process inspection/control, SMART health, capture, clipboard history,
alerts, scripting, marketplace and external-app mirroring are not implemented.
Battery and sleep controls now have their own first implementation in `power-controls.md`;
monitoring itself remains read-only and does not require that helper.
CPU/GPU clock frequency and per-engine power are not guessed from unrelated counters;
readable raw firmware power keys remain selectable. Intel/older macOS and multi-hour
acceptance still need separate validation.

Protocol/source facts were checked against the installed macOS SDK and Apple's
[network tools source](https://github.com/apple-oss-distributions/network_cmds/blob/main/netstat.tproj/if.c),
[thermal-state API](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property),
and the named reference's [monitoring source](https://github.com/vorssaint/vorssaint-utils/tree/main/Sources/Vorssaint/Services/SystemMonitor)
and [power/temperature readers](https://github.com/vorssaint/vorssaint-utils/tree/main/Sources/Vorssaint/Services/Metrics).
The MenuSprite collectors are implemented locally; no third-party monitoring package
or reference-app executable is embedded.

## 0.3.3 configuration follow-up

The second CPU reading was part of the user-created mixed Network sprite. It was
removed from that sprite; the original standalone CPU reading was retained. New
blank sprites now start with no selected reading, so selecting network readings
does not silently retain a default CPU value. Save stays disabled until a reading
is selected. Existing saved configurations retain their meanings.

The saved personal configuration was backed up in Application Support before
applying the two-row Network and Fan & CPU temperature items. Both use white,
bold text and no extra icon. `sensor.fanSpeed` is the highest readable fan RPM;
zero means reported fans are stopped, while absent sensors stay unavailable.
Individual fan sensors remain selectable in the library. This is a readout only,
with no fan-control change.
