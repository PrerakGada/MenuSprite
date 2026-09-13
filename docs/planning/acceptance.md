# Acceptance, resource targets, and delivery

Working proposal · 7 September 2026 · All native checks are **not run**.

**8 September update:** [First personal build](../first-personal-build.md) now
governs delivery. The larger scenario catalog is reference; only checks applicable
to the selected personal tools and their resource/recovery behavior are required
for that first usable app. Marketplace/community acceptance comes later.

Expanded by [the sprite-platform direction](sprite-platform.md). Earlier bar-only
workloads remain useful subsets. The package/system-tool/community acceptance
contracts below still require detailed product decisions; this is not a final
implementation baseline.

## 1. Trace from the agreed product

| Requirement | Feature coverage | Evidence needed |
| --- | --- | --- |
| R-01 Organization | ORG-01–ORG-09 | V-02; A-05/A-06; actual replacement list |
| R-02 Visual building | BUILD-01–BUILD-08, LOGIC-01–LOGIC-08 | A-01/A-02/A-14; V-05 with Prerak |
| R-03 Appearance | STYLE-01–STYLE-05 | V-01; A-01/A-06/A-14 |
| R-04 Sprites/animation | STYLE-06–STYLE-08 | A-12; static and animated resource measurements |
| R-05 Refresh | LOGIC-01, LOGIC-06–LOGIC-08; source broker | A-07/A-08/A-13/A-18 |
| R-06 Data/metrics/logs | DATA-01–DATA-13, APP-04 | V-03; A-04/A-09/A-16 |
| R-07 Basic scripts | SCRIPT-01–SCRIPT-06, DATA-12 | V-06; A-03/A-10/A-17 |
| R-08 Native macOS | Renderer, APP-01–APP-04 | Real native UI review; lifecycle and platform matrix |
| R-09 Low resource use | Scheduler, source sharing, APP-05 | V-04 and the workloads below |
| R-10 Personal replacement | All selected features | D-01 app-to-workflow checklist and daily use |
| R-11 Planning only | This pack and unchanged native boundary | Only documentation changed; no native code, experiments, build, or release |
| R-12 Sprite definition and creation | SPRITE-01, BUILD-01, SPRITE-03–SPRITE-05 | A-01/A-19; D-20 surface details |
| R-13 Versioned installed sprites | SPRITE-02, PKG-01–PKG-04 | A-20/A-22; V-08/V-09 |
| R-14 Broad system utility scope | TOOL-01–TOOL-06 | D-01 replacement inventory; A-19/A-21; V-07 |
| R-15 Marketplace, likes and friends | COMMUNITY-01–COMMUNITY-05 | A-23/A-24 and accepted social mechanics |
| R-16 Personal customization | SPRITE-05, PKG-02 | A-20/A-25; presentation and code editability contracts |
| R-17 Icon required, menu bar presence optional | SPRITE-03, SPRITE-04, SPRITE-06 | A-26; confirmed D-17 |
| R-18 Optional custom expanded menu board | CLICK-01, CLICK-04–CLICK-07 | A-03; confirmed D-02, detailed palette still proposed |

Exact popup controls (A-03), profiles (A-08), import mechanics (A-10) and recovery
(A-11) remain proposed details. Customizable click behavior, installable sprites,
broader tools and marketplace/social direction are now user-stated requirements.

## 2. End-to-end scenarios

