# Signing, Sparkle and releasing

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments explain why, thresholds say where the number came from, and no em dashes. -->

Read this before touching `make_app.sh`, `release.sh`, `sparkle.conf` or `CHANGELOG.md`.

## Signing decides whether permissions survive a rebuild

Straight from Speak, and it matters more here. Ad-hoc signing gives a
designated requirement of `cdhash H"…"`, pinned to one build, so **every
rebuild silently invalidates the permission** while System Settings still shows
the toggle on. On an app that records hour-long meetings, that failure is
expensive. `make_app.sh` signs with a real certificate when one exists.

```sh
codesign -d -r- /Applications/Listen.app     # must not contain cdhash
```

## Sparkle's key is not in the default keychain account

Listen has its own keypair, deliberately not Speak's. Sparkle's own tool says
you only need one key however many apps you ship, and for a single publisher
that is reasonable advice, but one leaked key would then be an
arbitrary-code-execution channel into both apps at once. Two keys, two backups.

The cost of that choice is that **every Sparkle tool defaults to the `ed25519`
keychain account, and on this machine that account holds Speak's key.** A
`generate_appcast` run without `--account listen` does not fail. It signs, it
writes a well-formed feed, `--publish` uploads it, and every installed copy of
Listen then rejects the update because the signature does not match the
`SUPublicEDKey` in its own bundle. Nothing on the release machine reports any
of this; the only symptom is an update that never arrives, on somebody else's
Mac.

So the account name and the public key live together in `sparkle.conf`, sourced
by both `make_app.sh` (which bakes `SUPublicEDKey` into `Info.plist`) and
`release.sh` (which signs the feed). Two readers, one definition, no way for
them to disagree. `release.sh` also compares
`generate_keys --account "$SPARKLE_ACCOUNT" -p` against the shipped public key
before it builds anything, because the alternative is discovering the mismatch
an hour later in someone's release notes.

Measured, on the 0.1.0 bundle: `sign_update --verify --account listen` accepts
the generated signature, and `--account ed25519` rejects it. The flag is
load-bearing rather than decorative.

An empty `SPARKLE_PUBLIC_KEY` still omits `SUFeedURL` and `SUPublicEDKey`
altogether, which makes Sparkle refuse every update rather than accept one.
That is the escape hatch for a fork, which must not ship a build that trusts
Listen's key. Shipping a placeholder key would be the dangerous option.

The framework is still linked, embedded and signed from milestone 0 so that the
rpath and the inside-out nested signing are exercised from the start. Both are
things you want to discover early, not during a release.

## How fast a new version is noticed is four settings, and three of them are defaults

All four are written by `make_app.sh` into `Info.plist`, and they are worth
reading together because each one is a different way for a copy to sit stale.

**`SUScheduledCheckInterval` is six hours, and was two days.** The comment
behind the old number said Sparkle's default of one day "is more attention than
this deserves", which conflated how often Listen asks GitHub with how often it
interrupts anybody. A scheduled check that finds nothing shows no UI at all, so
the interval costs the user nothing and is only a floor on staleness. Measured
against what actually ships: 0.17.0, 0.18.0 and 0.18.1 all published on
2026-08-24, and 0.14.0 to 0.18.1 spanned twelve days, so a two-day floor left a
typical copy one to three versions behind.

**`SUEnableAutomaticChecks` is now set, so Sparkle's permission prompt never
appears.** Without the key Sparkle asks each user for permission and stores the
answer per-user. The important half is what happens to somebody who declines:
`SPUUpdater.m` suppresses the prompt whenever `boolNumberForKey:` is non-nil,
so a stored `NO` means that copy never checks again and never says so, and the
only way back is a checkbox in a settings pane nobody opens unless they already
suspect they are stale. Unbounded staleness, and largely still invisible from here: the update check
itself is a GET of a signed feed that sends no profile information, so there
was nothing in it that needed consent, and opt-in telemetry (`Telemetry.swift`)
only ever hears from an install that said yes, which a copy stuck on a
suppressed prompt has no more reason to have done than before.

