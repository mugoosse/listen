#!/bin/sh
# Builds the memory core out of the real ListenKit sources and runs the
# assertions in verify_memory_core.swift.
#
# It compiles the whole module rather than the seven files the assertions
# name. The named list broke twice on upstream edits that added no API this
# harness calls: `MemoryPreferences` grew a reference to `CloudRecords`, which
# needs `Recording`, `DevicePolicy`, `RecordStore`, `PairingKey` and so on, and
# swiftc needs every one of those declarations in scope for a function nothing
# here invokes. ListenKit deliberately depends on nothing (see Package.swift),
# so the whole module compiles standalone, and compiling all of it is the only
# version of this list that an upstream edit cannot invalidate.
#
# The module is cached under .xcbuild/tools, keyed on the content of the
# sources: about two minutes the first time and about two seconds after that.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$HERE/Sources/ListenKit"
CACHE="$HERE/.xcbuild/tools/memory-core"
TMP="$(mktemp -d /tmp/listen-memory-core.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$CACHE"

WANT="$(ls "$KIT"/*.swift | sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
if [ ! -f "$CACHE/libListenKit.dylib" ] || [ ! -f "$CACHE/stamp" ] || [ "$(cat "$CACHE/stamp")" != "$WANT" ]; then
  printf 'Building ListenKit (about two minutes, then cached)…\n'
  rm -f "$CACHE/stamp"
  swiftc -Onone -emit-library -emit-module -module-name ListenKit \
    -emit-module-path "$CACHE/ListenKit.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libListenKit.dylib \
    "$KIT"/*.swift -o "$CACHE/libListenKit.dylib"
  printf '%s' "$WANT" > "$CACHE/stamp"
fi

swiftc -parse-as-library -I "$CACHE" -L "$CACHE" -lListenKit \
  -Xlinker -rpath -Xlinker "$CACHE" \
  "$HERE/tools/verify_memory_core.swift" -o "$TMP/verify"
"$TMP/verify"
