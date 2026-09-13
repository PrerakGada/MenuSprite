# MenuSprite feature specification

Working draft · 7 September 2026

**Current personal scope, 8 September:** follow [First personal build](../first-personal-build.md).
Prerak's actual list is system RAM/CPU/power, network rates, fans/temperature,
AlDente-style battery UI/charge limit, CleanShot workflows and Paste workflows.
Those supersede the older candidate/prioritization labels below for personal work.
Exact capture/clipboard features and additional hardware controls remain to specify.

Updated scope: [Sprite platform direction](sprite-platform.md). A sprite is the
customizable tool, not its character artwork. Existing item/bar specifications
describe one surface of a sprite. Broader utilities, installable packages and
marketplace/community requirements are added below; their exact designs remain
open. The original 73 entries are not a ceiling on the product.

The original brief confirms product goals, not every behavior below. In the
tables, **C** means the category is grounded in a confirmed requirement; **P** is
a proposed addition; **V** means native validation is also required. All precise
interaction details are draft specifications. Candidate extensions are listed at
the end. No feature is implemented in the native app.

## 1. Menu bar organization

| ID | Feature | Draft behavior / acceptance | Basis |
| --- | --- | --- | --- |
| ORG-01 | Inventory | Show MenuSprite items and discoverable items from running apps, identified by owner where possible. Distinguish unsupported, unavailable, and hidden. Never guess identity from an icon alone. | C/V |
| ORG-02 | Arrangement | Drag or keyboard-move an item to a supported position. Show the intended change, apply, verify observed placement, and undo where supported. Store desired and observed layout separately. | C/V |
| ORG-03 | Visibility sections | Always visible, hidden-until-revealed, and optionally rarely used. Define "hidden" as placement policy, not quitting the owner app. Surface unsupported cases. | C/V |
| ORG-04 | Reveal | One click or a configurable shortcut reveals hidden items; manual close or optional delay rehides. Never rehide while the user interacts with an open menu. Hover/scroll reveal are optional preferences. | P/V |
| ORG-05 | Overflow and notch | Preserve access when items cannot fit. Proposed overflow panel for owned items; external-item representation and activation need validation. Do not claim a screenshot is an interactive clone. | P/V |
| ORG-06 | Persistence | Restore supported layout intent after relaunch/owner-app restart; tolerate missing items and duplicates. Ambiguous external items require user reconciliation instead of moving the wrong item. | P/V |
| ORG-07 | Groups and spacers | Group MenuSprite items visually, add adjustable spacers within supported geometry, optionally render a group as one status item. External groups are conditional on ORG-02. | P/V |
| ORG-08 | Recovery and coexistence | Restore last valid organization, reveal items, and disable external management. Detect likely competing managers when possible and explain conflicting control; never quit another utility automatically. | P/V |
| ORG-09 | Display handling | Reconcile after attaching/removing displays, resolution changes, Spaces, fullscreen, auto-hide, and wake. Report the observed capabilities for each tested configuration. | C/V |

MenuSprite cannot assume control of another app's menu, font, image, or lifecycle.
App-owned settings remain the route for disabling an app's own item. Whole-bar
position/style changes are not hidden inside the definition of item arrangement.

## 2. Visual creation and editing

| ID | Feature | Draft behavior / acceptance | Basis |
| --- | --- | --- | --- |
| BUILD-01 | Add/Create Custom Sprite | Direct creation entry; blank sprite or editable template; name, duplicate, disable, delete with undo. Duplicate receives a new stable identity. | C |
| BUILD-02 | Visual workspace | Searchable block/asset palette, connected behavior workspace, bar/popup preview, and selection inspector. Common tasks never require opening source code. | C |
| BUILD-03 | Connectable blocks | Event stacks with snap targets and typed value sockets; conditional branches visible. Add, reconnect, reorder, collapse, copy, and delete through mouse or keyboard. | C |
| BUILD-04 | Immediate presentation preview | Styling updates in preview immediately. Explicit Live Preview can temporarily update the actual bar; Cancel restores the active item. It does not silently run actions. | P |
| BUILD-05 | Test inputs | Inspect live readings or clearly labeled sample inputs. Inject normal, threshold, missing, stale, and error cases. Step through a behavior and see values/branches. | P |
| BUILD-06 | Draft and apply | Autosave a recoverable draft; Apply validates and promotes it atomically. Invalid drafts never replace the running revision. Undo/redo covers visual edits. | P |
| BUILD-07 | Validation | Explain incomplete sockets, incompatible units/types, missing dependencies, cycles, and unsupported capabilities on the affected block. A disabled block can remain in a draft. | P |
| BUILD-08 | Reuse | Templates use the same model as user items. Copy a block stack or presentation group; edit without converting into an opaque preset. | P |

