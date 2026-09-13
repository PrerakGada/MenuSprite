# Native feasibility and evidence

Reviewed 7 September 2026. **Documentation research only; no native experiments.**
The local development machine reports macOS 26.6.2 (25G83) through `sw_vers`.
That observation neither selects the minimum OS nor establishes compatibility.

The original research primarily covers menu bar surfaces. Broader utility and
marketplace scope is now explicit; see [sprite-platform.md](sprite-platform.md)
for Vorssaint evidence and the confirmed/proposed distinction. None of those
capabilities has been implemented or tested in MenuSprite.

## Overall feasibility assessment

Prerak asked whether everything discussed is actually possible. Engineering
assessment, 7 September: **the core sprite platform is technically credible**,
with documented native UI and integration building blocks. This is not proof of
the complete implementation, every proposed system capability, or the resource
targets. It is a substantial extensible application and community service.

| Scope | Assessment and boundary |
| --- | --- |
| Required icons, optional bar presence, custom expanded menu boards | Feasible foundation in native status-item, popup and window APIs. Building the visual editor and accurate preview is product engineering; exact rendering still needs V-01. |
| Visual customization and scripting | Feasible with an editable representation of layout, data bindings, actions and settings. Arbitrary opaque code cannot automatically become visually editable; custom component and extension contracts must define the boundary. |
| Versioned installation, marketplace, likes and friends | Feasible application/service architecture. Package compatibility, preserving personal edits, code trust, identity and operations are substantial work rather than an OS impossibility. |
| Docker/Homebrew tools | Documented integration interfaces exist. Validate the selected local connection, versions, permissions and operations; no installed-system test has occurred. |
| App/window/input/system helpers | Some implementations are demonstrated in the Vorssaint source review. Each operation needs permission, OS-version and failure-recovery validation. Do not extrapolate this to unrestricted Spaces or third-party app control. |
| Claude/Codex and other app-specific readings | Named desired integrations, still unverified. Define the reading and establish an accessible source before committing; a data source's stability is separate from rendering the sprite. |
| Very low CPU/RAM with arbitrary sprites | Optimize and measure the host; attribute and bound extension work. Unrestricted scripts, continuous animation or expensive integrations cannot be guaranteed negligible total cost. |

Design recommendation: sprites describe their UI, data, actions and settings in
a host-understood format, with custom code extending defined capabilities. Users
can then personalize installed sprites without being confined to the original
author's fixed UI. Rich custom components and new native services require an
explicit extension path; a finite visual palette cannot anticipate every idea.

Three boundaries must remain honest: full control of our sprite surfaces does
not confer control over other apps; arbitrary code does not become safe from a
permission declaration; and resource limits may require delaying or stopping
expensive work. Distribution remains open: Apple requires App Sandbox for Mac
App Store distribution, so that path cannot be assumed to support the intended
extension capabilities unchanged.

Additional primary evidence reviewed for this assessment:

- [Apple MenuBarExtra window style](https://developer.apple.com/documentation/swiftui/menubarextrastyle/window): native popover-like content with window-style controls/layout.
- [Apple NSPanel](https://developer.apple.com/documentation/appkit/nspanel): native auxiliary/floating panel capability.
- [Apple event taps](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29): event interception has access and event-availability constraints. The page includes legacy permission wording; verify current behavior before choosing a technique.
- [Docker Engine API](https://docs.docker.com/reference/api/engine/): documented daemon API with version compatibility considerations.
- [Homebrew command reference](https://docs.brew.sh/Manpage): documented package search, listing, installation and removal commands.
- [Apple App Sandbox](https://developer.apple.com/documentation/security/app-sandbox): resource access restrictions and the Mac App Store requirement.

When development is explicitly authorized, the strongest early proof is three
different sprites through the same host: a customized live reading and expanded
board; an installed/scripted sprite whose local edits survive an upgrade; and a
native app switcher or larger Homebrew tool. Measure resource use and failure
behavior. These are recommendations for future validation, not authorization to
run experiments in the planning phase. Feasibility research does not narrow the
confirmed vision or mark any proposed capability implemented.

## Reading another app's menu bar data

**Parked, low priority:** Prerak stopped this line of discussion on 7 September
because it was becoming too detailed for its importance. Retain the research
below for reference; do not pursue it or V-10 as a core planning prerequisite.

Prerak proposed watching another app's menu bar item and rendering its displayed
data in a custom sprite/expanded menu board. **Possible for some targets; no
universal cloning capability is established.** This is a candidate capability
under investigation (D-21), not a promise that every app can be mirrored.

Prefer a reader running outside the target process. Proposed approaches, from
most direct to most presentation-dependent:

| Approach | What MenuSprite could reuse | Dependency / limit |
| --- | --- | --- |
| App-provided API, CLI, scripting interface or documented data source | Structured values/state, and separately documented actions | Availability is app-specific. If MenuSprite talks directly to the underlying source, the original app may no longer be required; this must be verified. |
| Accessibility inspection | Exposed title, value, description or child controls; parse selected fields into typed sprite data | Requires permitted Accessibility access and actual target support. A label might contain the reading or only the app's name. Available attributes and notifications differ. |
| Screen capture plus OCR / explicit visual interpretation | Visible text from a captured item or expanded UI; optional app-specific visual-state recognition | Requires suitable capture access and available content. Pixels do not supply the original structured model, hidden history or action semantics; uncertainty and refresh costs must be measured. |
| Authorized source/plugin modification | A cooperative adapter exposes the data explicitly | Where the target supports extensions or its source can be adapted; a separate maintained integration, not automatic external UI cloning. |

Apple documents [Accessibility attribute reads](https://developer.apple.com/documentation/applicationservices/1462060-axuielementcopyattributevalues),
[displayed titles](https://developer.apple.com/documentation/applicationservices/kaxtitleattribute),
and an [extras-menu-bar attribute](https://developer.apple.com/documentation/applicationservices/kaxextrasmenubarattribute).
Their existence does not guarantee every status item exposes its measurements.
[AX observers](https://developer.apple.com/documentation/applicationservices/1462089-axobserveraddnotification)
can subscribe to supported notifications; notification support is explicitly
optional. Prefer events where they actually work; otherwise consider measured,
bounded polling rather than assuming updates will always be pushed.

[ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
provides capture building blocks and [Vision text recognition](https://developer.apple.com/documentation/vision/vnrecognizetextrequest)
provides OCR. The proposed combination is an engineering inference, not tested
menu bar extraction. A displayed value can be misread, rounded, truncated or
ambiguous; screenshots of a graph do not establish exact historical samples.

**Literal code injection is not the proposed integration architecture.** It is
different from running a script which observes accessible UI. Apple's
[Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)
protects against classes of code injection. Target-specific modification may
exist in controlled cases, but a generic script cannot assume it can execute
inside any signed app or obtain its private internal state. Do not make disabling
system protections a baseline product dependency.

Critical behavior to validate for each target:

- Whether the reading exists as accessible data or only visual content; preserve
  source text, parsing/units and observation time so failure never becomes zero.
- Whether the value updates while its original menu is closed, its bar item is
  hidden, the menu bar is auto-hidden, or the display/session changes. Closed
  menus may not expose their content, and hidden content may be unavailable or
  stop refreshing. Do not silently open menus/fight focus for background sampling.
- Source app exit/restart, changed element identities, version changes and locale
  differences. Bind to confirmed owner/element identity rather than coordinates
  alone; ambiguous rematches need user repair.
- Readability and action forwarding are separate capabilities. Recreating a
  button's appearance does not reproduce its behavior. Supported API/AX actions
  require their own explicit mapping and validation.
- UI mirroring normally requires the target app to keep running. It can provide
  a personal presentation without eliminating the source app's resource use.
  Replacing the underlying integration is a separate path, not automatic cloning.
- Capture/OCR cost, confidence and stale/error behavior. Do not assume hidden
  source items remain capturable or promise cheap continuous screenshot parsing.

Proposed workflow: select target app/item → inspect available fields and update
behavior → choose/extract a value → preview live data with provenance → bind it
to the sprite's face/board → separately choose supported actions. An adapter can
be distributed as part of a sprite package, with target/version compatibility
and method disclosed. No target application has been inspected live in this phase.

## What the evidence supports

| Area | Evidence | Implication for MenuSprite |
| --- | --- | --- |
| Owned status items | Apple documents creating NSStatusItem instances and customizing their buttons, menus, visibility, and length. [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem) | A documented foundation for custom items; exact font, color, animation, grouping, and placement behavior still require a native check. |
| Native popup controls | Apple documents MenuBarExtra and a window style for richer controls. [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) | Native click-open content is a reasonable proposal. This does not validate our custom builder or settle AppKit versus SwiftUI ownership. |
| Interactive removal | Apple describes removalAllowed and the resulting visibility change. [removalAllowed](https://developer.apple.com/documentation/appkit/nsstatusitem/behavior-swift.struct/removalallowed) | Item removal/reopening is a lifecycle requirement. It does not grant removal rights over someone else's status item. |
| Login launch | SMAppService manages registration and reports status, with registration subject to user approval. [SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice) | Implement a real registration/status flow; a persisted Boolean is insufficient. |
| Energy | Apple's guidance favors events over unnecessary polling and allows timer tolerance. [Minimize Timer Usage](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/Timers.html) | Supports a shared demand-driven scheduler. The guide is archived; API choices still need current SDK checks. It provides no MenuSprite benchmark. |
| Power events | Apple documents a power-source notification run-loop source. [IOPSNotificationCreateRunLoopSource](https://developer.apple.com/documentation/iokit/1523868-iopsnotificationcreaterunloopsou) | Investigate native battery/power change notifications rather than a per-item polling loop. Validate available fields on supported hardware. |
| Unified logs | OSLogStore represents log entries. Its local-store method documents an admin-account requirement and a logging entitlement. [OSLogStore](https://developer.apple.com/documentation/oslog/oslogstore), [local store access](https://developer.apple.com/documentation/oslog/oslogstore/local%28%29) | No unrestricted system-log promise. Whether the needed entitlement/access is available to the chosen distribution must be established; do not assume adding an entitlement grants it. |
| Shortcuts integration | Apple documents command-line input/output and warns that interactive Shortcuts can wait for user input. [Run Shortcuts from the command line](https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac) | A proposed optional integration; require explicit runs, deadlines, and an interaction state. |
| App Store / sandbox | Apple states Mac App Store apps must enable App Sandbox. [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox) | Distribution affects available operations and script behavior; choose after testing requirements. Direct distribution is a proposal, not a requirement proved by this page. |
| Public direct delivery | Apple describes Developer ID signing, hardened runtime, and notarization for distribution. [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) | Public sharing needs a release/signing plan. Notarization is not a functional test or a sandbox. |

Apple's main documentation pages exposed Markdown links which the web reader
could not render; their linked `.md` versions were retrieved directly and read
where needed. No quoted API documentation has been copied into the specification.

## External engineering evidence

[Ice's source](https://github.com/jordanbaird/Ice/blob/main/Ice/MenuBar/ControlItem/ControlItem.swift)
shows an expanded control status item for hiding a section. Its
[maintainer discussion of auto-hidden menu bars](https://github.com/jordanbaird/Ice/issues/201)
describes problems capturing offscreen items and arranging them in that state.
This is historical evidence of compatibility risk, not proof that the same defect
affects every current version. Investigate current behavior on the selected OS.

Inference: external organization should expose supported operations and be
isolated from the custom-item runtime. These sources do not establish a universal
Apple API for changing another app's status item, nor prove such control is
impossible. Copying an existing project's technique is not native validation.

[SwiftBar's own documentation](https://github.com/swiftbar/SwiftBar) demonstrates
script-produced menu bar content, menus, refresh schedules, and optional
long-lived stream processes. It is a useful comparison for optional scripting.
MenuSprite's visual-first authoring and resource policy remain its own proposed
design. No SwiftBar-format compatibility is committed by referencing that project.

No external application code was imported, installed, or executed in this pass.
Any future code reuse needs the chosen project's actual license reviewed before
incorporation; no license choice for MenuSprite is implied.

## Investigations to run only after development is authorized

| ID | Investigation | Required evidence / resulting decision |
| --- | --- | --- |
| V-01 | Owned rendering and interaction | Small native experiment: independent items and one combined group; all promised styling; user image; static/animated sprite; menu and proposed popover; keyboard/VoiceOver; recreation and removal. Record supported geometry and performance. Choose renderer, grouping, and minimum OS. |
| V-02 | External organization | Use the agreed real utility list. For each, record identity stability, move/hide/reveal/activation, permissions, multi-display, notch, auto-hide/fullscreen, owner restart, and failure recovery. Identify documented versus compatibility-sensitive techniques and undo limits. Return unsupported desired workflows to Prerak. |
| V-03 | Data accuracy and access | Validate each selected provider's output definition, units, sample window, missing state, and actual access. Include no-battery hardware where in support scope, counter resets, log rotation, and unified-log entitlement feasibility. Decide final catalog and defaults. |
| V-04 | Resource baseline | Measure static, representative, editor, popup, animation, script, log-burst, and organizer workloads. Include all owned helper processes. Set global caps for graphs, assets, history, sources, and imported workspaces using the measured envelope. |
| V-05 | Visual authoring | With Prerak, build one simple and one multi-source item from his actual examples using a native interaction prototype. Check that blocks, preview, editing, and click-open composition match the intended visual workflow. |
| V-06 | Execution and distribution | Test script/Shortcut behavior, runtime discovery, timeout/child cleanup, permissions, signed and chosen sandbox configurations, login registration, and recovery. Choose signing/distribution/sandbox strategy with observed limits. |
| V-07 | Broader native tools and surfaces | Test app/window/desktop actions and selected input/system helpers behind capability contracts; appropriate windows/overlays, disable/restoration and resource cost. Record actual OS/API limits rather than assuming a shell command can implement everything. |
| V-08 | Package/customization lifecycle | Validate package versus instance separation, version/dependency compatibility, theme/UI/action customization, migration/merge and rollback. Use a usage monitor, Homebrew tool and native switcher as materially different examples. |
| V-09 | Untrusted extensions and service lifetimes | Choose supported script/native extension models, effective enforcement and isolation, sustained-service budgets, long-operation handling, background ownership and fault recovery. A declared permission manifest alone is not enforcement. |
| V-10 | Existing menu bar data readers — deferred | Low-priority idea parked by Prerak. If explicitly resumed, validate the target/field, access method, hidden/closed states, accuracy, actions and cost. Not a prerequisite for the core sprite product. |

Marketplace/social architecture needs a separate specification of identity,
publishing, artifacts, access/privacy, likes/friends, integrity, reporting and
operations. Those are design tasks, not macOS experiments, and are not covered
by the first draft's native feasibility findings.

V-01 and V-02 should occur before a large editor investment, because they can
change what the product can represent. V-04 starts early and repeats only when
new work changes the resource envelope. These experiments are future tasks, not
authorization to begin them now.

## Claims that remain prohibited by lack of evidence

No "controls every menu bar app," "restyles every icon," "works on every display
and macOS version," "reads all system logs," "uses X MB," "zero CPU," "replaces
all paid utilities," or "ready to download." Every such claim would require a
defined scope and observed result. The website's simulated values cannot supply
that evidence.
