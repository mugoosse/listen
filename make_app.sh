#!/bin/sh
# Wrap the built binary in a real .app bundle.
#
# macOS attributes Microphone and audio-capture permissions to a bundle
# identity. A bare executable run from a terminal gets attributed to the
# terminal instead, so it never shows up in the permission list as itself.
#
# Env:
#   LISTEN_SIGN_ID   override the signing identity
#   LISTEN_BUILD     build number for CFBundleVersion (default: git commit count)
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILT="$ROOT/.xcbuild/Build/Products/Release"
APP="$ROOT/Listen.app"

[ -x "$BUILT/listen" ] || { echo "build first: ./build.sh" >&2; exit 1; }

# The binary has to be newer than the code, or it is not this code.
#
# A failed `build.sh` leaves the previous binary exactly where this script
# expects to find one, so bundling carried on and produced an app that looked
# built and did not contain the change. It happened twice, once from a build
# lock held by a shared worktree and once from the transient scheme error a
# fresh clone hits, and both times a "fix" was shipped and tested that had
# never been compiled.
STALE=$(find "$ROOT/Sources" -name '*.swift' -newer "$BUILT/listen" -print -quit 2>/dev/null)
if [ -n "$STALE" ]; then
    echo "error: the built binary is older than $(basename "$STALE")." >&2
    echo "       ./build.sh did not produce it. Run it again and read the" >&2
    echo "       output: bundling now ships code that was never compiled." >&2
    exit 1
fi

# Marketing version lives in one place; the build number is derived from commit
# count so it always increases, which macOS requires. Sparkle compares
# CFBundleVersion, so anything that makes it go backwards strands every
# installed copy.
VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
BUILD="${LISTEN_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

# SPARKLE_PUBLIC_KEY and SPARKLE_ACCOUNT, shared with release.sh so the key
# baked into Info.plist and the key the appcast is signed with cannot come
# apart.
. "$ROOT/sparkle.conf"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BUILT/listen" "$APP/Contents/MacOS/Listen"

