#!/bin/bash
# The MCP server's read surface, as assertions.
#
# Tags live in `verify_note_tags.sh`, person and project memory in
# `tools/verify_context.py`, and the dictionary tools in `verify_dictionary.sh`.
# Everything else the server answers had no script at all, which is what this is:
# the provenance an agent needs before it believes a transcript, note bodies
# being searchable, the calendar, conversations, retitling and its guard, and
# the allowlist refusing each write by name.
#
# **The fixture is synthetic**, for the reason `verify_dictionary.sh` gives: what
# is under test is what the server projects, and a library copied out of a real
# one grows a title or a speaker and fails six assertions for that instead.
#
# Needs no calendar and no invitation: `LISTEN_FAKE_EVENTS` stands in, with
# starts in minutes from now so the fixture cannot expire at midnight. The one
# case it cannot reach is a Mac with no calendar permission at all, which is a
# TCC subject rather than a setting, so that assertion runs against a copy of
# the app under its own bundle identifier.
set -u

export LISTEN_NO_KEYCHAIN=1
export LISTEN_NO_TELEMETRY=1

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIR="${TMPDIR:-/tmp}/listen-verify-mcp"
export LISTEN_LIBRARY="$DIR/library"
LISTEN="$ROOT/Listen.app/Contents/MacOS/Listen"
COPY="$DIR/T.app"
EVENTS="$DIR/events.json"

[ -x "$LISTEN" ] || { echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

# One `listen mcp` process per call, which is what a client does anyway. Built
# in python because a tool's arguments are JSON and quoting them through bash
# twice is how a test starts asserting on its own escaping. The same helper
# `verify_dictionary.sh` uses.
mcp() {   # tool, json arguments, optional --tools allowlist, optional binary
  python3 - "${4:-$LISTEN}" "$1" "$2" "${3:-}" <<'PY'
import json, subprocess, sys
listen, tool, args, tools = sys.argv[1:5]
cmd = [listen, "mcp"] + (["--tools", tools] if tools else [])
lines = [json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {}}),
         json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                     "params": {"name": tool, "arguments": json.loads(args)}})]
p = subprocess.run(cmd, input="\n".join(lines) + "\n", capture_output=True, text=True)
for line in p.stdout.splitlines():
    m = json.loads(line)
    if m.get("id") != 1:
        continue
    r = m.get("result", {})
    print(("ERROR: " if r.get("isError") else "")
          + r.get("content", [{}])[0].get("text", ""))
PY
}

# ---------------------------------------------------------------------------
# The fixture
# ---------------------------------------------------------------------------

rm -rf "$DIR"
mkdir -p "$LISTEN_LIBRARY/recordings" "$LISTEN_LIBRARY/notes" "$LISTEN_LIBRARY/chats"

recording() {   # id, title, then key=value metadata, then -- , then sentences
  python3 - "$LISTEN_LIBRARY/recordings/$1" "$@" <<'PY'
import json, os, sys
dir = sys.argv[1]
rest = sys.argv[2:]
id, title = rest[0], rest[1]
split = rest.index("--")
extra = dict(kv.split("=", 1) for kv in rest[2:split])
sentences = rest[split + 1:]
os.makedirs(dir, exist_ok=True)
segments = [{"start": i * 5.0, "end": i * 5.0 + 4.0, "speaker": "Me", "text": s}
            for i, s in enumerate(sentences)]
json.dump({"segments": segments, "duration": len(segments) * 5.0,
           "model": "mlx-community/parakeet-tdt-0.6b-v3", "wordLevel": False,
           "cleanup": {}, "dictionary": {}},
          open(f"{dir}/transcript.json", "w"), indent=1, sort_keys=True)
json.dump([{"start": s["start"], "end": s["end"], "speaker": "Me", "text": s["text"]}
           for s in segments],
          open(f"{dir}/turns.json", "w"), indent=1, sort_keys=True)
meta = {"id": id, "title": title, "recorded_at": "2026-09-01T10:00:00Z",
        "duration": len(segments) * 5.0, "source": "mac", "state": "done"}
for key, value in extra.items():
    meta[key] = True if value == "true" else value
json.dump(meta, open(f"{dir}/metadata.json", "w"), indent=1, sort_keys=True)
PY
}

