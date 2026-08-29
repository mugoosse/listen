#!/bin/bash
# The DMG guard, as assertions: launched from a read-only mounted image, the
# app says so before it registers anything, and "Not now" continues instead of
# blocking. Builds a scratch DMG from the working-directory app; the real
# /Applications copy is never touched (the offered escape is declined).
#
# Needs the display awake and Accessibility permission for this terminal.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE="$ROOT/.xcbuild/tools/axprobe"
DIR="${TMPDIR:-/tmp}/listen-verify-installguard"
export LISTEN_LIBRARY="$DIR/library"
export LISTEN_NO_TELEMETRY=1

[ -x "$ROOT/Listen.app/Contents/MacOS/Listen" ] || {
  echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }
[ -x "$PROBE" ] || swiftc -O "$ROOT/tools/axprobe.swift" -o "$PROBE" || exit 2

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

rm -rf "$DIR"; mkdir -p "$DIR/stage" "$LISTEN_LIBRARY"
cp -R "$ROOT/Listen.app" "$DIR/stage/"

# UDZO mounts read-only, which is what the shipped image is. -nobrowse keeps
# Finder out of it. The volume name is scratch-specific so a stale mount from
# an interrupted run cannot be mistaken for this one.
VOL="ListenGuardTest-$$"
hdiutil create -srcfolder "$DIR/stage" -volname "$VOL" -format UDZO \
    -quiet "$DIR/test.dmg" || { echo "hdiutil create failed" >&2; exit 2; }
hdiutil attach "$DIR/test.dmg" -nobrowse -quiet || { echo "attach failed" >&2; exit 2; }
trap 'hdiutil detach "/Volumes/'"$VOL"'" -quiet 2>/dev/null; true' EXIT

caffeinate -u -t 2 2>/dev/null
"/Volumes/$VOL/Listen.app/Contents/MacOS/Listen" >/dev/null 2>&1 &
APP=$!
sleep 4

echo "1. the guard notices and says so"
dump=$("$PROBE" texts $APP 2>&1)
case $? in 3) echo "  SKIP: no Accessibility permission" >&2; exit 2;; esac
echo "$dump" | grep -q "running from the installer"
check $? "the alert names the situation"

echo "2. declining continues instead of blocking"
"$PROBE" press $APP "Not now" >/dev/null 2>&1
check $? "Not now is pressable"
sleep 3
kill -0 $APP 2>/dev/null
check $? "the app is still running after declining"
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "What's cooking"
check $? "and the library came up"

kill $APP 2>/dev/null
sleep 1
hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null
trap - EXIT
rm -rf "$DIR"

echo
echo "passed $pass, failed $fail"
[ "$fail" = "0" ] || exit 1
