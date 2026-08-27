#!/bin/bash
# Asserts the telemetry consent machine from outside the process: an unset or
# denied consent produces ZERO requests (not zero events, zero requests), the
# managed kill switch, LISTEN_NO_TELEMETRY, and a build nobody released all
# silence a consented install, and the beforeSend allowlist drops off-schema
# events and smuggled properties. Run ./build.sh && ./make_app.sh first, or
# this tests the last build (and case 6 specifically wants that build to be
# a plain local one, without LISTEN_RELEASE_BUILD=1: that is the point of it).
#
# The app under test is a copy with its own bundle identifier, per the
# CLAUDE.md setup-rerun recipe, so nothing here touches the real preferences.
# Expect the copy to raise a Keychain prompt naming the real app once per
# launch; Deny is the right answer and the test does not depend on it.
set -u

cd "$(dirname "$0")"

APP=Listen.app
[ -d "$APP" ] || { echo "no $APP here. ./build.sh && ./make_app.sh first."; exit 1; }

PORT=8765
DOMAIN=com.mgo.listen-uitest
COPY=/tmp/ListenTelemetryTest.app
SCRATCH=$(mktemp -d /tmp/listen-telemetry-lib.XXXXXX)
CAPTURE=$(mktemp /tmp/listen-telemetry-capture.XXXXXX)
GATE_LOG=$(mktemp /tmp/listen-telemetry-gate.XXXXXX)
FAILURES=0

say()  { printf '%s\n' "$*"; }
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# --- the listener -----------------------------------------------------------
# Decompresses gzip bodies because the SDK compresses batches; every request
# body lands in $CAPTURE as one line of JSON-ish text.
python3 - "$PORT" "$CAPTURE" <<'PY' &
import gzip, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port, capture = int(sys.argv[1]), sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        if self.headers.get("Content-Encoding") == "gzip":
            try: body = gzip.decompress(body)
            except OSError: pass
        with open(capture, "ab") as f:
            f.write(self.path.encode() + b" " + body + b"\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{\"status\":1}")
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *args): pass

HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
LISTENER=$!
trap 'kill $LISTENER 2>/dev/null; rm -rf "$COPY" "$SCRATCH" "$CAPTURE" "$GATE_LOG"' EXIT
sleep 1

# --- the app copy -----------------------------------------------------------
rm -rf "$COPY"
cp -R "$APP" "$COPY"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DOMAIN" "$COPY/Contents/Info.plist"
codesign --force --sign - --deep "$COPY" 2>/dev/null

# Launch the binary directly, never `open`: Launch Services would prefer
# /Applications and drop the environment. See CLAUDE.md.
launch() {  # launch <seconds> [extra env as VAR=VALUE ...]
    local seconds=$1; shift
    : > "$CAPTURE"
    env LISTEN_LIBRARY="$SCRATCH" \
        LISTEN_TELEMETRY_ENDPOINT="http://127.0.0.1:$PORT" \
        LISTEN_TELEMETRY_SELFTEST=1 \
        "$@" \
        "$COPY/Contents/MacOS/Listen" >/dev/null 2>&1 &
    APP_PID=$!
    sleep "$seconds"
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
}

requests() { wc -c < "$CAPTURE" | tr -d ' '; }

# Deliberately without LISTEN_TELEMETRY_ENDPOINT: case 6 is exactly the
# scenario that override exists to make safe to test everywhere else, so
# testing the release gate itself has to launch without it. Safe anyway:
# `Telemetry.startIfConsented()` reports `blocked` before its own guard, and
# returns immediately when blocked, so a build with the gate working can
# never construct the SDK or reach any host, real or fake, whatever this
# prints. $GATE_LOG is stdout+stderr, not the request capture file: there is
# nothing to intercept when nothing is sent.
launch_no_endpoint() {  # launch_no_endpoint <seconds>
    local seconds=$1
    env LISTEN_LIBRARY="$SCRATCH" \
        LISTEN_TELEMETRY_SELFTEST=1 \
        LISTEN_DEBUG=1 \
        "$COPY/Contents/MacOS/Listen" >"$GATE_LOG" 2>&1 &
    APP_PID=$!
    sleep "$seconds"
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
}

