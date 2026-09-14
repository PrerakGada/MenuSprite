# MenuSprite product requirements

Working draft · 7 September 2026 · Planning only

Updated with [Prerak's sprite-platform clarification](sprite-platform.md).
The initial menu-bar-only boundary and character-only meaning of sprite are
superseded. Every sprite requires an identity icon; menu bar presence is optional.
Detailed broader UI surfaces remain proposals.

## Product definition

MenuSprite is a native macOS playground for creating, installing, customizing,
running, and sharing tools called **sprites**. It combines menu bar organization
with custom monitors, system tools, shortcuts, and helpers. A person chooses a
sprite's appearance, information, interactions, and behavior. Personal daily use
is the starting point; community creation and discovery belong to the vision.

**The core experience must work through an approachable visual GUI.** Writing a
script is an extension. Opening the builder, changing appearance or behavior,
and seeing the result should feel like making something, not editing a large
preferences form or maintaining a collection of scripts.

## Problem and audience

The main frustration is inconsistent, largely fixed appearance and interactions
across utilities. Prerak already uses vorssaint/vorssaint-utils and wants to
replace it along with other small tools. He wants the broad system-helper scope,
not only status readouts. Exact daily-used functions and remaining utilities
still need an inventory; preserve the full-suite replacement ambition.

First user: Prerak. Intended community: Mac users who create, install, customize,
and share sprites. A marketplace, likes, and friends are now explicit product
intent. The MenuSprite source license is MIT (selected 14 September 2026).
Account/social mechanics, release order, third-party sprite licensing, monetization,
and broad OS coverage are undecided. Propose independent local operation for installed
sprites, with online services for community features.

## Confirmed requirements

| ID | Requirement | Consequence |
| --- | --- | --- |
| R-01 | Organize the Mac's menu bar | Existing-app organization remains a first-class goal; custom items alone do not complete the product. |
| R-02 | Build custom items visually, inspired by Scratch | Provide connectable behavior blocks and visual presentation editing; presets alone are insufficient. |
| R-03 | Customize icons, user images, text, font color, weight, style, and size | Changes affect MenuSprite-owned items; equivalent control over other apps is not established. |
| R-04 | Optional animation and sprite choices | Static use is complete; animation has an explicit resource policy. |
| R-05 | Choose refresh behavior and frequency | Expose suitable update policies, including event-driven options where available. |
| R-06 | Optional system data, metrics, and logs | Enable sources individually; permission denial and unavailable data are normal states. |
| R-07 | Basic scripts as an extension | Scripts integrate with the visual workflow; built-in items need no scripting runtime. |
| R-08 | Native macOS technology | Native status items, controls, lifecycle, accessibility, and platform integration. |
| R-09 | Minimal idle CPU, small RAM footprint, no leaks | Define and measure budgets; active scripts and animation must be accounted for. |
| R-10 | Personal daily use first; avoid extra paid utilities for selected workflows | Prioritize the actual replacement list over an arbitrary library of widgets. |
| R-11 | Planning before development | No scaffold, application code, native experiments, or release activity in this phase. |
| R-12 | A sprite is the customizable tool, not merely its artwork | Appearance, click interactions, data, actions, and behavior belong to its definition; include Add/Create Custom Sprite. |
| R-13 | Installable versioned sprites | Support packaged scripts and dependencies, configuration, installation and updates; do not reduce this to static template import. |
| R-14 | Broader system tools and helpers | Desktop/app switching, Homebrew, monitors, shortcuts, and other utility jobs belong in the product discussion. Menu bar geometry does not exclude them. |
| R-15 | Community and marketplace | Creation/sharing, discovery/download, likes, and friends are intended capabilities; exact social mechanics and delivery order remain open. |
| R-16 | Preserve the user's creative control | Installed sprites must support meaningful customization of appearance and interactions; document the editing boundary of custom code and preserve personal changes on updates. |
| R-17 | Required identity icon, optional menu bar presence | Every sprite has an icon/mini logo even when hidden from the menu bar. Visibility and enablement are separate states; a hidden sprite retains its identity and enabled behavior. |
| R-18 | Optional custom expanded menu board | A sprite can define a board opened by clicking its icon, with its own custom UI and rendered data. The board belongs to that sprite and is not mandatory for every sprite. |

## Proposed product structure

The working nouns are **sprite**, **source**, **block**, **action**, **surface**,
**layout**, **profile**, **package**, and **template**. A character is optional
artwork. Existing "item" wording in detailed bar specifications refers to a
sprite's menu bar presentation or an external app's item, not a competing product
concept. The earlier character-only definition was wrong and is replaced.

A sprite owns its appearance and behavior. Propose a menu bar face, click-open
content, a tool window, a shortcut overlay, and/or background behavior as possible
surfaces/modes. Every sprite must have an identity icon; a permanent menu bar
face is optional. Sources provide values; blocks connect events, values, conditions,
and actions. Profiles preserve enabled sprites and arrangements. Templates create
editable starting points; packages distribute versioned sprites and code.

There are two kinds of items in the organizer:

- **MenuSprite items:** created by this app; appearance, sources, and behavior can
  be edited here.
- **Other apps' items:** owned by those apps; supported organization operations
  depend on macOS and the validated adapter. Their internal UI and behavior do
  not become editable blocks automatically.

## Proposed primary workflows

### W-01: Make a useful item without code

Open MenuSprite → choose a template or Blank Item → select an icon/text/image →
connect a source → format its value → preview actual output → place in the bar.
Save, close the editor, and continue using the item. Reopen it later without losing
its visual structure. Clock and battery are illustrative templates, pending the
personal replacement list.

Acceptance: all steps are possible without a terminal, JSON, or a script. The
editor can label sample data explicitly when a live source is unavailable.

### W-02: Add behavior visually

Open an item → add a trigger → attach a source/value block → add a condition →
change appearance or perform an action. Example: show an amber CPU indicator when
a selected threshold is exceeded. Preview a normal, high, unavailable, and stale
input. Display changes use the latest value; notifications fire on meaningful
transitions with a cooldown rather than repeatedly on every sample.

Acceptance: the graph remains editable, invalid connections explain their type
problem, and testing a display condition does not accidentally run a command.

### W-03: Build a custom expanded menu board — confirmed, controls still proposed

A sprite may have a custom expanded menu board that opens when its icon is
clicked. The user designs the UI and connects the data rendered inside it. The
board is part of the sprite definition; sprites without a board retain their
other configured behavior. Exact layout/control choices below are proposals.

Open the item's click behavior → choose a simple menu or a custom popover → add
readings and controls → connect actions → preview → apply. A user could show a
reading in the bar and a short history plus related actions underneath it.

Acceptance: content is native, keyboard accessible, dismisses predictably, and
shares source state with the sprite's other surfaces. The supported layout/control
palette is still proposed; a larger job may open a tool window under the new
surface proposal rather than being forced into a small popover.

### W-04: Organize a crowded menu bar

Open Arrange → see MenuSprite items and identifiable existing items → choose
always-visible and hidden items → arrange the supported items → preview/apply →
reveal hidden items when needed. Retain a recovery route to MenuSprite and an
undo/restore path. Clearly indicate unsupported items and disconnected apps.

Acceptance: verify against Prerak's real applications, a notched display, external
display changes, sleep/wake, fullscreen, and automatic menu bar hiding. A manual
Command-drag fallback can finish placement where appropriate, but does not count
as implementing an automatic arranging promise.

### W-05: Use a personal data source or script

Add a source → choose a file, request, Shortcut, or script → configure input and
refresh → inspect output → bind a value to the item. Show dependencies and errors
at the affected source. Scripts are reviewable and explicitly enabled; imported
executable content does not run merely because a file was opened.

Acceptance: a slow, failed, or missing dependency cannot freeze the menu bar or
quietly turn a missing value into zero. All other items keep working.

### W-06: Save and switch a setup — proposed

Duplicate a profile → change enabled items and layout → switch profiles → return
to the previous setup. Share a template or export a complete setup; import first
shows an editable preview and any missing local dependencies.

Acceptance: round-trip without losing blocks/assets; credentials and OS grants
are not exported. Profile switching changes future execution, with clear treatment
of already-running actions; it cannot undo external side effects.

### W-07: Recover and understand resource use

When something fails, the item remains reachable with a useful state. Inspect its
last successful update, error, and activity. Pause one source or all automation.
Recover the last valid configuration or launch with executable integrations and
third-party organization disabled.

Acceptance: a malformed configuration, denied permission, runaway script, or
organizer failure cannot permanently lock the user out of the builder.

## Whole-product coverage

The expanded direction adds installable packages and community lifecycle, plus
broader system tools. See feature families SPRITE, TOOL, PKG, and COMMUNITY and
[sprite-platform.md](sprite-platform.md). These are not optional ideas introduced
by the assistant; their detailed behavior and release sequencing still need design.

The [feature specification](features.md) covers organization, visual creation,
styling and sprites, menus/popovers, sources, behavior, scripting, templates and
profiles, app lifecycle, accessibility, privacy, performance, and recovery. Its
candidate section keeps possible utilities visible without promising them.

An implementation sequence is a dependency order, not permission to remove
confirmed features from the product. If organization proves narrower than the
desired workflow, return that product decision to Prerak.

## Proposed boundaries

- The menu bar is a central home for sprites; broader tool windows, shortcut
  overlays, and background modes are proposed so system helpers fit naturally.
  Desktop/app switching and window-related utility jobs are included for planning.
- macOS remains the native target. Cross-platform and browser-extension products
  have not been requested.
- Installed local tools should work independently of marketplace availability.
  Hosted discovery, publishing, likes, and friends need an online-service design;
  no mandatory account for purely local use is proposed.
- No general promise of modifying other apps' icons, changing menu bar height,
  forcing arbitrary per-display placement, or reading unrestricted system logs.
- Hardware control, process termination, and privileged monitoring require explicit
  capability contracts and native feasibility; reading a metric does not grant a
  write operation. They are not excluded merely because they exceed the bar.
- Long-term time-series storage, cloud sync, and AI-generated sprites remain
  candidates. Marketplace creation/installation and social features are now part
  of intended scope, with exact functionality to be discussed.

These are recommendations, not new user-approved exclusions. The discussion can
change them.

## Product success and release condition

Agree a concrete daily-use list, then complete every selected workflow end to end.
Prerak can build and revise items without scripts; organize supported real items;
use the app after restart and display changes; and inspect stale data and errors.
The agreed CPU/RAM and recovery checks pass with that setup.

No replacement claim until the named old utility's selected jobs work. No "native
verified" claim based on the website, API documentation, a unit test, or this PRD.
Proposed measurable checks and the full requirement trace are in
[acceptance.md](acceptance.md).
