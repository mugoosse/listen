#!/bin/bash
#
# The week's review: which cards it makes, and what each one is allowed to say.
#
# Over a synthetic library the script builds, so it needs no recordings, no
# model and no network. `listen review --json` is the same `WeeklyReview.build`
# the deck renders, so a card that is wrong here is wrong on screen.
#
# What it exists to catch:
#
#   - **A card with no verb.** Every card but the opening one and the counts
#     has to offer something to do. A card nobody can answer is a feed post,
#     and the whole argument for a review rather than a digest is that
#     answering is what makes memory better instead of merely bigger.
#   - **Two counts of one idea.** The loose-ends card and `listen context
#     status` both count recordings waiting for a speaker name. They said four
#     and two about the same library until both went through
#     `ContextEnrolment.needsNames`.
#   - **Somebody being called new who is not**, which is the only claim on the
#     page that is about the past rather than about this week.
#
set -uo pipefail
cd "$(dirname "$0")"

APP="${LISTEN_APP:-Listen.app/Contents/MacOS/Listen}"
[ -x "$APP" ] || { echo "no app at $APP; run ./build.sh && ./make_app.sh"; exit 1; }

LIB="$(mktemp -d)/library"
mkdir -p "$LIB/recordings"
trap 'rm -rf "$(dirname "$LIB")"' EXIT
run() { LISTEN_LIBRARY="$LIB" "$APP" "$@"; }

pass=0; fail=0
ok() { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

# Two conversations this week and one long ago, so "new this week" has
# something to be wrong about: Ada speaks only in the old one and must not be
# called new, and must be the one who is out of touch. One recording has no
# named speaker at all, which is the loose end.
python3 - "$LIB" <<'PY'
import json, os, sys, time
lib = sys.argv[1]
now = time.time()
def meeting(rid, ago_days, title, turns):
    when = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - ago_days * 86400))
    d = os.path.join(lib, "recordings", rid)
    os.makedirs(d, exist_ok=True)
    segs, t = [], 0.0
    for speaker, text in turns:
        segs.append({"start": t, "end": t + 30, "speaker": speaker, "text": text}); t += 30
    json.dump({"id": rid, "recorded_at": when, "title": title, "state": "done",
               "duration": t, "source": "detected", "room": False},
              open(d + "/metadata.json", "w"))
    json.dump(segs, open(d + "/turns.json", "w"))
    json.dump({"duration": t, "segments": segs, "wordLevel": False,
               "model": "mlx-community/parakeet-tdt-0.6b-v2", "cleanup": {}, "dictionary": {}},
              open(d + "/transcript.json", "w"))

meeting("rec-this-week-1", 2, "Call with Nick", [
    ("Me",   "Where did the pricing work land?"),
    ("Nick", "I lead the platform team and the numbers are ready."),
])
meeting("rec-this-week-2", 4, "Call with Bo", [
    ("Bo", "I run design and I am hiring two people."),
    ("Me", "Send me the roles."),
])
# Ada, twice, long ago: enough conversations to count as a relationship, and
# old enough to be out of touch.
meeting("rec-old-1", 200, "Call with Ada", [
    ("Ada", "I have taken over the platform team."),
    ("Me",  "Congratulations."),
])
meeting("rec-old-2", 190, "Call with Ada again", [
    ("Ada", "The handover is finished."),
    ("Me",  "Good."),
])
# Nobody named: the loose end.
meeting("rec-unnamed", 1, "New recording", [
    ("A", "Some words nobody has attributed."),
    ("B", "More of them."),
])
PY

echo "Synthetic library: $LIB"
run context index >/dev/null 2>&1

r=$(run review --days 7 --json 2>/dev/null)
q() { printf '%s' "$r" | python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }
kinds=$(q "['card_kinds']")

echo
echo "Which cards the week makes"
printf '%s' "$r" | python3 -c "import json,sys;print('  ..   ' + ', '.join(json.load(sys.stdin)['card_kinds']))"
case "$kinds" in *"'week'"*) ok "it opens with the week itself";; *) no "it opens with the week itself";; esac
case "$kinds" in *"'newPeople'"*) ok "somebody new gets a card";; *) no "somebody new gets a card";; esac
case "$kinds" in *"'looseEnds'"*) ok "the recording nobody has named gets a card";; *) no "the recording nobody has named gets a card";; esac
case "$kinds" in *"'outOfTouch'"*) ok "the person nobody has spoken to gets a card";; *) no "the person nobody has spoken to gets a card";; esac

echo
echo "What the cards say"
# Two this week plus the unnamed one; the two old ones are outside the window.
week=$(printf '%s' "$r" | python3 -c "
import json,sys
for c in json.load(sys.stdin)['cards']:
    if c['kind']=='week': print(c['detail'])")
case "$week" in "3 conversations"*) ok "the week counts only this week's conversations";; *) no "the week counts only this week's conversations (got '$week')";; esac

