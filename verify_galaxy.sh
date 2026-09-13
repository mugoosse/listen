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
# Wait for a string to appear in the tree, rather than sleeping a guess. The
# page is opened after the library has been read off disk, which is fast on a
# warm cache and not on a cold one, and a fixed sleep is the difference between
# a suite that passes and one that passes today.
await() {
  local want="$1" tries=0
  while [ $tries -lt 30 ]; do
    dump=$("$PROBE" texts $APP 2>&1)
    if field "$dump" "$want"; then return 0; fi
    sleep 0.5; tries=$((tries + 1))
  done
  return 1
}

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

# **A locked screen is not a failing build, and it reads exactly like one.**
# Every window subtree comes back empty behind the lock: `axprobe texts` exits 0
# with nothing but `AXApplication Listen` lines, so every positive assertion
# below fails and every negative one passes, which is a page of confident FAILs
# about controls nothing ever looked at. Measured here, twice. `caffeinate -u`
# wakes the display and does not clear this, so it is asked rather than worked
# around.
if ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'; then
  echo "  SKIP: the screen is locked, so every window assertion would read an" >&2
  echo "        empty tree. Unlock it and run this again." >&2
  echo
  echo "$pass passed, $fail failed (window checks skipped)"
  [ "$fail" = "0" ] || exit 1
  exit 2
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
  # **Detection off, or the copy records the room in the middle of the test.**
  # Meeting detection is on by default and a copy inherits it, so a call
  # anywhere on this Mac puts the window on the recording screen with "Are you
  # in a meeting?" over it. Measured: it is what made three assertions in
  # `verify_ask_states.sh` fail for several builds against an app that was
  # working, and a run that does this captures the microphone unasked.
  defaults write com.mgo.listen-uitest autoDetectMeetings -bool false
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
# The legend's first line, which is on the picture from the first frame.
# **Not "Reset view", which is what this used to be.** That control moved into
# the title bar and it is only there once the camera has been moved, so a guard
# on it would fail on a galaxy nobody had touched, which is the state every
# assertion below is about.
echo "$dump" | grep -q "(this Mac)"
check $? "the window is up and readable (guard against an empty AX tree)"
field "$dump" "People"
check $? "the legend names the people shell"
field "$dump" "Recordings"
check $? "and the recordings shell"
# The centre is named after you now, so the row is "<your name> (this Mac)".
# Matched on the bracket rather than the name, which is a preference.
echo "$dump" | grep -q "(this Mac)"
check $? "and says the centre is you, on this Mac"
# **Silence is the pass here.** The status line used to restate the picture on
# every galaxy ("159 of your library, on four shells"), which is true and is
# the shells saying it twice. It speaks only when something is not drawn, so on
# a library inside the cap there should be nothing to find.
! echo "$dump" | grep -q "of your library, on four shells"
check $? "the status line is silent when there is nothing it alone can say"
# **In the title bar now, beside the way out**, where the rest of this window's
# verbs are, and a glyph rather than two words: the item's own label is what
# accessibility reads, and it says what pressing it does rather than what it is
# about. The reset control is not asserted here because it is absent until the
# camera has been moved; `--ui` moves it below and checks it appears.
field "$dump" "Pause motion"
check $? "the motion control is in the title bar, named for what it does"
! echo "$dump" | grep -q "Reset view"
check $? "and nothing offers to reset a picture nobody has moved"
# 12 recordings + 4 notes + 3 people, because the fourth is the centre.
grep -q "galaxy snapshot 20 stars" "$TRACE"
check $? "the snapshot it drew is the library, read on a background queue"
stop

echo
echo "8. a selected star offers the page it stands for"
: > "$TRACE"
launch galaxy:selected
dump=$("$PROBE" texts $APP 2>&1)
# The kind is in the line under the title now, not a header above it: the top
# of the card is the name.
echo "$dump" | grep -q "^AXStaticText.*Recording · "
check $? "the card says what kind of thing is selected, under its name"
field "$dump" "Open recording"
check $? "and offers to open it"
echo "$dump" | grep -qE "[0-9]+ links?|Nothing links"
check $? "and says what it is connected to, or that nothing is"
# **A link goes where it says.** The card's link lines were static text: it
# told you a recording was written up in a note and then left you to find that
# note in the sphere yourself. Following one selects it, which changes the card
# to that thing.
link=$(echo "$dump" | awk -F'\t' '/AXButton/ && ($3 ~ /^Speaker / || $3 ~ /^Written up in /) { print $3; exit }')
[ -n "$link" ]
check $? "the card's links are buttons, not text ($link)"
"$PROBE" press $APP "$link" >/dev/null 2>&1
check $? "and one can be followed"
sleep 3
dump=$("$PROBE" texts $APP 2>&1)
! echo "$dump" | grep -q "^AXStaticText.*Recording · 1 May"
check $? "and the card is now about the thing at its other end"