**`SUAutomaticallyUpdate` is now set, so a found update installs on the next
quit** instead of waiting behind a dialog somebody has to notice and click.

**Both of those are defaults rather than decisions, and that was verified in
Sparkle's source rather than assumed.** `SUHost.boolNumberForKey:` reads user
defaults first and falls back to the info dictionary, so the checkboxes in the
Updates pane still win. The corollary is the awkward one: anyone running a build
from before these keys existed answered the first-run prompt instead, and
`updatePermissionRequestFinishedWithResponse:` wrote their answer into user
defaults, where it keeps beating the new default forever. For them the pane is
the only way in, which is why "Install updates automatically" is now a control
there rather than only a plist key.

**A launch used to also ask quietly, and that quiet ask was what stopped every
automatic install.** `Updater.checkQuietly` called `checkForUpdateInformation()`
on every launch, to put the badge on the gear without waiting for the scheduler.
It is gone, and the paragraph below is why.

## The launch probe was what stopped the automatic install

The report was that "Install updates automatically" was ticked, the gear had a
dot on it, and no version ever arrived. All three were true at once, and the
probe is what joined them. Read out of Sparkle 2.9.5's own source, three
separate mechanisms and each one alone is enough:

1. `checkForUpdateInformation` sets `sessionInProgress` **synchronously**.
   `startUpdater:` schedules its real work with a `dispatch_async` one runloop
   turn later, and that block reads `if (!self->_sessionInProgress) {
   [self startUpdateCycle]; }`. So the probe, called in
   `applicationDidFinishLaunching`, was always in flight by the time the check
   ran, and `startUpdateCycle` never ran at all. That is the branch holding
   "we're overdue, run one now", which is the only launch path that can
   download anything.
2. `checkForUpdatesWithDriver:` calls `updateLastUpdateCheckDate` before it does
   anything else, so the probe stamped `SULastCheckTime` with now on every
   launch, however recently a real check had run.
3. `SPUProbingUpdateDriver` aborts with `abortUpdateAndShowNextUpdateImmediately:NO`
   the moment it has an answer, and the completion handler then calls
   `scheduleNextUpdateCheckFiringImmediately:NO usingCurrentDate:NO`. The `NO`
   is the expensive one: `intervalSinceCheck` is taken as zero, so the next real
   check is a **full interval after the launch** rather than where it was due.

A probe downloads nothing. It is `SPUProbingUpdateDriver`, not
`SPUAutomaticUpdateDriver`, and the automatic driver is only ever reached
through `_checkForUpdatesInBackground`. So the whole launch did exactly one
useful thing, put the dot on the gear, and paid for it by pushing the only
check that could act six hours into the future, from a timer that does not
survive a quit. **A copy launched more often than every six hours therefore
never installed anything, ever**, and the dot on the gear was the only evidence
it left.

Measured on 0.19.0, both builds against the same seeded preference:

```sh
defaults write com.mgo.listen SULastCheckTime -date "$(date -u '+%Y-%m-%d %H:%M:%S +0000')"
# launch, wait, read it back
```

| build | seeded | after launch |
|---|---|---|
| 242, with the probe | 15:28:09 | 15:28:11 |
| 243, without it | 15:27:17 | 15:27:17 |

Two seconds later on the old one, from a check it had no reason to run. The fix
is to call nothing at launch: Sparkle's own cycle starts one runloop turn in,
and when the last check is older than `SUScheduledCheckInterval` that cycle is a
real background check, which downloads and stages with automatic installing on
and puts Sparkle's own window up with it off. Both are what the Updates pane
promises. The interval being a floor is fine; it is a floor at six hours.

## The dot is restored from disk, and never from the network

Deleting the probe left one real gap behind, which is the thing it was written
for: `Outcome` lives in the process and starts at `.unknown`, so a relaunch
forgot that an update existed and the gear lost its dot until the next scheduled
check.

