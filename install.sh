#!/bin/bash
# Installs Token Tracker into /Applications and launches it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/TokenTracker.app"

if [ ! -d "$APP" ]; then
    echo "App not built yet — building first…"
    "$ROOT/build.sh"
fi

echo "==> Installing to /Applications"
rm -rf "/Applications/TokenTracker.app"
cp -R "$APP" "/Applications/TokenTracker.app"
# Strip quarantine so it opens without Gatekeeper friction.
xattr -dr com.apple.quarantine "/Applications/TokenTracker.app" 2>/dev/null || true

echo "==> Launching"
open "/Applications/TokenTracker.app"
echo "Done. Token Tracker is in your Applications folder."
