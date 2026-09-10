#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/.build"
bash "$HERE/build.sh"
LINK=(-parse-as-library -I "$BUILD" -L "$BUILD" -lListenKit -Xlinker -rpath -Xlinker @executable_path)
swiftc "${LINK[@]}" "$HERE"/Sources/*.swift "$HERE/tests/test_core.swift" -o "$BUILD/test-core"
"$BUILD/test-core"
swiftc "${LINK[@]}" "$HERE/GraphLibrary.swift" "$HERE/tests/test_library.swift" -o "$BUILD/test-library"
"$BUILD/test-library"
swiftc -parse-as-library "$HERE/GraphCamera.swift" "$HERE/tests/GraphCameraTests.swift" -o "$BUILD/test-camera"
"$BUILD/test-camera"
for test in test_renderer test_motion test_galaxy_renderer; do
  if [[ -f "$HERE/tests/$test.swift" ]]; then
    swiftc "${LINK[@]}" "$HERE"/Sources/*.swift "$HERE/GraphCamera.swift" "$HERE/GraphMotion.swift" "$HERE/GraphRenderer.swift" "$HERE/GraphGPUProbe.swift" "$HERE/tests/$test.swift" -o "$BUILD/$test"
    "$BUILD/$test"
  fi
done
swiftc "${LINK[@]}" "$HERE"/Sources/*.swift "$HERE/tests/test_shells.swift" -o "$BUILD/test-shells"
"$BUILD/test-shells"
swiftc -parse-as-library "$HERE/GraphAnimation.swift" "$HERE/GraphCamera.swift" "$HERE/tests/test_animation.swift" -o "$BUILD/test-animation"
"$BUILD/test-animation"
swiftc "${LINK[@]}" "$HERE"/Sources/*.swift "$HERE/GraphAnimation.swift" "$HERE/GraphCamera.swift" "$HERE/GraphMotion.swift" "$HERE/GraphRenderer.swift" "$HERE/GraphGPUProbe.swift" "$HERE/GraphViewController.swift" "$HERE/tests/test_focus_cancellation.swift" -o "$BUILD/test-focus-cancellation"
"$BUILD/test-focus-cancellation"
python3 "$HERE/tests/test_cli.py"
if [[ "${1:-}" == "--ui" ]]; then python3 "$HERE/tests/test_ui.py"; fi
