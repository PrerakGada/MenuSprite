#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
native_root="$repo_root/native"
build_root="$native_root/.build"
public_preview=false
if [[ "${1:-}" == "--public-preview" ]]; then
    public_preview=true
    build_root="$native_root/.build/public-preview"
fi
app_path="$build_root/MenuSprite.app"
# Keep a consistent designated requirement between local builds. Never silently fall back to ad hoc signing.
if $public_preview; then
    signing_identity="${MENUSPRITE_SIGNING_IDENTITY:-Developer ID Application: MIND WEALTH (RC63N3VU27)}"
else
    signing_identity="${MENUSPRITE_SIGNING_IDENTITY:-Apple Development: Prerak Gada (X38RF8Q3T4)}"
fi

if ! security find-identity -v -p codesigning | /usr/bin/grep -Fq "$signing_identity"; then
    echo "Signing identity unavailable: $signing_identity" >&2
    echo "Set MENUSPRITE_SIGNING_IDENTITY explicitly to an appropriate local identity. Grant continuity must be revalidated if it changes." >&2
    exit 1
fi

swift_args=(--package-path "$native_root" -c release)
product_args=()
if $public_preview; then
    swift_args+=(--scratch-path "$build_root/swift" --arch arm64 -Xswiftc -DMENUSPRITE_PUBLIC_PREVIEW)
    product_args=(--product MenuSprite)
    # The public staging bundle must never inherit a developer helper/installer.
    rm -rf "$app_path"
fi
swift build "${swift_args[@]}" ${product_args[@]+"${product_args[@]}"}
# The Now Playing adapter is a separate library that /usr/bin/perl loads at run time; the app never links it.
swift build "${swift_args[@]}" --product NowPlayingBridge
binary_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Frameworks" "$build_root/AppIcon.iconset"
cp "$binary_dir/MenuSprite" "$app_path/Contents/MacOS/MenuSprite"
cp "$binary_dir/libNowPlayingBridge.dylib" "$app_path/Contents/Frameworks/libNowPlayingBridge.dylib"
cp "$native_root/Resources/Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_root/LICENSE" "$app_path/Contents/Resources/LICENSE.txt"
if $public_preview; then
    python3 - "$repo_root/distribution/version.json" "$app_path/Contents/Info.plist" <<'PY'
import json, plistlib, sys
version = json.load(open(sys.argv[1]))
info = plistlib.load(open(sys.argv[2], 'rb'))
assert info['CFBundleShortVersionString'] == version['version'] and info['CFBundleVersion'] == version['build'], 'Release manifest and app version disagree'
PY
    /usr/libexec/PlistBuddy -c 'Add :MenuSpriteReleaseChannel string public-preview' "$app_path/Contents/Info.plist"
fi
artwork="$repo_root/brand/variants/menusprite-icon-light.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$artwork" --out "$build_root/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$artwork" --out "$build_root/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$build_root/AppIcon.iconset" -o "$app_path/Contents/Resources/AppIcon.icns"
sips -z 112 112 "$artwork" --out "$app_path/Contents/Resources/BrandIcon.png" >/dev/null
# The menu bar uses the isolated sprite/rail artwork, not the opaque app-icon tile.
sips -Z 96 "$native_root/Resources/MenuBarArtwork.png" --out "$app_path/Contents/Resources/MenuBarIcon.png" >/dev/null
# The other menu-bar icons a person can pick (docs/menu-bar-icon.md), already cut and sized.
rm -rf "$app_path/Contents/Resources/MenuBarIcons"
cp -R "$native_root/Resources/MenuBarIcons" "$app_path/Contents/Resources/MenuBarIcons"
bridge_path="$app_path/Contents/Frameworks/libNowPlayingBridge.dylib"
if $public_preview; then
    codesign --force --options runtime --timestamp --identifier in.prerakgada.MenuSprite.now-playing --sign "$signing_identity" "$bridge_path"
    codesign --force --options runtime --timestamp --sign "$signing_identity" \
        --entitlements "$native_root/Resources/MenuSprite.entitlements" "$app_path"
else
    cp "$binary_dir/MenuSpritePowerHelper" "$app_path/Contents/Resources/MenuSpritePowerHelper"
    cp "$native_root/Resources/"*power-helper.sh "$app_path/Contents/Resources/"
    codesign --force --options runtime --timestamp=none --identifier in.prerakgada.MenuSprite.PowerHelper --sign "$signing_identity" "$app_path/Contents/Resources/MenuSpritePowerHelper"
    codesign --force --options runtime --timestamp=none --identifier in.prerakgada.MenuSprite.now-playing --sign "$signing_identity" "$bridge_path"
    codesign --force --options runtime --timestamp=none --sign "$signing_identity" \
        --entitlements "$native_root/Resources/MenuSprite.entitlements" "$app_path"
fi
codesign --verify --strict --verbose=2 "$app_path"
plutil -lint "$app_path/Contents/Info.plist"
echo "Built $app_path"

if [[ "${1:-}" == "--install" ]]; then
    install_path="$HOME/Applications/MenuSprite.app"
    if pgrep -f "^$install_path/Contents/MacOS/MenuSprite( |$)" >/dev/null; then
        echo "Quit MenuSprite before replacing its installed bundle, then rerun this command." >&2
        exit 1
    fi
    if [[ -d "$install_path" ]]; then
        old_requirement="$(codesign -d -r- "$install_path" 2>&1 | /usr/bin/grep '^designated =>')"
        new_requirement="$(codesign -d -r- "$app_path" 2>&1 | /usr/bin/grep '^designated =>')"
        if [[ "$old_requirement" != "$new_requirement" ]]; then
            echo "Refusing to replace a build with a different signing requirement. Review the identity change first." >&2
            exit 1
        fi
        mkdir -p "$build_root/previous-install"
        ditto "$install_path" "$build_root/previous-install/MenuSprite.app"
    fi
    mkdir -p "$HOME/Applications"
    ditto "$app_path" "$install_path"
    codesign --verify --strict --verbose=2 "$install_path"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$install_path"
    echo "Installed $install_path"
    echo "Launch: open '$install_path'"
fi