# One with every provenance field set, one with none, one nobody has named.
recording 2026-09-01-100000-AAAA "Pilot kickoff" \
    asr_model=mlx-community/parakeet-tdt-0.6b-v2 app_name="Google Chrome" \
    calendar_event_id="fake-0-Pilot kickoff" transcribed_by=mb-flame \
    -- "We agreed the pilot stays monthly."
recording 2026-09-01-110000-BBBB "Voice memo" source=phone \
    -- "A note to myself about procurement."
recording 2026-09-01-120000-CCCC "Untitled" \
    -- "Nobody has named this recording."

note() {   # slug, title, source, recording, body
  { printf -- '---\ntitle: "%s"\ncreated: 2026-09-02T09:00:00Z\n' "$2"
    printf 'updated: 2026-09-02T09:00:00Z\nsource: %s\nrecordings: ["%s"]\n---\n\n' "$3" "$4"
    printf '%s\n' "$5"
  } > "$LISTEN_LIBRARY/notes/$1.md"
}
note pilot-scope "Pilot scope" agent 2026-09-01-100000-AAAA \
"## What was decided

The pilot stays monthly, and we upsell the team plan rather than discounting."
note procurement-timeline "Procurement timeline" you 2026-09-01-110000-BBBB \
"Legal review takes three weeks."

python3 - "$LISTEN_LIBRARY/chats" <<'PY'
import json, os, sys
dir = sys.argv[1]
os.makedirs(dir, exist_ok=True)
json.dump({"title": "What did we agree on pricing?", "backend": "claude",
           "created": "2026-09-02T11:00:00Z", "updated": "2026-09-02T11:00:30Z",
           "recordings": ["2026-09-01-100000-AAAA"], "person": "Marcia",
           "turns": [
             {"who": "you", "text": "What did we agree on pricing?",
              "at": "2026-09-02T11:00:00Z"},
             {"who": "agent", "text": "The pilot stays monthly.",
              "at": "2026-09-02T11:00:30Z",
              "steps": [{"kind": "activity", "text": "Reading the transcript"},
                        {"kind": "text", "text": "The pilot stays monthly."}]},
           ]}, open(f"{dir}/2026-09-02-110000-CH01.json", "w"), indent=1)
PY

cat > "$EVENTS" <<'JSON'
[
  {"title": "Pilot kickoff", "in": 35, "minutes": 60,
   "people": ["Marcia Lima <marcia@example.com>"],
   "link": "https://meet.google.com/abc-defg-hij",
   "agenda": "Walk through the scope and the pricing.\nJoin Zoom Meeting\nhttps://zoom.us/j/1"},
  {"title": "Focus block", "in": 120, "minutes": 60},
  {"title": "Design review", "in": 200, "minutes": 45,
   "people": ["Sam Okafor <sam@example.com>"]}
]
JSON

# ---------------------------------------------------------------------------
echo "1. get_recording says how far to trust the transcript"
# ---------------------------------------------------------------------------
full=$(mcp get_recording '{"recording_id":"2026-09-01-100000-AAAA"}')
# The encoder escapes the slash in a model path, so match the half with none.
echo "$full" | grep -q 'parakeet-tdt-0.6b-v2'
check $? "which model read it, because an older one misreads the language silently"
echo "$full" | grep -q '"app" : "Google Chrome"'
check $? "the app the call was in, which is the evidence behind \"Call with\""
# The same id the fake event gets, so the calendar row below can find it.
echo "$full" | grep -q '"calendar_event_id" : "fake-0-Pilot kickoff"'
check $? "the meeting it was matched to"
echo "$full" | grep -q '"transcribed_by" : "mb-flame"'
check $? "and the device that did the work"

phone=$(mcp get_recording '{"recording_id":"2026-09-01-110000-BBBB"}')
echo "$phone" | grep -q '"recorded_by" : "phone"'
check $? "a phone recording says so, because its voices were never named"
echo "$phone" | grep -q '"asr_model"'
[ "$?" = "1" ]
check $? "and a field the library does not have is absent rather than null"

# The listing stays thin: `brief` feeds fifty rows at a time.
mcp list_recordings '{"limit":3}' | grep -q '"asr_model"'
[ "$?" = "1" ]
check $? "none of it is on the list_recordings rows"

