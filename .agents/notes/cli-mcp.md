# The CLI and the MCP server

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments explain why, thresholds say where the number came from, and no em dashes. -->

Read this before touching `CLI`, `Settings`, `AppInfo`, `CLIInstall` or `MCP`.

## The CLI wrote its preferences into the wrong domain

`UserDefaults.standard` is the app's own domain only while the process is
bundled. Run through the installed symlink there is no `Info.plist` above the
executable, `Bundle.main.bundleIdentifier` is nil, and the standard domain
becomes one named after the process. Measured: `listen me "Symlink Test"`
printed the new name, `defaults read com.mgo.listen userName` said the pair did
not exist, and the app went on showing `Me`. A setting that reports success and
reaches nothing is the worst shape this bug can take.

Reads had the same fault the other way round: `listen sources` answered
"detection is on" from the default rather than from the preference, however the
app was actually configured.

`Settings.defaults` resolves it the way `AppInfo` resolves the version, from the
`Info.plist` beside the real binary, and **every** preference goes through it
including `microphoneUID`. One storage rule with no exceptions, because the
exception is what this bug was.

## An unknown command must not launch the app

`CLI.wants` treats any bare first argument as the CLI, including one it does
not recognise, so `listen bogus` says so and exits 1. Gating on the known list
instead meant an unrecognised command fell through to `NSApplication.run` and
hung the terminal, which reads as the binary being broken rather than the
command being wrong.

Anything starting with `-` that is not one of ours still falls through to
AppKit on purpose: launch services and Xcode pass their own flags (`-psn_0_…`,
`-NSDocumentRevisionsDebugMode`), and refusing to start because of one would
break launching the app entirely.

## `Bundle.main` is wrong when the CLI is run through its symlink

The installed `listen` command is a symlink in `/usr/local/bin` or
`~/.local/bin`, and `Bundle.main` is derived from the path the process was
launched by rather than the binary it landed on. Run that way it points at the
symlink's directory, finds no `Info.plist`, and `listen --version` prints
"unbundled build" while the MCP configuration block loses the command path it
exists to show.

`AppInfo` resolves the real executable with `resolvingSymlinksInPath()` and
walks up to `Contents/Info.plist`. Anything reading the version or the
executable path goes through it, not through `Bundle.main`.

A symlink and not a copy, incidentally, for the same family of reason: a copy
goes stale the first time Sparkle replaces the app, leaving a `listen` on the
PATH that is an older version of the app it claims to be.

## An installed command that is not on the PATH says so

`/usr/local/bin` does not exist on a Mac without Homebrew and creating it needs
an admin prompt this app deliberately does not raise, so the install usually
lands in `~/.local/bin`, which is frequently not on the PATH. An installed
command that cannot be run is worse than one that was never installed, because
nothing else would explain why. `CLIInstall.isOnPath` checks, and the
Developers pane says to add it to the shell profile.

A GUI launch inherits no shell environment, so `PATH` is empty there. The check
falls back to the default login list rather than reporting a false negative.

## The MCP server owns stdout completely

`listen mcp` speaks line-delimited JSON-RPC on stdout. Any stray `print` for
the lifetime of that process corrupts the stream and the client reports a parse
error rather than anything useful. This is the same hazard as mlx-audio's
"Using cached model at" line, which is why `withStdoutOnStderr` exists, and the
MCP path must never load a model.

Notifications, which have no `id`, take no reply. Answering one is a protocol
violation some clients treat as fatal, hence the explicit
`notifications/initialized` case that returns without sending.

A failure inside a tool call is returned as content with `isError`, not as a
JSON-RPC error: the call arrived and was understood, and the agent needs to see
why it failed rather than being told the request was malformed.

### A person filter has to match the name nobody stored

`SpeakerName.matches` compares against the stored label **and**
`SpeakerName.display(label)`, because the two differ for exactly the speakers an
agent is most likely to ask about. The microphone track is `Me` on disk however
the user has set their name, and `A` is `Speaker A` everywhere it is read. A
filter that matched only the disk label would return nothing for
`person: "Maxime"` on a library where 19 recordings are that person, and an
empty result is indistinguishable from "no such person".

Verified both directions on the real library: `person: "A"` and
`person: "Speaker A"` both return the same 17 recordings, and `person: "Edgar"`
returns 4 whatever the case.

`list_people` prints `display` as `name` and adds `label` **only when they
differ**, which is the user's own row and nothing else. Printing
`label: "Edgar"` beside `name: "Edgar"` on every row is noise; printing it for
`Me` is the one case where an agent reading a raw transcript meets a word that
is in no list it was given.

### A bare date is a day, and a day has two ends

`before: "2026-07-14"` meaning midnight would exclude everything recorded on the
14th, which is the opposite of what anyone asking means. `MCP.dayBound` widens a
bare `YYYY-MM-DD` to the end of the day for `before` and the start for `after`,
and takes a full ISO 8601 timestamp literally. Measured: `before: "2026-07-03"`
returns 4 recordings including all three made on the 3rd.

An unparseable date is refused with a message naming what was passed. The
alternative is a filter that silently matches everything or nothing, which is
the same failure shape as the empty person filter above.

`Timestamps` uses a pinned `en_US_POSIX` locale and UTC. A `DateFormatter` on
its default locale reads `yyyy-MM-dd` differently under a non-Gregorian regional
calendar, and that only ever fails on somebody else's Mac.

Date bounds are applied **before** `person` and `query`, which is not cosmetic:
those two read every `turns.json` in the library and the date bounds read only
the metadata already in hand.
