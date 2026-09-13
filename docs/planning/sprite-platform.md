# Sprite platform direction

7 September 2026 · Discussion update · Planning only

This incorporates Prerak's clarification after the first planning draft.
His [original voice-typed message](discussions/2026-09-07-sprite-platform.md)
is preserved. This direction supersedes the earlier menu-bar-only boundary,
character-only definition of sprite, and treatment of a marketplace as merely
an unsolicited candidate. The detailed architecture is still a working proposal.

## Confirmed direction

**A sprite is the user-created or installed tool, including its appearance,
interaction, and behavior.** Prerak explicitly calls a menu bar item a sprite.
It is not restricted to an animated character. Character artwork is an optional
part of a sprite's presentation.

Customization is the central reason to build MenuSprite. Existing utilities
bring their own fixed appearance and interactions. Users should be able to design
their own sprites, including what they show, what happens on click, and their
behavior. The product must expose **Add / Create Custom Sprite** and **Install
Sprite** as direct workflows. The visual builder is still foundational.

Installable sprites can contain versioned scripts/background behavior, such as
Claude usage, Codex usage, Docker monitoring, or commands for a particular app.
These are confirmed examples, not verified data integrations; no usage endpoint,
credential method, or measurement meaning has been established.

The intended product also includes system tools, shortcuts, desktop/app switching,
monitoring, Homebrew management, and other helpers. The menu bar must not exclude
these jobs. Prerak wants the breadth represented by Vorssaint and other utilities,
with creative freedom and a common customizable host.

Community creation, a marketplace for downloading other people's sprites, likes,
and friends are part of the intended product vision. Their release order and
exact mechanics are still to be discussed. Open-source licensing and monetization
are separate undecided questions; a marketplace does not imply paid sprites.

## Proposed way to fit the product together

**MenuSprite is a native Mac playground for creating, running, customizing, and
sharing small tools called sprites. The menu bar is its home and a presentation
surface, not the limit of what those tools can do.** This is proposed positioning.

One sprite owns a definition of its UI, triggers, actions, data, settings, and
background work. It can expose an appropriate combination of surfaces:

| Surface / activation | Proposed fit |
| --- | --- |
| Menu bar face | A persistent reading, icon, progress indicator, or shortcut. |
| Click-open menu/popover | Related details and compact controls. |
| Tool window | A larger working interface, such as package search and management. |
| Shortcut-invoked overlay | A switcher, command palette, or quick control surface. |
| Background behavior | A selected monitor or system behavior with controls/status available in My Sprites. |

**Confirmed: every sprite must have an icon or mini logo, but it need not be
shown in the menu bar.** Its visual identity exists independently of menu bar
visibility. Hiding it from the bar is separate from disabling its behavior.
Propose using that icon in My Sprites, the editor and marketplace listings; it
does not replace the stable technical ID. Broader surface details remain proposed.

Illustrative mapping, based on Prerak's examples rather than verified APIs:

| Sprite | Visible experience | Work it owns |
| --- | --- | --- |
| Claude / Codex usage | A chosen bar design; click for account/usage detail | Explicitly selected, validated data integration; configurable refresh. |
| Docker monitor | Count/state in the bar; list and actions in a panel/window | Container data and user-invoked operations through a configured connection. |
| Homebrew manager | Optional updates badge; searchable management window | Discover packages, inspect details, run selected operations with progress. |
| App switcher | Keyboard-triggered overlay; customizable layout/order/style | Native app/window discovery and activation. |
| Desktop/Spaces switcher | Shortcut, optional bar control, and optional overlay | Supported workspace actions; native feasibility still required. |
| Input helper | Optional status/control face; configuration in My Sprites | Enabled keyboard/mouse behavior, with reliable disable and restoration. |

This means "anything creative" can compose supported capabilities and add custom
code. It does not mean a visual block can invent a missing macOS API. New deep
system capabilities need native engineering behind the builder or an accepted
extension mechanism. Their UI should still participate in the customization model.

## Customization must survive installation and updates

Follow-up confirmed: a sprite can optionally have a **custom expanded menu board**
opened by clicking its icon, with custom UI and data rendered inside it. Board
presence is distinct from the required icon, menu bar visibility and enablement.
Exact controls/layout are still to specify. Propose also making the board
accessible from My Sprites when its menu bar icon is hidden.