# ---------------------------------------------------------------------------
echo "2. note bodies are searchable, which nothing else here does"
# ---------------------------------------------------------------------------
hit=$(mcp list_notes '{"query":"upsell the team plan"}')
echo "$hit" | grep -q '"slug" : "pilot-scope"'
check $? "a phrase in a note body finds the note"
echo "$hit" | grep -q '"excerpt"'
check $? "and comes back with an excerpt"
echo "$hit" | grep -q "## What was decided"
[ "$?" = "1" ]
check $? "flattened, so a heading marker is not three lines of JSON"
echo "$hit" | grep -q '"matched" : "body"'
check $? "and says the hit was in the body"

title=$(mcp list_notes '{"query":"Procurement"}')
echo "$title" | grep -q '"matched" : "title"'
check $? "a title-only match says so"
echo "$title" | grep -q '"excerpt"'
[ "$?" = "1" ]
check $? "and grows no excerpt repeating the name already on the row"

mcp list_notes '{"query":"nothing in any note"}' | grep -q '"notes" : \[' \
  && ! mcp list_notes '{"query":"nothing in any note"}' | grep -q '"slug"'
check $? "a query matching nothing returns an empty list, not everything"

# ANDed with the other two, like every other filter on this tool.
mcp list_notes '{"query":"monthly","recording_id":"2026-09-01-110000-BBBB"}' \
  | grep -q '"slug"'
[ "$?" = "1" ]
check $? "a query and a recording_id narrow together"

# ---------------------------------------------------------------------------
echo "3. the calendar, which the agent could not see at all"
# ---------------------------------------------------------------------------
export LISTEN_FAKE_EVENTS="$EVENTS"
up=$(mcp list_upcoming '{}')
echo "$up" | grep -q '"authorized" : true'
check $? "the list says whether Listen can see the calendar"
echo "$up" | grep -q '"title" : "Pilot kickoff"'
check $? "a meeting with guests and a link is listed"
echo "$up" | grep -q '"kind" : "call"'
check $? "and named a call"
echo "$up" | grep -q '"kind" : "inPerson"'
check $? "one with guests and nowhere to click is in person"
echo "$up" | grep -q "Focus block"
[ "$?" = "1" ]
check $? "an hour blocked out with nobody in it is not a meeting by default"
mcp list_upcoming '{"include_blocked":true}' | grep -q '"kind" : "blocked"'
check $? "and is listed when asked for"
echo "$up" | grep -q "zoom.us"
[ "$?" = "1" ]
check $? "the agenda stops where the dial-in boilerplate begins"
echo "$up" | grep -q '"agenda" : "Walk through the scope and the pricing."'
check $? "and keeps what was actually written"
echo "$up" | grep -q '"horizon_hours" : 12'
check $? "the twelve hour horizon is stated rather than implied"

# The recording of a meeting is named on its row rather than the row being
# dropped: a tool has no second place to show the live meeting, so "you are in
# this one, and here is its id" is the more useful answer.
echo "$up" | grep -q '"recording_id" : "2026-09-01-100000-AAAA"'
check $? "a meeting Listen already has a recording of names it"

ev=$(echo "$up" | python3 -c "import json,sys;print(json.load(sys.stdin)['events'][0]['event_id'])")
one=$(mcp get_event "{\"event_id\":\"$ev\"}")
echo "$one" | grep -q "It has not happened yet"
check $? "get_event answers with the sentence the Prepare button already sends"
mcp get_event '{"event_id":"no-such-event"}' | grep -q "only reaches twelve hours ahead"
check $? "an id outside the window is not found rather than silently empty"

# ---------------------------------------------------------------------------
echo "4. conversations, which only the window could read"
# ---------------------------------------------------------------------------
chats=$(mcp list_conversations '{}')
echo "$chats" | grep -q '"title" : "What did we agree on pricing?"'
check $? "a conversation is listed by what was asked"
echo "$chats" | grep -q '"person" : "Marcia"'
check $? "with the person it was scoped to"
mcp list_conversations '{"person":"Nobody"}' | grep -q '"conversation_id"'
[ "$?" = "1" ]
check $? "and the person filter narrows"

