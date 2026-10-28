#!/bin/sh
# Wraps the SwiftPM build into Orilio.app so macOS treats it as a real agent app
# (LSUIElement: no Dock icon; a bundle is also needed for reliable activation and a stable defaults domain).
set -eu
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
# The version the app reports (and Sparkle compares); override to build a test update.
VERSION="${ORILIO_VERSION:-0.1.0}"
BUILD="${ORILIO_BUILD:-1}"
# Sparkle: the appcast and the EdDSA public key (from Sparkle's generate_keys). While these are
# placeholders the updater doesn't start and nothing goes on the network.
FEED_URL="${ORILIO_FEED_URL:-https://PLACEHOLDER.invalid/appcast.xml}"
PUBLIC_KEY="${ORILIO_PUBLIC_ED_KEY:-PLACEHOLDER_SPARKLE_PUBLIC_ED_KEY}"
swift build -c "$CONFIG"
APP="build/Orilio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
cp "$BIN/OrilioPrototype" "$APP/Contents/MacOS/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework" # keeps its symlinks and helpers
cp Resources/WhatsNew.json "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.enbiyagoral.orilio</string>
  <key>CFBundleName</key><string>Orilio</string>
  <key>CFBundleExecutable</key><string>OrilioPrototype</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$PUBLIC_KEY</string>
  <key>SUEnableSystemProfiling</key><false/>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>LSMinimumSystemVersion</key><string>14.6</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Orilio shows today's events and your next meeting in the notch. Calendar data stays on this Mac.</string>
  <key>NSCalendarsUsageDescription</key><string>Orilio shows today's events and your next meeting in the notch. Calendar data stays on this Mac.</string>
  <key>NSCameraUsageDescription</key><string>Orilio shows the camera as a mirror in the notch while you have it open. Nothing is recorded, saved or sent.</string>
  <key>NSAppleEventsUsageDescription</key><string>Orilio shows what is playing in Spotify and Music, and controls playback when you use its buttons.</string>
</dict></plist>
PLIST
# Inside out: Sparkle's helpers, the framework, then the app (ad-hoc; Sparkle verifies updates by EdDSA).
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign - --preserve-metadata=entitlements "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
echo "Built $APP — open it with: open $APP"
