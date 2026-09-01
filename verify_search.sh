#!/bin/bash
# Search that shows the match, as assertions, over a scratch library built from
# copies of real recordings. No audio is copied and the real library is never
# opened for writing.
#
# It exists because a search used to answer with a row and nothing else: the
# right recording, with nothing on it saying which of 38 minutes the word was
# in. What is checked here is the three things that changed. A result row
# carries the sentence that matched and how many there are; the page has a find
# bar with a counter on it; and clicking a result opens the page already on the
# first match.
#
# Driven through `tools/axprobe`, which is `AXUIElementCreateApplication(pid)`
# and nothing else, for the reason CLAUDE.md records against synthetic pointer
# events.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="${LISTEN_APP:-$HERE/Listen.app}"
BIN="$APP_BUNDLE/Contents/MacOS/Listen"
SRC="$HOME/Library/Application Support/Listen/recordings"
export LISTEN_LIBRARY="${TMPDIR:-/tmp}/listen-verify-search"

# A word in exactly one of the copied transcripts, several times over, which is
# what makes both halves of the row checkable at once: the excerpt has to name
# the speaker who said it, and the count has to be the number of times.
# Re-derive it with the probe at the foot of this file if the fixtures change.
TERM_BODY=iphone
TERM_BODY_COUNT=8
TERM_BODY_TITLE="Call with Joris Goossens"
# In a title and in no transcript, which is the row that must **not** grow a
# third line: repeating the title underneath itself is noise.
TERM_TITLE=marcia
# Written into the fixtures below, so they cannot be true by accident.
TERM_NOTE=frobnicate
TERM_CHAT=widgetsmith

PROBE="$HERE/.xcbuild/tools/axprobe"

pass=0; fail=0
check() {
    if [ "$1" -eq 0 ]; then echo "  ok   $2"; pass=$((pass+1))
    else echo "  FAIL $2"; fail=$((fail+1)); fi
}

if [ ! -x "$BIN" ]; then
    echo "no build at $BIN; run ./build.sh && ./make_app.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# The fixtures.

echo "building a scratch library at $LISTEN_LIBRARY"
rm -rf "$LISTEN_LIBRARY"
mkdir -p "$LISTEN_LIBRARY/recordings" "$LISTEN_LIBRARY/notes" "$LISTEN_LIBRARY/chats"

copied=0
for id in $(ls -1 "$SRC" | tail -8); do
    [ -f "$SRC/$id/turns.json" ] || continue
    mkdir -p "$LISTEN_LIBRARY/recordings/$id"
    for f in metadata.json transcript.json turns.json embeddings.json; do
        [ -f "$SRC/$id/$f" ] && cp "$SRC/$id/$f" "$LISTEN_LIBRARY/recordings/$id/"
    done
    copied=$((copied+1))
done
[ "$copied" -ge 4 ] || { echo "only $copied recordings copied; nothing to search" >&2; exit 1; }

# A note whose body carries a word nothing else does, so the note row's excerpt
# is the only thing that can produce it.
#
# **Its body is markdown with a bullet across a line break, on purpose.** A note
# is written by an agent as a document: headings, blank lines and lists. Cut a
# window out of that raw and the newlines came with it, so a row with two lines
# to spend drew four and painted them over the row below. The assertion below
# looks for the two sides of that break joined by a single space, which only
# happens when `Excerpt.flattened` has run.
cat > "$LISTEN_LIBRARY/notes/search-fixture.md" <<EOF
---
title: "Search fixture"
created: 2026-09-01T09:00:00Z
updated: 2026-09-01T09:00:00Z
source: cli
---

# Search fixture

A paragraph of ordinary words so the excerpt has something to cut around.

- Then the word $TERM_NOTE sits after a bullet, followed by more ordinary
  words so both ends of the window have somewhere to go.
EOF

# And a conversation carrying another, for the handoff row.
cat > "$LISTEN_LIBRARY/chats/2026-09-01-090000-FFFF.json" <<EOF
{"backend":"claude","created":"2026-09-01T09:00:00Z","updated":"2026-09-01T09:00:00Z",
 "id":"2026-09-01-090000-FFFF","title":"A fixture conversation","turns":[
 {"at":"2026-09-01T09:00:00Z","who":"you","text":"what did we say about $TERM_CHAT"},
 {"at":"2026-09-01T09:00:05Z","who":"agent","text":"Nothing about $TERM_CHAT came up."}]}
EOF

# The probe is compiled on demand, the way the other scripts do it.
mkdir -p "$HERE/.xcbuild/tools"
if [ ! -x "$PROBE" ] || [ "$HERE/tools/axprobe.swift" -nt "$PROBE" ]; then
    swiftc -O "$HERE/tools/axprobe.swift" -o "$PROBE" 2>/dev/null \
        || { echo "could not build axprobe" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# Launch and drive, in one shell, for the reason CLAUDE.md gives: `open`
# resolves through Launch Services to /Applications and drops the environment
# with it, which opens the real library.

# The trace is how the scroll is checked. Where a find jump lands is a fact no
# AX tree carries: every `TurnView` is in the tree whether or not it is on
# screen, so a page that never moved reads exactly like one that moved
# correctly. It was wrong once, in the direction, and only a screenshot showed
# it.
export LISTEN_DEBUG=1
TRACE="${TMPDIR:-/tmp}/listen-verify-search.log"
: > "$TRACE"

"$BIN" 2>"$TRACE" >/dev/null &
APP=$!
trap 'kill $APP 2>/dev/null' EXIT
sleep 6

dump=$("$PROBE" texts $APP 2>&1)
case $? in
    3) echo "  SKIP: this terminal has no Accessibility permission" >&2; exit 2;;
