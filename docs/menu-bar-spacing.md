# Menu bar spacing

Added 22 September 2026. Hub → Tools → **Menu bar spacing**: Default / Small / Very small / None.

## How it works (same mechanism as Bartender and Ice)

AppKit's `NSSystemStatusBar` reads two per-host global defaults when an app launches:

| Key | Meaning | macOS default |
| --- | --- | --- |
| `NSStatusItemSpacing` | gap between menu-bar items | 16 pt |
| `NSStatusItemSelectionPadding` | padding inside an item's highlight | 16 pt |

Equivalent shell: `defaults -currentHost write -globalDomain NSStatusItemSpacing -int 4` (and the
same for the padding key); `defaults -currentHost delete -globalDomain <key>` restores the default.
MenuSprite writes them with `CFPreferencesSetValue(…, kCFPreferencesAnyApplication,
kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)`. Presets set both keys to the same value:
Small 8, Very small 4, None 0; Default removes them. Code: `native/Sources/MenuSprite/MenuBarSpacing.swift`.

## Replacing Bartender

Bartender writes the same two keys — its own preferences carry `ReduceMenuItemSpacing = 2`. macOS
stores them in `~/Library/Preferences/ByHost/.GlobalPreferences.<host UUID>.plist`, so **the value
survives a restart with nothing running to re-apply it**. Observed on Nebula: both keys still read 0
with Bartender quit and not running, so Bartender does not clear them on quit and is not needed at
login for spacing alone.

MenuSprite takes it over in two parts:

- **Ownership.** Picking a preset stores it as `MenuSprite.MenuBarSpacing`. At every launch
  `MenuBarSpacing.enforce()` compares the stored keys with the owned preset and rewrites them only
  if they have drifted — so a login restores the spacing if anything else changed or cleared it.
  Without a preset picked, MenuSprite owns nothing and leaves another app's value alone.
- **Open at login** (`LoginItem`, `SMAppService.mainApp`), so MenuSprite is there to do that.

## Why a logout

Each app reads the keys once, at launch. Logging out relaunches everything; an individual app that
is quit and reopened picks up the value alone. The card compares the saved value with the value
MenuSprite launched with, shows "Log out to apply" when they differ, and offers to relaunch
MenuSprite itself. There is no Log Out button: MenuSprite has no Apple Events entitlement, and adding
one means an Automation consent prompt and a change to the public build.

## Evidence on macOS 27.0 (Nebula)

- Both keys were already `0` on Nebula before this work (not set by MenuSprite; Bartender is not installed).
- The key strings are still present in AppKit next to `NSSystemStatusBar` in the dyld shared cache.
- A menu-bar screenshot shows third-party items packed tight, so apps still honour them.
- `--spacing-validate <dir>` on the installed bundle: **11 checks, 0 failed** (22 Sep) — write
  accepted, value reads back, `enforce()` a no-op when the keys match and a repair when they drift,
  login-item registration reports `enabled`, and both the spacing and the login-item state found on
  the Mac restored. The mode changes nothing permanently.
- macOS 27 draws the menu bar through `/System/Library/CoreServices/MenuBarAgent.app`, and status items
  are no longer separate layer-25 windows. **System items (Control Center, clock) ignore the keys.**
  Confirmed 28 Sep from Accessibility frames: third-party items sit edge to edge at 0 pt, but there
  are 7 pt before the Control Center item and 16 pt between it and the clock, although `MenuBarAgent`
  launched (22 Sep 18:53) with both keys already 0. Its spacing is internal (`leadingItemSpacing`,
  `trailingItemSpacing`), with no key in its binary or in `com.apple.MenuBarAgent`. Changing it would
  mean patching a SIP-protected system process, so there is no supported way to change it.