`Updater.remember`/`recall` keep the found version in `updatePendingVersion`, so
the answer is on screen before the window has finished opening and no request
goes out to get it. It is compared against `AppInfo.version` on the way back in
rather than trusted, because the obvious way for that key to be stale is the
update having been installed since it was written, and an app claiming a version
is available when you are already running it is worse than one saying nothing.

It comes back as `.available` even when the copy really was staged, because the
block that installs it does not survive a relaunch: claiming a button exists
that does not is the one lie available here.

## Install on quit is a promise an app you never quit cannot keep

`SUAutomaticallyUpdate` means "downloaded in the background, put in place on the
next quit". Listen opens at login and watches for meetings, so on a Mac that is
only ever put to sleep that next quit can be weeks away, and nothing anywhere
said a version was sitting on disk waiting for it.

`SPUUpdaterDelegate.updater:willInstallUpdateOnQuit:immediateInstallationBlock:`
is the only place Sparkle hands out a handle that installs on demand. Answering
`true` claims it, which is what the Install and Relaunch button in the Updates
pane presses, and the header states the half that makes that safe: "in either
case Sparkle will always attempt to install the update when the app terminates".
Quitting still behaves exactly as it did.

The stated cost of answering `true` is that it stalls the update cycle, so no
further checks run until this one is applied. That is the right trade, because
there is nothing a later check could find that this copy could act on without
first installing what it already has, and `canCheckForUpdates` going false is
what greys out Check Now while a version waits.

**The button asks about recording and transcription first, because a relaunch
destroys both.** `Updater.installNowBlocker` refuses while `Capture.isRecording`
or `Queue.isBusy`, and says which, in the note under the button. An hour of
meeting that has not been written out and a transcription job that would restart
from the top are the two things in this app that a quit cannot be taken back on.

**Optional protocol methods fail silently, so the selector was checked in the
binary rather than in the diff.** `SPUUpdaterDelegate` is an ObjC protocol and
every method on it is optional: a Swift signature that does not match the
imported declaration is not `@objc`, is not a witness, compiles clean, and is
simply never called. There is no warning anywhere. The test is one line:

```sh
strings -a Listen.app/Contents/MacOS/Listen | grep willInstallUpdateOnQuit
# updater:willInstallUpdateOnQuit:immediateInstallationBlock:
```

## `LISTEN_UPDATE_READY`, because publishing a release is not a test

The staged state cannot be reached without a signed release newer than the one
you are running, which means a publish, so without a seam the Install button and
the second gear tooltip would ship having never been on screen. Same family as
`LISTEN_OFFLINE`, and the same argument.

```sh
LISTEN_UPDATE_READY=0.99.0 LISTEN_LIBRARY=/tmp/scratch ./Listen.app/Contents/MacOS/Listen
```

The install block prints `[Listen] would install 0.99.0` to stderr instead of
relaunching, which is the one part a fake cannot do. Nothing is persisted while
it is set: without that guard a single test run would leave a permanent dot on a
real copy, pointing at a version that does not exist.

## The badged control has to answer its own badge

The gear is the only badged control in the library window, and it opened on
whichever settings section was last read. So the one press that the badge itself
prompted was the one press that did not go where the badge pointed, and somebody
who had last been in General went to General to find out about an update.

`LibraryWindow.openSettings` passes `.updates` while `Updater.isPending`. The nil
default still holds for Cmd-, and for the menu bar's Settings item, which carry
no dot and so make no promise about what they are for.

The tooltip distinguishes the two states the dot covers, because one of them is
a version you could be running in ten seconds and the other is a download that
has not started.

## The changelog is the only place release notes are written

`CHANGELOG.md`, newest first, each section starting `##` followed by a version
number. `release.sh` extracts the top section and uses it twice: the GitHub
release body, and the description embedded in the appcast, which is the pane
Sparkle shows before an update. Same argument as `sparkle.conf` holding the
account name and the public key together, and there was a `RELEASE_NOTES.md`
holding a copy until there wasn't.

Preflight refuses a top section that is missing, empty, or not `VERSION`. The
last is the one that matters: a changelog left at the previous version
publishes the previous release's notes under this one's name, and nothing
anywhere reports it, because the release page reads perfectly well. It just
describes a different build.

