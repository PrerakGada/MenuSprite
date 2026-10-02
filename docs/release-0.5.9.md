# MenuSprite 0.5.9 Preview 1 — released 2 October 2026

**Published and verified** on GitHub, Homebrew and the canonical website.
App build 20; tag `v0.5.9-preview.1`; Homebrew version `0.5.9,20`.

- Website: https://menusprite.prerakgada.in/#download
- Release: https://github.com/PrerakGada/menusprite-releases/releases/tag/v0.5.9-preview.1
- Update: `brew update` followed by `brew upgrade --cask prerakgada/tap/menusprite`

## Included

Everything committed on `main` since 0.5.8, by Prerak's choice, plus the feedback feature:

- **Report a Problem… and Send Feedback…** (`docs/feedback.md`): a Help & feedback card first in the hub's Tools
  tab opens one small window that posts to the shared product-feedback endpoint only when Send is pressed, with
  only what the form lists. The real sender exists only in an ordinary launch.
- **Wi-Fi and Bluetooth sprites, readings and boards** (`docs/wifi-bluetooth.md`), icons bound to a value, the
  Location entitlement, and Location/Bluetooth requests made from the front with a fallback to the Privacy pane.

Still excluded: Work & Clients.

## Artifacts and signing

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `MenuSprite-0.5.9-preview.1-arm64.zip` | 12,412,883 | `b5fe332437c3c493282a6e816eab643af76a4c47a1ad9407f7fe67a9c7062985` |
| `MenuSprite-0.5.9-preview.1-arm64-installer3.dmg` | 14,267,526 | `2a3daf8512b73b9f3f35e6c54a0d260664b59801371c0e1b1f2d350299a05753` |

Developer ID Application (`RC63N3VU27`), hardened runtime, secure timestamp, on the app and both nested
executables. Entitlements: camera, audio-input, calendars, location. Apple accepted app submission
`9af46232-6c20-4a99-959f-d5cc47a4dbfd` and DMG submission `32100118-28af-4197-bad0-8b61974782da`. Both are stapled
and accepted by Gatekeeper; `codesign --verify --deep --strict` and `scripts/verify-power-helper.sh` pass.

**The `menusprite-notary` keychain profile disappeared** between the first and second packaging on 2 October
(Pastebook, Screenroll and MacSweep share it). The release was notarized with the team's App Store Connect API key
(`company/infra/README.md` §4) by running `package-release.sh`'s steps from `notarytool submit` on with `--key`.
Run `scripts/setup-notarization.sh` to restore the profile.

A first build (card at the bottom of Tools, app submission `f090844b-…`) was notarized and validated 29/29 but
never published; it is kept under `attempt1/`.

## Verification

- 1,137 unit tests passed (15 new in `ProductFeedbackTests`). Source audit passed (644 files, full history).
- `--release-validate` on the exact notarized ZIP: **29/29**. New: a validation launch has no live feedback sender
  and opens no feedback window.
- Upgrade check: `--sprite-studio-render --from` on 0.5.7's and 0.5.8's fresh-install configs gives the same widths
  as 0.5.8's run (fan item 93 pt, accepted at 0.5.7); only live values differ.
- `--feedback-render` from the release binary: every form state and the Tools tab's first screen, light and dark;
  the card is first. "Sent with" reads `MenuSprite 0.5.9 (20) · macOS … · Mac…`.
- The endpoint answers for `menusprite` (an empty body returns the server's 400; nothing stored).
- Homebrew: `brew info` shows `0.5.9,20`; `brew fetch` downloaded a ZIP byte-identical to the validated one, and
  Gatekeeper accepts the extracted app. `brew livecheck`: `0.5.9,20 ==> 0.5.9,20`. No real `brew install`.
- The public DMG download matches the local SHA-256 and passes Gatekeeper. The live site shows 0.5.9 Preview 1,
  both counted download links 302 to the exact 0.5.9 DMG, and the FAQ describes the feedback send.

**Not verified:** nothing of the feedback window has been used on screen (typing, ⌘↩, Esc, ⌘W, activation from the
hub, a real send), nor the Wi-Fi/Bluetooth boards' clicks and prompts on a fresh Mac.

## Publication records

- Download repository metadata commit `87bbec0`; Homebrew tap commit `93478ab`.
- Release published 2026-10-02 08:48:53 UTC.
- Source: binary built from `28bcc70`; `1e3fbdf` and `d326740` are copy-only (README, release notes, site).

Private evidence: `native/.build/distribution/v0.5.9-preview.1/` (`validation-public/`, `upgrade-fresh057/`,
`upgrade-fresh058/`, `feedback-render/`, `attempt1/`).
