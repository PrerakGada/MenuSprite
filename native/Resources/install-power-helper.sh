#!/bin/bash
# Local development installer: fixed app-owned paths, no sudoers edits.
set -euo pipefail
service='in.prerakgada.MenuSprite.PowerHelper'
requirement='anchor apple generic and identifier "in.prerakgada.MenuSprite.PowerHelper" and certificate leaf[subject.OU] = "RC63N3VU27"'
if [[ "$EUID" -ne 0 ]]; then
    echo 'Run with sudo. Installing the power helper requires administrator authorization.' >&2
    exit 1
fi
source_dir="$(cd "$(dirname "$0")" && pwd)"
installed="/Library/PrivilegedHelperTools/$service"
plist="/Library/LaunchDaemons/$service.plist"
# Never install or execute unverified helper code, including during upgrades.
/usr/bin/codesign --verify --strict -R "=$requirement" "$source_dir/MenuSpritePowerHelper"
if [[ -f "$installed" ]]; then
    /usr/bin/codesign --verify --strict -R "=$requirement" "$installed"
    if /usr/bin/pgrep -f '/MenuSprite.app/Contents/MacOS/MenuSprite' >/dev/null; then
        echo 'Quit MenuSprite before upgrading its helper.' >&2; exit 1
    fi
    /bin/launchctl bootout "system/$service" 2>/dev/null || true
    "$installed" --restore
fi
/usr/bin/install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
stage="$(/usr/bin/mktemp -d /Library/PrivilegedHelperTools/.menusprite.XXXXXX)"
trap '/bin/rm -rf "$stage"' EXIT
/usr/bin/install -m 755 -o root -g wheel "$source_dir/MenuSpritePowerHelper" "$stage/helper"
/usr/bin/codesign --verify --strict -R "=$requirement" "$stage/helper"
/usr/bin/install -d -m 755 -o root -g wheel '/Library/Application Support/MenuSprite'
/bin/mv "$stage/helper" "$installed"
cat > "$stage/service.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$service</string>
<key>ProgramArguments</key><array><string>$installed</string></array>
<key>MachServices</key><dict><key>$service</key><true/></dict>
<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>ThrottleInterval</key><integer>10</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$stage/service.plist"
/usr/bin/install -m 644 -o root -g wheel "$stage/service.plist" "$plist"
/bin/launchctl bootstrap system "$plist"
echo 'MenuSprite power helper installed. Return to Power Controls and click Refresh. No battery or sleep control is enabled by installation.'
