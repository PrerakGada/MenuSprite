# MenuSprite — Permissions & Access

Governing specification · 8 September 2026 · First native implementation available

**One page shows MenuSprite's app permissions, their current status, what uses
them, and how to change them.** Prerak wants to proceed gradually with this page
first, before tool implementations or an MVP. Vorssaint is the named reference.
The six personal utility areas remain recorded for subsequent steps.

Scope interpretation: permissions belonging to MenuSprite and any explicitly
identified helper it owns. This is not a system-wide editor of other apps'
permissions. The user's reference to "Wallet" is preserved in the discussion
record; no specific Wallet product has been identified or inspected.

## Page behavior

A single scrollable list, with small group labels and search. **All categories
are visible**, including those no current sprite uses. Optional filters: All,
Granted, Needs attention, Used by my sprites. Start on All.

Each row contains the permission name/icon, short purpose, current access badge,
which sprites/features need it, and the applicable action. Expand a row in place
for individual targets/resources and details. No separate maze of permission
pages. Identify the app/helper whose access the row actually represents.

| Row information | Meaning |
| --- | --- |
| Permission | The macOS permission category or explicitly labeled other access type. |
| Access | Observed system state, not a saved preference masquerading as a grant. |
| Used by | Named sprites/features, or "Not used by MenuSprite". This is separate from grant status. |
| Action | Request access, Manage in System Settings, or the supported app-controlled operation. |
| Details | What access allows, effect of denial, scope, verification method/time and any restart requirement. |

Default to simple **Granted / Not granted** wording where the OS establishes
that result. Preserve **Not requested**, **Limited**, **Restricted by system**,
**Check in System Settings**, and **Unavailable on this macOS** when necessary.
An unknown status must never become Not granted. A successful file operation is
evidence that that operation worked, not proof of a universal Full Disk Access grant.
Keep last-checked/stale information when a refresh cannot establish current state.

The first native page is implemented in `native/`, with 36 rows covering this
catalog (29 privacy/framework/clipboard rows, including separate screen/audio
modes, plus 7 app-service/resource rows). Live results come from the signed app,
never this specification. See [native validation](native-validation.md) for the
observed build, checks, resource measurements and remaining manual cases.

## Permission catalog for the page

The following is the public, user-facing category inventory for the current
macOS families, based on Apple's [Privacy & Security reference](https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac),
with Notifications listed separately. Check the selected release/SDK before
implementation; retain unsupported categories with an accurate availability label.
This is not a list of every private TCC service or signing entitlement.

| Group | Categories to display |
| --- | --- |
| Screen and input | Accessibility; Input Monitoring; Screen & System Audio Recording (separate access modes where exposed); Remote Desktop |
| Camera and audio | Camera; Microphone; Speech Recognition |
| Files and applications | Files & Folders; Full Disk Access; Automation; App Management; Developer Tools |
| Personal data | Contacts; Calendars; Reminders; Photos; Media & Apple Music; HomeKit; Focus; Motion & Fitness |
| Network and location | Bluetooth; Local Network; Location Services |
| Browser credentials | Passkeys Access for Web Browsers |
| Alerts | Notifications |
| Clipboard | Pasteboard access behavior, where supported |
| Additional framework access | Health data (per type, where available); App Tracking Transparency |

These are category names, not claims that MenuSprite can request/use every one.
Some depend on a relevant implemented feature, special entitlement or supported
framework. An unused category remains visible without initiating access or
pretending its permission has been denied.

Clipboard, HealthKit and tracking supplement the settings-category inventory.
Do not assume a supported SDK symbol means the service is available on this Mac.
Siri authorization APIs in INPreferences list iOS/Catalyst rather than native
macOS; do not copy those APIs without a supported Mac equivalent.

Expand **Automation** by target application; a Finder grant does not mean all
apps can be controlled. Expand **Files & Folders** by the available resource
scope (for example, Desktop, Documents, Downloads, removable/network volumes)
without pretending there is a universal status query for all of them. For Photos,
Contacts and Calendars preserve the level of access the selected OS reports.
Global Location Services availability and the app's authorization are distinct.

Show other approval/access types on the **same page**, clearly labeled so they
are not confused with privacy grants:

- Launch at login and background helpers: registration/approval state per service.
- Administrator-authorized helper/operation: show installed/approved state and
  the specific capability; no permanent global "Administrator granted" switch.
- Selected files/folders and retained access: show the selected resource and
  whether its saved access remains usable; removing a local reference is not
  the same as revoking macOS-wide access.
- Keychain/credential access: named integrations and stored credential references;
  do not expose secrets or claim a blanket Keychain grant.
- Extensions/network configurations if present: identify the concrete service
  and its activation/approval state; no hypothetical helper is installed just
  to populate this page.
- Hardware control access if implemented: the actual fan/charge-control helper
  and its availability. macOS privacy settings do not provide generic "CPU",
  "RAM", "Fan control" or "Battery charge limit" grant switches.

Global security preferences such as FileVault, Gatekeeper and firewall settings
are not MenuSprite permission grants. They must not appear as privileges the
app can simply turn on for itself.

## What "manage" can actually do

**macOS remains the authority for system permission grants.** Request launches
the supported system consent flow; it does not self-grant access. Manage opens
the appropriate system section when possible, with a plain fallback instruction
if a section link is unavailable. Revoking privacy access generally requires the
user to change it in System Settings. Do not show a working revoke toggle when
all the app can do is open that pane.

