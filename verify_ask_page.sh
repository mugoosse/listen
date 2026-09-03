#!/bin/bash
# The Ask surfaces on a meeting page: which starters are offered, History on
# the card, and the Chats tab.
#
# Three claims, all of them about the same screen and all of them needing the
# same fixture, which is why they are one script:
#
#   1. The recording starters are Summarise / Action items / Decisions, plus
#      Positions on a meeting whose speakers have all been named. "Catch me
#      up" is gone from this set (it says "I missed this meeting", which
#      nobody using Listen can truthfully say) and Positions is absent while
#      anybody is still `Speaker B`, and on a memo with one voice on it.
#   2. History is on the card's own line while the composer is in use, which
#      is the only route to a meeting's past conversations before one is open.
#   3. Chats is a third tab beside Recording and Notes, it counts, it lists,
#      it says what to do when it is empty, and it is not there at all with
#      `Settings.askEnabled` off.
#
# Runs on the uitest bundle copy (com.mgo.listen-uitest) against a scratch
# library, so the real preferences and the real library are never touched.
#
# HEADS UP for whoever is at the keyboard: the ad-hoc copy raises a real
# Keychain prompt naming Listen on every launch. Deny it; nothing here needs
# the endpoint key.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE="$ROOT/.xcbuild/tools/axprobe"
APP_UNDER_TEST="${LISTEN_APP:-$ROOT/Listen.app}"
DIR="${TMPDIR:-/tmp}/listen-verify-ask-page"
COPY="$DIR/T.app"
export LISTEN_LIBRARY="$DIR/library"
export LISTEN_NO_TELEMETRY=1
export SHELL=/usr/bin/false

[ -x "$APP_UNDER_TEST/Contents/MacOS/Listen" ] || {
  echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }
[ -x "$PROBE" ] || swiftc -O "$ROOT/tools/axprobe.swift" -o "$PROBE" || exit 2

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

# A whole AX field equal to the needle, so "Positions" cannot be satisfied by
# a transcript line that happens to contain the word.
field() {
  echo "$1" | awk -F'\t' -v want="$2" \
    '{ for (i = 1; i <= NF; i++) if ($i == want) f = 1 } END { exit f ? 0 : 1 }'
}

rm -rf "$DIR"; mkdir -p "$DIR/bin" "$DIR/library/recordings" "$DIR/library/chats"
cp -R "$APP_UNDER_TEST" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    "$COPY/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Listen-uitest" \
    "$COPY/Contents/Info.plist" 2>/dev/null
codesign --force --sign - --deep "$COPY" 2>/dev/null

# **Sidecars only, no WAVs.** Everything this script touches works on
# metadata, transcript and turns; `Recording.hasAudio` says the rest honestly.
# See CLAUDE.md, "Driving the built app against a scratch library".
python3 - "$DIR/library" <<'PY'
import json, os, sys
root = sys.argv[1]

def meeting(rid, title, at, lines):
    folder = os.path.join(root, "recordings", rid)
    os.makedirs(folder)
    turns, clock = [], 2.0
    for speaker, text in lines:
        turns.append({"start": round(clock, 2), "end": round(clock + 3, 2),
                      "speaker": speaker, "text": text})
        clock += 3.6
    json.dump({"id": rid, "title": title, "recorded_at": at,
               "duration": round(clock, 2), "source": "detected",
               "state": "done", "app_bundle_id": "com.google.Chrome"},
              open(os.path.join(folder, "metadata.json"), "w"),
              indent=1, sort_keys=True)
    json.dump({"segments": turns, "duration": round(clock, 2),
               "model": "mlx-community/parakeet-tdt-0.6b-v2",
               "wordLevel": False, "cleanup": {}, "dictionary": {}},
              open(os.path.join(folder, "transcript.json"), "w"),
              indent=1, sort_keys=True)
    json.dump(turns, open(os.path.join(folder, "turns.json"), "w"),
              indent=1, sort_keys=True)

# Named, two speakers: the state Positions is for.
meeting("2026-09-03-1201-named", "Pricing with Chloe", "2026-09-03T12:01:00Z", [
    ("Me", "I want to hold the trial at fourteen days."),
    ("Chloe", "Thirty converts better on the enterprise plans."),
    ("Me", "Not on the self-serve ones, and that is most of them."),
])
# One voice still a letter: Positions must not be offered.
meeting("2026-09-02-1030-lettered", "Weekly review", "2026-09-02T10:30:00Z", [
    ("Me", "Where did we land on the migration?"),
    ("B", "Behind, and the reconciliation step is why."),
])
# One voice at all: a memo has nobody to disagree with.
meeting("2026-09-01-0900-memo", "Memo", "2026-09-01T09:00:00Z", [
    ("Me", "Remember to send Chloe the cohort split before Thursday."),
])