Propose a shared visual language and personal theme defaults, with per-sprite
overrides. Installed sprites should expose their declared layout, face, actions,
and settings in the builder. A custom-coded component must identify what is
editable and what requires editing/forking code. Do not advertise every binary's
internal behavior as magically editable without source or exposed controls.

Store the published package/version separately from a user's instance and local
customizations. Update code without casually overwriting the person's appearance,
bindings, shortcuts, or settings. Show incompatible changes; retain a previous
working package and support a separate editable fork when needed. Configuration
rollback does not reverse a package operation or script's external side effects.

The planned primary journeys become Create → Preview/Test → Use; Discover →
Install → Configure/Customize → Use; and Create/Remix → Publish → Version/Update.
Exact remix permissions, publishing rules, identity, likes, and friend mechanics
remain proposals to specify, not assumptions about licensing or social behavior.

## Architectural consequence

Keep the native host responsible for the editor, surfaces, theme, source sharing,
execution lifecycle, permissions, installation/versioning, and diagnostics.
Sprites declare which capabilities and surfaces they need. Native capability
providers handle OS integration; scripts handle configurable custom integrations;
some explicitly enabled services may need to stay active while their UI is closed.

Finite scripts alone do not cover app switching, input interception, streaming
monitors, or long package operations. Define distinct execution classes and a
supervisor before promising resource bounds. Do not run arbitrary marketplace
code inside an input-event callback or assume scripts are sandboxed by a manifest.

A separate online component will be needed for hosted marketplace/social features.
Propose that installed local sprites keep working independently of community
availability; account and identity requirements apply to the online features as
chosen. No backend, protocol, plugin ABI, or sandbox model is settled yet.

The major product challenge is enabling broad customization while keeping each
installed sprite's cost and access understandable. The low CPU/RAM requirement
survives the scope expansion; work starts because a sprite needs it, not because
its package is installed.

## Vorssaint reference and replacement evidence

Prerak already uses [vorssaint/vorssaint-utils](https://github.com/vorssaint/vorssaint-utils)
and wants to replace it alongside other unnamed tools. Its documented scope
includes monitoring, switching/window tools, input helpers, and Homebrew. This
supports the breadth discussion; individual daily-used functions remain to list.
No parity claim or installed-app inspection has occurred.

Source reviewed at commit `4b12b976c3cf77e84800d1358a6011268da1e48c`:

- [FeatureCatalog.swift](https://github.com/vorssaint/vorssaint-utils/blob/4b12b976c3cf77e84800d1358a6011268da1e48c/Sources/Vorssaint/Core/FeatureCatalog.swift): separately identified feature families and permission needs.
- [HomebrewManager.swift](https://github.com/vorssaint/vorssaint-utils/blob/4b12b976c3cf77e84800d1358a6011268da1e48c/Sources/Vorssaint/Services/Homebrew/HomebrewManager.swift): package state and operations are a service behind the interface.
- [AppSwitcher.swift](https://github.com/vorssaint/vorssaint-utils/blob/4b12b976c3cf77e84800d1358a6011268da1e48c/Sources/Vorssaint/Services/Switcher/AppSwitcher.swift): native panel and event-tap lifecycle.
- [SmoothScrollService.swift](https://github.com/vorssaint/vorssaint-utils/blob/4b12b976c3cf77e84800d1358a6011268da1e48c/Sources/Vorssaint/Services/SmoothScrollService.swift): enabled input behavior uses an event tap with start/stop handling.

Inference from these excerpts: the location of a tool's entry point does not
define the scope of its service. MenuSprite can provide broader surfaces while
retaining its menu bar identity. This is not proof of API support on every Mac
and not an instruction to fork or copy the reference project.

## Next discussion

Icon identity and optional bar presence are settled. Next walk through a usage
monitor, Homebrew manager, and app switcher as examples of the
same creation/install/customization experience. Keep the other tools in the
replacement inventory as Prerak names them. Detail marketplace/social behavior
after this core model is coherent; do not delete it from the product vision.
