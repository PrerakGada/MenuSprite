#!/bin/bash
set -euo pipefail
service='in.prerakgada.MenuSprite.PowerHelper'
installed="/Library/PrivilegedHelperTools/$service"
if [[ "$EUID" -ne 0 ]]; then echo 'Run with sudo after stopping controls and quitting MenuSprite.' >&2; exit 1; fi
if /usr/bin/pgrep -f '/MenuSprite.app/Contents/MacOS/MenuSprite' >/dev/null; then echo 'Quit MenuSprite before uninstalling its helper.' >&2; exit 1; fi
if [[ -f "$installed" ]]; then
    /usr/bin/codesign --verify --strict -R '=anchor apple generic and identifier "in.prerakgada.MenuSprite.PowerHelper" and certificate leaf[subject.OU] = "RC63N3VU27"' "$installed"
    /bin/launchctl bootout "system/$service" 2>/dev/null || true
    "$installed" --restore
    /bin/rm "$installed"
fi
/bin/rm -f "/Library/LaunchDaemons/$service.plist"
echo 'Helper removed. Recovery journal retained for review.'
