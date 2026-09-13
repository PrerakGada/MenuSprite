# Security and privacy

Do not include tokens, keychain exports, account lists, real work databases, session
logs or unreviewed screenshots in issues. Review diagnostics locally before sharing.
For sensitive reports, contact the maintainer privately through the contact options
on [the maintainer's website](https://prerakgada.in/). Public issues are appropriate
only for reports that contain no private data or exploitable vulnerability details.

MenuSprite has no backend or telemetry. Optional AI usage tools contact the relevant
provider with the user's CLI credentials and can refresh or switch those credentials.
Spend estimates read local session logs only after being enabled. The experimental
Work & Clients report reads a user-selected local database. These records do not
belong in the source repository.

The privileged power helper is experimental and excluded from public preview bundles.
It requires administrator installation and a matching signed app; hardware acceptance
remains pending. Do not weaken its signing requirements to get a development build working.

Before committing or publishing, run the [source audit](docs/open-source-readiness.md).
A clean scan is evidence within its coverage, not a guarantee of absence of vulnerabilities.
