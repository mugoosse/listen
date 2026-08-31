#!/bin/bash
# `Settings.askEnabled`, as assertions: with Ask off there is no composer, no
# Chats and no setup card anywhere in the window, and with it on all three are
# back. Runs on the uitest bundle copy (com.mgo.listen-uitest) against a
# scratch library, so the real preferences are never touched.
#
# The point of the switch is a first run that asks for nothing, so the "off"
# half is checked on a machine with no agent at all: that is the state the
# whole surface used to be loudest in. See `Settings.askEnabled`.
#
# HEADS UP for whoever is at the keyboard: the ad-hoc copy raises a real
# Keychain prompt naming Listen on every launch. Deny it; nothing here needs
# the endpoint key.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE="$ROOT/.xcbuild/tools/axprobe"
DIR="${TMPDIR:-/tmp}/listen-verify-ask-toggle"
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

# An exact match on any tab-separated field of the probe's dump.
#
# **Not `grep`, and the difference is the whole reliability of this script.**
# `axprobe texts` prints role, subrole, title, value and accessibility
# description in tab-separated columns, and the two controls this file is
# about carry their name in the *description* column: the composer's send
# button and the Chats toolbar item both have an empty title. A substring
# grep for "Chats" hits the menu bar as well as the toolbar, and `grep -x`
# hits nothing at all because the line is mostly tabs, which is a negative
# assertion that passes whatever the app does.
field() {
  echo "$1" | awk -F'\t' -v want="$2" \
    '{ for (i = 1; i <= NF; i++) if ($i == want) f = 1 } END { exit f ? 0 : 1 }'
}

rm -rf "$DIR"; mkdir -p "$DIR/library"
cp -R "$ROOT/Listen.app" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    "$COPY/Contents/Info.plist"
codesign --force --sign - --deep "$COPY" 2>/dev/null

APP=""
stop() { [ -n "$APP" ] && kill "$APP" 2>/dev/null; sleep 1; }
launch() {
  "$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
  APP=$!
  sleep 5
}

# No agent anywhere, which is the first-run state the switch is for. The empty
# provider list is pre-stored for `verify_ask_states.sh`'s reason: the
# migration's evidence check reads the Keychain, and the ad-hoc copy's read
# raises a blocking prompt that hangs detection. 5b5d is "[]".
base() {
  defaults delete com.mgo.listen-uitest >/dev/null 2>&1
  defaults write com.mgo.listen-uitest onboarded -bool true
  defaults write com.mgo.listen-uitest agentPath_claude -string "/nonexistent/claude"
  defaults write com.mgo.listen-uitest agentPath_codex -string "/nonexistent/codex"
  defaults write com.mgo.listen-uitest agentProviders -data 5b5d
}

echo "1. the default is off, and off is silent"
base
launch
dump=$("$PROBE" texts $APP 2>&1)
case $? in 3) echo "  SKIP: no Accessibility permission" >&2; exit 2;; esac
# The empty tree a sleeping display gives back would pass every negative
# assertion below, so the window has to prove it is there first.
field "$dump" "Record"
check $? "the window is up and readable (guard against an empty AX tree)"
! field "$dump" "Ask"
check $? "no composer: its send button is not in the window"
! echo "$dump" | grep -q "Pick what answers your questions"
check $? "no setup card"
! echo "$dump" | grep -q "Set up Ask"
check $? "and nothing on the page asks to set anything up"
! field "$dump" "Chats"
check $? "no Chats in the title bar"
stop

echo "2. on, and the three surfaces come back"
base
defaults write com.mgo.listen-uitest askEnabled -bool true
launch
"$PROBE" focus $APP "Ask about" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
field "$dump" "Chats"
check $? "Chats is in the title bar"
echo "$dump" | grep -q "Pick what answers your questions"
check $? "and with no agent the card asks which one"
# The card replaces the composer rather than sitting over it: the state is
# known before anything is typed, so a field that can only fail is not offered.
! field "$dump" "Ask"
check $? "and the card stands alone, with no field that cannot answer"
echo "$dump" | grep -q "Not now puts Ask away"
check $? "the card says what its way out does"

# The card is the only screen somebody who turned Ask on and could not finish
# setting it up ever sees, so the way out has to be on it rather than back in
# Settings. Pressing it turns the whole surface off, which is the same
# assertion as case 1 taken from the other direction.
"$PROBE" press $APP "Not now" >/dev/null 2>&1
check $? "Not now is pressable"
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
field "$dump" "Record"
check $? "the window is still there afterwards"
! echo "$dump" | grep -q "Pick what answers your questions"
check $? "the card is gone"
! field "$dump" "Chats"
check $? "and Chats with it"
[ "$(defaults read com.mgo.listen-uitest askEnabled 2>/dev/null)" = "0" ]
check $? "the switch in Settings is what was actually turned off"
stop

echo "3. recording and transcribing never mention it either way"
base
launch
dump=$("$PROBE" texts $APP 2>&1)
field "$dump" "Record"
check $? "the record button is on the toolbar with Ask off"
stop

defaults delete com.mgo.listen-uitest >/dev/null 2>&1
rm -rf "$DIR"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
