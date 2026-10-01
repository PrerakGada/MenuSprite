#!/bin/bash
# Checks that a MenuSprite.app carries its power helper the way macOS's SMAppService needs it:
# the launchd plist in Contents/Library/LaunchDaemons naming the bundled executable, which is signed by
# the same team with hardened runtime, and no Terminal installers left over from the first builds.
# Usage: verify-power-helper.sh /path/MenuSprite.app [--developer-id]
set -euo pipefail
app="$1"
service='in.prerakgada.MenuSprite.PowerDaemon'
plist="$app/Contents/Library/LaunchDaemons/$service.plist"
helper="$app/Contents/MacOS/MenuSpritePowerHelper"
requirement='anchor apple generic and identifier "in.prerakgada.MenuSprite.PowerHelper" and certificate leaf[subject.OU] = "RC63N3VU27"'
[[ "${2:-}" == '--developer-id' ]] && requirement+=' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
fail() { echo "Power helper check failed: $1" >&2; exit 1; }
[[ -f "$plist" ]] || fail "missing $plist"
[[ -x "$helper" ]] || fail "missing $helper"
/usr/bin/plutil -lint "$plist" >/dev/null || fail 'daemon plist does not parse'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$plist")" == "$service" ]] || fail 'daemon label'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$plist")" == 'Contents/MacOS/MenuSpritePowerHelper' ]] || fail 'BundleProgram'
/usr/libexec/PlistBuddy -c "Print :MachServices:$service" "$plist" >/dev/null || fail 'Mach service'
/usr/bin/codesign --verify --strict -R "=$requirement" "$helper" || fail 'helper signature'
details="$(/usr/bin/codesign -d --verbose=2 "$helper" 2>&1)"
[[ "$details" == *'(runtime)'* ]] || fail 'helper lacks hardened runtime'
[[ "$(/usr/bin/lipo -archs "$helper")" == 'arm64' ]] || fail 'helper architecture'
if [[ -e "$app/Contents/Resources/MenuSpritePowerHelper" ]] || compgen -G "$app/Contents/Resources/*power-helper.sh" >/dev/null; then
    fail 'Terminal installers from the first developer builds are still in the bundle'
fi
echo "Power helper bundled correctly: $helper"
