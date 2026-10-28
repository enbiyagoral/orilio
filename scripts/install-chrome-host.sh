#!/bin/sh
# Registers Orilio as Chrome's native messaging host for the Orilio extension.
# Usage: scripts/install-chrome-host.sh [path/to/Orilio.app]   (default: build/Orilio.app)
#        scripts/install-chrome-host.sh --uninstall
set -eu
cd "$(dirname "$0")/.."

NAME="com.deaconcornsoft.orilio"
EXTENSION_ID="jpnkibdkjlelnemfnpifoakbglenjnbg"
DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST="$DIR/$NAME.json"

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$MANIFEST"
  echo "Removed $MANIFEST"
  exit 0
fi

APP="${1:-build/Orilio.app}"
BINARY="$(cd "$APP/Contents/MacOS" && pwd)/OrilioPrototype"
[ -x "$BINARY" ] || { echo "Not found: $BINARY (run scripts/make-app.sh first)" >&2; exit 1; }

mkdir -p "$DIR"
# Only the Orilio extension may start the host; Chrome enforces allowed_origins.
cat > "$MANIFEST" <<JSON
{
  "name": "$NAME",
  "description": "Orilio media bridge",
  "path": "$BINARY",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXTENSION_ID/"]
}
JSON
chmod 644 "$MANIFEST"
echo "Registered $MANIFEST -> $BINARY"
