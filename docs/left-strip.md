# Left strip — sprites over the app's menus

Requested by Prerak on 29 September 2026. The right side of the menu bar is shared with macOS and
every other app, and on a notched MacBook it overflows quickly. The frontmost app's menus (Shell,
Edit, View, …) take the left half and are rarely used. The left strip draws MenuSprite's sprites
over those menus, so the right side keeps its room for everything else.

## Behaviour

- **Placement is per sprite and nothing moves by default.** Right-click a sprite → *Move to left
  side* / *Move to right side*, or the **Left | Right** switch in the sprite studio's header (next to
  *In menu bar*; disabled while the sprite is hidden; applies at once and is not part of undo). Stored as a list of sprite IDs in the `MenuSprite.LeftStripSprites`
  default (`SpritePlacement`), apart from the sprite configuration. The hub icon stays on the right.
- **Where it sits.** From just after the app's bold name (the Apple menu and the name stay visible)
  across the app's last menu, growing further if the sprites need more room, and never past the notch
  (`NSScreen.auxiliaryTopLeftArea`) or, on a display without one, the leftmost status item. Sprites
  that do not fit are clipped at the right. Pure rule: `LeftStripLayout` in `SystemMonitoring`, tested.
- **Look.** A black pill like the Island, with a dark appearance, so sprites designed for a dark bar
  (white numbers) stay readable whatever the wallpaper.
- **Pointing at the strip — a choice, `MenuSprite.LeftStripReveal`** (hub → Sprites → *Left strip*, or a strip
  sprite's right-click → *Left strip*):
  - **Sprites first · rest on the strip for the app's menus** (default, Prerak 29 Sep). Sprites take clicks,
    right-clicks and drags at once, no modifier. Resting on the strip for `MenuSprite.LeftStripHoverDelay` (1 s by
    default; 0.5–3 s in the hub card) fades it and lets clicks through to the menus; it returns when the pointer
    leaves, unless a menu is open (⌘ over it returns it at once). Clicking or dragging a sprite stops the fade until
    the pointer leaves. A 0.12 s dwell with ⌘ for the sprites was tried the same evening and rejected: it took two
    hands to read a board.
  - **Sprites stay · hold ⌘ for the app's menus** (the first design). Letting go of ⌘ brings the strip back,
    unless a menu is open.
  A menu opened through the faded strip keeps it faded until HIToolbox's end-of-menu-tracking notification.
  Keyboard access (⌃F2, ⌘? Help search) needs neither: dropdowns open above the strip.
- **Reordering: drag a strip sprite** (press, move more than 3 pt; in the ⌘-for-menus mode too). The others slide aside; on release the order is
  written into the sprite list (`MonitoringStore.reorder`, only the strip's sprites swap places among the slots they
  hold), and only the strip is re-arranged — right-side items are not rebuilt. The list's ⋯ → Move up/down still works.
- **Hidden** in full-screen spaces (the panel does not join them) and whenever the menu bar is not
  reserved (auto-hide), measured from the screen's visible frame.
- Clicks, the context menu and every board behave as on the right side: the same `SpriteMenuItem`
  draws into a strip button instead of a status item. Popovers opened from the strip get the process
  panels' outside-click and app-switch dismissal, because macOS only provides it for status items.

## What it reads, and what it costs

- The frontmost app's menu bar item **frames only** (no titles), through Accessibility, on app
  activation, space or screen change, again at +0.5 s and +1.5 s for apps still building their menus.
  Each read has a 0.3 s messaging timeout and runs off the main thread. Without Accessibility, the
  strip is placed after an estimate of the app name's width and covers up to the notch.
- Status-item window bounds and levels through `CGWindowListCopyWindowInfo`, at the same moments.
  No Screen Recording is needed and no window titles are read.
- ⌘ and the pointer are polled at 12.5 Hz **only while the pointer is over the strip or the strip is
  faded**. There is no global key monitor, so no Input Monitoring permission is needed, and nothing
  runs at idle.
- The strip exists only while at least one sprite is placed on it. Moving the last one back tears it
  down.

## Not yet verified on screen (29 Sep)

Built and unit-tested only; no GUI checks while Prerak works. On first use, check:
1. The strip's left edge sits just after the app name on the notched built-in display, and on an
   external display, and it moves when switching apps.
2. `auxiliaryTopLeftArea` is in global coordinates on the built-in display (the code handles both).
3. ⌘-point reveals; clicking a menu while holding ⌘ opens it; releasing ⌘ with the menu open keeps it
   faded (depends on the HIToolbox distributed notification reaching MenuSprite).
4. Boards open under their strip sprite and close on an outside click.

Not built: per-app readings (frontmost app CPU, RAM, CPU-energy, running time) for strip sprites.
That was the first idea in the request and is the natural next step.
