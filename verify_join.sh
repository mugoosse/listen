#!/bin/bash
# Every claim in `.agents/notes/capture.md` under "A call cut in two is one
# meeting", as assertions, over the app built in the working directory.
#
# Builds nothing. Run `./build.sh && ./make_app.sh` first or it tests the last
# build. It never opens the real library: everything happens under a scratch
# LISTEN_LIBRARY made here and removed at the end.
#
# **The audio is synthesised rather than copied from a real recording.** Two
# WAVs of a known length are cheaper than 90 MB of somebody's meeting, and more
# importantly they make the arithmetic checkable: a joined file has to be
# exactly first + gap + second samples long, and that is only an assertion when
# you chose all three numbers.
set -u

export LISTEN_NO_KEYCHAIN=1
cd "$(dirname "$0")"

BIN="$(pwd)/Listen.app/Contents/MacOS/Listen"
[[ -x "$BIN" ]] || { echo "no built app. ./build.sh && ./make_app.sh first."; exit 1; }

SCRATCH="${TMPDIR:-/tmp}/listen-verify-join"
export LISTEN_LIBRARY="$SCRATCH"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
is()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got '$2', wanted '$3')"; }
has() { grep -q -- "$2" <<<"$1" && ok "$3" || bad "$3 (not in: $(head -c 200 <<<"$1"))"; }

