# Releasing Listen

`release.sh` is the only thing that publishes, and CI calls the same script, so
a local release and a CI release cannot come apart.

```sh
./release.sh                  # build and package into dist/, publish nothing
./release.sh --publish        # also tag, create the GitHub release, upload
./release.sh --resume <id>    # reuse a notarization submission already accepted
```

## Cutting a release

`/release` is the shortcut, and it does all of the below: commits and pushes
what is outstanding, bumps `VERSION`, writes the changelog entry, asks once,
then publishes and dispatches the cask. It lives in
`.claude/skills/release/SKILL.md`. By hand:

```sh
$EDITOR CHANGELOG.md          # a '## 1.0.1 (2026-08-12)' section on top
echo 1.0.1 > VERSION
git commit -am "1.0.1"
git push
./release.sh --publish        # tags, pushes the tag, builds, notarizes, uploads
gh workflow run homebrew-tap.yml -f tag=v1.0.1
```

Do not tag by hand. `release.sh` tags and pushes the tag itself, and a tag that
disagrees with `VERSION` ships a release named v1.0.1 containing
`Listen-1.0.0.dmg`, which is worse than a failed build. It checks and refuses.

Pushing the tag does not start CI. `.github/workflows/release.yml` is
dispatch-only, deliberately: a local release would otherwise start a job that
builds for ten minutes, finds no signing secrets and mails a failure for a
release that actually succeeded.

## The changelog is the only place release notes are written

`CHANGELOG.md`, newest section first, each starting `##` followed by a version
number. `release.sh` extracts the top section and uses it twice: as the GitHub
release body, and as the description embedded in the appcast, which is the
"what's new" pane Sparkle shows before an update. There is no second file to
keep in agreement, which is the same argument as `sparkle.conf` holding the
account name and the public key together.

Three things it refuses in preflight, before a ten-minute build rather than
after it: no `CHANGELOG.md`, a top section whose version is not `VERSION`, and
a top section that is empty. The middle one is the one that matters. A
changelog left at the previous version publishes the previous release's notes
under this one's name, and nothing anywhere reports it: the release page reads
perfectly well, it just describes a different build.

A section ends at the next heading that is `##` followed by a version number,
rather than at the next `##` of any kind, so an entry can use its own
sub-headings. 0.1.0's notes have three, and a parser keyed on heading level
would have published its first paragraph and dropped the rest.

### Sparkle needs the notes embedded, not linked

`generate_appcast` embeds a release-notes file only when it is HTML. Given the
`.md` the changelog produces, it emits a `<sparkle:releaseNotesLink>` instead.
Measured: without `--embed-release-notes` the feed pointed at
`releases/latest/download/Listen-0.1.0.md`, a file no release uploads, so every
updater would have fetched a 404 into the pane. With the flag it becomes
`<description sparkle:format="markdown">` inside the feed, and there is no
second file to keep published.

0.1.0's feed shipped with no description at all, so the only thing an updater
was given to decide on was a version number.

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

**Done.** The public half is in `sparkle.conf` and ends up in `Info.plist` as
`SUPublicEDKey`; the private half is in the login keychain under the account
`listen`. Nothing below needs doing again on this machine. It is written down
because it has to be redone on a new one, and because the account name is the
part that bites.

```sh
.xcbuild/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account listen
```

`--account listen` is not optional. Without it the key goes into the default
`ed25519` account, which already holds **Speak's** key, and the two apps then
share an update-signing key: one leak would be an arbitrary-code-execution
channel into both. Every other Sparkle tool defaults to that same account, so
`release.sh` passes `--account` when it signs, and checks the two halves agree
before it builds. See CLAUDE.md for what the unchecked version looks like.

**The private key must be backed up.** Losing it ends the update channel for
every installed copy: an installed app only accepts updates signed by the key
it shipped with, so a new key means every existing user reinstalls by hand.
There is no recovery.

