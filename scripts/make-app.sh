#!/bin/sh
# Wraps the SwiftPM build into Orilio.app so macOS treats it as a real agent app
# (LSUIElement: no Dock icon; a bundle is also needed for reliable activation and a stable defaults domain).
set -eu
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
swift build -c "$CONFIG"
APP="build/Orilio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c "$CONFIG" --show-bin-path)/OrilioPrototype" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.deaconcornsoft.orilio.prototype</string>
  <key>CFBundleName</key><string>Orilio</string>
  <key>CFBundleExecutable</key><string>OrilioPrototype</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.6</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Orilio shows what is playing in Spotify and Music, and controls playback when you use its buttons.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP — open it with: open $APP"
