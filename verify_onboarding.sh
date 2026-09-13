#!/bin/bash
# First-run setup, as assertions: the window has no close button on a first
# run, every step still has its own way past, the library appears only after
# "You are set", and a second launch shows no setup. Runs on the uitest bundle
# copy (com.mgo.listen-uitest) with scratch LISTEN_LIBRARY and HF_HOME, so the
# real preferences, model choice and library are never touched. See CLAUDE.md,
# "Running setup again without spending the real preferences".
#
# HEADS UP for whoever is at the keyboard: the ad-hoc copy raises a real
# Keychain prompt naming Listen on every launch. Deny it; the script never
# needs the endpoint key. Never press "Allow microphone" if a system prompt
# appears; the script only ever presses Skip-shaped buttons.
set -u

# macOS grants Keychain access to a binary, and every run of this suite
# launches one signed a minute ago, so the app was asking for a password
# per launch to read an endpoint key none of these tests uses.
export LISTEN_NO_KEYCHAIN=1

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROBE="$ROOT/.xcbuild/tools/axprobe"
COPY="${TMPDIR:-/tmp}/listen-verify-onboarding/T.app"
export LISTEN_LIBRARY="${TMPDIR:-/tmp}/listen-verify-onboarding/library"
export HF_HOME="${TMPDIR:-/tmp}/listen-verify-onboarding/hf"
export LISTEN_NO_TELEMETRY=1

[ -x "$ROOT/Listen.app/Contents/MacOS/Listen" ] || {
  echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }
[ -x "$PROBE" ] || swiftc -O "$ROOT/tools/axprobe.swift" -o "$PROBE" || exit 2

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

rm -rf "$(dirname "$COPY")"
mkdir -p "$(dirname "$COPY")" "$LISTEN_LIBRARY" "$HF_HOME"
cp -R "$ROOT/Listen.app" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    "$COPY/Contents/Info.plist"
codesign --force --sign - --deep "$COPY" 2>/dev/null
defaults delete com.mgo.listen-uitest >/dev/null 2>&1

press() {  # press <pid> <needle> <what>
  "$PROBE" press "$1" "$2" >/dev/null 2>&1
  check $? "$3"
  sleep 1
}

# One step forward, whatever this machine has already granted: a step whose
# permission exists shows plain Continue with no secondary, one whose
# permission is missing shows the granting primary (never pressed here) with
# the way past as the secondary. So prefer the way-past words, fall back to
# Continue, and never press anything that grants, opens System Settings,
# downloads, or turns sync on.
advance() {  # advance <pid> -> echoes what it pressed, exit 1 when stuck
  local buttons
  buttons=$("$PROBE" texts "$1" | awk -F'\t' '$1=="AXButton"{print $3}')
  for wanted in "Start using Listen" "Later" "Skip" "Not now" "Continue"; do
    if echo "$buttons" | grep -qx "$wanted"; then
      "$PROBE" press "$1" "$wanted" >/dev/null 2>&1 && { echo "$wanted"; return 0; }
    fi
  done
  return 1
}

caffeinate -u -t 2 2>/dev/null
"$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
APP=$!
trap 'kill $APP 2>/dev/null' EXIT
sleep 4

echo "1. a first run cannot be dismissed"
dump=$("$PROBE" texts $APP 2>&1) || { echo "  SKIP: $dump" >&2; exit 2; }
echo "$dump" | grep -q "Welcome to Listen"
check $? "the setup window is up"
[ "$("$PROBE" hasclose $APP "welcome")" = "no" ]
check $? "and it has no close button"
# The home page's greeting is the tell; "New Recording" would match the menu
# bar, which is in the app's AX tree whatever window is up. There are two
# greetings and an empty library gets the other one: a library with nothing in
# it says "Ready when you are", and only one with recordings, people, notes or
# conversations says "What's cooking". Matching one of them alone passed this
# assertion for the wrong reason and failed the two below for a real one.
home() { echo "$1" | grep -qE "What's cooking|Ready when you are"; }
! home "$dump"
check $? "the library window is not on screen yet"

echo "2. every step still has its own way past"
reached_end=1
for step in 1 2 3 4 5 6 7 8 9 10; do
  said=$(advance $APP) || { bad "stuck at step $step: nothing safe to press"; break; }
  echo "     pressed: $said"
  sleep 1.5
  if [ "$said" = "Start using Listen" ]; then reached_end=0; break; fi
done
check $reached_end "walked to the end pressing only safe buttons"
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
home "$dump"
check $? "the library window appeared after finishing"

# The memory step is optional in the same way the Ask step is, so walking the
# flow pressing only the way-past words must leave it off. Declining writes
# nothing rather than writing false, so Settings can still offer it as a
# question nobody has answered.
! grep -q "enrolNewPeople" "$LISTEN_LIBRARY/people-memory-settings.json" 2>/dev/null
check $? "declining the memory step leaves people un-enrolled"

kill $APP 2>/dev/null
sleep 1

echo "3. a second launch shows no setup"
"$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
APP=$!
sleep 4
dump=$("$PROBE" texts $APP 2>&1)
! echo "$dump" | grep -q "Welcome to Listen"
check $? "no setup window on the second launch"
home "$dump"
check $? "the library came straight up"

echo "4. the Settings re-run is closable"
# `restart()` is the Settings route; reached through the gear, the section
# list and the Updates pane's button, so the assertion covers the whole path.
"$PROBE" press $APP "Settings" >/dev/null 2>&1; sleep 1
"$PROBE" selectrow $APP "Updates" >/dev/null 2>&1; sleep 1
"$PROBE" press $APP "Run setup again" >/dev/null 2>&1; sleep 1.5
[ "$("$PROBE" hasclose $APP "welcome")" = "yes" ]
check $? "setup opened from Settings has a close button"

echo "5. the memory step turns memory on when it is pressed"
# Walk forward with the safe words until the memory step names itself, then
# press the one button on it that does something. It is the only step whose
# consent is a file in the library rather than a defaults key, which is why
# the assertion reads the library.
reached_memory=1
for step in 1 2 3 4 5 6 7 8 9 10; do
  if "$PROBE" texts $APP 2>/dev/null | grep -q "Remember the people you talk to"; then
    reached_memory=0; break
  fi
  advance $APP >/dev/null || break
  sleep 1.2
done
check $reached_memory "the memory step is reachable from a Settings re-run"
if [ "$reached_memory" = "0" ]; then
  press $APP "Remember people" "pressing it is accepted"
  sleep 1
  "$PROBE" texts $APP 2>/dev/null | grep -q "People will be remembered"
  check $? "and the step says so where it promised"
  grep -q '"enrolNewPeople"' "$LISTEN_LIBRARY/people-memory-settings.json" 2>/dev/null
  check $? "the library records that new people are remembered"
fi

kill $APP 2>/dev/null
trap - EXIT
defaults delete com.mgo.listen-uitest >/dev/null 2>&1
rm -rf "$(dirname "$COPY")"

echo
echo "passed $pass, failed $fail"
[ "$fail" = "0" ] || exit 1
