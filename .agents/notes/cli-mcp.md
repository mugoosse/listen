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

### A workaround only helps the code that remembers it, and MLX does not

The paragraph above was the whole story for a year, and it was not enough,
because `AppInfo` fixes `Bundle.main` **for callers who go through `AppInfo`**.
A dependency reading the main bundle directly is untouched by it.

`load_default_library` in mlx-swift's `Source/Cmlx/mlx/mlx/backend/metal/device.cpp`
tries five locations for `default.metallib`. The only one that ever succeeds in
this app is `NS::Bundle::allBundles()` reaching the main bundle's `resourceURL`,
which is `Listen.app/Contents/Resources`, holding `mlx-swift_Cmlx.bundle`.
Launched through the symlink the main bundle is `~/.local/bin`, so all five miss
and every command that loads a model dies with "Failed to load the default
metallib. library not found" repeated once per attempt.

Measured on shipped 0.9.0, same binary and same file:

| launched as | result |
|---|---|
| `/Applications/Listen.app/Contents/MacOS/Listen` | transcribes |
| `~/.local/bin/listen` | fails, exit 255 |

So `listen transcribe` had never worked through the installed command, which is
every use of it that follows the Developers pane's own instructions.

`CLI.reexecAsRealBinary` fixes it at the root: if the launched path differs from
its symlink-resolved self, `execv` the real one before dispatching. `execv` and
not a child process, so stdin, stdout, the exit code and signals belong to the
real binary with nothing to forward, and the environment carries over, which is
how `LISTEN_LIBRARY` survives and how the `LISTEN_REEXEC` loop guard gets
across. Everything downstream is then simply correct, including `Settings`'
bundle identifier, rather than correct-where-somebody-remembered.

Gated on nothing else on purpose. Restricting it to "commands that load a model"
would be a second list to keep in agreement with reality, which is the failure
this note is already about.

Verify with the guard forced on, or the test proves nothing: `LISTEN_REEXEC=1
listen transcribe x.wav` must still fail. And read `$?` from the **unpiped**
command. An early reading here recorded a silent exit 0, which was `tail`'s
status in a pipeline, not `listen`'s.

## An installed command that is not on the PATH says so

`/usr/local/bin` does not exist on a Mac without Homebrew and creating it needs
an admin prompt this app deliberately does not raise, so the install usually
lands in `~/.local/bin`, which is frequently not on the PATH. An installed
command that cannot be run is worse than one that was never installed, because
nothing else would explain why. `CLIInstall.isOnPath` checks, and the
Developers pane says to add it to the shell profile.

A GUI launch inherits no shell environment, so `PATH` is empty there. The check
falls back to the default login list rather than reporting a false negative.

## Naming a recording had no owner, and no route outside the window

`listen rename` is people. Nothing named a *recording*, so the one part of
tidying a library that could not be scripted was the part a messy day needs
most: six segments of one workshop, all reading "Untitled", each needing a
trip to the window.

`listen title <id> [<text> | --clear]` is that route, and the arguments are
joined with a space the way `listen me` does rather than quoted the way
`listen tags add` does. Both rules are right and the difference is the point: a
tag joins a **derived vocabulary** where two spellings of one name split a group
in half, and a title is free text belonging to one recording with nothing to
disagree with. `--clear` is honoured only when it stands alone, so a recording
may still be called `--clear`.

The part worth reading before adding any command that writes metadata: this
would have been the **sixth** hand-rolled `metadata.title = …; try? save()`, a
count `Tags` already complains about in its own header. The trimming rule is
what makes that dangerous rather than merely untidy, because "an empty field
means `Untitled`" lived only in `DetailView.controlTextDidEndEditing`, and
`isUntitled` is what `MeetingCalendar` checks before applying a name of its own.
A second copy that trimmed differently would have produced recordings the
calendar quietly renamed later.

So `Recording.rename(to:)` owns it and both callers go through it. It returns
**whether anything changed**, which is not a nicety: the window commits the
title on every focus loss, so without it clicking away from an untouched field
wrote the file and fired `onChanged` for nothing. `false` is not a failure, and
a failed write throws.

`MeetingCalendar` deliberately does **not** come through it. It writes a title
derived from an event rather than one a person typed, under its own `isUntitled`
guard, and trimming input nobody typed is a rule borrowed from the wrong caller.

## `listen mcp --tools` is what makes the allowlist true

`MCP.serve` takes arguments now, and `case "mcp"` passes `rest` instead of
dropping it. The reasoning belongs to the agent surface and is in
`.agents/notes/agent.md` under "The allowlist is an argument, because only one
of three backends honoured it". What matters at this layer:

- Without the flag the server offers everything, which is what a
  hand-configured client such as Claude Desktop or Hermes gets. nil is not an
  empty set: nil is "nobody restricted this" and an empty set is a caller that
  may call nothing.
- Every refusal, including an unknown option and a `--tools` naming something
  that is not a tool, goes to **stderr** and exits 2. `serve` owns stdout for
  the life of the process, so a usage line there corrupts the stream before the
  client has finished connecting and it reports a parse error instead.
- Comma-separated, which breaks this CLI's repeat-the-flag rule on purpose. The
  rule exists because user text may contain a comma, which is exactly why
  `Tags.check` refuses one; a tool name is an identifier from a list compiled
  into this binary. `listen notes write --tag` is repeatable, and it is user
  text, so the two are consistent about the thing the rule is actually for.

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

## `listen mcp connect-desktop` edits the Claude app's config, and refuses broken JSON

The Developers pane's copy-the-JSON block works for every MCP client and is a
wall for the person most likely to own the Claude app. `ClaudeDesktop` does
the paste itself: detect the app, back the config up once (never rewritten:
the backup's value is being the file from before Listen touched it), write
only `mcpServers.listen`, keep every other key and server, and refuse a file
that does not parse rather than clobbering somebody's other servers. The CLI
twin exists so the logic is provable headless (`verify_desktop_connect.sh`,
23 assertions over scratch configs) and so the window action has a route
outside the window; `--config` and `LISTEN_CLAUDE_CONFIG` are the same
override. It dispatches before `MCP.serve`, because everything else under
`mcp` owns stdout for the life of the process. The Claude app reads the file
at launch and nothing re-reads it, so the pane says "quit and reopen" and
offers the restart itself.