Proposed builder layout: left sidebar for items/templates; central menu bar
preview above the currently selected Appearance / Behavior / On Click workspace;
palette beside the workspace; a compact inspector for the selected block or
visual element. Behavior is a connected visual surface, not an endless settings
form. On Click edits the optional expanded menu board and click behavior (D-02).
Settings, source health, and runtime diagnostics
are separate destinations so the builder stays about creation.

## 3. Appearance and character artwork

| ID | Feature | Draft behavior / acceptance | Basis |
| --- | --- | --- | --- |
| STYLE-01 | Content | Icon, image, text, numeric value, or a composition of these; hide optional pieces when their value is absent. | C |
| STYLE-02 | Typography | Available native font family, color, weight, supported style, and size; preview unavailable-font fallback. Font controls fit within real menu bar geometry. | C/V |
| STYLE-03 | Formatting | Prefix/suffix, units, decimal precision, date/time formats, alignment, width bounds, and truncation with full accessible label/tooltip. Stable widths prevent distracting layout shifts. | P |
| STYLE-04 | Icon/image library | Built-in symbols and sprite assets plus user image import; crop/fit, scale, and preview in light/dark appearances. Proposed first import types: PNG/JPEG/HEIC; broader formats require a decoder decision. | C/V |
| STYLE-05 | Appearance states | Default, condition-specific, loading, stale, error, and disabled presentation. Meaning must not rely only on color. System appearance can select appropriate assets/colors. | P |
| STYLE-06 | Character artwork | Choose character art or a personal image for a sprite; keep Slim rail / Arranger app identity distinct. A sprite need not be a character. | C |
| STYLE-07 | Animation | Optional bounded frame sequence or native property animation; user chooses trigger, loop/one-shot, and speed within limits. Pause when inactive/hidden where visibility is reliable, on lock/sleep, and under reduced-motion policy. | C/V |
| STYLE-08 | Tiny charts | Optional progress/ring/bar/sparkline presentation, with bounded samples and accessible text equivalent. Long histories belong in a popup, not an expanding menu bar. | P/V |

No global font or icon replacement for third-party apps is implied. No promise
that the system menu bar grows taller to accommodate an oversized custom item.
Images and animation assets must have bounded decoded size, frame count, and
cache cost; the resource policy is part of the importer, not just a file-size hint.

## 4. Click behavior, menus, and popovers

An optional **custom expanded menu board** with custom UI and rendered data,
opened by clicking the sprite's icon, is **confirmed**. The following control
palette and rendering details remain proposed; larger tool surfaces are covered
by SPRITE-03 below. A board is part of its sprite, not a separate sprite.

| ID | Feature | Draft behavior / acceptance |
| --- | --- | --- |
| CLICK-01 | Primary click | A sprite configured to open its expanded menu board does so when its icon is clicked. Sprites without a board may use another configured click action. Avoid accidental double dispatch. |
| CLICK-02 | Secondary click | Consistent item management menu: Edit, Refresh where relevant, Pause/Resume, diagnostics, and access to MenuSprite. Remains reachable when a custom primary action fails. |
| CLICK-03 | Native menus | Text/value rows, actions, separators, checkmarks, disabled conditions, and submenus. Live data does not reorder the currently targeted row while the menu is open. |
| CLICK-04 | Custom expanded menu board | User-designed layout and rendered data. Proposed palette: rows/columns, labels, values, images, charts, buttons, toggles, sliders, pickers and simple text input, using native controls and explicit accessibility order. Exact palette and geometry are not yet settled. |
| CLICK-05 | Binding controls | A control reads a state value and invokes a named write/action. While pending, show progress; on failure, keep/revert to confirmed state and explain. A read-only source cannot become writable just by binding a slider. |
| CLICK-06 | Focus and dismissal | Escape/outside click dismiss; keyboard traversal and activation work; opening on another display positions within available bounds. Do not steal focus for background updates. |
| CLICK-07 | Lightweight lifecycle | Build rich content when opened; release it when closed except bounded cached state. Hidden popover charts do not keep high-frequency collection alive. |

