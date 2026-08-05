#!/bin/sh
# Build, sign, notarize, package and publish a release.
#
#   ./release.sh                 build and package into dist/, no publishing
#   ./release.sh --publish       also create the GitHub release and upload
#   ./release.sh --resume <id>   reuse an existing notarization submission
#
# Notarization runs only when a Developer ID certificate and stored notarytool
# credentials are both present. Without them the artifacts are still produced,
# just with a warning: users will meet Gatekeeper on first launch, and
# --publish refuses to ship them.
#
# One-time notarytool setup (needs the paid Apple Developer Program):
#   xcrun notarytool store-credentials listen-notary \
#       --apple-id you@example.com --team-id TEAMID \
#       --password <app-specific-password>
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$ROOT/Listen.app"
VERSION=$(tr -d ' \n' < "$ROOT/VERSION")
KEYCHAIN_PROFILE="${LISTEN_NOTARY_PROFILE:-listen-notary}"
# SPARKLE_PUBLIC_KEY and SPARKLE_ACCOUNT, the same file make_app.sh reads.
. "$ROOT/sparkle.conf"
PUBLISH=0
RESUME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --publish) PUBLISH=1 ;;
        --resume)  RESUME="$2"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

ZIP="$DIST/Listen-$VERSION.zip"
DMG="$DIST/Listen-$VERSION.dmg"
# A byte-identical copy under a name that never changes, so that
# /releases/latest/download/Listen.dmg is a working direct download.
#
# GitHub's latest/download/ redirect resolves the filename literally, so a
# versioned name cannot be linked to without going stale on the next release.
# That is why the feed is called appcast.xml and not appcast-1.0.2.xml, and
# this buys the download button on the README and the website the same
# property. The versioned name stays: the cask pins a sha256 against it, and
# that only means anything while the URL is immutable.
LATEST_DMG="$DIST/Listen.dmg"
SUMS="$DIST/SHA256SUMS.txt"
APPCAST="$DIST/appcast.xml"
TAG="v$VERSION"
# Which bundle each notarization submission belongs to. Outside dist/, which
# is wiped on every run, and gitignored.
STATE="$ROOT/.notarization"
CHANGELOG="$ROOT/CHANGELOG.md"
# The top section of the changelog, extracted below. One file is the source for
# both the GitHub release body and the pane Sparkle shows before an update, so
# the two cannot describe the same version differently.
NOTES="$DIST/release-notes.md"

# A section runs from a heading that is `##` followed by a version number to
# the next one. Keyed on the version rather than on the heading level, because
# an entry's own sub-headings are `##` in the release body people read, and a
# parser that stopped at those would silently publish the first paragraph and
# drop the rest.
changelog_body() {
    awk '
        /^## [0-9]+\.[0-9]+\.[0-9]+/ { if (seen) exit; seen = 1; next }
        seen && !body && /^[[:space:]]*$/ { next }
        seen { body = 1; print }
    ' "$CHANGELOG"
}

# The version the top section claims, from `## 0.2.0 (2026-08-12)`.
changelog_version() {
    awk '/^## [0-9]+\.[0-9]+\.[0-9]+/ {
        sub(/^##[[:space:]]+/, ""); sub(/[[:space:](].*$/, ""); print; exit
    }' "$CHANGELOG"
}

# --- preflight -------------------------------------------------------------
#
# Everything here is cheap and fails before a ten-minute build rather than
# after it.

