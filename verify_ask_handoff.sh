#!/bin/bash
# A question hands over the whole page, and Back is the way home.
#
# **This replaces `verify_ask_close.sh`, which tested a card that no longer
# exists.** The bar used to grow into a glass panel resting over the meeting,
# with a cross in its own header to close it and a disc beside that to grow it
# again into a page; the cross is what that script pressed. A question goes
# straight to the page now, so what there is to assert is the handover: the
# answer arrives on a screen of its own, the card's two controls are nowhere,
# and Back puts the composer back where it was.
#
# The stub answers rather than failing, which is what no other Ask script
# does: every one of them drives a backend that cannot answer, so none of them
# has ever seen a conversation on screen at all.
#
# Runs on the uitest bundle copy (com.mgo.listen-uitest) against a scratch
# library; the real preferences are never touched.
#
# HEADS UP for whoever is at the keyboard: the ad-hoc copy raises a real
# Keychain prompt naming Listen on every launch. Deny it; nothing here needs
# the endpoint key.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE="$ROOT/.xcbuild/tools/axprobe"
# The app under test, so the same assertions can be pointed at a released
# build. On anything before the card was removed, cases 1 and 2 fail: the
# answer lands in a panel over the meeting, "Close the conversation" is on
# screen, and there is no Back to press.
APP_UNDER_TEST="${LISTEN_APP:-$ROOT/Listen.app}"
DIR="${TMPDIR:-/tmp}/listen-verify-ask-handoff"
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

field() {
  echo "$1" | awk -F'\t' -v want="$2" \
    '{ for (i = 1; i <= NF; i++) if ($i == want) f = 1 } END { exit f ? 0 : 1 }'
}

# **Polled, not slept for, and case 3 is why.** The run is a spawned process
# and there is an animated mode change either side of it, so a fixed sleep is
# a guess: at nine seconds this script failed about one run in two on the
# second question and passed on the first, which reads as a bug in the app
# rather than as a stopwatch that is too short. Leaves the tree it succeeded
# on in `dump`, so the assertions after it read the same pass.
waitfor() {
  local waited=0
  while [ "$waited" -lt "${2:-20}" ]; do
    dump=$("$PROBE" texts $APP 2>&1)
    echo "$dump" | grep -q "$1" && return 0
    sleep 1; waited=$((waited+1))
  done
  return 1
}

rm -rf "$DIR"; mkdir -p "$DIR/bin" "$DIR/library/recordings" "$DIR/library/chats"
cp -R "$APP_UNDER_TEST" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    "$COPY/Contents/Info.plist"
codesign --force --sign - --deep "$COPY" 2>/dev/null

# A `claude` that signs in and answers, in the stream-json dialect
# `readClaude` parses.
#
# **The deltas are the answer, not the `assistant` message.** The window asks
# for a streaming run, and in that mode `readClaude` skips the text blocks of
# the finished `assistant` message on purpose, because the deltas already
# carried the same words. A stub that emits only the finished message
# therefore produces a page that says "Worked for 0s" with nothing in it.
cat > "$DIR/bin/claude" <<'STUB'
#!/bin/bash
say() {
  printf '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"%s"}}}\n' "$1"
}
case "$1" in
  --version) echo "2.1.212 (Claude Code)";;
  auth) echo '{"loggedIn": true, "email": "stub@example.com"}';;
  --print|*)
    echo '{"type":"system","subtype":"init","session_id":"stub-session-1"}'
    say "You have three recordings in the library. "
    say "The most recent is a call with Nadia from this morning, which lasted "
    say "about ten minutes and has two speakers on it. Before that there is a "
    say "weekly review from Tuesday, and a phone memo from last week that "
    say "nobody has named yet. Ask about any of them by name and I will read "
    say "the transcript rather than guessing from the title."
    echo '{"type":"assistant","message":{"content":[{"type":"text","text":"You have three recordings in the library."}]}}'
    echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.0,"duration_ms":120}'
    exit 0;;
esac
STUB
chmod +x "$DIR/bin/claude"

# One meeting, sidecars only, so case 4 can ask from a page that is about
# something and check what Back lands on. See CLAUDE.md, "Driving the built app
# against a scratch library".
python3 - "$DIR/library" <<'FIXTURE'
import json, os, sys
root = sys.argv[1]
rid = "2026-09-03-1201-named"
folder = os.path.join(root, "recordings", rid)
os.makedirs(folder)
turns = [{"start": 2.0, "end": 5.0, "speaker": "Me",
          "text": "The trial stays at fourteen days."},
         {"start": 5.6, "end": 8.6, "speaker": "Chloe",
          "text": "Thirty converts better on the enterprise plans."}]
json.dump({"id": rid, "title": "Pricing with Chloe",
           "recorded_at": "2026-09-03T12:01:00Z", "duration": 8.6,
           "source": "detected", "state": "done",
           "app_bundle_id": "com.google.Chrome"},
          open(os.path.join(folder, "metadata.json"), "w"), indent=1, sort_keys=True)
json.dump({"segments": turns, "duration": 8.6,
           "model": "mlx-community/parakeet-tdt-0.6b-v2",
           "wordLevel": False, "cleanup": {}, "dictionary": {}},
          open(os.path.join(folder, "transcript.json"), "w"), indent=1, sort_keys=True)
json.dump(turns, open(os.path.join(folder, "turns.json"), "w"), indent=1, sort_keys=True)
FIXTURE

