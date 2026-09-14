# Source publication audit — 14 September 2026

The source has been prepared for publication. **The owner selected [MIT](../LICENSE)
on 14 September 2026; the source repository has not yet been published**. The existing
[website](https://menusprite.prerakgada.in/) and
[GitHub release repository](https://github.com/PrerakGada/menusprite-releases)
distribute preview binaries. Describe the project as planned open source until
the licensed source is publicly available.

## Cleanup

- Private agent instructions and session records remain local and are ignored.
  Agent files and operational deployment records were removed from both existing
  source commits. Current public documentation omits account identities, personal
  usage/spend totals, private work history and hosting identifiers.
- Examples use synthetic projects and `example.com` accounts. The work validator
  selects a project from its supplied data instead of requiring a particular client.
- Source commit identities use GitHub no-reply attribution. The six public release
  commits and three MenuSprite commits in the shared Homebrew tap were corrected
  too. Every public file tree and release asset was preserved. Earlier unrelated
  tap commits and its existing unrelated tag retain their original objects.
- Git ignores credentials, signing keys, account files, local databases, diagnostics,
  native build products and installer outputs. Source publication checks run before
  local commits/pushes and are configured for GitHub Actions.
- Large credential writes now use the macOS Security framework instead of process
  arguments. Short writes use stdin; write errors never surface tool stderr.
  Existing access lists are retained. Provider requests refuse redirects so bearer
  tokens and refresh bodies cannot be forwarded by a redirect.

Original records and pre-rewrite repositories were backed up outside the source
checkout with restricted permissions. Do not publish those backups. Updating Git
refs cannot erase earlier clones or cached commits: see
[GitHub's history-removal guidance](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository).
No credential rotation was indicated by the scans; the identified historical
exposure was private context and author-email metadata, not detected live keys.

## Verification

- Gitleaks 8.30.1, verified against its release checksum: no detected secrets in
  the source candidate, all source refs, public release history, downloaded ZIPs,
  extracted bundles or binary strings. Archive contents were included where supported.
- Publication guard checks exact staged content, private paths, non-example emails,
  personal home paths, hosting IDs, nested ZIPs and all reachable historical blobs.
  Five positive/negative checks verify it catches private staged files, a clean
  working copy hiding private staged content, nested private files and removed history.
- The 153-test native suite compiled and passed on the build Mac. The credential integration test
  uses a disposable keychain and synthetic values, verifies large creation/update,
  CLI readability, short writes and deletion. Live account switches and usage/spend
  scans are not part of this audit.
- Both public ZIP signatures validate, and their binary strings contain no detected
  email addresses or personal home paths. All six published installer/archive files
  match their paired SHA-256 checksums. All four DMGs contain the exact signed
  executable from the matching ZIP and only the app and expected installer assets.
  Eighty-eight external URLs and 81 local documentation links were checked; a URL
  extractor's truncated Apple method link was reviewed separately. Fifteen live
  website/download/metadata URLs returned HTTP 200 after rewriting Git refs.
- Website syntax checks and the static build passed on the build Mac. Python
  parsing and shell syntax checks passed for the repository scripts.
- The bundled Manrope license is intact. The Swift manifest has no external package
  dependencies and the site has no runtime npm dependencies. Optional packaging tools
  and generated artwork are recorded in [third-party notices](../THIRD_PARTY_NOTICES.md).

This is a publication/privacy audit with targeted credential hardening, not a
penetration test or legal clearance of all intellectual-property rights. The
installed app and public 0.5.5 binaries have not been replaced by this source change;
the credential hardening needs inclusion in a subsequent signed release.

## Repeat before publishing

Install [Gitleaks](https://github.com/gitleaks/gitleaks) (8.30.1 or newer), then:

```sh
python3 scripts/audit-source.py --history
git config core.hooksPath .githooks
```

If Gitleaks is outside `PATH`, set `GITLEAKS_BIN`, or configure its absolute path
with `git config menusprite.gitleaksPath /absolute/path/to/gitleaks`.
The check fails if the scanner is unavailable. The commit hook scans the exact
index; the push hook scans the index and all refs. Use no-reply commit attribution
and synthetic fixtures. Review new binary assets manually; scans are not a substitute
for that review. Do not bypass a failed check to publish.

The MIT license covers MenuSprite's own code, documentation and project artwork;
third-party components retain their own notices. The brand pack includes the license,
and new native bundles will include it in `Contents/Resources/LICENSE.txt`.
Before the first public source push, publish the audited Git repository to a dedicated source remote.
Keep existing installer URLs and the binary release repository working. A source
license is a separate decision from making downloads free.
