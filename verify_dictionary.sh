#!/bin/bash
# The dictionary, as assertions: the backfill over transcripts that already
# exist, the two guards that keep the sounds-like matcher off ordinary English,
# the suggestions collected from hand edits, and the pane that shows all of it.
#
# **The fixture is synthetic, and that is deliberate.** Every other script here
# copies real recordings, which is right when the thing under test is the
# pipeline. This one is about text rules, and the sentences it needs are exactly
# the ones that break them: "and it knows the email address" has to survive a
# term called Kinsight, and "kin site" has to be rewritten by it. Both are one
# line of JSON, and a fixture that states its own cases cannot go stale the way
# a copied library does.
#
# The AX half runs on the uitest bundle copy against the same scratch library,
# so the real preferences are never touched. `LISTEN_PANEL=settings:dictionary`
# opens the pane directly.
set -u

export LISTEN_NO_KEYCHAIN=1
export LISTEN_NO_TELEMETRY=1
export SHELL=/usr/bin/false

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE="$ROOT/.xcbuild/tools/axprobe"
DIR="${TMPDIR:-/tmp}/listen-verify-dictionary"
COPY="$DIR/T.app"
export LISTEN_LIBRARY="$DIR/library"
LISTEN="$ROOT/Listen.app/Contents/MacOS/Listen"

