# Menu bar icon

Prerak asked on 28 September 2026 to be able to pick which artwork MenuSprite's own menu-bar item
wears, from the sample sprites made at the start of the project.

## Where to choose it

**Hub → Tools → Menu bar icon**: a grid of every choice, grouped as *MenuSprite* (the identity
treatments) and *Characters*, with a **Monochrome** switch under it. A right-click "Menu Bar Icon"
submenu existed briefly on 28 September. It was removed the same evening, when right-click became
Keep Awake at Prerak's request.

A pick applies at once, with no relaunch. The item's width follows the artwork's aspect ratio at the
menu bar's height (`AppDelegate.applyMenuBarIcon`). The choice is `MenuSprite.MenuBarIcon`, and
monochrome is `MenuSprite.MenuBarIconMonochrome`, both in the app's UserDefaults. Nothing saved means
the Arranger, so existing installs look the same until someone picks.

## The choices

| Group | Choices | Source | Monochrome |
| --- | --- | --- | --- |
| MenuSprite | Arranger (default) | `native/Resources/MenuBarArtwork.png`, unchanged | no |
| MenuSprite | Arranger, flat | `brand/variants/menusprite-logo-flat.png` | yes |
| MenuSprite | Slim rail, Ribbon rail, Glass strip, Warm studio, Paper sprite | `brand/exploration/slim-rail-selection.png` (3D) | no |
| MenuSprite | Graphic sprite | the same sheet (flat) | yes |
| Characters | Peek, Bitwing, Droplet, Mochi, Comet, Bud, Batlet, Tilekin, Orbit, Fold | `brand/exploration/sprite-library-concepts.png` | yes |

**Monochrome is a template image**, which macOS tints black on a light menu bar and white on a dark
one. The 3D renders turned into blotchy silhouettes without their faces, so they come in colour only.
The switch is disabled for them, and switching designs keeps the monochrome preference.

## Assets

`native/Resources/MenuBarIcons/` holds `<id>.png` and, where monochrome exists, `<id>-template.png`.
Each is trimmed and 192 px on the long side, about 600 KB for the set. `scripts/build-native.sh`
copies the folder into `Contents/Resources/MenuBarIcons/`. `scripts/cut-menu-bar-icons.swift` cut
them from the sheets, and its header lists every crop:
- flat art: flood-filled the card colour from the edge
- 3D renders: Vision's foreground mask, with enclosed pale parts (eyes, pills) put back

## Checking it without the screen

```
native/.build/MenuSprite.app/Contents/MacOS/MenuSprite --menu-bar-icon-render <dir>
```

This writes the picker card (dark, light, monochrome) and every icon on a light and a dark 24 pt bar,
at the size the app draws them. It saves no choice. 28 Sep: all 18 found, 12 monochrome.
**Not yet exercised on screen:** clicking a tile and the live swap. They
were checked by build and off-screen render only.
