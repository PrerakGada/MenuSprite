# MenuSprite 0.4.0 Preview 1 — historical release record

Released 10 September 2026; superseded by 0.5.5 on 13 September.
The scripts and future-release notes below describe the original 0.4.0 release workflow.

**Published and installation verified.** MenuSprite 0.4.0 Preview 1 is available
from the owner's Homebrew tap:

```sh
brew install --cask prerakgada/tap/menusprite
```

The [landing page installation guide](https://menusprite.prerakgada.in/#download)
now includes Homebrew and DMG drag-to-Applications instructions; its 10 September deployment
and download verification are recorded in `deployment.md`.

- [Public download and release notes](https://github.com/PrerakGada/menusprite-releases/releases/tag/v0.4.0-preview.1)
- [Homebrew cask](https://github.com/PrerakGada/homebrew-tap/blob/main/Casks/menusprite.rb)
- Requirements: **Apple Silicon and macOS 26+**.
- App version/build: `0.4.0` (`8`); cask version: `0.4.0,8`.
- Primary manual download: `MenuSprite-0.4.0-preview.1-arm64-installer3.dmg`, 4,642,930 bytes.
- DMG SHA-256: `9acd47428180617b06637ac926caf2399ba785efd7ddc7f719b36b7ae74f2e94`.
- ZIP retained for Homebrew and existing links: `MenuSprite-0.4.0-preview.1-arm64.zip`, 2,774,764 bytes.
- ZIP SHA-256: `e937fa30a4a5b5caa6139c807183c02a69921f3707d92dd803f7547798c4c62f`.

The two formats contain the same app. DMG installer revision 3 adds a violet/mint,
Retina-ready Finder window with large app/Applications icons, a sweeping curved
arrow, “Control your menu.” branding and clear installation instructions. The original DMG remains available under
its existing URL. The presentation update does not require an app reinstall.
See [DMG packaging and verification](dmg-installation.md).

This is a public preview distributed through `prerakgada/tap`, not an acceptance
into the official Homebrew Cask repository. The download repository contains
README/version metadata and release binaries only. Application source, internal
plans, private diagnostics and personal configuration remain local.

## Scope

Monitoring, native CPU/RAM/Power process panels, Permissions & Access and ordinary
keep-awake are included. Public builds exclude the privileged helper/installers,
hide charging/closed-lid actions, reject privileged IPC and mark those access
categories unavailable in this build. Personal developer builds retain the
experimental controls.

The known keep-awake issues were corrected for this preview: timer expiry ends
only the manual session, sleep cancels the pending timer, inactive user sessions
pause assertions, and Pause rules preserves a manual session. AC rules use
IOPowerSources. Physical lock/sleep/display acceptance remains separate from the
simulated callback tests; hardware controls are not advertised as accepted.

New installations receive five readouts: CPU, RAM, Power, paired upload/download,
and paired fan/CPU temperature. Existing settings are preserved. Sensors vary by
Mac; CPU-temperature mapping currently targets the tested M5 family. Per-process
Power is explicitly CPU-energy-derived, excluding GPU/display/other components.

## Signing and publication evidence

- Developer ID Application: MIND WEALTH (`RC63N3VU27`), hardened runtime and secure timestamp.
- Apple notarization **Accepted**, submission `4888517b-3ca4-45e6-b4b5-8b429948eead`.
- Current DMG notarization **Accepted**, submission `72e20e8d-b0fb-4581-a9a8-35698cd6ab97`;
  the disk image is separately Developer ID signed, stapled and Gatekeeper accepted.
- Ticket stapled and validated, both in staging and after archive extraction.
- Gatekeeper: **accepted — Notarized Developer ID**.
- Anonymous public download matched the published SHA-256 and GitHub asset digest.
- Download-repository metadata commit: `ac11cc4`; original release tag references `88ac837`.
- Tap commits: `329de01` (cask), `60c785c` (preview/update metadata and README).

The tap explicitly identifies this exact version as a GitHub prerelease in
`audit_exceptions/github_prerelease_allowlist.json`; it does not relabel the build
as stable or bypass signing checks. Livecheck reads the public version manifest
and correctly reports current/latest `0.4.0,8`. Future preview releases must update
the version-specific declaration, manifest, URL and checksum together.

## Verified

- 44 automated tests passed; one optional live-source probe skipped (45 total).
- 18 native public-build checks passed again on the exact notarized archive.
- A real `brew install --cask` from the public tap succeeded into an isolated app
  directory, downloading the public GitHub asset with checksum verification.
- The Homebrew-installed app retained quarantine, passed signature/staple/Gatekeeper
  checks, launched via LaunchServices and passed all 18 native release checks.
- Homebrew style, strict online audit and livecheck passed. Homebrew 6 no longer
  accepts the old `--signing` audit flag; signing was checked directly above.
- The test cask was uninstalled without `--zap`; its isolated app was removed.
  The original local development app and saved configuration were preserved.
  Homebrew also auto-removed unused LLVM 23.1.0 and Z3 5.1.0 during cleanup; both
  exact versions were restored from cached bottles, with their dependency status
  and older installed versions preserved. Future test cleanup must set
  `HOMEBREW_NO_AUTOREMOVE=1` (and must not use `--zap`).
- 14 native readout checks passed in the public build. Five readouts with windows
  closed measured 19.56 MiB physical footprint / 65.25 MiB RSS and 0.990% of one CPU
  core over 15.43 seconds. This is a short observation, not a resource guarantee.

Local evidence is in `native/.build/distribution/`: notarization reports,
`validation-notarized/`, `validation-homebrew/`, `validation-resources/`, public
checksums, cask/install info, `livecheck.json` and `publication-verification.json`.
These private diagnostic artifacts were not uploaded.

## Rebuilding and future releases

`./scripts/package-release.sh` builds a separate public bundle at
`native/.build/public-preview/MenuSprite.app` using `MENUSPRITE_PUBLIC_PREVIEW`.
The local development build/signing default remains separate. Notarization uses
the configured `menusprite-notary` Keychain profile; credentials stay out of Git.
Packaging now emits both the original ZIP and a signed, notarized DMG. The DMG
builder uses pinned Python tooling in an ignored local virtual environment and
native AppKit artwork; it does not run or modify the packaged application.

```sh
MENUSPRITE_NOTARY_PROFILE=menusprite-notary ./scripts/package-release.sh
# Validate the exact packaged app using --release-validate and a fresh output directory.
./scripts/publish-release.sh
```

The scripts currently pin Preview 1. Before the next release, update its version,
build, tag/asset names and `distribution/version.json`, then repeat native,
notarization, public-download and Homebrew install checks. Existing release tags
and assets are not overwritten automatically. Publication uploads only public
metadata/binaries and changes the cask in the existing tap.

Keep one installed copy when adopting the public build. Changing from the local
Apple Development signature to Developer ID can require macOS to reassess access;
never reset or assume TCC grants just to make an upgrade look seamless.
