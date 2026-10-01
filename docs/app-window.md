# One MenuSprite window

29 September 2026, Prerak's request: every full page MenuSprite opens lives in **one window with a
tab per page**, and MenuSprite shows in the Dock while that window is open, so it behaves like any
other app — ⌘-Tab, Stage Manager, Mission Control — instead of loose windows floating over others.

## What changed

Before, five separate windows opened from the menu bar: Monitoring & Sprites, Power Controls,
Dynamic Island settings, Work & Clients and Permissions & Access. The app stayed `.accessory` (no Dock
icon) all the time, so those windows had no app to belong to in Stage Manager or ⌘-Tab.

Now `AppWindowController` (`native/Sources/MenuSprite/AppWindow.swift`) owns one window:

- **Toolbar tabs** (preference style, icon over label): Sprites · Controls (Awake in the public build) ·
  Island · Work (local build only) · Access. The window title follows the page.
- **Every entry point opens its tab**: the hub footer (Sprites, Controls, Island, Access), the Hub's
  Work "Open" button, the app menu, a sprite's Edit, the island's Settings button and section links,
  Island's "Open Permissions…", the energy board's settings button. They all still call
  `showMonitoring()` / `showPower()` / `showIslandSettings()` / `showWork()` / `showSettings()`,
  which now select the tab.
- **Dock icon while open**: showing the window sets `NSApp.setActivationPolicy(.regular)`; closing it
  sets `.accessory` again. Minimising keeps the Dock icon (the window lives there). Clicking the Dock
  icon, or launching MenuSprite again, reopens the window on the last page.
- **One page alive at a time.** A page is built when its tab is chosen and released when another tab
  is chosen or the window closes, with the same open/close calls the separate windows made
  (`setLibraryOpen`, `PowerStore.opened/closed`, `PermissionStore`, `WorkStore`, the Island page's
  observers and preview sampling). Switching tabs therefore costs what closing and opening a window
  did, and a hidden page samples nothing. Consequence: a sprite open in the studio closes when you
  switch tabs, as it did when the window closed.
- The window keeps its size across tabs; a page only passes its minimum size up
  (`NSHostingView.sizingOptions = [.minSize]`), so the window grows if a page needs more room
  (the studio needs 1120 pt) and never shrinks on its own. Frame autosave name `MenuSpriteWindow`.
- The cross-page buttons in the Sprites and Controls page headers were removed — the toolbar has them.
- ⌘W closes the window, ⌘M minimises, ⌘H hides.

## What did not change

The menu-bar pop-ups stay pop-ups: the hub, AI Accounts, the RAM/CPU/Power boards and the energy
dashboard are non-activating panels anchored to the menu bar. The Island's own floating tool windows
(scratchpad, file shelf, command bar) are part of the island, not settings pages.

## Validation

Builds; all 959 tests pass. The validation harnesses still find the page through
`settingsWindow` / `monitoringWindow` / `powerWindow` / `workWindow`, which now return the one window
while it shows that page. **Not yet exercised on screen**: the Dock icon appearing and going, the
toolbar tabs, Stage Manager grouping.