# The way out of the card, which is a cross in its corner rather than a second
# verb beside Open. Pressed before Open, because Open leaves the galaxy.
"$PROBE" press $APP "Clear selection" >/dev/null 2>&1
check $? "the card's cross is pressable"
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
! field "$dump" "Open recording"
check $? "and it puts the card away"
! echo "$dump" | grep -q "RECORDING"
check $? "with nothing of it left behind"

stop
: > "$TRACE"
launch galaxy:selected
dump=$("$PROBE" texts $APP 2>&1)
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
echo "9. the globe on a page, and the way back"
: > "$TRACE"
launch ""
dump=$("$PROBE" texts $APP 2>&1)
# The home page: the globe takes the ellipsis's slot, where that menu has one
# row in it saying nothing is selected.
field "$dump" "Galaxy"
check $? "the home page carries the globe"
! field "$dump" "Actions"
check $? "instead of an actions menu with nothing in it"
stop
# **`LISTEN_PANEL=page`, because the sidebar cannot be reached.** Every row in
# that list is a `HoverRow`, a plain NSView with a target and an action, so
# neither `press` nor `selectrow` finds one, and the status menu's Recent rows
# only cover the newest few. See `LibraryWindow.previewPage`.
launch page
await "Actions"
check $? "opening a recording brings the actions menu back"
field "$dump" "Galaxy"
check $? "with the globe beside it"
# The globe carries the page: the galaxy opens on that star rather than on the
# whole library and a hunt.
"$PROBE" press $APP "Galaxy" >/dev/null 2>&1
await "Open recording"
check $? "the globe opens the galaxy with that page's star already picked"
echo "$dump" | grep -q "LISTEN BRAIN"
check $? "and it is the galaxy"
# **The camera flew to that star, so there is now a way back.** The control is
# absent over a picture nobody has moved and appears when one has, which is the
# whole of what it is for. The flight takes 0.65 s, so this is awaited rather
# than read.
await "Reset view"
check $? "the way back appears once the camera has moved"
"$PROBE" press $APP "Reset view" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
! echo "$dump" | grep -q "Reset view"
check $? "and goes again once it has been used"
# And the cross comes back to the page it came from, which the sidebar's
# selection is what makes true.
"$PROBE" press $APP "Close" >/dev/null 2>&1
await "Actions"
check $? "and the cross comes back to the page it came from"
! echo "$dump" | grep -q "LISTEN BRAIN"
check $? "with the galaxy gone"
stop

echo
echo "10. motion stops when nobody can see it"
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

# **A selection is not an interaction.** A card left open used to freeze the sky
# for as long as it stood there, while the one control that says whether the
# picture is moving went on offering to pause it. Read out of the trace, because
# a still picture and a drifting one photograph exactly the same.
: > "$TRACE"
launch galaxy:selected
if grep -q "galaxy motion on" "$TRACE"; then
  ! grep -q "galaxy motion off .*interacting=true" "$TRACE"
  check $? "selecting a star does not stop the drift"
  dump=$("$PROBE" texts $APP 2>&1)
  field "$dump" "Pause motion"
  check $? "so the control over it still offers to pause something that moves"
else
  ok "a selection was not asked about: this Mac has motion off for a setting"
fi
stop

echo
echo "11. the legend gets out of the way of the window's own controls"
: > "$TRACE"
launch galaxy
# **Collapsing the sidebar puts the traffic lights on the legend.** Everything
# before `.sidebarTrackingSeparator` is drawn over the sidebar's width, so with
# it gone the lights, the masthead, the gear and the collapse control all land
# on this pane's top-left corner, where the legend is. Measured, because where
# a view landed is exactly what a `texts` dump cannot say: the assertion is the
# whole point of `axprobe frame`.
open_at=$("$PROBE" frame $APP "listen brain")
"$PROBE" press $APP "Sidebar" >/dev/null
sleep 2
away_at=$("$PROBE" frame $APP "listen brain")
"$PROBE" press $APP "Sidebar" >/dev/null
sleep 2
back_at=$("$PROBE" frame $APP "listen brain")
read -r ox oy _ _ <<<"$open_at"
read -r ax ay _ _ <<<"$away_at"
[ -n "$oy" ] && [ -n "$ay" ]
check $? "the legend can be found and measured ($open_at)"
# Screen coordinates here are top-left origin, so down is a larger y. One title
# bar is 52 points on this build; 30 is the smallest move that cannot be a
# rounding of staying put.
[ "$ay" -ge "$((oy + 30))" ]
check $? "collapsing the sidebar drops the legend clear of the title bar ($oy -> $ay)"
[ "$ax" -lt "$ox" ]
check $? "and the pane really did take the sidebar's width ($ox -> $ax)"
[ "$back_at" = "$open_at" ]
check $? "bringing the sidebar back puts the legend back ($back_at)"
stop

