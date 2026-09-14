# Third-party components and artwork

| Component | Use | License or provenance |
| --- | --- | --- |
| Manrope | Self-hosted website font | SIL Open Font License 1.1; the complete upstream notice is preserved in [OFL.txt](site/assets/fonts/OFL.txt). |
| Apple frameworks and SF Symbols | Native app, system-provided APIs and symbols | Provided by the macOS SDK/runtime; not relicensed by this repository. |
| SQLite | Native Work & Clients database reader | Linked from macOS's system library; no SQLite source is vendored. |
| dmgbuild 1.6.7, ds_store 1.3.3, mac_alias 2.2.3 | Optional installer packaging tools | Installed separately using `scripts/dmg-requirements.txt`; no package code is vendored. Retain upstream licenses if redistributing these tools. |
| MenuSprite raster artwork | Brand, website and app assets | Generated artwork selected for MenuSprite; provenance and variants are described in [brand/README.md](brand/README.md). |

`native/Package.swift` declares no external Swift package dependencies. The website
has no npm runtime dependencies. Documentation links to other utilities as research
references; those links are not a license grant to copy their implementations.
Check ownership and the actual license before incorporating any outside code.

MenuSprite's own code, documentation and project artwork are covered by the
[MIT license](LICENSE), selected on 14 September 2026. Third-party components
retain their own licenses and notices as listed above.
