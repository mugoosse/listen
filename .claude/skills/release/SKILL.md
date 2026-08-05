---
name: release
description: Cut and publish a Listen release. Commits and pushes outstanding work, bumps VERSION, writes the CHANGELOG.md entry, then builds, signs, notarizes and publishes through release.sh, and updates the Homebrew cask. Use when the user says /release, "cut a release", "ship a version", "publish 0.2.0", or asks to put a new build out.
---

# Cutting a release

`release.sh` is the only thing that publishes, and CI calls the same script, so
this skill must never reimplement any part of it. Everything here is the work
that has to happen *before* that script runs, plus the one thing that has to
happen after it. `RELEASING.md` is the reference for the pipeline itself and
for one-time setup; read it if anything below fails rather than improvising a
way around the failure.

Steps 1 to 4 run without asking. Step 5 is the only gate. Do not add gates the
user did not ask for, and do not skip the one that is here.

If the user named a version in the invocation (`/release 0.2.0`), that is the
version. Otherwise propose one in step 3.

## 1. Orient

```sh
git status --short
git rev-parse --abbrev-ref HEAD
cat VERSION
git log "$(git describe --tags --abbrev=0)"..HEAD --format='%s'
```

Stop and say so, rather than continuing, if:

- The branch is not `main`. A release is cut from `main`.
- There are no commits since the last tag **and** nothing is uncommitted.
  There is nothing to release.
- The working tree holds something that should not be committed: credentials,
  a stray key file, a large binary, debug leftovers. Say what you found and
  wait.

## 2. Commit and push

Review the actual diff before writing anything. Group unrelated changes into
separate commits rather than one omnibus commit.

House style, from `git log`: sentence case, imperative, describing the intent
rather than the file touched ("Colour the played waveform by who is talking",
not "Update WaveformView.swift"). No conventional-commit prefixes, no
`Co-Authored-By`, no generated-with trailer, and no em dashes anywhere.

Then `git push`. The tree has to be clean before step 6: `release.sh` refuses
to publish a dirty tree, because the tag would otherwise point at something
nobody can rebuild.

## 3. Choose the version

Semver, and Listen is pre-1.0, so a breaking change is a minor bump rather
than a major one. Propose from what actually changed since the last tag:

- Bug fixes and copy only: patch.
- Any new behaviour a user would notice: minor.

Do not write the file yet. `VERSION` and the changelog entry are written
together in the next step, because a version with no matching changelog
section is a release `release.sh` now refuses to publish.

## 4. Write the changelog entry

Add a section to the top of `CHANGELOG.md`, under the preamble and above the
previous version:

```markdown
## 0.2.0 (2026-08-12)
```

Use today's date. A section runs from one version heading to the next, so
headings inside the entry can be anything that is not `##` followed by a
version number.

This text is read twice by people who have not seen the commits: it is the
GitHub release body, and it is the pane Sparkle puts in front of somebody
deciding whether to take the update. Write it for them. Look at the 0.1.0
entry for the register, and match it:

- Say what changed and what it costs, not what was worked on. Trade-offs
  stated plainly rather than hidden.
- Measured numbers where there are any, said as measured.
- Known limitations belong in it. 0.1.0 shipped with the corrupted-word rate
  in the notes on purpose.
- No marketing voice, no emoji, no "we are excited to", no em dashes.
- Commits are the input, not the output. Do not paste a list of subject lines:
  `--generate-notes` already appends the full commit list under whatever you
  write.

Then write the version:

```sh
echo 0.2.0 > VERSION
```

Commit both together, and push:

```sh
git commit -am "0.2.0" && git push
```

Do **not** create the tag. `release.sh` tags and pushes the tag itself, and a
tag created here that disagrees with `VERSION` is a failure the script has to
refuse in preflight.

## 5. Confirm, once

Show the user, in one message, before anything is published:

- the version, and the last one
- the changelog entry, in full
- what will be published: the zip, both DMG names, `SHA256SUMS.txt`,
  `appcast.xml`
- that notarization is Apple's queue and has taken over an hour

Then ask whether to publish. This is the only confirmation in the skill, and it
covers steps 6 and 7, so do not ask again inside them. The one exception is
pushing the Homebrew tap, which is a different public repository and is asked
for separately in step 7.

## 6. Publish

```sh
./release.sh --publish
```

