# Shared agent workflow

## Working notes

`CLAUDE.md` is the index. The traps themselves are in `.agents/notes/`, one
file per area, and the index lists every headline so you can tell which file
answers the question in front of you. Read the file for the area you are about
to change before you change it: each entry has a measurement behind it, and the
measurement is the part that stops it being re-derived.

## Releases

When a user asks to cut, ship, publish or release Listen, first read
`.agents/skills/release/SKILL.md`, then the complete procedure it links to.
This makes the release workflow available to Codex-style and other
AGENTS.md-aware harnesses as well as Claude Code's `/release` command.

## Two release paths, and when each is right

`./release.sh --publish` runs here and is the one used in practice. It builds,
signs with the Developer ID identity, notarizes through the stored `listen-
notary` credentials, staples, tags, updates the Sparkle appcast and publishes.

`.github/workflows/release.yml` does the same in CI on `workflow_dispatch`,
importing its certificate into a keychain it makes for that job. It is a real
path and it is the Mac's alone: **`listen-ios` has no workflows**, so "use the
cloud release for both apps" is not a plan that exists. TestFlight uploads run
locally, through `listen-ios/tools/release_testflight.sh`.

**Do not open Keychain Access, and do not drive it.** Signing, notarizing and
Sparkle all read the login keychain, which is ordinary and needs nothing from
an agent. Clicking around in Keychain Access is not: doing so locked the login
keychain, which took out codesign, notarization and Sparkle signing across both
apps for an evening, and cost an unrelated afternoon of Xcode account repair.
If signing fails, report the failure and stop rather than investigating the
keychain.

Adding a file to `Sources/ListenKit` also changes the iPhone app, which
compiles those sources. Run `python3 ../listen-ios/tools/make_xcodeproj.py`
after adding one, or the next TestFlight build fails to compile several minutes
in with an error naming a type rather than the cause.
