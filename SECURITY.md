# Security and privacy

Do not include tokens, keychain exports, account lists, real work databases, session
logs or unreviewed screenshots in issues. Review diagnostics locally before sharing.
For sensitive reports, contact the maintainer privately through the contact options
on [the maintainer's website](https://prerakgada.in/). Public issues are appropriate
only for reports that contain no private data or exploitable vulnerability details.

MenuSprite has no account, analytics or telemetry. It sends something of its own only when
you press **Send** in **Report a Problem…** or **Send Feedback…** (hub → Tools): your message,
the name and email you chose to add, and the app version, build, macOS version and Mac model,
to the maintainer's feedback endpoint at `api.prerakgada.in`. Nothing is sent at launch or in
the background, and the app does not keep the name or email.
The server notes a rough location (country, region and city) from your connection and stores no IP address. Optional AI usage tools contact the relevant
provider with the user's CLI credentials and can refresh or switch those credentials.
Spend estimates read local session logs only after being enabled. The experimental
Work & Clients report reads a user-selected local database. These records do not
belong in the source repository.

The power helper ships inside the app (since 0.5.8) as a launchd daemon that stays off until
the user chooses Turn on power controls and allows it in System Settings. It accepts only a
matching signed app. Do not weaken its signing requirements to get a development build working.

Before committing or publishing, run the [source audit](docs/open-source-readiness.md).
A clean scan is evidence within its coverage, not a guarantee of absence of vulnerabilities.
