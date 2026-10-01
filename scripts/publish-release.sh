#!/bin/bash
# Explicit publication command. It refuses an unnotarized or untested archive.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release_tag"])' "$repo_root/distribution/version.json")"
title="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["release_title"])' "$repo_root/distribution/version.json")"
release_root="$repo_root/native/.build/distribution/$tag"
asset_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive_asset"])' "$repo_root/distribution/version.json")"
asset="$release_root/$asset_name"
dmg_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dmg_asset"])' "$repo_root/distribution/version.json")"
dmg="$release_root/$dmg_name"
release_repo='PrerakGada/menusprite-releases'
tap_repo='PrerakGada/homebrew-tap'
[[ -f "$asset" ]] || { echo 'Run package-release.sh with notarization credentials first.' >&2; exit 1; }
[[ -f "$dmg" && -f "$dmg.sha256" ]] || { echo 'The notarized drag-to-Applications DMG is required.' >&2; exit 1; }
codesign --verify --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "RC63N3VU27" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(cd "$release_root" && shasum -a 256 --check "$(basename "$dmg").sha256")
python3 - "$release_root/notarization.json" "$release_root/validation-public/report.json" <<'PY'
import json, sys
assert json.load(open(sys.argv[1])).get('status') == 'Accepted', 'Apple has not accepted this submission'
report=json.load(open(sys.argv[2]))
assert report['checks'] and all(c['passed'] for c in report['checks']), 'Native public-build checks have not all passed'
PY
verify_root="$(mktemp -d "$release_root/verify.XXXXXX")"
trap 'rm -rf "$verify_root"' EXIT
ditto -x -k "$asset" "$verify_root"
app="$verify_root/MenuSprite.app"
python3 - "$app" "$repo_root/distribution/version.json" "$release_root/validation-public/report.json" <<'PY'
import json, plistlib, hashlib, pathlib, sys
app=pathlib.Path(sys.argv[1]); version=json.load(open(sys.argv[2])); report=json.load(open(sys.argv[3]))
info=plistlib.load(open(app/'Contents/Info.plist','rb'))
assert info['CFBundleShortVersionString']==version['version'] and info['CFBundleVersion']==version['build']
assert report['version']==version['version'] and report['build']==version['build']
assert hashlib.sha256((app/'Contents/MacOS/MenuSprite').read_bytes()).hexdigest()==report['executableSHA256'], 'Validation is not for this exact binary'
PY
codesign --verify --strict -R '=anchor apple generic and identifier "in.prerakgada.MenuSprite" and certificate leaf[subject.OU] = "RC63N3VU27" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
"$repo_root/scripts/verify-power-helper.sh" "$app" --developer-id
python3 "$repo_root/scripts/generate-homebrew-cask.py" "$asset" "$release_root/menusprite.rb"
# This clone contains only public distribution metadata, never the source checkout.
if ! gh repo view "$release_repo" --json name >/dev/null 2>&1; then
    gh repo create "$release_repo" --public --description 'MenuSprite macOS public-preview downloads'
fi
metadata="$release_root/download-repository"
[[ -d "$metadata/.git" ]] || gh repo clone "$release_repo" "$metadata"
[[ -z "$(git -C "$metadata" status --porcelain)" ]] || { echo 'Download checkout has pending changes; review it first.' >&2; exit 1; }
cp "$repo_root/distribution/README.md" "$metadata/README.md"
cp "$repo_root/distribution/version.json" "$metadata/version.json"
git -C "$metadata" add README.md version.json
if ! git -C "$metadata" diff --cached --quiet; then
    git -C "$metadata" -c user.email=58708396+PrerakGada@users.noreply.github.com commit -m 'Document MenuSprite public preview downloads'
fi
git -C "$metadata" push -u origin HEAD:main
if ! gh release view "$tag" --repo "$release_repo" >/dev/null 2>&1; then
    gh release create "$tag" "$asset" "$asset.sha256" "$dmg" "$dmg.sha256" --repo "$release_repo" --target main --draft --prerelease \
        --title "$title" --notes-file "$repo_root/distribution/release-notes.md"
else
    echo 'Release tag already exists. Inspect it before retrying; artifacts are immutable.' >&2; exit 1
fi
gh release edit "$tag" --repo "$release_repo" --draft=false --prerelease
# Publish the tap only after the exact release archive is publicly downloadable.
curl --fail --location --silent --show-error "https://github.com/$release_repo/releases/download/$tag/$(basename "$asset")" -o "$verify_root/download.zip"
[[ "$(shasum -a 256 "$asset" | cut -d ' ' -f1)" == "$(shasum -a 256 "$verify_root/download.zip" | cut -d ' ' -f1)" ]] || { echo 'Public download checksum mismatch.' >&2; exit 1; }
tap="$release_root/publish-tap"
[[ -d "$tap/.git" ]] || gh repo clone "$tap_repo" "$tap"
[[ -z "$(git -C "$tap" status --porcelain)" ]] || { echo 'Tap checkout has pending changes; review it first.' >&2; exit 1; }
git -C "$tap" pull --ff-only
cp "$release_root/menusprite.rb" "$tap/Casks/menusprite.rb"
python3 - "$tap" "$repo_root/distribution/version.json" <<'PYTHON'
import json,sys
from pathlib import Path
path=Path(sys.argv[1])/'audit_exceptions/github_prerelease_allowlist.json'
values=json.loads(path.read_text()) if path.exists() else {}
values['menusprite']=json.load(open(sys.argv[2]))['homebrew_version']
path.parent.mkdir(parents=True,exist_ok=True)
path.write_text(json.dumps(values,indent=2,sort_keys=True)+'\n')
PYTHON
HOMEBREW_NO_AUTO_UPDATE=1 brew style "$tap/Casks/menusprite.rb"
git -C "$tap" add Casks/menusprite.rb audit_exceptions/github_prerelease_allowlist.json
git -C "$tap" -c user.email=58708396+PrerakGada@users.noreply.github.com commit -m "Update MenuSprite to $tag"
git -C "$tap" push origin HEAD:main
echo 'Published: brew install --cask prerakgada/tap/menusprite'
echo 'Complete a real Homebrew install, quarantine/Gatekeeper assessment and launch check next.'
