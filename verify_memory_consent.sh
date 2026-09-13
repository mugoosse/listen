#!/bin/bash
#
# Who the person-memory sweep is allowed to read about, and whose turn it is.
#
# Over a synthetic library built here rather than copied from anybody's real
# one, so it needs no recordings, no model and no network: everything asserted
# is a decision about consent and scheduling, and all of those are readable
# from `listen context status --json` before a single provider request.
#
# The two failures it exists to catch:
#
#   - **Nobody enrolled.** Memory was off for every person until somebody
#     opened their page and worked through a modal. Measured on the real
#     library on 11 September 2026: 34 named people, one enrolled, 321 pending
#     parts and 18 processed, and the one enrolled person had nothing left to
#     read, so the queue was finished and could never move again.
#   - **One person eating the budget.** The sweep walked the labels
#     alphabetically and stopped at the first with work. Harmless at one
#     enrolled person, a starvation bug at thirty-four: the first name spends
#     the whole daily limit every day until their backlog runs out, and nobody
#     after them is ever read. `nextUp` exists so that is observable.
#
set -uo pipefail
cd "$(dirname "$0")"

APP="${LISTEN_APP:-Listen.app/Contents/MacOS/Listen}"
[ -x "$APP" ] || { echo "no app at $APP; run ./build.sh && ./make_app.sh"; exit 1; }

