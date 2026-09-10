#!/bin/bash
# The "Up next" section, the page it opens, and the preparation that outlives
# it, as assertions over the app built in the working directory.
#
# Builds nothing. Run `./build.sh && ./make_app.sh` first or it tests the last
# build. It never opens the real library or the real calendar: everything here
# runs under a scratch LISTEN_LIBRARY and a LISTEN_FAKE_EVENTS fixture, both
# made here and removed at the end.
#
# **The fixture is written in minutes from now, not in wall-clock times.** Every
# claim worth asserting is relative ("in 12 min", "listed at 5 minutes late and
# gone at 20"), and a fixture with times in it is a fixture that passes until
# midnight and then stops. See `MeetingCalendar.fakeEvents`.
#
# `--ui` adds the window, which needs an unlocked screen and Accessibility
# permission for this terminal. Without it only the CLI half runs, which is
# every rule about which meetings are listed and everything the agent is told.
set -u

export LISTEN_NO_KEYCHAIN=1
cd "$(dirname "$0")"

BIN="$(pwd)/Listen.app/Contents/MacOS/Listen"
[[ -x "$BIN" ]] || { echo "no built app. ./build.sh && ./make_app.sh first."; exit 1; }

SCRATCH="${TMPDIR:-/tmp}/listen-verify-upcoming"
export LISTEN_LIBRARY="$SCRATCH"
EVENTS="$SCRATCH/events.json"

WITH_UI=0
[[ "${1:-}" == "--ui" ]] && WITH_UI=1

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got '$2', wanted '$3')"; }
has() { grep -q -- "$2" <<<"$1" && ok "$3" || bad "$3 (not in: $(head -c 300 <<<"$1"))"; }
hasnt() { grep -q -- "$2" <<<"$1" && bad "$3" || ok "$3"; }

reset() {
    rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/recordings" "$SCRATCH/notes" "$SCRATCH/chats"
}

# The ordinary fixture: one meeting soon with two guests and an agenda, one
# block with nobody else in it, one all-day, one declined, and two more so the
# cap has something to cut.
write_events() {
    cat > "$EVENTS" <<'JSON'
[
  {"title": "Standup", "in": 12, "minutes": 15,
   "people": ["Ryan Mitchell <ryan@example.com>", "Emily Chen <emily@example.com>"],
   "link": "https://meet.google.com/abc-defg-hij",
   "agenda": "Ship the release notes and agree the date.\nJoin with Google Meet\nmeet.google.com/abc-defg-hij\nDial in: +31 20 555 0100 PIN: 123456"},
  {"title": "Deep work", "in": 45, "minutes": 120},
  {"title": "Company holiday", "in": 60, "allDay": true, "people": ["hr@example.com"]},
  {"title": "Thing I declined", "in": 90, "declined": true, "people": ["x@example.com"]},
  {"title": "Design review", "in": 150, "minutes": 45, "people": ["Sam Okafor <sam@example.com>"]},
  {"title": "Fourth meeting", "in": 300, "people": ["nina@example.com"]},
  {"title": "Fifth meeting", "in": 400, "people": ["nina@example.com"]}
]
JSON
}

echo "== which meetings are listed"
reset; write_events
export LISTEN_FAKE_EVENTS="$EVENTS"
out="$("$BIN" calendar next 2>&1)"
has "$out" "Standup" "the meeting with guests is listed"
has "$out" "in 12 min" "and says how long there is, in minutes under the hour"
has "$out" "Ryan Mitchell, Emily Chen" "with the guests named rather than counted"
has "$out" "\[link\]" "and says there is something to join"
has "$out" "Deep work" "an hour blocked out with nobody else in it is listed too"
has "$out" "Company holiday.*all-day" "an all-day event is not listed, and says why"
has "$out" "Thing I declined.*you declined" "a declined invitation is not listed, and says why"
has "$out" "Fifth meeting.*past the cap" "the cap is stated rather than silent"
is "three at most" "$(sed -n '/^up next:/,/^$/p' <<<"$out" | grep -c '^  ')" "3"
# The order is the calendar's and nothing else: a block does not sort behind a
# meeting, because what is next is what is next.
is "and they are in the order they happen" \
   "$(sed -n '/^up next:/,/^$/p' <<<"$out" | grep '^  ' | sed -n '2p' \
      | grep -c 'Deep work')" "1"

