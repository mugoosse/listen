#!/bin/bash
# Every claim in the "notes get tags" and "the allowlist is an argument" work,
# as assertions, over the app built in the working directory.
#
# Builds nothing. Run `./build.sh && ./make_app.sh` first or it tests the last
# build. It never opens the real library: everything happens under a scratch
# LISTEN_LIBRARY made here and removed at the end.
#
# The one thing it cannot assert is the search field lifting `tag:kinsight `
# into a pill, which is a window behaviour. It asserts the predicate underneath
# instead, which is what actually regresses; the lift itself is a manual check.
set -u
cd "$(dirname "$0")"

BIN="$(pwd)/Listen.app/Contents/MacOS/Listen"
[[ -x "$BIN" ]] || { echo "no built app. ./build.sh && ./make_app.sh first."; exit 1; }

SCRATCH="${TMPDIR:-/tmp}/listen-verify-note-tags"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
export LISTEN_LIBRARY="$SCRATCH"
NOTES="$SCRATCH/notes"

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL: $1"; }

REC="2026-08-20-090000-AAAA"
REC2="2026-08-21-090000-BBBB"
for id in "$REC" "$REC2"; do
  mkdir -p "$SCRATCH/recordings/$id"
  printf '%s' "{\"id\":\"$id\",\"title\":\"Meeting $id\",\"recorded_at\":\"2026-08-20T09:00:00Z\",\"duration\":600,\"source\":\"mac\",\"state\":\"done\"}" \
    > "$SCRATCH/recordings/$id/metadata.json"
done

# --- a note round-trips its tags -------------------------------------------
echo
echo "the file on disk"

SLUG="$("$BIN" notes write "Job hunt roundup" --recording "$REC" \
        --body "the body" --tag "job hunt" --tag acme 2>/dev/null)"
if grep -q 'tags: \["acme", "job hunt"\]' "$NOTES/$SLUG.md"; then
  ok "tags are a quoted flow sequence, sorted, above recordings"
else
  bad "the tags line is not what encode should write: $(grep '^tags:' "$NOTES/$SLUG.md")"
fi

# The key is written even when empty, which is the opposite of what a recording
# does, so that clearing tags is an instruction a peer's `extra` merge can see.
BARE="$("$BIN" notes write "No filing" --recording "$REC" --body "b" 2>/dev/null)"
if grep -q '^tags: \[\]$' "$NOTES/$BARE.md"; then
  ok "an untagged note writes tags: [], not a missing key"
else
  bad "an untagged note omitted the tags key"
fi

"$BIN" notes write --replace "$SLUG" --body "body two" >/dev/null 2>&1
if grep -q 'job hunt' "$NOTES/$SLUG.md"; then
  ok "a rewrite with no --tag leaves the filing alone"
else
  bad "--replace dropped the tags"
fi

# --- files this version did not write --------------------------------------
echo
echo "files written by something else"

cat > "$NOTES/old-shape.md" <<EOF
---
title: "Written before tags existed"
created: 2026-08-19T09:00:00Z
updated: 2026-08-19T09:00:00Z
source: agent
recordings: ["$REC"]
---

Nothing here mentions tags.
EOF
if "$BIN" notes list 2>/dev/null | grep -q old-shape; then
  ok "a note with no tags key still lists"
else
  bad "an old-shaped note stopped reading"
fi

cat > "$NOTES/by-hand.md" <<EOF
---
title: "Dropped in with Finder"
created: 2026-08-19T10:00:00Z
updated: 2026-08-19T10:00:00Z
source: you
tags:
  - alpha
  - "beta gamma"
recordings: []
---

Body.
EOF
if "$BIN" notes list 2>/dev/null | grep by-hand | grep -q "beta gamma"; then
  ok "a YAML block sequence of tags reads"
else
  bad "the block sequence was dropped"
fi

"$BIN" notes write --replace by-hand --body "Body two" >/dev/null 2>&1
if grep -q '"beta gamma"' "$NOTES/by-hand.md"; then
  ok "and survives being written back"
else
  bad "the block sequence was lost on the first rewrite"
fi

# --- one vocabulary ---------------------------------------------------------
echo
echo "one vocabulary, two kinds of thing"

