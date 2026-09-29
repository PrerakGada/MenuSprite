# Sprite studio

29 September 2026 · Prerak's request: "the ability to customize the sprite is the main core feature".

## What he asked for

- The My Sprites list shows each sprite **exactly as the menu bar shows it**.
- Clicking a sprite turns **the whole right side** into its customization: design on the left,
  logic (values and rules) on the right.
- Design is **flexbox, not a form of dropdowns**: split a piece into a row or a column, merge,
  drag to rearrange, fixed text, value text, or both ("{value}%"), colour per piece.
- **Several values per sprite**: readings, or a CLI command's output.
- **Rules** in the spirit of Shortcuts/Scratch: when/if a value …, change that piece.

## What was built

**Model** (`SystemMonitoring/SpriteDesign.swift`, stored as `SpriteConfiguration.design`):

- `root`: a tree of `row` / `column` containers and `text`, `icon`, `bar`, `battery` leaves. A text
  is segments: typed text and `{value}` references. Style per node: colour (inherit / auto / hex),
  size, weight, fixed-width digits, alignment, opacity, hidden, shrink-to-fit; containers add gap,
  spread (start/centre/end/push apart/equal bands) and side padding.
- `variables`: a reading (`cpu.usage`…), a command (`/bin/zsh -f -c`, interval 2 s–1 h, timeout
  1–60 s, output as text / first number / JSON path), or fixed text. Per-value format: unit,
  decimals, °F, bits.
- `rules`: If / Otherwise if / Otherwise. Conditions compare a value (or an AI limit's pace) with
  above / at least / below / at most / is / is not / contains / unavailable / available, all or any.
  Actions: colour, hide, show, change icon, replace text, fade. Rules run top to bottom; a later
  rule wins. They restyle while they hold (no one-shot actions yet).

**Rendering** (`DesignRenderer.swift`): lays out the tree at menu-bar height (the bar holds two lines;
text in a column shrinks to fit, shrink-to-fit labels first), keeps tabular value slots at their
widest template so the item does not jiggle, and returns every node's frame for the studio canvas.
The status item, the studio canvas and the list all use it.

**Migration**: every sprite saved before the studio is converted on load
(`SpriteDesign.migrated(from:metric:)`); the file is copied to
`monitoring.before-sprite-studio-<date>.json` first, and the old settings stay in the file so an
older build still draws the sprite. The four layouts and the colour rules (pace, pace-%-only,
memory pressure, power draw, network direction, level-bar thresholds) become ordinary nodes and
rules — including "Hide % while <value> is unknown", which the old renderer did implicitly.

**Studio** (`MenuSprite/SpriteStudio*.swift`, opened from the list in Monitoring & Sprites):
header (identity icon, name, running, in menu bar, refresh, undo/redo, revert); zoomed canvas on a
dark or light bar (click selects, drag onto another piece moves it — edge nearest the pointer
decides beside vs above/below; palette pieces drag in or click to add beside the selection);
pieces outline; inspector; values with live readings and a command editor with Run now; rule cards
with live "true now" markers. Changes apply to the menu bar as they are made (saved 350 ms after
the last one). Every "edit sprite" entry point (menu-bar Configure…, hub, presets) opens the studio.

## Boards (what a click opens) — added 29 Sep

Prerak, same day: "whatever opens when you click on that particular sprite should also be customizable …
script the whole UI … with some premade things".

- `SpriteDesign.board` (`BoardDesign.swift`): nil keeps the **classic panel** (RAM/CPU process panel, Battery &
  Power, AI accounts, readings list), so no sprite changes until it is customised. A board is width, header
  on/off, and a tree of blocks — layout: stack, row, card (titled), divider, space; content: text (with
  `{values}`), big value, chart (a reading's history), gauge, stats list, button (run a command, open a
  link or app, copy text, refresh), command output; **script rows** (a command's output lines become rows,
  SwiftBar format: `Text | color= sfimage= href= bash= size= font=`, `---` divider, `--` indent); premade:
  process list (CPU/memory/power, with the quit buttons), Battery & Power dashboard, AI accounts board,
  readings with graphs.
- Boards share the sprite's values and rules; rule actions can target board blocks (colour, hide, show,
  text, button icon, fade).
- Studio: a **Menu bar / Board** switch on the design side. Board mode: live board canvas (click selects,
  drag a block onto another to move it, palette blocks click-to-add or drag in), outline, inspector.
  "Customize, starting from the current panel" builds a board around the matching premade block.
- An open board samples the readings it shows (and the Power metrics for the Battery & Power block) and runs
  its script rows; nothing runs while it is closed. It opens as a popover sized to its content.

## Evidence (29 Sep, off-screen only)

`MenuSprite --sprite-studio-render <dir>` works on a copy of the saved sprites:

- Old renderer vs converted design for Prerak's eight sprites: CPU, RAM, Power, Network, Battery
  **0 differing pixels**; Fan 464 px, Weekly AI 261 px, Claude 252 px — sub-pixel kerning where
  the "%" became its own text (same widths ±1 pt, visually identical at 4×).
- Studio screenshots for RAM (dark, light), Weekly AI and Network.
- Command runner: number, JSON path, first-line text, 1 s timeout (1.03 s), `yes` stopped at
  64 KiB, exit 3 reported; no orphaned child after the timeout.
- `SpriteDesignTests`: 9 tests (migration, rules, template parsing, tree edits, renderer fit);
  `BoardDesignTests`: 3 (block moves/wraps, round-trip and pruning, script-line parsing).
- Boards: studio Board mode for RAM (started from its classic panel) and a showcase board rendered as the
  click-open panel with live CPU value, gauge, chart, stats with a command value, script rows, a command
  button and the live CPU process list.

**Not verified**: nothing has been clicked or dragged on screen (Prerak was working), so the canvas
gestures, palette drag-and-drop and live-apply cadence are unexercised. CPU cost of the new
status-item drawing (two layout passes per refresh per sprite) is unmeasured.

## Not built yet

- One-shot actions on a rule becoming true (notification, run a command). Buttons are the only one-shot actions.
- Board popover has not been opened from the real menu bar; block drag-and-drop is unexercised on screen.
- Rule targets on individual characters (the "%" is split into its own text instead).
- Animation, images, and more than two lines of height (the menu bar has no more room).
- Import/export of a sprite and anything marketplace-shaped.