if [ "$PUBLISH" -eq 1 ]; then
    # In CI the tag is what triggered the run, and VERSION is whatever the
    # tagged commit happens to contain. Tag v1.0.1 on a commit that still says
    # 1.0.0 and the release is named v1.0.1 while every artifact inside it is
    # 1.0.0. This is the check that makes that impossible.
    if [ -n "${GITHUB_REF_NAME:-}" ] && [ "$GITHUB_REF_NAME" != "$TAG" ]; then
        echo "error: triggered by tag $GITHUB_REF_NAME but VERSION says $VERSION." >&2
        echo "       Expected tag $TAG. Fix VERSION and retag." >&2
        exit 1
    fi

    # A tag that disagrees with VERSION ships artifacts named after one version
    # under a release named after another, and the app then reports a version
    # nobody can find. Catch it before anything is built.
    if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
        TAGGED=$(git -C "$ROOT" show "$TAG:VERSION" 2>/dev/null | tr -d ' \n')
        if [ -n "$TAGGED" ] && [ "$TAGGED" != "$VERSION" ]; then
            echo "error: tag $TAG has VERSION=$TAGGED but VERSION says $VERSION." >&2
            echo "       Delete the tag or fix VERSION; they have to agree." >&2
            exit 1
        fi
    fi

    # A changelog whose top section was left at the previous version publishes
    # the previous release's notes under this one's name, and nothing anywhere
    # reports it: the release page reads perfectly well, it just describes a
    # different build, and so does the pane Sparkle puts in front of everyone
    # deciding whether to take the update. Same family as the tag check above,
    # and cheap for the same reason.
    if [ ! -f "$CHANGELOG" ]; then
        echo "error: no CHANGELOG.md, so the release would have no notes and" >&2
        echo "       Sparkle's update pane would be blank." >&2
        exit 1
    fi
    HEADING=$(changelog_version)
    if [ "$HEADING" != "$VERSION" ]; then
        echo "error: CHANGELOG.md opens on ${HEADING:-no version section} but" >&2
        echo "       VERSION says $VERSION. Add a '## $VERSION' section at the" >&2
        echo "       top; they have to agree." >&2
        exit 1
    fi
    if [ -z "$(changelog_body | tr -d '[:space:]')" ]; then
        echo "error: the $VERSION section of CHANGELOG.md is empty, so the" >&2
        echo "       release would ship a version number and no reason to take it." >&2
        exit 1
    fi

    if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
        echo "error: working tree is dirty. Commit before publishing," >&2
        echo "       otherwise the tag points at something you cannot rebuild." >&2
        exit 1
    fi

    # Without a public key in the bundle, Sparkle has nothing to verify an
    # update against and refuses every one of them. Publishing that way ships
    # an update channel that silently never works, and the only fix afterwards
    # is asking everyone to reinstall by hand. See RELEASING.md, Sparkle keys.
    if [ -z "${SPARKLE_PUBLIC_KEY:-}" ]; then
        echo "error: SPARKLE_PUBLIC_KEY is empty, so the app would ship with" >&2
        echo "       no update key and could never update itself." >&2
        echo "       Generate a keypair once (RELEASING.md), then put the" >&2
        echo "       public half in sparkle.conf." >&2
        exit 1
    fi

    # The private half that signs the appcast lives in the login keychain under
    # SPARKLE_ACCOUNT, and every Sparkle tool defaults to a different account.
    # Signing with the wrong key produces a perfectly well-formed feed that
    # every installed copy rejects, and nothing on this machine reports it: the
    # failure is only visible on a user's Mac, as an update that never arrives.
    # So compare the two halves before spending an hour on notarization.
    #
    # Skipped in CI, which has no keychain and reads the key from a file.
    if [ -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
        GENERATE_KEYS=$(find "$ROOT/.build/artifacts" \
            "$ROOT/.xcbuild/SourcePackages/artifacts" \
            -name generate_keys -type f 2>/dev/null | head -1)
        if [ -z "$GENERATE_KEYS" ]; then
            echo "error: generate_keys not found. Run ./build.sh first." >&2
            exit 1
        fi
        HAVE=$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null || true)
        if [ "$HAVE" != "$SPARKLE_PUBLIC_KEY" ]; then
            echo "error: the key in keychain account '$SPARKLE_ACCOUNT' is not the one" >&2
            echo "       sparkle.conf ships. The appcast would be signed with a key" >&2
            echo "       no installed copy accepts." >&2
            if [ -z "$HAVE" ]; then
                echo "       That account holds no key at all. See RELEASING.md." >&2
            fi
            exit 1
        fi
    fi
fi

# --- build -----------------------------------------------------------------

if [ -z "$RESUME" ]; then
    "$ROOT/build.sh" >/dev/null
    "$ROOT/make_app.sh"
else
    # A notarization ticket is keyed to the cdhash of the exact bundle that was
    # submitted. Rebuilding produces a different hash, so stapling would fail
    # and the resumed submission would be wasted. Reuse what is on disk.
    [ -d "$APP" ] || {
        echo "error: --resume needs the Listen.app that was submitted," >&2
        echo "       and there is none at $APP." >&2
        exit 1
    }

    # Not rebuilding is not enough: anything else that ran make_app.sh since
    # the submission has already replaced the bundle, and Apple's ticket is
    # keyed to the cdhash of the one it saw. Without this check that surfaces
    # as "Record not found" from stapler after the wait, which reads like an
    # Apple fault rather than a local one.
    NOW_HASH=$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')
    WAS_HASH=$(sed -n "s/^$RESUME //p" "$STATE" 2>/dev/null)
    if [ -n "$WAS_HASH" ] && [ "$NOW_HASH" != "$WAS_HASH" ]; then
        echo "error: $APP is not the bundle that was submitted." >&2
        echo "       submitted cdhash: $WAS_HASH" >&2
        echo "       on disk now:      $NOW_HASH" >&2
        echo "       Something rebuilt it since. The ticket cannot be" >&2
        echo "       stapled to a different binary, so this submission is" >&2
        echo "       spent. Run ./release.sh again to build and resubmit." >&2
        exit 1
    fi
    echo "reusing the existing bundle; rebuilding would invalidate the ticket"
