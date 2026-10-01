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
    # The public staging bundle is assembled from scratch every time.
    rm -rf "$app_path"
fi
# The power helper once lived in Resources beside Terminal install scripts; it now ships as a
# launchd daemon the app registers through SMAppService (docs/power-controls.md).
rm -f "$app_path/Contents/Resources/MenuSpritePowerHelper" "$app_path/Contents/Resources/"*power-helper.sh
swift build "${swift_args[@]}" ${product_args[@]+"${product_args[@]}"}
# The Now Playing adapter is a separate library that /usr/bin/perl loads at run time; the app never links it.
swift build "${swift_args[@]}" --product NowPlayingBridge
# The menusprite command agents use (docs/agent-authoring.md). Built as MenuSpriteCLI because the bin folder is
# case-insensitive and already holds MenuSprite; it ships as Contents/Helpers/menusprite.
swift build "${swift_args[@]}" --product MenuSpriteCLI
# The root power helper (charge limit, fans, closed lid). launchd runs it from inside the bundle:
# Contents/Library/LaunchDaemons names it with BundleProgram, and the app registers it on request.
swift build "${swift_args[@]}" --product MenuSpritePowerHelper
binary_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Frameworks" "$app_path/Contents/Helpers" "$app_path/Contents/Library/LaunchDaemons" "$build_root/AppIcon.iconset"
cp "$binary_dir/MenuSprite" "$app_path/Contents/MacOS/MenuSprite"
helper_path="$app_path/Contents/MacOS/MenuSpritePowerHelper"
cp "$binary_dir/MenuSpritePowerHelper" "$helper_path"
cp "$native_root/Resources/LaunchDaemons/in.prerakgada.MenuSprite.PowerDaemon.plist" "$app_path/Contents/Library/LaunchDaemons/"
cli_path="$app_path/Contents/Helpers/menusprite"
cp "$binary_dir/MenuSpriteCLI" "$cli_path"
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
    codesign --force --options runtime --timestamp --identifier in.prerakgada.MenuSprite.cli --sign "$signing_identity" "$cli_path"
    codesign --force --options runtime --timestamp --identifier in.prerakgada.MenuSprite.PowerHelper --sign "$signing_identity" "$helper_path"
    codesign --force --options runtime --timestamp --sign "$signing_identity" \
        --entitlements "$native_root/Resources/MenuSprite.entitlements" "$app_path"
else
    codesign --force --options runtime --timestamp=none --identifier in.prerakgada.MenuSprite.PowerHelper --sign "$signing_identity" "$helper_path"
    codesign --force --options runtime --timestamp=none --identifier in.prerakgada.MenuSprite.now-playing --sign "$signing_identity" "$bridge_path"
    codesign --force --options runtime --timestamp=none --identifier in.prerakgada.MenuSprite.cli --sign "$signing_identity" "$cli_path"
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
    # launchd runs the power helper from inside this bundle; overwriting its executable mid-run would
    # kill it without restoring. It hands back and exits about ten seconds after MenuSprite quits.
    bundled_helper="^$install_path/Contents/MacOS/MenuSpritePowerHelper( |$)"
    for _ in {1..30}; do pgrep -f "$bundled_helper" >/dev/null || break; sleep 1; done
    if pgrep -f "$bundled_helper" >/dev/null; then
        echo "MenuSprite's power helper is still running (a control may be active). Quit MenuSprite, wait a few seconds, then rerun." >&2
        exit 1
    fi
    if [[ -d "$install_path" ]]; then
        old_requirement="$(codesign -d -r- "$install_path" 2>&1 | /usr/bin/grep '^designated =>')"
        new_requirement="$(codesign -d -r- "$app_path" 2>&1 | /usr/bin/grep '^designated =>')"
        if [[ "$old_requirement" != "$new_requirement" ]]; then
            echo "Refusing to replace a build with a different signing requirement. Review the identity change first." >&2
            exit 1
        fi
        rm -rf "$build_root/previous-install/MenuSprite.app"
        mkdir -p "$build_root/previous-install"
        ditto "$install_path" "$build_root/previous-install/MenuSprite.app"
    fi
    mkdir -p "$HOME/Applications"
    # Replace, never merge: ditto into an existing bundle keeps files a newer build no longer has, and a
    # leftover breaks the seal (the old Terminal helper scripts did, 1 Oct). The previous copy is backed up above.
    rm -rf "$install_path"
    ditto "$app_path" "$install_path"
    codesign --verify --strict --verbose=2 "$install_path"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$install_path"
    echo "Installed $install_path"
    # Shells and agents find the command at ~/.local/bin/menusprite. Only a link is ever replaced there: a real
    # file with that name is someone else's.
    link_path="$HOME/.local/bin/menusprite"
    mkdir -p "$HOME/.local/bin"
    if [[ -L "$link_path" || ! -e "$link_path" ]]; then
        ln -sfn "$install_path/Contents/Helpers/menusprite" "$link_path"
        echo "Linked $link_path"
    else
        echo "Left $link_path alone: it is a file, not a link. Remove it to use the bundled menusprite command." >&2
    fi
    echo "Launch: open '$install_path'"
fi
