# MenuSprite 0.5.7 Preview 1 — released 29 September 2026

**Published and verified** on GitHub, Homebrew and the canonical website.
App build 18; tag `v0.5.7-preview.1`; Homebrew version `0.5.7,18`.

- Website: https://menusprite.prerakgada.in/#download
- Release: https://github.com/PrerakGada/menusprite-releases/releases/tag/v0.5.7-preview.1
- Update: `brew update` followed by `brew upgrade --cask prerakgada/tap/menusprite`

## Included

Everything built on 29 September: the Sprite studio (design trees, values including shell commands,
If/Otherwise rules, designable boards), the left strip, Keep Awake at Vorssaint parity with right-click
toggle and active icon, the menu-bar icon picker, the power flow split by app category, and the Island's
customisable System cards and Tools. Prerak chose to ship the whole tree as it stood (29 Sep, 20:0x),
knowing the Sprite studio and left strip had never been clicked on screen.

**Existing sprites are converted on first launch.** A copy of the previous settings is written beside
them first (`monitoring.before-sprite-studio-<stamp>.json`), and converted sprites keep their old fields.

Excluded from the public build as before: the privileged helper (charge limit, Low Power Mode switching,
closed-lid controls) and Work & Clients.

## Artifacts and signing

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `MenuSprite-0.5.7-preview.1-arm64.zip` | 10,403,488 | `fbcdcb3341ea7459dc63ad7cb7794d53a8af019b3cd968991066395ff759463d` |
| `MenuSprite-0.5.7-preview.1-arm64-installer3.dmg` | 12,264,582 | `29b00c9cfd9866c69018b49162117ff8333fc2ab507a7291fc5a85f315340aa5` |

Developer ID Application (`RC63N3VU27`), hardened runtime, secure timestamp. Apple accepted app
submission `25d02160-e32a-47cd-8517-6bc1283b14ca` and DMG submission
`14c648bb-5c32-46e2-9148-548981f64760`; both stapled, Gatekeeper accepts both.

## Verification

- 955 unit tests passed.
- `--release-validate` on the exact notarized ZIP: **25/25**.
- **Upgrade check (new for this release).** `--release-validate` starts from a fresh config, so it never
  exercises the conversion a 0.5.6 user hits. The release binary's `--sprite-studio-render --from` was run
  on the 0.5.6 fresh-install config (`v0.5.6-preview.1/validation-public/test-config.json`) and on Prerak's
  pre-studio backup. **The first build failed it:** every converted Fan & CPU temperature item drew
  "67°C" larger than "3757 rpm", because each two-row band was fitted alone and "rpm" has a descender.
  Fixed in `DesignRenderer.fit` (text starting at one size across equal bands ends at one size) with test
  `twoRowValuesShrinkTogether`, rebuilt and re-notarized; the first build is kept under `attempt1/`.
  Remaining, accepted: that item is 7 pt narrower (93 vs 100 pt) because each row now spaces its own label
  and value instead of sharing one value column. Other default items: same width, 0–190 differing pixels.
- Homebrew: `brew info` shows `0.5.7,18`; `brew fetch` downloaded a ZIP byte-identical to the validated one,
  and Gatekeeper accepts the extracted app. `brew livecheck`: `0.5.7,18 ==> 0.5.7,18`.
  **No real `brew install` this time**: its uninstall quits every app with the shared bundle ID, including
  Prerak's running build, and a quarantined launch stops at macOS's first-open prompt.
- The public DMG download matched the local SHA-256 and passed Gatekeeper.
- The live website shows 0.5.7 Preview 1 with both DMG links and the Sprite studio copy.

## Publication records

- Source: `d671fc4` on `PrerakGada/MenuSprite`.
- Download repository metadata commit `6c730a6`; Homebrew tap commit `6bac49f`.
- Release published 2026-09-29 15:05:26 UTC.

Private evidence: `native/.build/distribution/v0.5.7-preview.1/` (`upgrade-fresh056/compare.png`).