echo
echo "== how far ahead, and how late"
reset; mkdir -p "$SCRATCH"
# 5 minutes in, 20 minutes in, and 13 hours out: the two edges of
# `MeetingCalendar.lateness` and the far edge of `horizon`.
cat > "$EVENTS" <<'JSON'
[
  {"title": "Started five ago", "in": -5, "people": ["a@example.com"]},
  {"title": "Started twenty ago", "in": -20, "people": ["b@example.com"]},
  {"title": "Tomorrow afternoon", "in": 780, "people": ["c@example.com"]}
]
JSON
out="$("$BIN" calendar next 2>&1)"
has "$out" "now.*Started five ago" "a meeting you are five minutes late for is still listed, as now"
hasnt "$out" "up next:.*Started twenty ago" "and one twenty minutes in has gone"
has "$out" "Started twenty ago" "though it is still reported as not listed"
hasnt "$out" "up next:.*Tomorrow afternoon" "thirteen hours out is past the horizon"

echo
echo "== what the agent is told"
reset; write_events
out="$("$BIN" calendar next --prompt 2>&1)"
has "$out" "has not happened yet" "the question says the meeting has not happened"
has "$out" "no recording or transcript" "and that there is nothing of it to find"
has "$out" "Ryan Mitchell (ryan@example.com)" "the guests are named with their addresses"
has "$out" "Ship the release notes" "the agenda travels with it"
hasnt "$out" "PIN: 123456" "and the dial-in boilerplate does not"
hasnt "$out" "Join with Google Meet" "nor the join instructions"
has "$out" "name the meeting behind each point" "the question asks for its evidence"

echo
echo "== preparation outlives the invitation"
# A conversation asked ahead of a meeting, and then the meeting is recorded.
# `MeetingCalendar.attach` is the one moment a folder and an invitation are
# known to be the same meeting, and `Chat.adopt` is what it spends that on.
reset
now="$(python3 -c "import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
id="$(python3 -c "import datetime;print(datetime.datetime.now().strftime('%Y-%m-%d-%H%M%S')+'-ZZZZ')")"
cat > "$EVENTS" <<JSON
[ {"title": "Standup", "in": 0, "minutes": 15,
   "people": ["Ryan Mitchell <ryan@example.com>"]} ]
JSON
event_id="$("$BIN" calendar next 2>/dev/null >/dev/null; echo "fake-0-Standup")"
mkdir -p "$SCRATCH/recordings/$id"
cat > "$SCRATCH/recordings/$id/metadata.json" <<JSON
{ "id": "$id", "recorded_at": "$now", "duration": 900, "title": "Untitled",
  "state": "done", "source": "detected", "room": false }
JSON
cat > "$SCRATCH/chats/prep-1.json" <<JSON
{ "id": "prep-1", "title": "What should I know", "event": "$event_id",
  "event_title": "Standup", "created": "$now", "updated": "$now",
  "turns": [ { "who": "you", "text": "What should I know", "at": "$now" } ] }
JSON
out="$("$BIN" calendar backfill --apply 2>&1)"
has "$out" "Standup" "the recording is matched to the invitation"
is "the conversation asked beforehand now names the recording" \
   "$(python3 -c "
import json; c=json.load(open('$SCRATCH/chats/prep-1.json'))
print('$id' in (c.get('recordings') or []))")" "True"
is "and still names the event it was asked ahead of" \
   "$(python3 -c "
import json; print(json.load(open('$SCRATCH/chats/prep-1.json')).get('event'))")" "$event_id"
before="$(python3 -c "import json;print(json.load(open('$SCRATCH/chats/prep-1.json'))['updated'])")"
"$BIN" calendar backfill --apply --refresh >/dev/null 2>&1
is "a second pass adopts nothing twice" \
   "$(python3 -c "
import json; c=json.load(open('$SCRATCH/chats/prep-1.json'))
print((c.get('recordings') or []).count('$id'))")" "1"
is "and does not reorder History by touching it" \
   "$(python3 -c "import json;print(json.load(open('$SCRATCH/chats/prep-1.json'))['updated'])")" "$before"

if [[ $WITH_UI -eq 0 ]]; then
    echo
    rm -rf "$SCRATCH"
    echo "$pass passed, $fail failed  (the window was not tested; --ui does that)"
    [[ $fail -eq 0 ]]
    exit
fi

