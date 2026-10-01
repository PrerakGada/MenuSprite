# MenuSprite 0.5.8 Preview 1 — released 1 October 2026

**Published and verified** on GitHub, Homebrew and the canonical website.
App build 19; tag `v0.5.8-preview.1`; Homebrew version `0.5.8,19`.

- Website: https://menusprite.prerakgada.in/#download
- Release: https://github.com/PrerakGada/menusprite-releases/releases/tag/v0.5.8-preview.1
- Update: `brew update` followed by `brew upgrade --cask prerakgada/tap/menusprite`

## Included

The whole tree as of 1 October, by Prerak's choice to ship everything. Three sessions' work was merged and released
together:

- **Agent-built sprites** (`docs/agent-authoring.md`): the bundled `menusprite` command at
  `Contents/Helpers/menusprite`, its MCP server, the sprite spec, real previews, `menusprite setup <agent>`, eight
  examples in `examples/sprites/`. The app listens on `~/Library/Application Support/MenuSprite/agent.sock` (0600,
  peer uid checked). A second copy of the app refuses to take a socket that already answers.
- **The power helper ships in the public build for the first time** (`docs/power-controls.md`). It is an SMAppService
  daemon, label `in.prerakgada.MenuSprite.PowerDaemon`, at `Contents/MacOS/MenuSpritePowerHelper`, with its plist in
  `Contents/Library/LaunchDaemons/`. It covers charge limit, discharge, Low Power Mode, the MagSafe light, fan control
  and closed-lid keep-awake. Nothing registers until "Turn on power controls…"; the person then allows it in
  System Settings → Login Items & Extensions. The helper writes only the controls the Mac reports as writable. A
  developer install of the older Terminal helper is booted out, restored and removed before registering.
- Fan control (`docs/fan-control.md`), the one tabbed window (`docs/app-window.md`), the sprite gallery, the left
  strip's hover delay, and AI usage Auto refresh with the live Claude login named exactly.

Still excluded: Work & Clients.

**The Homebrew cask** now links `menusprite` onto the PATH (`binary`). It removes the daemon (both labels) and
`/Library/Application Support/MenuSprite` only on `zap`. Uninstall also runs on every upgrade, and booting the
daemon out there would ask for an administrator password each time.

## Artifacts and signing

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `MenuSprite-0.5.8-preview.1-arm64.zip` | 12,106,164 | `1c3101373f172cc61ae88fa573af682d61c42f2bdcff850ce17de464ba7ed3dc` |
| `MenuSprite-0.5.8-preview.1-arm64-installer3.dmg` | 13,934,507 | `7fbc157a316af01a623b0bcc7e94096847dcb791a29cf3511ed27b6fca032f59` |

Developer ID Application (`RC63N3VU27`), hardened runtime, secure timestamp, all on the app and on both nested
executables (`in.prerakgada.MenuSprite.cli`, `in.prerakgada.MenuSprite.PowerHelper`). Apple accepted app submission
`898f7d4e-6f2e-4d4c-ac87-0f3b4560e74d` and DMG submission `19f3589e-673d-44f9-915a-4a1dbb48d53a`. Both are
stapled, and Gatekeeper accepts both. `codesign --verify --deep --strict` passes, and so does
`scripts/verify-power-helper.sh`.

## Verification

- 1,101 unit tests passed. Source audit passed (632 files, full history).
- `--release-validate` on the exact notarized ZIP: **28/28**. This includes the new helper checks: no Terminal
  installers, the daemon plist names the bundled helper, the helper carries the signature the app requires, a
  launch asks nothing of macOS, and helper access reports the real SMAppService status.
- Upgrade check: the release binary's `--sprite-studio-render --from` was run on 0.5.7's fresh-install config.
  It gave the same widths as 0.5.7, including the fan item at 93 pt, which was accepted then. Only value-kerning
  pixels differ. A copy of Prerak's own config also rendered cleanly.
- The bundled `menusprite version` reached the running app over the socket. Earlier the same day, a7's real
  demo created a sprite through `menusprite mcp` against the installed build.
- Homebrew: `brew info` shows `0.5.8,19`. `brew fetch` downloaded a ZIP byte-identical to the validated one, and
  Gatekeeper accepts the extracted app. `brew livecheck` reports `0.5.8,19 ==> 0.5.8,19`. The cask carries the
  `binary` and `zap launchctl` stanzas. No real `brew install` was run, for the same reason as 0.5.7.
- The public DMG download matched the local SHA-256 and passed Gatekeeper. The live website shows 0.5.8
  Preview 1 with both DMG links.

**Not verified:**
- The SMAppService approval flow on a Mac that never had the developer helper. It was tested only on Nebula,
  through the legacy-replacement path.
- Fan and charge writes on any Mac other than Nebula's M5 Max.
- Board blocks, switches and the Refresh button have not been clicked on screen. Nor have the fan board, the one
  window or the left-strip hover.

## Publication records

- Source: `5e42157` on `PrerakGada/MenuSprite` (features in `f8ece98`).
- Download repository metadata commit `f7beed4`; Homebrew tap commit `c44c1fe`.
- Release published 2026-10-01 08:19:35 UTC.

Private evidence: `native/.build/distribution/v0.5.8-preview.1/` (`validation-public/`, `upgrade-fresh057/compare.png`,
`upgrade-own/`).
