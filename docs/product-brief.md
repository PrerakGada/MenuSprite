# MenuSprite product brief

MenuSprite is a personal-first, native macOS-only menu bar playground. The intended
workflow is a visual builder inspired by Scratch: choose items, connect optional
data sources, set behavior, customize presentation, and arrange a personal menu bar.

## Agreed product scope

- Menu bar organization and custom items in one app.
- Icons, user images, text, font color, weight, style, size, and optional animation.
- User-controlled refresh timing, including exploring event-driven updates.
- Optional system metrics, data, and logs, subject to available macOS APIs and
  appropriate user permissions. Do not promise unrestricted access.
- Visual building blocks and basic scripting as an extension of the GUI workflow.
- A choice of sprite characters; the main app logo is a sprite operating a bar.
- Native macOS technology, low idle CPU, small RAM footprint, and leak prevention.
- Build for Prerak's own daily use first, with the goal of avoiding extra paid
  utilities. Potential future open source; no public licensing commitment yet.

The app aims to consolidate menu bar tools, but complete third-party app control,
API feasibility, scripting runtime, supported macOS versions, and release scope
remain to be designed. Windows and cross-platform app implementation are out of scope.

## Current implementation boundary

The repository contains the brand data and a public landing page. The page includes
an interactive browser concept with simulated readings. It is not a native macOS
app and does not read operating-system metrics or logs. Uploaded demo images stay
in the browser tab; there is no upload endpoint. The native app has no scaffold yet.

The page describes the vision and current planning state, with no fake download,
waitlist backend, performance benchmark, shipping date, or published source repo.

## Website acceptance map

| Outcome | Implementation | Verification |
| --- | --- | --- |
| Slim rail brand and Arranger pose | `brand/`, `site/assets/` | Visual comparison with selected reference |
| Customizable menu bar story | Hero and interactive concept | Desktop/mobile browser review |
| Fonts, colors, icons/images, animation, refresh | Playground controls | Exercise each state and reset |
| Optional metrics and logs | Sources section and FAQ | Copy review against scope above |
| Visual GUI plus scripts | Builder section | Distinguish vision from browser demo |
| Native, personal-first, lightweight, free goal | Principles and status | No unmeasured claims |
| Sprite choices | Character gallery | Select each preview |
| Brand variants available | Brand pack download | Open archive and verify manifest |
| Public deployment and domain | Vercel project `menusprite` | HTTPS and canonical-domain checks |