# One recording folder: id, start time, seconds of audio, app, title, and the
# transcript's one line so the offsets have something to be checked against.
make_recording() { # id, recorded_at, seconds, bundle, title, first-word
    local id="$1" at="$2" secs="$3" bundle="$4" title="$5" word="$6"
    local d="$SCRATCH/recordings/$id"
    mkdir -p "$d"
    python3 - "$d" "$secs" <<'PY'
import struct, sys, math
folder, secs = sys.argv[1], float(sys.argv[2])
rate, frames = 16000, int(float(sys.argv[2]) * 16000)
for name in ("mic.wav", "system.wav"):
    with open(folder + "/" + name, "wb") as f:
        data = frames * 4
        f.write(b"RIFF" + struct.pack("<I", 36 + data) + b"WAVEfmt ")
        f.write(struct.pack("<IHHIIHH", 16, 3, 1, rate, rate * 4, 4, 32))
        f.write(b"data" + struct.pack("<I", data))
        # A quiet tone rather than digital silence, so a waveform built from
        # this has something in it and a track that was skipped is visible.
        block = b"".join(struct.pack("<f", 0.05 * math.sin(i / 40.0)) for i in range(rate))
        for _ in range(frames // rate): f.write(block)
        f.write(block[: (frames % rate) * 4])
PY
    cat > "$d/metadata.json" <<JSON
{ "id": "$id", "recorded_at": "$at", "duration": $secs, "title": "$title",
  "state": "done", "source": "detected", "app_bundle_id": "$bundle",
  "app_name": "Google Chrome", "room": false }
JSON
    cat > "$d/transcript.json" <<JSON
{ "segments": [ { "start": 1.0, "end": 3.0, "speaker": "Me", "text": "$word one" },
                { "start": 4.0, "end": 6.0, "speaker": "Ada", "text": "$word two" } ],
  "duration": $secs, "model": "test-model", "wordLevel": false,
  "cleanup": { "dup": 1 }, "dictionary": { "term:x": 2 } }
JSON
    cat > "$d/turns.json" <<JSON
[ { "start": 1.0, "end": 3.0, "speaker": "Me", "text": "$word one" },
  { "start": 4.0, "end": 6.0, "speaker": "Ada", "text": "$word two" } ]
JSON
    python3 - "$d/embeddings.json" "$7" <<'PY'
import json, sys
speech = float(sys.argv[2])
bank = {name: {"embedding": [v] * 256, "speech": speech}
        for name, v in (("Me", 0.10), ("Ada", 0.20))}
json.dump(bank, open(sys.argv[1], "w"))
PY
}

reset() {
    rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/recordings" "$SCRATCH/notes"
    # Ids of the real shape, because `Library.delete` refuses anything else and a
    # fixture id no library could hold would skip the tombstone entirely.
    # 100 s from 12:00:00, then 60 s from 12:03:00. The second starts 180 s in,
    # so 80 s of the call was never recorded and the join is 240 s long.
    make_recording 2026-01-01-120000-AAAA  "2026-01-01T12:00:00Z" 100 com.google.Chrome "Standup"   alpha 30
    make_recording 2026-01-01-120300-BBBB "2026-01-01T12:03:00Z" 60  com.google.Chrome "Call with Ada" beta 10
}

seconds() { # a WAV's length, from its header
    python3 -c "
import struct,sys
d=open(sys.argv[1],'rb').read(64)
i=d.index(b'data'); print(round(struct.unpack('<I',d[i+4:i+8])[0]/4/16000,3))" "$1"
}

echo "== detection"
reset
out="$("$BIN" join 2026-01-01-120300-BBBB 2>&1)"
has "$out" "looks like a continuation of 2026-01-01-120000-AAAA" "2026-01-01-120300-BBBB is offered against 2026-01-01-120000-AAAA"
has "$out" "1m 20s apart" "the gap is stated, and it is the 80 s that was lost"
has "$out" "both Google Chrome" "the evidence names the app rather than asserting a match"
has "$out" "nothing changed" "a dry run says so"
is "the dry run left 2026-01-01-120000-AAAA's audio alone" "$(seconds "$SCRATCH/recordings/2026-01-01-120000-AAAA/mic.wav")" "100.0"
[[ -d "$SCRATCH/recordings/2026-01-01-120300-BBBB" ]] && ok "the dry run deleted nothing" || bad "2026-01-01-120300-BBBB is gone after a dry run"

echo
echo "== refusals"
reset
out="$("$BIN" join 2026-01-01-120000-AAAA --into 2026-01-01-120000-AAAA 2>&1)";  has "$out" "cannot be joined to itself" "a recording will not join itself"
out="$("$BIN" join 2026-01-01-120000-AAAA --into 2026-01-01-120300-BBBB 2>&1)"; has "$out" "starts before" "the later one has to be named first"
out="$("$BIN" join 2026-01-01-120000-AAAA 2>&1)";               has "$out" "nothing in the library" "2026-01-01-120000-AAAA has nothing before it"
# 150 s of audio from 12:00 runs to 12:02:30, past where 2026-01-01-120300-BBBB begins.
rm -rf "$SCRATCH/recordings/2026-01-01-120000-AAAA"
make_recording 2026-01-01-120000-AAAA "2026-01-01T12:00:00Z" 250 com.google.Chrome "Standup" alpha 30
out="$("$BIN" join 2026-01-01-120300-BBBB --into 2026-01-01-120000-AAAA 2>&1)"; has "$out" "these overlap" "overlapping recordings are refused"
# A different app with no shared calendar event is not offered, though naming
# it outright still works: the window is a suggestion, not a permission.
reset
python3 -c "
import json; p='$SCRATCH/recordings/2026-01-01-120300-BBBB/metadata.json'
m=json.load(open(p)); m['app_bundle_id']='com.apple.Safari'; json.dump(m,open(p,'w'))"
out="$("$BIN" join 2026-01-01-120300-BBBB 2>&1)"; has "$out" "nothing in the library" "a different app is not offered"
out="$("$BIN" join 2026-01-01-120300-BBBB --into 2026-01-01-120000-AAAA --apply 2>&1)"; has "$out" "joined." "and --into joins it anyway"

echo
echo "== the join"
reset
"$BIN" notes write "About both" --recording 2026-01-01-120000-AAAA --recording 2026-01-01-120300-BBBB --body "x" >/dev/null 2>&1
out="$("$BIN" join 2026-01-01-120300-BBBB --apply 2>&1)"
has "$out" "joined." "it reports having done it"
is "mic.wav is first + gap + second"    "$(seconds "$SCRATCH/recordings/2026-01-01-120000-AAAA/mic.wav")"    "240.0"
is "system.wav is the same length"      "$(seconds "$SCRATCH/recordings/2026-01-01-120000-AAAA/system.wav")" "240.0"
[[ -e "$SCRATCH/recordings/2026-01-01-120000-AAAA/mic.wav.joining" ]] && bad "a staging track was left behind" \
    || ok "no staging track is left behind"
[[ -d "$SCRATCH/recordings/2026-01-01-120300-BBBB" ]] && bad "2026-01-01-120300-BBBB survived the join" || ok "2026-01-01-120300-BBBB is deleted"
[[ -d "$SCRATCH/.trash" ]] && ok "and is in the trash rather than gone" || bad "2026-01-01-120300-BBBB was not kept in the trash"
has "$(cat "$SCRATCH/.deletions.json")" "2026-01-01-120300-BBBB" "a tombstone carries the deletion"

python3 - <<'PY'
import json, os, sys
d = os.environ["LISTEN_LIBRARY"] + "/recordings/2026-01-01-120000-AAAA"
t = json.load(open(d + "/transcript.json")); turns = json.load(open(d + "/turns.json"))
m = json.load(open(d + "/metadata.json")); e = json.load(open(d + "/embeddings.json"))
checks = [
    ("the transcript holds both halves", len(t["segments"]), 4),
    ("the second half is offset by the wall clock", t["segments"][2]["start"], 181.0),
    ("and so are its turns", turns[2]["start"], 181.0),
    ("the transcript's duration is the joined one", round(t["duration"], 1), 240.0),
    ("so is the metadata's", round(m["duration"], 1), 240.0),
    ("cleanup counts are summed, never replaced", t["cleanup"]["dup"], 2),
    ("dictionary counts too", t["dictionary"]["term:x"], 4),
    ("the earlier title wins", m["title"], "Standup"),
    ("speech seconds are summed per speaker", e["Me"]["speech"], 40.0),
    ("the voiceprint keeps its width", len(e["Me"]["embedding"]), 256),
]
for name, got, want in checks:
    print(("  ok: " if got == want else "  FAIL: ") + name + ("" if got == want else " (got %r, wanted %r)" % (got, want)))
if any(got != want for _, got, want in checks): sys.exit(1)
PY
[[ $? -eq 0 ]] || fail=$((fail+1))

[[ -e "$SCRATCH/recordings/2026-01-01-120000-AAAA/waveform.json" ]] && bad "a stale waveform survived" \
    || ok "the waveform is dropped so it rebuilds"
note="$(cat "$SCRATCH"/notes/about-both.md)"
has "$note" '"2026-01-01-120000-AAAA"' "the note about both now names the survivor"
grep -q "2026-01-01-120300-BBBB" <<<"$note" && bad "the note still names the deleted recording" \
    || ok "and no longer names the deleted one"
grep -c "2026-01-01-120000-AAAA" <<<"$(grep '^recordings:' <<<"$note")" >/dev/null
is "named once rather than twice" "$(python3 -c "
import re,sys
line=[l for l in open('$SCRATCH/notes/about-both.md') if l.startswith('recordings:')][0]
print(line.count('2026-01-01-120000-AAAA'))")" "1"

echo
rm -rf "$SCRATCH"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