fi

rm -rf "$DIST"
mkdir -p "$DIST"

# After the wipe, not before: dist/ is emptied on every run and would take the
# notes with it. Publishing has already refused above if this section is
# missing, so the warning is for a dry run, where no notes costs nothing.
if [ -f "$CHANGELOG" ] && [ "$(changelog_version)" = "$VERSION" ]; then
    changelog_body > "$NOTES"
else
    echo "warning: CHANGELOG.md has no $VERSION section at the top, so this" >&2
    echo "         build gets no release notes and no Sparkle description." >&2
fi

# --- notarize --------------------------------------------------------------
#
# Apple staples the ticket to the .app, so notarize before packaging and the
# ticket travels inside both the zip and the dmg.

HAS_DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -c "Developer ID Application" || true)
HAS_CREDS=0
xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
    && HAS_CREDS=1

# Submit a path and print the submission id. Submit and wait are separate
# calls: `submit --wait` polls over the network for as long as Apple's queue
# takes, and a single dropped packet kills the run with the submission already
# accepted server-side, which then has to be thrown away. Splitting them means
# a lost connection costs a retry of the wait, not of the upload.
submit_for_notarization() {
    xcrun notarytool submit "$1" --keychain-profile "$KEYCHAIN_PROFILE" \
        --output-format json | sed -n 's/.*"id":"\([^"]*\)".*/\1/p'
}

# Wait for a verdict, then staple the ticket to $2.
await_and_staple() {
    _id="$1"
    _path="$2"

    # Retry the wait rather than the upload. Apple's queue has taken over four
    # hours on a first submission from a new Developer ID account.
    _attempt=1
    until xcrun notarytool wait "$_id" \
        --keychain-profile "$KEYCHAIN_PROFILE" --timeout 30m; do
        _attempt=$((_attempt + 1))
        [ "$_attempt" -gt 3 ] && break
        echo "wait failed, retrying ($_attempt/3). Resume later with:" >&2
        echo "  ./release.sh --resume $_id" >&2
        sleep 30
    done

    _status=$(xcrun notarytool info "$_id" \
        --keychain-profile "$KEYCHAIN_PROFILE" --output-format json \
        | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
    if [ "$_status" != "Accepted" ]; then
        echo "error: notarization returned '$_status'." >&2
        echo "       Reasons:" >&2
        xcrun notarytool log "$_id" \
            --keychain-profile "$KEYCHAIN_PROFILE" 2>/dev/null >&2 || true
        exit 1
    fi

    if ! xcrun stapler staple "$_path"; then
        echo >&2
        echo "error: notarization succeeded but stapling failed." >&2
        echo "       Apple accepted the submission, so this is almost always" >&2
        echo "       a local mismatch: $_path is no longer what was submitted." >&2
        echo "       Run ./release.sh again to build and resubmit." >&2
        exit 1
    fi
}

NOTARIZED=0
if [ "$HAS_DEVID" -gt 0 ] && [ "$HAS_CREDS" -eq 1 ]; then
    if [ -n "$RESUME" ]; then
        echo "resuming notarization $RESUME…"
        SUBMISSION="$RESUME"
    else
        echo "notarizing the app…"
        # An .app cannot be uploaded directly; it goes as a zip whatever we
        # ship afterwards.
        SUBMIT="$DIST/submit.zip"
        ditto -c -k --keepParent "$APP" "$SUBMIT"
        SUBMISSION=$(submit_for_notarization "$SUBMIT")
        rm -f "$SUBMIT"
        [ -n "$SUBMISSION" ] || { echo "error: no submission id returned." >&2; exit 1; }
        # Remember which bundle this ticket will belong to, so --resume can
        # refuse early if the bundle has been replaced in the meantime.
        echo "$SUBMISSION $(codesign -dvvv "$APP" 2>&1 | sed -n 's/^CDHash=//p')" \
            >> "$STATE"
        echo "submission: $SUBMISSION"
    fi

    await_and_staple "$SUBMISSION" "$APP"
    NOTARIZED=1
    echo "stapled the app"
else
    echo "warning: skipping notarization." >&2
    [ "$HAS_DEVID" -eq 0 ] && \
        echo "         no Developer ID Application certificate found." >&2
    [ "$HAS_CREDS" -eq 0 ] && \
        echo "         no notarytool profile '$KEYCHAIN_PROFILE' stored." >&2
    echo "         Users will have to bypass Gatekeeper on first launch." >&2
fi

# --- package ---------------------------------------------------------------

# ditto, not zip: it preserves the signature and resource forks that a plain
# zip mangles, which invalidates the code signature.
ditto -c -k --keepParent "$APP" "$ZIP"

# A DMG with an Applications symlink is the drag-to-install window people
# expect. hdiutil builds it from a staging folder.
STAGE="$DIST/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Listen $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# The DMG is signed separately; the app inside already carries its own ticket.
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ -n "$SIGN_ID" ]; then
    codesign --force --sign "$SIGN_ID" --timestamp "$DMG" 2>/dev/null || true