# --- case 1: consent unset sends nothing ------------------------------------
say "1. consent never asked"
defaults delete "$DOMAIN" >/dev/null 2>&1
launch 10
if [ "$(requests)" = "0" ]; then pass "zero requests before consent"
else fail "requests arrived with consent unset:"; head -c 400 "$CAPTURE"; echo; fi

# --- case 2: consent denied sends nothing ------------------------------------
say "2. consent denied"
defaults delete "$DOMAIN" >/dev/null 2>&1
defaults write "$DOMAIN" telemetryConsent -bool false
defaults write "$DOMAIN" onboarded -bool true
defaults write "$DOMAIN" telemetryPrompted -bool true
launch 10
if [ "$(requests)" = "0" ]; then pass "zero requests after an explicit no"
else fail "requests arrived with consent denied"; fi

# --- case 3: consented, the allowlist filters -------------------------------
say "3. consented, self-test events"
defaults delete "$DOMAIN" >/dev/null 2>&1
defaults write "$DOMAIN" telemetryConsent -bool true
defaults write "$DOMAIN" onboarded -bool true
defaults write "$DOMAIN" telemetryPrompted -bool true
launch 15
if [ "$(requests)" = "0" ]; then
    fail "nothing arrived from a consented install (selftest flushes explicitly)"
else
    pass "a consented install sends"
    if grep -q "feature_used" "$CAPTURE"; then pass "the known-good event arrived"
    else fail "feature_used missing from the batch"; fi
    if grep -q "off_schema_event" "$CAPTURE"; then fail "an off-schema event escaped"
    else pass "the off-schema event was dropped"; fi
    if grep -q "smuggled_title" "$CAPTURE"; then fail "an off-schema property escaped"
    else pass "the off-schema property was stripped"; fi
    if grep -q '\$device_name' "$CAPTURE"; then fail "\$device_name escaped"
    else pass "\$device_name never travels"; fi
fi

# --- case 4: the managed kill switch ----------------------------------------
say "4. managed telemetryDisabled"
launch 10 LISTEN_MANAGED='{"telemetryDisabled":true}'
if [ "$(requests)" = "0" ]; then pass "a forced-off install sends nothing, whatever consent says"
else fail "requests arrived under a managed kill"; fi

# --- case 5: the environment kill -------------------------------------------
say "5. LISTEN_NO_TELEMETRY=1"
launch 10 LISTEN_NO_TELEMETRY=1
if [ "$(requests)" = "0" ]; then pass "the env seam silences a consented install"
else fail "requests arrived under LISTEN_NO_TELEMETRY"; fi

# --- case 6: a build nobody released -----------------------------------------
# This is the app built moments ago by hand, so it carries no
# ListenReleaseBuild key: only make_app.sh writes it, only when release.sh
# asks. A consented, local, no-override launch has to report itself blocked
# for exactly that reason, or a developer's own daily use of their own
# build would count as a real install every time it runs.
say "6. a consented local build, no override"
defaults delete "$DOMAIN" >/dev/null 2>&1
defaults write "$DOMAIN" telemetryConsent -bool true
defaults write "$DOMAIN" onboarded -bool true
defaults write "$DOMAIN" telemetryPrompted -bool true
: > "$GATE_LOG"
launch_no_endpoint 8
if grep -q "TELEMETRY_SELFTEST isReleaseBuild=false blocked=true" "$GATE_LOG"; then
    pass "a local build reports itself blocked, and never got as far as a host"
else
    fail "the release gate did not report blocked for a local build:"
    grep "TELEMETRY_SELFTEST" "$GATE_LOG" || echo "  (no TELEMETRY_SELFTEST line at all)"
fi

defaults delete "$DOMAIN" >/dev/null 2>&1
echo
if [ "$FAILURES" = "0" ]; then echo "telemetry: all checks passed"; exit 0
else echo "telemetry: $FAILURES check(s) FAILED"; exit 1; fi
