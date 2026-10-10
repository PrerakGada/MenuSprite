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

## Download form and the Homebrew command (9 October 2026, sign-in removed 10 October)

The page no longer prints the Homebrew command. Both "Install with Homebrew" (hero, beside
Download) and "Get the Homebrew command" (install section, beside the DMG button) are
`<button data-pt-command>` elements owned by the shared download tracker
(`https://api.prerakgada.in/v1/p/tracker.js?v=5`). The tracker opens the download form (typed
name and email, all optional), then shows the command from its script tag's `data-command` with a
Copy button. The form keeps its skip button. There is no Google or Apple sign-in on the form: on
10 October 2026 sign-in was taken off the landing-page download forms (it belongs inside apps that
have a login), and the shared backend serves the tracker with both providers off. The FAQ "Does
this website track me?" says what the form asks.

- The command lives in one place for script: the tracker tag's `data-command`. JavaScript-off
  visitors get a `<noscript>` copy, and the buttons and hint are hidden for them.
- `site/app.js` falls back to showing the command in the install section when the tracker
  never loaded (an extension blocked it, or the API is down) or did not open its dialog within
  600 ms of the click. Installing is never blocked; those installs are simply not collected.
- The FAQ's update line uses the short cask name (`brew upgrade --cask menusprite`), which
  resolves for anyone who installed from the tap.
- The CSP in `vercel.json` needs no change: the tracker's script, stylesheet and requests all go
  to `api.prerakgada.in`.
- **Deploy only after the backend serves the current tracker.** The page uses `?v=5`. Older
  query strings are stale at Cloudflare (`?v=3` holds the old v2 file, `?v=4` still shows
  "Continue with Apple" for hours). Never request a tracker version through `api.prerakgada.in`
  before it is deployed (Cloudflare would cache the old file under it for hours):

```sh
curl -s 'https://api.prerakgada.in/v1/p/tracker.js?v=5' | grep -c '"apple":false'      # 1
npm run check && npm run build && vercel deploy --prod --scope engaze
curl -s https://menusprite.prerakgada.in/ | grep -c 'tracker.js?v=5'      # 1
curl -s https://menusprite.prerakgada.in/ | grep -c 'data-pt-command'     # 3 (two buttons + the noscript style)
```

Deployed to production on 10 October 2026 with the `?v=4` tracker tag, then redeployed the same
day with `?v=5` and the sign-in wording removed.

The install command is still public in the repository README, `distribution/` and the GitHub
release notes; the gate covers the website only.