**Run it in the background.** The build alone runs about ten minutes and
Apple's notarization queue has taken over an hour, so a foreground call hits
the ten minute tool timeout and looks like a hang. Report progress from the
output rather than starting anything else against the same tree while it runs.

Do not kill it during the notarization wait. If it dies there, the submission
is usually still accepted server-side and the recovery is `./release.sh
--resume <id>`, which the script prints. `--resume` deliberately does not
rebuild: the ticket is keyed to the bundle's cdhash.

Everything else it refuses to do is deliberate and none of it should be worked
around. In particular it will not publish a build Gatekeeper rejects, an
appcast with no signature, or a changelog whose top section is not this
version.

## 7. Update the Homebrew cask

Two lines change per release, the version and the sha256 of the versioned DMG,
so this cannot happen until the DMG exists. The hash is already in
`dist/SHA256SUMS.txt`; take it from there rather than recomputing it.

The workflow is the intended route and **it fails today**, because it needs a
`HOMEBREW_TAP_TOKEN` secret that is not set and exits on its first step.
Nothing is half-written when it does. So check before dispatching, rather than
reporting a dispatch that is already dead:

```sh
gh secret list | grep HOMEBREW_TAP_TOKEN
```

If it is there, dispatch and say so:

```sh
gh workflow run homebrew-tap.yml -f tag=v0.2.0
```

If it is not, edit the cask directly. The tap is cloned at
`../homebrew-tap`, and `Casks/listen.rb` is the file:

```sh
grep "Listen-0.2.0.dmg" dist/SHA256SUMS.txt
```

Change only `version` and `sha256`. Everything else in that file, the caveats
and the zap stanza in particular, is hand-written and not derivable from a
release. Then verify before pushing, because a wrong hash there is an install
that fails for everyone and nothing local would have caught it:

```sh
TAP="$(brew --repository)/Library/Taps/mugoosse/homebrew-tap"
cp Casks/listen.rb "$TAP/Casks/listen.rb"
brew style mugoosse/tap/listen && brew audit --cask --strict mugoosse/tap/listen
brew fetch --cask mugoosse/tap/listen        # downloads and checks the pinned hash
git -C "$TAP" checkout -- Casks/listen.rb 2>/dev/null || rm -f "$TAP/Casks/listen.rb"
git -C "$TAP" status --short                 # must be empty
```

**Put the tapped clone back, and do not assume which way.** That last line is
two cases and picking one is wrong half the time. Before the cask has ever been
pushed, the copy is untracked there and has to be deleted, because `brew update`
refuses to pull over an untracked file. Once it has been pushed and any `brew
update` has run, the file is tracked, and deleting it stages a deletion of
somebody's tap. `git checkout --` restores the tracked copy and fails harmlessly
when there is nothing to restore, which is why it is tried first. Measured both
ways: the 0.1.0 run left it untracked, the 0.1.1 run found it tracked.

Check the status line is empty either way. A dirty tapped clone is a broken
`brew update` for the user, and nothing else reports it.

Commit as `listen 0.2.0`, matching the tap's history. Ask before pushing the
tap: it is a public repository and a separate one from the release.

## 8. Report

- the release URL
- whether the cask went by workflow or by hand, and whether it is pushed
- anything the run warned about

The website needs no change: `docs/index.html` links
`releases/latest/download/Listen.dmg`, which is why `release.sh` publishes an
unversioned copy of the DMG alongside the versioned one.

The website needs no change: `docs/index.html` links
`releases/latest/download/Listen.dmg`, which is why `release.sh` publishes an
unversioned copy of the DMG alongside the versioned one.

## Things that will bite you

- **Never run `swift build`.** It links and then dies at runtime on the
  metallib. `release.sh` calls `build.sh`, which is the xcodebuild wrapper.
- **`CFBundleVersion` is `git rev-list --count HEAD`.** Sparkle compares it to
  decide an update exists, so anything that makes the commit count go backwards
  strands every installed copy. Do not rewrite published history.
- **`.github/workflows/release.yml` is dispatch-only on purpose.** Pushing the
  tag does not start CI, and it should not: a local release would otherwise
  start a job that builds for ten minutes, finds no signing secrets and mails a
  failure for a release that succeeded.
- **The Sparkle key lives in the `listen` keychain account, not the default
  one**, which holds Speak's. `release.sh` checks the two halves agree before
  it builds, and that check is the only thing standing between here and a feed
  every installed copy silently rejects. If it fails, read `RELEASING.md`; do
  not pass `--account ed25519` to make it go away.
