#!/bin/bash
set -euo pipefail
[[ $# -eq 1 && "$1" == *.dmg && -f "$1" ]] || { echo 'Usage: notarize-dmg.sh /path/release.dmg' >&2; exit 1; }
: "${MENUSPRITE_NOTARY_PROFILE:?Set MENUSPRITE_NOTARY_PROFILE to your Keychain profile}"
asset="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
codesign --verify --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "RC63N3VU27" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$asset"
xcrun notarytool submit "$asset" --keychain-profile "$MENUSPRITE_NOTARY_PROFILE" --wait --timeout 20m --output-format json > "$asset.notarization.json"
python3 - "$asset.notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not Accepted; do not publish this DMG.')
print('Disk image notarization accepted:', result['id'])
PY
xcrun stapler staple "$asset"
xcrun stapler validate "$asset"
spctl --assess --type open --context context:primary-signature --verbose=2 "$asset"
(cd "$(dirname "$asset")" && shasum -a 256 "$(basename "$asset")" > "$asset.sha256")
echo "Notarized DMG and checksum ready: $asset"
