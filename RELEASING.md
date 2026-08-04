# Releasing Listen

`release.sh` is the only thing that publishes, and CI calls the same script, so
a local release and a CI release cannot come apart.

```sh
./release.sh                  # build and package into dist/, publish nothing
./release.sh --publish        # also tag, create the GitHub release, upload
./release.sh --resume <id>    # reuse a notarization submission already accepted
```

## Cutting a release

```sh
echo 1.0.1 > VERSION
git commit -am "1.0.1"
git tag v1.0.1
git push && git push --tags
```

The tag triggers `.github/workflows/release.yml`. The tag has to agree with
`VERSION`: a release named v1.0.1 containing `Listen-1.0.0.dmg` is worse than a
failed build, so `release.sh` checks and refuses.

## One-time setup

### 1. A Developer ID certificate

From the Apple Developer Program. Without one `make_app.sh` falls back to
ad-hoc signing, and ad-hoc signing pins the designated requirement to a
`cdhash`, so every rebuild silently invalidates the microphone permission while
System Settings still shows the toggle on. Verify:

```sh
codesign -d -r- /Applications/Listen.app      # must not contain cdhash
```

### 2. notarytool credentials

```sh
xcrun notarytool store-credentials listen-notary \
    --apple-id you@example.com --team-id TEAMID \
    --password <app-specific-password>
```

App-specific passwords come from appleid.apple.com, not your Apple ID password.

### 3. A Sparkle keypair

**Listen does not have one yet.** Until it does, `make_app.sh` omits
`SUFeedURL` and `SUPublicEDKey` entirely, so Sparkle refuses to update rather
than accepting anything. That is the safe failure and it is deliberate: a
placeholder key would be an arbitrary-code-execution channel.

```sh
./.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

It writes the private key into the login keychain and prints the public key.
Put the public key in `make_app.sh`'s `SPARKLE_PUBLIC_KEY` default, and export
it when releasing.

**Back the private key up before you ship anything with it.**

```sh
./.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
# store it in a password manager, then:
rm sparkle-private-key.txt
```

Losing it ends the update channel for every installed copy. Installed apps only
accept updates signed by the key they shipped with, so a new key means every
existing user has to reinstall by hand. There is no recovery.

### 4. Repository secrets, for CI

| Secret | What |
|---|---|
| `SIGNING_CERTIFICATE_P12` | base64 of a Developer ID Application `.p12` |
| `SIGNING_CERTIFICATE_PWD` | the password used when exporting it |
| `NOTARY_APPLE_ID` | Apple ID email |
| `NOTARY_TEAM_ID` | 10-character team identifier |
| `NOTARY_PASSWORD` | app-specific password |
| `SPARKLE_PRIVATE_KEY` | the EdDSA private key, for signing the appcast |

Without them the build still runs and produces artifacts, unsigned and
unpublished, so a fork can build with no setup at all.

## Things the process depends on

### VERSION is the only place the version is written

`CFBundleVersion` is derived from `git rev-list --count HEAD`, so it always
increases without anyone maintaining it. **Sparkle compares `CFBundleVersion`**
to decide whether an update exists, so anything that makes it go backwards
strands every installed copy: they will never see another update.

### Notarization is not a synchronous step

Submit and wait are separate calls rather than `notarytool submit --wait`.
Apple's queue has taken over an hour on a first submission, and a dropped
connection during the wait kills the run with the submission already accepted
server-side. Splitting them means a lost connection costs a retry of the wait,
not of the upload, and `--resume <id>` picks up an accepted submission.

`--resume` deliberately does not rebuild. A notarization ticket is keyed to the
`cdhash` of the exact bundle that was submitted, so rebuilding produces a
different hash and stapling fails. `release.sh` records the submitted hash in
`.notarization` and refuses early if the bundle on disk has changed, because
otherwise this surfaces as "Record not found" from stapler after the wait,
which reads like an Apple fault rather than a local one.

### The DMG needs its own ticket

Stapling the app makes the app pass Gatekeeper once it is in `/Applications`,
but the DMG is what people download and it is what Gatekeeper evaluates when
they open it. A DMG containing a notarized app is still itself "Unnotarized
Developer ID" and produces exactly the dialog notarizing was meant to remove.
So the DMG is signed, notarized and stapled separately, and the checksums are
taken after that, because stapling rewrites the file.

### Sparkle's nested code is signed inside-out

`Sparkle.framework` contains two XPC services, a helper binary and an updater
app. Each needs its own signature with the hardened runtime, signed before the
framework, which is signed before the app: sealing a container fixes whatever
it holds.

They must not receive Listen's entitlements or bundle identifier. That would
grant the microphone to Sparkle's downloader and produce four bundles claiming
to be `com.mgo.listen`.

The framework is copied with `ditto`, not `cp -R`: a framework's version
symlinks get flattened by `cp` and the result fails
`codesign --verify --deep --strict`.

### Packaging uses ditto, not zip

`ditto -c -k --keepParent` preserves the signature and resource forks that a
plain `zip` mangles, and a mangled archive is an invalid signature on the other
end.

### The release is drafted before it is uploaded

Draft, upload, then publish. A failed upload halfway through would otherwise
leave a public release advertising files it does not have, and Sparkle clients
would see a feed pointing at a missing archive.

`release.sh` also refuses to publish anything Gatekeeper rejects. Shipping a
build macOS will not open is never what anyone meant.

## Homebrew

```sh
gh workflow run homebrew-tap.yml -f tag=v1.0.1
```

The cask pins a sha256 against the versioned filename, which only means
anything while that URL is immutable. That is why both `Listen-1.0.1.dmg` and
an unversioned `Listen.dmg` are published: the unversioned one makes
`/releases/latest/download/Listen.dmg` a working direct download, and the
versioned one stays put for the cask to pin.