# SPM resource bundles (notably mlx-swift's compiled Metal kernels) are looked
# up next to the executable, so they have to travel with it.
for b in "$BUILT"/*.bundle; do
    [ -e "$b" ] || continue
    cp -R "$b" "$APP/Contents/MacOS/"
    cp -R "$b" "$APP/Contents/Resources/"
done

# Icon, if it has been generated.
if [ -f "$ROOT/Assets/Listen.icns" ]; then
    cp "$ROOT/Assets/Listen.icns" "$APP/Contents/Resources/Listen.icns"
fi
if [ -f "$ROOT/Assets/MenuBarTemplate.png" ]; then
    cp "$ROOT/Assets/MenuBarTemplate.png" "$APP/Contents/Resources/MenuBarTemplate.png"
fi

# A machine-readable statement of every outbound connection, read by firewall
# tools such as Little Snitch. Listen claims audio never leaves the machine,
# and an update check is a connection, so it has to be declared rather than
# implied.
if [ -f "$ROOT/InternetAccessPolicy.plist" ]; then
    cp "$ROOT/InternetAccessPolicy.plist" "$APP/Contents/Resources/"
fi

# Sparkle ships as a binary framework. SwiftPM links it but does not embed it,
# so a bare executable built from this package dies at launch with a dyld
# "Library not loaded: @rpath/Sparkle.framework" error. Package.swift adds the
# matching rpath; this copies the framework to where that rpath points.
SPARKLE=$(find "$BUILT" -maxdepth 3 -name "Sparkle.framework" -type d 2>/dev/null | head -1)
if [ -n "$SPARKLE" ]; then
    mkdir -p "$APP/Contents/Frameworks"
    # -R would flatten the version symlinks a framework needs; ditto preserves
    # them, and a flattened framework fails codesign --verify.
    ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
else
    echo "warning: Sparkle.framework not found in $BUILT" >&2
    echo "         the app will not launch. Run ./build.sh first." >&2
fi

# Sparkle verifies every update against this key before installing it, so a
# wrong or missing value is the difference between an update channel and an
# arbitrary-code-execution channel. The key comes from sparkle.conf; an empty
# one omits the update keys entirely, which makes Sparkle refuse every update
# rather than accept one signed by somebody else. Shipping a placeholder key
# would be the dangerous option.
if [ -n "$SPARKLE_PUBLIC_KEY" ]; then
    SPARKLE_KEYS="    <key>SUFeedURL</key>
    <string>https://github.com/mugoosse/listen/releases/latest/download/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>${SPARKLE_PUBLIC_KEY}</string>
    <!-- Two days. Sparkle defaults to one, which is more attention than this
         deserves. -->
    <key>SUScheduledCheckInterval</key>
    <integer>172800</integer>"
else
    SPARKLE_KEYS="    <!-- No SUPublicEDKey yet: see make_app.sh. Sparkle will not update. -->"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Listen</string>
    <key>CFBundleDisplayName</key><string>Listen</string>
    <key>CFBundleIdentifier</key><string>com.mgo.listen</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleExecutable</key><string>Listen</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>Listen</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Deliberately NOT LSUIElement, which is where this differs from Speak.
         Speak is a menu bar utility with no primary window, so hiding it from
         the Dock is right. Listen's main surface is a window people read
         transcripts in for minutes at a time, and an app you cannot reach with
         Cmd-Tab or the Dock is an app you cannot get back to once the window
         is behind a browser. The menu bar item stays for start and stop.

         The onboarding rule this reverses one reason for still holds: windows
         float and re-activate after each permission prompt, because a window
         behind a system dialog is unrecoverable either way. -->
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Listen records your side of a meeting on this Mac.</string>
    <!-- The Core Audio process tap used for system audio (milestone 2) asks
         for audio capture, not screen recording, which is the entire reason to
         prefer taps over ScreenCaptureKit. -->
    <key>NSAudioCaptureUsageDescription</key>
    <string>Listen records the other side of a meeting on this Mac.</string>
    <!-- The full-access key, not the legacy NSCalendarsUsageDescription.
         LSMinimumSystemVersion is 14.0 and the call is
         requestFullAccessToEvents; there is no read-only tier that returns
         events, so asking for less would return an empty calendar and look
         exactly like a Mac with nothing in it.

         Unlike the two above, this one is optional. Listen records and
         transcribes without it; refusing costs the meeting's name and the
         attendee suggestions, which is why Permissions.allGranted does not
         include it. -->
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Listen reads the calendars already on this Mac, to name a recording after the meeting it belongs to and to suggest who was in it. Nothing is sent anywhere.</string>
${SPARKLE_KEYS}
</dict>
</plist>
PLIST

# Signing identity decides two things: whether other Macs will run this at all,
# and whether the microphone and audio-capture grants survive an update.
#
# Ad-hoc signing (`--sign -`) produces a designated requirement of
# `cdhash H"..."`, the hash of this exact build. TCC pins the grant to it, so
# every rebuild silently invalidates the permission: the toggle still looks on
# in System Settings, but the new binary is a different app as far as macOS is
# concerned, and capture quietly stops working. On an app that records hour
# long meetings that failure is expensive.
#
# Preference order:
#   Developer ID Application  distributable, notarizable
#   Apple Development         fine locally, rejected on other Macs
#   ad-hoc                    last resort
SIGN_ID="${LISTEN_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ {print $2; exit}')
fi

# Which CloudKit container this build talks to, decided here because it is a
# property of the signature and not a setting the app can change.
#
#   production   (default)  Developer ID + the Developer ID profile. What ships.
#   development             Apple Development + the Mac Development profile,
#                           for the scratch libraries Phase 3 develops against.
#
# A Developer ID build can only ever reach Production, so verifying against
# Development proves nothing about the configuration that goes out. That is why
# this is an explicit mode rather than something inferred from whichever
# certificate happened to be found.
ENTITLEMENTS="$ROOT/Listen.entitlements"
PROFILE="$ROOT/Provisioning/Listen_Developer_ID.provisionprofile"
if [ "${LISTEN_CLOUDKIT_ENV:-production}" = "development" ]; then
    PROFILE="$ROOT/Provisioning/Listen_Mac_Development.provisionprofile"
    # Derived, never a second file in the repo. The two differ in exactly two
    # values and everything else has to stay identical, so a committed copy is
    # a copy that eventually disagrees with the original about something that
    # matters and says nothing when it does.
    ENTITLEMENTS="$ROOT/.xcbuild/Listen.dev.entitlements"
    mkdir -p "$(dirname "$ENTITLEMENTS")"
    cp "$ROOT/Listen.entitlements" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c \
        "Set :com.apple.developer.icloud-container-environment Development" \
        "$ENTITLEMENTS" >/dev/null
    /usr/libexec/PlistBuddy -c \
        "Set :com.apple.developer.aps-environment development" \
        "$ENTITLEMENTS" >/dev/null
    # Overriding SIGN_ID rather than LISTEN_SIGN_ID, because the preference
    # order above has already run and picked Developer ID. A development
    # container is only reachable by a development signature, so the two have
    # to move together or the build claims an environment its certificate
    # cannot enter.
    if [ -z "${LISTEN_SIGN_ID:-}" ]; then
        SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
            | awk -F'"' '/Apple Development/ {print $2; exit}')
        [ -n "$SIGN_ID" ] || { echo "no Apple Development certificate" >&2; exit 1; }
    fi
fi

# The profile is what lets codesign accept the restricted iCloud entitlements
# at all, and it has to be inside Contents/ before the outer signature, because
# that signature seals whatever the bundle holds. Copied rather than referenced:
# the app has to carry it to every Mac it runs on.
if [ -f "$PROFILE" ]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
else
    echo "warning: $PROFILE is missing, so the iCloud entitlements have" >&2
    echo "         nothing vouching for them and codesign will refuse them." >&2
fi

# The Hardened Runtime is required for notarization and harmless without it,
# so it is always on. It is why the entitlements file exists: without the
# audio-input entitlement the runtime blocks the microphone.
COMMON="--force --timestamp --options runtime \
        --entitlements $ENTITLEMENTS --identifier com.mgo.listen"

# codesign, with its one routine line hidden and every other failure fatal.
#
# Each of these calls used to end `2>&1 | grep -v "replacing existing
# signature" || true`, which discards the outcome twice over: the exit status
# of a pipeline is the last command's, so it belonged to grep rather than to
# codesign, and `|| true` then threw that away too. A refusal printed nothing
# and the script went on to announce a build it had not signed. That is about
# to matter a great deal more than it did: a restricted entitlement without a
# matching provisioning profile fails precisely here.
sign() {
    for target; do :; done          # what is being signed is the last argument
    if out=$(codesign "$@" 2>&1); then
        status=0
    else
        status=$?
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | grep -v "replacing existing signature" || true
    fi
    if [ "$status" -ne 0 ]; then
        echo "error: codesign refused $target" >&2
        exit "$status"
    fi
}

if [ -n "$SIGN_ID" ]; then
    # Sign nested bundles before the outer one; --deep is deprecated and does
    # not apply entitlements correctly.
    for b in "$APP/Contents/MacOS"/*.bundle "$APP/Contents/Resources"/*.bundle; do
        [ -e "$b" ] || continue
        sign $COMMON --sign "$SIGN_ID" "$b"
    done

    # Sparkle contains its own nested code: two XPC services, a helper binary
    # and an updater app. Every one needs its own signature with the hardened
    # runtime or notarization rejects the bundle, and they must be signed
    # inside-out because signing a container seals whatever it holds.
    #
    # They deliberately do NOT get $COMMON: that carries Listen's entitlements
    # and bundle identifier. Granting the microphone to Sparkle's downloader
    # would be wrong, and forcing Listen's identifier onto four other binaries
    # produces four bundles claiming to be Listen.
    SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPARKLE_FW" ]; then
        NESTED="--force --timestamp --options runtime"
        for inner in \
            "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc" \
            "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc" \
            "$SPARKLE_FW/Versions/B/Autoupdate" \
            "$SPARKLE_FW/Versions/B/Updater.app"
        do
            [ -e "$inner" ] || continue
            sign $NESTED --sign "$SIGN_ID" "$inner"
        done
        sign $NESTED --sign "$SIGN_ID" "$SPARKLE_FW"
    fi

    sign $COMMON --sign "$SIGN_ID" "$APP"
else
    echo "warning: no signing certificate found, falling back to ad-hoc." >&2
    echo "         Microphone and audio capture must be re-granted after every" >&2
    echo "         rebuild, and other Macs will refuse to run this build." >&2
    echo "         Fix: Xcode > Settings > Accounts, add an Apple ID." >&2
    sign --force --deep --sign - --identifier com.mgo.listen "$APP"
fi

echo "version:     $VERSION (build $BUILD)"
codesign -dv "$APP" 2>&1 | grep -E "Authority=" | head -1 || true
# The leading "# " that older codesign printed is gone in current releases, so
# match both. This line is how CLAUDE.md tells you to check the requirement is
# identity-based rather than a cdhash, and matching only "# " silently printed
# nothing.
echo "requirement: $(codesign -d -r- "$APP" 2>&1 \
    | sed -n 's/^#* *designated => //p')"
echo "built: $APP"
