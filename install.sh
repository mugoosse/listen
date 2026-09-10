#!/bin/sh
# Build, bundle, and install to /Applications, then restart the running copy.
#
# Installing to a fixed path lets macOS keep the app's login-item registration
# attached to the same bundle across rebuilds.
#
# Permissions survive too, because make_app.sh always signs with the same
# identifier (com.mgo.listen) and TCC keys the microphone and audio-capture
# grants to that identity rather than to the file's contents.
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="/Applications/Listen.app"
LIBRARY="${LISTEN_LIBRARY:-$HOME/Library/Application Support/Listen}"

# Never replace the app while it is recording.
#
# This script quits the running copy, and on 10 September 2026 it did that
# eleven minutes into a call: the meeting was cut into two recordings and the
# 97 seconds between them were lost for good. Nobody chose that. The person who
# started the build was not the person on the call, which is the ordinary case
# when an agent is working in this tree, so the build has to be the thing that
# refuses.
#
# **The test is the audio on disk, not a state field.** A recording in progress
# rewrites its WAV header as it runs (`.agents/notes/capture.md`), so a track
# touched seconds ago is capture happening now. `metadata.state` cannot answer
# this: `unconfirmed` is written when the recording starts and outlives it, so
# it says "maybe, at some point" where this needs "right now". Asking the app
# would be better still and there is nothing to ask it with.
#
# 15 seconds because the header rewrite is the slowest thing that touches the
# file, and a window shorter than its period would read a live recording as
# finished. It errs towards refusing, which is the right way round: a refused
# install costs one command, and the alternative costs somebody's meeting.
recording_now() {
    [ -d "$LIBRARY/recordings" ] || return 1
    now=$(date +%s)
    newest=$(stat -f %m "$LIBRARY"/recordings/*/mic.wav "$LIBRARY"/recordings/*/system.wav \
        2>/dev/null | sort -rn | head -1)
    [ -n "$newest" ] || return 1
    [ "$((now - newest))" -lt 15 ]
}

refuse() {
    echo "listen: a recording is in progress, so the app was left alone." >&2
    echo "        Stop it first, or re-run with LISTEN_INSTALL_FORCE=1 to install anyway." >&2
    echo "        Library: $LIBRARY" >&2
    exit 1
}

if [ -z "$LISTEN_INSTALL_FORCE" ] && recording_now; then refuse; fi

"$ROOT/build.sh" >/dev/null
"$ROOT/make_app.sh" >/dev/null
echo "built"

# Asked again after the build, and this is the check that actually protects a
# call. The one above only saves you the wait: a build takes minutes, and a
# meeting that starts during it would otherwise be killed by a script that
# checked when nothing was happening.
if [ -z "$LISTEN_INSTALL_FORCE" ] && recording_now; then refuse; fi

# Quit the running copy so we are not overwriting a live binary.
#
# Anchored, because `pkill -f` matches the whole command line and other
# processes carry this path as an argument. The former LAN helper exposed this
# first, and `Listen mcp` is still a current example: an unanchored install kill
# must not stop a process merely because it was handed the app's executable.
pkill -f "^$DEST/Contents/MacOS/Listen$" 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$ROOT/Listen.app" "$DEST"
echo "installed -> $DEST"

open "$DEST"
echo "restarted"
