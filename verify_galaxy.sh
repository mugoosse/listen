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

echo "1. the shells, out of a real library read"
out=$(LISTEN_LIBRARY="$LIB" "$APP_BIN" galaxy --json 2>/dev/null)
[ -n "$out" ]
check $? "listen galaxy --json answers"
[ "$(echo "$out" | kind_ recording)" = "12" ]
check $? "every recording is a star"
[ "$(echo "$out" | kind_ note)" = "4" ]
check $? "every note is a star"
[ "$(echo "$out" | kind_ person)" = "4" ]
check $? "every speaker is a star"
[ "$(echo "$out" | kind_ device)" = "1" ]
check $? "and exactly one centre"
[ "$(echo "$out" | jq_ off_shell)" = "0" ]
check $? "every star sits exactly on its own shell"
[ "$(echo "$out" | jq_ centre_edges)" = "0" ]
check $? "the centre has no edges: it is where you are looking from, not a claim"

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
check $? "a second read is identical, so a star does not move between launches"

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
[ "$(echo "$empty" | jq_ edges)" = "0" ]
check $? "with no links invented to fill it"

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

echo "6. the galaxy opens, and says what it is showing"
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
field "$dump" "Listen on this Mac"
check $? "and says what the centre is"
echo "$dump" | grep -q "on four shells"
check $? "the status line says how much of the library is drawn"
field "$dump" "Pause motion"
check $? "the motion switch is on the pane, named, and reachable"
grep -q "galaxy snapshot 17 stars" "$TRACE"
check $? "the snapshot it drew is the library, read on a background queue"
stop

echo
echo "7. a selected star offers the page it stands for"
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
echo "8. motion stops when nobody can see it"
: > "$TRACE"
launch galaxy
# The window is frontmost after launch, so ambient motion is permitted unless
# this Mac has Reduce Motion or Low Power on. Either is a real answer, so the
# trace is asked which it is rather than the run being called a failure.
if grep -q "galaxy motion on" "$TRACE"; then
  ok "a visible galaxy animates"
  osascript -e 'tell application "System Events" to keystroke "h" using command down' >/dev/null 2>&1
  sleep 2
  grep -q "galaxy motion off .*visible=false" "$TRACE"
  check $? "hiding the app stops it, and the trace says visibility is why"
  osascript -e 'tell application "System Events" to tell process "Listen" to set visible to true' >/dev/null 2>&1
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
