#!/bin/bash
# Every claim the title-provenance work makes, as assertions, over a scratch
# library built from copies of real recordings. No audio is copied and the real
# library is never opened for writing.
set -u

BIN="$(cd "$(dirname "$0")" && pwd)/Listen.app/Contents/MacOS/Listen"
SRC="$HOME/Library/Application Support/Listen/recordings"
export LISTEN_LIBRARY="${TMPDIR:-/tmp}/listen-verify-title"

CELINE=2026-08-08-150113-9BA4   # untitled, WhatsApp, Me + Céline, no placeholders
FRANCESCO=2026-08-08-122758-67E2 # untitled, no call app, Me + Francesco
WORKSHOP=2026-08-07-111927-1047  # typed title, Nick + an unnamed B
IMPORTED=2026-07-17-095222-B5D2  # legacy Python import title, no source
EVENT=2026-08-13-092646-0C16     # matches a real calendar event three minutes later
MEMO=2026-08-26-122058-3B28      # recorded on the phone, Me + Rita, no placeholders

pass=0; fail=0
reset() {
  rm -rf "$LISTEN_LIBRARY"; mkdir -p "$LISTEN_LIBRARY/recordings"
  for id in "$CELINE" "$FRANCESCO" "$WORKSHOP" "$IMPORTED" "$EVENT" "$MEMO"; do
    # Loudly, because the alternative is a run that copies nothing, asserts
    # against an empty library, and passes by finding no title to be wrong.
    # These are six real recordings and any of them can be deleted.
    if [ ! -f "$SRC/$id/metadata.json" ]; then
      echo "missing fixture $id. Pick a recording of the same shape (the" >&2
      echo "comment beside the id says which) and update it at the top." >&2
      exit 2
    fi
    mkdir -p "$LISTEN_LIBRARY/recordings/$id"
    for f in metadata.json transcript.json turns.json embeddings.json voiceprints.json; do
      [ -f "$SRC/$id/$f" ] && cp "$SRC/$id/$f" "$LISTEN_LIBRARY/recordings/$id/"
    done
  done
  # The two "untitled" fixtures are made untitled again in the copy.
  #
  # They are real recordings in a library somebody uses, and the app titles a
  # recording the moment its last speaker is named, so both had grown a "Call
  # with ..." since this script was written. Six assertions failed for that and
  # not for anything in the code, which is the worst kind of failing test: it
  # points at the change in front of you. What the tests need is the *shape*
  # (untitled, no source), so the copy is put into that shape rather than the
  # fixture being replaced every few weeks with one that will do the same.
  #
  # `title` is set to the placeholder rather than deleted. It is a **required**
  # key: `Metadata.title` is a non-optional `String`, so a file without it fails
  # to decode and the app reports no such recording, which looks from here like
  # the library being empty. Measured by deleting it: `listen list` printed "no
  # recordings yet" over a folder with four sidecars in it. See "The placeholder
  # is a key on disk and a word on screen" in `.agents/notes/titles.md`.
  for id in "$CELINE" "$FRANCESCO"; do
    python3 - "$LISTEN_LIBRARY/recordings/$id/metadata.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["title"] = "Untitled"
data.pop("title_source", None)
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
  done
  # The one named speaker in the Céline fixture is renamed to the name the
  # assertions below rename *from*.
  #
  # Same rot as the titles above and a nastier shape: she is `Céline` in the
  # live library now and `Céline Goossens` in that recording's own
  # `embeddings.json`, so a `listen label` from the old name renamed nobody,
  # the title stayed `Untitled`, and six assertions failed pointing squarely at
  # whatever change was in front of you. All three sidecars are rewritten
  # together, because a speaker's name is in every one of them and a fixture
  # that half agrees with itself is worse than one that is simply old.
  python3 - "$LISTEN_LIBRARY/recordings/$CELINE" <<'PY'
import json, pathlib, sys
folder, name = pathlib.Path(sys.argv[1]), "Céline Goossens"
for f in ("transcript.json", "turns.json"):
    path = folder / f
    if not path.exists(): continue
    data = json.loads(path.read_text())
    rows = data["segments"] if isinstance(data, dict) else data
    for row in rows:
        if row.get("speaker") not in (None, "Me"): row["speaker"] = name
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2))
path = folder / "embeddings.json"
if path.exists():
    data = json.loads(path.read_text())
    path.write_text(json.dumps(
        {(k if k == "Me" else name): v for k, v in data.items()},
        ensure_ascii=False, indent=2))
PY
  # Same for the legacy import, which has since been given a real name in the
  # live library. What the tests need from it is a title with no `title_source`
  # that no automatic titler may touch, and the Python pipeline's own string is
  # the one this file talks about.
  python3 - "$LISTEN_LIBRARY/recordings/$IMPORTED/metadata.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["title"] = "2607-17-Google Chrome"
