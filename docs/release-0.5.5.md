# MenuSprite 0.5.5 Preview 1 — released 13 September 2026

**Published and installation verified** on GitHub, Homebrew and the canonical website.
App build 16; tag `v0.5.5-preview.1`; Homebrew version `0.5.5,16`.

- Website: https://menusprite.prerakgada.in/#download
- Release: https://github.com/PrerakGada/menusprite-releases/releases/tag/v0.5.5-preview.1
- Install: `brew install --cask prerakgada/tap/menusprite`
- Update: `brew update` followed by `brew upgrade --cask prerakgada/tap/menusprite`

## Included

Filled blue fan icon with white normal-weight values, independently configurable
icon/text colors, and 3 pt left/right margins in inline, stacked and paired readouts.
AI usage supports whole-text or percent-only pace colors and editable labels.
Prerak's existing configuration retains bold white AI text with colored percent
symbols, paired weekly limits without labels, and a separate Claude session item.
Other readouts keep normal weight. New system-monitoring defaults also use normal weight.

The public preview includes Claude/Codex usage and AI Accounts. Privileged charging/
closed-lid controls and the experimental Work & Clients report remain excluded.
No live account switch was run. Source and personal configuration were not published.

## Artifacts and signing

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `MenuSprite-0.5.5-preview.1-arm64.zip` | 3,365,891 | `c6f7d60fabe76dc9bd4214026708a8d6a347bc447b2752300df35a3aa81eb1e0` |
| `MenuSprite-0.5.5-preview.1-arm64-installer3.dmg` | 5,233,230 | `73f6d1259c7004b0ecc2292cb56e4a4bad9c569d1a4cc3851d6b5a5b77194167` |

Developer ID Application: MIND WEALTH (`RC63N3VU27`), hardened runtime, secure timestamp.
Apple accepted app submission `a1fb4f42-967c-4e73-b9eb-fd36fdeadc31` and DMG submission
`97b7bad6-97cc-4aa1-9976-8b6d06713c82`. Both tickets are stapled and validated; Gatekeeper
accepts both. The previously missing `menusprite-notary` profile was restored by Prerak;
credentials remained in Keychain and were not printed or copied.

The mounted DMG's app file tree exactly matches the final ZIP. Its Applications
shortcut resolves to `/Applications`; Finder window bounds, 128 pt icon sizes,
positions and artwork match the existing installer revision 3 layout. This run checked
mounted content/layout metadata; it does not claim a new full Finder-window screenshot.
Older releases and installer assets remain available unchanged.

## Verification

- 127 unit tests passed during implementation, including side margins, independently
  colored filled icons, white digits/colored percent rendering, and configuration compatibility.
- Installed local usage checks: 12/12. Actual status-button images of all seven readouts
  were reviewed in `native/.build/validation/fan-spacing-final-2026-09-13/`.
- Exact notarized public ZIP: 24/24 native checks passed. Reports bind the tests to the
  executable SHA-256 and check the public build's excluded privileged tooling.
- Real Homebrew install downloaded 0.5.5 from the public tap into an isolated app directory.
  Quarantine was retained; signature, staple and Gatekeeper checks passed. LaunchServices
  launched it and all 24 native release checks passed again on that installed binary.
- Homebrew style and strict online audit passed. Livecheck reports current/latest
  `0.5.5,16`, not outdated. The temporary cask was uninstalled without zap and with
  `HOMEBREW_NO_AUTOREMOVE=1`; the original personal app was restored to background use.
- Anonymous GitHub DMG download matched the local SHA-256 and passed staple/Gatekeeper.
- The live website matches the validated HTML byte-for-byte. Both download links,
  release-notes link, version and Homebrew command are correct. Clicking its DMG button
  in the shared browser downloaded a file matching the published SHA-256 and valid staple.
- Website syntax/build and desktop/mobile checks passed. Vercel dry run and actual build
  included only 14 website inputs, excluding native code and internal/private documents.

## Publication records

- Download repository metadata commit: `7368c98`.
- Homebrew tap commit: `5b4b89a`.
- Release published: 2026-09-13 11:07:58 UTC.
- Private hosting deployment identifiers are retained in local operational records.
- Canonical URL: https://menusprite.prerakgada.in/

Private evidence is under `native/.build/distribution/v0.5.5-preview.1/`, including
`publication-verification.json`, notarization reports, native reports, public-download
checks, install/audit/livecheck logs and exact artifact checksums. The mounted DMG
was detached after verification.

Personal config backup before the fan change:
`~/Library/Application Support/MenuSprite/monitoring.before-fan-icon-20260913-011516.json`.

## Future releases

Update `distribution/version.json` and `native/Resources/Info.plist` together, then
run `MENUSPRITE_NOTARY_PROFILE=menusprite-notary ./scripts/package-release.sh`.
Validate the exact final archive with `--release-validate`, write its report to the
version's `validation-public/report.json`, and run `./scripts/publish-release.sh`.
Finish public-download, real Homebrew, Gatekeeper/audit/livecheck and website checks.
The publisher rejects stale binary validation and never overwrites existing release assets.
