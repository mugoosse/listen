#!/bin/bash
# Parakeet against Apple's SpeechTranscriber, over this library's own audio.
#
# The argument for either engine is a number nobody has: Apple's assets are free
# and already on the machine, Parakeet costs 2.5 GB, and the thing that decided
# v2 against v3 was not the leaderboard but the proper nouns in these meetings.
# 39% of them went missing in the model that reads 25 languages. So this runs
# both engines over the same tracks and reports the same three things the v2/v3
# table reports, plus the two questions Apple's engine raises on its own:
# whether it reports word timings, and whether it is deterministic.
#
# Determinism is not a curiosity here. Any control that compares two runs over
# re-encoded audio assumes the engine is a function of its input, and Parakeet
# is: 3643 words, two runs, zero differences. Nothing had established that for
# Apple's engine, so it is asserted rather than assumed.
#
# Usage:
#   tools/measure_engines.sh <recording-id|audio-file> [more...]
#
#   ENGINES="v2 v3 apple"  which engines to run (default "v2 apple")
#   TERMS="Claude ChatGPT" the proper nouns to count (default: the five the
#                          v2/v3 table already counts, so the numbers compare)
#   LISTEN_LOCALE=en-US    the locale Apple's engine decodes in
#   OUT=<dir>              where the transcripts land (default: a temp dir)
#
# A recording id expands to both of its tracks, which is how "six meetings, ten
# tracks" was counted. A path is used as it stands.
#
# Run ./build.sh && ./make_app.sh first, or it measures the last build.
set -uo pipefail

APP="${LISTEN_APP:-./Listen.app/Contents/MacOS/Listen}"
LIBRARY="${LISTEN_LIBRARY:-$HOME/Library/Application Support/Listen}"
ENGINES="${ENGINES:-v2 apple}"
TERMS="${TERMS:-Claude ChatGPT DeepSeek WhatsApp Kinsight}"
OUT="${OUT:-${TMPDIR:-/tmp}/listen-measure-$$}"

