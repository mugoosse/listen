#!/bin/bash
# Does the system audio tap survive this output route?
#
# The three meetings lost on 2026-09-01 were all on AirPods, and the difference
# between a route that records the far side and one that shreds it has never
# been measured, only inferred. This measures it, without needing anybody to
# hold a real call: it plays continuous speech through a chosen route, records
# it with the real capture path, and reports what arrived.
#
# What it can and cannot establish
# --------------------------------
# It exercises the same tap, the same aggregate device and the same IO cycle a
# meeting uses, on the route under test, with Listen's microphone open at the
# same time. Getting the *input* right matters as much as the output, for the
# reason under "The input matters more than it looks" below.
#
# It does **not** reproduce Chrome's WebRTC pipeline. A far side that arrives
# over the network has jitter this does not have. So a route that fails here is
# certainly broken, and a route that passes here is not proven good for calls,
# only not obviously bad.
#
# Usage
# -----
#   ./verify_tap_routes.sh                    every output device, 90s each
#   ./verify_tap_routes.sh --seconds 180      longer, for an intermittent fault
#   ./verify_tap_routes.sh --only bluetooth   one transport
#   ./verify_tap_routes.sh --with-mic         also move the default input to the
#                                             device under test, so a headset
#                                             enters its call profile
#   ./verify_tap_routes.sh --mic AT2020       put the default input on a named
#                                             device instead
#   ./verify_tap_routes.sh --load             pin four cores while it runs, on
#                                             the theory that HAL overloads are
#                                             missed deadlines
#
# The input matters more than it looks. The calls lost on 2026-09-01 had the
# AirPods on output only, in high quality A2DP, with an Audio-Technica
# AT2020USB-XP on input: two devices on two clocks, not one headset in its call
# profile. `--with-mic` reproduces the wrong thing for that case, and the first
# run of this script came back intact because of it.
#
# Note that Listen picks its own microphone from `Settings.microphoneUID`, not
# from the system default, so plugging the usual mic in is what actually puts
# the recording on it. `--mic` moves the *system* default, which is what a
# browser in a call would follow.
set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/Listen.app/Contents/MacOS/Listen"
ROUTE="$ROOT/.xcbuild/tools/audioroute"
WORK="${TMPDIR:-/tmp}/listen-verify-routes"
export LISTEN_LIBRARY="$WORK/library"

SECONDS_PER=90
ONLY=""
WITH_MIC=0
MIC_NAME=""
LOAD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds)   SECONDS_PER="$2"; shift 2 ;;
        --only)      ONLY="$2"; shift 2 ;;
        --with-mic)  WITH_MIC=1; shift ;;
        --mic)       MIC_NAME="$2"; shift 2 ;;
        --load)      LOAD=1; shift ;;
        *) echo "unknown argument: $1"; exit 2 ;;
    esac
done

[ -x "$BIN" ] || { echo "build first: ./build.sh && ./make_app.sh"; exit 2; }
mkdir -p "$(dirname "$ROUTE")" "$LISTEN_LIBRARY/recordings"
[ -x "$ROUTE" ] || swiftc -O "$ROOT/tools/audioroute.swift" -o "$ROUTE" || exit 2

# Put the route back however this exits, including on Ctrl-C. Leaving somebody's
# Mac on a device they did not choose is a worse bug than the one being chased.
ORIG_OUT=$("$ROUTE" get | awk '$1=="out"{print $2}')
ORIG_IN=$("$ROUTE" get | awk '$1=="in"{print $2}')
restore() {
    "$ROUTE" set-out "$ORIG_OUT" >/dev/null 2>&1
    "$ROUTE" set-in  "$ORIG_IN"  >/dev/null 2>&1
    [ -n "${LOAD_PIDS:-}" ] && kill $LOAD_PIDS 2>/dev/null
    [ -n "${PLAY_PID:-}" ] && kill $PLAY_PID 2>/dev/null
}
trap restore EXIT INT TERM

# One speech file, played on a loop. Speech rather than a tone because the torn
# detector only counts windows that carry signal, and a tone would also hide a
# fault behind its own regularity.
CLIP="$WORK/clip.aiff"
LINE="This is the far side of a call. It is speaking continuously so that the
      capture path has something to lose. If any of this is missing from the
      recording, the tap dropped it rather than the speaker pausing."
[ -f "$CLIP" ] || say -v Daniel -o "$CLIP" "$LINE" 2>/dev/null \
    || say -o "$CLIP" "$LINE" 2>/dev/null \
    || { echo "could not synthesise the test clip"; exit 2; }