data.pop("title_source", None)
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
  # The phone fixture is put back into the shape a memo arrives in, for the same
  # reason as the two above: it is a real recording that has since been named
  # after its speakers, and what these tests need is the shape.
  #
  # The title is **derived from the id** rather than typed here, which is the
  # claim under test: `Metadata.makeID` and the phone's default title are two
  # renderings of one wall clock, so this is the string `DeviceTitle` has to
  # rebuild. English month names, because `candidates(for:)` always tries
  # `en_US_POSIX` and a test that only passes in one locale is worse than none.
  python3 - "$LISTEN_LIBRARY/recordings/$MEMO/metadata.json" "$MEMO" <<'PY'
import datetime, json, sys
path, rid = sys.argv[1], sys.argv[2]
at = datetime.datetime.strptime(rid[:17], "%Y-%m-%d-%H%M%S")
data = json.load(open(path))
data["source"] = "iphone"
data["title"] = f"Memo, {at.day} {at:%B}, {at:%H:%M}"
data.pop("title_source", None)
json.dump(data, open(path, "w"), indent=2, sort_keys=True)
PY
  cp "$HOME/Library/Application Support/Listen/contacts.json" "$LISTEN_LIBRARY/" 2>/dev/null
}
memo_title() {  # the string the phone would have written for the memo fixture
  python3 -c "
import datetime
at = datetime.datetime.strptime('$MEMO'[:17], '%Y-%m-%d-%H%M%S')
print(f'Memo, {at.day} {at:%B}, {at:%H:%M}')"
}
field() {  # <id> <key>
  python3 -c "
import json;m=json.load(open('$LISTEN_LIBRARY/recordings/$1/metadata.json'))
print(m.get('$2') if m.get('$2') is not None else '-')"
}
check() {  # <what> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$1" "$2" "$3"; fi
}

echo "the title follows the speakers until somebody types one"
reset
"$BIN" label "$CELINE" "Céline Goossens" "Celine" >/dev/null 2>&1
check "a rename names the recording"        "Call with Celine" "$(field $CELINE title)"
check "and records that the app did it"     "people"           "$(field $CELINE title_source)"
"$BIN" label "$CELINE" "Celine" "Céline Goossens" >/dev/null 2>&1
check "a second rename follows it"          "Call with Céline Goossens" "$(field $CELINE title)"
"$BIN" title "$CELINE" "Flights to Cumbuco" >/dev/null 2>&1
check "typing over it takes the title"      "Flights to Cumbuco" "$(field $CELINE title)"
check "and freezes it"                      "-"                 "$(field $CELINE title_source)"
"$BIN" label "$CELINE" "Céline Goossens" "Celine" >/dev/null 2>&1
check "a later rename leaves it alone"      "Flights to Cumbuco" "$(field $CELINE title)"

echo
echo "a call app decides the wording, and Me is never in it"
reset
"$BIN" label "$FRANCESCO" Francesco "Francesco Rossi" >/dev/null 2>&1
check "no app means a conversation"  "Conversation with Francesco Rossi" "$(field $FRANCESCO title)"

echo
echo "an unnamed speaker blocks the title"
reset
"$BIN" title "$WORKSHOP" --clear >/dev/null 2>&1
"$BIN" label "$WORKSHOP" Nick "Nick Adams" >/dev/null 2>&1
check "one letter left means no title"      "Untitled" "$(field $WORKSHOP title)"
"$BIN" label "$WORKSHOP" B "Sarah" >/dev/null 2>&1
check "naming the last one releases it"     "Conversation with Nick Adams and Sarah" \
                                            "$(field $WORKSHOP title)"

echo
echo "a title nobody typed is dropped when its speakers go"
reset
"$BIN" label "$FRANCESCO" Francesco "Francesco Rossi" >/dev/null 2>&1
"$BIN" label "$FRANCESCO" "Francesco Rossi" --discard >/dev/null 2>&1
check "discarding the last person un-names it" "Untitled" "$(field $FRANCESCO title)"
check "and clears the source with it"          "-"        "$(field $FRANCESCO title_source)"

echo
echo "the calendar outranks the speakers, and nothing outranks a person"
reset
python3 -c "
import json,pathlib
p=pathlib.Path('$LISTEN_LIBRARY/recordings/$EVENT/metadata.json')
m=json.loads(p.read_text()); m['title']='Conversation with Somebody'; m['title_source']='people'
p.write_text(json.dumps(m,indent=2,sort_keys=True))"
dry=$("$BIN" calendar backfill --refresh 2>&1)
check "the dry run says it will rename it" "1" \
      "$(echo "$dry" | grep -c "Conversation with Somebody → Catchup Chloe")"
