# MenuSprite

A native macOS menu bar playground in the making.

Landing page: https://menusprite.prerakgada.in/

- `brand/`: Slim rail / Arranger identity, variants, manifest, and references.
- `site/`: public landing page and interactive browser concept with example data.
- `docs/product-brief.md`: agreed scope and what is implemented versus planned.

The native app is not scaffolded yet. Website work does not choose its architecture.

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