[ -x "$LISTEN" ] || { echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

field() {
  echo "$1" | awk -F'\t' -v want="$2" \
    '{ for (i = 1; i <= NF; i++) if ($i == want) f = 1 } END { exit f ? 0 : 1 }'
}

# ---------------------------------------------------------------------------
# The fixture
# ---------------------------------------------------------------------------

rm -rf "$DIR"; mkdir -p "$LISTEN_LIBRARY/recordings"

recording() {   # id, then one sentence per argument
  local id="$1"; shift
  local dir="$LISTEN_LIBRARY/recordings/$id"
  mkdir -p "$dir"
  python3 - "$dir" "$id" "$@" <<'PY'
import json, sys
dir, id, *sentences = sys.argv[1:]
segments = [{"start": i * 5.0, "end": i * 5.0 + 4.0, "speaker": "Me", "text": s}
            for i, s in enumerate(sentences)]
json.dump({"segments": segments, "duration": len(segments) * 5.0,
           "model": "mlx-community/parakeet-tdt-0.6b-v3", "wordLevel": False,
           "cleanup": {}, "dictionary": {}},
          open(f"{dir}/transcript.json", "w"), indent=1, sort_keys=True)
json.dump([{"start": s["start"], "end": s["end"], "speaker": "Me", "text": s["text"]}
           for s in segments],
          open(f"{dir}/turns.json", "w"), indent=1, sort_keys=True)
json.dump({"id": id, "title": f"Meeting {id[-4:]}", "recorded_at": "2026-09-01T10:00:00Z",
           "duration": len(segments) * 5.0, "source": "mac", "state": "done"},
          open(f"{dir}/metadata.json", "w"), indent=1, sort_keys=True)
PY
}

# The three sentences the matcher used to destroy, and the two it exists for.
recording 2026-09-01-100000-AAAA \
  "And it knows the email address of everybody in the room." \
  "I know I said we would talk tomorrow." \
  "That is how you Kinsight to work for them."
recording 2026-09-01-110000-BBBB \
  "We talked about kin site yesterday and the kinside dashboard." \
  "We use can site for that, and I hired an ex-McKinsey guy." \
  "Their own keys or their own cloud code."
recording 2026-09-01-120000-CCCC \
  "Nothing in this recording needs changing at all."

cat > "$LISTEN_LIBRARY/dictionary.json" <<'JSON'
{
  "version" : 1,
  "entries" : [
    { "kind": "term", "text": "Kinsight", "replacement": "",
      "caseSensitive": false, "enabled": true },
    { "kind": "correction", "text": "cloud code", "replacement": "Claude Code",
      "caseSensitive": false, "enabled": true },
    { "kind": "term", "text": "Beehiiv", "replacement": "",
      "caseSensitive": false, "enabled": true },
    { "kind": "term", "text": "Goossens", "replacement": "",
      "caseSensitive": false, "enabled": true },
    { "kind": "term", "text": "flyinpublic", "replacement": "",
      "caseSensitive": false, "enabled": true }
  ]
}
JSON

# ---------------------------------------------------------------------------
echo "1. the sounds-like matcher stays off ordinary English"
# ---------------------------------------------------------------------------
# Soundex is lossy on purpose, so "knows the" and "know I said" both code
# exactly as "Kinsight" and neither joined form is in the lexicon to be
# refused. Before the spelling guard these rewrote real sentences, and one of
# them deleted a word. See `accepts(phrase:as:words:joined:)`.
try() { "$LISTEN" dictionary test "$1" 2>/dev/null; }

[ "$(try "and it knows the email address")" = "and it knows the email address" ]
check $? "\"knows the\" is left alone"
[ "$(try "I know I said we will talk")" = "I know I said we will talk" ]
check $? "\"know I said\" is left alone"
[ "$(try "how you Kinsight to work")" = "how you Kinsight to work" ]
check $? "a span that already holds the term is left alone, and keeps its \"to\""
[ "$(try "we talked about kin site")" = "we talked about Kinsight" ]
check $? "\"kin site\" is still rewritten, which is what the feature is for"
[ "$(try "the kinside dashboard")" = "the Kinsight dashboard" ]
check $? "and so is a one-word mishearing"
[ "$(try "we use can site for that")" = "we use can site for that" ]
check $? "\"can site\" stays refused, as the notes say it should"
[ "$(try "an ex-McKinsey guy")" = "an ex-McKinsey guy" ]
check $? "McKinsey is not a misspelt Kinsight"
# Soundex collapses b and v, so "Bye-bye" codes exactly as "Beehiiv" and
# neither is in the lexicon. The preview over a real library wanted to rewrite
# it in 17 recordings.
[ "$(try "Bye-bye.")" = "Bye-bye." ]
check $? "\"Bye-bye\" is not a misheard Beehiiv"
[ "$(try "we use beehive")" = "we use beehive" ]
check $? "and an English word that sounds like a term is never swapped"
[ "$(try "you know I got depressed")" = "you know I got depressed" ]
check $? "a one-letter word means the span is a sentence, not a name"
# The three the feature exists for, which every guard above has to leave alone.
[ "$(try "ask Gusens about it")" = "ask Goossens about it" ]
check $? "\"Gusens\" still becomes \"Goossens\""
[ "$(try "meet me at fly in public")" = "meet me at flyinpublic" ]
check $? "three words still close up into one"
[ "$(try "we talked about kim site")" = "we talked about Kinsight" ]
check $? "and a span is judged joined up, so the speaker's space costs nothing"

# ---------------------------------------------------------------------------
echo "2. the backfill previews, applies once, and is idempotent"
# ---------------------------------------------------------------------------
before=$(cat "$LISTEN_LIBRARY/recordings/2026-09-01-110000-BBBB/transcript.json")
dry=$("$LISTEN" dictionary backfill 2>&1)
echo "$dry" | grep -q "would change"
check $? "the dry run says what it would change"
[ "$(cat "$LISTEN_LIBRARY/recordings/2026-09-01-110000-BBBB/transcript.json")" = "$before" ]
check $? "and writes nothing"
echo "$dry" | grep -q "nothing was written"
check $? "and says so"

"$LISTEN" dictionary backfill --apply >/dev/null 2>&1
grep -q "Kinsight dashboard" "$LISTEN_LIBRARY/recordings/2026-09-01-110000-BBBB/transcript.json"
check $? "--apply rewrites the transcript"
grep -q "Kinsight dashboard" "$LISTEN_LIBRARY/recordings/2026-09-01-110000-BBBB/turns.json"
check $? "and rebuilds turns.json from the same segments"
grep -q "Claude Code" "$LISTEN_LIBRARY/recordings/2026-09-01-110000-BBBB/transcript.json"
check $? "corrections are applied too"
grep -q "knows the email address" "$LISTEN_LIBRARY/recordings/2026-09-01-100000-AAAA/transcript.json"
check $? "and the sentences the matcher must not touch are untouched"

python3 - <<'PY'; check $? "the fires are counted into the transcript"
import json, os
p = os.environ["LISTEN_LIBRARY"] + "/recordings/2026-09-01-110000-BBBB/transcript.json"
counts = json.load(open(p))["dictionary"]
raise SystemExit(0 if counts.get("term:Kinsight") == 2
                 and counts.get("correction:cloud code") == 1 else 1)
PY

# A backfill is what the pipeline would have written, not a hand correction, so
# it must not raise the flag that makes Transcribe Again warn about losing work
# nobody did. See `DictionaryBackfill.apply`.
[ -z "$(ls "$LISTEN_LIBRARY"/recordings/*/*.raw.json.bak 2>/dev/null)" ]
check $? "no .raw.json.bak: a backfill is not a human correction"

"$LISTEN" dictionary backfill 2>&1 | grep -q "nothing to change"
check $? "a second pass finds nothing"
python3 - <<'PY'; check $? "and adds nothing to the counts"
import json, os
p = os.environ["LISTEN_LIBRARY"] + "/recordings/2026-09-01-110000-BBBB/transcript.json"
counts = json.load(open(p))["dictionary"]
raise SystemExit(0 if counts.get("term:Kinsight") == 2 else 1)
PY

"$LISTEN" dictionary backfill 2026-09-01-120000-CCCC 2>&1 | grep -q "1 recording(s) read"
check $? "one recording can be backfilled on its own"

# ---------------------------------------------------------------------------
echo "3. a hand edit teaches the dictionary"
# ---------------------------------------------------------------------------
one="Nothing in this recording needs changing at all."
"$LISTEN" edit 2026-09-01-120000-CCCC "$one" \
  "Nothing in this recording needs amending at all." >/dev/null 2>&1
"$LISTEN" dictionary suggestions 2>/dev/null | grep -q "changing -> amending"
check $? "one word replaced in a sentence becomes a suggestion"

# Rewriting a whole sentence is a person fixing the meaning. Turning that into
# a rule that rewrites the library would be absurd.
"$LISTEN" edit 2026-09-01-120000-CCCC "Nothing in this recording needs amending at all." \
  "A completely different sentence about something else." >/dev/null 2>&1
[ "$("$LISTEN" dictionary suggestions 2>/dev/null | grep -c '\->')" = "1" ]
check $? "a wholesale rewrite teaches nothing"

python3 - <<'PY'; check $? "the pair carries the sentence it came from"
import json, os
d = json.load(open(os.environ["LISTEN_LIBRARY"] + "/dictionary-suggestions.json"))
s = d["suggestions"][0]
raise SystemExit(0 if s["heard"] == "changing" and s["meant"] == "amending"
                 and "recording" in s["example"] and s["source"] == "edit" else 1)
PY

"$LISTEN" dictionary suggestions --add changing >/dev/null 2>&1
python3 - <<'PY'; check $? "--add writes it as an exact correction"
import json, os
e = json.load(open(os.environ["LISTEN_LIBRARY"] + "/dictionary.json"))["entries"]
raise SystemExit(0 if any(x["kind"] == "correction" and x["text"] == "changing"
                          and x["replacement"] == "amending" for x in e) else 1)
PY
[ -z "$("$LISTEN" dictionary suggestions 2>/dev/null | grep 'changing ->')" ]
check $? "and takes the row away"

# The rule now covers the pair, so making the same edit again must not offer it
# back: `pending` re-checks against the dictionary as it stands.
"$LISTEN" edit 2026-09-01-100000-AAAA "I know I said we would talk tomorrow." \
  "I know I said we would talk tomorrow, changing." >/dev/null 2>&1
"$LISTEN" edit 2026-09-01-100000-AAAA "I know I said we would talk tomorrow, changing." \
  "I know I said we would talk tomorrow, amending." >/dev/null 2>&1
[ -z "$("$LISTEN" dictionary suggestions 2>/dev/null | grep 'changing ->')" ]
check $? "a pair the dictionary already handles is not offered again"

"$LISTEN" dictionary suggestions --dismiss nonexistent 2>&1 | grep -q "no suggestion"
check $? "dismissing something that is not there is refused, not silent"

# ---------------------------------------------------------------------------
echo "4. the agent's tools"
# ---------------------------------------------------------------------------
# The dictionary is the only writable surface on the MCP server that can change
# a transcript, so what is asserted here is the guard rather than the write: an
# apply that never previewed is refused, and a preview somebody read is what
# `sentences` carries.

# One `listen mcp` process per call, which is what a client does anyway. The
# request is built in python because a tool's arguments are JSON and quoting
# them through bash twice is how a test starts asserting on its own escaping.
mcp() {   # tool, json arguments, optional --tools allowlist
  python3 - "$LISTEN" "$1" "$2" "${3:-}" <<'PY'
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

AAAA="$LISTEN_LIBRARY/recordings/2026-09-01-100000-AAAA"

mcp list_dictionary '{}' | grep -q "cloud code"
check $? "list_dictionary reads the list the pane writes"

# The allowlist is the only thing standing between a read-only question and the
# transcripts, and it is enforced here rather than by the client. See `MCP.call`.
mcp add_dictionary_entry '{"text":"Nope","replacement":"Nah"}' "list_dictionary" \
  | grep -q "not one of the tools this session may call"
check $? "a session without writes cannot add a rule"
mcp apply_dictionary_backfill '{"sentences":1}' "list_dictionary" \
  | grep -q "not one of the tools this session may call"
check $? "nor apply a backfill"

mcp add_dictionary_entry '{"text":"everybody","replacement":"everyone"}' \
  | grep -q '"kind" : "correction"'
check $? "both halves of a mishearing make a correction"
mcp add_dictionary_entry '{"text":"everybody","replacement":"everyone"}' \
  | grep -q "already in the dictionary"
check $? "and adding it twice is refused rather than duplicated"

# `DictionarySuggestions.entry` makes the same choice from `caseOnly`. An
# insensitive correction here matches its own replacement for ever.
mcp add_dictionary_entry '{"text":"seapoint","replacement":"Seapoint"}' \
  | grep -q '"forced_case_sensitive" : true'
check $? "a pair differing only in capitals is forced case-sensitive"

mcp add_dictionary_entry '{"text":"Beehiv"}' | grep -q "ordinary English word"
check $? "a term that sounds like English is saved with the reason it will not fire"
mcp add_dictionary_entry '{"text":"Ekko"}' | grep -q "needs five letters"
check $? "so is a term too short to be matched by sound"
mcp add_dictionary_entry '{"text":"Embt","replacement":"Embt"}' \
  | grep -q "would do nothing"
check $? "and a correction that replaces text with itself is refused"

before=$(cat "$AAAA/transcript.json")
preview=$(mcp preview_dictionary_backfill '{"recording_id":"2026-09-01-100000-AAAA"}')
echo "$preview" | grep -q "everybody in the room.  ->  .*everyone in the room."
check $? "the preview quotes the sentence either side of the edit"
[ "$(cat "$AAAA/transcript.json")" = "$before" ]
check $? "and writes nothing"

mcp apply_dictionary_backfill \
  '{"recording_id":"2026-09-01-100000-AAAA","sentences":99}' \
  | grep -q "Nothing was written"
check $? "an apply whose count does not match the preview is refused"
[ "$(cat "$AAAA/transcript.json")" = "$before" ]
check $? "and really does write nothing"

mcp apply_dictionary_backfill \
  '{"recording_id":"2026-09-01-100000-AAAA","sentences":1}' | grep -q '"sentences" : 1'
check $? "the count the preview returned is what lets it through"
grep -q "everyone in the room" "$AAAA/transcript.json"
check $? "and the transcript is rewritten"
grep -q "everyone in the room" "$AAAA/turns.json"
check $? "with turns.json rebuilt from the same segments"
[ ! -f "$AAAA/transcript.raw.json.bak" ]
check $? "and no .raw.json.bak, because a backfill is not a human correction"

mcp preview_dictionary_backfill '{"recording_id":"2026-09-01-100000-AAAA"}' \
  | grep -q '"sentences" : 0'
check $? "a second preview of the same recording finds nothing"

mcp remove_dictionary_entry '{"text":"EVERYBODY"}' | grep -q '"text" : "everybody"'
check $? "an entry is removed however it is capitalised"
grep -q "everyone in the room" "$AAAA/transcript.json"
check $? "and removing the rule does not put the sentence back"
mcp remove_dictionary_entry '{"text":"never-added"}' | grep -q "no dictionary entry"
check $? "removing one that is not there is refused, not silent"

# ---------------------------------------------------------------------------
echo "5. the pane"
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$PROBE")"
[ -x "$PROBE" ] || swiftc -O "$ROOT/tools/axprobe.swift" -o "$PROBE" || exit 2
cp -R "$ROOT/Listen.app" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    "$COPY/Contents/Info.plist" >/dev/null
codesign --force --sign - --deep "$COPY" 2>/dev/null
defaults delete com.mgo.listen-uitest >/dev/null 2>&1
defaults write com.mgo.listen-uitest onboarded -bool true
  # **Detection off, or the copy records the room in the middle of the test.**
  # Meeting detection is on by default and a copy inherits it, so a call
  # anywhere on this Mac puts the window on the recording screen with "Are you
  # in a meeting?" over it. Measured: it is what made three assertions in
  # `verify_ask_states.sh` fail for several builds against an app that was
  # working, and a run that does this captures the microphone unasked.
  defaults write com.mgo.listen-uitest autoDetectMeetings -bool false

LISTEN_PANEL=settings:dictionary "$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
APP=$!
sleep 6
dump=$("$PROBE" texts $APP 2>&1); code=$?
# 4 is an empty tree, which is what a sleeping display gives back: every
# negative assertion below would pass on nothing, so it is a skip and not a
# result. See the note about `axprobe` in CLAUDE.md.
case $code in
  3) echo "  SKIP: no Accessibility permission" >&2; kill $APP 2>/dev/null; exit 2;;
  4) echo "  SKIP: empty AX tree (is the display asleep?)" >&2
     kill $APP 2>/dev/null; exit 2;;
