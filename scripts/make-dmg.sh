#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Orilio — a calm control surface for the Mac notch.
# Copyright (C) 2026 Enbiya Goral and Orilio contributors

# Packs build/Orilio.app into build/Orilio-<version>.dmg with the M5 Icon design's window: 600 × 400,
# the dark background with a dashed arrow, the app on the left and Applications on the right.
# Usage: scripts/make-dmg.sh            (run scripts/make-app.sh release first)
#        ORILIO_DMG_NO_LAYOUT=1 scripts/make-dmg.sh   (skip the Finder layout step, e.g. without a GUI session)
# Only built-in tools: hdiutil, tiffutil, osascript (Finder).
set -eu
cd "$(dirname "$0")/.."

APP="build/Orilio.app"
[ -d "$APP" ] || { echo "Not found: $APP (run scripts/make-app.sh release first)" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="build/Orilio-$VERSION.dmg"
STAGE="$(mktemp -d)"
RW="build/Orilio-rw.dmg"
trap 'rm -rf "$STAGE" "$RW"' EXIT

# TODO(release): sign the app with the Developer ID first:
#   codesign --force --deep --options runtime --timestamp --sign "Developer ID Application: …" "$APP"

ditto "$APP" "$STAGE/Orilio.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
# One TIFF with both resolutions, so Finder picks the sharp one on Retina displays.
tiffutil -cathidpicheck Resources/DMG/background.png Resources/DMG/background@2x.png -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

rm -f "$RW" "$OUT"
hdiutil create -quiet -volname "Orilio" -srcfolder "$STAGE" -fs HFS+ -format UDRW -size 200m "$RW"

if [ -z "${ORILIO_DMG_NO_LAYOUT:-}" ]; then
  MOUNT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\// {print $NF}')"
  # Finder lays out the window: icon view, no toolbar, 96 pt icons at the design's positions.
  osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$(basename "$MOUNT")"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 548}
    set options to the icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to 96
    set text size of options to 13
    set background picture of options to file ".background:background.tiff"
    set position of item "Orilio.app" of container window to {160, 190}
    set position of item "Applications" of container window to {440, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
  sync
  hdiutil detach -quiet "$MOUNT"
fi

hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"

# TODO(release): sign, notarize and staple the disk image:
#   codesign --sign "Developer ID Application: …" --timestamp "$OUT"
#   xcrun notarytool submit "$OUT" --keychain-profile "orilio-notary" --wait
#   xcrun stapler staple "$OUT"
echo "Built $OUT"
