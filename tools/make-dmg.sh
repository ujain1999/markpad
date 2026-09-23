#!/bin/sh
# make-dmg.sh — package build/Markpad.app as a drag-to-install disk image.
#
# Run ./build.sh first. The version comes from the built app, so the image is
# named after whatever was actually built.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/Markpad.app"
VOLUME="Markpad"

if [ ! -d "$APP" ]; then
    printf 'make-dmg: no build at %s — run ./build.sh first\n' "$APP" >&2
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$ROOT/dist/Markpad-$VERSION.dmg"
STAGE=$(mktemp -d)/"$VOLUME"
RW="$ROOT/dist/rw.dmg"
MOUNT=""

cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -force -quiet 2>/dev/null
    rm -rf "$(dirname "$STAGE")" "$RW"
}
trap cleanup EXIT

mkdir -p "$STAGE" "$ROOT/dist"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG" "$RW"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
# Take the mount point from hdiutil rather than assuming it: if a volume of
# the same name is already mounted, this one lands on "/Volumes/Markpad 1".
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)
if [ -z "$MOUNT" ]; then
    printf 'make-dmg: could not mount the staging image\n' >&2
    exit 1
fi
VOLUME_NAME=$(basename "$MOUNT")

# Lay the window out so the app sits beside the Applications alias. Cosmetic;
# the image is perfectly usable if Finder refuses to co-operate.
osascript >/dev/null 2>&1 <<APPLESCRIPT || printf 'make-dmg: skipped window layout\n' >&2
tell application "Finder"
	tell disk "$VOLUME_NAME"
		open
		delay 1
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {300, 150, 900, 560}
		set opts to the icon view options of container window
		set arrangement of opts to not arranged
		set icon size of opts to 128
		set text size of opts to 13
		set position of item "Markpad.app" of container window to {150, 200}
		set position of item "Applications" of container window to {450, 200}
		update without registering applications
		delay 1
		close
	end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

printf '%s\n' "$DMG"
shasum -a 256 "$DMG"