fi

# The DMG needs its own ticket, not just the app inside it.
#
# Stapling the app makes the app pass Gatekeeper once it is in /Applications,
# but the DMG is what the user downloads, and it is what Gatekeeper evaluates
# when they open it. A DMG that only contains a notarized app is still itself
# "Unnotarized Developer ID" and produces a warning on first open, which is
# exactly the dialog notarizing was meant to remove.
#
# This has to happen after signing, and the checksums have to be taken after
# this, because stapling rewrites the file.
if [ "$NOTARIZED" -eq 1 ]; then
    echo "notarizing the dmg…"
    DMG_SUBMISSION=$(submit_for_notarization "$DMG")
    [ -n "$DMG_SUBMISSION" ] || { echo "error: no dmg submission id." >&2; exit 1; }
    echo "submission: $DMG_SUBMISSION"
    await_and_staple "$DMG_SUBMISSION" "$DMG"
    echo "stapled the dmg"
fi

# Copied only now, after stapling. The ticket is written into the file, so a
# copy taken any earlier would be an unstapled duplicate that shows the
# Gatekeeper warning notarizing exists to remove. Both names are checksummed
# below, so either download can be verified against SHA256SUMS.txt.
cp "$DMG" "$LATEST_DMG"

# --- appcast ---------------------------------------------------------------
#
# Sparkle reads this to decide whether an update exists. generate_appcast signs
# each entry with the private EdDSA key from the login keychain; without a
# valid signature Sparkle refuses the update, which is the whole security
# model. The zip is the update archive: Sparkle can install from a DMG, but a
# zip needs no mounting step.

GENERATE_APPCAST=$(find "$ROOT/.build/artifacts" "$ROOT/.xcbuild/SourcePackages/artifacts" \
    -name generate_appcast -type f 2>/dev/null | head -1)
if [ -n "$GENERATE_APPCAST" ]; then
    FEED="https://github.com/mugoosse/listen/releases/latest/download/appcast.xml"
    # generate_appcast works on a directory of archives and writes the feed
    # beside them, so give it one holding only this release's zip.
    ARCHIVES="$DIST/archives"
    mkdir -p "$ARCHIVES"
    cp "$ZIP" "$ARCHIVES/"
    # generate_appcast picks up a .md, .html or .txt file whose basename
    # matches an archive and embeds it as that item's description, which is the
    # "what's new" pane Sparkle shows before an update. Without one the pane is
    # empty: 0.1.0's feed shipped that way, so the only thing an updater was
    # given to decide on was a version number. The name has to track the zip's.
    if [ -f "$NOTES" ]; then
        cp "$NOTES" "$ARCHIVES/Listen-$VERSION.md"
    fi
    # Locally the private key comes from the login keychain, where
    # generate_keys put it, under Listen's own account rather than the default
    # one. Omitting --account does not fail: it signs with whatever the default
    # account holds, which on this machine is Speak's key, and produces a feed
    # no copy of Listen will accept. CI has no keychain to read, so it writes
    # the key to a file and points at it with SPARKLE_PRIVATE_KEY_FILE.
    if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
        KEYARG="--ed-key-file $SPARKLE_PRIVATE_KEY_FILE"
    else
        KEYARG="--account $SPARKLE_ACCOUNT"
    fi
    LOG="$DIST/appcast.log"
    # --embed-release-notes is not optional. By default generate_appcast embeds
    # a notes file only when it is HTML, and emits a <sparkle:releaseNotesLink>
    # for anything else. Measured: without the flag the feed pointed at
    # releases/latest/download/Listen-0.1.0.md, which no release uploads, so
    # every updater would have fetched a 404 into the pane. Embedded, it
    # becomes <description sparkle:format="markdown"> in the feed itself, and
    # there is no second file to keep published.
    #
    # shellcheck disable=SC2086
    if "$GENERATE_APPCAST" $KEYARG --download-url-prefix \
        "https://github.com/mugoosse/listen/releases/download/$TAG/" \
        --link "https://github.com/mugoosse/listen" \
        --embed-release-notes \
        --full-release-notes-url "https://github.com/mugoosse/listen/blob/main/CHANGELOG.md" \
        "$ARCHIVES" >"$LOG" 2>&1
    then
        mv "$ARCHIVES/appcast.xml" "$APPCAST"
        # generate_appcast writes a feed whether or not it managed to sign
        # anything, so the file existing is not evidence that it did. An entry
        # with no edSignature is one Sparkle refuses, which is an update
        # channel that looks published and never works.
        if grep -q 'edSignature=' "$APPCAST"; then
            echo "appcast: $(basename "$APPCAST") (feed $FEED)"
        else
            echo "error: the appcast carries no edSignature, so nothing signed" >&2
            echo "       it and every client would refuse the update." >&2
            if [ "$PUBLISH" -eq 1 ]; then exit 1; fi
        fi
    else
        echo "error: generate_appcast failed. Updates would not be offered." >&2
        sed 's/^/       /' "$LOG" >&2
        if [ "$PUBLISH" -eq 1 ]; then exit 1; fi
    fi
    rm -rf "$ARCHIVES" "$LOG"
