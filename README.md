# MenuSprite

A native macOS playground for customizable tools called sprites, in the making.

Landing page: https://menusprite.prerakgada.in/

**MenuSprite is open source under the [MIT license](LICENSE).**
The complete source is at [PrerakGada/MenuSprite](https://github.com/PrerakGada/MenuSprite).
The separate release repository below distributes binaries. See the
[publication audit](docs/open-source-readiness.md),
[security policy](SECURITY.md), and [third-party notices](THIRD_PARTY_NOTICES.md).

[Download and installation guide](https://menusprite.prerakgada.in/#download).

Public preview for Apple Silicon Macs on macOS 26+:

```sh
brew install --cask prerakgada/tap/menusprite
```

[Download and release notes](https://github.com/PrerakGada/menusprite-releases/releases/tag/v0.5.5-preview.1).
Developer ID-signed and notarized; this preview excludes privileged battery and
closed-lid controls. [Release verification](docs/release.md).


- `brand/`: Slim rail / Arranger identity, variants, manifest, and references.
- `site/`: public landing page and interactive browser concept with example data.
- `docs/product-brief.md`: agreed scope and what is implemented versus planned.
- `native/`: working AppKit/SwiftUI app, Permissions & Access, system monitoring
  and configurable menu-bar sprites, plus first battery/sleep controls.
- [Power Controls](docs/power-controls.md): keep-awake, battery/helper setup and validation limits.
- [System monitoring](docs/system-monitoring.md): readings, sprite configuration and limits.
- [Permissions & Access](docs/permissions-page.md): the governing page specification.
- [First personal build](docs/first-personal-build.md): current priority and short
  path to a usable app with very low memory use; marketplace work is deferred.
- [Native product planning](docs/planning/README.md): working PRD, feature spec,
  architecture, feasibility evidence, acceptance plan, and decisions for discussion.

## Native app

Local 0.5.0 adds the [Battery & Power dashboard](docs/energy-dashboard.md).
Click PWR for live flow, battery charts and charge controls. Hardware actions need
the signed administrator helper and a handover from any other charge controller.

```sh
./scripts/build-native.sh --install
open ~/Applications/MenuSprite.app
swift test --package-path native
```

The installed app opens **Monitoring & Sprites**. Its MenuSprite menu-bar icon opens
that configuration window or Permissions & Access. Closing the window leaves enabled
monitoring sprites running. Quit from its menu.
Requires macOS 26+ and Xcode's Swift toolchain to build. The current local build is
arm64, development-signed, with 36 permission/access rows and a monitoring library.
Start with the System sprite or use a reading's **+ → New sprite** to add your own.
The website remains a separate concept.

For a source-only build and synthetic tests, no signing credentials are needed:

```sh
swift build --package-path native
swift test --package-path native
```

Creating an installable bundle with `build-native.sh` requires a local signing identity.
Set `MENUSPRITE_SIGNING_IDENTITY` to your own certificate. The experimental privileged
helper and official release tooling deliberately require the maintainer's team; do not
weaken those checks. Keep live-account test flags unset during ordinary test runs.

See [native setup](native/README.md) for signing and reproducible checks, and
[monitoring validation](docs/monitoring-validation.md) for current checks/resources.
[Foundation validation](docs/native-validation.md) retains the earlier baseline.

## Landing page

```sh
npm run dev     # http://127.0.0.1:4317
npm run check   # JavaScript syntax checks
npm run build   # static site in dist/
```

No package installation is required. The website uses static HTML, CSS, and
JavaScript, with self-hosted Manrope. Vercel configuration is in `vercel.json`.
Changes to `brand/` should be reflected in the downloadable pack and site assets.
Deployment details and verification are in `docs/deployment.md`.
