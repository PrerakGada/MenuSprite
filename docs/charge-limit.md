# Charge limit, Top Up, Discharge and the MagSafe light — 24 September 2026

MenuSprite now holds any charge limit from 21% to 100% on Nebula, the way AlDente Pro does on
current firmware: by driving **macOS's own charge limit**, not the SMC. This supersedes the
"a limit cannot be built on this Mac" conclusion in `power-controls.md` and `battery-item.md`.
That conclusion was true of the SMC and wrong about the Mac.

## Why the SMC route was a dead end, and what replaced it

On macOS 26.4+ firmware the charge-inhibit keys (`CHTE`, `CH0B/CH0C`, the `bfF0` range keys)
are absent, read-only, or gated behind Apple's `com.apple.private.iokit.soc-limit`
entitlement even for root (charlie0129/batt issue #152). Charge control moved into powerd:
**PowerUIAgent** (root) owns a *manual charge limit* (MCL), registers it with powerd as a
charge-control policy, and powerd enforces it through the firmware. Enforcing it this way:

- **holds the level with the adapter powering the Mac** — a real charge inhibit, so no extra
  battery cycles, unlike toggling the adapter switch;
- **drains to the limit when the pack is above it** (`drain` in the policy), cable connected;
- **survives sleep, restarts and MenuSprite quitting**.

System Settings offers only 80–100% in 5% steps, and PowerUI's client API
(`PowerUISmartChargeClient -setMCLLimit:error:`) refuses anything else with
`PowerUISmartChargingErrorDomain` code 4. PowerUIAgent's stored preference is not bounded:
`mclLimitValue` in its root domain `com.apple.smartcharging.topoffprotection`, re-read when
`com.apple.smartcharging.defaultschanged` is posted. AlDente Pro 1.39.3 does exactly this. Its
binary logs "writing defaults charge limit" and "writing MCL limit", and its root helper exposes
`writeDefaultsWithDomain:key:value:user:host:`.

## Evidence on Nebula (M5 Max, macOS 27.0)

- Before: powerd policy `soclimit 80, drain` owned by PowerUIAgent (System Settings' 80%).
  AlDente's own preferences read `chargeVal = 80`, `useTahoeNativeLimit = 1`.
- `defaults write com.apple.smartcharging.topoffprotection mclLimitValue -int 55` as root plus
  the notification → powerd `soclimit 55, drain`; PowerUI `getMCLLimit` → 55. About a minute
  later: `InstantAmperage` −1454 mA, `IsCharging No`, AC attached. macOS was draining, and it
  reached 69% within the session.
- `--limit-validate <dir>` on the installed signed app with the upgraded helper: **14/14** —
  60% through the helper (a value PowerUI refuses), powerd enforcing it, Top Up to 100 and back,
  a paused discharge holding the current level and resuming, the MagSafe LED read back as
  blinking amber, and the original limit restored.
- **powerd's record (`/Library/Preferences/com.apple.powerd.charging.plist`) lags PowerUI by
  roughly 6–10 s after a change.** The app treats a record that disagrees with PowerUI as stale
  and re-reads it at 2, 8 and 16 s.

## How it works in MenuSprite

- `PowerUIBridge` (Objective-C) — reads the limit, support and enabled state through PowerUI at
  run time, with no privilege. It sets values PowerUI accepts directly.
- `SystemChargeLimit` — the root-only preference write plus the notification, used by the
  helper's new `chargeLimit` request for every other value. `EnforcedChargeLimit` parses
  powerd's world-readable record, so the UI reports what macOS enforces, not what was asked.
- `PowerStore.reconcileLimit()` runs at launch, wake, plug/unplug and every power event. It
  writes only when macOS differs from MenuSprite's target, and **never while MenuSprite's limit
  is off**, so a limit chosen in System Settings is left alone. On the first run of this build,
  an existing macOS limit is adopted rather than overwritten.
- **Drag the line** on the Battery & Power bar (the dashboard and the Power window gauge). The
  value shows while dragging and is applied on release. The dashboard slider, the right-click
  presets and "Apply limit" set the same limit. "Turn limit off" writes 100.
- **Top Up** sets 100% and returns to the limit when the cable is unplugged.
- **Discharge** is macOS's drain to the limit. Pressing it while draining stops and holds the
  current level (the limit is set to that level). Pressing again resumes. The hold clears on
  unplug or when a new limit is chosen.
- **Run on battery** (Power window, "While the cable is connected") is still the adapter-switch
  one-shot from 15 September, independent of the limit.

## Sailing (added the same evening)

Prerak saw the Mac charge and discharge by less than 1% around 55%. macOS's limit is exact:
any dip below it, under load or after unplugged use, is topped straight back up, and above it
macOS drains. PowerUI has no band; every MCL policy is registered with `drain` on.

Sailing puts the band on top: with a 5% band and a 55% limit, **nothing charges between 50 and
55**. Inside the band MenuSprite sets macOS's limit to the current level, which holds the pack
where it is (no charge, no drain). Below 50 the limit goes back to 55 and it charges, and that
recharge runs all the way to 55 rather than stopping at the band's edge (`power.sailRecharging`
carries it over). The decision is the pure `Sailing.target` in PowerControl, with a unit test
of the exact example.

- Choices: off, 3, 5 or 10%; default **5**. `power.sailing`. Set in the dashboard's limit card,
  the right-click menu or the Power window. The band is shaded on the bar.
- No writes while unplugged: macOS does not charge on battery. The plug-in power event writes
  the held level, so plugging in at 52% does not top up to 55. A second or two of charge can
  land before the write takes effect.
- Each 1% the level falls inside the band while plugged in is one helper write. That happens
  only under heavy load; at idle the adapter carries the Mac and the level does not move.
- The menu-bar tick and the bar line show the user's limit, not the level being held.
- **Proven on hardware, 24 Sep 23:1x** (`--limit-validate`, installed build): at 55% with sailing 5%, a
  57% limit left macOS holding **55**, status "Sailing · holding 55%, charges below 52%". With
  sailing off, the same 57% limit went to macOS as 57 and it began charging.
- **Bug found by that run, fixed and installed:** a limit change that reached the helper while it
  was still busy with the previous write was silently dropped. The latest target is now
  re-applied when the helper answers, and for 15 s after a write the value actually sent counts,
  not PowerUI's report, which lags by a second or two.
- At idle with the cable in and the level at the limit, the pack reads **0 mA for two minutes**:
  no flapping. The top-ups Prerak saw come from load exceeding the adapter (the battery covers
  the difference), followed by macOS refilling to the exact limit. Sailing removes the refill.

## How macOS takes a change — measured 25 September

A morning of experiments, each read from powerd's record rather than PowerUI's report:

- **Only a changed stored value reaches powerd.** Re-writing the value already stored does
  nothing, even when powerd enforces something else.
- **While the Mac is charging, PowerUIAgent passes a new value to powerd only at the next 1%
  step** (about 2 min at this Mac's rate). While holding or draining, it passes it within about
  20 s. So a stall is at most one step of charge, and it resolves by itself.
- **At 100 the agent's limit is off and it ignores the preference.** Turning it back on (API or
  `enableMCL`) restores macOS's own saved 80, which is what once left powerd at 80 after Top
  Up. MenuSprite therefore leaves 100 through PowerUI's API at 80 and then writes its value.
  Apple's "charge to full" (`temporarilyDisableMCL`) behaves the same way.
- **Every other write goes through the helper**, even the values PowerUI's API accepts.
- `com.apple.system.powersources.chargingtofulloverride`, posted as root, looked like an
  instant re-apply once. It was a coincidence (the level ticked at that moment), so it is **not**
  used.
- MenuSprite checks powerd itself about 35 s after a write, and on power events. If powerd
  disagrees while not charging, it nudges once (target+1, then the target), at most every 2 min.
  The status reads "N% set · macOS applies it at the next 1% step" while a change waits.
- `MenuSprite --limit-set N` (MenuSprite quit first) asks the installed helper to write N and
  prints what was stored. It is the diagnostic used for all of the above.
- `--limit-validate`: **14/14** on the installed build with the final helper, including Top Up
  returning to the limit and two back-to-back writes landing on the second.

## MagSafe light

SMC key `ACLC`, written only by the helper, only with the values below:

| Value | Meaning |
|---|---|
| 0 | macOS controls it |
| 1 | off |
| 3 | green |
| 4 | amber |
| 6 | slow blink (amber) |

The LED has no red; amber stands in. Shown: green while holding, amber while charging, blinking
while discharging with the cable in, driven by the pack's signed current (±50 mA dead band).
macOS rewrites the key itself, so the helper re-applies it on every power-source change and
every 15 s. The light returns to macOS on unplug, on sleep, when the setting is turned off,
and when MenuSprite quits or stops answering. It is a setting (`power.magsafeLED`), on in
Prerak's build.

## Limits and open points

- Requires macOS 26.4+ with PowerUI's MCL. `MSPowerUI.isSupported()` gates it; older firmware
  keeps the SMC path.
- Choosing a limit in System Settings while MenuSprite's limit is on is undone at the next
  reconcile. That is AlDente's behaviour too.
- Sailing mode is unnecessary on this path, because macOS inhibits charging instead of cycling
  the adapter. Not built.
- The drag line has not been exercised by an automated click: GUI validation is not run while
  Prerak is working. The same `setLimit` path is covered by `--limit-validate`.
- A private preference is an Apple implementation detail, and a macOS update may move it.
  `checkLimitSoon` states it plainly in the UI when macOS does not take a value.
