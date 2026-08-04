#!/bin/sh
# Metal kernels need Xcode's build system; `swift build` alone produces a
# binary that dies with "Failed to load the default metallib".
set -e
if ! xcrun metal --version >/dev/null 2>&1; then
    echo "Metal toolchain missing. Run: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
fi
xcodebuild -scheme listen -destination 'platform=macOS,arch=arm64' \
    -configuration Release -derivedDataPath .xcbuild \
    -skipPackagePluginValidation build "$@"
echo "built: $(pwd)/.xcbuild/Build/Products/Release/listen"