Tool windows and shortcut overlays are proposed to serve broader utilities.
Custom HTML, arbitrary embedded websites and a freeform pixel canvas remain
implementation choices to evaluate against native customization and footprint.

## 5. Sources and built-in tools

The **ability to choose sources is confirmed**; this provider catalog is proposed.
Every source exposes value/type/unit, availability, observation time, last
success, and error. Never use zero to stand for failed, denied, or unsupported.
Source settings show what is accessed and the effective refresh policy.

| ID | Provider / tool | Proposed output and default update | Limits / validation |
| --- | --- | --- | --- |
| DATA-01 | Clock/date/world time | User-selected timezone/format; next visible boundary, minute by default | Locale, DST, manual clock/timezone changes; seconds only when displayed. |
| DATA-02 | Battery/power | Available charge percentage and charging/power-source state; event subscription | Unsupported hardware/fields stay unavailable; no battery charge control implied. |
| DATA-03 | CPU activity | Aggregate CPU utilization over an explicitly reported sample window; 5 s default | Validate numerator/denominator on Apple silicon; do not label load average as utilization. |
| DATA-04 | Memory | Clearly defined memory quantities and optional pressure state; 5 s default | Document exact definition; do not equate low "free" memory with pressure. No memory cleaner. |
| DATA-05 | Storage | Capacity and available space for selected volume; 60 s default plus relevant events | Volume identity, removal, purgeable versus available distinction; no recursive disk scan. |
| DATA-06 | Network | Selected interface status and optional throughput; events for status, 5 s for rates | Route changes and counter resets; connectivity does not prove internet/service availability. SSID details need separate access checks. |
| DATA-07 | Local file | User-selected text/JSON; inspect/extract a field or bounded text; file-change events with debounce | Missing/moved/rotated file, encoding errors, size limit; no whole-disk watcher. |
| DATA-08 | HTTP/JSON | Explicit URL/request, response field selection, headers and stored credentials; 60 s default/manual | Timeouts, offline, HTTP failures, rate limits, bounded response; no built-in paid provider assumed. |
| DATA-09 | Local log file | Tail a selected file into a bounded recent buffer; filters/counts/last matching entry | Rotation/truncation, partial lines, burst backpressure. Not all system logs. |
| DATA-10 | Unified system log | User-selected filters over accessible OSLog data | Candidate within confirmed logs goal; Apple's local-store API documents admin-account and logging-entitlement requirements. Feasibility of that access, scope, and retention must be proven. No root/helper assumption. |
| DATA-11 | Script output | Text or a declared structured value from a finite process; manual or 60 s default | See script contract; dependencies and trust are explicit. |
| DATA-12 | Shortcut output/action | Existing user-selected macOS Shortcut; manual by default | Some Shortcuts prompt or have external effects. Scheduled use must be explicitly enabled and tested. |
| DATA-13 | Manual value | Text/number/bool choice, editable by the user | Valid useful fallback when a desired value cannot be read automatically; do not fabricate an automatic feed. |
| DATA-14 | Countdown/stopwatch | User-managed timer state and formatted time | Proposed elapsed-time behavior across sleep; no promise to wake the Mac for alarms. Completion delivery requires policy decision. |
| DATA-15 | Another app's menu bar data | Parked, low-priority candidate (D-21); preserve the idea of reading external values into a custom sprite without further design now | Existing feasibility notes retained. Not required for the current core plan; V-10 remains deferred unless the topic is explicitly resumed. |

Every provider is optional. Shared requests to the same source/configuration
collect once and fan out to interested items. Different credentials/paths/configs
must never be treated as the same source. No provider runs solely because it
appears in the palette.

Suggested editable templates: clock, battery, CPU condition indicator, memory or
storage reading, service-status endpoint, selected log counter, launcher/action
menu, and a static/animated sprite. Final templates follow D-01. Template examples
use labeled sample data until the user configures a real source.

## 6. Behavior and automation