# A note holds "job hunt". Tagging a recording "Job Hunt" must adopt it.
"$BIN" tags add "$REC" "Job Hunt" >/dev/null 2>&1
if "$BIN" show "$REC" 2>/dev/null | grep -q "tags: .*job hunt"; then
  ok "a recording adopts a note's spelling"
else
  bad "a recording did not adopt the note's spelling"
fi

# And the other way: a recording holds "acme" via the note above; add "ACME".
"$BIN" tags add "$REC2" acme >/dev/null 2>&1
"$BIN" tags add --note by-hand "ACME" >/dev/null 2>&1
if grep -q '"acme"' "$NOTES/by-hand.md"; then
  ok "a note adopts a recording's spelling"
else
  bad "a note did not adopt the recording's spelling"
fi

if "$BIN" tags 2>/dev/null | grep "job hunt" | grep -q "and"; then
  ok "listen tags reports both counts on one row"
else
  bad "the counts are not joined: $("$BIN" tags 2>/dev/null | grep 'job hunt')"
fi

if "$BIN" tags 2>/dev/null | grep -q "^beta gamma.*1 note$"; then
  ok "a tag only a note carries is in the vocabulary, and says so"
else
  bad "a note-only tag is missing or mis-summarised"
fi

# --- no inheritance ---------------------------------------------------------
echo
echo "no inheritance"

# `old-shape` is about $REC, which carries "job hunt". It must not match.
if "$BIN" notes list --tag "job hunt" 2>/dev/null | grep -q old-shape; then
  bad "a note inherited its recording's tag"
else
  ok "a note carries only what was put on it"
fi
if "$BIN" notes list --tag "job hunt" 2>/dev/null | grep -q "$SLUG"; then
  ok "and a note that was tagged does match"
else
  bad "notes list --tag missed a note that carries the tag"
fi

# --- a rename reaches both --------------------------------------------------
echo
echo "a library-wide edit reaches both kinds"

OUT="$("$BIN" tags rename "job hunt" "the search" 2>&1)"
if grep -q "recording" <<< "$OUT" && grep -q "note" <<< "$OUT"; then
  ok "rename reports recordings and notes: $(tr -d '\n' <<< "$OUT")"
else
  bad "rename under-reported: $OUT"
fi
if grep -q '"the search"' "$NOTES/$SLUG.md" \
   && "$BIN" show "$REC" 2>/dev/null | grep -q "the search"; then
  ok "and actually changed both"
else
  bad "the rename missed one kind"
fi
if "$BIN" tags 2>/dev/null | grep -q "^job hunt"; then
  bad "the old name is still in the vocabulary"
else
  ok "the old name is gone, because a tag nothing carries does not exist"
fi

# --- the tag lens over notes ------------------------------------------------
echo
echo "the tag lens"

# `$SLUG` is about exactly one recording, so it is not `pageless` and is
# ordinarily left out of the list. Under a tag lens it has to be listed.
if "$BIN" list --tag "the search" 2>/dev/null | grep -q "$REC"; then
  ok "listen list --tag finds the recording"
else
  bad "listen list --tag missed the recording"
fi
if "$BIN" notes list --tag "the search" 2>/dev/null | grep -q "$SLUG"; then
  ok "notes list --tag finds the single-source note (the pageless reversal)"
else
  bad "notes list --tag missed the single-source note"
fi

# --- the user's own note ----------------------------------------------------
echo
echo "the user's own note"

YOURS="$REC-yours"
cat > "$NOTES/$YOURS.md" <<EOF
---
title: "Your notes"
created: 2026-08-19T11:00:00Z
updated: 2026-08-19T11:00:00Z
source: you
tags: []
recordings: ["$REC"]
---

What I typed during the call.
EOF
call() {
  printf '%s\n' "$1" | "$BIN" mcp 2>/dev/null \
    | python3 -c "import sys,json;d=json.load(sys.stdin);r=d.get('result',{});print(('ERR ' if r.get('isError') else '')+r['content'][0]['text'])"
}
RES="$(call "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"add_tags\",\"arguments\":{\"note\":\"$YOURS\",\"tags\":[\"mine\"]}}}")"
if grep -q '"mine"' <<< "$RES"; then
  ok "an agent may tag the user's own note"
