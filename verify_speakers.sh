#!/bin/bash
# Every way a speaker can be changed, as assertions, over a scratch library
# built from copies of real recordings. No audio is copied and the real library
# is never opened for writing.
#
# It exists because the window's three sizes of speaker edit were reported
# losing work: a name put on one turn was gone by the time its author looked
# back. The defect it found on the first run is the one the "one turn is one
# turn" section below fences off, and the rest of the file is the surrounding
# behaviour, so the next change to `TranscriptEditor` has something to fail
# against.
set -u

BIN="$(cd "$(dirname "$0")" && pwd)/Listen.app/Contents/MacOS/Listen"
SRC="$HOME/Library/Application Support/Listen/recordings"
export LISTEN_LIBRARY="${TMPDIR:-/tmp}/listen-verify-speakers"

# A long two-track meeting: Me and Nick talking over each other for an hour and
# a half, plus two speakers with a turn or two each. The overlap is the point.
# Turns from the two tracks interleave, so consecutive turns by one speaker
# touch at the edges, and that is the shape that broke the reassignment.
MEETING=2026-08-25-155152-AD4A
# A short one, for the edits that act on a whole speaker.
WORKSHOP=2026-08-07-111927-1047

# The name every assertion moves somebody to, and it is deliberately not one
# anybody would type. The fixtures are copies of a real library that somebody
# keeps correcting, so a plausible name is one the recording can grow on its
# own: this script used "Marla" until the meeting acquired a speaker of that
# name between two runs, and three assertions counted four segments where they
# wanted two. `reset` refuses to run if the fixture has it.
NEW=ZZNew

pass=0; fail=0
reset() {
  rm -rf "$LISTEN_LIBRARY"; mkdir -p "$LISTEN_LIBRARY/recordings"
  for id in "$MEETING" "$WORKSHOP"; do
    # Loudly, because the alternative is a run that copies nothing, asserts
    # against an empty library and passes by finding nothing to be wrong.
    if [ ! -f "$SRC/$id/metadata.json" ]; then
      echo "missing fixture $id. Pick a recording of the same shape (the" >&2
      echo "comment beside the id says which) and update it at the top." >&2
      exit 2
    fi
    mkdir -p "$LISTEN_LIBRARY/recordings/$id"
    for f in metadata.json transcript.json turns.json embeddings.json; do
      [ -f "$SRC/$id/$f" ] && cp "$SRC/$id/$f" "$LISTEN_LIBRARY/recordings/$id/"
    done
    if grep -q "\"$NEW\"" "$LISTEN_LIBRARY/recordings/$id/transcript.json" 2>/dev/null; then
      echo "$id already has a speaker called $NEW. Change NEW at the top to" >&2
      echo "something nobody would type, or these counts will be wrong." >&2
      exit 2
    fi
  done
}

check() {  # <what> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$1" "$2" "$3"; fi
}

# Every speaker in the transcript with how many turns they hold, as one line.
tally() {  # <id>
  python3 -c "
import json, sys
from collections import Counter
turns = json.load(open('$LISTEN_LIBRARY/recordings/$1/turns.json'))
count = Counter(t['speaker'] for t in turns)
print(' '.join('%s=%d' % kv for kv in sorted(count.items())))"
}

# What changed between two tallies, as "Me-1 $NEW+1".
#
# Deltas rather than absolute counts, because the fixtures are copies of a real
# library that somebody keeps using: this recording grew a speaker called "dd"
# between two runs of this script and five assertions failed for that rather
# than for anything in the code. That is the worst kind of failing test, because
# it points at the change in front of you. See the same warning in CLAUDE.md
# about `verify_title.sh`.
delta() {  # <before> <after>
  python3 -c "
import sys
def read(text):
    out = {}
    for part in text.split():
        name, _, count = part.rpartition('=')
        out[name] = int(count)
    return out
before, after = read(sys.argv[1]), read(sys.argv[2])
moves = []
for name in sorted(set(before) | set(after)):
    change = after.get(name, 0) - before.get(name, 0)
    if change:
        moves.append('%s%+d' % (name, change))
print(' '.join(moves) if moves else 'nothing')" "$1" "$2"
}

turn() {  # <id> <index> -> "<speaker> <start> <end>"
  python3 -c "
import json
turns = json.load(open('$LISTEN_LIBRARY/recordings/$1/turns.json'))
t = turns[$2]
print('%s %.2f %.2f' % (t['speaker'], t['start'], t['end']))"
}

# What the window hands `TranscriptEditor` when somebody uses the pill on turn
# n: the speaker it is attributed to, and the window it occupies.
move_turn() {  # <id> <index> <name>
  read -r who start end <<<"$(turn "$1" "$2")"
  "$BIN" label "$1" "$who" --move-turn "$start" "$end" "$3" >/dev/null 2>&1
}

