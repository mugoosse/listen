#!/bin/bash
# The sync status lie, as assertions: a Mac that never enabled sync must not
# say "Syncing transcript" about a recording it has just transcribed, on the
# row or on the page, and `listen sync status` must name the environment and
# say sync is off. Runs the built app against a scratch LISTEN_LIBRARY, so the
# real library is never opened for writing.
#
# Needs: the ASR model already on disk (any machine that has transcribed
# before), the display awake, and Accessibility permission for this terminal.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/Listen.app/Contents/MacOS/Listen"
PROBE="$ROOT/.xcbuild/tools/axprobe"
export LISTEN_LIBRARY="${TMPDIR:-/tmp}/listen-verify-sync-status"
export LISTEN_NO_TELEMETRY=1
ID="2026-08-29-100000-SYNC"

[ -x "$BIN" ] || { echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }
[ -x "$PROBE" ] || swiftc -O "$ROOT/tools/axprobe.swift" -o "$PROBE" || exit 2

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

rm -rf "$LISTEN_LIBRARY"
mkdir -p "$LISTEN_LIBRARY/recordings/$ID"

# Ten seconds of quiet tone: enough for the queue to adopt and transcribe,
# and nothing here asserts on the words, only on the states around them.
python3 - "$LISTEN_LIBRARY/recordings/$ID/mic.wav" <<'WAV'
import math, struct, sys, wave
out = wave.open(sys.argv[1], "w")
out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
frames = b"".join(struct.pack("<h", int(3000 * math.sin(i * 440 * 2 * math.pi / 16000)))
                  for i in range(16000 * 10))
out.writeframes(frames); out.close()
WAV
cat > "$LISTEN_LIBRARY/recordings/$ID/metadata.json" <<JSON
{"id":"$ID","title":"Untitled","source":"mac","state":"pending",
 "duration":10,"recorded_at":"2026-08-29T10:00:00Z"}
JSON

echo "1. the CLI, before the app: environment and off-ness"
status=$("$BIN" sync status 2>&1)
echo "$status" | grep -qi "environment:"; check $? "sync status names the CloudKit environment"
echo "$status" | grep -q "sync:.*off";    check $? "and says sync is off for this scratch library"

echo "2. the app transcribes it, and no row claims to be syncing"
caffeinate -u -t 2 2>/dev/null
"$BIN" >/dev/null 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null' EXIT

waited=0
until python3 -c "
import json, sys
m = json.load(open('$LISTEN_LIBRARY/recordings/$ID/metadata.json'))
sys.exit(0 if m.get('state') in ('done', 'needs_labelling', 'failed') else 1)
" 2>/dev/null; do
  sleep 2; waited=$((waited+2))
  if [ $waited -ge 180 ]; then bad "the recording never finished transcribing"; break; fi
  kill -0 $APP 2>/dev/null || { bad "the app died before transcribing"; break; }
done
[ $waited -lt 180 ] && ok "the recording transcribed (${waited}s)"

sleep 3   # let the last activity repaint land before reading the tree
dump=$("$PROBE" texts $APP 2>&1)
case $? in
  3) echo "  SKIP: no Accessibility permission for this terminal" >&2; exit 2;;
  4) bad "the AX tree is empty: display asleep, or the window never drew";;
esac
# The recording's own row, not "New Recording": that phrase is in the menu
# bar, which is in the app's AX tree whatever window is up, so it proves
# nothing about the window this script is reading.
echo "$dump" | grep -q "Untitled"
check $? "the recording's row is on screen (positive control)"
! echo "$dump" | grep -qi "syncing transcript"
check $? "nothing on screen says 'Syncing transcript' with sync off"
! echo "$dump" | grep -qi "retrying sync"
check $? "and nothing says 'Retrying sync' either"

kill $APP 2>/dev/null
trap - EXIT

echo
echo "passed $pass, failed $fail"
[ "$fail" = "0" ] || exit 1
