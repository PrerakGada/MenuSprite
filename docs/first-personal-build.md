# MenuSprite — first personal build

Current direction · 8 September 2026

**Completed foundation: [Permissions & Access](permissions-page.md).** Prerak wanted
to go gradually and address one transparent page listing the app's permissions,
statuses and management actions before tools or an MVP.
The app foundation and this page were authorized and implemented on 8 September.
See [native validation](native-validation.md) for what is working and measured.
Prerak subsequently authorized read-only monitoring and easily configurable
menu-bar sprites. That implementation is described in [system monitoring](system-monitoring.md).

**Build toward an app Prerak can use every day, with a very low memory footprint.**
This brief governs the first build. The broader planning pack is reference for
later work, not a list of prerequisites. We are narrowing the remaining discussion
to daily-use requirements. The separately authorized foundation, permissions page,
monitoring catalog and visual readout configuration are implemented.

## Keep in the first usable app

- Native Mac app with a single place to manage personal sprites.
- Every sprite has a name and identity icon. Show in Menu Bar and Enabled are
  separate controls.
- Create/customize sprites visually: icon/image, text, fonts, colors, data,
  refresh and the behavior needed by the selected tools. Preserve the visual
  building goal; a fixed set of uneditable utilities would miss the point.
- Optional custom expanded menu board with user-designed UI, rendered data and
  relevant actions. Implement the controls needed by the first actual examples.
- The system tools, monitors and shortcuts Prerak actually uses, with appropriate
  native interfaces. Do not restrict their jobs to menu bar geometry.
- Local scripts/integrations where a selected tool needs them; save configuration,
  restore after restart, and provide clear disable/error recovery.
- Organization needed for Prerak's actual bar; detailed existing-app control must
  be checked only where the chosen workflow requires it.

## Actual replacement list — supplied 8 September

| Area | Current tool/use reported by Prerak | MenuSprite outcome / remaining detail |
| --- | --- | --- |
| System readings | Vorssaint mainly for RAM, CPU and power numbers | Customizable readings and optional expanded detail. Define what the power number measures and validate the available source on his Mac. |
| Network | App Store app called "Scalar"; upload/download speeds | Live upload/download rate sprite with chosen units/layout. App name is user-reported; exact listing has not been verified and is not needed to define the job. |
| Fans and temperature | Macs Fan Control menu bar fan speed and temperature | Show fan RPM and selected sensor temperatures. Whether manual RPM/curves are used is unanswered; do not assume control parity from sensor readings. |
| Battery | AlDente Pro; graphical battery UI and charge-percentage control | Custom battery presentation/board plus the used charge-limit behavior. Other AlDente controls are to be named. Control functionality stays in the replacement goal and requires native validation. |
| Screen capture | CleanShot, used through Setapp | Bring the used capture workflow into MenuSprite. Exact screenshot/annotation/OCR/scrolling/recording/sharing functions still to select. |
| Clipboard | Paste, used through Setapp | Bring the used clipboard workflow into MenuSprite. Exact history/search/content types/pinboards/sync needs still to select. |

These six areas replace the previously hypothetical tool list as current focus.
Claude/Codex usage, Docker, app/desktop switching and Homebrew remain earlier
ideas, not required first-build priorities unless Prerak selects them again.
Other unnamed third-party apps remain unlisted; do not infer their functions.

**Implemented first monitoring path:** configurable CPU/RAM/network readings,
small history boards and persistence, with actual resource measurements. Power,
GPU, disk, battery and available read-only sensor sources are included. The full
visual block builder and freely designed boards remain later work. Retain battery
control, capture and clipboard as the remaining personal replacement work; they
are not considered complete or dropped when monitoring becomes usable.

The remaining questions are narrow: viewing versus changing fan speeds; AlDente
controls beyond the charge limit; and the exact CleanShot/Paste daily workflows.
Native control code must reproduce the selected behavior before its source app
can be considered replaced. A battery percentage display is not a charge limiter.

## Low memory is part of acceptance

Measure the resident app with the editor closed and the agreed daily tools active,
including owned helper/script processes. Also check idle CPU, editor/board closure,
disable/re-enable, restart and a long-running session for retained memory.

Use shared native collection, release closed UI, stop unused work, and bound logs,
history and images. Start with one native host and local settings; add helpers or
extra layers only for a demonstrated need. The old 60/120/250 MiB planning figures
were proposals, not accepted budgets or performance claims. Establish an honest
measured baseline early and agree an operating budget against the actual tools.

For the proposed capture/clipboard tools, keep retained history/media on disk and
load bounded previews when needed; avoid retaining full images/video frames in
the idle host. Measure during capture and after its editor closes, as well as
with monitoring active. These are design recommendations, not measured results.

## Later, without blocking personal use

Marketplace, publishing, likes/friends, account/backend design, public extension
distribution and its compatibility machinery are deferred. External-app data
mirroring remains parked. Keep these ideas in the broader pack; no need to solve
them now. Simple stable sprite IDs and saved settings leave room to evolve without
building the future platform in advance or claiming future upgrades cost nothing.

## Immediate path

1. Permissions & Access is implemented with truthful status/actions.
2. Read-only monitoring and configurable sprites are implemented by the next request.
   Continue to the next tool with Prerak when that step is ready.
   Retain fan/battery and CleanShot/Paste questions for their relevant steps.
3. Eventually complete the selected personal tools with visual customization,
   restart/recovery and low measured memory use. Marketplace remains deferred.

Research a specific API only when it determines a selected feature's viability.
Do not make every earlier open question or feasibility investigation a gate.
