#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Orilio — a calm control surface for the Mac notch.
# Copyright (C) 2026 Enbiya Goral and Orilio contributors

# Wraps the SwiftPM build into Orilio.app so macOS treats it as a real agent app
# (LSUIElement: no Dock icon; a bundle is also needed for reliable activation and a stable defaults domain).
set -eu
cd "$(dirname "$0")/.."
CONFIG="${1:-debug}"
# The version the app reports (and Sparkle compares); override to build a test update.
VERSION="${ORILIO_VERSION:-0.1.0}"
BUILD="${ORILIO_BUILD:-1}"
# Sparkle: the appcast (appcast.xml in the public repository) and the EdDSA public key, which
# scripts/release.sh saves to scripts/sparkle-public-key.txt. Without the key the updater doesn't
# start and nothing goes on the network.
FEED_URL="${ORILIO_FEED_URL:-https://raw.githubusercontent.com/enbiyagoral/orilio/main/appcast.xml}"
KEY_FILE="scripts/sparkle-public-key.txt"
PUBLIC_KEY="${ORILIO_PUBLIC_ED_KEY:-$( [ -s "$KEY_FILE" ] && tr -d '[:space:]' < "$KEY_FILE" || echo PLACEHOLDER_SPARKLE_PUBLIC_ED_KEY)}"
WEBSITE_URL="https://github.com/enbiyagoral/orilio/releases/latest"
# Send Feedback: the address Mail fills in, and the GitHub "new issue" page (empty: the button is hidden).
FEEDBACK_EMAIL="${ORILIO_FEEDBACK_EMAIL:-}"
ISSUES_URL="${ORILIO_ISSUES_URL-https://github.com/enbiyagoral/orilio/issues/new}"
swift build -c "$CONFIG"
APP="build/Orilio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
cp "$BIN/OrilioPrototype" "$APP/Contents/MacOS/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework" # keeps its symlinks and helpers
cp Resources/WhatsNew.json LICENSE "$APP/Contents/Resources/" # LICENSE: the GPL's text, shown in Settings › About
ditto Resources/Localization "$APP/Contents/Resources" # en.lproj, tr.lproj: Localizable.strings and InfoPlist.strings
# The app icon (Default, Dark and Tinted; drawn by scripts/make-icons.swift) → Assets.car + AppIcon.icns.
xcrun actool Resources/Assets.xcassets --compile "$APP/Contents/Resources" --platform macosx \
  --minimum-deployment-target 14.6 --app-icon AppIcon --output-partial-info-plist "build/icon-info.plist" >/dev/null
cp .build/artifacts/sparkle/Sparkle/LICENSE "$APP/Contents/Resources/Sparkle-LICENSE.txt" # MIT, plus what Sparkle includes
# Extensions that ship with Orilio, and the catalog entries describing them.
mkdir -p "$APP/Contents/Resources/Extensions"
cp extensions/catalog.json "$APP/Contents/Resources/Extensions/"
ditto extensions/community.prayer-times.orilioext "$APP/Contents/Resources/Extensions/community.prayer-times.orilioext"
# The sandboxed XPC service extensions run in: no network, no files outside its container.
XPC="$APP/Contents/XPCServices/OrilioExtensionRunner.xpc"
mkdir -p "$XPC/Contents/MacOS"
cp "$BIN/OrilioExtensionRunner" "$XPC/Contents/MacOS/"
cat > "$XPC/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.enbiyagoral.orilio.ExtensionRunner</string>
  <key>CFBundleName</key><string>OrilioExtensionRunner</string>
  <key>CFBundleExecutable</key><string>OrilioExtensionRunner</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.6</string>
  <key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST
cat > build/runner.entitlements <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
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
  <key>OrilioFeedbackEmail</key><string>$FEEDBACK_EMAIL</string>
  <key>OrilioIssuesURL</key><string>$ISSUES_URL</string>
  <key>OrilioWebsiteURL</key><string>$WEBSITE_URL</string>
  <key>LSMinimumSystemVersion</key><string>14.6</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Orilio shows today's events and your next meeting in the notch. Calendar data stays on this Mac.</string>
  <key>NSCalendarsUsageDescription</key><string>Orilio shows today's events and your next meeting in the notch. Calendar data stays on this Mac.</string>
  <key>NSCameraUsageDescription</key><string>Orilio shows the camera as a mirror in the notch while you have it open. Nothing is recorded, saved or sent.</string>
  <key>NSAppleEventsUsageDescription</key><string>Orilio shows what is playing in Spotify and Music, and controls playback when you use its buttons.</string>
</dict></plist>
PLIST
# Inside out: Sparkle's helpers, the framework, the extension runner, then the app (ad-hoc; Sparkle verifies updates by EdDSA).
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign - --preserve-metadata=entitlements "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --entitlements build/runner.entitlements "$XPC"
codesign --force --sign - "$APP"
echo "Built $APP — open it with: open $APP"