LIB="$(mktemp -d)/library"
mkdir -p "$LIB/recordings"
trap 'rm -rf "$(dirname "$LIB")"' EXIT
run() { LISTEN_LIBRARY="$LIB" "$APP" "$@"; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

# ---------------------------------------------------------------- the library
# Three meetings. Nick is in two and Ada in one, so the cold-start weighting has
# something to order by. The third names Zara in its text without her ever
# speaking, which is the mention fan-out: `ContextSources.people` includes her
# and `speakers` does not.
python3 - "$LIB" <<'PY'
import json, os, sys
lib = sys.argv[1]
def meeting(rid, when, title, turns):
    d = os.path.join(lib, "recordings", rid)
    os.makedirs(d, exist_ok=True)
    segs, t = [], 0.0
    for speaker, text in turns:
        segs.append({"start": t, "end": t + 6, "speaker": speaker, "text": text}); t += 6
    json.dump({"id": rid, "recorded_at": when, "title": title, "state": "done",
               "duration": t, "source": "detected", "room": False},
              open(os.path.join(d, "metadata.json"), "w"))
    json.dump(segs, open(os.path.join(d, "turns.json"), "w"))
    json.dump({"duration": t, "segments": segs, "wordLevel": False,
               "model": "mlx-community/parakeet-tdt-0.6b-v2",
               "cleanup": {}, "dictionary": {}},
              open(os.path.join(d, "transcript.json"), "w"))

meeting("2026-09-01-090000-0001", "2026-09-01T09:00:00Z", "Call with Nick", [
    ("Me",   "I want to get the pricing settled before the end of the month."),
    ("Nick", "I lead the platform team and I can have numbers by Thursday."),
    ("Me",   "That works. Send them over when you have them."),
])
meeting("2026-09-02-090000-0002", "2026-09-02T09:00:00Z", "Call with Nick", [
    ("Nick", "The numbers are done. I moved off the platform team last week."),
    ("Me",   "Congratulations. Who picks it up?"),
    ("Nick", "Ada does, starting Monday."),
])
meeting("2026-09-03-090000-0003", "2026-09-03T09:00:00Z", "Call with Ada", [
    ("Ada", "I have taken over the platform team and I am hiring two people."),
    ("Me",  "Good. Zara mentioned the same thing to me last week."),
])
PY

echo "Synthetic library: $LIB"
run context index >/dev/null 2>&1

# --------------------------------------------------- nobody is enrolled at first
s=$(run context status --json 2>/dev/null)
q() { printf '%s' "$s" | python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }

echo
echo "Before anybody is asked"
is "nobody is enrolled"            "$(q "['enrolled']")"        "0"
is "new people stay off"           "$(q "['enrolsNewPeople']")" "False"
is "the queue is empty"            "$(q "['nextUp']")"          "[]"
# Me, Nick, Ada speak. Zara is named by somebody else and is not a candidate:
# enrolling her would queue work with nothing of hers in it, and on a real
# library every passing first name would do the same.
is "only speakers are candidates"  "$(q "['people']")"          "3"

# ------------------------------------------------------------------- enrolling
echo
echo "After turning enrolment on"
run context enrol on >/dev/null 2>&1
s=$(run context status --json 2>/dev/null)
is "everybody is enrolled"         "$(q "['enrolled']")"        "3"
is "new people join automatically" "$(q "['enrolsNewPeople']")" "True"
is "Zara is still not a person"    "$(q "['people']")"          "3"
[ "$(q "['enrolledPending']")" -gt 0 ] \
  && ok "there is a backlog to read" \
  || no "there is a backlog to read (got $(q "['enrolledPending']"))"
[ "$(q "['estimatedDays']")" -ge 1 ] \
  && ok "the backlog is quoted in days" \
  || no "the backlog is quoted in days"

# Scoped extraction reads a shared meeting once per participant, so the work the
# enrolled people represent is larger than the count of sources.
[ "$(q "['enrolledPending']")" -gt "$(q "['pending']")" ] \
  && ok "per-person backlog exceeds the source count" \
  || no "per-person backlog exceeds the source count"

# ------------------------------------------------------- an explicit no is kept
echo
echo "An explicit decline"
run context auto off --person Ada >/dev/null 2>&1
run context enrol on >/dev/null 2>&1          # a second pass must not undo it
s=$(run context status --json 2>/dev/null)
is "a declined person stays declined" "$(q "['enrolled']")" "2"

run context auto on --person Ada >/dev/null 2>&1
s=$(run context status --json 2>/dev/null)
is "and can be turned back on"        "$(q "['enrolled']")" "3"

# -------------------------------------------------------------- a new arrival
echo
echo "Somebody new"
python3 - "$LIB" <<'PY'
import json, os, sys
lib = sys.argv[1]
d = os.path.join(lib, "recordings", "2026-09-04-090000-0004")
os.makedirs(d, exist_ok=True)
segs = [{"start": 0, "end": 6, "speaker": "Bo", "text": "I run the design side and I report to Ada."},
        {"start": 6, "end": 12, "speaker": "Me", "text": "Good to know."}]
json.dump({"id": "2026-09-04-090000-0004", "recorded_at": "2026-09-04T09:00:00Z",
           "title": "Call with Bo", "state": "done", "duration": 12,
           "source": "detected", "room": False}, open(d + "/metadata.json", "w"))
json.dump(segs, open(d + "/turns.json", "w"))
json.dump({"duration": 12, "segments": segs, "wordLevel": False,
           "model": "mlx-community/parakeet-tdt-0.6b-v2", "cleanup": {}, "dictionary": {}},
          open(d + "/transcript.json", "w"))
PY
run context index >/dev/null 2>&1
run context enrol on >/dev/null 2>&1          # what the sweep does every pass
s=$(run context status --json 2>/dev/null)
is "a new person is enrolled without being asked again" "$(q "['enrolled']")" "4"

# --------------------------------------------------------------- whose turn it is
# The sweep stamps the head's entity id in context/schedule.json and moves on.
# Serving the head five times must serve five different people; the behaviour
# this replaced would have returned the same name every time.
echo
echo "Whose turn it is"
python3 - "$LIB" "$APP" <<'PY'
import json, os, subprocess, sys, time
lib, app = sys.argv[1], sys.argv[2]
env = {**os.environ, "LISTEN_LIBRARY": lib}
sched = os.path.join(lib, "context", "schedule.json")
if os.path.exists(sched): os.remove(sched)

def status():
    out = subprocess.run([app, "context", "status", "--json"], env=env,
                         capture_output=True, text=True).stdout
    return json.loads(out)

heads = []
for step in range(4):
    queue = status()["nextUp"]
    if not queue: break
    head = queue[0]
    heads.append(head["name"])
    current = json.load(open(sched)) if os.path.exists(sched) else {}
    current[head["id"]] = time.time() + step
    os.makedirs(os.path.dirname(sched), exist_ok=True)
    json.dump(current, open(sched, "w"))

print("  ..   served in order: " + ", ".join(heads))
problems = []
if not heads or heads[0] != "Maxime":
    problems.append(f"you should go first on a cold start, got {heads[:1]}")
if len(set(heads)) != len(heads):
    problems.append(f"four passes should serve four different people, got {heads}")
for line in problems: print("  FAIL " + line)
if not problems:
    print("  ok   you go first on a cold start")
    print("  ok   four passes serve four different people")
sys.exit(1 if problems else 0)
PY
if [ $? -eq 0 ]; then pass=$((pass+2)); else fail=$((fail+1)); fi

# ------------------------------------------------- turning enrolment off again
echo
echo "Turning enrolment off"
run context enrol off >/dev/null 2>&1
s=$(run context status --json 2>/dev/null)
is "new people stop joining"                 "$(q "['enrolsNewPeople']")" "False"
is "people already enrolled are left alone"  "$(q "['enrolled']")"        "4"

# ------------------------------------------------------------------ the pane
# Only with --ui, like the other scripts here: it needs an unlocked screen and
# it drives the uitest bundle copy, so it must not run alongside another AX
# script (they share one defaults domain and would wipe each other's setup).
if [ "${1:-}" = "--ui" ]; then
  echo
  echo "The People & Memory roster"
  PROBE="$(pwd)/.xcbuild/tools/axprobe"
  [ -x "$PROBE" ] || swiftc -O tools/axprobe.swift -o "$PROBE" || exit 2
  D="${TMPDIR:-/tmp}/listen-verify-consent-ui"
  rm -rf "$D"; mkdir -p "$D/hf"
  cp -R "$LIB" "$D/library"
  cp -R Listen.app "$D/T.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest"       "$D/T.app/Contents/Info.plist" >/dev/null
  codesign --force --sign - --deep "$D/T.app" 2>/dev/null
  defaults delete com.mgo.listen-uitest >/dev/null 2>&1
  defaults write com.mgo.listen-uitest onboarded -bool true
  export LISTEN_LIBRARY="$D/library" HF_HOME="$D/hf" LISTEN_NO_KEYCHAIN=1 LISTEN_NO_TELEMETRY=1
  caffeinate -u -t 2 2>/dev/null
  "$D/T.app/Contents/MacOS/Listen" >/dev/null 2>&1 &
  UI=$!
  sleep 5
  "$PROBE" activate $UI >/dev/null 2>&1; sleep 1
  "$PROBE" press $UI "Settings" >/dev/null 2>&1; sleep 1.5
  "$PROBE" selectrow $UI "People & Memory" >/dev/null 2>&1; sleep 3
  # Column 3 is the title and column 4 the value, so a label's words are in 4.
  dump=$("$PROBE" texts $UI 2>/dev/null | awk -F'\t' '{v=($4!=""?$4:$3); if(v!="") print v}')
  kill $UI 2>/dev/null
  defaults delete com.mgo.listen-uitest >/dev/null 2>&1
  rm -rf "$D"

  echo "$dump" | grep -q "Who is remembered" && ok "the roster has a section" || no "the roster has a section"
  echo "$dump" | grep -qE "of [0-9]+ people remembered" && ok "it says how many of how many" || no "it says how many of how many"
  echo "$dump" | grep -qE "about [0-9]+ day" && ok "and how long the backlog will take" || no "and how long the backlog will take"
  echo "$dump" | grep -q "Turn On for Everyone" && ok "there is a way to change all of them at once" || no "there is a way to change all of them at once"
  echo "$dump" | grep -q "Bo" && ok "everybody in the library has a row" || no "everybody in the library has a row"
  echo "$dump" | grep -qE "to read|details|Nothing found yet" && ok "each row says where that person stands" || no "each row says where that person stands"
  # The line this pane used to carry said the opposite of what now happens.
  ! echo "$dump" | grep -q "New people start with memory off"     && ok "the old copy about memory starting off is gone"     || no "the old copy about memory starting off is gone"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