segments_of() {  # <id> <speaker>
  python3 -c "
import json
d = json.load(open('$LISTEN_LIBRARY/recordings/$1/transcript.json'))
print(sum(1 for s in d['segments'] if s['speaker'] == '$2'))"
}

echo "one turn is one turn"
# The bug this file was written for. Turn 4 (Me, 88.32-98.40) and turn 6 (Me,
# 98.40-106.16) are two paragraphs with one of Nick's between them, and they
# touch: turn 6 starts at the instant turn 4 ends. Moving turn 4 by sweeping
# every segment of Me's inside its window took turn 6 with it, silently. Nobody
# had selected turn 6, nothing on screen said it had gone, and the repair anyone
# would reach for is a whole-speaker edit on the name they had just made, which
# is how one turn's correction became none.
reset
check "the fixture still has two turns that touch" \
      "Me 98.40 106.16" "$(turn $MEETING 6)"
was_me=$(segments_of $MEETING Me)
before=$(tally $MEETING)
move_turn $MEETING 4 "$NEW"
check "the turn that was asked for moved"      "$NEW 88.32 98.40" "$(turn $MEETING 4)"
check "and the one that touches it did not"    "Me 98.40 106.16"   "$(turn $MEETING 6)"
check "one paragraph left its speaker"         "Me-1 $NEW+1" \
                                               "$(delta "$before" "$(tally $MEETING)")"
# The paragraph is two sentences, and both of them and no more came out of Me.
check "two sentences moved, not the next turn's" "2" "$(segments_of $MEETING "$NEW")"
check "and Me is short by exactly those two"     "$((was_me - 2))" "$(segments_of $MEETING Me)"

echo
echo "every paragraph in the meeting, one at a time"
# The sweep. Each turn is moved to a name nobody has, on a fresh copy, and what
# moved is rebuilt from the segments and compared with the paragraph that was on
# screen. It is the assertion the section above makes, made once per paragraph,
# and it is what says the fold and the window agree everywhere rather than at the
# one place the bug was found.
reset
python3 - "$LISTEN_LIBRARY/recordings/$MEETING" "$BIN" "$MEETING" <<'SWEEP'
import json, os, subprocess, sys

folder, binary, ident = sys.argv[1], sys.argv[2], sys.argv[3]
pristine = {f: open(os.path.join(folder, f)).read()
            for f in ("transcript.json", "turns.json", "metadata.json")}
turns = json.load(open(os.path.join(folder, "turns.json")))
bad = []
for i, turn in enumerate(turns):
    for name, text in pristine.items():
        open(os.path.join(folder, name), "w").write(text)
    for stale in os.listdir(folder):
        if stale.endswith(".bak"):
            os.remove(os.path.join(folder, stale))
    subprocess.run([binary, "label", ident, turn["speaker"], "--move-turn",
                    "%.10g" % turn["start"], "%.10g" % turn["end"], "ZZTest"],
                   capture_output=True)
    after = json.load(open(os.path.join(folder, "transcript.json")))["segments"]
    moved = " ".join(s["text"].strip() for s in after if s["speaker"] == "ZZTest")
    if moved != turn["text"]:
        bad.append((i, turn["speaker"], turn["start"], moved[:60], turn["text"][:60]))
for i, who, start, got, want in bad[:5]:
    print("  turn %d (%s at %.2f)" % (i, who, start))
    print("    want %s" % want)
    print("    got  %s" % got)
print("  (%d of %d paragraphs moved exactly themselves)" % (len(turns) - len(bad), len(turns)))
sys.exit(1 if bad else 0)
SWEEP
check "every paragraph moves exactly itself" "0" "$?"

echo
echo "a name made on one turn survives the next edit"
# The report, replayed. Name one paragraph, then correct a different one, and
# look again.
reset
before=$(tally $MEETING)
move_turn $MEETING 4 "$NEW"
move_turn $MEETING 2 Rita
check "the new name is still there"       "$NEW 88.32 98.40" "$(turn $MEETING 4)"
check "and so is the second edit"  "Me-2 Rita+1 $NEW+1" \
                                   "$(delta "$before" "$(tally $MEETING)")"
move_turn $MEETING 6 Beile
check "and a third leaves both"    "Beile+1 Me-3 Rita+1 $NEW+1" \
                                   "$(delta "$before" "$(tally $MEETING)")"

echo
echo "a window that names no turn is refused, not guessed at"
# The compare-and-swap. A pane drawn before something else edited the transcript
# hands over a window that no longer folds into a paragraph, and the edit has to
# refuse rather than move whatever is nearest.
reset
before=$(tally $MEETING)
"$BIN" label $MEETING Me --move-turn 88.32 98.00 "$NEW" >/dev/null 2>&1
check "an end that is nobody's turn writes nothing"   "$before" "$(tally $MEETING)"
"$BIN" label $MEETING Nick --move-turn 88.32 98.40 "$NEW" >/dev/null 2>&1
check "the right window and the wrong speaker too"    "$before" "$(tally $MEETING)"
"$BIN" label $MEETING Me --move-turn 0 9999 "$NEW" >/dev/null 2>&1
check "and a window over the whole recording"         "$before" "$(tally $MEETING)"

