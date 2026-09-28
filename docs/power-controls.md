# Power Controls — first implementation, 8 September 2026

> **Superseded 24 September 2026:** a charge limit *is* held on Nebula — any value 21–100%, through macOS's own charge limit (PowerUIAgent `mclLimitValue`), the way AlDente does it. The SMC findings below still stand; the conclusion drawn from them does not. See `charge-limit.md`.


The local 0.5.0 update adds the [Battery & Power dashboard](energy-dashboard.md)
with live flow, charts and the same guarded battery backend. The hardware
acceptance boundary below still applies.

MenuSprite 0.3.0 (4). Prerak explicitly authorized battery and sleep controls after
monitoring. This is the first control implementation, not a verified replacement
for all AlDente/Vorssaint behavior. Website, capture, fan controls and clipboard
history are unchanged.

## Open and use

Open `~/Applications/MenuSprite.app`, then **Power Controls** in Monitoring or the
menu-bar menu (Command-P). The existing purple-sprite/light-blue-rail app menu is
retained. CPU, RAM and PWR are now three independent stacked, icon-free readouts
in the saved personal configuration, with 14-point heavy white values and small
labels above them. Each remains editable. PWR is the live **PSTR system power**
sensor, not adapter nameplate wattage or battery discharge alone.

**Keep awake** works without administrator access. Choose a duration or Until
stopped, optionally keep the display on, restrict it to AC power, or pause while
locked. Automatic rules cover power connected, an external display connected,
and chosen running applications. Stop also pauses rules so they cannot immediately
restart the session. Saved rules need Resume after relaunch. This uses owned native
IOPM idle-system/display assertions. Explicit Sleep and lid closure follow macOS
rules unless the separate closed-lid mode is active.

**Battery** offers a charge ceiling and lower resume threshold (20–100%, lower
strictly below upper), a one-time top-up to 100%, and discharge to the ceiling while
plugged in. Top-up returns to the chosen band without forcing a discharge. Forced
discharge reconnects the adapter at the ceiling; it does not generate artificial
load. Controls stop on unplug, system sleep, app exit, connection loss or critical
thermal state. They do not resume automatically after sleep/relaunch. This means
this version does not maintain a charge limit while the Mac sleeps.

**Closed-lid mode** uses the same root-controlled `pmset disablesleep` approach as
Vorssaint. It disables system sleep broadly, not just the lid trigger. Requires AC,
known battery above 20%, and a duration up to 24 hours. It restores its setting on
Stop, timeout, unplug, critical thermal state or lost app connection. It refuses
to start if system sleep is already disabled. Keep the Mac ventilated. External
display continuity depends on the Mac/display configuration and needs physical
validation. Pause-while-locked and display toggles apply to ordinary keep-awake;
the stronger closed-lid mode is separate.

## Administrator helper and coexistence

The app bundles a signed `in.prerakgada.MenuSprite.PowerHelper`, but installation
and activation are separate. No helper was installed or privileged hardware written
during this implementation session. AlDente Pro and Vorssaint were already running;
Vorssaint's existing system sleep-disable setting was preserved.

For this development-signed, unnotarized build, **Copy install command** supplies:

```sh
sudo /bin/bash "$HOME/Applications/MenuSprite.app/Contents/Resources/install-power-helper.sh"
```

Run it yourself in Terminal and enter the administrator password there. Return to
Power Controls and Refresh. Installation enables no controls. This local developer
installer is used instead of claiming a notarized SMAppService distribution flow.
Before starting battery control, turn off charge control in AlDente (or another
controller) and quit it. MenuSprite never quits a competing app. Battery starts
are blocked when a known competing controller is detected. Hardware changes by
another controller cause MenuSprite to stop rather than continuously fight it.
Unknown competing controllers cannot all be identified automatically; use one at
a time. Similarly, stop Vorssaint's sleep override before using MenuSprite's.

The helper uses a launchd Mach service, exact app/helper bundle identifiers and
Apple-signed team requirements (`RC63N3VU27`) in both XPC directions. Its only
requests are status, heartbeat, battery mode, closed-lid session and stop. No raw
SMC key/value, command, path or shell execution endpoint is exported. The helper
runs as root; the GUI stays unprivileged. The installer verifies the staged signed
helper, installs root-owned files, and adds no sudoers rule.

- Executable: `/Library/PrivilegedHelperTools/in.prerakgada.MenuSprite.PowerHelper`
- Service: `/Library/LaunchDaemons/in.prerakgada.MenuSprite.PowerHelper.plist`
- Recovery journal: `/Library/Application Support/MenuSprite/PowerRecovery.json`
- Saved UI preferences: app-owned UserDefaults under the main bundle identity.

Only active controls sample in the helper (15s with tolerance); the app sends a
20s heartbeat only while a privileged control is active. A heartbeat older than
65s triggers restoration. An unused, disconnected helper exits after at most
roughly two minutes; launchd can start it on demand. Idle app keep-awake rules use
power/display/workspace events rather than polling. Ordinary keep-awake uses a
one-shot expiration task. Opening the page only reads state.

Writes journal the original and intended value before touching hardware. Partial
failures, connection invalidation and daemon restarts restore values still owned
by MenuSprite, reconnecting the adapter first. Unknown original states are rejected.
The helper also receives system-sleep notifications and restores before acknowledging
sleep. A recovery error remains visible and blocks new battery control. A journal
is not a guarantee against hardware failure, corrupt storage, OS bugs or an external
controller writing the same value; these require real acceptance before relying on
this build unattended.

Quit MenuSprite before helper upgrades/removal. Remove with:

```sh
sudo /bin/bash "$HOME/Applications/MenuSprite.app/Contents/Resources/uninstall-power-helper.sh"
```

Removal stops the service, attempts journal recovery and refuses to remove the
binary if recovery fails. The journal is retained. If the app cannot run, the signed
installed helper's `--restore` command is the local root recovery path; stop the
launch daemon first so no active controller can race recovery.

## Hardware boundary and validation

Charge controls use undocumented firmware interfaces; they are not macOS privacy
grants. The backend supports known CH0B/CH0C or CHTE charge keys with a
CH0I/CH0J/CHIE adapter key, and refuses the bfF0/bfD0/bfE0 range-control family
until a separate backend is validated. Presence of a key is capability evidence,
not proof a hardware write succeeds; every write requires success and readback
confirmation.

### Nebula has no writable charge key — measured 15 September 2026

An earlier revision of this document claimed "the current Mac exposes four-byte
CHTE and one-byte CHIE controls". **That is no longer true of Nebula** (M5 Max,
macOS 27.0 26A428), and the reason matters more than the key list.

**Presence is not capability.** Every SMC key carries an attributes byte whose
`0x40` bit is write permission. A key can be present, readable and refuse every
write with SMC error `0x86`. The backend previously treated presence alone as
evidence, which is how it could have offered controls this firmware never
accepts. `BatteryHardware.info(_:)` now reads that byte and `chargeKeys` /
`adapterKey` only return keys that are the right width **and** writable.

Measured on this Mac, unprivileged and again as root, identical both times:

| Key | attributes | Writable |
|---|---|---|
| `CHIE` | `0xd4` | **yes** — confirmed by a real write |
| `CHIB` `CHIC` `CHIL` `CHIO` | `0x94` | no |
| `CHCC` `CHCE` `CHCR` `bfI0` `bfJ0` `bfK0` | `0x94` | no |
| `CHSE` `CHST` `CHRT` `CHSC` `CH0R` `CHOC` `CHTC` | `0x84` | no |
| `ACLM` | `0x95` | no |

Absent entirely: **`CHTE`, `CH0B`, `CH0C`, `CH0I`, `CH0J`, `CHWA`, `BCLM`,
`bfF0`, `bfE0`, `bfD0`.** The whole SMC table was enumerated (3,864 keys, 3,776
resolved) rather than guessed at by name.

The `CHIx` spelling is the old `CH0x` block renamed — `CHIE` really is the
former `CH0I` — so `CHIB`/`CHIC` look exactly like the `CH0B`/`CH0C`
charge-inhibit pair. **They are read-only, so the resemblance is a trap.**

**`CHIE` is an adapter switch, not a charge inhibitor — proven by writing it.**
With the adapter attached at 99%, `CHIE=8` moved `pmset -g batt` from
`finishing charge` to `discharging` within six seconds; `0` restored
`AC attached`. Values `1`, `2` and `4` each read back as `8` and produced the
same discharge, so the register is binary, not a bitfield hiding an inhibit bit.

#### What this Mac can and cannot do

**Can: run from the battery on demand with the cable connected.** This needs
only the adapter switch. `dischargeSupported` is therefore independent of the
charge keys — gating it on `chargeSupported`, as it was, hid a control this
hardware can actually run. A discharge here is a **one-shot**: it reconnects the
adapter at the target and hands control back, because there is no way to hold a
band afterwards.

**Cannot: hold a charge limit.** There is no writable charge-inhibit key.
Approximating one by toggling the adapter would discharge and recharge
repeatedly — at this machine's measured idle draw a 50–55% band is roughly
3.6 Wh per swing, several full-equivalent cycles a day, worse for the pack than
no limit at all. It is deliberately not implemented, and `handle(.battery)`
refuses `.maintain` on such firmware without writing anything.

Untested write candidates remain (`CHIB`, `CHIC`, `CHIL`, `CHIO`, `CHSE`,
`CHST`, `CHRT`, `bfI0`) but all are read-only, so there is nothing to try.

#### Validation

`--discharge-validate <dir>` drives the installed app through the real root
helper: it starts a discharge, confirms the adapter is off in firmware with the
cable still connected and charge current at zero, stops, and confirms the
adapter is reconnected with no recovery pending. **12 of 12 checks passed on
15 September 2026.** Its report carries its own note — that run *does* write
privileged firmware, and must not claim otherwise.

Still unverified: a full-depth discharge all the way to the target, and physical
lid behaviour.

See `power-validation.md` for actual test results and measurements. Remaining
manual acceptance: root installation/XPC authentication/rejection, write/readback
on this firmware, long charge/top-up/discharge transitions, helper crash while a
real control is active, physical lid close/open, AC removal, real sleep/wake and
locked-session/selected-app automation. Do not describe those as verified from
policy tests or from Terminal's access.

API/protocol references inspected for this implementation (behavior and wire facts,
not copied application implementation):

- [Apple IOPM assertions](https://developer.apple.com/documentation/iokit/1557134-iopmassertioncreatewithname)
- [Apple XPC signing requirement](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))
- [Apple Service Management packaging](https://developer.apple.com/documentation/servicemanagement/updating-your-app-package-installer-to-use-the-new-service-management-api)
- [Vorssaint keep-awake behavior](https://github.com/vorssaint/vorssaint-utils/blob/main/Sources/Vorssaint/Services/KeepAwakeManager.swift)
- [batt firmware charge control](https://github.com/charlie0129/batt/blob/master/pkg/smc/charging.go)
- [batt adapter control](https://github.com/charlie0129/batt/blob/master/pkg/smc/adapter.go)
