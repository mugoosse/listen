#!/bin/bash
# The cross on the conversation card closes it, and it stays closed.
#
# **This does not reproduce the bug it was written for, and says so rather
# than being quietly kept.** It was written to catch a report of an Ask panel
# that opened itself after a recording and could not be closed, on the theory
# that `closeConversation` cleared `putAway` and `applyHeight` then re-expanded
# the bar on the same pass. Pointed at the build that shipped that bug it
# passes:
#
#     LISTEN_APP=/Applications/Listen.app ./verify_ask_close.sh   # 7 passed
#
# So the reported symptom needs some other condition, and it is still open.
# Three guesses were measured and none of them was it: a real conversation
# closed with the cross (this script), the setup card with no agent
# configured, and Chats mode with nothing in it. The last two never put the
# card's header on screen at all, on either build.
#
# What it is good for is what it actually asserts: that closing a conversation
# works and that asking again brings it back, which is the regression guard
# the `putAway` correction needed and did not otherwise have.
#
# The stub answers rather than failing, which is what no other Ask script
# does: every one of them drives a backend that cannot answer, so none of them
# has ever seen a card with a conversation in it.
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
# build. That is how this script was shown to be measuring something:
# `LISTEN_APP=/Applications/Listen.app ./verify_ask_close.sh` on 0.24.1 fails
# case 2, which is the bug as the user met it.
APP_UNDER_TEST="${LISTEN_APP:-$ROOT/Listen.app}"
DIR="${TMPDIR:-/tmp}/listen-verify-ask-close"
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

rm -rf "$DIR"; mkdir -p "$DIR/bin" "$DIR/library"
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
# therefore produces a card that says "Worked for 0s" with nothing in it,
# which is what this script first measured.
#
# Long enough that the card clears `barCeiling`, which is the condition being
# tested: a short answer collapses on its own and proves nothing.
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

echo "1. a question opens the card"
"$PROBE" settext $APP "Ask about" "how many recordings do I have?" >/dev/null 2>&1
sleep 1
"$PROBE" press $APP "Ask" >/dev/null 2>&1
# The whole run, not just the first delta: the card is measured after the
# answer has landed, because that is what makes it tall enough to matter.
sleep 9
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "You have three recordings in the library"
check $? "the answer arrived"
field "$dump" "Close the conversation"
check $? "and the card is open, so its cross is on screen"

echo "2. the cross closes it, and it stays closed"
"$PROBE" press $APP "Close the conversation" >/dev/null 2>&1
sleep 3
dump=$("$PROBE" texts $APP 2>&1)
# The bug reopened it on the same layout pass, so this is the assertion: not
# "did it animate shut" but "is it still shut a moment later".
! echo "$dump" | grep -q "You have three recordings in the library"
check $? "the answer is off screen"
! field "$dump" "Close the conversation"
check $? "and the card's own controls went with it"
field "$dump" "Ask"
check $? "the composer is still there to ask the next question"

echo "3. asking again brings it back"
"$PROBE" focus $APP "Ask about" >/dev/null 2>&1
sleep 1
"$PROBE" settext $APP "Ask about" "and what about last week?" >/dev/null 2>&1
sleep 1
"$PROBE" press $APP "Ask" >/dev/null 2>&1
# The whole run, not just the first delta: the card is measured after the
# answer has landed, because that is what makes it tall enough to matter.
sleep 9
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "You have three recordings in the library"
check $? "a new question reopens the card, so putAway is not a one-way latch"

kill $APP 2>/dev/null; sleep 1
defaults delete com.mgo.listen-uitest >/dev/null 2>&1
rm -rf "$DIR"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