echo
echo "== the window"
AX=".xcbuild/tools/axprobe"
mkdir -p .xcbuild/tools
if [[ ! -x "$AX" || tools/axprobe.swift -nt "$AX" ]]; then
    swiftc -O tools/axprobe.swift -o "$AX" || { echo "could not build axprobe"; exit 1; }
fi
reset; write_events
# Launched directly and never through `open`, for the reason CLAUDE.md gives:
# Launch Services prefers /Applications and drops the environment with it, so
# the real library would be opened instead of this one.
"$BIN" >/tmp/listen-verify-upcoming.log 2>&1 &
PID=$!
sleep 6
texts="$("$AX" texts $PID)"
probe=$?
if [[ $probe -eq 3 ]]; then
    kill $PID 2>/dev/null
    echo "  this terminal has no Accessibility permission; the window was not tested"
    rm -rf "$SCRATCH"; exit 1
fi
# Exit 4 is an empty tree, which is a sleeping display or a window that has not
# drawn yet, and it is **not** a failing assertion: every negative check below
# would pass on nothing and every positive one would fail for the same reason.
# Measured: one run in four came up empty at five seconds and reported ten
# failures that were all this. One retry, then give up loudly.
if [[ $probe -eq 4 ]]; then
    sleep 6
    texts="$("$AX" texts $PID)"
    probe=$?
fi
if [[ $probe -eq 4 ]]; then
    kill $PID 2>/dev/null
    echo "  the window never drew (a sleeping display empties the AX tree);"
    echo "  the window was not tested"
    rm -rf "$SCRATCH"; exit 1
fi
# A sleeping display empties every window's subtree with no error, so absence
# would pass on nothing. The heading is the presence check.
has "$texts" "Up next" "the section is at the top of the library"
has "$texts" "Standup, in 12 min, Ryan Mitchell, Emily Chen" \
    "the row counts down, and the faces on it say who is coming to a reader who cannot see them"
has "$texts" "in 12 min" "the countdown is on the row as text"
has "$texts" "Deep work" "and so is an hour blocked out with nobody in it"

"$AX" selectrow $PID "Standup" >/dev/null
sleep 2
page="$("$AX" texts $PID)"
has "$page" "Today.*to.*Fake / Work" "the page says when it is and which calendar it came from"
has "$page" "AXButton.*Join" "there is a way to join it"
has "$page" "AXButton.*Prepare" "and a way to prepare that does not wait for the caret"
has "$page" "INVITED" "the guests are on the page"
has "$page" "ryan@example.com" "with the address the library would know them by"
has "$page" "Ship the release notes" "the agenda is on the page"
hasnt "$page" "PIN: 123456" "and the dial-in boilerplate is not"
has "$page" "No recordings with them yet" "an empty library says so rather than showing nothing"

# A block's page says what it is rather than heading an empty guest list, and
# offers nothing to prepare, because every question `MeetingBrief` sends is
# about the people invited.
"$AX" selectrow $PID "Deep work" >/dev/null
sleep 2
block="$("$AX" texts $PID)"
has "$block" "An hour you blocked out" "a block says what it is"
hasnt "$block" "INVITED" "and heads no guest list it cannot fill"
hasnt "$block" "AXButton.*Prepare" "and offers nothing to prepare about nobody"
"$AX" selectrow $PID "Standup" >/dev/null
sleep 2

# The trap `.agents/notes/window.md` records against notes: the ellipsis said
# "No recording selected" over a page that is not a recording.
# **Opened until it is open, up to three times.** A menu's items are in the
# tree only while it is up, and reading it mid-animation is indistinguishable
# from a menu that was never built, which is the failure this whole assertion
# is about. Observed here: a fixed one second failed about half the runs and
# two seconds still failed one in three, with the same build passing when run
# by hand, so the wait is not the thing to tune.
# **Activate first, then open once, then read until it is there.**
#
# Two separate traps, and only one of them is timing. `AXShowMenu` on a toolbar
# item in a window that is not key succeeds and does nothing, and this script
# has launched and killed several apps by the time it gets here, so focus can
# be anywhere: the same command by hand worked every time, which is what made
# it look like a wait that was too short. And asking again is not a retry,
# because `AXShowMenu` on an open menu closes it, so a loop around the command
# toggles the thing it is waiting for. So: activate, open once, and poll the
# tree, which is the only one of the three that is safe to repeat.
"$AX" activate $PID >/dev/null 2>&1
"$AX" showmenu $PID "Actions" >/dev/null 2>&1
menu=""
for attempt in 1 2 3 4 5; do
    sleep 1
    menu="$("$AX" texts $PID | grep AXMenuItem)"
    grep -q "Join Meeting" <<<"$menu" && break
