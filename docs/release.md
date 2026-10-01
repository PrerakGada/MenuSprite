# Public Homebrew preview

**Current: MenuSprite 0.5.8 Preview 1 (19), released 1 October 2026.**
Signed and notarized for Apple Silicon Macs running macOS 26 or newer.

```sh
brew install --cask prerakgada/tap/menusprite
```

Update an existing Homebrew installation with `brew update`, then
`brew upgrade --cask prerakgada/tap/menusprite`.

- [Website and DMG installation guide](https://menusprite.prerakgada.in/#download)
- [GitHub release and checksums](https://github.com/PrerakGada/menusprite-releases/releases/tag/v0.5.8-preview.1)
- [Homebrew cask](https://github.com/PrerakGada/homebrew-tap/blob/main/Casks/menusprite.rb)
- [Full 0.5.8 verification record](release-0.5.8.md) · [0.5.7](release-0.5.7.md) · [0.5.6](release-0.5.6.md) · [0.5.5](release-0.5.5.md)
- [Historical 0.4.0 release](release-0.4.0.md)

## Public scope

Configurable system monitoring, native CPU/RAM/Power views, Permissions & Access,
ordinary keep-awake, and optional Claude/Codex usage/account tools. Icon and text
colors are independent, labels editable, pace colors can target just the percent
symbol, and readouts have small side margins. Existing user settings are preserved.

Charge limit, discharge, Low Power Mode, the MagSafe light, fan control and closed-lid
keep-awake are included. They need MenuSprite's power helper, which ships inside the app,
stays off until you choose Turn on power controls, and runs only after you allow MenuSprite
in System Settings → General → Login Items & Extensions (macOS asks for an administrator
password there). Work & Clients stays excluded. No claim of capture, clipboard,
marketplace or sharing. Per-process Power is CPU-energy-derived. Sensors vary by Mac.

This is the owner's `prerakgada/tap` preview, not the official Homebrew Cask catalog.
Only public metadata and binaries go to the separate download repository; native
source, internal plans, personal configuration and private diagnostics stay local.

## Build and publish

The release version, build, channel and asset names come from `distribution/version.json`.
Keep `native/Resources/Info.plist` consistent; the public build refuses a mismatch.
Artifacts and reports live under `native/.build/distribution/<release_tag>/`.

```sh
MENUSPRITE_NOTARY_PROFILE=menusprite-notary ./scripts/package-release.sh
# Validate the exact final ZIP via --release-validate and the version's validation-public directory,
# then run --sprite-studio-render --from <previous release's validation-public/test-config.json> on it
# to check what upgrading users' sprites turn into (see release-0.5.7.md and release-0.5.8.md).
./scripts/publish-release.sh
```

The package script uses Developer ID, secure timestamps, Apple notarization and
stapling for both app and DMG. The publish script verifies those results, the public
policy, version and exact binary hash from native validation. It will not overwrite
existing release tags/assets. It then publishes downloads and updates the checksum-pinned
cask and prerelease declaration. Complete public-download/Gatekeeper, real isolated
Homebrew installation, strict online audit/livecheck, and website checks afterward.

The installed personal development app keeps its existing Apple Development signing
identity. Test public builds in an isolated app directory and restore the personal
app afterward. Remove test casks without zap and with `HOMEBREW_NO_AUTOREMOVE=1`.
Never reset TCC to hide a signing-identity transition.