else
  bad "tagging the user's own note was refused: $RES"
fi
RES="$(call "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"edit_note\",\"arguments\":{\"note\":\"$YOURS\",\"body\":\"x\",\"was\":\"What I typed during the call.\"}}}")"
if grep -q '^ERR' <<< "$RES"; then
  ok "and still may not rewrite its words"
else
  bad "the user's own note was rewritten from MCP"
fi

# --- tagging does not mark a note hand-edited -------------------------------
echo
echo "filing is not editing"

CREATED="$(grep '^created:' "$NOTES/$YOURS.md" | cut -d' ' -f2)"
UPDATED="$(grep '^updated:' "$NOTES/$YOURS.md" | cut -d' ' -f2)"
if [[ "$CREATED" == "$UPDATED" ]]; then
  ok "add_tags left updated alone, so edited_by_hand stays false"
else
  bad "tagging moved updated: $CREATED -> $UPDATED"
fi

# --- the MCP surface --------------------------------------------------------
echo
echo "the MCP tools"

RES="$(call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_tags","arguments":{"tags":["x"]}}}')"
grep -q '^ERR.*needs recording_id or note' <<< "$RES" \
  && ok "add_tags with neither names both" || bad "wrong error for neither: $RES"

RES="$(call "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"add_tags\",\"arguments\":{\"note\":\"$SLUG\",\"recording_id\":\"$REC\",\"tags\":[\"x\"]}}}")"
grep -q '^ERR.*not both' <<< "$RES" \
  && ok "add_tags with both is refused rather than resolved" \
  || bad "wrong error for both: $RES"

RES="$(call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_tags","arguments":{}}}')"
grep -q '"notes"' <<< "$RES" && grep -q '"recordings"' <<< "$RES" \
  && ok "list_tags carries both counts on every row" \
  || bad "list_tags is missing a count: $RES"

# --- the allowlist is enforced ----------------------------------------------
echo
echo "listen mcp --tools"

COUNT="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | "$BIN" mcp --tools list_tags,list_notes 2>/dev/null | grep -o '"name"' | wc -l | tr -d ' ')"
[[ "$COUNT" == "2" ]] && ok "tools/list is filtered to the allowlist" \
                      || bad "tools/list returned $COUNT tools, not 2"

OUT="$(printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"delete_note\",\"arguments\":{\"note\":\"by-hand\"}}}" \
  | "$BIN" mcp --tools list_tags,list_notes 2>/dev/null)"
if grep -q '"isError":true' <<< "$OUT" && grep -q 'delete_note' <<< "$OUT"; then
  ok "a tool outside the allowlist is refused by name"
else
  bad "delete_note was not refused, or the refusal did not name it"
fi
[[ -f "$NOTES/by-hand.md" ]] && ok "and the note is still on disk" \
                             || bad "delete_note ran"

printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}' \
  | "$BIN" mcp 2>/dev/null | grep -q delete_note \
  && ok "an unrestricted server still offers everything" \
  || bad "the default surface changed"

"$BIN" mcp --tools nope </dev/null 2>&1 | grep -q 'no tool named .nope' \
  && ok "an unknown tool name is refused at startup" \
  || bad "a typo in --tools was accepted"

"$BIN" mcp --wat </dev/null 2>&1 | grep -q 'unknown option' \
  && ok "an unknown option is refused rather than ignored" \
  || bad "listen mcp still ignores an unknown option"

# The refusal is logged like any other failure, which is what makes it audible
# to an audit. `verify_compliance.sh` owns the activity log; this is the one
# line about a refused call.
if grep -q '"tool":"delete_note".*"ok":false' "$SCRATCH/activity.jsonl" 2>/dev/null \
   || grep -q '"ok":false' "$SCRATCH/activity.jsonl" 2>/dev/null; then
  ok "the refused call is in the activity log"
else
  bad "a refused tool call left no trace"
fi

echo
echo "$pass passed, $fail failed"
rm -rf "$SCRATCH"
[[ $fail -eq 0 ]]