# The device list goes through a file rather than a pipe. A `while read` on the
# right of a pipe runs in a subshell, so the loop's PLAY_PID and LOAD_PIDS would
# be invisible to the EXIT trap, and a Ctrl-C would leave a playback loop and
# four spinning cores behind on somebody's Mac.
DEVICES="$WORK/devices.tsv"
"$ROUTE" list > "$DEVICES"

printf '%-22s %-10s %8s %8s %9s %9s  %s\n' \
    DEVICE TRANSPORT ARRIVED TORN "TORN%" OVERLOADS VERDICT
printf '%s\n' "----------------------------------------------------------------------------------------"

while IFS=$'\t' read -r id transport ins outs dname; do
    outs="${outs#out:}"
    [ "$outs" -gt 0 ] 2>/dev/null || continue
    [ "$transport" = "virtual" ] && continue      # aggregates and loopbacks are not routes
    [ -n "$ONLY" ] && [ "$transport" != "$ONLY" ] && continue

    if ! "$ROUTE" set-out "$id" >/dev/null 2>&1; then
        printf '%-22s %-10s %8s %8s %9s %9s  %s\n' \
            "${dname:0:22}" "$transport" - - - - "cannot select"
        continue
    fi
    # A headset that is also the input is in its call profile, which is the
    # state the 2026-09-01 failures happened in.
    #
    # Matched by name, not by id. AirPods present input and output as two
    # separate device objects (92 in, 86 out), so setting the input to the
    # output's own id is a no-op that looks like it worked, and the test would
    # quietly run in the wrong profile.
    ins="${ins#in:}"
    if [ -n "$MIC_NAME" ]; then
        MIC_ID=$(awk -F'\t' -v n="$MIC_NAME" \
                 'index(tolower($5), tolower(n)) && $3 != "in:0" {print $1; exit}' "$DEVICES")
        if [ -n "$MIC_ID" ]; then
            "$ROUTE" set-in "$MIC_ID" >/dev/null 2>&1 \
                && echo "   (input on $(awk -F'\t' -v i="$MIC_ID" '$1==i{print $5}' "$DEVICES"))"
        else
            echo "   NO INPUT DEVICE MATCHES \"$MIC_NAME\" -- is it plugged in?"
        fi
    elif [ "$WITH_MIC" = 1 ]; then
        MIC_ID=$(awk -F'\t' -v n="$dname" '$5 == n && $3 != "in:0" {print $1; exit}' "$DEVICES")
        if [ -n "$MIC_ID" ]; then
            "$ROUTE" set-in "$MIC_ID" >/dev/null 2>&1 \
                && echo "   (input also on $dname, id $MIC_ID)"
        else
            echo "   (no input side on $dname; output only)"
        fi
    fi
    sleep 2                                        # let the route settle

    START=$(date '+%Y-%m-%d %H:%M:%S')
    LOAD_PIDS=""
    if [ "$LOAD" = 1 ]; then
        for _ in 1 2 3 4; do (while :; do :; done) & LOAD_PIDS="$LOAD_PIDS $!"; done
    fi
    ( while :; do afplay "$CLIP" 2>/dev/null; done ) & PLAY_PID=$!

    FOLDER=$(LISTEN_TAP_TEAR= "$BIN" record --seconds "$SECONDS_PER" 2>/dev/null | tail -1)

    kill $PLAY_PID 2>/dev/null; PLAY_PID=""
    [ -n "$LOAD_PIDS" ] && kill $LOAD_PIDS 2>/dev/null; LOAD_PIDS=""
    END=$(date '+%Y-%m-%d %H:%M:%S')

    # Core Audio's own account of the same window. A deadline miss here is the
    # thing the torn detector sees the consequences of.
    OVER=$(log show --start "$START" --end "$END" \
             --predicate 'subsystem == "com.apple.coreaudio"' --style compact 2>/dev/null \
           | grep -c "HALS_OverloadMessage.cpp:254")

    RID=$(basename "$FOLDER")
    OUT=$("$BIN" audio --check "$RID" 2>/dev/null)
    ARRIVED=$(printf '%s' "$OUT" | awk '/far end:/{print $3}')
    TORN=$(printf '%s' "$OUT" | awk '/torn:/{print $2}')
    PCT=$(printf '%s' "$OUT" | awk '/torn:/{print $6}')
    VERDICT=$(printf '%s' "$OUT" | grep -q "looks intact" && echo "intact" || echo "LOST AUDIO")

    printf '%-22s %-10s %8s %8s %9s %9s  %s\n' \
        "${dname:0:22}" "$transport" "${ARRIVED:-?}" "${TORN:-0s}" "${PCT:-0%}" "$OVER" "$VERDICT"
done < "$DEVICES"

echo
echo "A route that says LOST AUDIO is broken for meetings. A route that says"
echo "intact is not proven good: this has no network jitter in it. Repeat a"
echo "suspect route with --seconds 300 --load before trusting either answer."
