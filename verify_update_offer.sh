#!/bin/bash
# What happens to a version that has been downloaded and is waiting, as
# assertions. Runs on the uitest bundle copy (com.mgo.listen-uitest) against a
# scratch library, so the real preferences and the real library are never
# touched.
#
# `LISTEN_UPDATE_READY` is the only way to reach the staged state without
# publishing a release. What it cannot reproduce is Sparkle's half of the
# report this was written for: a real staged update stalls the update cycle, so
# `canCheckForUpdates` is false and the menu's Check for Updates is greyed for
# the rest of the launch. The fake never asks Sparkle anything, so underneath
# it that check is still live. Everything Listen owns is here; see
# `.agents/notes/release.md` for the half that is Sparkle's.
#
# Needs an unlocked screen: a sleeping display empties every AX tree.
set -u

# A copy signed a minute ago is a different code identity, so reading the
# endpoint key would raise a Keychain prompt naming the real app on every
# launch. Nothing here needs it.
export LISTEN_NO_KEYCHAIN=1

ROOT="$(cd "$(dirname "$0")" && pwd)"
# Every AX script here drives a copy under one bundle identifier and deletes
# that defaults domain between runs, so two of them running at once wipe each
# other's setup: measured as this script's app coming up on the welcome screen,
# because another run had just deleted `onboarded`. `LISTEN_UITEST_ID` is how a
# run takes a domain of its own when it has to overlap with another.
ID="${LISTEN_UITEST_ID:-com.mgo.listen-uitest}"
PROBE="$ROOT/.xcbuild/tools/axprobe"
DIR="${TMPDIR:-/tmp}/listen-verify-update"
COPY="$DIR/T.app"
export LISTEN_LIBRARY="$DIR/library"
export LISTEN_NO_TELEMETRY=1

[ -x "$ROOT/Listen.app/Contents/MacOS/Listen" ] || {
  echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }
[ -x "$PROBE" ] || swiftc -O "$ROOT/tools/axprobe.swift" -o "$PROBE" || exit 2

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

rm -rf "$DIR"; mkdir -p "$LISTEN_LIBRARY"
cp -R "$ROOT/Listen.app" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" \
    "$COPY/Contents/Info.plist"
codesign --force --sign - --deep "$COPY" 2>/dev/null

defaults delete $ID >/dev/null 2>&1
defaults write $ID onboarded -bool true
# Meeting detection is on by default and a copy inherits it, so a call anywhere
# on this Mac would put the window on the recording screen mid-run and capture
# the microphone unasked.
defaults write $ID autoDetectMeetings -bool false
# Sparkle's own scheduler off for the staged cases, so the run needs no
# network and no clock. It is turned back on in step 8, which is about it.
defaults write $ID SUEnableAutomaticChecks -bool false

APP=""
launch() {  # launch [version] -> $APP set, log at $DIR/run.log
  caffeinate -u -t 2 2>/dev/null
  if [ $# -ge 1 ]; then
    LISTEN_UPDATE_READY="$1" "$COPY/Contents/MacOS/Listen" > "$DIR/run.log" 2>&1 &
  else
    "$COPY/Contents/MacOS/Listen" > "$DIR/run.log" 2>&1 &
  fi
  APP=$!
  sleep 6
  front
  sleep 2
}

# Asked until it answers. A background process activating another app is not
# granted on the first ask every time, and a run where it was not looks exactly
# like an offer that never appeared. `activate` is the one probe command that
# is safe to repeat.
front() {
  local i=0
  while [ $i -lt 6 ]; do
    [ "$("$PROBE" activate $APP 2>&1)" = "active" ] && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}
stop() { kill $APP 2>/dev/null; wait $APP 2>/dev/null; sleep 2; }

# Polled rather than slept at: the offer is raised from activation, and how
# long this Mac takes to hand the app the front is not a constant.
waitfor() {  # waitfor <needle> [seconds]
  local tries=${2:-12}
  local i=0
  while [ $i -lt "$tries" ]; do
    "$PROBE" texts $APP 2>/dev/null | grep -q "$1" && return 0
    sleep 1
    i=$((i+1))
  done
  return 1
}

# `defaults read` answers "does not exist" for a key that is there if cfprefsd
# happens to be flushing the domain, which it is right after the app that owns
# it exits. Measured while writing this: the same read failed and then
# succeeded two seconds later, on a key whose value had been written before
# the app ever started.
readcheck() {
  local i=0 v=""
  while [ $i -lt 5 ]; do
    v=$(defaults read $ID SULastCheckTime 2>/dev/null)
    [ -n "$v" ] && { echo "$v"; return 0; }
    sleep 1
    i=$((i+1))
  done
  echo ""
}

echo "1. a staged version is offered to somebody who comes back to the app"
launch 0.99.0
"$PROBE" texts $APP >/dev/null 2>&1
case $? in 3) echo "  SKIP: no Accessibility permission" >&2; exit 2;;
           4) echo "  SKIP: empty AX tree, the display is asleep" >&2; exit 2;; esac
