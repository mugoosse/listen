#!/bin/bash
# The galaxy, as assertions.
#
# Two halves, and they are separate on purpose. The first is `listen galaxy
# --json` over a scratch library and needs no screen at all: the shells, the
# centre, the cap, determinism, and the rule that the centre has no edges. The
# second drives the real window through the accessibility tree and needs an
# unlocked, awake display, so it exits specially without one rather than
# passing on an empty tree.
#
# **The stars are one Metal view, so a probe has nothing to click.** Every
# other UI script in this repo presses a control by name; here there are no
# controls, only pixels the GPU drew. `LISTEN_PANEL=galaxy:selected` is what
# stands in for the click, and the motion policy is read out of the
# `LISTEN_DEBUG` trace the way `verify_search.sh` reads a scroll position: what
# the GPU is doing is invisible to accessibility and to a screenshot alike.
set -u

export LISTEN_NO_KEYCHAIN=1
export LISTEN_NO_TELEMETRY=1
export SHELL=/usr/bin/false

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_BIN="$ROOT/Listen.app/Contents/MacOS/Listen"
PROBE="$ROOT/.xcbuild/tools/axprobe"
DIR="${TMPDIR:-/tmp}/listen-verify-galaxy"
LIB="$DIR/library"
BIG="$DIR/big"
COPY="$DIR/T.app"