esac
# A sleeping display empties every window's subtree with no error, so a script
# grepping for absence would pass on nothing at all.
echo "$dump" | grep -qi "record" \
    || { echo "  SKIP: empty AX tree (is the display asleep?)" >&2; exit 2; }

search() {
    "$PROBE" focus $APP "Search" >/dev/null 2>&1
    sleep 1
    "$PROBE" settext $APP "Search" "$1" >/dev/null 2>&1
    sleep 3
}

# **The shape of an excerpt line, and the only thing on a row that has it.**
#
# `Maxime  15:52  …Ik heb een iPhone, dus…`: a speaker, two spaces, a
# timestamp, two spaces. The subtitle beside it is `Saturday · 15:27 · 41:30`,
# which has the separators and not the doubled spaces, and no other row in the
# list carries either.
#
# It is asserted positively in 1 and negatively in 2 on purpose. A negative
# assertion whose pattern matches nothing anywhere passes on an empty screen,
# which is the failure this whole file is written to avoid; matching it in 1 is
# the control that says the pattern is real.
EXCERPT='[A-Za-z]+  [0-9][0-9]:[0-9][0-9]  '

echo
echo "1. a transcript match shows the sentence and how many"
search "$TERM_BODY"
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -qiE "$EXCERPT.*$TERM_BODY"
check $? "the row grew an excerpt line naming the speaker and the time"
# Its own label on the row, not a digit loose somewhere in the window: a bare
# grep for the number matches half the timestamps on screen.
echo "$dump" | grep -qE "^AXStaticText(	)+$TERM_BODY_COUNT(	|\$)"
check $? "and the count says $TERM_BODY_COUNT"
echo "$dump" | grep -q "$TERM_BODY_TITLE"
check $? "on the one recording that has it"

echo
echo "2. a title match does not repeat itself underneath"
search "$TERM_TITLE"
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -qi "marcia"
check $? "the row is in the list"
! echo "$dump" | grep -qE "$EXCERPT"
check $? "and it grew no excerpt line"

echo
echo "3. a note's body is excerpted too"
search "$TERM_NOTE"
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -qi "Search fixture"
check $? "the note row is in the list"
echo "$dump" | grep -qi "$TERM_NOTE"
check $? "and the row shows the sentence carrying \"$TERM_NOTE\""
# The two sides of a line break and a bullet, joined by one space. Raw, this
# reads "around.\n- Then the word", and the row drew four lines over its
# neighbour. See `Excerpt.flattened`.
echo "$dump" | grep -q "around. Then the word $TERM_NOTE"
check $? "and the markdown is flattened into one line of prose"

echo
echo "4. conversations are offered, not listed"
search "$TERM_CHAT"
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -qi "See .* chat result"
check $? "a handoff row offers the chats that mention it"
"$PROBE" press $APP "chat result" >/dev/null 2>&1
sleep 2
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -qi "A fixture conversation"
check $? "pressing it lands in Chats with the query carried over"

echo
echo "5. the find bar counts, and the ellipsis offers it"
"$PROBE" press $APP "Back" >/dev/null 2>&1
sleep 2
search "$TERM_BODY"
"$PROBE" selectrow $APP "$TERM_BODY_TITLE" >/dev/null 2>&1
sleep 3
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -qE "1 of $TERM_BODY_COUNT"
check $? "clicking the result opens the page on match 1 of $TERM_BODY_COUNT"
# 60 is `DetailView.findLead`. Any other number means the two coordinate
# systems have been mixed again: the stack counts up from its bottom and the
# clip view counts down from the document's top, and using one where the other
# belongs scrolls most of a meeting the wrong way while still "scrolling".
grep -q "find scroll .* lead=60" "$TRACE"
check $? "and the match lands 60 points below the top of the transcript"
"$PROBE" press $APP "Next match" >/dev/null 2>&1
sleep 1
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -qE "2 of $TERM_BODY_COUNT"
check $? "and Next steps to 2"
"$PROBE" press $APP "Previous match" >/dev/null 2>&1
sleep 1
"$PROBE" press $APP "Previous match" >/dev/null 2>&1
sleep 1
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -qE "$TERM_BODY_COUNT of $TERM_BODY_COUNT"
check $? "and Previous wraps backwards past the start"

# `showmenu`, not `press`: the toolbar's ellipsis is an `NSMenuToolbarItem` and
# `AXPress` on it returns success while doing nothing, which is
# indistinguishable from a menu that was never built. A menu's items are in the
# tree only while it is open, so the order is showmenu, read, press.
"$PROBE" showmenu $APP "Actions" >/dev/null 2>&1
sleep 1
dump=$("$PROBE" texts $APP 2>&1)
echo "$dump" | grep -q "Find in Page"
check $? "and the ellipsis lists Find in Page"

echo
echo "6. Done puts it away"
"$PROBE" press $APP "Done" >/dev/null 2>&1
sleep 1
dump=$("$PROBE" texts $APP 2>&1)
! echo "$dump" | grep -qE "of $TERM_BODY_COUNT"
check $? "the counter is gone"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
