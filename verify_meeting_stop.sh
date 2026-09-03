#!/bin/bash
# Does pressing Stop during a call start another recording?
#
# The loop this is about, measured on 3 September 2026 from inside a Google
# Meet call: Stop in Listen without leaving the call left a new recording about
# three seconds later, the panel asked about it again, and stopping that one
# started a third. See `.agents/notes/capture.md`, "Stopping by hand during a
# call started the next recording, and the one after that".
#
# A real meeting cannot be held on demand, so `LISTEN_FAKE_CALLERS` stands in
# for the process list: a file of bundle identifiers, one per line, re-read on
# every poll. Joining a call is a write and leaving one is a truncation, which
# is the only part of detection this script pretends about. Everything else is
# the shipped path, including the capture.
#
# What it establishes:
#   1. a call in the file is detected and recorded, so the rest means something;
#   2. Stop while that call is still running starts nothing else;
#   3. the app leaving the call re-arms it, so the *next* call is still offered;
#   4. a meeting that ends on its own still stops the recording and still
#      leaves the following call detectable, which is the case the fix must not
#      have broken.
#
# Needs `./build.sh && ./make_app.sh` first, or it tests the last build, plus
# Accessibility permission for this terminal (to press the panel) and the
# display awake. Recordings are real, so microphone and screen-recording
# permission decide whether they have audio in them; nothing here reads it.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/Listen.app/Contents/MacOS/Listen"
TOOLS="$ROOT/.xcbuild/tools"
WORK="${TMPDIR:-/tmp}/listen-verify-meeting-stop"
PROBE="$TOOLS/axprobe"
CALLERS="$WORK/callers"
TRACE="$WORK/app.trace"
export LISTEN_LIBRARY="$WORK/library"
export LISTEN_FAKE_CALLERS="$CALLERS"
export LISTEN_DEBUG=1

pass=0; fail=0; skipped=0
check() {  # <what> <expected> <actual>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$1" "$2" "$3"; fi
}
skip() { skipped=$((skipped+1)); printf '  SKIP  %s\n' "$1"; }
# "yes" while the panel is asking about a detected meeting. Read from the tree
# every time rather than from a dump taken earlier, because the whole point is
# what is on screen at this moment.
asking() {
    if "$PROBE" texts $APP 2>/dev/null | grep -qi 'are you in a meeting'
    then echo yes; else echo no; fi
}

[ -x "$BIN" ] || { echo "no app at $BIN; run ./build.sh && ./make_app.sh"; exit 1; }
[ -x "$PROBE" ] || swiftc -O "$ROOT/tools/axprobe.swift" -o "$PROBE" 2>/dev/null \
    || { echo "could not build axprobe"; exit 1; }

# Detection is a real preference in the real defaults domain, and this script
# must not write there: a run that turned it on would leave it on.
if [ "$(defaults read com.mgo.listen autoDetectMeetings 2>/dev/null || echo 1)" = "0" ]; then
    echo "meeting detection is off in Settings; nothing here can run"
    exit 1
fi

rm -rf "$WORK"; mkdir -p "$LISTEN_LIBRARY"
APP=""
cleanup() { [ -n "$APP" ] && kill "$APP" 2>/dev/null; : ; }
trap cleanup EXIT

join()  { printf 'com.google.Chrome\n' > "$CALLERS"; }
leave() { : > "$CALLERS"; }
detections() { grep -c 'meeting detected' "$TRACE" 2>/dev/null | head -1; }
ended()      { grep -c 'meeting ended'   "$TRACE" 2>/dev/null | head -1; }
recordings() {  # every folder the library holds, staged or filed
    find "$LISTEN_LIBRARY" -maxdepth 2 -mindepth 2 -type d 2>/dev/null | wc -l | tr -d ' '
}

# The poll is three seconds and a stop is called after two quiet ones, so
# "long enough for anything to have happened" is four polls.
POLL=3
SETTLE=$((POLL * 4))

echo "1. a call in the file is detected and recorded"
# Nobody on a call at launch, because the poll seeds its edge state from what
# is happening right then: a call already running when Listen starts is one it
# deliberately does not claim, so a file with Chrome in it before the launch
# traces "a call is already running" and nothing is ever detected.
leave
"$BIN" 2>"$TRACE" >/dev/null &
APP=$!
sleep 8
dump=$("$PROBE" texts $APP 2>&1); rc=$?
if [ $rc -eq 3 ]; then
    skip "this terminal has no Accessibility permission"; exit 1
elif ! printf '%s' "$dump" | grep -qi record; then
    skip "empty AX tree (is the display asleep?)"; exit 1
fi
before=$(recordings)
join
sleep $((POLL * 2))
check "the meeting was detected"      "1"   "$(detections)"
check "and a recording is running"    "yes" "$(asking)"
started=$(recordings)
check "and it is a new one"           "$((before + 1))" "$started"

echo "2. Stop, with the call still running, starts nothing else"
"$PROBE" press $APP Yes >/dev/null 2>&1     # approve it, as the report did
sleep 1
"$PROBE" press $APP Stop >/dev/null 2>&1
sleep $SETTLE
check "no second detection"           "1"   "$(detections)"
check "no second recording"           "$started" "$(recordings)"
check "and nothing is on screen"      "no"  "$(asking)"

echo "3. the app leaving the call re-arms it"
leave
sleep $SETTLE
join
sleep $((POLL * 2))
check "the next call is detected"     "2"   "$(detections)"
check "and recorded"                  "$((started + 1))" "$(recordings)"

echo "4. a meeting that ends on its own stops the recording, and suppresses nothing"
leave
sleep $SETTLE
check "the recording stopped"         "1"   "$(ended)"
join
sleep $((POLL * 2))
check "and the next call is detected" "3"   "$(detections)"

leave
kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null; APP=""

echo
printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