esac

# A sleeping display empties every window's subtree, and every negative
# assertion below would pass on nothing.
# The window has to prove it is there before anything below is believed. A
# sleeping display leaves the application element in the tree with no window
# under it, which is not an empty tree and would fail every assertion here for
# a reason that has nothing to do with the pane.
if ! field "$dump" "Dictionary"; then
  echo "  SKIP: the settings window is not readable (is the display asleep?)" >&2
  kill $APP 2>/dev/null; rm -rf "$COPY"; exit 2
fi
ok "the pane is up and readable"
field "$dump" "Kinsight"
check $? "the word is a row"
field "$dump" "Also heard as"
check $? "its spellings are a column, not a second tab"
! field "$dump" "Terms"
check $? "and the terms/corrections switch is gone"
echo "$dump" | grep -q "Fixed"
check $? "so is the count of what each word has fixed"
echo "$dump" | grep -q "Fix older transcripts"
check $? "the pane can apply the list to transcripts that already exist"

"$PROBE" press $APP "Add…" >/dev/null 2>&1
check $? "Add is pressable"
sleep 2
sheet=$("$PROBE" texts $APP 2>&1)
echo "$sheet" | grep -q "Spell it like this"
check $? "and opens a sheet that asks for the word first"
echo "$sheet" | grep -q "Also heard as"
check $? "with room for as many spellings as you have seen"
echo "$sheet" | grep -q "transcripts you already have"
check $? "and says what it will do to what you already have"

kill $APP 2>/dev/null
sleep 1
rm -rf "$COPY"

echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