newpeople=$(printf '%s' "$r" | python3 -c "
import json,sys
for c in json.load(sys.stdin)['cards']:
    if c['kind']=='newPeople': print(','.join(sorted(i['text'] for i in c['items'])))")
is "the new people are the ones first heard this week" "$newpeople" "Bo,Nick"

stale=$(printf '%s' "$r" | python3 -c "
import json,sys
for c in json.load(sys.stdin)['cards']:
    if c['kind']=='outOfTouch': print(c['title'])")
case "$stale" in *Ada*) ok "and the one out of touch is the one from months ago";; *) no "and the one out of touch is the one from months ago (got '$stale')";; esac

echo
echo "Every card can be answered"
verbless=$(printf '%s' "$r" | python3 -c "
import json,sys
bad=[c['kind'] for c in json.load(sys.stdin)['cards'] if not c['verbs'] and c['kind']!='week']
print(','.join(bad))")
is "no card is offered that nobody can act on" "$verbless" ""

echo
echo "One idea, one count"
# The loose-ends card and `context status` must agree about how many
# recordings are waiting for a speaker name.
loose=$(printf '%s' "$r" | python3 -c "
import json,sys
print(sum(len(c['items']) for c in json.load(sys.stdin)['cards'] if c['kind']=='looseEnds'))")
status=$(run context status --json 2>/dev/null | python3 -c "import json,sys;print(json.load(sys.stdin)['waitingForNames'])")
is "the review and context status agree on what needs a name" "$loose" "$status"

echo
echo "The reveal names only this week"
stars=$(q "['new_stars']")
case "$stars" in *rec-this-week-1*) ok "this week's recordings are revealed";; *) no "this week's recordings are revealed";; esac
case "$stars" in *rec-old-1*) no "an old recording must not be revealed";; *) ok "and the old ones are already there";; esac

echo
echo "One person, over a longer window"
# A catch-up answers "where were we", which is a question about the
# relationship: seven days of somebody you see monthly is an empty page, so a
# person defaults to ninety.
pr=$(run review --person Nick --json 2>/dev/null)
pq() { printf '%s' "$pr" | python3 -c "import json,sys;print(json.load(sys.stdin)$1)"; }
is "a person's review defaults to a season, not a week" "$(pq "['days']")" "90"
pkinds=$(pq "['card_kinds']")
printf '%s' "$pr" | python3 -c "import json,sys;print('  ..   ' + ', '.join(json.load(sys.stdin)['card_kinds']))"
case "$pkinds" in *"'week'"*) ok "it opens on the person and the span";; *) no "it opens on the person and the span";; esac
# The three library cards that make no sense about one person: who is new is
# about everybody, a recording with no speaker cannot be attributed to them,
# and telling you that you have not spoken to the person whose page you just
# opened is a nag.
case "$pkinds" in *newPeople*) no "a person's review must not ask who is new";; *) ok "a person's review does not ask who is new";; esac
case "$pkinds" in *outOfTouch*) no "nor nag about being out of touch with them";; *) ok "nor nags about being out of touch with them";; esac
ptitle=$(printf '%s' "$pr" | python3 -c "
import json,sys
for c in json.load(sys.stdin)['cards']:
    if c['kind']=='week': print(c['title'])")
case "$ptitle" in Nick*) ok "and it is named after them";; *) no "and it is named after them (got '$ptitle')";; esac
case "$pkinds" in *looseEnds*) ok "their own conversations are listed";; *) no "their own conversations are listed";; esac

# The empty window is its own answer rather than a blank page: Ada was last
# spoken to months ago, so ninety days of her has nothing in it.
ar=$(run review --person Ada --days 30 --json 2>/dev/null)
adetail=$(printf '%s' "$ar" | python3 -c "
import json,sys
for c in json.load(sys.stdin)['cards']:
    if c['kind']=='week': print(c['detail'])")
case "$adetail" in *"Nothing recorded"*) ok "an empty window says so, and how long it has been";; *) no "an empty window says so (got '$adetail')";; esac
case "$adetail" in *"days ago"*) ok "and how long since you last spoke";; *) no "and how long since you last spoke";; esac

