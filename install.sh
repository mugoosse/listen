#!/bin/sh
# Build, bundle, and install to /Applications, then restart the running copy.
#
# Installing to a fixed path lets macOS keep the app's login-item registration
# attached to the same bundle across rebuilds.
#
# Permissions survive too, because make_app.sh always signs with the same
# identifier (com.mgo.listen) and TCC keys the microphone and audio-capture
# grants to that identity rather than to the file's contents.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="/Applications/Listen.app"

"$ROOT/build.sh" >/dev/null
"$ROOT/make_app.sh" >/dev/null
echo "built"

# Quit the running copy so we are not overwriting a live binary.
#
# Anchored, because `pkill -f` matches the whole command line and other
# processes carry this path as an *argument*. The sync agent runs as
# `listen-sync serve --listen /Applications/Listen.app/Contents/MacOS/Listen`,
# so an unanchored pattern killed the sync server on every install. Measured on
# 2026-08-08: it fired 200 ms after an iPhone upload's `finish` and cost the
# two recordings queued behind it. `Listen mcp` was collateral in the same way.
pkill -f "^$DEST/Contents/MacOS/Listen$" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$ROOT/Listen.app" "$DEST"
echo "installed -> $DEST"

open "$DEST"
echo "restarted"