done
has "$menu" "Join Meeting" "the actions menu is the meeting's"
has "$menu" "Prepare for This Meeting" "and offers the preparation"
hasnt "$menu" "No recording selected" "and never claims a recording is missing"

{ kill $PID; wait $PID; } 2>/dev/null
sleep 1
"$BIN" >/dev/null 2>&1 &
PID=$!
sleep 6
"$AX" settext $PID "Search" "review" >/dev/null 2>&1
sleep 2
searched="$("$AX" texts $PID)"
hasnt "$searched" "Up next" "a search takes the section away, because none of it has been said yet"
{ kill $PID; wait $PID; } 2>/dev/null

echo
echo "== prepare, end to end"
# The whole spine of the feature in one gesture: press Prepare on a meeting
# that has not happened, and the question reaches the agent and the answer
# reaches the page, with `chat.json` naming the invitation it was asked ahead
# of. It needs a stub agent and therefore its own preferences, so this is the
# one case on the uitest bundle copy. See CLAUDE.md, "Running setup again
# without spending the real preferences".
UI="$SCRATCH/uitest"
COPY="$UI/T.app"
mkdir -p "$UI/bin" "$UI/library/chats"
cp -R Listen.app "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    "$COPY/Contents/Info.plist" >/dev/null
codesign --force --sign - --deep "$COPY" 2>/dev/null
# `verify_ask_handoff.sh`'s stub, cut down: the deltas are the answer, because
# a streaming run skips the finished `assistant` message's text blocks.
cat > "$UI/bin/claude" <<'STUB'
#!/bin/bash
case "$1" in
  --version) echo "2.1.212 (Claude Code)";;
  auth) echo '{"loggedIn": true, "email": "stub@example.com"}';;
  --print|*)
    echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
    printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}}\n' \
      "Nothing in your library mentions them yet."
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.0,"duration_ms":90}'
    exit 0;;
esac
STUB
chmod +x "$UI/bin/claude"
defaults delete com.mgo.listen-uitest >/dev/null 2>&1
defaults write com.mgo.listen-uitest onboarded -bool true
  # **Detection off, or the copy records the room in the middle of the test.**
  # Meeting detection is on by default and a copy inherits it, so a call
  # anywhere on this Mac puts the window on the recording screen with "Are you
  # in a meeting?" over it. Measured: it is what made three assertions in
  # `verify_ask_states.sh` fail for several builds against an app that was
  # working, and a run that does this captures the microphone unasked.
  defaults write com.mgo.listen-uitest autoDetectMeetings -bool false
defaults write com.mgo.listen-uitest askEnabled -bool true
defaults write com.mgo.listen-uitest agentPath_claude -string "$UI/bin/claude"
defaults write com.mgo.listen-uitest agentPath_codex -string "/nonexistent/codex"
defaults write com.mgo.listen-uitest agentProviders -data 5b5d
LISTEN_LIBRARY="$UI/library" SHELL=/usr/bin/false LISTEN_NO_TELEMETRY=1 \
    "$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
PID=$!
sleep 7
"$AX" selectrow $PID "Standup" >/dev/null
sleep 2
"$AX" press $PID "Prepare" >/dev/null
check=$?
[[ $check -eq 0 ]] && ok "Prepare is pressable" || bad "Prepare could not be pressed"
sleep 6
answered="$("$AX" texts $PID)"
has "$answered" "Go through my recordings with these people" "the question the chip would send is what was asked"
has "$answered" "Nothing in your library mentions them yet" "and the answer lands on the page"
{ kill $PID; wait $PID; } 2>/dev/null
sleep 1
is "the conversation names the invitation it was asked ahead of" \
   "$(python3 -c "
import glob, json
for path in glob.glob('$UI/library/chats/*.json'):
    c = json.load(open(path))
    if c.get('event'): print(c['event_title']); break
else: print('none')")" "Standup"
defaults delete com.mgo.listen-uitest >/dev/null 2>&1

echo
rm -rf "$SCRATCH"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
