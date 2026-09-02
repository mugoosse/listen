#!/bin/bash
# Does the microphone track survive the states that have lost it?
#
# Every claim in `.agents/notes/capture.md` under "A call on the built-in
# microphone turns it into three channels", as assertions, over the app built
# in the working directory. It plays a phrase aloud through the built-in
# speakers and records it with the real capture path, so it needs:
#
#   - `./build.sh && ./make_app.sh` first, or it tests the last build;
#   - microphone permission for the terminal running it (the first run asks);
#   - the lid open and nothing else on a call, because it puts the built-in
#     microphone into its call state itself and checks that it came back;
#   - a room quiet enough that a phrase from the speakers is the loudest thing.
#
# What it establishes: the three-channel state records, at a level the meter
# shows; a microphone that will not open is retried, padded, reported and
# recovered from; a track that never opened is a full-length silent file marked
# `mic_silent`; and, with --ui, that both warnings reach the screen and that a
# recording with an empty mic file still plays. What it does not establish:
# anything about a real WhatsApp call's audio engine beyond the device state it
# leaves the microphone in, which `tools/vpio.swift` reproduces exactly.
#
#   ./verify_capture.sh          the four CLI cases, about 90 seconds
#   ./verify_capture.sh --ui     also the on-screen cases, read back through
#                                `tools/axprobe` (needs Accessibility permission
#                                for the terminal, and the display awake)
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/Listen.app/Contents/MacOS/Listen"
TOOLS="$ROOT/.xcbuild/tools"
WORK="${TMPDIR:-/tmp}/listen-verify-capture"
export LISTEN_LIBRARY="$WORK/library"
UI=0
[ "${1:-}" = "--ui" ] && UI=1

pass=0; fail=0; skipped=0
check() {  # <what> <expected> <actual>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL  %s\n        want %s\n        got  %s\n' "$1" "$2" "$3"; fi
}
atleast() {  # <what> <minimum> <actual>   numeric, floats allowed
    if awk -v a="$3" -v m="$2" 'BEGIN{exit !(a+0 >= m+0)}'; then
        pass=$((pass+1)); printf '  ok    %s (%s)\n' "$1" "$3"
    else fail=$((fail+1)); printf '  FAIL  %s\n        want at least %s\n        got  %s\n' "$1" "$2" "$3"; fi
}
contains() {  # <what> <needle> <file>
    if grep -q -- "$2" "$3"; then pass=$((pass+1)); printf '  ok    %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL  %s\n        wanted "%s" in %s\n' "$1" "$2" "$3"; fi
}

[ -x "$BIN" ] || { echo "no Listen.app in $ROOT; run ./build.sh && ./make_app.sh" >&2; exit 1; }
mkdir -p "$TOOLS" "$LISTEN_LIBRARY"
for tool in vpio wavstats axprobe; do
    if [ ! -x "$TOOLS/$tool" ] || [ "$ROOT/tools/$tool.swift" -nt "$TOOLS/$tool" ]; then
        swiftc -O "$ROOT/tools/$tool.swift" -o "$TOOLS/$tool" 2>/dev/null \
            || { echo "could not build tools/$tool.swift" >&2; exit 1; }
    fi
done

# The scratch library must not be the consented one, or a pass would push
# invented recordings into the real container. The app is what knows that.
"$BIN" sync status 2>/dev/null | grep -q "off for this library" \
    || { echo "sync is not off for $LISTEN_LIBRARY; refusing to record into it" >&2; exit 1; }

# The phrase and where it plays. The built-in speakers rather than the default
# output, because that is what the built-in microphone can hear.
SPEAKER=$(say -a '?' 2>/dev/null | awk '/Speakers/{sub(/^ *[0-9]+ +/, ""); print; exit}')
[ -n "$SPEAKER" ] || { echo "no built-in speakers to play the phrase through" >&2; exit 1; }
PHRASE="Testing the microphone, one two three four five six seven eight nine ten, eleven twelve thirteen."
SPEAK_PID=""
speak() { ( sleep "${1:-1}"; say -a "$SPEAKER" -v Samantha "$PHRASE" ) & SPEAK_PID=$!; }