A section ends at the next heading that is `##` **followed by a version
number**, not at the next `##` of any kind. 0.1.0's notes carry three
sub-headings of their own, so a parser keyed on heading level would have
published the first paragraph and silently dropped the rest.

### Sparkle needs the notes embedded, not linked

`generate_appcast` embeds a notes file only when it is HTML, and emits a
`<sparkle:releaseNotesLink>` for anything else, including the `.md` the
changelog produces. Measured: without `--embed-release-notes` the feed pointed
at `releases/latest/download/Listen-0.1.0.md`, a file no release uploads, so
every updater would have fetched a 404 into the pane. With the flag it is
`<description sparkle:format="markdown">` inside the feed, and there is no
second file to keep published.

0.1.0's feed shipped with no description at all, so the only thing an updater
was given to decide on was a version number.

## The notes are in the app now, and they stop at the version you have

Until this window existed, nothing inside Listen could show a changelog. The
notes reached a user through exactly one surface, the pane Sparkle draws in
front of an update, and that pane is dismissed and gone. `SUAutomaticallyUpdate`
makes that worse rather than better: the default path is now a version arriving
on the next quit with its notes never having been on screen at all, so the more
reliably Listen updates itself the less anybody sees what it changed. Settings
could say "up to date" and About could say `0.18.2`, and neither could say what
0.18.2 was.

`Changelog` parses the file, `ChangelogWindow` draws it, and `make_app.sh`
copies `CHANGELOG.md` into `Contents/Resources` so there is something to parse.
Three ways in, because three different questions land here: Help › Release
Notes for somebody looking for it by name, a button under the version number in
About, and one under the version line in Settings › Updates.

**The bundled copy stops at the build it shipped in, so it can never show notes
for a version nobody has installed.** That is the whole trade-off, and the
footer states it rather than leaving it to be discovered. Fetching the newest
changelog instead would put a request on the wire every time somebody reads
their own release notes, on an app whose claim is that it talks to two hosts,
and `raw.githubusercontent.com` is not one of the entries in
`InternetAccessPolicy.plist`. The footer links to the file on GitHub for the
versions this copy cannot know about, at the same URL `release.sh` hands to
`--full-release-notes-url`.

**Two parsers now split one file, and they have to agree.** `release.sh`'s awk
keys on `^## [0-9]+\.[0-9]+\.[0-9]+`, and `Changelog.parse` keys on the same
shape for the same reason given above: an entry's own sub-headings must not end
a section. A disagreement would be silent on both sides, because each half
produces a well-formed result on its own, and the symptom would be a release
whose published notes and whose in-app notes are different halves of one entry.

`listen changelog` is what makes that checkable without the GUI: it reads the
same bundled file through the same parser, so a section the window would split
wrong is a section it prints wrong. `listen changelog --list` against
`grep '^## ' CHANGELOG.md` is the whole test, and `listen changelog <version>`
prints one section.

## `/release` is the shortcut, and it publishes nothing itself

`.claude/skills/release/SKILL.md`. It commits and pushes what is outstanding,
bumps `VERSION`, writes the changelog entry, confirms once, then calls
`./release.sh --publish` and dispatches the Homebrew cask. Every publishing
decision stays in `release.sh`, which CI calls too, so a local release and a CI
release cannot come apart. A skill that reimplemented any of it would be a
second publisher to keep in agreement with the first.

It must run `release.sh` in the background: the build is about ten minutes and
Apple's notarization queue has taken over an hour, so a foreground call hits
the ten minute tool timeout and reads as a hang.

## CI runs a different Xcode from the machine you are on, and only one of them ships

`build.yml` picks the newest Xcode on the runner image on purpose, so it does
not age out with a pinned version. The consequence is that **there is no version
agreement between CI and a developer machine, and neither is told about it.**
Measured on 0.21.0: CI was on Xcode 26.3.0 and this Mac on 26.6.