waitfor "Listen 0.99.0 is ready to install"
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "Listen 0.99.0 is ready to install"
check $? "the alert names the version"
echo "$dump" | grep -q "Install and Relaunch"
check $? "and offers to install it"
echo "$dump" | grep -q "Later"
check $? "and offers to leave it"
echo "$dump" | grep -q "cannot see anything published since"
check $? "and says what leaving it costs, which is the whole point of asking"

echo "2. Later means later, and nothing was installed"
"$PROBE" press $APP "Later" >/dev/null 2>&1
sleep 1
! "$PROBE" texts $APP 2>&1 | grep -q "Listen 0.99.0 is ready to install"
check $? "the alert is gone"
! grep -q "would install" "$DIR/run.log"
check $? "and the install block never ran"

echo "3. going away and coming back inside the hour does not ask again"
FINDER=$(pgrep -x Finder | head -1)
[ -n "$FINDER" ] && "$PROBE" activate "$FINDER" >/dev/null 2>&1
sleep 2
front
sleep 3
! "$PROBE" texts $APP 2>&1 | grep -q "Listen 0.99.0 is ready to install"
check $? "the second visit is quiet"

echo "4. the menu offers the verb that exists, not a check it cannot run"
menu=$("$PROBE" statusmenu $APP 2>&1)
echo "$menu" | grep -q "Update to 0.99.0…"
check $? "the row names the version waiting"
! echo "$menu" | grep -q "Check for Updates…"
check $? "and has taken the place of the check, rather than sitting beside it"

echo "5. Settings says the same thing, with the button that was always there"
# Activated again first. Opening the menu bar item takes the front away from
# the window, and a press on a toolbar button in a window that is not key
# reports success and does nothing, which is the same trap `activate` exists
# for on `showmenu`.
front
sleep 1
"$PROBE" press $APP "Settings" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "Version 0.99.0 is downloaded and ready to install"
check $? "the Updates pane names the version"
echo "$dump" | grep -q "checking resumes once it has"
check $? "and says why Check Now is grey"
stop

echo "6. Install and Relaunch installs"
launch 0.99.0
waitfor "Listen 0.99.0 is ready to install"
check $? "the offer is up again on a fresh launch"
"$PROBE" press $APP "Install and Relaunch" >/dev/null 2>&1
sleep 2
grep -q "would install 0.99.0" "$DIR/run.log"
check $? "the staged version was put in place"
stop

echo "7. with nothing staged, nothing is offered and the check is back"
launch
dump=$("$PROBE" texts $APP 2>&1)
! echo "$dump" | grep -q "ready to install"
check $? "no alert"
menu=$("$PROBE" statusmenu $APP 2>&1)
echo "$menu" | grep -q "Check for Updates…"
check $? "the menu offers a check again"
stop

echo "8. the launch check runs, and only when checking is allowed"
# Seeded with now, not with an old date: an old one would be overdue and
# Sparkle's own scheduler would check at launch anyway, which is the thing this
# has to be told apart from. A date that is not due isolates `checkAtLaunch`.
seed=$(date -u '+%Y-%m-%d %H:%M:%S +0000')
defaults write $ID SULastCheckTime -date "$seed"
before=$(readcheck)
launch
stop
after=$(readcheck)
[ -n "$before" ] && [ "$before" = "$after" ]
check $? "with checking off, launching asks nobody"

defaults write $ID SUEnableAutomaticChecks -bool true
defaults write $ID SULastCheckTime -date "$seed"
before=$(readcheck)
launch
stop
after=$(readcheck)
[ -n "$after" ] && [ "$before" != "$after" ]
check $? "with checking on, a launch is a check, even though one was not due"

defaults delete $ID >/dev/null 2>&1
rm -rf "$DIR"
echo
echo "$pass passed, $fail failed"
[ "$fail" = "0" ]