echo
echo "12. the sidebar's search narrows the picture"
: > "$TRACE"
launch galaxy
# **What is drawn is countable, and only through the Metal view's own label.**
# The stars are pixels, so there is nothing in the tree to count; the view says
# how many it drew, which is `updateSceneAccessibility`, and that sentence is
# the only handle a script has on the filter.
stars() { "$PROBE" texts $APP 2>/dev/null | sed -n 's/.*picture: \([0-9]*\) stars.*/\1/p' | head -1; }
narrow() {
  "$PROBE" focus $APP "Search" >/dev/null 2>&1
  sleep 1
  "$PROBE" settext $APP "Search" "$1" >/dev/null 2>&1
  sleep 3
}
whole=$(stars)
[ "$whole" = "19" ]
check $? "the picture opens whole (19 stars, got ${whole:-nothing})"
# One note, the two meetings it is written about, and the centre. The
# neighbours are the point: the matches alone would be one star in an empty
# sphere, which answers "is it in here" and nothing else.
narrow "Write-up 2"
narrowed=$(stars)
[ "$narrowed" = "3" ]
check $? "a search leaves its match and what it links to (3 stars, got ${narrowed:-nothing})"
# The sidebar is still the sidebar: the same word narrows the list beside it.
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "Write-up 2"
check $? "and the list beside it is narrowed by the same word"
narrow "zzqqzz"
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "Nothing here matches"
check $? "a search nothing answers says so, rather than going blank"
narrow ""
back=$(stars)
[ "$back" = "$whole" ]
check $? "clearing the field gives the whole picture back ($back)"
stop

echo
echo "13. a selected star is what the list beside it is about"
# The fixture decides these: Meeting 0 is spoken in by Ari Chen and Morgan Bell
# (never Samira Patel, who joins from Meeting 1 on), and Write-up 0 is the note
# written about it. So its neighbourhood is two people and a note, and no
# recording at all, which is why the meetings are what disappear.
: > "$TRACE"
launch galaxy
before=$("$PROBE" texts $APP 2>&1)
field "$before" "Meeting 1"
check $? "the whole library is in the list before a star is picked"
stop

: > "$TRACE"
launch galaxy:selected
dump=$("$PROBE" texts $APP 2>&1)
! echo "$dump" | grep -q "Meeting 1"
check $? "picking one drops everything it is not linked to"
# **`field`, not `grep`.** The card lists the same links as "Speaker Ari Chen"
# and "Written up in Write-up 0", so a substring match here would pass on the
# card alone and say nothing about the list. A row's text field is the name
# exactly.
field "$dump" "Ari Chen"
check $? "and lists the people who spoke in it"
# **Not "Write-up 0", which is the note's title and not its row.** `NoteCell`
# leads one of the user's own notes with the meeting it is about, because every
# one of them is titled "Your notes"; the fixture's notes have no agent marker,
# so the row reads "Meeting 0" over "Your notes · 2 recordings". The subtitle is
# the half that is this row and nothing else on screen.
echo "$dump" | grep -q "Your notes · 2 recordings"
check $? "and the note written about it"
! field "$dump" "Samira Patel"
check $? "and nobody who is linked to something else"
# Searching inside the list, which is the whole reason this is a lens rather
# than a list built somewhere else: the pill and the field are ANDed.
narrow "Ari"
dump=$("$PROBE" texts $APP 2>&1)
field "$dump" "Ari Chen"
check $? "a word typed with a star selected searches inside that list"
! echo "$dump" | grep -q "Your notes · 2 recordings"
check $? "and narrows it"
field "$dump" "Open recording"
check $? "while the card stays up, so the star cannot fall out of its own list"
lit=$(stars)
[ "$lit" = "19" ]
check $? "and the picture is lit rather than narrowed (19 stars, got ${lit:-nothing})"
narrow ""
# The pill is the way out, and pressing it has to reach the picture: the
# selection is what put it there.
dump=$("$PROBE" texts $APP 2>&1)
pill=$(echo "$dump" | awk -F'\t' '/AXButton/ && $3 ~ /✕/ { print $3; exit }')
[ -n "$pill" ]
check $? "the list says which star it is about, on a pill you can drop ($pill)"
"$PROBE" press $APP "$pill" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
field "$dump" "Meeting 1"
check $? "dropping it gives the library back"
! field "$dump" "Open recording"
check $? "and clears the selection the pill came from"
stop

defaults delete com.mgo.listen-uitest >/dev/null 2>&1
rm -rf "$DIR"
echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ] || exit 1