[ -x "$APP" ] || { echo "no app at $APP. Run ./build.sh && ./make_app.sh"; exit 1; }
# The header is the help, down to the first line that is not a comment, so the
# two cannot come apart.
[ $# -gt 0 ] || { awk 'NR>1 && !/^#/{exit} NR>1{sub(/^# ?/,""); print}' "$0"; exit 1; }

mkdir -p "$OUT"
INDEX="$OUT/index.tsv"
: > "$INDEX"

# Every track to run. Two arrays rather than one delimited string: a label and
# a path both survive spaces that way, and nothing here has to agree about a
# separator that a later edit could lose.
LABELS=(); PATHS=()
for arg in "$@"; do
    if [ -f "$arg" ]; then
        LABELS+=("$(basename "$(dirname "$arg")")/$(basename "$arg")")
        PATHS+=("$arg")
        continue
    fi
    dir="$LIBRARY/recordings/$arg"
    [ -d "$dir" ] || { echo "not a recording or a file: $arg"; exit 1; }
    found=0
    # A recording contributes both of its tracks, which is how "six meetings,
    # ten tracks" was counted for v2 against v3.
    for track in system.wav mic.wav; do
        [ -s "$dir/$track" ] && { LABELS+=("$arg/$track"); PATHS+=("$dir/$track"); found=1; }
    done
    [ "$found" = 1 ] || { echo "$arg has no audio"; exit 1; }
done

echo "== $(echo "$ENGINES" | wc -w | tr -d ' ') engine(s) over ${#LABELS[@]} track(s), into $OUT =="

run() {   # engine, label, path, suffix
    local engine="$1" label="$2" path="$3" suffix="$4"
    local slug; slug=$(echo "$label" | tr '/' '_')
    local json="$OUT/$slug.$engine$suffix.json"
    local err="$OUT/$slug.$engine$suffix.log"
    printf '  %-34s %-6s ' "$label" "$engine"
    if ! "$APP" transcribe "$path" --model "$engine" --format json \
            > "$json" 2> "$err"; then
        printf 'FAILED: %s\n' "$(tail -1 "$err")"
        return 1
    fi
    # The app's own timing line, so the number is the one it prints on every
    # run rather than a second stopwatch that includes process launch.
    local secs; secs=$(sed -n 's/.*transcribe \([0-9.]*\)s for.*/\1/p' "$err" | tail -1)
    printf 'ok  %ss\n' "${secs:-?}"
    # Only the first pass is counted. The determinism run is the same audio
    # again, and adding it to the totals would double every number in the
    # report while looking exactly like a longer library.
    if [ -z "$suffix" ]; then
        printf '%s\t%s\t%s\t%s\n' "$engine" "$label" "$json" "${secs:-0}" >> "$INDEX"
    fi
}

for engine in $ENGINES; do
    for i in "${!LABELS[@]}"; do
        run "$engine" "${LABELS[$i]}" "${PATHS[$i]}" ""
    done
done

# Determinism: the first track again, per engine, compared byte for byte.
echo "== the same track twice, per engine =="
for engine in $ENGINES; do
    run "$engine" "${LABELS[0]}" "${PATHS[0]}" ".again" >/dev/null
    slug=$(echo "${LABELS[0]}" | tr '/' '_')
    if [ ! -s "$OUT/$slug.$engine.again.json" ]; then
        printf '  %-6s could not run\n' "$engine"
    elif cmp -s "$OUT/$slug.$engine.json" "$OUT/$slug.$engine.again.json"; then
        printf '  %-6s identical\n' "$engine"
    else
        printf '  %-6s DIFFERS: %s\n' "$engine" \
            "$(diff "$OUT/$slug.$engine.json" "$OUT/$slug.$engine.again.json" | grep -c '^[<>]') line(s)"
    fi
done

TERMS="$TERMS" python3 - "$INDEX" <<'PY'
import json, os, sys, collections

terms = os.environ["TERMS"].split()
rows = collections.defaultdict(lambda: {"words": 0, "audio": 0.0, "secs": 0.0,
                                        "segments": 0, "timed": 0, "conf": [],
                                        "terms": collections.Counter()})
for line in open(sys.argv[1]):
    engine, label, path, secs = line.rstrip("\n").split("\t")
    try:
        t = json.load(open(path))
    except Exception as e:
        print(f"unreadable {path}: {e}", file=sys.stderr)
        continue
    r = rows[engine]
    text = t.get("text", "")
    r["words"] += len(text.split())
    r["audio"] += t.get("duration", 0.0)
    r["secs"] += float(secs or 0)
    for s in t.get("segments", []):
        r["segments"] += 1
        if s.get("words"): r["timed"] += 1
        if s.get("confidence") is not None: r["conf"].append(s["confidence"])
    low = text.lower()
    for term in terms:
        r["terms"][term] += low.count(term.lower())

if not rows:
    sys.exit("nothing transcribed")

print("\n== proper nouns, occurrences over the same audio ==\n")
engines = list(rows)
print("| | " + " | ".join(engines) + " |")
print("|---|" + "---|" * len(engines))
for term in terms:
    print(f"| {term} | " + " | ".join(str(rows[e]['terms'][term]) for e in engines) + " |")
print("| **total** | " + " | ".join(
    f"**{sum(rows[e]['terms'].values())}**" for e in engines) + " |")

print("\n== the rest ==\n")
def line(name, fn):
    print(f"| {name} | " + " | ".join(fn(rows[e]) for e in engines) + " |")
print("| | " + " | ".join(engines) + " |")
print("|---|" + "---|" * len(engines))
line("words", lambda r: str(r["words"]))
line("words per second of audio", lambda r: f"{r['words'] / max(r['audio'], 1e-9):.2f}")
line("audio, seconds", lambda r: f"{r['audio']:.0f}")
line("transcribe, seconds", lambda r: f"{r['secs']:.1f}")
line("x realtime", lambda r: f"{r['audio'] / max(r['secs'], 1e-9):.0f}")
line("segments", lambda r: str(r["segments"]))
line("segments with word timings",
     lambda r: f"{r['timed']} of {r['segments']}")
line("mean confidence",
     lambda r: f"{sum(r['conf']) / len(r['conf']):.3f}" if r["conf"] else "not reported")
print()
PY

echo "transcripts kept in $OUT"