# `listen record` prints the folder on stdout and everything else on stderr.
record() {  # <name> <seconds> [VAR=value ...]  -> folder in $FOLDER, trace in $TRACE
    local name=$1 secs=$2; shift 2
    TRACE="$WORK/$name.trace"
    FOLDER=$(env LISTEN_DEBUG=1 "$@" "$BIN" record --seconds "$secs" 2>"$TRACE")
    [ -n "$SPEAK_PID" ] && wait "$SPEAK_PID" 2>/dev/null
    [ -d "$FOLDER" ] || { echo "  no recording folder from $name; see $TRACE" >&2; FOLDER=""; }
}
stat_of() {  # <file> <key>
    "$TOOLS/wavstats" "$1" | sed -n "s/.* $2=\([^ ]*\).*/\1/p"
}
aligned() {  # both tracks within 0.3 s of each other
    local a b
    a=$(stat_of "$FOLDER/mic.wav" duration); b=$(stat_of "$FOLDER/system.wav" duration)
    awk -v a="$a" -v b="$b" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d<=0.3)}' && echo "aligned" || echo "mic $a s, system $b s"
}
VPIO_PID=""
cleanup() { [ -n "$VPIO_PID" ] && kill "$VPIO_PID" 2>/dev/null; [ -n "${APP:-}" ] && kill "$APP" 2>/dev/null; }
trap cleanup EXIT

echo "1. the microphone in its ordinary state"
"$TOOLS/vpio" 0 2>/dev/null | grep -q "before: .* 1 ch" \
    || { echo "  the built-in microphone is not in its 1-channel state; is something on a call?" >&2; exit 1; }
speak; record baseline 9
if [ -n "$FOLDER" ]; then
    contains "one channel, processed"                   "mic format 48000 Hz, 1 ch" "$TRACE"
    atleast  "the phrase reached the microphone (dBFS)" -60 "$(stat_of "$FOLDER/mic.wav" peak)"
    check    "the two tracks end together"              "aligned" "$(aligned)"
fi

echo "2. the microphone as a call leaves it: three raw channels"
# The state under test belongs to the built-in microphone, and a shut lid
# switches that off: Listen would record case 2 from whatever else is plugged
# in, at one channel, and prove nothing. So this case is skipped rather than
# failed on a closed laptop, and says so.
if ioreg -r -k AppleClamshellState -d 1 2>/dev/null | grep -q '"AppleClamshellState" = Yes'; then
    skipped=$((skipped+1)); echo "  SKIP  the lid is shut, so the built-in microphone is off; open it for this case"
else
    "$TOOLS/vpio" 40 --no-duck > "$WORK/vpio.out" 2>&1 &
    VPIO_PID=$!; sleep 3
    contains "a voice-processing session turns it into three channels" "running: .* 3 ch" "$WORK/vpio.out"
    speak; record threech 9
    if [ -n "$FOLDER" ]; then
        contains "the recorder takes all three, with the gain"  "mic format 48000 Hz, 3 ch, raw array, +24 dB" "$TRACE"
        atleast  "the phrase reached the microphone (dBFS)"     -60 "$(stat_of "$FOLDER/mic.wav" peak)"
        atleast  "and the meter would have moved (peak 0..1)"   0.05 "$(sed -n 's/.*levels: you \([0-9.]*\).*/\1/p' "$TRACE")"
        check    "the two tracks end together"                  "aligned" "$(aligned)"
    fi
    kill "$VPIO_PID" 2>/dev/null; wait "$VPIO_PID" 2>/dev/null; VPIO_PID=""; sleep 1
    "$TOOLS/vpio" 0 2>/dev/null | grep -q "before: .* 1 ch" && echo "  ok    and it is back to one channel" \
        || { fail=$((fail+1)); echo "  FAIL  the microphone did not return to one channel"; }
fi

echo "3. every microphone refuses for 8 seconds of a 20 second recording"
# The refusal is simulated for every device, so the attempts go round the
# candidates in turn and the one that finally opens depends on what is
# plugged in; a silent one (a webcam with its microphone off) is then left
# for the next by the silence switch. The chain is printed for the reader.
speak 12; record retry 20 LISTEN_MIC_FAIL_OPEN=8
if [ -n "$FOLDER" ]; then
    contains "the failure is reported at the start"        "could not be opened" "$TRACE"
    contains "the track is tried again"                    "trying the microphone again; now recording from" "$TRACE"
    grep -o "now recording from [^(]*" "$TRACE" | sed 's/^/        /'
    atleast  "the gap is padded, not closed up (s)"         8 "$(sed -n 's/.*mic padded \([0-9.]*\)s.*/\1/p' "$TRACE" | sort -n | tail -1)"
    atleast  "the phrase after the recovery was recorded (dBFS)" -60 "$(stat_of "$FOLDER/mic.wav" peak)"
    check    "the two tracks end together"                  "aligned" "$(aligned)"
    check    "not marked silent, because it recovered"      "" "$(grep -o '"mic_silent" : true' "$FOLDER/metadata.json")"
fi

