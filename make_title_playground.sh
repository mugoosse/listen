#!/bin/bash
# A scratch library for trying the title work by hand, built from copies of the
# real one. The real library is only ever read.
#
#   ./make_title_playground.sh
#   LISTEN_LIBRARY=/tmp/listen-titles Listen.app/Contents/MacOS/Listen
#
# Sidecars only, no WAVs, which is the shape `CLAUDE.md` describes: everything
# about speakers, people and titles works, and only playback and Transcribe
# Again do not. Pass --with-audio to copy the audio for the one recording the
# walkthrough uses, at about 105 MB, if you want to hear it too.
#
# Two recordings are staged so the whole arc is visible rather than only its
# end. The rest of the library is copied as it is, so the sidebar looks like
# yours and a change is easy to spot against it.
set -eu

SRC="$HOME/Library/Application Support/Listen"
DEST="${LISTEN_LIBRARY:-/tmp/listen-titles}"
AUDIO=no
[ "${1:-}" = "--with-audio" ] && AUDIO=yes

# Untitled, on WhatsApp, one other speaker the voice bank already named.
# Staged back to an unnamed letter, so naming them is what produces the title.
ARC=2026-08-08-150113-9BA4
# Titled by hand, and still has an unnamed speaker in it. Left exactly as it
# is: naming that speaker must change nothing about the title.
FROZEN=2026-08-07-111927-1047

[ -d "$SRC/recordings" ] || { echo "no library at $SRC" >&2; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/recordings"
for folder in "$SRC/recordings"/*/; do
  id=$(basename "$folder")
  mkdir -p "$DEST/recordings/$id"
  for f in metadata.json transcript.json turns.json embeddings.json \
           voiceprints.json waveform.json; do
    [ -f "$folder/$f" ] && cp "$folder/$f" "$DEST/recordings/$id/"
  done
done
for f in contacts.json dictionary.json; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DEST/"
done
[ -d "$SRC/notes" ] && cp -R "$SRC/notes" "$DEST/"

if [ "$AUDIO" = yes ]; then
  for f in mic.wav system.wav mix.m4a; do
    [ -f "$SRC/recordings/$ARC/$f" ] && cp "$SRC/recordings/$ARC/$f" \
      "$DEST/recordings/$ARC/"
  done
fi

# Put the named speaker back to a letter, in both files that carry labels, and
# drop the voiceprint so the bank cannot simply name them again on sight.
python3 - "$DEST/recordings/$ARC" <<'PY'
import json, pathlib, sys

folder = pathlib.Path(sys.argv[1])

# Whoever is not the microphone. Read rather than hardcoded, so this keeps
# working when the fixture is a different recording.
turns = json.loads((folder / "turns.json").read_text())
them = next(t["speaker"] for t in turns if t["speaker"] != "Me")

for name in ("transcript.json", "turns.json"):
    path = folder / name
    doc = json.loads(path.read_text())
    rows = doc["segments"] if isinstance(doc, dict) else doc
    for row in rows:
        if row.get("speaker") == them:
            row["speaker"] = "B"
    path.write_text(json.dumps(doc, indent=2, sort_keys=True))

for name in ("embeddings.json", "voiceprints.json"):
    path = folder / name
    if not path.exists():
        continue
    bank = json.loads(path.read_text())
    if isinstance(bank, dict) and them in bank:
        bank["B"] = bank.pop(them)
        path.write_text(json.dumps(bank, indent=2, sort_keys=True))

meta = json.loads((folder / "metadata.json").read_text())
meta["state"] = "needs_labelling"
meta["title"] = "Untitled"
meta.pop("title_source", None)
meta.pop("auto_named", None)
(folder / "metadata.json").write_text(json.dumps(meta, indent=2, sort_keys=True))
print(f"  {folder.name}: {them} is now Speaker B, and it is Untitled")
PY

cat <<EOF

playground at $DEST  ($(du -sh "$DEST" | cut -f1))

  LISTEN_LIBRARY=$DEST Listen.app/Contents/MacOS/Listen

Launch the binary, never \`open\`: Launch Services prefers /Applications and
drops the variable, which opens the real library instead. Then:

  $ARC   is Untitled with a Speaker B. Name B and watch the
  title appear in the sidebar. Rename them again and it follows. Type your
  own title and it stops following.

  $FROZEN   is named by hand and also has a Speaker B.
  Name them: the title must not move.
EOF