echo
echo "the same paragraph, moved twice"
reset
before=$(tally $MEETING)
move_turn $MEETING 4 "$NEW"
move_turn $MEETING 4 Beile
check "the second move finds it under its new name" "Beile 88.32 98.40" "$(turn $MEETING 4)"
check "and nobody is left behind"                   "Beile+1 Me-1" \
                                                    "$(delta "$before" "$(tally $MEETING)")"

echo
echo "moving every turn of a speaker takes the speaker with it"
# `.reassign` re-reads the recording afterwards and drops the voiceprint only
# when the label has gone from the transcript entirely.
reset
before=$(tally $MEETING)
"$BIN" label $MEETING Rita --merge-into Beile >/dev/null 2>&1
check "merged away, and gone from the transcript" "Beile+2 Rita-2" \
                                                  "$(delta "$before" "$(tally $MEETING)")"
check "and gone from the voice bank"              "0" \
      "$(python3 -c "
import json
bank = json.load(open('$LISTEN_LIBRARY/recordings/$MEETING/embeddings.json'))
print(sum(1 for k in bank if k == 'Rita'))")"

echo
echo "the whole-speaker edits still act on the whole speaker"
reset
before=$(segments_of $WORKSHOP Nick)
"$BIN" label $WORKSHOP Nick "Nick Adams" >/dev/null 2>&1
check "a rename moves every segment"  "$before" "$(segments_of $WORKSHOP 'Nick Adams')"
check "and leaves none behind"        "0"       "$(segments_of $WORKSHOP Nick)"
"$BIN" label $WORKSHOP "Nick Adams" --unname >/dev/null 2>&1
check "unnaming puts them back to a letter" "0" "$(segments_of $WORKSHOP 'Nick Adams')"

echo
echo "one sentence is one sentence"
reset
"$BIN" label $MEETING Me --move 4 "$NEW" >/dev/null 2>&1
check "the segment moved"          "1" "$(segments_of $MEETING "$NEW")"
"$BIN" label $MEETING Me --move 4 Beile >/dev/null 2>&1
check "and a stale index is refused" "1" "$(segments_of $MEETING "$NEW")"

echo
echo "a selection is every sentence it touches"
# The window's sentence menu acts on the selection, so the scope carries a list
# and the CLI takes one. Reported as: selecting the bottom half of a paragraph
# and asking who said it moved the first sentence and left the rest.
reset
"$BIN" label $MEETING Me --move 4,5,6 "$NEW" >/dev/null 2>&1
check "three sentences moved together" "3" "$(segments_of $MEETING "$NEW")"
# All or nothing. Segment 4 is somebody else's now, so the whole list is
# refused rather than half-applied across two speakers.
"$BIN" label $MEETING Me --move 4,7,8 Beile >/dev/null 2>&1
check "and one stale index refuses the lot" "3" "$(segments_of $MEETING "$NEW")"
check "with nothing half-written"           "0" \
      "$(python3 -c "
import json
d = json.load(open('$LISTEN_LIBRARY/recordings/$MEETING/transcript.json'))
print(sum(1 for i in (7, 8) if d['segments'][i]['speaker'] == 'Beile'))")"

echo
echo "a sentence can be deleted, which an emptied field still refuses to mean"
# Asked for after finding the model had heard one sentence twice, once at the
# end of a paragraph and again at the start of the next, which is what a
# two-track recording produces where the speakers overlap. Emptying the Edit
# Sentence field is still refused, deliberately; this is the verb that means it.
reset
was=$(segments_of $MEETING Me)
text=$(python3 -c "
import json
d = json.load(open('$LISTEN_LIBRARY/recordings/$MEETING/transcript.json'))
print(d['segments'][4]['text'].strip())")
"$BIN" edit $MEETING --delete "$text" >/dev/null 2>&1
check "the sentence is gone"       "$((was - 1))" "$(segments_of $MEETING Me)"
check "and nobody else lost one"   "$(python3 -c "
import json
d = json.load(open('$LISTEN_LIBRARY/recordings/$MEETING/transcript.json'))
print(sum(1 for s in d['segments'] if s['speaker'] == 'Nick'))")" \
                                   "$(segments_of $MEETING Nick)"
"$BIN" edit $MEETING --delete "$text" >/dev/null 2>&1
check "deleting it again finds nothing" "$((was - 1))" "$(segments_of $MEETING Me)"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