| ID | Scenario | Pass condition |
| --- | --- | --- |
| A-01 | Create → style → apply → relaunch → edit | Build an agreed item entirely in GUI; set icon/image, text and typography; active result matches the preview; reload preserves editable blocks and assets. Cancel restores the previous live presentation. |
| A-02 | Conditional behavior | Feed known below/above/boundary values, missing, stale, and failure. Correct branch/style; exact configured duration/hysteresis; notification occurs once per intended transition. Preview produces no side effects. |
| A-03 | Custom expanded menu board | Create a sprite with a board containing custom layout, two bound readings and a control. Icon click opens that board once; data and pending/failure state are truthful; keyboard use and dismissal work; saving/reopening preserves layout/bindings. A sprite with no board remains valid and uses its configured behavior. Proposed management access remains available when hidden from the bar. |
| A-04 | Source truth | Compare selected real metrics with their documented calculation and appropriately aligned reference samples. Confirm units/sample windows; no zero on missing/denied. A manual value is labeled manual. |
| A-05 | Actual organization | Every selected app/item operation succeeds or is honestly identified unsupported before application. Verify visible/hidden state, revealing, ordering, restart recovery, identity conflicts, and undo limits. D-01 goals remain incomplete if required operations cannot be met. |
| A-06 | Display/lifecycle matrix | Test selected OS/hardware with notched/unnotched or external displays as applicable, scales, resolution changes, display attach/remove, Spaces, fullscreen, menu bar auto-hide, light/dark, and wake. No lost recovery access or endless rearrangement. |
| A-07 | Shared source lifecycle | Three items use one source at different intervals. One provider samples at effective demand; disabling fastest consumer lowers demand; disabling last consumer removes all its observers/timers/jobs. Hidden active alerts still receive required data. |
| A-08 | Profiles and state | Switch profiles during polling and a slow action. Correct items/subscriptions activate; stale results cannot overwrite new state; an already-run external effect is never reported undone. Shared versus duplicated definitions behave as documented. |
| A-09 | Denied/revoked access | Deny and revoke each applicable permission; affected features report the cause and repair route while unrelated items work. Re-enable without duplicate subscriptions or repeated prompts. |
| A-10 | Portable setup | Export/import an item and a profile with nested dependencies, user assets, scripts, missing files, and credentials. Blocks round-trip; IDs remap correctly; no secret/live-log leakage; scripts stay disabled; malicious/oversized archive fails without changing active setup. |
| A-11 | Bad configuration and crash recovery | Invalid draft cannot replace active revision. Truncated file, interrupted save, incompatible schema, failed migration, and repeated-start failure preserve original/backup and allow editor recovery. |
| A-12 | Animation and resource policy | Static is fully usable; selected animation state/speed work. Reduced motion, locked screen, popup closure, disable, and sleep stop relevant work. Bounded assets cannot grow decoded memory indefinitely. |
| A-13 | Sleep, clock, and interval behavior | Sleep across several scheduled intervals; wake refreshes once with no side-effect replay. Timezone/DST/manual wall-clock change updates clock/calendar rules; countdown behavior matches the selected elapsed-time policy. |
| A-14 | Accessibility | Complete create/connect/style/reorder/apply without drag-only interaction. VoiceOver announces values, units and status; focus visible; color-independent errors; reduced motion honored. |
| A-15 | Daily lifecycle | Launch at login enabled/denied/disabled; close editor; relaunch app with no visible item; quit; reopen. No orphan observers/jobs, duplicate app instance, or invisible unrecoverable state. |
| A-16 | Logs and network failures | Rotate/truncate/delete log, burst beyond bounds, invalid JSON, offline, timeout, rate limit, moved volume. Buffers/queues remain bounded; last success and staleness truthful; retries follow policy. |
| A-17 | Script containment and action semantics | Harmless fixtures: slow, failure, huge output, missing runtime, spawned child, interactive Shortcut. Verify deadlines, cleanup limits, bounded concurrency, pause-after-failures; a recorded action runs once and is not retried after uncertain completion. |
| A-18 | Overload and responsiveness | Import/configure beyond agreed limits; flood source changes and trigger actions. Validation/backpressure preserve main-thread responsiveness; dropped/coalesced data explained where relevant; no silent unbounded queues. |
| A-19 | Same sprite across appropriate surfaces | Demonstrate the accepted versions of a usage monitor, Homebrew manager and app switcher. Shared settings/state and meaningful customization; no forced tiny popup for a large job. Sprites hidden from the bar remain identifiable and controllable in My Sprites. |
| A-20 | Install → personalize → upgrade | Install a versioned sprite, change appearance/actions/settings, upgrade compatible code, and retain user changes. Show incompatible changes and explicit resolution; package rollback does not claim to undo external effects. |
| A-21 | System helper lifecycle | Each selected OS helper handles access denial, conflict, disable, uninstall, crash and wake. Restore input/window behavior where supported; failing code cannot trap keyboard/mouse input. Record unavoidable limits. |
| A-22 | Sustained service / long operation | Active service stays alive only while needed; health/cost attributable; backoff and stop work. Long package operation retains progress and truthful outcome through UI closure; uncertain writes are not blindly retried. |
| A-23 | Community distribution | Accepted creator/account model: publish a version, another user discovers/installs it, dependencies and compatibility resolved, update/removal behavior matches policy. Test package integrity and no executable activation merely from browsing. |
| A-24 | Likes/friends and offline use | Verify selected relationship/privacy rules and community interactions; marketplace outage does not break installed local sprites. Exact social flows require a spec before this can pass. |
| A-25 | Creative freedom on installed tools | Rework the face, declared window/popup/overlay layout, styles, shortcuts and actions of installed examples. Identify any custom-code boundary; fixed opaque UI does not count as full visual editability. |
| A-26 | Identity, visibility and enablement | Create/install a sprite with an identity icon; hide it from the menu bar; retain its icon in management UI and its enabled functionality. Restore bar visibility without losing configuration. Disabling behavior is separate. Save/relaunch preserves these independent states. |
| A-27 | External app data reader, if selected | Against an identified target/version/field, compare source and rendered values through updates, hiding, menu closure, restart, locale and denied access. Show unavailable/stale/uncertain instead of inventing a value; measure source-plus-reader cost. Action forwarding needs separate proof. A screenshot or static mirror is not evidence of a working structured-data adapter. |