# ------------------------------------------------------------------ the deck
if [ "${1:-}" = "--ui" ]; then
  echo
  echo "The deck"
  PROBE="$(pwd)/.xcbuild/tools/axprobe"
  [ -x "$PROBE" ] || swiftc -O tools/axprobe.swift -o "$PROBE" || exit 2
  D="${TMPDIR:-/tmp}/listen-verify-review-ui"
  rm -rf "$D"; mkdir -p "$D/hf"
  cp -R "$LIB" "$D/library"
  cp -R Listen.app "$D/T.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
      "$D/T.app/Contents/Info.plist" >/dev/null
  codesign --force --sign - --deep "$D/T.app" 2>/dev/null
  defaults delete com.mgo.listen-uitest >/dev/null 2>&1
  defaults write com.mgo.listen-uitest onboarded -bool true
  # Long enough to cover the launch, the activation loop and the reads. At
  # three seconds it expired before the first `texts`, the display slept, and
  # the window's whole subtree came back empty: the walk then reports only the
  # application element, over and over, which reads exactly like a deck that
  # rendered nothing. See ".agents": a sleeping display empties the AX tree.
  caffeinate -u -t 40 2>/dev/null
  LISTEN_LIBRARY="$D/library" HF_HOME="$D/hf" LISTEN_PANEL=review LISTEN_DEBUG=1 \
      LISTEN_NO_KEYCHAIN=1 LISTEN_NO_TELEMETRY=1 \
      "$D/T.app/Contents/MacOS/Listen" > "$D/trace.txt" 2>&1 &
  UI=$!
  sleep 8
  # Activation is not granted on the first ask to a background process, and a
  # run where it was not looks exactly like a window that never drew. Loop.
  for i in 1 2 3 4 5 6; do a=$("$PROBE" activate $UI 2>&1); [ "$a" = "active" ] && break; sleep 1; done
  sleep 2
  texts() { "$PROBE" texts $UI 2>/dev/null | awk -F'\t' '{v=($4!=""?$4:$3); if(v!="") print v}'; }
  # Whether the walk reached the window at all, which is a different question
  # from whether it read anything: the menu bar alone fills a dump.
  sawWindow() { "$PROBE" texts $UI 2>/dev/null | awk -F'\t' '$1=="AXWindow"{f=1} END{exit f?0:1}'; }
  first=$(texts)
  # Captured now rather than in the skip below, which runs after the app has
  # been killed and would report an empty tree every time whatever happened.
  roles=$("$PROBE" texts $UI 2>/dev/null | awk -F'\t' '{print $1}' | sort | uniq -c | sort -rn | head -3 | tr '\n' ' ')
  "$PROBE" press $UI "Next" >/dev/null 2>&1; sleep 2
  second=$(texts)
  kill $UI 2>/dev/null

  # **A harness that could not bring the app forward has not tested the deck.**
  # Activation is not always granted to a background process, and when it is
  # refused the window is not in the tree at all: the walk spends its whole
  # budget on the menu bar (8,460 menu items, in the run that prompted this)
  # and every assertion below fails for a reason that has nothing to do with
  # the code. Skipping says that; failing would send somebody to read a deck
  # that is fine.
  # **The precondition is a window in the tree, not a successful activate.**
  # `axprobe walk` spends a fixed budget and the menu bar can eat all of it:
  # measured here at 8,460 `AXMenuItem` rows and 406 visits to the menu bar
  # itself, with no window element reached at all, on a run where `activate`
  # had answered "active". Every assertion below then fails for a reason that
  # has nothing to do with the deck, which renders correctly in a screenshot
  # taken in the same second. Worth fixing in `axprobe` (visit windows before
  # `AXExtrasMenuBar`, and do not re-enter it); until then, say so rather than
  # send somebody to read a deck that is fine.
  if ! sawWindow; then
    echo "  SKIP: no window in the AX tree (activate said '$a'); the deck was not read"
    echo "        what the walk saw instead: $roles"
  else
    ok "the review page comes up"
    echo "$first" | grep -q "Your week" && ok "it opens on the week" || no "it opens on the week"
    echo "$first" | grep -qE "of [0-9]+" && ok "and says where you are in the deck" || no "and says where you are in the deck"
    echo "$second" | grep -q "new people" && ok "Next moves to the next card" || no "Next moves to the next card"
    echo "$second" | grep -q "Leave out" && ok "and that card carries its verbs" || no "and that card carries its verbs"
  fi
  # The galaxy is drawn by the GPU and is invisible to the tree, so whether it
  # is running is read out of the trace, the way `verify_galaxy.sh` reads it.
  grep -q "galaxy motion on" "$D/trace.txt" \
    && ok "the picture keeps drifting while a card holds a star" \
    || no "the picture keeps drifting while a card holds a star"
  # The reveal is the one part of this nothing else can see: a screenshot taken
  # after it finishes is identical to one with no animation at all, and the AX
  # tree has never known anything about the scene. It was silently dead once
  # already, because `policy.flights` includes `visible` and a review opened
  # while the window is still coming up is not visible yet.
  grep -qE "galaxy reveal [0-9]+ stars" "$D/trace.txt" \
    && ok "this week's stars arrive rather than being there already" \
    || no "this week's stars arrive rather than being there already"
  grep -q "galaxy reveal done" "$D/trace.txt" \
    && ok "and the arrival finishes instead of stalling part way" \
    || no "and the arrival finishes instead of stalling part way"
  defaults delete com.mgo.listen-uitest >/dev/null 2>&1
  rm -rf "$D"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
