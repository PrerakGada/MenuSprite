#!/bin/bash
# Wrap an already-notarized app; never rebuild or re-sign its contents.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -eq 2 ]] || { echo 'Usage: build-dmg.sh /path/MenuSprite.app /path/output.dmg' >&2; exit 1; }
app_path="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
output="$2"
[[ "$app_path" == */MenuSprite.app && "$output" == *.dmg && ! -e "$output" ]] || { echo 'Expected MenuSprite.app and a new .dmg output path.' >&2; exit 1; }
codesign --verify --strict -R '=anchor apple generic and identifier "in.prerakgada.MenuSprite" and certificate leaf[subject.OU] = "RC63N3VU27" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app_path"
xcrun stapler validate "$app_path"
"$repo_root/scripts/verify-power-helper.sh" "$app_path" --developer-id
[[ "$(lipo -archs "$app_path/Contents/MacOS/MenuSprite")" == 'arm64' ]] || { echo 'The public preview requires arm64.' >&2; exit 1; }
tool_root="$repo_root/native/.build/dmg-tools"
if [[ ! -x "$tool_root/bin/dmgbuild" ]]; then
    python3 -m venv "$tool_root"
    "$tool_root/bin/python" -m pip install -r "$repo_root/scripts/dmg-requirements.txt"
fi
mkdir -p "$(dirname "$output")"
art_root="$(mktemp -d "$repo_root/native/.build/dmg-art.XXXXXX")"
trap 'rm -rf "$art_root"' EXIT
xcrun swift "$repo_root/scripts/draw-dmg-background.swift" "$art_root/background.tiff"
"$tool_root/bin/dmgbuild" -s "$repo_root/scripts/dmg-settings.py" \
    -D "app=$app_path" -D "background=$art_root/background.tiff" 'MenuSprite' "$output"
codesign --sign 'Developer ID Application: MIND WEALTH (RC63N3VU27)' --timestamp --identifier in.prerakgada.MenuSprite.diskimage "$output"
codesign --verify --strict "$output"
hdiutil verify "$output"
echo "Signed disk image prepared: $output"
echo 'Review the Finder layout, then run scripts/notarize-dmg.sh before publishing.'
