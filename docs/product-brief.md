# MenuSprite product brief

**Immediate step:** [Permissions & Access](permissions-page.md). One transparent
page for MenuSprite's permissions, statuses and management actions comes before
the personal utility implementations. This first native step is now implemented;
see [native validation](native-validation.md) for evidence and limitations.

**Subsequent implemented step:** read-only [system monitoring](system-monitoring.md)
and visual configuration of which readings/sprites appear in the menu bar. The next
explicitly authorized step is now implemented in [Power Controls](power-controls.md):
ordinary keep-awake, with battery/closed-lid helper code awaiting privileged hardware acceptance.

**Current priority, 8 September:** [First personal build](first-personal-build.md).
Focus on Prerak's important daily tools and very low memory use. Marketplace,
social and public extension-platform work are retained for later; they do not
block the first usable app. The six daily-tool areas are recorded in that brief;
capture/clipboard details and fan-control depth remain for later steps.

The [native planning pack](planning/README.md) expands this brief into a working
PRD, feature specification, architecture, and acceptance plan. It is a discussion
draft: proposed details are not settled decisions. The separately authorized native
foundation and permissions page do not authorize the rest of that pack.

MenuSprite is a native macOS playground for creating, installing, customizing,
running, and sharing small tools called sprites, starting with Prerak's daily use.
The menu bar is a central home; intended scope also includes system tools,
desktop/app switching, shortcuts, monitoring, Homebrew, and other helpers.
The visual builder is inspired by Scratch. See the
[7 September direction clarification](planning/sprite-platform.md).

## Agreed product scope

- Menu bar organization and custom items in one app.
- A sprite means the customizable tool/menu bar item, including its appearance,
  interactions and background behavior. It is not merely a character asset.
- Every sprite must have an identity icon or mini logo. It can be hidden from the
  menu bar; visibility is separate from enablement and does not remove its icon.
- A sprite may also have a custom expanded menu board, opened by clicking its
  icon, with custom UI and data rendered inside it. The board is optional.
- Add/Create Custom Sprite and Install Sprite, including versioned scripts for
  personal integrations; Claude/Codex usage and Docker are named examples.
- Broad utility replacement, starting with vorssaint/vorssaint-utils, which Prerak
  already uses; remaining apps and precise replacement workflows are to be listed.
- Community creativity, a marketplace for sharing/downloading sprites, likes,
  and friends; exact social behavior, accounts, and release order are undecided.
- Icons, user images, text, font color, weight, style, size, and optional animation.
- User-controlled refresh timing, including exploring event-driven updates.
- Optional system metrics, data, and logs, subject to available macOS APIs and
  appropriate user permissions. Do not promise unrestricted access.
- Visual building blocks and basic scripting as an extension of the GUI workflow.
- A choice of sprite characters; the main app logo is a sprite operating a bar.
- Native macOS technology, low idle CPU, small RAM footprint, and leak prevention.
- Build for Prerak's own daily use first, with the goal of avoiding extra paid
  utilities. Potential future open source; no public licensing commitment yet.

The app aims to consolidate Mac utilities with deep personal customization.
Detailed tool windows, overlays, execution/package
contracts, marketplace architecture, third-party control, API feasibility,
supported macOS versions, and release scope remain to be designed. Windows and
cross-platform app implementation are out of scope.

## Current implementation boundary

The landing page now offers the signed, notarized 0.5.5 Preview 1 download and
Homebrew/DMG installation instructions for Apple Silicon on macOS 26+. It separates
the released monitoring, Claude/Codex usage, permissions and ordinary keep-awake tools from the browser
concept, future visual builder and sprite library. The broader platform direction
remains in planning.

The repository contains brand data, a public landing page, and a separate native
foundation in `native/`. The website includes
an interactive browser concept with simulated readings. It is not a native macOS
app and does not read operating-system metrics or logs. Uploaded demo images stay
in the browser tab; there is no upload endpoint.

The native app uses Swift, AppKit and SwiftUI. It has the MenuSprite menu-bar icon,
a settings window and all 36 rows of the Permissions & Access implementation,
including separate screen/audio modes and app-owned service/resource types.
It reads status through public APIs where possible, keeps unqueryable states
unknown, and offers explicit consent/settings actions. Launch-at-login registration
is the only configurable app service. A separate monitoring window now provides
CPU, memory, network, disk, GPU, battery and available read-only hardware readings.
Sprites can combine selected readings, configure appearance/units/refresh and open
a small history board. This is the first visual configuration slice; fan/battery
control, capture, clipboard history, the full block-based builder, marketplace,
social and mirroring tools are not built.
The native app does not use or host the website. Build details: `../native/README.md`.

The page links to the actual public release and Prerak's Homebrew tap. It states
the preview's compatibility and hardware-control limits, and explains installation,
first launch and updates. The public distribution repository contains release
assets and metadata; application source remains local. The site has no waitlist
backend or claimed performance guarantee.

## Website acceptance map

| Outcome | Implementation | Verification |
| --- | --- | --- |
| Slim rail brand and Arranger pose | `brand/`, `site/assets/` | Visual comparison with selected reference |
| Customizable menu bar story | Hero and interactive concept | Desktop/mobile browser review |
| Public preview download and installation | Hero, download section and FAQ | Published DMG checksum, Finder copy flow, Homebrew command and responsive checks |
| Fonts, colors, icons/images, animation, refresh | Playground controls | Exercise each state and reset |
| Optional metrics and logs | Sources section and FAQ | Copy review against scope above |
| Visual GUI plus scripts | Builder section | Distinguish vision from browser demo |
| Native, personal-first, lightweight, free goal | Principles and status | No unmeasured claims |
| Sprite choices | Character gallery | Select each preview |
| Brand variants available | Brand pack download | Open archive and verify manifest |
| Public deployment and domain | Vercel project `menusprite` | HTTPS and canonical-domain checks |
