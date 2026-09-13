# Landing page deployment

The public site is https://menusprite.prerakgada.in/.
It is a static site built into `dist/` by `npm run build`, with no runtime dependencies.

## Build and preview

```sh
npm run check
npm run build
npm run dev
```

`vercel.json` defines hosting and security headers. `.vercelignore` includes only
website files and build inputs, excluding native code, private notes and credentials.
Link your own Vercel project interactively with `vercel link`, then deploy with
`vercel deploy`. Use `vercel deploy --prod` only when ready to update your production site.
The generated `.vercel/` project linkage stays local and is ignored by Git.
No environment variables or authentication tokens belong in the website.

## Verify an update

Check the canonical HTTPS URL, internal anchors, downloaded artwork, DMG and release-note
links. Confirm the release tag and filenames against `distribution/version.json` and
verify each release checksum. Keep account dashboards, DNS record IDs, deployment IDs,
rollback URLs and deployment logs in private operational notes.