check "and that the import keeps its name" "1" \
      "$(echo "$dry" | grep -c "$IMPORTED  2607-17-Google Chrome (keeps its name")"
"$BIN" calendar backfill --refresh --apply >/dev/null 2>&1
check "the apply agrees with the dry run"  "Catchup Chloe" "$(field $EVENT title)"
check "and stamps the calendar"            "calendar"       "$(field $EVENT title_source)"
check "the import is untouched"            "2607-17-Google Chrome" "$(field $IMPORTED title)"
check "and still has no source"            "-"              "$(field $IMPORTED title_source)"

echo
echo "backfill writes nothing until asked, and then exactly what it promised"
reset
"$BIN" title "$WORKSHOP" --clear >/dev/null 2>&1     # untitled, one letter left
dry=$("$BIN" title backfill 2>&1)
check "it offers the one it can name"    "1" \
      "$(echo "$dry" | grep -c "$FRANCESCO  New recording → Conversation with Francesco")"
check "it says what the others wait on"  "1" \
      "$(echo "$dry" | grep -c "$WORKSHOP  New recording (waiting on 1 unnamed speaker)")"
check "and wrote nothing"                "Untitled" "$(field $FRANCESCO title)"
check "nor to the one still waiting"     "Untitled" "$(field $WORKSHOP title)"
"$BIN" title backfill --apply >/dev/null 2>&1
check "--apply names it"                 "Conversation with Francesco" \
                                         "$(field $FRANCESCO title)"
check "and records the source"           "people"   "$(field $FRANCESCO title_source)"
check "and still leaves the waiting one" "Untitled" "$(field $WORKSHOP title)"
check "and does not touch a titled one"  "Catchup Chloe"        "$(field $EVENT title)"
check "nor an imported one"              "2607-17-Google Chrome" "$(field $IMPORTED title)"
check "it also names the other it could" "Call with Céline Goossens" "$(field $CELINE title)"
check "running it twice changes nothing" "0" \
      "$("$BIN" title backfill 2>&1 | grep -c ' → ')"

echo
echo "the placeholder is worded on screen and keyed on disk"
reset
check "the stored string is the key"       "Untitled" "$(field $CELINE title)"
check "and the CLI shows the wording"      "1" \
      "$("$BIN" list 2>/dev/null | grep -c "$CELINE.*New recording")"
check "and listen show shows it too"       "1" \
      "$("$BIN" show "$CELINE" 2>/dev/null | head -1 | grep -c '^New recording$')"
check "while the script read-back does not" "Untitled" \
      "$("$BIN" title "$CELINE" 2>/dev/null)"
"$BIN" label "$CELINE" "Céline Goossens" "Celine" >/dev/null 2>&1
check "a named one is unaffected by any of it" "Call with Celine" \
      "$("$BIN" title "$CELINE" 2>/dev/null)"

echo
echo "the phone named the memo, and that is not somebody typing"
reset
check "the fixture wears the phone's name"  "$(memo_title)" "$(field $MEMO title)"
check "and says nothing about who wrote it" "-"             "$(field $MEMO title_source)"
dry=$("$BIN" title backfill 2>&1)
check "the dry run spots the phone's name"  "1" \
      "$(echo "$dry" | grep -c "$MEMO  $(memo_title).*named by the phone")"
check "and offers the speakers' name"       "1" \
      "$(echo "$dry" | grep -c "$MEMO  $(memo_title).*→ Conversation with Rita")"
check "and wrote neither"                   "$(memo_title)" "$(field $MEMO title)"
check "nor the source"                      "-"             "$(field $MEMO title_source)"
"$BIN" title backfill --apply >/dev/null 2>&1
check "--apply names it after its speakers" "Conversation with Rita" "$(field $MEMO title)"
check "and the speakers get the credit"     "people" "$(field $MEMO title_source)"

echo
echo "a memo falls back to the phone's name, and a typed one is never claimed"
reset
"$BIN" title backfill --apply >/dev/null 2>&1
"$BIN" label "$MEMO" Rita --discard >/dev/null 2>&1
# The prefix rather than the whole string, deliberately. Recognising a memo is
# locale-independent (`candidates` always tries `en_US_POSIX`), but *writing* one
# uses the current locale, so a Mac set to Dutch restores "Memo, 26 augustus,
# 12:20" and is just as right. What is under test is that it goes back to the
# phone's name at all rather than to the placeholder.
check "discarding the last person restores it" "1" \
      "$(field $MEMO title | grep -c '^Memo, ')"
check "and hands it back to the device"        "device"        "$(field $MEMO title_source)"
check "and a second pass leaves it there"      "0" \
      "$("$BIN" title backfill --apply 2>&1 | grep -c "$MEMO.*→")"
reset
"$BIN" title "$MEMO" "Strom t-shirts" >/dev/null 2>&1
dry=$("$BIN" title backfill 2>&1)
check "a typed title is nobody's to reclaim"   "0" \
      "$(echo "$dry" | grep -c 'named by the phone')"
check "and it survives the apply"              "Strom t-shirts" \
      "$("$BIN" title backfill --apply >/dev/null 2>&1; field $MEMO title)"

echo
echo "an automatic name says so where somebody can read it"
reset
"$BIN" label "$CELINE" "Céline Goossens" "Celine" >/dev/null 2>&1
check "listen show marks it" "1" \
      "$("$BIN" show "$CELINE" 2>/dev/null | grep -c 'named after the speakers')"

rm -rf "$LISTEN_LIBRARY"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
