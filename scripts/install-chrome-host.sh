#!/bin/sh
# Registers Orilio as the native messaging host for the Orilio extension in every installed
# Chromium-based browser (Chrome, Chrome Beta/Canary, Chromium, Brave, Edge, Vivaldi, Arc).
# Usage: scripts/install-chrome-host.sh [path/to/Orilio.app]   (default: build/Orilio.app)
#        scripts/install-chrome-host.sh --uninstall
set -eu
cd "$(dirname "$0")/.."

NAME="com.deaconcornsoft.orilio"
EXTENSION_ID="jpnkibdkjlelnemfnpifoakbglenjnbg"
SUPPORT="$HOME/Library/Application Support"
BROWSERS="Google/Chrome
Google/Chrome Beta
Google/Chrome Canary
Chromium
BraveSoftware/Brave-Browser
Microsoft Edge
Vivaldi
Arc/User Data"

if [ "${1:-}" != "--uninstall" ]; then
  APP="${1:-build/Orilio.app}"
  BINARY="$(cd "$APP/Contents/MacOS" && pwd)/OrilioPrototype"
  [ -x "$BINARY" ] || { echo "Not found: $BINARY (run scripts/make-app.sh first)" >&2; exit 1; }
fi

echo "$BROWSERS" | while IFS= read -r browser; do
  dir="$SUPPORT/$browser"
  # Other apps create NativeMessagingHosts folders for browsers that aren't installed;
  # a real profile always has "Local State".
  [ -f "$dir/Local State" ] || continue
  manifest="$dir/NativeMessagingHosts/$NAME.json"
  if [ "${1:-}" = "--uninstall" ]; then
    [ -f "$manifest" ] && rm -f "$manifest" && echo "Removed: $browser"
    continue
  fi
  mkdir -p "$dir/NativeMessagingHosts"
  # Only the Orilio extension may start the host; the browser enforces allowed_origins.
  cat > "$manifest" <<JSON
{
  "name": "$NAME",
  "description": "Orilio media bridge",
  "path": "$BINARY",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON
  chmod 644 "$manifest"
  echo "Registered: $browser"
done