turns=$(mcp read_conversation '{"conversation_id":"2026-09-02-110000-CH01"}')
echo "$turns" | grep -q '"who" : "you"'
check $? "reading one gives the question"
echo "$turns" | grep -q "The pilot stays monthly."
check $? "and the answer"
echo "$turns" | grep -q "Reading the transcript"
[ "$?" = "1" ]
check $? "but not the activity line, which is progress rather than content"
mcp read_conversation '{"conversation_id":"nope"}' | grep -q "no conversation"
check $? "an unknown id is refused"

# ---------------------------------------------------------------------------
echo "5. naming a recording, and the two names that outrank it"
# ---------------------------------------------------------------------------
mcp set_recording_title \
  '{"recording_id":"2026-09-01-120000-CCCC","title":"Procurement and the pilot"}' \
  | grep -q '"title_source" : "model"'
check $? "an unnamed recording can be named, and the name is marked as derived"
grep -q "Procurement and the pilot" "$LISTEN_LIBRARY/recordings/2026-09-01-120000-CCCC/metadata.json"
check $? "and it reaches metadata.json"

# A title with no source is one a person typed, and `mayTitle` freezes it.
mcp set_recording_title \
  '{"recording_id":"2026-09-01-100000-AAAA","title":"Something else"}' \
  | grep -q "does not write over that"
check $? "a name the user typed is refused, with whose it is"
grep -q '"title": "Pilot kickoff"' "$LISTEN_LIBRARY/recordings/2026-09-01-100000-AAAA/metadata.json"
check $? "and nothing changed"

mcp set_recording_title '{"recording_id":"2026-09-01-120000-CCCC","clear":true}' \
  | grep -q '"title" : "Untitled"'
check $? "clearing goes back to the floor"
mcp set_recording_title '{"recording_id":"2026-09-01-120000-CCCC"}' \
  | grep -q "needs .title., or .clear"
check $? "and neither a title nor clear is refused rather than guessed at"

# ---------------------------------------------------------------------------
echo "6. the allowlist, which is the only thing enforcing any of this"
# ---------------------------------------------------------------------------
reads="list_recordings,get_recording,list_notes,list_upcoming,get_event"
reads="$reads,list_conversations,read_conversation,get_context_status,list_dictionary"
for tool in set_recording_title suggest_context_correction; do
  mcp "$tool" '{"recording_id":"x"}' "$reads" \
    | grep -q "not one of the tools this session may call"
  check $? "a read-only session cannot call $tool"
done
mcp list_upcoming '{}' "$reads" | grep -q '"authorized"'
check $? "and the reads it was given still work"

# ---------------------------------------------------------------------------
echo "7. a Mac with no calendar permission"
# ---------------------------------------------------------------------------
# A new bundle identifier is a new TCC subject, which is the only way to reach
# this branch: there is no setting for "pretend the calendar is denied", and the
# whole point of the field is that an empty list and a denied calendar are
# different answers that look identical. See CLAUDE.md on the uitest copy.
cp -R "$ROOT/Listen.app" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    "$COPY/Contents/Info.plist" >/dev/null
codesign --force --sign - --deep "$COPY" 2>/dev/null
unset LISTEN_FAKE_EVENTS
denied=$(mcp list_upcoming '{}' "" "$COPY/Contents/MacOS/Listen")
if echo "$denied" | grep -q '"authorized" : false'; then
    ok "a Mac that cannot see the calendar says so"
    echo "$denied" | grep -q '"events" : \[' && echo "$denied" | grep -q '"title"'
    [ "$?" = "1" ]
    check $? "and its empty list is not mistaken for a clear day"
    mcp get_event '{"event_id":"x"}' "" "$COPY/Contents/MacOS/Listen" \
      | grep -q "permission, not an empty calendar"
    check $? "get_event names the permission rather than the meeting"
else
    # Not a failure, and worth stating: a binary started from a shell is not
    # the TCC subject, the terminal is, so the real app and a copy under a new
    # bundle identifier both answer with whatever the terminal was granted. This
    # branch is reachable only where the responsible process genuinely lacks the
    # permission, which is the app itself and a client such as Claude Desktop
    # spawning `listen mcp`. That is the case the field exists for, and it
    # cannot be driven from here.
    echo "  SKIP: a shell-launched CLI inherits this terminal's calendar grant" >&2
fi
rm -rf "$COPY"

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