```sh
.xcbuild/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
    --account listen -x sparkle_private_key.txt
# store the contents in a password manager, then:
rm sparkle_private_key.txt
```

`sparkle_private_key.txt` is gitignored, which is a backstop and not a plan.
Delete it once it is in the password manager.

### 4. Repository secrets, for CI

| Secret | What | Set |
|---|---|---|
| `SIGNING_CERTIFICATE_P12` | base64 of a Developer ID Application `.p12` | no |
| `SIGNING_CERTIFICATE_PWD` | the password used when exporting it | no |
| `NOTARY_APPLE_ID` | Apple ID email | no |
| `NOTARY_TEAM_ID` | 10-character team identifier | no |
| `NOTARY_PASSWORD` | app-specific password | no |
| `SPARKLE_PRIVATE_KEY` | the EdDSA private key, for signing the appcast | yes |
| `HOMEBREW_TAP_TOKEN` | fine-grained PAT, contents and pull-requests write on the tap | no |

```sh
gh secret set SPARKLE_PRIVATE_KEY --repo mugoosse/listen < sparkle_private_key.txt
```

`HOMEBREW_TAP_TOKEN` is the one the cask step needs, and the default
`GITHUB_TOKEN` cannot stand in for it because it cannot reach another
repository. It is not set, so `homebrew-tap.yml` fails on its first step by
design rather than half-updating the tap. Until it is, the cask is two lines
edited by hand; see Homebrew at the end of this file.

Without them the build still runs and produces artifacts, unsigned and
unpublished, so a fork can build with no setup at all.

### 5. A public repository, before the first release and not after

`mugoosse/listen` is private. Everything above works while it is, and a release
published from it does not: `releases/latest/download/appcast.xml` and every
asset URL answer 404 to anyone not signed in, which is every Sparkle client and
the Homebrew cask both.

The order matters. Making the repository public after a release has already
gone out is fine. Publishing a release while it is private ships an update
channel that fails for reasons no user can see, and the app cannot be told
about it afterwards: the feed URL is baked into every bundle already
installed.

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

The cask is `Casks/listen.rb` in `mugoosse/homebrew-tap`. Two lines change per
release, the version and the sha256 of the versioned DMG, which `release.sh`
has already written into `dist/SHA256SUMS.txt`.

```sh
gh workflow run homebrew-tap.yml -f tag=v1.0.1
```

**That dispatch fails today**, and it is worth knowing why before reading the
run log. It needs `HOMEBREW_TAP_TOKEN`, which is not set, so it exits on its
first step. Nothing is half-written when it does. Until the secret exists, bump
the cask by hand in a clone of the tap:

```sh
grep Listen-1.0.1.dmg dist/SHA256SUMS.txt        # the hash to paste
$EDITOR Casks/listen.rb                          # version and sha256
git commit -am "listen 1.0.1" && git push
```

The workflow only ever rewrites those two lines with `sed`, deliberately: the
caveats and the zap stanza are hand-written and not derivable from a release,
so regenerating the file would lose them. The consequence is that it cannot
create the cask, only update one, which is why `Casks/listen.rb` had to be
written by hand once before any of this could run.

The cask pins a sha256 against the versioned filename, which only means
anything while that URL is immutable. That is why both `Listen-1.0.1.dmg` and
an unversioned `Listen.dmg` are published: the unversioned one makes
`/releases/latest/download/Listen.dmg` a working direct download, and the
versioned one stays put for the cask to pin.

### The recordings survive `--zap`

`zap trash:` lists the preferences and the caches and stops there.
`~/Library/Application Support/Listen` holds the meetings, `--zap` is a flag
people pass without reading it, and the two errors do not cost the same:
preferences regenerate, an hour of somebody's meetings does not. The caveats
say where they are and how to remove them, so it stays a choice somebody makes.
The model cache is left alone for the reason Speak leaves it alone, that
removing it would take Speak's copy too.
