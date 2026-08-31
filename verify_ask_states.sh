#!/bin/bash
# The Ask surfaces' honesty, as assertions, with stub CLIs standing in for
# every install state a real machine can be in. Runs on the uitest bundle copy
# (com.mgo.listen-uitest) against a scratch library; the real preferences are
# never touched. The stubs are pointed at through the explicit agentPath
# setting, which wins over detection by design.
#
# HEADS UP for whoever is at the keyboard: the ad-hoc copy raises a real
# Keychain prompt naming Listen on every launch. Deny it; nothing here needs
# the endpoint key.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE="$ROOT/.xcbuild/tools/axprobe"
DIR="${TMPDIR:-/tmp}/listen-verify-ask"
COPY="$DIR/T.app"
export LISTEN_LIBRARY="$DIR/library"
export LISTEN_NO_TELEMETRY=1
# The login-shell pass would find the real CLIs whatever the defaults say.
export SHELL=/usr/bin/false

[ -x "$ROOT/Listen.app/Contents/MacOS/Listen" ] || {
  echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }
[ -x "$PROBE" ] || swiftc -O "$ROOT/tools/axprobe.swift" -o "$PROBE" || exit 2

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

rm -rf "$DIR"; mkdir -p "$DIR/bin" "$LISTEN_LIBRARY"
cp -R "$ROOT/Listen.app" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    "$COPY/Contents/Info.plist"
codesign --force --sign - --deep "$COPY" 2>/dev/null

# The stub speaks exactly what detection asks of a real `claude`: a version,
# an auth status, and something for the alias-resolution probe. Any actual
# question (--print with stream-json) fails the way a signed-out CLI fails:
# a sign-in sentence on stderr and a nonzero exit, which is what the failure
# text the app classifies is made of.
cat > "$DIR/bin/claude" <<'STUB'
#!/bin/bash
case "$1" in
  --version) echo "2.1.212 (Claude Code)";;
  auth) cat "$(dirname "$0")/auth.json";;
  --print|*)
    if [ "$(python3 -c "import json;print(json.load(open('$(dirname "$0")/auth.json'))['loggedIn'])")" = "True" ]; then
      echo "Please run claude auth login to sign in before asking." >&2
      exit 1
    fi
    echo "Please run claude auth login to sign in." >&2
    exit 1;;
esac
STUB
chmod +x "$DIR/bin/claude"

launch() {  # launch -> $APP set, composer focused
  caffeinate -u -t 2 2>/dev/null
  "$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
  APP=$!
  sleep 5
  # The Ask surfaces draw their setup card only once the composer has the
  # caret ("the chips wait for the caret"), so every case starts focused.
  "$PROBE" focus $APP "Ask about" >/dev/null 2>&1
  sleep 2
}
settle() { sleep 2; }

configure() {  # configure <claude-path> <codex-path>
  defaults delete com.mgo.listen-uitest >/dev/null 2>&1
  defaults write com.mgo.listen-uitest onboarded -bool true
  # Ask is off until somebody turns it on, and every state below is a state of
  # a surface that does not exist until then. See `Settings.askEnabled` and
  # `verify_ask_toggle.sh`, which is the script that checks the switch itself.
  defaults write com.mgo.listen-uitest askEnabled -bool true
  defaults write com.mgo.listen-uitest agentPath_claude -string "$1"
  defaults write com.mgo.listen-uitest agentPath_codex -string "$2"
  # An empty provider list, pre-stored, so the one-time provider migration is
  # already done. The migration's evidence check reads the Keychain, the
  # ad-hoc copy's Keychain read raises the blocking prompt CLAUDE.md warns
  # about, and detection then hangs until a human answers it: measured, the
  # composer chip said "Loading…" for ever. 5b5d is "[]".
  defaults write com.mgo.listen-uitest agentProviders -data 5b5d
}