else
    echo "warning: generate_appcast not found. Run: swift package resolve" >&2
fi

# --- checksums -------------------------------------------------------------
#
# Published as an asset, not just printed, so anyone can verify a download
# without trusting the terminal output of whoever cut the release.

( cd "$DIST" && shasum -a 256 ./*.zip ./*.dmg | sed 's| \./| |' > "$SUMS" )

echo
echo "artifacts:"
ls -lh "$DIST" | awk 'NR>1 {printf "  %-28s %s\n", $9, $5}'
echo
echo "sha256:"
sed 's/^/  /' "$SUMS"

# --- verify ----------------------------------------------------------------

# Check the DMG, not just the app. The app passing says nothing about what
# happens when someone opens the download: the app was passing while the DMG
# around it was still rejected, and the DMG is the artifact people receive.
GATEKEEPER_OK=1

printf "\ngatekeeper, app: "
if spctl -a -vvv -t exec "$APP" 2>&1 | grep -q "accepted"; then
    echo "accepted"
else
    echo "REJECTED"
    GATEKEEPER_OK=0
fi

printf "gatekeeper, dmg: "
if spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 \
    | grep -q "accepted"; then
    echo "accepted (opens with no warning)"
else
    echo "REJECTED (users get a Gatekeeper dialog on open)"
    GATEKEEPER_OK=0
fi

# --- publish ---------------------------------------------------------------

if [ "$PUBLISH" -eq 1 ]; then
    # Shipping a build macOS refuses to open is never what anyone meant, and
    # the old script printed REJECTED and then published anyway.
    if [ "$GATEKEEPER_OK" -eq 0 ] || [ "$NOTARIZED" -eq 0 ]; then
        echo >&2
        echo "error: refusing to publish a release Gatekeeper would block." >&2
        echo "       Artifacts are in dist/ if you want them anyway." >&2
        exit 1
    fi

    echo
    echo "publishing $TAG…"
    git -C "$ROOT" tag -a "$TAG" -m "Listen $VERSION" 2>/dev/null || echo "  tag exists, reusing"
    git -C "$ROOT" push origin "$TAG" 2>/dev/null || true

    # Draft first, upload, then publish. A failed upload halfway through
    # otherwise leaves a public release that advertises files it does not have,
    # and Sparkle clients would see a feed pointing at a missing archive.
    if ! gh release view "$TAG" >/dev/null 2>&1; then
        gh release create "$TAG" --draft --verify-tag \
            --title "Listen $VERSION" \
            --notes-file "$NOTES" --generate-notes
    fi
    gh release upload "$TAG" "$ZIP" "$DMG" "$LATEST_DMG" "$SUMS" \
        $([ -f "$APPCAST" ] && echo "$APPCAST") --clobber
    gh release edit "$TAG" --draft=false

    echo "released: $(gh repo view --json url -q .url)/releases/tag/$TAG"
    echo
    echo "next: update the Homebrew cask."
    echo "  gh workflow run homebrew-tap.yml -f tag=$TAG"
fi