defaults delete com.mgo.listen-uitest >/dev/null 2>&1
defaults write com.mgo.listen-uitest onboarded -bool true
defaults write com.mgo.listen-uitest askEnabled -bool true
defaults write com.mgo.listen-uitest agentPath_claude -string "$DIR/bin/claude"
defaults write com.mgo.listen-uitest agentPath_codex -string "/nonexistent/codex"
defaults write com.mgo.listen-uitest agentProviders -data 5b5d

"$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
APP=$!
sleep 6
# The field takes the caret before it takes text: `settext` into an unfocused
# composer lands nowhere and the send button then has nothing to send, which
# reads as a run that failed rather than one that never started.
"$PROBE" focus $APP "Ask about" >/dev/null 2>&1
sleep 2

dump=$("$PROBE" texts $APP 2>&1)
case $? in 3) echo "  SKIP: no Accessibility permission" >&2; exit 2;; esac
field "$dump" "Record"
check $? "the window is up and readable (guard against an empty AX tree)"
! field "$dump" "Back"
check $? "and it is the library, so there is nothing to go back from"

echo "1. a question takes the page"
"$PROBE" settext $APP "Ask about" "how many recordings do I have?" >/dev/null 2>&1
sleep 1
"$PROBE" press $APP "Ask" >/dev/null 2>&1
# The whole run, not just the first delta: the last words of the answer.
waitfor "guessing from the title"
check $? "the answer arrived"
field "$dump" "Back"
check $? "and it is a page, whose way out is Back in the title bar"
field "$dump" "New chat"
check $? "with the page's own New chat beside it"
! field "$dump" "Close the conversation"
check $? "the card's cross is nowhere, because there is no card"
! field "$dump" "Fill the page"
check $? "nor the disc that used to grow one into this"
! field "$dump" "Record"
check $? "and the record capsule is gone with the library's toolbar"

echo "2. Back puts the composer back, and lets the conversation go"
"$PROBE" press $APP "Back" >/dev/null 2>&1
sleep 3
dump=$("$PROBE" texts $APP 2>&1)
! echo "$dump" | grep -q "You have three recordings in the library"
check $? "the answer is off screen"
! field "$dump" "Back"
check $? "and so is the way back, because this is the library again"
field "$dump" "Ask"
check $? "the composer is still there to ask the next question"
field "$dump" "Record"
check $? "and so is the record capsule"
# **The settings pane, which is what this used to land on.** `enter(.library)`
# asked whether the first responder was inside `settingsNav`, and asking
# *loaded* that controller, whose first row selects itself and shows its pane
# into the content area. Measured on 0.30.0 too, by growing the card to full
# width and pressing Back.
! echo "$dump" | grep -q "Your name"
check $? "and it is the library, not Settings > General"
echo "$dump" | grep -q "Select something from the list"
check $? "which is the home page, with its own sentence back"

echo "3. asking again takes the page again"
"$PROBE" focus $APP "Ask about" >/dev/null 2>&1
sleep 1
"$PROBE" settext $APP "Ask about" "and what about last week?" >/dev/null 2>&1
sleep 1
"$PROBE" press $APP "Ask" >/dev/null 2>&1
waitfor "guessing from the title"
check $? "the answer is on screen"
field "$dump" "Back"
check $? "on a page, the same as the first question"

echo "4. asked from a meeting, Back comes home to that meeting"
"$PROBE" press $APP "Back" >/dev/null 2>&1
sleep 3
"$PROBE" selectrow $APP "Pricing with Chloe" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "The trial stays at fourteen days"
check $? "the transcript is on screen"
"$PROBE" focus $APP "Ask about" >/dev/null 2>&1
sleep 1
"$PROBE" settext $APP "Ask about" "what did we settle?" >/dev/null 2>&1
sleep 1
"$PROBE" press $APP "Ask" >/dev/null 2>&1
waitfor "guessing from the title"
check $? "the answer arrived"
# **The meeting is not behind it any more, and that is the change.** A card
# rested over the transcript and left it in the tree; a page hides the pane, for
# accessibility as much as for the eye.
! echo "$dump" | grep -q "The trial stays at fourteen days"
check $? "and the transcript is off screen rather than underneath"
"$PROBE" press $APP "Back" >/dev/null 2>&1
# Polled, for the reason `waitfor` gives: at three seconds flat this failed
# about one run in three, on a mode change that had not finished.
waitfor "The trial stays at fourteen days" 10
check $? "Back puts the meeting back, which is where the question was asked"
! echo "$dump" | grep -q "guessing from the title"
check $? "and the conversation is let go"

kill $APP 2>/dev/null; sleep 2

echo "5. a conversation opened at launch is a page, not a panel over one"
# `LISTEN_CHAT` is the only way in that is not a click: every control on the
# composer is laid out by frame and invisible to accessibility. The id is
# whichever conversation the two questions above wrote.
CHAT=$(basename "$(ls -t "$LISTEN_LIBRARY"/chats/*.json 2>/dev/null | head -1)" .json)
if [ -z "$CHAT" ]; then
  bad "no conversation was written to disk, so there is nothing to reopen"
else
  LISTEN_CHAT="$CHAT" "$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
  APP=$!
  sleep 3
  waitfor "guessing from the title"
  check $? "the conversation is on screen"
  field "$dump" "Back"
  check $? "as a page"
  ! field "$dump" "Close the conversation"
  check $? "with no card's cross on it"
  kill $APP 2>/dev/null; sleep 1
fi

defaults delete com.mgo.listen-uitest >/dev/null 2>&1
rm -rf "$DIR"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