echo "1. installed but signed out: the card says sign in, and offers the wizard"
echo '{"loggedIn": false}' > "$DIR/bin/auth.json"
configure "$DIR/bin/claude" "/nonexistent/codex"
launch
dump=$("$PROBE" texts $APP 2>&1)
case $? in 3) echo "  SKIP: no Accessibility permission" >&2; exit 2;; esac
echo "$dump" | grep -q "Claude Code is installed but not signed in"
check $? "the setup card names the state"
echo "$dump" | grep -q "Set up Ask"
check $? "and the way in is the wizard button"
! echo "$dump" | grep -qi "npm install"
check $? "nothing tells an installed CLI's owner to install it"
"$PROBE" press $APP "Set up Ask" >/dev/null 2>&1
check $? "the wizard opens from the card"
settle
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "How should Listen answer questions"
check $? "and lays the options out"
echo "$dump" | grep -q "OpenRouter"
check $? "OpenRouter is one of them"
"$PROBE" press $APP "Close" >/dev/null 2>&1
settle
# Closing the wizard without finishing an option writes nothing: the provider
# list is still the empty one this script planted, and no backend choice was
# stored. The save path itself is deliberately NOT driven here: `AgentKey`
# uses one fixed Keychain service, so a scripted save would delete the real
# OpenRouter key of whoever runs this. The writes are one-line calls into
# `Settings.addProvider` and `AgentKey.save`, which the settings pane already
# exercises by hand.
defaults read com.mgo.listen-uitest agentProviders 2>/dev/null | grep -q "0x5b5d"
check $? "closing the wizard left the provider list untouched"
! defaults read com.mgo.listen-uitest agentBackend >/dev/null 2>&1
check $? "and stored no backend choice"

echo "2. the settings row for a signed-out CLI says sign in, not install"
"$PROBE" press $APP "Settings" >/dev/null 2>&1; sleep 1
# The second "Ask" row: the first is the section heading with the same word.
"$PROBE" selectrow $APP "Ask" 2 >/dev/null 2>&1; sleep 3
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "Installed. Run "
check $? "the claude row leads with Installed"
! echo "$dump" | grep -qi "npm install"
check $? "and never with npm"
echo "$dump" | grep -qi "Set up Ask"
check $? "the pane offers the wizard too"
echo "$dump" | grep -q "Automatic"
check $? "the which-one picker is filled, not empty"
kill $APP 2>/dev/null; sleep 1

echo "3. nothing installed at all: the plain-language card"
configure "/nonexistent/claude" "/nonexistent/codex"
launch
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "Pick what answers your questions"
check $? "the card leads with the choice, not with a requirement"
echo "$dump" | grep -q "each option says what it costs"
check $? "and says the options carry their price"
# The selling is the onboarding step's job now, and this card is only ever
# read by somebody who already said yes there. See `Settings.askEnabled`.
! echo "$dump" | grep -q "Check again"
check $? "and offers two calls to action rather than three"
! echo "$dump" | grep -qi "npm install"
check $? "with no package manager in sight"
kill $APP 2>/dev/null; sleep 1

echo "4. a run that fails on credentials corrects the surface"
echo '{"loggedIn": true, "email": "stub@example.com"}' > "$DIR/bin/auth.json"
configure "$DIR/bin/claude" "/nonexistent/codex"
launch
dump=$("$PROBE" texts $APP 2>&1)
! echo "$dump" | grep -q "installed but not signed in"
check $? "a signed-in probe shows no card"
"$PROBE" settext $APP "Ask about" "how many recordings do I have?" >/dev/null 2>&1
check $? "the composer takes a question"
sleep 1
"$PROBE" press $APP "Ask" >/dev/null 2>&1
check $? "and it can be sent"
sleep 6
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "installed but not signed in"
check $? "the failed run put the sign-in card up instead of a second failure"
kill $APP 2>/dev/null

defaults delete com.mgo.listen-uitest >/dev/null 2>&1
rm -rf "$DIR"

echo
echo "passed $pass, failed $fail"
[ "$fail" = "0" ] || exit 1