That is not a detail. `FakeSync.run` had grown to 1,775 lines in one function
under whole-module-optimization, which 26.6 compiled without a word and 26.3
could not: the frontend died and the driver reported `unable to open
dependencies file (ListenKit-primary.d)`, which names nothing about the cause.
Three runs failed identically on the same commit, so it was not transient, and
every local clean build succeeded, so local builds could not see it.

Two things follow, and both cost time before they were written down:

- **A green `./build.sh` is not evidence about CI.** It was used as evidence
  three times during that diagnosis and was worthless each time. Check
  `xcodebuild -version` on both sides before comparing anything.
- **The only way to test a toolchain-sensitive change is CI.** Reverting the
  223 lines on a branch and watching it go green is what established the cause;
  nothing local could have.

`/release` step 1 now reads the last few `Build` runs for this reason. 0.21.0
was published over three red ones because that step asked about the branch, the
commits and the working tree, and never about CI.

## Double-clicking the icon in the DMG window launches the image's copy

Drag to Applications, then double-click the icon still in the DMG window: one
of the most natural first-run gestures there is, and it runs the read-only
copy on the mounted image. Sparkle cannot update it, the login item registers
a path that vanishes on eject, and Gatekeeper may run it translocated
besides. Nothing said any of it; the first outside install did exactly this.
`InstallGuard` runs at launch **before** `LoginItem.applyDefaultIfNeeded` (so
the login item never records the image's path), notices `/Volumes/…`,
`/AppTranslocation/` or a read-only volume, and offers the Applications copy,
copying one there first if none exists and stripping quarantine best-effort,
LetsMove's shape. "Not now" always continues: the diagnosis is heuristic and
must not be able to lock somebody out of their own recorder.
`verify_install_guard.sh` builds a scratch UDZO, launches from the mount, and
asserts the alert and the decline path against the real thing.

## The notarytool profile went missing between two releases on the same day

0.24.1 built, signed and packaged, and then `release.sh` refused to publish:

```
warning: skipping notarization.
         no notarytool profile 'listen-notary' stored.
gatekeeper, app: REJECTED
gatekeeper, dmg: REJECTED (users get a Gatekeeper dialog on open)
error: refusing to publish a release Gatekeeper would block.
```

The refusal is the script working. What is worth writing down is that this
machine had the credential earlier the same afternoon and did not have it two
and a half hours later, and nothing said so in between. Measured rather than
assumed: the published `Listen-0.24.0.dmg` downloaded from the release staples
and validates, `source=Notarized Developer ID`, so the profile was live at
15:42; at 17:59 `xcrun notarytool history --keychain-profile listen-notary`
answers "No Keychain password item found for profile: listen-notary", and
neither `security dump-keychain | grep -i notary` nor `security
find-generic-password -s com.apple.gke.notary.tool` finds anything in the login
keychain. **Why it went is not known.** The Sparkle key in the same keychain was
read normally in the same run, so the keychain was neither locked nor
unreadable. Storing it again is what fixed it: 0.24.1 notarized at 18:39 the
same evening, forty minutes after the run that could not find it.

**It cost a whole build, because the credential was checked after it.**
`HAS_CREDS` was computed at the notarize step, so a missing profile was ten
minutes of xcodebuild before anything was said, and what it said at the end was
`REJECTED` twice with the real cause fifteen lines further up. It is now asked
for in preflight beside the Sparkle key, so it fails in about a second and
prints the `store-credentials` line to fix it. The probe is the same
`notarytool history` call, made once a run rather than twice: preflight settles
`HAS_CREDS` and the notarize step only asks when preflight did not, which is a
plain build.

**The probe is a network call, so its failure is two different things.** The
old warning said "no notarytool profile stored" whatever went wrong, which over
a dropped connection is a wrong answer somebody would act on by re-storing a
credential that was never missing. Both paths now keep what `notarytool` said
and match on `No Keychain password item` to tell setup from everything else.

Recovery is the one-time setup in `RELEASING.md` §2, run again, and then
`./release.sh --publish` from the top. `--resume` is no help: nothing was
submitted, so there is no id to resume, and no tag was created either, so the
re-run is clean rather than a repair.