## 3. Provisional resource and usability targets

These numbers are **engineering proposals**, not user-agreed budgets or measured
results. Benchmark the native feasibility build before accepting or revising
them with an explanation. Do not weaken them silently to make a test pass.

Measure a release build, debugger detached, on an identified Mac/OS with a fixed
configuration. Report app plus owned helper/process totals. CPU percent is
`100 × process CPU seconds / elapsed wall seconds` (100% = one fully occupied
core). Record sampling method, median, p95 and peaks, memory metric, wakeups, and
whether other applications/thermal state confounded the run.

| Workload | Proposed target / method |
| --- | --- |
| Static idle | Five static items, editor/popups closed, no providers/scripts/animation, external organization off: average CPU ≤0.1% over 10 min after 2 min warm-up; physical footprint ≤60 MiB. No MenuSprite periodic polling/animation timer. |
| Representative local bar | Clock at minute resolution, battery events, CPU/memory/network rates at 5 s, storage at 60 s, editor closed: average CPU ≤0.5%, footprint ≤120 MiB over 30 min. Validate the final personal layout separately. |
| Editor open | Ten items, selected item of 30 blocks, normal asset set: footprint ≤250 MiB; local edit-to-preview p95 <100 ms; no main-thread blocking by source work. |
| Popup opening | Cached native content appears within 150 ms p95 over 30 openings; asynchronous readings show pending/stale state instead of delaying opening. |
| Leak regression | After warm-up, 200 edit/open/close/profile cycles: no accumulating live owner objects, tasks, observers or child processes; settled footprint returns within 10 MiB of initial settled baseline. Investigate allocator caches separately from retained-object leaks. |
| Eight-hour use | Stable workload: no sustained upward footprint trend after caches settle; end within max(10 MiB, 10%) of post-warm-up baseline; no growing logs/queues/process counts. |
| Disabled workload | Disable all relevant items: no provider polling, running script, animation, or active file/network subscription remains solely for them. |
| Organizer enabled | Measure the same baseline with organizer on; report its incremental cost and compatibility. No continuous screenshot loop permitted without a separately agreed measured need/budget. |
| Animation/scripts/log bursts | Separate explicit workloads, measured together with the app. Meet configured bounds and responsive UI; set final CPU/RAM envelope from V-04. Do not hide subprocess cost from totals. |

Final numeric caps for import size, block/source counts, decoded image memory,
and aggregate caches are an explicit V-04 output before import is released.
Do not market the app's minimum static footprint as its cost with active scripts.

## 4. First personal-build sequence

**Latest steering, 8 September: Permissions & Access comes first.** Before the
tool sequence below, address [the single permissions page](../permissions-page.md).
Verify its supported state checks and management paths, honest unknown/limited
states, complete category visibility and low idle cost when implementation begins.
Do not interpret the subsequent sequence as an instruction to start an MVP now.

The previous whole-platform sequence is superseded by Prerak's 8 September
direction. Package/community design does not precede personal use.

1. Finish the actual daily-tool checklist and the expected readings/actions.
2. Build the native host and first selected tool end to end, including useful
   visual customization, optional expanded menu board, save/reopen and early
   measurement of memory and idle CPU. Resolve only that tool's API questions.
3. Add the other selected tools, measuring the combined resident app and owned
   workers. Reuse common pieces when useful; verify actual daily workflows,
   restart, disable/recovery and long-running memory behavior.

This sequence preserves the visual builder and broader system-tool jobs. It does
not require a complete generic block language, public package ABI, marketplace,
social service, or every research investigation before a usable personal release.
See [the current brief](../first-personal-build.md) for scope and deferred work.

## 5. Definition of ready / done

**Ready to begin an implementation stage:** its product scope is accepted,
upstream decisions are available, fixtures/real source references are identified,
failure behavior is specified, and its acceptance criteria are observable. A
feasibility stage can start with uncertainty only when it names the question and
the decision its evidence will resolve. Development still needs Prerak's explicit
start instruction.

**Done:** all selected confirmed/proposed features work in the native app on the
accepted platform matrix; D-01 replacement workflows are demonstrated; no open
acceptance failure is disguised as "macOS limitation" without a product decision;
resource/accessibility/recovery checks pass; installation and scope limitations
are documented. Distinguish local tests, Prerak's daily acceptance, and any public
release. Do not substitute the website's simulated interactions for native proof.