| ID | Feature | Draft behavior / acceptance | Basis |
| --- | --- | --- | --- |
| LOGIC-01 | Triggers | Source change, refresh interval, explicit click, popup open, app launch, and wake reconciliation. Only enabled behaviors subscribe. | C/P |
| LOGIC-02 | Values/transforms | Constants, source fields, formatting, unit conversion, arithmetic, comparisons, boolean combination, text operations, and simple bounded list selection. | C/P |
| LOGIC-03 | Conditions | If/else, match state, threshold with optional duration/hysteresis. Missing/stale input is explicit, not truthy/zero. | C/P |
| LOGIC-04 | Actions | Set item state/style, refresh source, copy selected content, open app/file/URL, run chosen Shortcut/script, and optional local notification. | C/P |
| LOGIC-05 | State | Item-local variables with declared types/defaults; selected variables may persist. Shared source values are immutable readings. | P |
| LOGIC-06 | Scheduling | Manual, event-driven, interval, and proposed calendar schedule. Show requested versus effective interval when a limit or resource policy changes it. | C/P |
| LOGIC-07 | Repeated events | Debounce source bursts; suppress duplicate presentation; notify on transitions; cooldown repeated side effects. Per-item action ordering is deterministic. | P |
| LOGIC-08 | Safety and pause | Pause an item/source or all automation, inspect pending work, cancel supported operations. Never automatically retry an action with possible external effects. | P |

Proposed block grammar: one trigger starts a stack; ordered action/condition
blocks attach beneath; pure value blocks fit typed sockets. A source's declaration
and subscription are reusable. Data dependencies must be acyclic. Initial core
has no unbounded loops, recursion, arbitrary native code blocks, or automatic
cross-item action chains. Visual reusability should not require a general-purpose
programming language. Broader looping/subroutine support is a later decision.

Pure display evaluation and side effects are separate. For example, an amber
style may persist for every high CPU sample, while a notification emits once on
entering that condition. Test Preview evaluates data/style with side effects off;
Run Action is an explicit separate command.

## 7. Scripts and integration contract

| ID | Feature | Draft behavior / acceptance |
| --- | --- | --- |
| SCRIPT-01 | Editable finite script | Inline shell script or explicitly selected executable; visible arguments, working directory, runtime, input, schedule, and dependencies. No automatic runtime download. |
| SCRIPT-02 | Data output | Choose text mode or structured mode. Structured mode produces a bounded JSON value matching its declared output type; program failure is separate from returned data. No implicit markup parsing. |
| SCRIPT-03 | Actions | Typed input passes as arguments/stdin, not interpolated shell commands. Display exit status and bounded stderr. Secret values are supplied only to explicitly configured integrations. |
| SCRIPT-04 | Resource control | Timeout, output bound, bounded concurrency, no overlapping scheduled runs, cancellation, and failure backoff. Diagnose and pause repeat failures. |
| SCRIPT-05 | Trust | Show executable code/dependencies before enabling an import. Scripts have the user's effective OS access subject to platform restrictions; app capability settings are not a process sandbox. |
| SCRIPT-06 | Debugging | Test explicitly; inspect last run, elapsed time, exit status, and redacted output. Missing executable or changed script shows an actionable state. |

Versioned installable scripts and background behavior are now confirmed intent.
Finite jobs remain one execution class; sustained services and long operations
also need a contract. SwiftBar/xbar compatibility, languages/runtimes, native
extensions and inbound triggers remain decisions. Built-in telemetry should use
native collection rather than launching shell tools at every refresh.

## 8. Profiles, templates, persistence

| ID | Feature | Draft behavior / acceptance | Basis |
| --- | --- | --- | --- |
| SAVE-01 | Persistent items | Stable IDs, source references, assets, behavior, active revision, and recoverable draft survive relaunch. | P |
| SAVE-02 | Manual profiles | Save/duplicate/rename/switch sets of item membership and layout. Item definitions are shared; Duplicate Item creates an independent variant. Inactive profiles do not collect data solely for their items. | P |
| SAVE-03 | Local templates | Ship editable examples, save a personal template, preview before inserting. Missing dependencies remain visible. | P |
| SAVE-04 | Export/import | Portable versioned bundle; item/profile dependency closure included; preview additions/conflicts and executable integrations before import. Secrets and machine-specific grants excluded. | P |
| SAVE-05 | Backup/migration | Atomic writes, last-good backup, version migration, and recovery. Unknown newer format opens safely without destructive downgrade. | P |

Profiles propose membership/order/visibility references, not arbitrary hidden
overrides of every property. Different appearances across profiles require
independent item variants until an explicit override model is designed.

