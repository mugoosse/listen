#!/bin/bash
# Every claim `listen mcp connect-desktop` makes, as assertions, against
# scratch config files. Nothing here touches the real Claude app config: the
# --config flag is the same override the app's button honours through
# LISTEN_CLAUDE_CONFIG, and every path is under a temp directory.
set -u

BIN="$(cd "$(dirname "$0")" && pwd)/Listen.app/Contents/MacOS/Listen"
DIR="${TMPDIR:-/tmp}/listen-verify-desktop"
CFG="$DIR/claude_desktop_config.json"
BAK="$DIR/claude_desktop_config.json.listen-backup"

[ -x "$BIN" ] || { echo "build first: ./build.sh && ./make_app.sh" >&2; exit 2; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }
check() { if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi }

json() { python3 -c "import json,sys; d=json.load(open('$CFG')); $1" 2>/dev/null; }

reset() { rm -rf "$DIR"; mkdir -p "$DIR"; }

echo "1. a missing file is created with only our entry"
reset
rm -f "$CFG"
"$BIN" mcp connect-desktop --config "$CFG" >/dev/null 2>&1
check $? "connect on a missing file exits 0"
json "assert d['mcpServers']['listen']['args'] == ['mcp']; assert d['mcpServers']['listen']['command']"
check $? "the entry names a command and args [mcp]"
[ ! -f "$BAK" ]; check $? "no backup was made when there was nothing to back up"

echo "2. an empty file counts as a config nobody wrote yet"
reset
: > "$CFG"
"$BIN" mcp connect-desktop --config "$CFG" >/dev/null 2>&1
check $? "connect on an empty file exits 0"
json "assert 'listen' in d['mcpServers']"
check $? "the entry landed"

echo "3. foreign keys and servers survive, and the original is backed up"
reset
cat > "$CFG" <<'JSON'
{
  "mcpServers": {
    "mobile-mcp": {"command": "/usr/local/bin/mobile-mcp", "args": ["serve"]}
  },
  "coworkUserFilesPath": "/Users/somebody/Files",
  "preferences": {"theme": "dark"}
}
JSON
cp "$CFG" "$DIR/original.json"
"$BIN" mcp connect-desktop --config "$CFG" >/dev/null 2>&1
check $? "connect over a real config exits 0"
json "assert d['mcpServers']['mobile-mcp']['args'] == ['serve']"
check $? "the foreign server is untouched"
json "assert d['coworkUserFilesPath'] == '/Users/somebody/Files' and d['preferences']['theme'] == 'dark'"
check $? "unknown top-level keys are untouched"
json "assert 'listen' in d['mcpServers']"
check $? "our entry is beside them"
cmp -s "$BAK" "$DIR/original.json"
check $? "the backup is the file from before the write, byte for byte"

echo "4. a second run changes nothing, backup included"
before=$(cat "$CFG")
before_bak=$(cat "$BAK")
out=$("$BIN" mcp connect-desktop --config "$CFG" 2>&1)
check $? "the second run exits 0"
echo "$out" | grep -q "Already connected"
check $? "and says it was already connected"
[ "$before" = "$(cat "$CFG")" ]; check $? "the config was not rewritten"
[ "$before_bak" = "$(cat "$BAK")" ]; check $? "the backup was not rewritten"

echo "5. malformed JSON is refused and left byte for byte alone"
reset
printf '{"mcpServers": {broken' > "$CFG"
cp "$CFG" "$DIR/broken.json"
"$BIN" mcp connect-desktop --config "$CFG" >/dev/null 2>"$DIR/err.txt"
[ $? -ne 0 ]; check $? "connect on a broken file exits non-zero"
grep -q "not valid JSON" "$DIR/err.txt"
check $? "the refusal says the file is not valid JSON"
cmp -s "$CFG" "$DIR/broken.json"
check $? "the broken file was not touched"
[ ! -f "$BAK" ]; check $? "no backup of a file nothing was going to change"

echo "6. an mcpServers that is not an object is refused too"
reset
printf '{"mcpServers": "yes"}' > "$CFG"
cp "$CFG" "$DIR/odd.json"
"$BIN" mcp connect-desktop --config "$CFG" >/dev/null 2>&1
[ $? -ne 0 ]; check $? "connect refuses rather than replacing it"
cmp -s "$CFG" "$DIR/odd.json"
check $? "and the file is untouched"

echo "7. --dry-run writes nothing"
reset
rm -f "$CFG"
out=$("$BIN" mcp connect-desktop --config "$CFG" --dry-run 2>&1)
check $? "dry run exits 0"
echo "$out" | grep -q "Would write"
check $? "and says what it would do"
[ ! -f "$CFG" ]; check $? "without creating the file"

echo
echo "passed $pass, failed $fail"
[ "$fail" = "0" ] || exit 1
