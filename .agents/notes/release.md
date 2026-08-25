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
suspect they are stale. Unbounded staleness, invisible from here because Listen
has no telemetry. The check is a GET of a signed feed that sends no profile
information, so there is nothing in it that needed consent.

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

**A launch also asks quietly, because the interval is a floor and not a
period.** Sparkle's scheduler will not check again until the interval has
elapsed, so a copy launched and quit inside that window learns nothing at all.
`Updater.checkQuietly` calls `checkForUpdateInformation()` on every launch,
which shows no window; the answer arrives through the same delegate callbacks
as any other check and is what puts the badge on the gear. It is guarded on
`automaticallyChecks`, because somebody who turned checking off meant the
network too, not just the dialog.

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
