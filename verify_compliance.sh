#!/bin/bash
# Every claim the compliance work makes about the CLI surface, as assertions
# over the app built in the working directory. Run ./build.sh && ./make_app.sh
# first, or this tests the previous build. The shape follows verify_title.sh:
# a scratch LISTEN_LIBRARY, property assertions, pass/fail counters.
set -u
cd "$(dirname "$0")"
BIN="$(pwd)/Listen.app/Contents/MacOS/Listen"
[[ -x "$BIN" ]] || { echo "no built app. ./build.sh && ./make_app.sh first."; exit 1; }

SCRATCH="${TMPDIR:-/tmp}/listen-verify-compliance"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/library" "$SCRATCH/backups"
export LISTEN_LIBRARY="$SCRATCH/library"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

# --- the MCP surface leaves a trace, and the trace carries no content -------

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_transcripts","arguments":{"query":"the secret plan"}}}' \
  | "$BIN" mcp >/dev/null 2>&1

LOG="$LISTEN_LIBRARY/activity.jsonl"
if [[ -f "$LOG" ]] && grep -q '"event":"mcp_call"' "$LOG" \
   && grep -q '"transport":"stdio"' "$LOG"; then
  ok "an MCP tool call lands in activity.jsonl with its transport"
else
  bad "the MCP call left no activity entry"
fi
if grep -q "secret plan" "$LOG" 2>/dev/null; then
  bad "the activity log carries the query text"
else
  ok "the activity log names the tool and never the query"
fi
if "$BIN" activity --limit 5 | grep -q "mcp_call"; then
  ok "listen activity reads the log back"
else
  bad "listen activity shows nothing"
fi

# --- stderr keeps to ids and slugs ------------------------------------------

ERR="$("$BIN" dictionary add "Marcia Verhoeven" 2>&1 >/dev/null)"
if grep -q "Marcia" <<< "$ERR"; then
  bad "dictionary add echoed the term to stderr"
else
  ok "dictionary add reports the event without the words"
fi

REC="2026-08-14-090000-AAAA"
mkdir -p "$LISTEN_LIBRARY/recordings/$REC"
printf '%s' "{\"id\":\"$REC\",\"title\":\"Fixture\",\"recorded_at\":\"2026-08-14T09:00:00Z\",\"duration\":60,\"source\":\"mac\",\"state\":\"done\"}" \
  > "$LISTEN_LIBRARY/recordings/$REC/metadata.json"
SLUG="$("$BIN" notes write "A Confidential Title" --body "the body" --recording "$REC" 2>/dev/null | tail -1)"
if [[ -n "$SLUG" ]]; then
  READERR="$("$BIN" notes read "$SLUG" 2>&1 >/dev/null)"
  if grep -q "Confidential" <<< "$READERR"; then
    bad "notes read echoed the title to stderr"
  else
    ok "notes read keeps the title off stderr"
  fi
  DELERR="$("$BIN" notes delete "$SLUG" 2>&1 >/dev/null)"
  if grep -q "Confidential" <<< "$DELERR"; then
    bad "notes delete echoed the title to stderr"
  else
    ok "notes delete keeps the title off stderr"
  fi
else
  bad "could not create a note to test with"
fi

# --- hosted endpoints need https, and a profile can pin Ask to this Mac -----

if "$BIN" provider add http://api.example.com/v1 2>&1 | grep -q "https"; then
  ok "plain http to a hosted endpoint is refused with the reason"
else
  bad "a hosted http endpoint was not refused"
fi
if echo "n" | "$BIN" provider add https://api.example.com/v1 2>&1 | grep -q "Not added"; then
  ok "a hosted provider asks before it is stored, and n stops it"
else
  bad "the CLI stored a hosted provider without asking"
fi
if LISTEN_MANAGED='{"agentLoopbackOnly": true}' "$BIN" provider add openrouter 2>&1 \
   | grep -q "organisation"; then
  ok "a loopback-only profile refuses a hosted provider, naming the profile"
else
  bad "the managed loopback restriction did not hold"
fi

# --- backups are owner-only, and a profile can move or stop them ------------

LISTEN_MANAGED="{\"backupsPath\": \"$SCRATCH/backups/Listen\"}" "$BIN" backup --now >/dev/null 2>&1
MODE="$(stat -f %Lp "$SCRATCH/backups/Listen" 2>/dev/null || echo missing)"
if [[ "$MODE" == "700" ]]; then
  ok "the backup folder is created owner-only (700)"
else
  bad "the backup folder mode is $MODE, not 700"
fi
if LISTEN_MANAGED='{"backupsDisabled": true}' "$BIN" backup 2>/dev/null \
   | grep -q "managed profile"; then
  ok "a profile can turn backups off, and the CLI says so"
else
  bad "backupsDisabled did not hold"
fi

# --- sync status names its environment and its last pass --------------------

# The one command a stalled install gets asked to run has to say which
# CloudKit environment this build reaches (TestFlight and Developer ID are
# Production, an Xcode debug install is Development, and a mismatch is
# invisible everywhere else) and, when a pass has run, what the last one said.
if "$BIN" sync status 2>/dev/null | grep -qi "environment:"; then
  ok "sync status names the CloudKit environment"
else
  bad "sync status says nothing about the environment"
fi

# --- the log rotates rather than growing without bound ----------------------

python3 - "$LOG" <<'EOF'
import sys
line = '{"at":"2026-01-01T00:00:00Z","event":"filler"}\n'
with open(sys.argv[1], "a") as f:
    f.write(line * (5 * 1024 * 1024 // len(line) + 100))
EOF
printf '%s\n' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_tags","arguments":{}}}' \
  | "$BIN" mcp >/dev/null 2>&1
if [[ -f "$LISTEN_LIBRARY/activity.1.jsonl" ]]; then
  ok "the activity log rotates at its cap"
else
  bad "the activity log grew past its cap without rotating"
fi

echo
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