For app-owned registrations such as launch at login, perform the supported
register/unregister operation and then reread the resulting state. Errors or
required approval stay visible. If we offer **Stop using this access**, it stops
the relevant MenuSprite-controlled functionality and is explicitly separate from
revoking the OS grant. Per-sprite controls are app policy, not independent TCC
grants or proof of isolation for arbitrary scripts.

Opening/refreshing the page must not request every permission, start capture,
record audio, scan private data, send automation commands or install helpers.
Only an explicit action initiates a request through an available adapter with
required app declarations and a truthful purpose. This can precede implementation
of the dependent sprite; actual recording/collection should not start merely to
request access.
No "grant everything" shortcut or blanket TCC reset is required for this page.

## Status checks and evidence

- Accessibility, input/screen capture preflight and camera/microphone have
  dedicated APIs to investigate for their exact effective access. Boolean APIs
  alone do not distinguish never-requested from previously denied.
- Clipboard access behavior can distinguish default, ask, always-allow and
  always-deny where supported. Preserve those semantics; do not read clipboard
  contents to populate this page. [Apple pasteboard access behavior](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum)
- HealthKit read authorization is intentionally not fully disclosed; write/share
  authorization is a different question. Do not infer read denial from an empty
  result or probe health data. [Apple HealthKit authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data)
- Tracking has a dedicated authorization API but is not a requested MenuSprite
  behavior. Show the category as unused without requesting it or enabling tracking.
  [Apple tracking manager](https://developer.apple.com/documentation/apptrackingtransparency/attrackingmanager)
- Notifications expose authorization and delivery settings; authorization does
  not guarantee every delivery mode is enabled. [Apple notification settings](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getnotificationsettings%28completionhandler%3A%29)
- Contacts and Photos expose authorization levels; preserve partial/restricted
  states where supported. [Contacts](https://developer.apple.com/documentation/contacts/accessing-the-contact-store), [Photos](https://developer.apple.com/documentation/photos/phauthorizationstatus)
- Automation is queried/requested for a specific target/event and checks must
  not prompt incidentally. [Apple automation API](https://developer.apple.com/documentation/coreservices/3025784-aedeterminepermissiontoautomatet)
- **Full Disk Access has no official API that confirms the grant.** Apple's
  guidance is to handle the access actually required; TCC database contents are
  not a definitive account of effective access. Show Check in System Settings
  when no accurate status is available. [Apple DTS explanation](https://developer.apple.com/forums/thread/835851)
- Local Network and App Management need honest method-specific handling; do not
  infer a denial from an offline machine, missing resource or failed operation.
  Use Check in System Settings when the grant cannot be established. [Local Network technical note](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- Login/helper status is a service registration state, with approval requirements
  and supported unregister operations. [Apple Service Management](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)

Vorssaint's [permission guide](https://github.com/vorssaint/vorssaint-utils/blob/4b12b976c3cf77e84800d1358a6011268da1e48c/docs/PERMISSIONS.md)
and [permission service](https://github.com/vorssaint/vorssaint-utils/blob/4b12b976c3cf77e84800d1358a6011268da1e48c/Sources/Vorssaint/Core/Permissions.swift)
were reviewed. Its per-feature explanation and System Settings handoff are useful
references. Its Full Disk Access probing is an inference technique, not an
official complete permission-status API; do not present it as one.

## Small implementation boundary for this step

**Readiness review, 8 September:** no further product discussion is needed to
start this specific step. The scope, page behavior, honest status model and
acceptance criteria are sufficiently defined. Native setup and API validation
are implementation work, not another broad planning exercise.

Working defaults for that setup: Swift with AppKit/SwiftUI, Prerak's current Mac
as the first acceptance device, and a locally installed app with a consistent
bundle/signing identity. Check the available SDK/toolchain and suitable signing
configuration during setup; these are recommendations, not verified environment
facts or a final public OS/distribution commitment. Measure the app with this page
open and closed before extending it with more tools.

Implemented first deliverable: a native MenuSprite app containing this permissions
page and the lifecycle/settings access needed to use it. No tool integrations or
marketplace work are prerequisites. Later feature-specific questions remain for
their own steps. The readiness review itself did not start implementation. The
subsequent explicit implementation request authorized this foundation and its
native validation; evidence is in `native-validation.md`.

The implementation now has a native settings surface, a macOS 26+ row catalog,
per-category status/request/settings handlers and consistent app identity/signing.
Do not create the monitor, capture, clipboard,
marketplace or a generic sprite framework merely to show permission rows.
Permission results must be queried in the real app/helper context, not inferred
from Terminal's access or a different signed build.

Refresh supported status on page opening, return from System Settings/app
activation, and explicit Refresh. Use relevant callbacks when available. No
permanent all-permissions polling while the page is closed; later active features
can own the minimal access checks they actually require.

Acceptance: all catalog categories remain discoverable; rows report correct
scoped state or an honest unknown; unsupported/unused are distinguishable;
request/manage/return works; revoked/limited/managed states do not appear granted;
unknown is not denied; page opening causes no consent storm; closing it leaves
no unnecessary timers/workers. The first authorized validation exercised Camera
request and revocation (macOS required quitting the app), plus login registration
and removal. Other consent/managed/limited-state interactions remain explicitly
unverified; see `native-validation.md`. This specification is not a live grant ledger.