## 9. Daily operation and quality

| ID | Feature | Draft behavior / acceptance |
| --- | --- | --- |
| APP-01 | Menu bar lifecycle | Background agent with editor/settings on demand; closing the editor keeps items running; launching the app again opens recovery/editor if its item is absent. |
| APP-02 | Launch at login | User-controlled, accurately reflects OS registration/approval state. |
| APP-03 | Shortcuts/accessibility | Keyboard alternatives for creation, connection, arrangement, and commands; VoiceOver labels; contrast/reduced-motion support; shortcut collision handling. |
| APP-04 | Permissions & Access page — current first step | All app-permission categories on one page with scoped status, purpose, used-by and Request/Manage actions. Preserve unknown/limited/restricted states; OS grants and local enablement are separate. Explicit actions initiate requests; opening the page does not. See ../permissions-page.md. |
| APP-05 | Health/activity | Per-item source status, last success, pending/failed action, refresh policy, and resource diagnostics. Attribute slow integration work without claiming precise per-item OS CPU accounting. |
| APP-06 | Recovery | Open with suspect integrations/organizer disabled; keep configurations inspectable; recover backup or export before reset. |
| APP-07 | Privacy | Local operation by default; no analytics/upload backend proposed. Configured network integrations can send data and must describe that destination. Diagnostics exclude secrets by default. |
| APP-08 | Distribution | Personal install/uninstall, version identity, documented signing path for sharing; update mechanism to be selected before public release. No launch date promise. |

## 10. Expanded sprite, utility and community requirements

The capability families below come from Prerak's clarification. **C** indicates
confirmed intent, not a promise that every detailed feature/API is designed.

| ID | Feature | Requirement / open design | Basis |
| --- | --- | --- | --- |
| SPRITE-01 | Sprite definition | Own appearance, interactions, data, behavior, settings and dependencies; distinguish a package from a personalized instance. | C/P |
| SPRITE-02 | Install Sprite | Discover or open a sprite package, inspect its version/dependencies/access, install, configure and use; installation alone need not activate background work. | C/P |
| SPRITE-03 | Multiple surfaces | Menu bar presence is optional (confirmed D-17). Popup, tool window and shortcut overlay details remain proposed, sharing sprite state. | C/P/V |
| SPRITE-04 | My Sprites | One place to find, configure, enable/disable, diagnose, update and remove installed/created sprites, including those hidden from the bar; each retains its identity icon. | P |
| SPRITE-05 | Deep customization | Shared theme defaults and personal overrides; editable declared UI/actions; show custom-code boundaries instead of claiming all internals are visually editable. | C/P |
| SPRITE-06 | Required identity icon | Every created/installed sprite has an icon or mini logo, independently of Show in Menu Bar and Enabled. Propose choosing a built-in icon or importing/designing one; custom artwork is not compulsory. | C/P |
| TOOL-01 | Claude/Codex usage sprites | Named example integrations: choose data meaning, account/source and supported access before designing readings; no unverified usage API assumed. | C/V |
| TOOL-02 | Docker sprite | Monitoring with customizable presentation; proposed container detail/actions. Actual connection, operations and authentication need specification. | C/V |
| TOOL-03 | Homebrew sprite | Management of installed and discoverable packages with appropriate UI, progress and results. Exact search/install/update/remove workflows remain to map. | C/V |
| TOOL-04 | App/window switching | Native switcher capabilities exposed through customizable interactions and proposed overlays; interaction/state restore and access need validation. | C/V |
| TOOL-05 | Desktop/Spaces switching | Supported workspace/desktop operations, shortcut behavior and optional presentation; OS compatibility must be investigated. | C/V |
| TOOL-06 | System, shortcut and helper tools | Preserve the broad Vorssaint replacement scope and other utilities as named; inventory each job and its capability needs before claiming parity. | C/V |
| TOOL-07 | Personal monitoring | RAM, CPU, power, upload/download rates, fan RPM and sensor temperatures as customizable sprites/boards. Validate metric definitions and actual hardware sources. | C/V |
| TOOL-08 | Personal battery management | Graphical battery sprite/board and charge-limit behavior replacing the used AlDente function; extra controls still to name. Showing a percentage does not complete charging control. | C/V |
| TOOL-09 | Personal capture tool | Replace the CleanShot workflows Prerak uses; identify required capture, edit and output paths before choosing the feature subset. | C/V |
| TOOL-10 | Personal clipboard tool | Replace the Paste workflows Prerak uses; identify content, search, reuse/organization and any sync requirements. | C/V |
| PKG-01 | Versioned packages | Identity, author, version, compatible host/capability versions, assets/layouts/blocks, code, dependencies, access and execution declarations. Manifest format proposed. | C/P |
| PKG-02 | User edits and upgrades | Keep upstream package separate from personalized instance; preview incompatible changes; preserve local edits or offer an explicit fork/merge; retain prior package for rollback. | C/P |
| PKG-03 | Background execution classes | One-shot, scheduled, sustained event service and long operation; explicit start/stop, cost attribution, crash handling and bounded resources per class. | C/P/V |
| PKG-04 | Extension capabilities | Creators compose host OS capabilities or add integration code. New deep OS behavior needs a supported extension contract; native plugin distribution/trust remains open. | C/P/V |
| COMMUNITY-01 | Marketplace | Browse/search, preview and download/install other creators' sprites. Detail pages/version/compatibility/access display proposed. | C/P |
| COMMUNITY-02 | Publish and share | Creators distribute their ideas as sprites; proposed draft, versioned publishing, attribution, updates, and editable remix workflow. Licensing/edit rights still need definition. | C/P |
| COMMUNITY-03 | Likes and friends | Both requested. Define public/private likes, mutual friends versus following, discovery/sharing behavior and privacy in discussion. No feed/chat assumed. | C |
| COMMUNITY-04 | Marketplace operation | Identity, package storage, integrity/review, reporting/removal, release compatibility and service operation need a concrete design before launch. | P |
| COMMUNITY-05 | Independent local use | Installed sprites continue through a marketplace outage; proposed local creation/import without an account. Select online-account boundaries explicitly. | P |

