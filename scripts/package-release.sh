#!/bin/bash
# Builds a public preview. Publication is a separate, explicit step.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release_tag"])' "$repo_root/distribution/version.json")"
release_root="$repo_root/native/.build/distribution/$tag"
app_path="$repo_root/native/.build/public-preview/MenuSprite.app"
asset_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive_asset"])' "$repo_root/distribution/version.json")"
mkdir -p "$release_root"
"$repo_root/scripts/build-native.sh" --public-preview
/usr/bin/codesign --verify --strict -R '=anchor apple generic and identifier "in.prerakgada.MenuSprite" and certificate leaf[subject.OU] = "RC63N3VU27" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app_path"
"$repo_root/scripts/verify-power-helper.sh" "$app_path" --developer-id
if [[ "$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/MenuSprite")" != 'arm64' ]]; then
    echo 'Release architecture is not the declared arm64 target.' >&2; exit 1
fi
if [[ -z "${MENUSPRITE_NOTARY_PROFILE:-}" ]]; then
    /usr/bin/ditto -c -k --keepParent "$app_path" "$release_root/MenuSprite-notarization-input.zip"
    echo "Signed preview prepared at $app_path"
    echo 'Not published. Set MENUSPRITE_NOTARY_PROFILE and rerun to notarize and package.'
    exit 0
fi
/usr/bin/ditto -c -k --keepParent "$app_path" "$release_root/MenuSprite-notarization-input.zip"
xcrun notarytool submit "$release_root/MenuSprite-notarization-input.zip" --keychain-profile "$MENUSPRITE_NOTARY_PROFILE" --wait --timeout 20m --output-format json > "$release_root/notarization.json"
python3 - "$release_root/notarization.json" <<'PY'
import json, sys
result=json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not Accepted. See the local notarization report; do not publish.')
print('Notarization accepted:',result['id'])
PY
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
/usr/sbin/spctl --assess --type execute --verbose=2 "$app_path"
/usr/bin/ditto -c -k --keepParent "$app_path" "$release_root/$asset_name"
(cd "$release_root" && /usr/bin/shasum -a 256 "$asset_name" > "$asset_name.sha256")
echo "Notarized release asset: $release_root/$asset_name"
dmg_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dmg_asset"])' "$repo_root/distribution/version.json")"
dmg_path="$release_root/$dmg_name"
"$repo_root/scripts/build-dmg.sh" "$app_path" "$dmg_path"
"$repo_root/scripts/notarize-dmg.sh" "$dmg_path"
