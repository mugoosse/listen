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
# The ad-hoc copy used to raise a real Keychain prompt naming Listen on every
# launch, and the note here said to deny it. `LISTEN_NO_KEYCHAIN` below makes
# the ask unnecessary rather than the answer manual.
set -u

# macOS grants Keychain access to a binary, and every run of this suite
# launches one signed a minute ago, so the app was asking for a password
# per launch to read an endpoint key none of these tests uses.
export LISTEN_NO_KEYCHAIN=1

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

# Is there a way to start a recording on screen?
#
# **Two controls answer this, and which one depends on the library.** The
# toolbar carries the Record capsule, except on the home page of a library with
# nothing in it: that page draws its own "Start recording" button and the
# toolbar gives way to it, because two controls for one verb on one screen is
# one too many. These scratch libraries are always empty, so this file was
# asserting the toolbar's presence on the one screen that does not have it.
# What it means to test is that turning Ask off does not take recording away,
# and that is true of whichever control is up.
record_control() {
  field "$1" "Record" || grep -q "Start recording" <<<"$1"
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
  # **Detection off, or the copy records the room in the middle of the test.**
  # Meeting detection is on by default and a copy inherits it, so a call
  # anywhere on this Mac puts the window on the recording screen with "Are you
  # in a meeting?" over it. Measured: it is what made three assertions in
  # `verify_ask_states.sh` fail for several builds against an app that was
  # working, and a run that does this captures the microphone unasked.
  defaults write com.mgo.listen-uitest autoDetectMeetings -bool false
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
record_control "$dump"
check $? "the window is up and readable (guard against an empty AX tree)"
! field "$dump" "Ask"
check $? "no composer: its send button is not in the window"
! echo "$dump" | grep -q "Ask your conversations anything"
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
echo "$dump" | grep -q "Ask your conversations anything"
check $? "and with no agent the card makes the offer"
# The card replaces the composer rather than sitting over it: the state is
# known before anything is typed, so a field that can only fail is not offered.
! field "$dump" "Ask"
check $? "and the card stands alone, with no field that cannot answer"
echo "$dump" | grep -q "Closing this hides Ask"
check $? "the card says in words what its glyph does"

# The card is the only screen somebody who turned Ask on and could not finish
# setting it up ever sees, so the way out has to be on it rather than back in
# Settings. Pressing it turns the whole surface off, which is the same
# assertion as case 1 taken from the other direction.
# **By what it declines, not by its two words.** The join offer on a meeting
# page has a "Not now" too, it is earlier in the tree, and it does nothing at
# all when no join is being offered: pressing by name got that one, and the
# three assertions below failed for several builds against an app that was
# working. Both buttons say what they decline to accessibility now.
"$PROBE" press $APP "put Ask away" >/dev/null 2>&1
check $? "Not now is pressable"
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
record_control "$dump"
check $? "the window is still there afterwards"
! echo "$dump" | grep -q "Ask your conversations anything"
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
record_control "$dump"
check $? "there is a way to record with Ask off"
stop

defaults delete com.mgo.listen-uitest >/dev/null 2>&1
rm -rf "$DIR"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