[ -x "$APP_BIN" ] || { echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }
field() {
  echo "$1" | awk -F'\t' -v want="$2" \
    '{ for (i = 1; i <= NF; i++) if ($i == want) f = 1 } END { exit f ? 0 : 1 }'
}
jq_() { python3 -c 'import json,sys;print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
kind_() { python3 -c 'import json,sys;print(json.load(sys.stdin)["nodes_by_kind"].get(sys.argv[1],0))' "$1"; }

rm -rf "$DIR"; mkdir -p "$LIB/recordings" "$LIB/notes" "$BIG/recordings"

# ---------------------------------------------------------------------------
# A library with all four kinds in it, and the links between them
# ---------------------------------------------------------------------------
python3 - "$LIB" "$BIG" <<'PY'
import datetime, json, os, sys
small, big = sys.argv[1], sys.argv[2]
people = ["Ari Chen", "Morgan Bell", "Samira Patel", "Me"]
start = datetime.datetime(2026, 5, 1, 9, 0)
ids = []
for i in range(12):
    when = start + datetime.timedelta(days=i)
    rid = when.strftime("%Y-%m-%d-%H%M%S")
    ids.append(rid)
    folder = os.path.join(small, "recordings", rid)
    os.makedirs(folder, exist_ok=True)
    json.dump({"id": rid, "title": f"Meeting {i}", "recorded_at": when.isoformat() + "Z",
               "duration": 600, "source": "system", "state": "done"},
              open(os.path.join(folder, "metadata.json"), "w"))
    speakers = people[:(i % 3) + 2]
    # `turns.json` is a bare array, which is what `People.speakers` decodes. A
    # dict with a "turns" key parses as nothing and every person disappears.
    turns = [{"speaker": speakers[k % len(speakers)], "start": k * 5.0,
              "end": k * 5.0 + 5, "text": f"Point {k}."} for k in range(8)]
    json.dump(turns, open(os.path.join(folder, "turns.json"), "w"))
for i in range(4):
    about = ids[i:i + 2]
    body = ["---", f"title: Write-up {i}", "created: 2026-06-01T10:00:00Z", "recordings:"]
    body += [f"  - {r}" for r in about] + ["---", "", "Body.", ""]
    open(os.path.join(small, "notes", f"write-up-{i}.md"), "w").write("\n".join(body))

# A library past the presentation cap, metadata only: the cap is about how many
# stars are drawn, and nothing here needs a transcript to count.
for i in range(1300):
    when = start + datetime.timedelta(minutes=i)
    rid = when.strftime("%Y-%m-%d-%H%M%S")
    folder = os.path.join(big, "recordings", rid)
    os.makedirs(folder, exist_ok=True)
    json.dump({"id": rid, "title": f"Bulk {i}", "recorded_at": when.isoformat() + "Z",
               "duration": 60, "source": "system", "state": "done"},
              open(os.path.join(folder, "metadata.json"), "w"))
PY

echo "0. the geometry, with no library and no window"
# Compiled straight out of the app's own sources: `Galaxy.swift` and
# `GalaxyRenderer.swift` depend on nothing but Foundation, simd and Metal,
# which is the whole reason `GalaxyLibrary.swift` is a separate file. It buys
# the one class of bug here that a screenshot cannot show and a count cannot
# catch, which is a sign: the orbit shipped inverted on the horizontal axis
# alone, so dragging right sent the scene left while dragging up brought it up.
GEOM="$DIR/geometry"
if swiftc -O -parse-as-library "$ROOT/Sources/listen/Galaxy.swift" \
        "$ROOT/Sources/listen/GalaxyRenderer.swift" \
        "$ROOT/tools/galaxy_geometry.swift" -o "$GEOM" 2>"$DIR/geom-build.log"; then
  "$GEOM" | sed 's/^/  /'
  if [ "${PIPESTATUS[0]}" = "0" ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
else
  bad "the geometry checks did not compile; see $DIR/geom-build.log"
fi

echo
echo "1. the shells, out of a real library read"
out=$(LISTEN_LIBRARY="$LIB" "$APP_BIN" galaxy --json 2>/dev/null)
[ -n "$out" ]
check $? "listen galaxy --json answers"
[ "$(echo "$out" | kind_ recording)" = "12" ]
check $? "every recording is a star"
[ "$(echo "$out" | kind_ note)" = "4" ]
check $? "every note is a star"
# Four speakers, and one of them is you: you are the centre rather than a
# fourth star on the people shell. Two stars for one person was the falsehood,
# and the one in the middle was the one carrying no evidence.
[ "$(echo "$out" | kind_ person)" = "3" ]
check $? "every speaker but you is a star on the people shell"
[ "$(echo "$out" | kind_ device)" = "1" ]
check $? "and you are the centre, exactly once"
[ "$(echo "$out" | jq_ centre_is_you)" = "True" ]
check $? "the centre is a person the library has heard, not an anonymous anchor"
[ "$(echo "$out" | jq_ centre_links)" -gt 0 ] 2>/dev/null
check $? "so its links are real ones it earned ($(echo "$out" | jq_ centre_links))"
[ "$(echo "$out" | jq_ off_shell)" = "0" ]
check $? "every star sits exactly on its own shell"
[ "$(echo "$out" | jq_ centre_edges)" = "0" ]
check $? "and the synthetic anchor is never an endpoint, because it stands for nothing"

echo
echo "2. the links are the ones already written down"
# Four notes naming two recordings each, and speakers over twelve recordings.
# Not a total, because what matters is that both kinds exist and neither is
# invented: a similarity or a co-occurrence edge would show up as a third kind.
echo "$out" | python3 -c '
import json, sys
kinds = set(json.load(sys.stdin)["edges_by_kind"])
sys.exit(0 if kinds <= {"Speaks in", "Written about", "Asked about"} else 1)'
check $? "only the three relationships the library actually records"
[ "$(echo "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["edges_by_kind"].get("Written about",0))')" = "8" ]
check $? "a note names its recordings, and that is the edge"

echo
echo "3. the same library twice is the same picture"
second=$(LISTEN_LIBRARY="$LIB" "$APP_BIN" galaxy --json 2>/dev/null)
[ "$out" = "$second" ]
check $? "a second read is identical"
# The counts above agree even for a layout that reshuffled every star, so the
# claim the seeded hash exists to make needs its own number.
digest=$(echo "$out" | jq_ layout_digest)
[ -n "$digest" ] && [ "$digest" != "0000000000000000" ]
check $? "the layout has a digest ($digest)"
[ "$digest" = "$(echo "$second" | jq_ layout_digest)" ]
check $? "and it is the same one, so no star moved between launches"

echo
echo "4. the cap is disclosed, never silent"
big=$(LISTEN_LIBRARY="$BIG" "$APP_BIN" galaxy --json 2>/dev/null)
[ "$(echo "$big" | jq_ nodes)" = "1200" ]
check $? "the picture stops at 1200 stars"
echo "$big" | jq_ label | grep -q "not drawn"
check $? "and says so, with a count, rather than quietly stopping"
[ "$(echo "$big" | jq_ off_shell)" = "0" ]
check $? "a capped library is still exactly on its shells"

echo
echo "5. an empty library says what it is rather than drawing nothing"
mkdir -p "$DIR/empty"
empty=$(LISTEN_LIBRARY="$DIR/empty" "$APP_BIN" galaxy --json 2>/dev/null)
[ "$(echo "$empty" | jq_ nodes)" = "1" ]
check $? "an empty library is the centre and nothing else"
[ "$(echo "$empty" | jq_ centre_is_you)" = "False" ]
check $? "and with nobody heard yet the centre falls back to the anchor"
[ "$(echo "$empty" | jq_ edges)" = "0" ]
check $? "with no links invented to fill it"

echo
echo "6. the picture itself, rendered with no window at all"
# Metal needs no display, so this is the half that still answers on a machine
# whose screen is locked. `screencapture` returns a black image there rather
# than an error, so a UI run that "passed" on one is a run that checked nothing.
SHOT="$DIR/galaxy.png"
LISTEN_LIBRARY="$LIB" "$APP_BIN" galaxy --image "$SHOT" >/dev/null 2>&1
[ -s "$SHOT" ]
check $? "listen galaxy --image writes a PNG"
LISTEN_LIBRARY="$LIB" "$APP_BIN" galaxy --image "$DIR/wrong.jpg" >/dev/null 2>&1
[ ! -e "$DIR/wrong.jpg" ]
check $? "and refuses a path it would not be readable at"
[ "$(python3 "$ROOT/tools/pngstats.py" "$SHOT" size)" = "1600 1000" ]
check $? "at the size it says"
bright=$(python3 "$ROOT/tools/pngstats.py" "$SHOT" bright)
[ "$bright" -gt 500 ] 2>/dev/null
check $? "and it is not a black frame ($bright lit pixels)"
[ "$bright" -lt 400000 ] 2>/dev/null
check $? "and not a wash over the whole image"
read -r people notes chats recordings <<EOF
$(python3 "$ROOT/tools/pngstats.py" "$SHOT" shells)
EOF
[ "$recordings" -gt 50 ] 2>/dev/null
check $? "the recordings shell is drawn ($recordings px)"
[ "$notes" -gt 20 ] 2>/dev/null
check $? "the notes shell is drawn ($notes px)"
[ "$people" -gt 20 ] 2>/dev/null
check $? "the people shell is drawn ($people px)"
# No chats in this fixture, so its shell must be empty rather than filled with
# something else. A colour that appears where there is nothing to draw is a
# palette bug, and it would be invisible in every count-based check above.
[ "$chats" -lt 40 ] 2>/dev/null
check $? "and the chats shell is empty, because this library has no chats ($chats px)"

# **The sky is the window's own ground.** Two constants, one in Swift for the
# sidebar and one handed to the GPU, and a shade between them is a seam down
# the middle of the window rather than depth. Measured off the corner of the
# render, where nothing is drawn but the sky.
sky=$(python3 "$ROOT/tools/pngstats.py" "$SHOT" pixel 40 40)
[ "$sky" = "10 15 29" ]
check $? "the galaxy's sky is Brand.canvas, byte for byte (got $sky)"

# **The near stop, which is a question about the glow and not the radius.**
# Zoomed all the way in, the camera used to sit inside the people shell with
# the centre filling most of the frame and nothing on screen saying which way
# was out. The geometry checks bound the camera's distance; only a picture
# bounds what the centre's glow actually covers.
NEAR="$DIR/closest.png"
LISTEN_LIBRARY="$LIB" "$APP_BIN" galaxy --image "$NEAR" --closest >/dev/null 2>&1
nearLit=$(python3 "$ROOT/tools/pngstats.py" "$NEAR" bright)
[ "$nearLit" -lt 240000 ] 2>/dev/null
check $? "zoomed all the way in, the centre is not most of the frame ($nearLit of 1600000 px lit)"
[ "$nearLit" -gt "$bright" ] 2>/dev/null
check $? "and it is closer than the opening view, so the stop is not the start"

EMPTYSHOT="$DIR/empty.png"
LISTEN_LIBRARY="$DIR/empty" "$APP_BIN" galaxy --image "$EMPTYSHOT" >/dev/null 2>&1
emptyBright=$(python3 "$ROOT/tools/pngstats.py" "$EMPTYSHOT" bright)
[ "$emptyBright" -lt "$bright" ] 2>/dev/null
check $? "an empty library draws the centre and the guides, and nothing else ($emptyBright px)"

# ---------------------------------------------------------------------------
# The window. Needs Accessibility permission and an awake, unlocked display.
# ---------------------------------------------------------------------------
echo
if [ "${1:-}" != "--ui" ]; then
  echo "skipping the window checks: pass --ui to run them"
  echo
  echo "$pass passed, $fail failed"
  [ "$fail" = "0" ] || exit 1
  rm -rf "$DIR"
  exit 0
fi

[ -x "$PROBE" ] || swiftc -O "$ROOT/tools/axprobe.swift" -o "$PROBE" || exit 2
cp -R "$ROOT/Listen.app" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    "$COPY/Contents/Info.plist" >/dev/null
codesign --force --sign - --deep "$COPY" 2>/dev/null

APP=""
TRACE="$DIR/trace.log"
stop() { [ -n "$APP" ] && kill "$APP" 2>/dev/null; sleep 1; }
launch() {
  defaults delete com.mgo.listen-uitest >/dev/null 2>&1
  defaults write com.mgo.listen-uitest onboarded -bool true
  LISTEN_LIBRARY="$LIB" LISTEN_DEBUG=1 LISTEN_PANEL="$1" \
      "$COPY/Contents/MacOS/Listen" >>"$TRACE" 2>&1 &
  APP=$!
  sleep 6
}

echo "7. the galaxy opens, and says what it is showing"
launch galaxy
dump=$("$PROBE" texts $APP 2>&1)
case $? in 3) echo "  SKIP: no Accessibility permission" >&2; stop; exit 2;; esac
# A locked screen or a sleeping display empties every window's subtree, and an
# empty tree passes every negative assertion below. So the window proves it is
# there before anything else is asked of it.
field "$dump" "Reset view"
check $? "the window is up and readable (guard against an empty AX tree)"
field "$dump" "People"
check $? "the legend names the people shell"
field "$dump" "Recordings"
check $? "and the recordings shell"
# The centre is named after you now, so the row is "<your name> (this Mac)".
# Matched on the bracket rather than the name, which is a preference.
echo "$dump" | grep -q "(this Mac)"
check $? "and says the centre is you, on this Mac"
echo "$dump" | grep -q "on four shells"
check $? "the status line says how much of the library is drawn"
field "$dump" "Pause motion"
check $? "the motion switch is on the pane, named, and reachable"
# 12 recordings + 4 notes + 3 people, because the fourth is the centre.
grep -q "galaxy snapshot 20 stars" "$TRACE"
check $? "the snapshot it drew is the library, read on a background queue"
stop

echo
echo "8. a selected star offers the page it stands for"
: > "$TRACE"
launch galaxy:selected
dump=$("$PROBE" texts $APP 2>&1)
field "$dump" "RECORDING"
check $? "the card says what kind of thing is selected"
field "$dump" "Open recording"
check $? "and offers to open it"
echo "$dump" | grep -qE "[0-9]+ links?|Nothing links"
check $? "and says what it is connected to, or that nothing is"
"$PROBE" press $APP "Open recording" >/dev/null 2>&1
check $? "Open is pressable"
sleep 3
dump=$("$PROBE" texts $APP 2>&1)
! field "$dump" "Open recording"
check $? "pressing it leaves the galaxy"
field "$dump" "Record"
check $? "and lands in the library, on the recording"
stop

echo
echo "9. motion stops when nobody can see it"
: > "$TRACE"
launch galaxy
# The window is frontmost after launch, so ambient motion is permitted unless
# this Mac has Reduce Motion or Low Power on. Either is a real answer, so the
# trace is asked which it is rather than the run being called a failure.
if grep -q "galaxy motion on" "$TRACE"; then
  ok "a visible galaxy animates"
  # **By pid, never by name and never by keystroke.** Several copies of this
  # app run on this machine at once, and Cmd-H goes to whatever is frontmost,
  # which on a busy desktop is not reliably the one just launched.
  osascript -e "tell application \"System Events\" to set visible of (first process whose unix id is $APP) to false" >/dev/null 2>&1
  sleep 2
  grep -q "galaxy motion off .*visible=false" "$TRACE"
  check $? "hiding the app stops it, and the trace says visibility is why"
  osascript -e "tell application \"System Events\" to set visible of (first process whose unix id is $APP) to true" >/dev/null 2>&1
else
  reason=$(grep -m1 "galaxy motion off" "$TRACE" || echo "no motion line in the trace")
  case "$reason" in
    *reduced=true*|*lowPower=true*)
      ok "motion is off for a system setting, and the trace names it: $reason" ;;
    *) bad "a visible galaxy did not animate, and no setting explains it: $reason" ;;
  esac
fi
stop

defaults delete com.mgo.listen-uitest >/dev/null 2>&1
rm -rf "$DIR"
echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ] || exit 1
