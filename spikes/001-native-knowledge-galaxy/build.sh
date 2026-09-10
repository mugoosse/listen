#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/.build"
mkdir -p "$BUILD"
SHARED=()
for name in ContextDatabase ContextLedger ContextCard ContextSync MemoryPreferences Hashing Metadata Sidecars; do
  SHARED+=("$ROOT/Sources/ListenKit/$name.swift")
done
REBUILD=0
if [[ ! -f "$BUILD/libListenKit.dylib" || ! -f "$BUILD/ListenKit.swiftmodule" ]]; then REBUILD=1; fi
for source in "${SHARED[@]}"; do
  if [[ "$source" -nt "$BUILD/libListenKit.dylib" ]]; then REBUILD=1; fi
done
if [[ "$REBUILD" == 1 ]]; then
  swiftc -O -emit-library -emit-module -module-name ListenKit \
    -emit-module-path "$BUILD/ListenKit.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libListenKit.dylib \
    "${SHARED[@]}" -o "$BUILD/libListenKit.dylib"
fi
swiftc -O -parse-as-library -I "$BUILD" -L "$BUILD" -lListenKit \
  -Xlinker -rpath -Xlinker @executable_path \
  "$HERE"/Sources/*.swift "$HERE"/*.swift -o "$BUILD/ListenGalaxy"
printf 'Built %s\n' "$BUILD/ListenGalaxy"