These requirements do not authorize publishing packages, creating accounts, or
building a backend during planning. Broader tools and community features must
remain represented in the whole-product plan even if implementation is sequenced.

## 11. Further candidates and detailed provider choices

These are recorded for full-product coverage, not committed to development.

| Candidate | Why it might belong | Decision / dependency |
| --- | --- | --- |
| Calendar, next meeting, reminders | Useful glance-and-click tools | Actual workflow, EventKit access, privacy, interaction depth. |
| Weather | Common glanceable source | Provider, location/manual location, credentials, cost/offline behavior. |
| Media and audio controls | Consolidate volume/output/now-playing tools | Supported platform/app APIs; do not promise universal media control. |
| Bluetooth/peripheral battery | Consolidate accessory utilities | Device-specific availability and supported access. |
| Thermal/fan/GPU/power sensors | Broader system monitoring | Hardware/API validation; distinguish readings from privileged controls. |
| App/process monitoring | Personal developer workflows | Definition, access, collection cost; process termination is a separate action. |
| Network service checks / remote machine readings | Personal infrastructure indicators | Explicit endpoint/SSH integration, credentials, safe schedules; no agent backend assumed. |
| Keep awake / focus timer | Consolidate small utilities | Explicit power-state effect, cancellation, sleep behavior. |
| Clipboard history, notes, task lists | Fast personal tools | Sensitive persistence and whether these expand product scope too far. Simple Copy action is already proposed. |
| Automatic profiles | Switch by time, app, power, or display configuration | Event availability, precedence, cooldown, manual override; manual profiles first. |
| Whole-bar tint, shapes, transparency, spacing | Broader visual customization | Separate native validation and compatibility cost; external app styling is not implied. |
| SwiftBar/xbar compatibility | Reuse existing personal scripts | Compatibility subset and parsing; sustained execution is already included in the expanded package design discussion. |
| Automatic cloud sync | Reuse across personal machines | Conflict and device-local credential/file-reference decisions. Marketplace/social distribution is already intended scope. |
| AI-assisted item creation | Potential simpler authoring | Explicit user demand, model/provider/cost/data handling; visual editing must remain complete. |

Use these rows to map the requested broad utility coverage. A row's presence here
does not override TOOL-06 or dismiss Vorssaint parity as irrelevant; exact jobs,
scope and sequencing still need discussion. Mark detailed choices with rationale
in decisions.md. Do not silently narrow the platform back to menu bar readouts.
