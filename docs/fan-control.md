# Fan control

Prerak, 30 September 2026: MenuSprite has to control the fans to replace Macs Fan Control.
**Clicking the fan sprite opens controls, not graphs:** Automatic (macOS manages them), 80%, 90%,
Full blast, or any speed in between on a slider. Since 1 October 2026 the public build has it too: the
power helper ships inside the app and is turned on from the board (`docs/power-controls.md`).

## Where it is

- **Fan sprite click** → `FanBoard` (`native/Sources/MenuSprite/FanControlView.swift`). Any sprite showing
  a fan reading (`sensor.fanSpeed` or `sensor.F<n>Ac/Tg/Mn/Mx`) opens it, unless it has a studio-designed
  board. The sprite's other readings (CPU temperature on his Fan & CPU item) follow as plain values.
- **Right-click on the fan sprite:** the fan status plus Automatic / Fans at 80% / Fans at 90% / Full blast.
- **Hub → Tools → Fans:** the same `FanControlView`. It replaced "MenuSprite does not change fan control".

Each fan's live rpm is read in-process every 2 s while a view shows it (`FanMonitor`); reading needs no root.

## What "80%" means

A percentage is **of each fan's own maximum**, never below its firmware minimum
(`FanPolicy.rpm`). On Nebula both fans are 2317–7826 rpm, so 80% = 6261, 90% = 7043 and
Full blast = 7826. The slider starts at 30%, where the minimum sits. One control drives every fan.

## Firmware (Nebula, M5 Max, macOS 27.0.1, measured 30 Sep)

| Key | Type | Writable | Meaning |
|---|---|---|---|
| `FNum` | ui8 | no | fan count (2) |
| `F<n>Ac` | flt | no | actual rpm |
| `F<n>Mn` / `F<n>Mx` | flt | no | 2317 / 7826 |
| `F<n>md` | ui8 | **yes** (attr 0xd0) | mode: 0 macOS, 1 manual (older firmware spells it `F<n>Md`) |
| `F<n>Tg` | flt | **yes** (attr 0xd4) | target rpm; macOS writes it in automatic mode |

**Measured with a root probe on 30 Sep, both fans:** writing target 7826 then mode 1 took them from about
2300 to 7826 rpm in about 3 s. A target of 4500 settled at 4500, and mode 0 handed them back to macOS at once. Two quirks:
- **A target reads back about 1 s late,** so an immediate readback shows the old value. The first helper
  build checked at once and rolled back every time. The controller now waits up to 2.5 s for it.
- **The firmware keeps the last manual target** and applies it the moment the mode flips to 1, so the
  target is written *before* the mode.

A public note (yolo-labz/fand, Mac17,2) claims `F<n>md=1` means "forced minimum" and `F<n>Tg` is a read-only
alias. That is wrong on this Mac: the note judged from the immediate readback, and the fans do follow the target.
There is no `Ftst` unlock key. The M1–M3 method needed one, and this firmware simply accepts the mode write.
`BatteryHardware.fans()` requires the write bit on both keys before calling a fan controllable.
**Writing still needs root**, so every write goes through the power helper.

## Helper behaviour (`PowerController`)

- **The app's choice rides on every request** (`PowerRequest.fans`), like the MagSafe LED setting, plus an
  explicit `.fans` command. An older helper rejects that command, and the board then says to reinstall it.
- **Hold:** it journals `fansOwned` in the recovery file, then writes mode 1 and the target for each fan, and
  reads both back. If a write fails, that fan goes back to macOS and the error is reported.
- **Every 15 s tick:** if the firmware dropped the mode or moved the target, it writes them again.
- **The fans go back to macOS when:** the app quits or crashes (connection invalidated), no heartbeat
  arrives for 65 s, the Mac sleeps, the thermal state turns critical, or you choose Automatic. A helper
  restart with `fansOwned` in the journal also hands them back.
- **The app puts it back:** the choice is saved (`power.fanPercent`) and re-sent at launch, on wake and on
  every heartbeat. So after a sleep or a relaunch the fans return to the chosen speed within seconds.
- **It refuses while another fan controller runs:** Macs Fan Control, TG Pro or smcFanControl. It names the
  app and keeps retrying on each heartbeat until that app quits.

## Checking it

- `swift test --filter PowerControlTests`: 7 fan tests in `FanControlTests.swift`, covering rpm mapping,
  riding on requests, hand-back, failed writes, the conflict, re-assert and journal recovery.
- `MenuSprite --fans` prints each fan as the SMC reports it.
- `MenuSprite --fan-render <dir>` renders the controls off-screen, in light and dark.
- `MenuSprite --fan-set <auto|1–100> [seconds]` asks the installed helper to hold the fans, prints their
  speed every second, then hands them back. The helper serves one app at a time, so quit MenuSprite first.
