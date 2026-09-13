#!/bin/bash
# Run interactively. Notarytool prompts for Apple ID / app-specific password;
# credentials go to Keychain and are never written to this repository.
set -euo pipefail
exec xcrun notarytool store-credentials menusprite-notary --team-id RC63N3VU27
