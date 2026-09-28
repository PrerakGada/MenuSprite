# Dynamic Island

MenuSprite's Dynamic Island: music, controls and everyday tools in one black shape that hangs from the
top centre of the screen, fused with the camera housing. Requested by Prerak on 28 September 2026 as a
rebuild of Vorssaint 3.4's island "with every customization and feature". It is **optional and off by
default**; turning it off leaves every separate MenuSprite panel working as before.

## Provenance: clean-room, not a port

Vorssaint is GPL-3.0 and MenuSprite is MIT, so no Vorssaint code was copied. Scouts read Vorssaint's
source and wrote behaviour specifications (numbers, rules, settings, and which macOS mechanism does
what); the builders worked only from those specifications and never opened Vorssaint. The
specifications live in `docs/dynamic-island/reference/`, which is excluded from git locally
(`.git/info/exclude`) because they describe another product's internals. Facts about macOS (private
symbols, the `/usr/bin/perl` route to MediaRemote) are not copyrightable and were reused.

## Code map

| Where | What |
|---|---|
| `native/Sources/IslandKit/` | Pure, tested logic: catalogue (sections, tiles, floating actions), settings model, geometry (cutout, silhouette, every state's size, open layout, floating-button placement), spring motion planner, activity picker and notice rules, navigation, gestures, plus each section's pure rules in its own folder. |
| `native/Sources/MenuSprite/Island/IslandController.swift` | The shell: lifecycle with the master switch, display choice, session (lock, sleep, display sleep), what the island shows, opening and closing, hover, clicks on the top screen row, outside clicks, app activation, keyboard, gestures, full screen, Mission Control, file drops. |
| `Island/IslandPanel.swift` | The window: a non-activating panel one level above status items, on every desktop, in a private overlay Space; a display-sized stage that never resizes, masked by the silhouette, so only a mask path animates. |
| `Island/IslandContract.swift`, `IslandEnvironment.swift` | How everything plugs in: sections, feature modules, Controls tiles and cards, compact activities, notices, rest content, the shared system-audio state. |
| `Island/Sections/`, `Island/Modules/` | One folder per section or module. |
| `Island/Settings/` | Settings › Dynamic Island: master switch, Layout, Content, Activity, Behavior. |
| `native/Sources/NowPlayingBridge/` | A small Objective-C library `/usr/bin/perl` loads to reach MediaRemote (the only route a non-Apple app has on macOS 15.4+); bundled in `Contents/Frameworks`, never linked into the app. |

## Sections

Controls (home: playback card, volume and brightness, shortcut tiles), Volume mixer, Now Playing,
Clipboard, Recent captures, Files, System, Tools, Calendar, Notifications, Timer, Camera mirror,
Downloads, Scratchpad, AI Agents. Each can be hidden and reordered (Settings › Content); ⌥⌘ plus a
fixed letter opens it; Explore (⌘K) shows them all. Feature modules without a page: volume and
brightness keys and notices, keyboard light, microphone mute, battery, accessory alerts, keep awake.

## Behaviour worth knowing

- **Closed:** the camera, or the camera with 44-pt wings for the At rest choice (Nothing, Battery,
  Music, AI limits). Live activities take it by priority Timer > Downloads > AI agents > Calendar >
  Music; with several live, hovering shows named choices and "Combine" (only the timer shares).
- **Notices:** one slot; volume/brightness/keyboard light replace anything, lower priorities are
  dropped. While open, level changes take over the header row instead.
- **Opening:** click (default), preview on hover, expand on hover, or hidden until hover. Two-finger
  swipe down opens, up over the header closes, sideways over music skips a track.
- **Show over the menus** (default on) uses the room an empty menu bar would give and never measures
  menus. With it off, a physical notch drops its wings and a drawn cutout rests hidden: measuring real
  menu-bar items through Accessibility is **not built**.
- **Mission Control:** hidden through the Dock's Accessibility notifications (event-driven). Vorssaint
  polls the window list four times a second; that read costs ~6 ms here, so it was not copied. Without
  Accessibility the island simply stays visible in Mission Control.
- **Liquid Glass** and the content blur on reveal are not built; the island is opaque black (the default).

## Permissions

Nothing is requested unless the person presses a button for it. Accessibility (volume/brightness keys,
notifications mirroring, ⌘V paste, Mission Control); System Audio Recording (mixer); Calendars (with
the `personal-information.calendars` entitlement); Camera (mirror, only while the page is open);
Microphone (only for a screen recording with "Record the microphone"); Screen Recording (captures);
Downloads/Desktop folder access (downloads watcher, capture saves). Bluetooth is never used:
accessory batteries come from the IORegistry and `system_profiler`, which need no prompt on macOS 27.

## Resource rules

Off means off: every feature starts in `islandDidStart()` and releases everything in
`islandDidStop()`; page-only work runs between `pageDidAppear()` and `pageDidDisappear()`. The
closed island at rest has no timers and no polling. Known periodic work while on: accessory batteries
every 60 s (`system_profiler` at most every 5 min), clipboard change count every 0.8 s only when
history is turned on, the calendar's one timer at the next event boundary.

## Checking it without disturbing the Mac

- `swift test --package-path native --filter IslandKitTests` — the pure rules.
- `MenuSprite --island-render <dir> [--section <id>|all] [--size compact|spacious|custom] [--wait s] [--start]`
  renders pages (and strips/notices with `--start`) to PNG in a window that is never shown.
- `MenuSprite --island-render <dir> --states` renders the shell's own states through the controller's
  real logic: rest, hover, notices, open pages, Explore, on a notched and an external display.
- `MenuSprite --settings-render <dir>` renders every settings tab and the button popovers.
- `MenuSprite --island-render <dir> --window-check` builds the **real** window (panel, Core Animation mask,
  outline) on a display parked off-screen and checks that the mask lands where the island should be. It
  exists because the first on-screen run showed only the outline: the mask sat in an unflipped view and
  was drawn mirrored at the bottom of the stage. The SwiftUI renders above cannot see that class of bug.

## Safety hardening (review, 28 Sep)

Three read-only reviews (system safety, Swift 6 isolation traps, idle cost) ran over the merged code;
their findings were fixed and re-tested:

- A CoreAudio or display call that hangs (a Bluetooth device reconnecting, a wedged DDC monitor) can no
  longer freeze volume, brightness or the mixer for the session: queues are watched, abandoned after
  2 s (4 s for DDC, 5 s for a mixer build) and late results dropped; the UI says "Not responding" and
  the keys fall back to macOS. A mixer build that gives up leaves that app at normal volume.
- The microphone tile reports what the microphones actually are, not what was asked; an unreadable
  mute record touches nothing (it used to unmute every microphone).
- A volume/brightness key tap that macOS disables is torn down and reinstalled when Accessibility
  returns; a brightness step that fails hands the key back to macOS.
- Clipboard paste sends ⌘V only once the target app is really frontmost (1 s limit), else leaves the
  item copied.
- The animation's completion hop to the main thread is explicit (it assumed the main thread before).

Known and accepted: two identical external monitors without a location can be paired to the wrong DDC
bus; an input device that cannot be silenced (an iPhone Continuity microphone) makes the tile read
"partly muted" while it is listed.

## Not verified on screen

Everything above was built and checked with tests and off-screen renders while the Mac was in use;
**the live window, animations, hover and clicks, key taps, audio taps, the camera, captures and the
notification reader have not been exercised on screen yet.** The first live session should check:
opening and closing by click, hover and swipe; the island on the notch at rest and with wings; volume
keys showing the island's notice instead of macOS's; a song showing the music strip; a timer; the
settings window's drag, popovers and resize grip.
