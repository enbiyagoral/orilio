#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Orilio — a calm control surface for the Mac notch.
# Copyright (C) 2026 Enbiya Goral and Orilio contributors

# Prepares a release: builds it, zips it, signs it with your Sparkle key and adds it to appcast.xml.
# Publishes nothing. Usage: scripts/release.sh 0.2.0 2   (version, build number)
set -eu
cd "$(dirname "$0")/.."
VERSION="$1"
BUILD="$2"
BIN=.build/artifacts/sparkle/Sparkle/bin
KEY_FILE=scripts/sparkle-public-key.txt
swift build -c release >/dev/null # fetches Sparkle's tools on a fresh checkout
# The private key stays in your Keychain (created once with Sparkle's generate_keys); its public half
# goes into every build through make-app.sh.
if [ ! -s "$KEY_FILE" ]; then
  if ! "$BIN/generate_keys" -p > "$KEY_FILE" 2>/dev/null; then
    rm -f "$KEY_FILE"
    echo "No Sparkle signing key yet. Create it once with $BIN/generate_keys (and back it up with -x), then run this again."
    exit 1
  fi
fi
ORILIO_VERSION="$VERSION" ORILIO_BUILD="$BUILD" ./scripts/make-app.sh release
OUT=build/releases
mkdir -p "$OUT"
ZIP="$OUT/Orilio-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Orilio.app "$ZIP"
cp appcast.xml "$OUT/appcast.xml"
"$BIN/generate_appcast" --download-url-prefix "https://github.com/enbiyagoral/orilio/releases/download/v$VERSION/" "$OUT"
cp "$OUT/appcast.xml" appcast.xml
echo "Ready: $ZIP"
echo "To publish: create the GitHub release v$VERSION with that zip attached, then commit and push appcast.xml."
