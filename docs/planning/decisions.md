# Decisions and discussion

Working draft · licensing updated 14 September 2026

**Current priority:** [First personal build](../first-personal-build.md). Prerak
asked to stop overengineering the discussion, defer marketplace and related
expansion, and focus on his important daily tools with very low memory use.
Older platform questions below are not prerequisites for that build.

**Latest steering:** permissions overview first; go gradually rather than jump
into an MVP. See [Permissions & Access](../permissions-page.md) and D-24. Do not
expand the utility implementation plan as the immediate task.

**Licensing update, 14 September 2026:** Prerak selected MIT for MenuSprite. The
license is in the repository root; source is published at
[PrerakGada/MenuSprite](https://github.com/PrerakGada/MenuSprite). This
supersedes the earlier licensing deferral below without changing marketplace scope.

## Confirmed before this planning pass

Native macOS only; personal daily use first; menu bar organization plus custom
items; Scratch-inspired visual building; fonts/colors/icons/images; optional
animation and sprite choices; chosen data sources and refresh timing; basic
scripting; low CPU/RAM and leak prevention. Potential later open source. The
website remains a separate, simulated concept. No native implementation exists.

Confirmed this session: discuss and document the whole product and architecture;
do not develop it yet.

## Direction clarified during discussion

Prerak corrected the first draft: **sprite means the customizable tool/menu bar
item, not a character asset**. Appearance, click behavior, and background behavior
must be customizable. He wants Add/Create Custom Sprite, versioned installable
sprites/scripts, a marketplace, likes, and friends. He already uses and wants to
replace vorssaint/vorssaint-utils, plus other unnamed tools. Broader system tools,
desktop/app switching, Homebrew management, shortcuts, monitoring and helpers
belong in scope. See [sprite-platform.md](sprite-platform.md) and the preserved
[voice-typed message](discussions/2026-09-07-sprite-platform.md).

The prior menu-bar-only boundary, character-only definition, finite-script-only
extension ceiling, and marketplace-as-unrequested-candidate treatment are
superseded. Prerak subsequently confirmed that every sprite must have an icon or
mini logo, while showing it in the menu bar is optional. Tool windows/overlays
remain proposed surfaces; their detailed architecture is not yet confirmed.

## Questions sent to Prerak

1. Which menu bar apps should MenuSprite replace, and what should be visible or
   clickable in the ideal bar? A rough voice dump is sufficient.
2. Should the visual builder cover custom dropdowns/popovers with controls and
   actions, or only the item with predefined click actions?

Answers now available: Vorssaint is the first named replacement; Claude usage,
Codex usage, Docker monitoring, app/desktop switching and Homebrew are explicit
examples. Complete customization of click behavior is confirmed; exact popup,
window and overlay controls remain to design. Other apps and precise daily-use
acceptance examples are still unknown.

## Decision register

| ID | Decision to make | Working recommendation | Status / impact |
| --- | --- | --- | --- |
| D-01 | Actual utilities and daily workflows to replace | System RAM/CPU/power (Vorssaint), network rates ("Scalar"), fan RPM/temperature (Macs Fan Control), battery UI/charge limit (AlDente Pro), CleanShot and Paste | Actual list supplied 8 September; see first-personal-build.md. Fan control depth, extra AlDente controls and exact CleanShot/Paste workflows remain to specify. |
| D-02 | Custom expanded menu board | A sprite can optionally define a custom expanded menu board that opens on clicking its icon, with custom UI and rendered data | Confirmed by Prerak, 7 September. Whether the sprite has a board is independent of icon identity, bar visibility and enablement. Exact controls/layout and native rendering remain to specify. |
| D-03 | Visual builder model | Connected Scratch-like event stacks with typed value sockets; live presentation preview alongside | Proposed; validate against one simple and one advanced personal example. |
| D-04 | OS and hardware coverage | First validate on Prerak's current Mac; consider macOS 26+ and Apple silicon for initial delivery | Proposed; local `sw_vers` reports 26.6.2, not a decision about all supported machines. Confirm secondary Mac OS and broader sharing needs. |
| D-05 | Native stack | Swift, AppKit for status-item ownership/lifecycle; SwiftUI for editor and popover content | Proposed; see architecture alternatives. |
| D-06 | External item organization | Keep it in the product; isolate OS-sensitive techniques behind a capability-reporting adapter | Goal confirmed; exact feature coverage and compatibility technique require investigation and discussion. |
| D-07 | Undocumented APIs / OS-sensitive automation | Prefer documented APIs; report gaps; choose whether to accept compatibility-sensitive methods after investigation | Open; do not infer acceptance or exclude organization unilaterally. |
| D-08 | Distribution and sandbox | Direct app delivery initially, with signing/notarization before sharing; evaluate sandbox constraints with source/script requirements | Proposed; no App Store commitment and no claim that subprocesses are a security sandbox. |
| D-09 | Scripts and extensions | Versioned packages; finite jobs, sustained services where needed, and native capabilities behind the builder | Installable code/background behavior confirmed; runtimes, isolation, native extension mechanism and package contract open. The finite-only ceiling is superseded. |
| D-10 | Profiles and sharing | Local profiles and portable packages; community publishing/discovery; local customization separate from upstream version | Sharing/installing confirmed; profile behavior, sync and upgrade merge mechanics proposed. |
| D-11 | Sources and built-in templates | Start from D-01; low-cost local clock/battery/CPU/memory/storage plus selected file/HTTP sources are draft examples | Open catalog; metric definitions need agreement in implementation specifications. |
| D-12 | Performance budgets | Use the provisional workloads and numbers in acceptance.md, benchmark before treating them as release thresholds | Proposed targets, never measured claims. |
| D-13 | Meaning of sprite | The whole customizable tool/menu bar item: presentation, interactions, data and behavior | Confirmed correction, 7 September. Character artwork is optional and no longer defines the noun. |
| D-14 | Entire menu bar appearance | Keep item styling core; whole-bar tint/shapes/background treatment requires explicit scope choice and native validation | Candidate; not implied by custom item font/color support. |
| D-15 | Public product policy | MIT for MenuSprite source, documentation and project artwork | Confirmed and source published 14 September 2026. Third-party sprite terms, monetization and support promises remain separate decisions. |
| D-16 | Broader utility scope | Include system helpers, desktop/app switching, Homebrew, monitors and shortcuts | Confirmed intent, 7 September; do not exclude these because they exceed menu bar geometry. |
| D-17 | Sprite icon and menu bar visibility | Every sprite has an identity icon/mini logo; showing it in the menu bar is optional and independent of enablement | Confirmed by Prerak, 7 September. Hidden from the bar does not mean iconless or disabled. |
| D-18 | Marketplace and community | Retain the vision for later; no further marketplace/social design needed for personal use | Deferred by Prerak, 8 September. Not part of the first personal build and not an architecture prerequisite. |
| D-19 | Customization after installation/update | Shared theme and editable presentation/behavior; separate user overrides from upstream package | Deep customization confirmed; edit/fork/merge contracts and code-component boundaries proposed. |
| D-20 | Broader sprite surfaces | Native popup, tool window, shortcut overlay and My Sprites management, sharing sprite state | Proposed; D-17 settles icon/visibility, not every surface detail. |
| D-21 | Reuse data displayed by other menu bar apps | Preserve external-reader idea and existing research for possible later use | Parked as low priority by Prerak, 7 September: this discussion was going too deep in an unimportant direction. Do not continue V-10 or expand cloning/mirroring design unless brought back into scope. Not a blocker for core sprite planning. |
| D-22 | First personal build | Important daily tools, visual sprite customization and custom expanded boards, with very low measured memory use | Confirmed priority, 8 September. Finish the actual tool checklist; defer broad platform/community contracts and avoid another exhaustive planning exercise. |
| D-23 | Personal replacement scope supplied | Six areas: system readings, network rates, fans/temperature, battery management, capture, clipboard | Confirmed by Prerak, 8 September. Monitoring is the proposed first usable path; battery control and used CleanShot/Paste workflows remain replacement goals. Earlier Docker/usage/switching/Homebrew examples are not first-build obligations by default. |
| D-24 | Permissions page first | One page listing public app-permission categories for supported macOS, scoped access, purpose/used-by and management actions, inspired by Vorssaint | Confirmed priority, 8 September. Scope interpreted as MenuSprite/owned helpers. OS-controlled grants/revokes require supported prompts or Settings; unverifiable states remain unknown. Page specified this turn; no MVP/native implementation started. |

## Discuss in this order

Address Permissions & Access first. Keep the actual tool list and outstanding
fan/battery/capture/clipboard details for subsequent steps; do not press those
questions while Prerak is defining this page. Keep the native page lightweight.
Do not reopen community design, package contracts, external-app mirroring or an
MVP implementation plan.

## Updating this pack

For each accepted decision, add its date and rationale here, then update the PRD,
feature spec, architecture, and affected acceptance scenarios in the same pass.
Keep rejected alternatives when they explain a consequential tradeoff. Do not
turn a non-response into agreement. Avoid marking all features "v1" before D-01.

## Resume instructions

Read this file and the planning index first. The native app is still unscaffolded.
Continue the discussion from unresolved decisions; do not restart discovery of
the brand or rebuild the website. When Prerak explicitly starts development,
confirm the accepted baseline and run the named native investigations before
committing to OS-sensitive behavior. Record real findings against their IDs.
