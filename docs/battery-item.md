# Battery menu-bar item — 15 September 2026

> **Superseded 24 September 2026:** a charge limit *is* held on Nebula — any value 21–100%, through macOS's own charge limit (PowerUIAgent `mclLimitValue`), the way AlDente does it. The SMC findings below still stand; the conclusion drawn from them does not. See `charge-limit.md`.

A battery with its charge beside it, in the menu bar, with the charge controls on
secondary click. Built so AlDente Pro can be dropped. **On Nebula MenuSprite's charge limit cannot run at all — this Mac
exposes no charge-inhibit key. That is recorded below and is a property of the hardware, not
of this work.** The earlier claim here that AlDente cannot either is **withdrawn**: see
*A ceiling is held on this Mac, by macOS* below.

## What is in the menu bar

The item is an ordinary sprite (`SpriteConfiguration.battery`, readings `["battery.charge"]`),
so it can be moved, recolored, renamed, paused or removed like any other. Two things make
it behave like a battery rather than a number:

- **The icon is drawn, not a symbol.** `BatteryGlyph` in `SystemMonitoring` fills a shell in
  proportion to the sampled charge, draws the terminal cap, knocks a bolt through the fill
  while charging, and marks an active charge ceiling with a tick. An unavailable reading
  draws an empty shell — the level is never estimated. The glyph is wider than tall, so
  `StackedReadout` now asks the icon for its width (`ReadoutIcon.width(forHeight:)`) instead
  of assuming a 14×14 square.
- **The tick reports the hardware, not the intention.** It is drawn from
  `PowerSnapshot.controlCeiling`, which is nil whenever no control is running. A saved limit
  that has not been applied shows in the menu text, never as a tick on the icon.

**Where the percentage sits (28 September):** `SpriteConfiguration.batteryPercentPlacement` —
*Inside* (default, including configurations saved before the setting), *Left* or *Right* of the
glyph; a segmented picker in the sprite editor, shown for battery sprites with the icon on.
Inside, `BatteryGlyph.percentInside` draws the number (no % sign) in the shell, always whole
and solid over a fill dimmed to 40% with a thin gap cleared around the digits (a first version
split digits at the fill edge, which read as stray lines), with a small bolt beside it while charging; no ceiling
tick is drawn at all (Prerak: a mark through the rim still cut the digits — the limit stays in the
tooltip, the secondary-click menu and the dashboard), and the icon slot is
15 pt tall instead of 14. The charge column is then dropped from the text
(`MonitoringStore.menuColumns`); the accessibility label still reads it. *Left* moves the icon
after the readings in every layout (`StackedReadout.layout`, `iconTrailing`). With the icon
hidden, the charge is always text.

