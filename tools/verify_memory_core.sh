#!/bin/sh
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/listen-memory-core.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
swiftc "$HERE/Sources/ListenKit/ContextDatabase.swift" \
  "$HERE/Sources/ListenKit/ContextLedger.swift" \
  "$HERE/Sources/ListenKit/ContextSearch.swift" \
  "$HERE/Sources/ListenKit/ContextCard.swift" \
  "$HERE/Sources/ListenKit/ContextSync.swift" \
  "$HERE/Sources/ListenKit/MemoryPreferences.swift" \
  "$HERE/Sources/ListenKit/Hashing.swift" \
  "$HERE/tools/verify_memory_core.swift" -o "$TMP/verify"
"$TMP/verify"
