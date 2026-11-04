#!/bin/sh
# Lays out a read-write DMG's Finder window (background, icon positions, window size) and sets
# the custom volume icon.
# Usage: scripts/layout-dmg.sh <rw.dmg> <volume name> <app name> <volume icon .icns>
# Uses Finder via AppleScript (macOS may ask once to allow controlling Finder).
set -eu
DMG="$1"
VOL="$2"
APP="$3"
VOLUME_ICON="$4"

DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG" | awk '/Apple_HFS/ {print $1}')
MOUNT="/Volumes/$VOL"
trap 'hdiutil detach "$DEVICE" -quiet || hdiutil detach "$DEVICE" -force -quiet' EXIT

# Window: 660x400 content (+28 pt title bar), icons at the spots the background leaves clear.
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 548}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "$APP.app" of container window to {165, 190}
        set position of item "Applications" of container window to {495, 190}
        close
        open
        update without registering applications
        delay 2
        close
    end tell
end tell
EOF

# Let Finder flush .DS_Store before touching the volume again.
sleep 2

# Custom volume icon: applied AFTER the Finder step, because Finder's layout pass removes
# .VolumeIcon.icns and clears the "has custom icon" flag.
cp "$VOLUME_ICON" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"
sync
chmod -Rf go-w "$MOUNT" || true