echo "4. a microphone that never opens"
speak; record never 6 LISTEN_MIC_FAIL_OPEN=60
if [ -n "$FOLDER" ]; then
    check    "marked mic_silent"                            '"mic_silent" : true' "$(grep -o '"mic_silent" : true' "$FOLDER/metadata.json")"
    atleast  "the mic track is still the length of the meeting (s)" 5.5 "$(stat_of "$FOLDER/mic.wav" duration)"
    check    "and holds nothing (nonzero %)"                "0.0" "$(stat_of "$FOLDER/mic.wav" nonzero)"
    atleast  "while the far end was recorded (dBFS)"        -30 "$(stat_of "$FOLDER/system.wav" peak)"
fi

if [ $UI -eq 1 ]; then
    # Launch and drive in one shell, for the reason CLAUDE.md gives: `open`
    # resolves to /Applications and drops the environment with it.
    PROBE="$TOOLS/axprobe"
    ui_skip() { skipped=$((skipped+1)); echo "  SKIP  $1"; kill "$APP" 2>/dev/null; APP=""; }

    echo "5. on screen: the warning for a microphone that will not open"
    export LISTEN_LIBRARY="$WORK/ui-library"; mkdir -p "$LISTEN_LIBRARY"
    LISTEN_DEBUG=1 LISTEN_MIC_FAIL_OPEN=600 "$BIN" 2>"$WORK/ui.trace" >/dev/null &
    APP=$!; sleep 7
    dump=$("$PROBE" texts $APP 2>&1); rc=$?
    if [ $rc -eq 3 ]; then ui_skip "this terminal has no Accessibility permission"
    elif ! printf '%s' "$dump" | grep -qi record; then ui_skip "empty AX tree (is the display asleep?)"
    else
        "$PROBE" press $APP record >/dev/null 2>&1; sleep 8
        texts=$("$PROBE" texts $APP 2>&1)
        check "the panel says so"            "yes" "$(printf '%s' "$texts" | grep -q 'Your microphone could not be opened' && echo yes || echo no)"
        check "the recording screen says so" "yes" "$(printf '%s' "$texts" | grep -q 'could not be opened.*Your voice is not being recorded' && echo yes || echo no)"
        "$PROBE" press $APP Stop >/dev/null 2>&1; sleep 2
        kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null; APP=""
    fi

    echo "6. on screen: a recording whose mic file is empty still plays"
    # The baseline recording with its mic track cut back to a bare header,
    # which is what the lost call left behind.
    SRC="$WORK/library/staging/$(ls "$WORK/library/staging" | head -1)"
    [ -d "$SRC" ] || SRC="$WORK/library/recordings/$(ls "$WORK/library/recordings" | head -1)"
    export LISTEN_LIBRARY="$WORK/play-library"; rm -rf "$LISTEN_LIBRARY"
    DST="$LISTEN_LIBRARY/recordings/$(basename "$SRC")"; mkdir -p "$DST"
    cp "$SRC"/* "$DST"/ 2>/dev/null
    # Transcribed first, through the real pipeline, because a recording with
    # no transcript is `pending` and the app would queue it on launch rather
    # than list it as something to play. Then the mic track is cut back to the
    # bare header the lost call left behind.
    sed -i '' 's/"state" : "[a-z_]*"/"state" : "pending"/' "$DST/metadata.json"
    "$BIN" transcribe "$DST" >/dev/null 2>"$WORK/play-transcribe.trace" \
        || echo "  (transcribing the fixture failed; see $WORK/play-transcribe.trace)"
    head -c 44 "$SRC/mic.wav" > "$DST/mic.wav"
    rm -f "$DST/mix.m4a"
    LISTEN_DEBUG=1 "$BIN" 2>"$WORK/play.trace" >/dev/null &
    APP=$!; sleep 7
    dump=$("$PROBE" texts $APP 2>&1); rc=$?
    if [ $rc -eq 3 ]; then ui_skip "this terminal has no Accessibility permission"
    elif ! printf '%s' "$dump" | grep -qi record; then ui_skip "empty AX tree (is the display asleep?)"
    else
        title=$(sed -n 's/.*"title" : "\([^"]*\)".*/\1/p' "$DST/metadata.json")
        "$PROBE" press $APP "${title:-Untitled}" >/dev/null 2>&1; sleep 2
        "$PROBE" press $APP Play >/dev/null 2>&1; sleep 4
        label=$(printf '%s' "$("$PROBE" texts $APP 2>&1)" | grep -o '[0-9][0-9]:[0-9][0-9] / [0-9][0-9]:[0-9][0-9]' | head -1)
        check "the player knows the length"   "no" "$(printf '%s' "$label" | grep -q '/ 00:00' && echo yes || echo no)"
        check "and is playing"                "no" "$(printf '%s' "$label" | grep -q '^00:00 /' && echo yes || echo no)"
        [ -n "$label" ] && echo "        ($label)"
        kill "$APP" 2>/dev/null; wait "$APP" 2>/dev/null; APP=""
    fi
fi

echo
printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
[ "$fail" -eq 0 ]