**The cap shows what the pack is doing (28 September):** `BatteryActivity` in `BatteryGlyph.swift`,
decided like the MagSafe LED — cable first (`battery.state`), then the measured `battery.current`:
**amber** charging, **green** holding with the cable in (a limit held by macOS reports "not
charging"), **blue** draining with the cable in (Discharge, or macOS draining down to the limit),
and the **plain grey cap** while running on the battery. An unread state keeps the plain cap. The
tooltip names the state. A colored cap makes the image non-template, so the digits are drawn at
full strength rather than the menu bar's slightly translucent label color.

**Right-click toggles Low Power Mode (28 September).** On the battery item a plain right-click
switches macOS Low Power Mode on, and again back to normal (automatic); the charge-control menu
moved to control-click or option-right-click, and carries a *Low Power Mode* checkbox. While it is
on, the whole outline is yellow (and the cap, unless it carries a charging/holding/draining color) and
the fill is a light yellow tint so the digits keep their contrast (`BatteryGlyph.lowPower`); the tooltip says so; the item redraws on
`NSProcessInfoPowerStateDidChange`, so a change made in System Settings shows too.
Mechanism: the helper runs `pmset -a powermode 1|0` (both power sources) and confirms it from
`pmset -g` (`PowerRequest.Action.lowPower`). Root is required — the private
`LowPowerMode.framework` (`_PMLowPowerMode setPowerMode:fromSource:`, what Control Center uses)
was tried first: powerd never replies to an unentitled client, sync or async. A helper older than
this build answers "Invalid request"; the app beeps, says to reinstall it, and the menu offers
*Copy helper install command*.

The image stays a template (it follows the menu bar's own appearance) unless a reading
demands a color: below 10% while running on the battery the glyph turns red, and only then.

## Secondary click

Right-click — or control-click — on any sprite now opens a small menu; the battery item
carries the charge controls above it. `SpriteContextMenu` builds it, and the status item
borrows it for the duration of the click in the same way the brand item does.

```
Battery 100% · Charging          ← live, from the same readings the boards use
Charge limit off                 ← what the hardware is doing
──
Limit charging to 55%            ← checkmark tracks the running control
Charge limit ▸  50 55 60 70 80 90 100 · Other…
Top up to 100% once
Discharge to 55%                 ← only when the firmware supports it
──
Battery & Power…
──
Configure sprite… · Pause readings · Hide from menu bar
```

When a control cannot run, the whole charge section is replaced by **the reason**, in the
same words the Battery & Power dashboard uses, plus *Copy helper install command* when the
helper is what is missing. A control that cannot work is never offered as a button that
silently does nothing.

Primary click still opens the Battery & Power dashboard — battery-only sprites now map to
the `.power` panel kind, so the item and the PWR sprite share one dashboard.

## The limit survives sleep, unplugging and relaunch

This is the difference between a one-shot control and something that replaces AlDente.
`PowerStore.saverEnabled` records the *intention* separately from what the hardware is
doing, persisted as `power.saverEnabled`. `resumeSaverIfPossible()` re-applies it when
conditions allow — at launch, after a wake, and when the adapter is reconnected — under
exactly the guards a manual start uses, throttled to one attempt per 30 seconds so a
standing refusal cannot become a retry loop. It only ever re-applies the ceiling the user
chose; it never starts a control nobody asked for, and stopping it in the menu clears the
saved intention rather than leaving it to come back.

`canRequestBattery` is the gate for the menu: everything `canControlBattery` requires except
an already-open XPC connection, because launchd starts the helper on demand and the menu
should not have to hold one open to offer the control.

## Fixed along the way: the capability answer was being thrown away

`PowerStore.refreshLocal()` recomputed `chargeSupported` from an **in-process** SMC read on
every power event, overwriting whatever the root helper had reported. On firmware where the
charge keys answer only to root, that silently downgraded a supported Mac to "unavailable".
The helper's answer is now remembered (`helperCapability`) and the unprivileged read can no
longer downgrade it.

## Firmware on Nebula — why the limit is unavailable here

**Nebula has no charge-inhibit key, so no charge ceiling can be held on this Mac.** That was
established independently the same day and is recorded in full, with root verification and a
live write test, in `docs/power-controls.md` → *Nebula has no charge key*. The short version:

- `CHTE`, `CH0B`, `CH0C`, `CHWA`, `BCLM` and the `bfF0`/`bfE0`/`bfD0` range controls do not
  resolve, unprivileged or as root. `chargeKeys` returns `[]`.
- `CHIE` is present but is an **adapter switch, not a charge inhibitor** — proven by writing
  to it and watching `pmset` move to `discharging`.
- Approximating a ceiling with that adapter switch would discharge above the limit and
  recharge below it, adding several full-equivalent cycles a day. It is worse than no limit,
  and `power-controls.md` records that it must not be implemented.

So the menu's "Charge control is unavailable on this Mac's firmware" is the correct and
honest answer here, not a gap in this work. Everything above it — the item, the glyph, the
menu, the saved-limit resume — is built and waiting for firmware that answers, and works
unchanged on a Mac whose firmware does.

⚠️ **This also means AlDente Pro cannot be holding a limit on Nebula either.** The 55% cap in
Prerak's power policy is not being enforced by anything: AlDente is not running, MenuSprite
cannot, and the pack read 98% then 100% while this was being built. That is a policy question
for him, not a bug in either app.

`scripts/smc-key-report.swift` is the read-only key report used here; it enumerates every SMC
key and prints the charge/battery ones with sizes and values, and has no code path that writes.

## Evidence

`--battery-validate <dir>` launches the installed signed app, renders the real status button,
builds the exact menu a secondary click would show, and writes `report.json`, `menu.json` and
`battery-item.png`. It is read-only: it sends no charge command and writes no firmware.

15 September, installed build, `~/Applications/MenuSprite.app`: **13 checks, 0 failed** —
including that the glyph level equals the sampled charge, that no ceiling tick is drawn while
no control is running, that the menu states the live level and the hardware state, and that
the unavailable path explains itself instead of offering a dead control. The menu bar was also
photographed: the filled shell with the bolt knocked through it, and `100%` beside it.

Unit tests for the glyph, the layout width and the seeding live in
`native/Tests/SystemMonitoringTests/BatteryGlyphTests.swift`. ⚠️ **They have not been run:**
`swift test` needs the full Xcode toolchain for swift-testing, and Xcode's license has not
been accepted since the 26.6 update (`sudo xcodebuild -license accept`). The app itself builds,
signs and installs against the Command Line Tools, which is how this build was produced.

## Existing configurations

The saved sprite file carries a version. Version 1 files gain the battery item once, on load,
and are rewritten as version 2 — so deleting the item keeps it deleted rather than having it
reappear at every launch.

## A ceiling is held on this Mac, by macOS — measured 19 September 2026

The claim that no tool can hold a ceiling on Nebula is wrong, and the measurement is simple.
With **AlDente not running** (absent from the process list, its privileged helper reporting
`state = not running`), the pack charged to exactly **80%** and stopped there:

```
pmset -g batt   →  80%; AC attached; not charging   (sustained, four samples over 80s)
ioreg           →  IsCharging = 0, FullyCharged = No, NotChargingReason = 0x1000000
```

`FullyCharged = No` rules out a full pack, and `NotChargingReason` is non-zero, so something
above the SMC stopped the charge. **That is Apple's own charge limit, a system setting that
survives the app that set it being quit.** AlDente's preferences are consistent with having
set it — `useTahoeNativeLimit = 1` and `chargeVal = 80` — though that it was AlDente rather
than macOS itself is inference from those keys, not something this measurement proves.

**What this changes.** The SMC finding stands exactly as recorded: there is no writable
charge-inhibit key, and MenuSprite's charge backend cannot work here. What does not follow is
that a ceiling is impossible on this Mac. There is a second mechanism — Apple's native charge
limit — which MenuSprite does not use and has not investigated. Whether it can be driven by a
third party, and whether it accepts a value below 80, are both **open questions**; AlDente
publishes an `allowChargeLimitsBelow80` preference, which hints at a path but proves nothing.

Until that is settled, the honest public statement is the narrow one: **MenuSprite cannot hold
a charge limit on firmware that publishes no charge-inhibit key** — not that no ceiling exists.
