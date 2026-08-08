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
RITA=2026-08-08-085243-B4C3      # matches a real calendar event at 09:00

pass=0; fail=0
reset() {
  rm -rf "$LISTEN_LIBRARY"; mkdir -p "$LISTEN_LIBRARY/recordings"
  for id in "$CELINE" "$FRANCESCO" "$WORKSHOP" "$IMPORTED" "$RITA"; do
    # Loudly, because the alternative is a run that copies nothing, asserts
    # against an empty library, and passes by finding no title to be wrong.
    # These are five real recordings and any of them can be deleted.
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
  cp "$HOME/Library/Application Support/Listen/contacts.json" "$LISTEN_LIBRARY/" 2>/dev/null
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
p=pathlib.Path('$LISTEN_LIBRARY/recordings/$RITA/metadata.json')
m=json.loads(p.read_text()); m['title']='Conversation with Somebody'; m['title_source']='people'
p.write_text(json.dumps(m,indent=2,sort_keys=True))"
dry=$("$BIN" calendar backfill --refresh 2>&1)
check "the dry run says it will rename it" "1" \
      "$(echo "$dry" | grep -c "Conversation with Somebody → Breakfast Rita")"
check "and that the import keeps its name" "1" \
      "$(echo "$dry" | grep -c "$IMPORTED  2607-17-Google Chrome (keeps its name")"
"$BIN" calendar backfill --refresh --apply >/dev/null 2>&1
check "the apply agrees with the dry run"  "Breakfast Rita" "$(field $RITA title)"
check "and stamps the calendar"            "calendar"       "$(field $RITA title_source)"
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
check "and does not touch a titled one"  "Breakfast Rita"        "$(field $RITA title)"
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
echo "an automatic name says so where somebody can read it"
reset
"$BIN" label "$CELINE" "Céline Goossens" "Celine" >/dev/null 2>&1
check "listen show marks it" "1" \
      "$("$BIN" show "$CELINE" 2>/dev/null | grep -c 'named after the speakers')"

rm -rf "$LISTEN_LIBRARY"
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
