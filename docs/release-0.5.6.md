# MenuSprite 0.5.6 Preview 1 — released 28 September 2026

**Published and verified** on GitHub, Homebrew and the canonical website.
App build 17; tag `v0.5.6-preview.1`; Homebrew version `0.5.6,17`.

- Website: https://menusprite.prerakgada.in/#download
- Release: https://github.com/PrerakGada/menusprite-releases/releases/tag/v0.5.6-preview.1
- Update: `brew update` followed by `brew upgrade --cask prerakgada/tap/menusprite`

## Included

Everything built between 14 and 28 September: the hub panel, quit buttons on process rows,
Claude Code session and Arc tab rows, fixed-width readouts with the level bar and memory-pressure /
power-draw colours, the battery item, regrouped Monitoring & Sprites, menu-bar spacing and Open at
login, the restyled Battery & Power dashboard, the compact AI Accounts board with auto-reload, and
read-only CLI logins. **The Dynamic Island ships switched off**, and it has not yet been
checked on screen (see `dynamic-island.md`).

Excluded from the public build as before: the privileged helper, and with it the charge limit,
Low Power Mode switching and closed-lid controls, plus Work & Clients.

## Artifacts and signing

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `MenuSprite-0.5.6-preview.1-arm64.zip` | 8,669,684 | `9e33478cd9628beb44f953ff3648e89c903cedf58f67cae39fd5fa799bb5de56` |
| `MenuSprite-0.5.6-preview.1-arm64-installer3.dmg` | 10,522,929 | `a0691934864647caf55f6948d3ee9c35b20df41a38fca9ae2a56478fea7f8549` |

Developer ID Application (`RC63N3VU27`), hardened runtime, secure timestamp. Apple accepted app
submission `2bbf2076-7319-4ad7-b541-1346cc1cfe77` and DMG submission
`fba99d22-de6a-42c6-9def-aa756fb26291`; both stapled, Gatekeeper accepts both. The Now Playing bridge
dylib is signed separately inside `Contents/Frameworks`.

## Verification

- 924 unit tests passed before release.
- `--release-validate` on the exact notarized ZIP: **25/25**. The first build failed one check
  ("five configured items"). The check was out of date: Battery had joined the fresh-install
  defaults. It now expects six items including Battery; the app was rebuilt and re-notarized. The
  first attempt is kept under `attempt1/`.
- The GitHub DMG download matched the local SHA-256 and passed Gatekeeper.
- Real `brew install --cask` into an isolated app directory: 0.5.6 installed, quarantine retained,
  Gatekeeper accepted. Launching the quarantined copy stopped at macOS's first-open prompt, which
  was not clicked. The cask's own download matched the published ZIP; its de-quarantined copy passed
  25/25 as the same executable. **Uninstalling the cask quits every app with the shared bundle ID,
  including the personal build. Relaunch `~/Applications/MenuSprite.app` afterwards.**
- The live website shows 0.5.6 Preview 1 with both DMG links.

## Publication records

- Source: `b478b75` on `PrerakGada/MenuSprite`.
- Download repository metadata commit `264f3e5`; Homebrew tap commit `405e2df`.
- Release published 2026-09-28 16:42:35 UTC.

Private evidence: `native/.build/distribution/v0.5.6-preview.1/`.