# One conversation about the named meeting, and none about the other two.
json.dump({
    "id": "chat-pricing", "title": "What did we settle on the trial length?",
    "created": "2026-09-03T12:39:00Z", "updated": "2026-09-03T12:39:00Z",
    "recordings": ["2026-09-03-1201-named"],
    "backend": "claude",
    "turns": [
        {"who": "you", "text": "What did we settle on the trial length?",
         "at": "2026-09-03T12:39:00Z"},
        {"who": "agent", "text": "Nothing was settled: you held at fourteen days "
         "and Chloe argued for thirty.", "at": "2026-09-03T12:39:10Z"},
    ],
}, open(os.path.join(root, "chats", "chat-pricing.json"), "w"), indent=1)
PY

# A `claude` that is present and signed in, so the chips are offered at all:
# `drawStarters` returns early when `AgentCLI.cachedChosen()` is nil. It never
# has to answer anything here.
cat > "$DIR/bin/claude" <<'STUB'
#!/bin/bash
case "$1" in
  --version) echo "2.1.212 (Claude Code)";;
  auth) echo '{"loggedIn": true, "email": "stub@example.com"}';;
  *) exit 0;;
esac
STUB
chmod +x "$DIR/bin/claude"

defaults delete com.mgo.listen-uitest >/dev/null 2>&1
defaults write com.mgo.listen-uitest onboarded -bool true
defaults write com.mgo.listen-uitest askEnabled -bool true
defaults write com.mgo.listen-uitest agentPath_claude -string "$DIR/bin/claude"
defaults write com.mgo.listen-uitest agentPath_codex -string "/nonexistent/codex"
defaults write com.mgo.listen-uitest agentProviders -data 5b5d

"$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
APP=$!
sleep 6

dump=$("$PROBE" texts $APP 2>&1)
case $? in 3) echo "  SKIP: no Accessibility permission" >&2; kill $APP; exit 2;; esac
field "$dump" "Record"
check $? "the window is up and readable (guard against an empty AX tree)"

# The chips wait for the caret, so every starter assertion below is made with
# the composer in use. See `AskView.drawStarters`.
compose() {
  "$PROBE" selectrow $APP "$1" >/dev/null 2>&1
  sleep 2
  "$PROBE" focus $APP "Ask about" >/dev/null 2>&1
  sleep 2
  "$PROBE" texts $APP 2>&1
}

echo "1. the starters on a meeting whose speakers are all named"
dump=$(compose "Pricing with Chloe")
field "$dump" "Summarise";    check $? "Summarise is offered"
field "$dump" "Action items"; check $? "Action items is offered"
field "$dump" "Decisions";    check $? "Decisions is offered"
field "$dump" "Positions"
check $? "and Positions, which is the one the labelling pays for"
! field "$dump" "Catch me up"
check $? "Catch me up is gone from a meeting you were in"

echo "2. History is on the card, next to the chips"
field "$dump" "History"
check $? "the card offers the conversations about this page"

echo "3. Positions is absent while anybody is still a letter"
dump=$(compose "Weekly review")
field "$dump" "Summarise"
check $? "the other three are still offered"
! field "$dump" "Positions"
check $? "and Positions is not, because 'Speaker B objected' is unreadable"

echo "4. and absent on a memo with one voice on it"
dump=$(compose "Memo")
field "$dump" "Decisions"
check $? "the other three are still offered"
! field "$dump" "Positions"
check $? "and Positions is not, because one speaker has nobody to disagree with"

echo "5. Chats is a third tab, and it counts"
"$PROBE" selectrow $APP "Pricing with Chloe" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
field "$dump" "Recording"; check $? "Recording is a tab"
field "$dump" "Notes";     check $? "Notes is a tab"
field "$dump" "Chats · 1"
check $? "and Chats says how many there are, the way Notes does"

echo "6. the tab lists them"
"$PROBE" press $APP "Chats · 1" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "What did we settle on the trial length?"
check $? "the conversation is named on the tab"
echo "$dump" | grep -q "1 question"
check $? "with when it was had and how much of it there is"
! echo "$dump" | grep -q "Also about this"
check $? "and the line it replaced is not underneath as well"

echo "7. an empty one says what to do about it"
"$PROBE" selectrow $APP "Weekly review" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
field "$dump" "Chats"
check $? "the tab has no count when there is nothing to count"
"$PROBE" press $APP "Chats" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "Ask a question below"
check $? "and points at the composer rather than apologising"

kill $APP 2>/dev/null; sleep 2

echo "8. with Ask off there is no Chats tab at all"
defaults write com.mgo.listen-uitest askEnabled -bool false
"$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
APP=$!
sleep 6
"$PROBE" selectrow $APP "Pricing with Chloe" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
field "$dump" "Recording"
check $? "the bar is still there"
! field "$dump" "Chats"
check $? "and its third segment is not, because there is no composer to fill it"
! field "$dump" "History"
check $? "nor is the card's History, because there is no card"

kill $APP 2>/dev/null; sleep 1
defaults delete com.mgo.listen-uitest >/dev/null 2>&1
rm -rf "$DIR"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
