# MenuSprite DMG installer — 10 September 2026

**Current release, 13 September:** installer revision 3 now wraps the notarized
0.5.5 (16) app. Layout/artwork are unchanged; mounted content and Finder layout metadata
were verified, and the downloaded DMG passes signing/staple/Gatekeeper checks.
Current artifact/checksum: [0.5.5 release record](release-0.5.5.md).
The remainder of this page records the original 0.4.0 installer work.

The direct download is now a signed, notarized disk image with a real
drag-to-Applications Finder window. It contains the **unchanged 0.4.0 (8) public
app** from the original notarized ZIP. The ZIP and Homebrew cask are preserved;
this packaging addition does not require existing users to update the app.

- Current installer revision: **3**, a presentation-only update.
- Asset: `MenuSprite-0.4.0-preview.1-arm64-installer3.dmg` (4,642,930 bytes).
- [Download](https://github.com/PrerakGada/menusprite-releases/releases/download/v0.4.0-preview.1/MenuSprite-0.4.0-preview.1-arm64-installer3.dmg).
- SHA-256: `9acd47428180617b06637ac926caf2399ba785efd7ddc7f719b36b7ae74f2e94`.
- Signer: Developer ID Application: MIND WEALTH (`RC63N3VU27`).
- DMG notarization: **Accepted**, `72e20e8d-b0fb-4581-a9a8-35698cd6ab97`.
- Ticket stapled and validated; Gatekeeper accepts the DMG as Notarized Developer ID.

## Installation experience

Opening the DMG mounts a read-only `MenuSprite` volume and opens its Finder window.
The app sits on the left and the real `/Applications` shortcut on the right, with
128-point icons and a broad curved arrow that starts beside the app and points
into the folder. Revision 3 brings back the violet/mint identity: a small menu-rail
motif, colored backdrops behind the real icons, a violet curved arrow, and a deep
violet footer. The taglines are “Control your menu.”, “Your tools. Your style. Your
rules.” and “A little sprite. A lot of control.” Clear drag/drop captions and the
open/eject instructions remain. The app and system folder retain their native artwork.

The background includes 1x and 2x representations. Finder window bounds are
760 × 604 points, leaving room for users whose Finder preferences show tabs,
path/status bars. Packaging does not change global Finder preferences.

For updates, quit MenuSprite before dragging and choose Replace when Finder asks.
The installer does not write personal configuration, run helper installers or
launch the app automatically. The landing page and release README explain this
flow alongside the unchanged Homebrew command.

## Build and release

`scripts/build-dmg.sh` takes an already notarized MenuSprite.app and a new output
path. It verifies the signing identity, arm64 architecture, notarization ticket,
and absence of privileged tooling. It renders the background through AppKit and
uses `dmgbuild` with `scripts/dmg-settings.py` to write the Finder layout.
Python packaging tools are pinned in `scripts/dmg-requirements.txt` and installed
only under ignored `native/.build/dmg-tools/`.

```sh
./scripts/build-dmg.sh /path/MenuSprite.app /path/MenuSprite.dmg
# Open the image in Finder and review the actual layout before publication.
MENUSPRITE_NOTARY_PROFILE=menusprite-notary ./scripts/notarize-dmg.sh /path/MenuSprite.dmg
```

The second script submits the disk image, requires Accepted status, staples its
ticket, checks Gatekeeper and writes its final SHA-256. `package-release.sh` now
runs both steps after app/ZIP notarization. `publish-release.sh` requires the
notarized DMG and checksum and includes both formats in future releases.
Existing release files must not be overwritten. Preview 1's DMG was added as a
new asset to the existing release, alongside its unchanged original ZIP.
Installer revisions use distinct filenames, recorded in `distribution/version.json` as
`dmg_asset` / `installer_revision`; both packaging scripts use that filename.
The landing page and release README link to the revision without changing the
app version or Homebrew cask. No reinstall is needed for existing users.

## Revision 3 checks

- Visually reviewed the actual Finder window: violet/mint accents, all taglines,
  arrow/target alignment, readable labels, and unclipped footer text.
- The app file tree is identical to the original notarized app; strict signature
  and stapled-ticket checks pass. The shortcut still points to `/Applications`.
- The new DMG is separately signed, notarized, stapled and Gatekeeper accepted.
- The live website's two download buttons point to revision 3. Its downloaded
  checksum, stapled ticket and Gatekeeper assessment passed after publication.
- This is a presentation-only change; the prior native tests were not rerun.

## Revision 2 checks (previous layout)

- Visually reviewed the actual mounted Finder window: curved arrow alignment,
  larger icons, neutral styling, readable captions and footer, and no overlaps.
- The entire packaged app file tree matches the original notarized app. Its
  signature and stapled ticket pass verification. `/Applications` is still the
  real destination of the installer shortcut.
- The revised DMG is signed, notarized, stapled, and Gatekeeper accepted.
- The download from the live landing page matches the final checksum and passes
  stapled-ticket and Gatekeeper checks. Both website download buttons use the new
  filename. The downloaded installer was mounted again for review.
- The app has no code changes, so the prior native tests below were not rerun.

## Initial DMG validation

- The actual installer window was visually reviewed in Finder on macOS 26,
  including Retina rendering, large icons, readable labels, and unclipped text.
- Opening the DMG through LaunchServices automatically mounted and opened its
  Finder window. The Applications shortcut resolves to `/Applications`.
- Finder copied the app from the mounted image into an isolated Applications
  folder. The entire app file tree matched the app extracted from the original ZIP.
- The copied app passed strict signing, stapled-ticket and Gatekeeper checks.
- LaunchServices launched that copied native app with isolated validation
  preferences; **18/18 native release checks passed**. No permission request,
  privileged helper action or physical sleep was triggered.
- The original personal app and configuration were not replaced. The production
  Applications destination and a Finder replacement dialog were not exercised.
- The DMG downloaded through the live landing-page button matched the final
  checksum and passed stapled-ticket and Gatekeeper checks again. Opening that
  downloaded copy mounted the installer for review.
- The live site passed 11 focused browser checks, including both DMG links,
  download completion, command copying, installation copy and responsive layout.

Local evidence: `native/.build/distribution/validation-dmg/`, each DMG's adjacent
notarization JSON/checksum, and
`~/.claude/playwright-output/menusprite-installer3-design.png` for revision 3.
The previous neutral layout is captured in `menusprite-dmg-refinement.png`.
The initial layout screenshot remains `menusprite-dmg-finder-v2.png` (the filename
reflects its internal drawing iteration, not the published installer revision).

The original `MenuSprite-0.4.0-preview.1-arm64.dmg` is preserved unchanged at
SHA-256 `0687a5129cc2bb3c74915b3b1881ec19a73ab340b82b2141b4a5a42e32306046`;
its notarization was `0b4a1e4b-ea92-4abd-a671-64b10e6c15f7`.

Installer revision 2 is also preserved as `MenuSprite-0.4.0-preview.1-arm64-installer2.dmg`,
SHA-256 `fd33df43026bb085479a9d8bd1cbe82d4a7f527f8da62128554202f6bdb8181a`,
notarization `6f632ebf-dc1b-4bcd-9a97-d8bae5eeb1fc`.
