# Asking an agent about the library

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments
explain why, thresholds say where the number came from, and no em dashes. -->

Read this before touching `Agent`, `listen ask`, or anything that spawns a
child process from the app.

Everything here was measured on this Mac against the real 47-recording library,
with `claude` 2.1.226 and `codex-cli` 0.144.5. Both numbers matter: these are
two CLIs under weekly development and half of what follows is a flag that did
not exist a year ago.

## The model is the user's, and Listen never sees a key

Listen ships no language model for this and calls no API of its own. It runs
`claude` or `codex`, already installed and already signed in, as a child
process, and hands it `listen mcp` as the way to reach the library.

That is not a compromise, it is the only version of this feature worth
shipping. A meeting recorder that wanted to summarise meetings used to need a
model, a key and somebody's server, and the whole premise of this app is that
the recordings do not leave the machine. Two of those three are already on the
Mac of anybody who would want the feature and the third was never wanted.
There is no Listen account, no key field in Settings and no proxy.

The cost lands on the user's own subscription, which is worth knowing before
promising anything about speed: measured, a week-summary question that read
three transcripts was 19.9s and $0.21 on a Max plan, and a plain count was 6s.
Anything that reads transcripts is the expensive shape.

## The agent cannot reach the library except through `listen mcp`

Claude is started with `--tools ""`, which removes every built-in tool
including Bash, Read and WebFetch. Measured: the `init` event then lists only
the thirteen `mcp__listen__*` tools, and asked to read `/etc/hosts` it made
zero tool calls and answered "there is no file-reading tool, no `Read`, and no
`Bash` to `cat` it".

Three things follow, and all three are the point:

- **No TCC prompt can appear.** The process reading
  `~/Library/Application Support/Listen` is Listen, which already has the right
  to. A child process rummaging through `~/Documents` would raise a system
  dialog attributed to Listen, and a user would be right to be alarmed by it.
- **The writable surface stays what `MCP.swift` argues for.** Notes and tags,
  and only when the caller passed `--write`.
- **A question costs tool calls**, so the retrieval ladder in
  `.claude/skills/listen-library` is the whole cost model.

Codex cannot be locked down that far, and the difference was measured rather
than assumed. It keeps its shell: asked to, it ran `head -1 /etc/hosts` through
a `command_execution` item and returned the real first line. The read-only
sandbox does hold on the writing side, where `echo hello > /tmp/…` came back
`Operation not permitted`, exit 1, and no file appeared.

So both backends are safe, and only one is *provably* narrow. That is why
`AgentBackend.preferenceOrder` puts Claude first when both are installed, and
why the shell calls are printed rather than hidden: somebody who chose Codex
should be able to watch it run commands.

## Codex will predict a command's output rather than run it

Worth its own headline, because it nearly went into this file as a false
measurement. Asked to run a write probe, Codex twice answered

```
touch: /tmp/listen-agent-write-probe: Operation not permitted
```

with **no `command_execution` event in the stream at all**. The wording was
exactly what the sandbox really does produce, the file really was absent, and
the conclusion "the sandbox refused it" would have been wrong: nothing ran.

Only a prompt that said the answer would be diffed against the filesystem
produced an actual execution, and only then was the refusal real.

The rule this leaves behind: **when measuring an agent, the event stream is the
evidence and the prose never is.** `listen ask --json` exists for exactly this
and is deliberately not routed through `AgentRun`, so the thing being doubted
is not also the thing doing the reading.

## Nothing of the user's own agent configuration runs

`--setting-sources ""` and `--strict-mcp-config` for Claude,
`--ignore-user-config` for Codex.

This is not tidiness. Measured without them, on this machine: five
`SessionStart` hooks fired inside what the user thinks is a text field in a
meeting recorder, every MCP server in the global config was launched, and
Codex's `notify` hook started a computer-use client. An app that spawns an
agent inherits the blast radius of that agent's configuration unless it says
otherwise, and typing a question into a chat box is not consent to run
somebody's hooks.

Auth survives suppression in both, which is the only reason this is usable at
all: Claude still reads its keychain entry and Codex still reads `CODEX_HOME`.
`--bare` would have been the tidier flag for Claude and is unusable here,
because it reads auth strictly from `ANTHROPIC_API_KEY` and never from the
OAuth login that a subscriber actually has.

## A GUI launch has no PATH, and neither CLI installs where one would look

`which` cannot answer this. A Finder launch inherits `/usr/bin:/bin:/usr/sbin:
/sbin` and nothing else, while Claude installs to `~/.local/bin`, Codex arrives
through Homebrew, and either can be somewhere else entirely under npm, bun,
mise, asdf or volta.

So `AgentCLI.locate` makes three passes, cheapest first: the process `PATH`
when there is one, then a fixed list of install directories, then the login
shell, cached for the life of the process.

The login shell pass is `-lic` and not `-lc`, because the `PATH` that nvm and
mise set usually lives in `.zshrc`, which a non-interactive shell never reads.
That means rc files run, so its output cannot be trusted line by line: a prompt
theme prints escape codes first. Every line is therefore tested as a path and
the first executable wins. Five seconds and then give up, because a profile
that hangs on startup must not become Listen hanging.

Order matters and the first pass is deliberately `PATH`. Measured from a
terminal inside a wrapper that shims both CLIs, `listen ask` found the shim and
reported Codex as signed out, which is correct: the shim is what the user's own
`codex` runs. From a GUI-like environment the same binary found
`/opt/homebrew/bin/codex` and reported it signed in.

## `codex login status` says nothing on stdout

`codex login status 2>/dev/null` is empty and exits 0. `2>&1 1>/dev/null`
prints "Logged in using ChatGPT". A probe reading only stdout therefore reports
a signed-in Codex as **not signed in**, and the feature then hides itself
behind a message that is not true, which is the worst shape a detection bug can
take.

`AgentCLI.Probe` keeps both streams and the exit status. Keeping them apart
matters in the other direction too: `claude auth status` prints JSON on stdout
that a merged stream could corrupt, and it is parsed as JSON rather than
matched as prose precisely because that prose is free to change.

## Codex has two approval gates, and the second one is the one that matters

`approval_policy="never"` is not enough. With it alone, every MCP call came
back `"user cancelled MCP tool call"` and the model answered "Unable to access
the library", which reads exactly like a broken MCP server.

The gate that actually applies to MCP tools is per server:

```
-c mcp_servers.listen.default_tools_approval_mode="approve"
```

With both set, the same question answered "47" in ten seconds.

## Two more that cost time

**stdin has to be closed.** Codex reads stdin when it is a pipe and prints
"Reading additional input from stdin..." while it waits, so an inherited stdin
is a hang with an explanation nobody sees. `FileHandle.nullDevice`, for both.

**`--verbose` is not optional.** Claude's `--output-format stream-json` refuses
to run without it, which is not something the flag's name suggests.

## The working directory is a choice, not a leftover

`AgentRun.workspace` is `…/Application Support/Listen/agent`, an empty
directory Listen owns. The current directory is where both CLIs look for
project instructions (`CLAUDE.md`, `AGENTS.md`), where Codex decides whether it
is inside a git repository, and what Claude reports as the workspace it was
trusted for. Left to inherit, the answer to a question would depend on where
the app happened to be launched from, and a developer running a build out of a
checkout would get a different agent from everybody else.

It is deliberately **not** the library. Codex can read whatever it is pointed
at, and there is no reason to point it at the recordings when the MCP server is
right there.

## The brief is the retrieval ladder, and without it the first move is wrong

`AgentRun.brief` is the short form of `.claude/skills/listen-library`, and the
half that earns its place is "narrow before you read". Without it the reliable
first move is `get_transcript` over everything recent, which is the one way to
fail at this: transcripts average about 5,500 tokens and every other tool in
the surface exists so the agent can decide which ones it needs.

Claude takes it through `--append-system-prompt`. Codex has no equivalent flag,
so it rides in front of the first question and is left off resumed threads,
where it is already in the history.

## `delete_note` is on neither tool list, and for a long time that was only true of Claude

The server offers it, because the CLI and a human at an MCP client should be
able to undo a note. An agent answering a question in a chat box should not,
and the asymmetry is the point: everything else it can write is reversible by
hand in the window, and a deleted note is not.

**That was a claim with no measurement behind it, and it was false for two of
the three backends.** `AgentRun.tools(allowWrites:)` says in its own comment
that it is the one owner of this decision, and only `.claude` ever passed it on,
as `--allowedTools`:

- `.codex` was handed nothing of the sort. Measured against the shipped 0.20.0
  binary, `listen mcp` answered `tools/list` with all thirteen tools however it
  was invoked, so a read-only `listen ask --codex` could delete a note.
- `.endpoint` computed the allowlist and used it only to choose which schemas to
  *advertise*. `AgentChat.runTool` called `MCP.call` with no membership check,
  so a model that named a tool it had never been offered was handed it. That is
  a defence against a model that only calls what it was shown, and against no
  other kind, which is the opposite of the population it was protecting from: a
  7B model that invents a tool name also invents one that exists.

## The allowlist is an argument, because only one of three backends honoured it

The fix cannot be on the client side, because one of the clients cannot do it.
Codex has no equivalent of `--allowedTools`: measured against codex-cli 0.147.0,
`codex mcp list --json` renders a server as a command, args, env, cwd and two
timeouts, and there is no tool-allowlist key anywhere in it.

So the list goes into the server's own argv, `listen mcp --tools a,b,c`, which
is the one place all three backends have in common. `MCP.call` refuses anything
outside it and `tools/list` advertises only what is inside it, and because
`call` is already the single choke point for both transports, the in-app tool
loop is covered by the same check as the stdio server. Claude is given
`--allowedTools` as well: the client filters and the server refuses, so all
three now fail the same way rather than one failing differently.

Three details worth keeping:

- **The refusal is a distinct error.** `notAllowed` and not
  `badArguments("unknown tool")`: one means the name is not a tool and the model
  should stop, the other means the name is real and this session does not have
  it, and that difference is the whole of what a model needs to do something
  else instead.
- **It is logged like any other failure**, inside `call`'s existing `do`, so a
  refused call appears in `activity.jsonl` with `"ok":false`. A refusal that
  leaves no trace is the one an audit most wants.
- **`allowed` is a parameter on `call` and a static only for `serve`.**
  `MCP.transport` looks like a precedent and is one for the opposite thing: a
  transport is a property of the process, while an allowlist is a property of
  the caller, and the window can have two conversations running at once with
  different answers to whether writes are on. One `listen mcp` process serves
  one client under one allowlist, which is why the stdio side may hold it in a
  static.

Before this, `listen mcp --anything` started an ordinary server and ignored the
argument. Every unrecognised option is now refused on stderr with `exit(2)`, as
is a `--tools` naming something that is not a tool: the only thing that produces
that list is `AgentRun.tools`, so a name that is not a tool is a bug in this
repo, and a tool silently missing from an agent's surface is a capability lost
with nothing anywhere to explain it. Stderr and never stdout, because `serve`
owns stdout from the first line.

## No cost is shown anywhere, and that is a decision rather than an omission

The stream carries `total_cost_usd` and `AgentRun.Outcome` parses it. Nothing
puts it on screen.

Everybody who can reach this feature is signed into a Claude or ChatGPT
subscription, which is a flat monthly price. The number in the stream is what
the same turn would have cost on metered API pricing, and it is not money
anybody is spending. It shipped briefly as "$0.149" under each answer and a
running "$0.27 so far" in the status line, and it was wrong in the way that
matters: it reads as a meter on a plan that has no meter, and its only possible
effect is somebody asking fewer questions than they are entitled to.

The duration stays. It is real, it sets an expectation, and nobody reads "24s"
as a bill.

## The Ask pane is a third mode, not a panel

`Transcript | Notes | Ask`, in the segmented control that already exists.

A floating window would be a fourth thing to arrange on screen, and the mode
picker already has the two properties this needs: it survives a selection
change, so reading down a list of meetings asking each the same question is a
mode rather than a repeated gesture, and it is attached to the recording whose
title is above it, which is what makes "this meeting" mean something.

### The record button is hidden while it is up, except when it is Stop

Both halves are load-bearing. Two controls in one corner is one covering the
other, and the loser was the field somebody is typing into. But while a
recording is running that button is **Stop**, and a meeting you cannot stop
because you happened to be reading an answer is a worse bug than any overlap,
so it stays and `AskView.trailingClearance` moves the input row out of its way.

That clearance is a number the window sets, not a constraint against the button,
and the first attempt is worth knowing about. `composer.trailingAnchor
.constraint(lessThanOrEqualTo: recordFAB.leadingAnchor)` is the obvious code and
it is wrong twice: `PaneHost.show(detail)` runs *after* the window builds its
chrome, so at the moment the constraint was activated the two views had no
common ancestor and it threw, and the app then ran with **no window at all** and
no crash report. `PaneHost.show` also removes and re-adds the pane on every mode
change, so the constraint would not have survived even if it could have been
made at the right time.

The symptom is worth recognising: an app that launches, stays alive at 0% CPU,
answers accessibility with only a menu bar, and writes nothing to stderr. A
`sample` of it shows the main thread idle in the run loop, which rules out the
deadlock it looks like.

### Nothing on the main thread may run detection

`AgentCLI.chosen()` spawns up to four processes and can spend five seconds in a
login shell. It was called from `AskView.updateStatus`, which runs on every
recording selection, so clicking down the sidebar paid four process launches per
click and the window froze for each one.

Everything on the main thread now reads `AgentCLI.cachedChosen()`, and
`warmUp()` fills the cache once in the background. `cached == nil` and
`cachedChosen() == nil` are different states with different sentences, and the
next note is about what each of them puts on screen.

### Four chips that do nothing were the whole no-agent state

With neither CLI installed the pane showed the starter chips, an empty field and
one line of grey text under the composer saying "No agent is set up. Settings ›
Agent explains how." Three things were wrong with that and all three were
visible on the first screenshot anybody took of it:

- The chips stayed up and stayed pressable. `ask` returns at its first guard, so
  pressing Summarise redrew the same status line and nothing else happened. An
  invitation that is dead on contact is worse than no invitation.
- "Settings › Agent" was prose inside a truncating label, not a route. The one
  thing to do next had no button.
- `usable` is `path != nil && signedIn != false`, so an installed CLI that was
  never signed into got the same sentence as a missing one. Those are one
  command apart, and "not set up" sends somebody to install what they have.

`SetupNotice` replaces it: a bordered card in the chips' slot, with the shortest
true heading, a paragraph, and two buttons. Signed-out wins over not-installed
whenever both are true, and it names the backends and their `signInCommand` in
the sentence rather than sending everybody to the same pane. `drawStarters` now
also requires `cachedChosen() != nil`, so the chips are only up when a press
would go somewhere, and `updateStatus` owns them for that reason.

The card is in the chips' slot rather than over the conversation. A recording
can hold answers saved before the CLI was removed, and those are still worth
reading, so a block in the middle of the pane would cover exactly the thing the
user still has. The status line stays empty while the card is up: two messages
about one problem, six points apart, and the small grey one is the one nobody
reads.

"Check again" is not a nicety either. Every state the card appears in is fixed
in a terminal, and `AgentCLI` caches its answer for the life of the process, so
without it the reward for installing Claude Code is having to quit Listen. It
calls `forgetCachedPaths()` first, as the Agent pane's button does, because an
npm install that landed somewhere this process has never heard of is exactly the
case being checked for.

`installCommand` and `signInCommand` live on `AgentBackend` because two places
now offer them: the Agent pane's copy button and this card. A command that
differs between them is a command one of them is wrong about.

### `LISTEN_PANEL=ask` is how the no-agent pane gets on screen

The state above is unreachable on a Mac that has both CLIs, which is every Mac
that develops this. Two things together make it reproducible, and neither is a
code change:

```sh
defaults write com.mgo.listen-uitest agentPath_claude -string /nonexistent/claude
defaults write com.mgo.listen-uitest agentPath_codex  -string /nonexistent/codex
LISTEN_LIBRARY=… LISTEN_PANEL=ask LISTEN_SHOT=/tmp/ask T.app/Contents/MacOS/Listen
```

`AgentCLI.locate` returns nil for an explicit path that is not executable, on
purpose: "an explicit setting wins even when it is wrong". That is what turns
"uninstall both CLIs" into one line of `defaults`. The signed-in-but-not-really
half needs a shim on disk instead: a shell script answering `--version`, and
`auth status` with `{"loggedIn": false}` or `login status` with a non-zero exit.

`LISTEN_PANEL=ask` is in the same family as `LISTEN_PANEL=live`, and exists for
the same stated reason: a state that cannot be put on screen on demand is a
state nobody checks.

### An answer carries the question it came from

`Save as note` titles the note from the question. Looking that up at save time,
as `chat.turns.last(where: { $0.who == you })`, takes the *newest* question
rather than the one that produced the answer being saved, so pressing Save on an
older answer filed it under something asked afterwards. Measured, and it reads
as the app attaching the wrong text to the wrong thing, because it is.

`AnswerTurn.question` and `Chat.Turn.question` hold it. Files written before
that field existed fall back to the preceding `you` turn, tracked while walking
the list.

### The model menu is asked, never hardcoded

Both halves of the composer's chooser are read from the machine, and the two
backends need opposite techniques.

**Codex** has `codex debug models`, which is the real catalog for the
signed-in account. Filter on `visibility == "list"`, sort by `priority`, and the
menu is exactly what that install offers. Its slugs are exact versions, so
hardcoding them would rot.

**Claude** has no such command, and asking for a model that does not exist
prints prose rather than a list. What it has is aliases, and an alias is
future-proof by construction: `opus` is whatever the newest Opus is. So `opus`,
`sonnet` and `haiku` are what get passed.

The *names* are still resolved, because "Opus" is a worse label than "Opus 5".
The `system/init` event carries the resolved id and is emitted **before the
first API request**, so a session started with a one-character prompt and killed
the moment init arrives costs a process launch and no tokens. Measured: `opus`
is `claude-opus-5`, `sonnet` is `claude-sonnet-5`, `haiku` is
`claude-haiku-4-5-20251001`, which `prettyModelName` turns into "Haiku 4.5" by
dropping the trailing eight-digit snapshot date.

Three of those run concurrently inside the background detection pass, because
three sequential process launches is four seconds added to something that
already spawns four.

Reasoning effort is deliberately **not** offered yet. Both support it: Claude
takes `--effort low|medium|high|xhigh|max`, and Codex has
`model_reasoning_effort` with the per-model levels listed in the same catalog
this menu is built from. It is left out because for reading one meeting the
default is right and the only thing a higher setting reliably buys is latency,
which is the resource this pane is shortest of.

### The composer is Liquid Glass, and laid out by frame

`NSGlassEffectView` where the OS has it, `.hudWindow` vibrancy below that: the
pair `RecordButton` already uses, because those two are the only controls this
app floats over its own content and they should be made of the same thing.

Positioned by frame in `layout()`, not by constraints. `NSGlassEffectView`
places its `contentView` itself, so anything pinned across that boundary is two
systems fighting over one number, which is the trap `RecordButton.layout`
records and the sidebar width paid for before that.

52 points tall, 15 point text. The first version was 36 and read as a search
field, which is the wrong idea about what the pane is for.

### The send button is a button, not a tinted symbol

`arrow.up.circle.fill` in the accent colour looked cheap next to everything
else, and the reason generalises: it is a *picture* of a button. The ring is
drawn by the font, so it cannot match a radius, cannot fill, and has no pressed
state.

`SendButton` is a filled circle with a glyph in it, and it doubles as the stop
control, because a question that is running has to be interruptible and a
separate stop button would be disabled for all but twenty seconds of the pane's
life.

Its idle state is **the accent faded, never a grey**. The first attempt used
`tertiaryLabelColor` as the background, which in dark mode is a translucent
*white*, so it drew a white disc with a `secondaryLabelColor` arrow on it: light
grey on near-white, a blank blob with no glyph. A label colour is for labels.

### Codex sends its preamble and its answer as separate messages

Two `agent_message` items, and appended end to end they read as one broken
sentence: "…what was decided versus left open.In "Post tennis chat with Frank"
(2026-08-08), the concrete decisions were…". Whole blocks are therefore joined
with a blank line, which the streaming path neither needs nor gets.

Codex also reports no duration. `turn.completed` carries token counts only, so
`AgentRun` times the process itself and fills `durationMS` in when the backend
did not. Wall clock, which is slightly longer than the API time Claude reports
and is the honest number anyway: it is how long the person waited.

### An answer is a clock, some blocks, and one line that changes

The first version listed every tool call above the answer, and it was wrong in a
way that is only obvious once you use it: the pane grew *upwards* while you were
reading, so each new call pushed the paragraph you were half way through down
the screen. A list of what an agent did is a thing to read afterwards. While it
is working, the only interesting fact is what it is doing now.

`AnswerTurn` is Codex's shape instead:

- **"Working for 12s"**, counting, which becomes "Worked for 1m 3s" plus a
  disclosure when it stops. One line, and the whole progress report.
- **The blocks**, in the order they happened: what it said, a folded summary of
  what it did, what it said next.
- **One shimmering line** at the bottom, replaced in place. Nothing below it
  ever moves, because nothing is ever added below it.

Tool calls appear twice and differently. Live, in the present tense and one at a
time: "Reading the transcript". Folded, in the past tense and de-duplicated:
"Read notes, read the transcript". `get_transcript 2026-08-08-120836-57DA` is
what happened and never what is shown. Codex's `shell` calls appear too, with
the command: somebody who chose the backend that keeps a shell should be able to
watch it use one.

The working-out **collapses itself** when the answer lands, and a saved
conversation opens collapsed. Nobody rereads "I'll start by checking what's
already known" after the answer arrives, and leaving it up pushes the answer
down the pane behind its own preamble. The whole "Worked for 23s" line toggles
it, not just the chevron: a nine point glyph is a small target for something
whose label sits beside it saying the same thing.

### The shimmer is load-bearing, and it is layers not text

A line of static grey text that changes every few seconds is indistinguishable
from a line of static grey text that has hung. The sweep is what says the
process is alive between changes.

In CSS this is a gradient clipped to the glyphs with its background position
animated. AppKit has no `background-clip: text`, so `ShimmerLabel` builds it out
of layers: the words drawn once in the base colour, a brighter gradient band
over them, and that band masked by *the same words again* so it can only ever
brighten glyphs and never the gaps between them.

`locations` is animated, not the layer's position. A sliding gradient has to be
wider than the view and then positioned against a text width that changes every
time the line does; the stops are in the layer's own coordinate space and are
correct at any width with nothing to recompute. Linear timing, because an eased
sweep reads as something speeding up and slowing down, which suggests progress
that is not being measured.

**Layer properties changed outside a draw animate themselves.** This line's
whole job is to be replaced in place, and the default quarter-second cross-fade
left the old sentence hanging behind the new one every time: "Reading the
transcript" drawn over the tail of "Reading the note …", caught in a screenshot
and initially mistaken for a text-clearing bug. Every layer mutation goes inside
a `CATransaction` with actions disabled.

### A selectable label throws its attributes away when you click it

Clicking an answer to copy a line out of it turned the whole block into plain
text: every bold, italic and list indent gone, and the paragraph noticeably
tighter at the same time. It looked like two bugs and was one.

A selectable `NSTextField` hands itself to the field editor on click, and the
field editor re-renders the content in the *control's* own font unless
`allowsEditingTextAttributes` is set. The tightening was the same event seen
from the other side: the paragraph styles went with the attributes.

That second symptom is what identified the spacing bug below, because the plain
version was the correctly spaced one.

### Markdown built for a note is spaced wrong in a stack of labels

`MarkdownText` ends every paragraph with a newline and gives it
`paragraphSpacing`. That is right in the notes pane, where the whole document is
one text view and the spacing is what separates paragraphs. It is wrong in the
Ask pane, where each block is its own label inside a stack that already spaces
them: the trailing newline drew an empty line and the trailing spacing added a
gap on top of the stack's, so the blocks drifted apart.

`AnswerTurn.rendered` trims the trailing newlines and zeroes `paragraphSpacing`
on the last paragraph only. `MarkdownText` is left alone, because the notes pane
is still right.

### A rotated chevron is only aligned in one of its two states

`frameCenterRotation` on the disclosure looked like the tidier way to have one
glyph in two positions, and under Auto Layout it is not: the constraint engine
sets the frame on the next pass and the rotation is then applied about a centre
that has moved. Measured, the collapsed chevron sat visibly below its own
baseline while the expanded one was fine, which is the giveaway. Two glyphs,
`chevron.right` and `chevron.down`. The fold still animates.

### Three ways a stack view lies about width, all in one pane

Worth reading together, because they look like three different bugs and are one
misunderstanding.

1. **A leading-aligned vertical `NSStackView` sizes each row to its own
   intrinsic width.** The answer turns were therefore as wide as they wanted to
   be, not as wide as the pane, so paragraphs wrapped at about half the window.
   Fixed by constraining each arranged subview to the stack's width, in
   `addTurn` and `addBlock`.
2. **`alignment = .width` is not that constraint.** It was the first attempt and
   it right-aligned the text: visible only on the short paragraphs, because one
   that fills its width looks identical either way. A width constraint plus
   leading alignment says the two separate things that were meant.
3. **An `NSTextField` computes its height from `preferredMaxLayoutWidth`, not
   from the width it was given.** Left unset, each paragraph reserved room for
   the lines it would need at some narrower width and then drew fewer, leaving
   the difference as blank space underneath. It reads as a spacing bug and is a
   measuring one. This is the same trap `Pane.sizeDocument` already records.

And the timing rule that goes with them: set that width from the view's **own**
`bounds`, never from a subview's. A subview's frame during a layout pass is
whatever it was before the pass, so reading it pins every paragraph to the width
the pane had when the turn was created.

### The conversation is a sidecar, and a note is not

`chat.json` beside the recording, the arrangement `turns.json` already has: the
folder is the recording, so deleting one in Finder cannot strand a conversation
about it.

Keeping it out of the note system is what lets it be cheap. Everything in the
pane is disposable, `Save as note` is the one gesture that promotes an answer
into the library, and a question you regret asking leaves nothing behind.

### Markdown is rendered at the end, not while streaming

Plain text while deltas arrive, `MarkdownText.attributed` once the answer is
finished. Re-parsing on every delta re-lays out the whole answer forty times a
second, and half-written markdown renders as its own syntax while it is
half-written.

## `listen ask` is the test mechanism, and it is the same engine as the window

The answer goes to stdout and everything else to stderr, the rule
`listen notes read` already follows, so `listen ask … > answer.md` gets the
answer alone.

A wrong result has three possible causes and there is a flag for each:

| symptom | flag |
|---|---|
| wrong binary, wrong flags | `--print-command` |
| agent cannot reach the library | the tool calls on stderr |
| `AgentRun` misread the stream | `--json` |

`--print-command` quotes the empty string explicitly. `allSatisfy` is vacuously
true for it, so `--tools ""` first printed as bare `--tools` and the pasted
command meant the opposite of what Listen runs.

## An empty row and the conversation shared one number, and the row took it

Opening a saved conversation drew an empty drawer. The chat loaded, the turns
were built, and nothing was on screen. Four hypotheses were spent before the
frames were printed, and the frames say it in one line. Drawer at 548 points,
`LISTEN_CHAT=2026-08-09-101558-BE0C` on the scratch library:

```
self       (0, 0, 1129, 548)
scroll     (0, 548, 1129, 0)     <- zero high
turns      (0, 0, 1129, 331)     <- every turn built and correctly sized
invitation (0, 72, 1129, 468)    <- an empty row, 468 points tall
```

`AskView` is a vertical chain pinned top and bottom: scroll, invitation,
composer, status. Between them the scroll view and the invitation row share
whatever the drawer's height leaves over, and **nothing said which of the two
takes it**.

The free variable is further down than it looks. The row holds `starterLine`,
which holds the starter chips, a spacer and the drawer's chevron.
`NSStackView` detaches hidden arranged views, and in the state that matters the
chips are gone (there are turns) and the chevron is gone (it is expanded), so
all that is left arranged is the spacer: a bare `NSView` with **no intrinsic
content size**. Nothing constrained its height, so nothing constrained
`starterLine`, so nothing constrained the row, and `NSScrollView` has no
intrinsic content size either. The solver split 468 points between the two
however it liked.

Content hugging cannot fix this, and it was tried and measured: hugging pulls a
view down *to its intrinsic size*, and there is no intrinsic size here to pull
towards. Raising it on both stacks changed nothing. The cure is one constraint
on the leaf, `spacer.heightAnchor == 0`, which determines the chain.

It is history-dependent, which is why asking a new question always worked and
only reopening failed. Asking lays the pane out with the chips visible, so the
scroll view already holds a real height when they disappear and the incremental
solver leaves it there. Restoring goes the other way: the turns are added while
the drawer is still a bar, which pins the scroll view at 0, and every point of
the growth to 548 then goes to the empty row.

The general rule, which is worth more than the fix: **two views with no
intrinsic content size cannot be neighbours in a chain that has slack.** One of
them has to be told a number.

## The chips wait for the caret, and the drawer's panel comes with them

The starter chips are the only thing in the composer with no material of their
own. The drawer draws no glass until it has something to hold, so over a meeting
nobody had asked about yet, four unbacked chips lay directly on the transcript
with its text running through them.

Both halves are fixed by one rule: the chips appear when the field takes the
caret, and the panel appears with them. Idle, the drawer over a meeting is one
glass capsule and the page is otherwise untouched.

**`controlTextDidBeginEditing` is not the caret, and it looks like it.** It is
posted when the text first *changes*, so keying off it put the chips up one
keystroke after the caret arrived, which is exactly one keystroke too late for
something whose whole job is to suggest what to type. Measured: focusing the
field left the chips down and the drawer unbacked. `ComposerField` overrides
`becomeFirstResponder` and `textDidEndEditing` instead, which fire on the caret
itself.

One thing that would have broken it and does not: pressing a chip does not end
editing, because an `NSButton` does not take first responder on a click, so the
row is not emptied under the mouse between the press and the release. Clicking a
plain view does not end editing either, for the related reason that `NSView`
does not accept first responder, and that half was read as correct for a while.
It is not; see below.

## The composer is always a fresh conversation, and History is how you go back

`show` used to load the newest conversation in whatever context you had arrived
at: the newest about this meeting, or the newest about nothing. Two bad
consequences, both of which read as bugs rather than as a feature:

- Opening the app put you inside an old conversation nobody had asked for, with
  a panel drawn round it.
- Clicking a meeting somebody had asked about once silently swapped an empty
  composer for last week's answers, and took the starter chips with it, because
  the chips only appear when there are no turns. Which pane you got depended on
  history you could not see.

Nothing is lost by dropping it. Every conversation is in History, and a
meeting's own are named on its page under "Also about this". `discard` was
changed for the same reason: it used to load the next conversation in the
context, which is the same guess made at the worst possible moment.

## History is every conversation, which reverses an earlier decision

The list used to be filtered to the page you were standing on, on the argument
that a flat list of everything was a second, worse library list that offered to
swap the page's subject out from under you.

That was right while the only way in was the title at the top of the drawer,
which is a label on the thing you are already looking at. It is wrong for a
control called History in the window's title bar: a history that hides most of
itself depending on which page you are on is a history you cannot trust.

So: every conversation, twenty of them, grouped Today / Yesterday / Earlier,
because "when did I ask that" is the only thing anybody remembers about a
question they want back. It sits immediately after `.sidebarTrackingSeparator`,
which is the only way to reach the top left of the *content* rather than the
sidebar.

Two menu traps, both measured through accessibility rather than by looking:

- `NSMenuToolbarItem` eats item 0, so `fillHistory` takes a `forPullDown` flag
  and prepends a bare item. Without it "New conversation" is the title and never
  drawn. Same trap as `recordingActionsMenu`.
- `NSMenu` re-enables everything as it opens unless `autoenablesItems` is off,
  so the day headings came back live: three rows that look pressable and do
  nothing, because they carry no action.

Delete used to be one item at the foot of it, and it is not on this menu at all
any more. "Delete is a verb on the conversation, so it is not on History" below
says where it went, and why it took two goes to get off this menu.

## Save as note did nothing on the screen most questions are asked from

`saveAsNote` opened with `guard let recording else { return }`, so on a
conversation about the library the press wrote no file and printed no message.
Measured from the outside: pressing the button through accessibility left
`notes/` empty and left the status line as it was, which is the same evidence a
user has, and it is none.

The guard was a leftover from when the Ask pane was a third mode on a recording
page and could not be reached without one. The composer belongs to the window
now, so nothing is selected on the screen the app opens on, and `persist` had
already been through exactly this: **a question asked with nothing selected is
about the library**, and refusing it there is refusing it in the common case.
An answer that spans four meetings is also the case the library-level note store
was built for, so the one answer most worth keeping was the one that could not be
kept.

Three parts to the fix, and the middle one is the interesting one:

- The guard is gone, and `Notes.create` takes `requiringSources: false` from the
  window only. See `notes-tags-dictionary.md`.
- **The sources are `chat.sources`, not the recording on screen.** `persist` has
  already named the meeting every turn was asked on, and a conversation opened
  from History is pinned, so clicking down the sidebar moves the selection
  without moving what the conversation was about. Filing last week's answer
  against whatever happens to be open would be provenance that is confidently
  wrong. Ids the library no longer has are dropped, because `Notes.create`
  refuses one it cannot resolve and a conversation outlives its recordings.
- **The button reports its own outcome.** The confirmation was only the small
  grey line under the composer, which is a long way from the thing that was
  pressed and is wiped by the next `updateStatus`. `saveTapped` now reads the
  closure's `Bool` and turns the button into a disabled "Saved" with a
  checkmark, which also stops one answer quietly becoming two notes.

Driven with `LISTEN_CHAT=<id>` and `AXUIElementPerformAction`, which is why the
first two claims above are measurements. The save button is a plain `NSButton`
in a stack view, so unlike everything in the composer well it is visible to
accessibility and can actually be pressed.

## A reference is an id the model wrote, and a number the reader clicks

Answers named recordings and left them dead: "Call with Céline Goossens
(2026-08-08)" is a place with no way to get to it, in an app whose whole point
is that the place exists. Granola's numbered citations are the shape, and the
question is where the identity comes from.

**Linkifying titles was tried on paper and abandoned.** Scanning the prose for
titles in the library needs nothing from the model, and it cannot work here:
most of this library is called "New recording", so the match is ambiguous
exactly where it matters, and a citation that opens the wrong meeting is worse
than none. The id is the identity, and only the model has it in hand.

So the agent writes markers and `AnswerReferences` reads them. `Agent.brief`
states the language, `[rec:<id>]`, `[note:<slug>]` and `[person:<name>]`, and
those two files are the whole contract. Measured against Claude Code on a
scratch library: it cites unprompted after the first sentence of each claim,
including two markers side by side, so the brief is worded for that rather than
against it. It puts them before the full stop unless told otherwise, which is
why the brief says "after its full stop".

Four decisions inside it are the ones worth keeping:

- **The marker is not a markdown link.** `[title](listen-recording:id)` parses
  for free and puts the model in charge of the words as well as the id, so the
  answer says the title twice and there is no way to draw the citation as a
  number without throwing its wording away.
- **Numbering happens before markdown and drawing happens after.** An offset
  taken in the source names a different character in the output, because
  `MarkdownText` joins wrapped lines and re-lays out tables. The number is
  parked in the text as `U+E000 n U+E001` and found again by searching the
  rendered string, which is the one thing both parsers leave alone.
- **A marker naming something the library does not have is dropped**, not drawn
  grey and not drawn at all. `ReferenceLookup` resolves each one while
  numbering, reading the library at most once per answer, so an invented id
  costs the reader nothing. Verified with a fabricated id in a fabricated
  `chat.json`: four markers, five references, the fifth silently gone.
- **A superscript, not a filled pill.** The pill has to be an `NSTextAttachment`,
  and an attachment cell takes the click before the `.link` under it is
  consulted. A raised number is one string with one attribute on it, which is
  what makes the whole mechanism the text view's own link routing.

The blocks of an answer are `LinkLine`s now rather than `NSTextField`s, because
a text field can only hand a link to `NSWorkspace` and `listen-recording:` is
nobody's URL scheme. That also retired the trap the field carried: a selectable
`NSTextField` re-renders its content in the control's font the moment somebody
clicks it, so the answer used to lose every bold and every list indent to a
click meant to copy a line. `layout()` went with it: a `LinkLine`'s container
tracks the width the constraint already states.

The number opens a card, and the card is what navigates. A citation is read
while reading the sentence it sits on, so a click that replaces the page under
you is one most people will not risk twice: the card says what it points at, and
"Open recording" is a second, deliberate click. Anchored to the text view, which
outlives the popover, and `.maxY` because an `NSTextView` is flipped and that is
the edge that is downward on screen.

Markers are stripped at both write boundaries: `saveTapped` before a note is
written from the pane, and `write_note` and `edit_note` in the MCP server, since
an agent told to cite in answers cites in the notes it writes too. A note is a
markdown file somebody may open in another editor, and what a note is about is
already a field on it.

One inconsistency, known and left: a preamble block is only markdown-rendered
when a conversation is read back, so a citation in a preamble is numbered on
restore and stripped while it streams. Nothing cites in a preamble today, and
the alternative is re-rendering every block on `finish` for the case where it
does.

## Clicking away gives up the caret, and the whole bar counts as inside

Clicking into the composer and then clicking the page left the caret in the
field: the chips stayed up, the drawer stayed backed, and the page somebody had
gone back to reading was still covered. `NSView` does not accept first
responder, so a click on anything that is not a control goes nowhere and the
field keeps what it has. Only another control took it away, which is why
clicking the sidebar always worked and clicking the meeting never did.

The pattern this app already had for the same problem is `DetailView.mouseDown`,
which catches every click no subview claimed because `NSView.mouseDown` forwards
up the responder chain. **It is not enough here.** `NSControl` does not forward,
and every piece of text on these pages is an `NSTextField`: the empty state's
own sentence, a transcript line, a speaker name. The complaint that started this
was a click on exactly such a label.

So `AskView.watchClicks` arms a local `.leftMouseDown`/`.rightMouseDown` monitor
while the field has the caret, which sees the click whoever ends up claiming it,
and `endComposing` asks for the resignation the ordinary way. The monitor is
armed and torn down inside `setComposing`, so it exists exactly while the flag
the chips key off is true.

**The test is the whole bar's bounds, not the well's.** A monitor runs before
the click is dispatched, so ending editing on a chip press empties the row under
the mouse and the press then lands on nothing, which is the trap recorded above.
Treating everything inside `AskView` as inside covers the chips, the
conversation, the model menu and the well's own padding in one number.
Measured against the built app through accessibility: clicking the field focuses
it, clicking the bar's background leaves it focused, and clicking the transcript
moves focus to the window.

## New chat is a button on the card, and the chevron became a cross

Two things about the drawer's header, both from the same reading of it.

Starting another conversation was reachable only through a list of old ones: the
History pull-down, and the same menu under the drawer's title. That is the wrong
shape. Going back to yesterday's question is browsing and belongs in a menu;
asking a fresh one is the commonest thing anybody does with a card that is
already open, and it was costing a menu and a read of every row in it. It is now
a disc in the header beside the other two, calling the same `newConversation`
the menu row calls. The menu keeps its row, because the pull-down is the only
route in when no card is up.

The collapse control was a `chevron.down`, which was drawn from the mechanics:
the drawer slides down to the bar, so down is where it goes. Nobody reads it
that way. A downward chevron in a pane full of scrolling text is "go to the
end", and this one sat in the corner where every card in every other app puts
its dismissal. It is an `xmark` now, and one-way rather than a toggle: the
header only exists while the card is open, so a cross that reopens what it just
closed would be a lie about which of the two it is.

**And a cross has to actually close it.** Collapsing kept the conversation
current: the bar came back and the next question silently continued it, with
nothing on screen naming which conversation that was or that there was one.
`closeConversation` therefore calls `startNew` and gives up the caret, so what
is left is a fresh composer over an untouched page. Nothing is lost, because
History holds every conversation and this one is one click into that menu.
The cost is that closing mid-answer stops the run, since `startNew` does; the
alternative is an agent streaming into a card nobody can see.

That leaves the two header buttons differing by one thing: both start a clean
conversation, and only `newConversation` puts the caret in the field. Which is
the difference between "ask something else now" and "I am done here".

Left to right the header is: title, new conversation, resize, close. The two
that change how much room the conversation has stay together, and the one that
ends it is on the outside.

## The height report is what reopened the card the cross had just closed

Pressing the cross emptied the conversation and left the card up: the three
header discs still there, the panel still the height of an answer, and nothing
drawn in it. Reproduced against the shipped 0.12.0 binary, so it is a fault in
the build rather than in a reading of the diff.

`AskView.reportHeight` answers 560 whenever `wantsRoom` is set, whatever the
view is actually holding: the number says *whether* there is a conversation, not
how tall one is. `wantsRoom` is set by asking and by opening something from
History, and cleared by `show`, `show(person:)` and `discard`. `startNew` never
cleared it. So the empty conversation the cross leaves behind went on claiming a
card's worth of room, and the drawer believes the last number it was given:

```swift
else if extent == .bar, wantedHeight > Self.barCeiling, !putAway {
    extent = .standard
}
```

That branch is what lets a bar open itself when an answer arrives. Here it fired
on the press that had just collapsed the drawer, and reopened it around nothing.
The fix is one line in `startNew`, which now matches the other three fresh
conversation paths.

**The New chat disc had the same fault and hid it.** `newConversation` ends with
`focusField`, and gaining the caret reports a height, which goes round
`applyHeight` once more: by then `extent` is `.standard` with no conversation,
which is the branch that forces the bar. One accidental extra report cancelled
it. Closing focuses nothing, so closing is where it showed. Measured on 0.12.0:
the cross leaves the header on screen and New chat does not.

**And the report arrives in the middle of the gesture.** `composer.startNew()`
reports its new height before `closeConversation` has finished saying what the
drawer should be, and that report used to lay the drawer out from a state the
press had not written yet: the card jumped shut unanimated, and the animated
pass meant to close it then found the height already at its target and had
nothing left to move. `settling` is the answer: the number is recorded, the
layout is skipped, and the three gestures that empty the composer, close, new
and delete, each collapse exactly once and ease while doing it.

Checked with an AX driver rather than by eye, and the assertion is the header.
`applyHeight` hides the header when the drawer is a bar, and a hidden `NSView`
leaves the accessibility tree, so "is there still a button called Close the
conversation" is the whole test. The library is a scratch directory holding one
`chats/<id>.json` and no recordings at all, which is enough: a conversation
loads from that file and needs nothing else on disk. One trap in writing it: the
History pull-down's own **New conversation** row is an `AXMenuItem` and stays in
the tree while the menu is open, so the check has to be for `AXButton` or it
fails on a menu it opened itself.

## Expanded is a page, and a page has no frame around it

`extent == .full` used to be the card grown until it nearly touched the window's
edges: the same 16 point inset, the same 20 point corners, the same glass, and a
blurred transcript behind an answer nobody was reading against it any more. That
is the worst of both. A frame drawn a few points inside a frame reads as a
mistake, and somebody who has asked for all the room has stopped looking at the
page underneath.

So full is a different thing rather than a bigger one, and Granola's expanded
chat is the shape:

- The drawer's four insets go to zero and the top is **pinned** rather than
  sized. `drawerTop` replaces `drawerHeight` while the page is up, so a window
  resize refits it with no code involved. The height constant is still kept
  current, because it is what the collapse animates from.
- `pageBackground`, an `NSBox` with `fillColor` rather than a layer-backed view,
  takes over from the glass. A box redraws itself when the appearance changes
  and a `CGColor` on a layer does not, which is the trap `DetailView.styleCard`
  records. The glass is hidden outright: a material exists to say what is behind
  it, and on a page nothing is.
- `content.view.isHidden = page`. An opaque background is enough for the eye and
  not for accessibility: a transcript still in the tree under a full-screen
  conversation is a page VoiceOver reads and nobody can see.
- Nothing is reserved underneath. `setBottomInset` exists so the last lines of a
  transcript clear the drawer; a transcript that is not on screen has nothing to
  clear, and reserving its whole height would leave it scrolled somewhere else
  on the way back.

The card is untouched. `standard` is still an inset glass panel resting over the
meeting it is about, because that is the state where the page behind still
matters.

## The page scrolls, not a panel inside it

The first version kept `AskView` a column and let it carry the scroll view with
it, so the conversation scrolled inside a 620 point strip with its own scroller
down the middle of an otherwise empty page. It reads as a panel with the frame
taken off rather than as a page.

What fixes it is which view is the column. `AskView` spans the page and its
scroll view is pinned to both edges; `setPage` moves the column inside, onto the
four things that are read: the turns stack in the document, the invitation row,
the composer well and the status line. The scroller then lands on the window's
edge, where a page's scroller belongs, and the thing that scrolls is the page.

Two numbers go with it. `scrollTop` is 52 on a page, which clears the toolbar
floating over the content: a content inset was the other way, and is what
`DetailView` does with its notes pane, but the page's own controls sit in that
strip now and text sliding under a glass group with History and New chat in it
is legible through the glass. And `pageColumn` is 620, which is 105 characters
of the 13 point body at the 5.9 points a character it measures: the same text
full width on a 1512 point window ran to 168.

## A width nobody else may have an opinion about

The column is one constraint, `width == 620` at **priority 300**, with required
margins either side of it. Every other way of writing it was tried against the
built app first and all three are wrong:

- **`widthCapped`'s trick**, a 500-priority equality to the parent against a
  required maximum, reached the window. Entering the page shrank it from 1512
  points to 1136, which is the column plus the margins plus the sidebar, moved
  the difference into the sidebar, and then refused to be dragged wider again.
  500 is `windowSizeStayPut`, which is exactly the priority at which AppKit
  stops holding a window's size against its content. `widthCapped` gets away
  with it in a settings pane because that is inside a scroll view, where nothing
  it says can reach the window.
- **The same equality at 240**, below the split view's holding priorities of 250
  and 260, lost to the invitation stack's own content hugging, which is 250. The
  column came out 560 wide whatever the window did: 560 is
  `SetupNotice.maxWidth`, and the hidden setup card was the only thing left with
  an opinion.
- **Required margins with the arithmetic done in code** blocked the resize they
  were computed from. A 228 point margin either side of a 620 column is a
  required 1077 points of pane, so the window would not go below 1380, and the
  recomputation that would have freed it needed a layout pass it could not have.

300 is above everything inside this pane with an opinion about width and below
the window's. Stating it as a breakable width with unbreakable margins is also
what makes a narrow window work: the column gives way to the pane's edges
instead of the pane refusing to be that narrow.

All three readings are from `AXUIElementCopyAttributeValue` on the running app,
against a scratch `LISTEN_LIBRARY` with `LISTEN_CHAT` opening a real
conversation. The first one was nearly mis-read as a second copy of Listen
running: check the pid, per `target-mac-apps-by-pid-not-system-events`.

## The document was as wide as the scroll view, and the scroller took the difference

`document.width == scroll.width` cut the right-hand edge off every question
bubble on a Mac set to show scrollers always, which is any Mac with a mouse
plugged in. The document was wider than the visible area by the scroller's
width, and no horizontal scroller appeared to say so, because the constraint
said there was nothing to scroll. It is `scroll.contentView.width` now.

The same difference is why the column is centred on the **scroll view** and not
on the document: centred in the document it sat half a scroller to the left of
the composer under it, which is a misalignment you can see and cannot name.

## A width was all the document had, so the first scroll moved the column

Stating only `document.width` left the document's **x** free, and a free
variable is one the solver may spend. Centring the column reaches out of the
clip view, and the cheapest way to satisfy that is not to move the column inside
the document at all: it is to slide the whole document sideways and let the clip
view's bounds origin follow it. The two cancel, so the page opens looking
exactly right.

The first scroll is where it comes apart. Scrolling writes a new bounds origin,
`x` goes back to zero, and nothing puts the document back, so the conversation
jumps sideways and stays there for the rest of the session. Both numbers are
measured: in an isolated harness the document sat at `x == -249` with the clip's
bounds origin at `-249` to match, and in the built app at 1400 points wide the
column opened centred at 541.5 and moved to 756.0 on the first scroll. The
direction is arbitrary, being wherever the solver parked the document, which is
why the report was of a page that shifts *left* and the harness shifted right.

The fix is one constraint, `document.leading == scroll.contentView.leading`,
which is the same edge the width is already taken from. Nothing else changes:
the column is still centred on the scroll view, the card still pins its turns to
both document edges, and no conflict is logged in either mode.

The general form is worth carrying past this pane: **a document view needs a
position as well as a size**, and a scroll view will hide the missing half until
something scrolls.

## The page's controls are the window's toolbar

A page has one strip of chrome and it is the title bar, so the drawer's header
is hidden while the page is up and its three discs are gone. Putting a header
under the toolbar would be two rows of buttons doing the same jobs six points
apart, and it would take the top of the conversation with it.

`chatting` is not a fifth `Mode`: the mode underneath is still selected and
comes back untouched. It only changes what the toolbar's content half holds,
which is everything after `.sidebarTrackingSeparator`. The sidebar's half is
left exactly as the mode had it, because the list is still there and still
works.

What the content half becomes:

- **`leaveChatItem`**, wearing the same `arrow.down.right.and.arrow.up.left` the
  card's resize disc wears while expanded, so the two directions of one control
  look like each other whichever strip they are in. It puts the conversation
  back over the page rather than closing it, which is what the card's cross is
  for.
- **History**, the same item and the same menu as everywhere else.
- **`newChatItem`** in New Recording's slot, with `title` set as well as
  `image`: the toolbar is `.iconOnly`, and setting `title` is what puts the
  words in the item rather than under it, which is how History gets its label
  too. A chat page is not a place you start a meeting from, and the words are
  what make the swap readable rather than a pencil where a record button was.
- **Stop, if a meeting is running.** The rule the Ask pane already had, kept
  because a page covers more than that pane ever did.

Two knock-on rules in `applyHeight`, both about staying where you are:
`newConversation` leaves the extent alone on a page, so New chat is an empty
page rather than a jump back to the meeting; and the "an empty conversation is a
bar" rule is narrowed to cards, which is what makes an empty page possible at
all. Opening one from History does the same: `onWantsOpen` only forces a card
when it is not already a page.

## Neither CLI says the network is gone, and both were measured saying nothing

A question asked with no connection used to be a pane that said "Thinking" until
somebody pressed Stop. The obvious fix, waiting for the CLI to report the
failure, does not exist. Against a blackholed API (`192.0.2.1`, which drops
packets rather than refusing them, so it looks like an unplugged uplink):

- `claude -p --output-format stream-json` ran for **100 seconds** emitting
  nothing but its own hook events, wrote nothing to stderr, and did not exit.
- `codex exec --json` ran the same 100 seconds, printed `thread.started` and
  `turn.started`, then nothing. Its only stderr was
  `failed to refresh available models: timeout waiting for child process to
  exit`, which names neither the network nor the question.

With the connection **refused** rather than dropped, which is the fast and
unambiguous error, `claude` got as far as `system init` and then sat silent for
90 more seconds. So even the case the CLI could report instantly is retried in
silence for longer than anybody waits. `Reachability` exists because of these
three measurements and nothing else.

## The path is certain and the probe is truthful, and neither is enough alone

`Reachability` has two halves on purpose.

`NWPathMonitor` is cheap, continuous and sends no traffic, and `.unsatisfied`
is definite: no interface can carry anything. It covers the Wi-Fi being
switched off and the cable coming out. It does **not** cover the commonest
outage there is, a router still happily handing out addresses over a dead
uplink, where the path stays `.satisfied` throughout.

So `.satisfied` proves nothing, and the second half is a TCP connection to the
backend's own API host, opened only when a run has already gone quiet.
Nothing is sent and nothing is read: the handshake completing is the whole
answer, so it costs no request against anybody's account and says nothing about
whether the credentials are good. `.waiting` counts as a no, because that is
the state `NWConnection` sits in with no route, and it will sit there for ever
rather than fail, which is the same trap as the CLIs one level down.

`api.anthropic.com` for Claude and `chatgpt.com` for Codex, which are the
default providers' hosts and nothing cleverer. Codex on an API key talks to
`api.openai.com`, and either CLI behind a corporate proxy talks to neither.
Both make the probe say less than the truth, which is survivable only because a
failed probe never stops or fails a run. It puts a sentence on the screen.

## Twenty seconds of silence, and why that is not a guess

The watchdog probes after 20 seconds with nothing from the process. Events
arrive far more often than that in a working run: streaming is on, so a
thinking model emits deltas continuously, and the longest natural gap is a tool
call into this app's own MCP server, which answers from local files in well
under a second. A silence that long is already abnormal. The probe is what
decides whether it is the network or a model taking its time, and a probe that
succeeds emits nothing at all, so a slow answer is never accused of being an
outage.

Anything arriving withdraws a report the **probe** made, because output is
proof the run is moving. It does not withdraw one the **path** made: with the
interface still down, a line of hook output says nothing about whether the
question can reach a model.

## A run is never killed for the network, and the line stops shimmering

Two states, one place. Offline before the process starts is a refusal:
`AgentRun.start()` throws `Failure.offline` and no process is spawned, because
starting one is 100 measured seconds of silence for nothing. Offline **under** a
running process is a sentence on the activity line and nothing more. A blip
mid-answer would otherwise cost the words already streamed and the session
behind them, both CLIs retry, and Stop is where it has always been.

The line goes amber and **stops sweeping**, which is the shimmer's own argument
read backwards: it is there to say the process is alive between changes, and
this is the one state where it is making no progress. A shimmering "no internet
connection" is the same reassuring movement that made the hang look like work.

The composer's status line says it too, before anything is typed. What neither
does is **disable** anything: `.satisfied` is not a promise and a wrong reading
has to cost a sentence rather than the feature.

## The failed turn had to end the turn, not just colour it

The catch around `start()` called `fail` on the answer view alone. That left
`answering` set, no turn in `chat.json`, and `updateStatus` never called, so the
send button kept the Stop it had been given a moment earlier with nothing left
to stop. It went unnoticed while the only way to reach it was a missing binary.
It routes through `finish` now, with a real `Outcome`, so the failure is on
screen, in the file, and the button says Ask again. Read back from disk the
turn renders the same red paragraph, which the stored `failure` field already
supported.

## `LISTEN_OFFLINE` and `LISTEN_PROBE_HOST`, because unplugging is not a test

`LISTEN_OFFLINE=1` makes every reachability check say offline, which drives the
whole pre-flight path without touching the Mac's connection. `LISTEN_PROBE_HOST`
replaces the host the probe opens a socket to; point it at `192.0.2.1` and
point the CLI at the same address with `ANTHROPIC_BASE_URL`, and the silent hang
reproduces end to end in about 25 seconds. In the family of `LISTEN_CHUNK` and
`LISTEN_PANEL`: measurement, not a user-facing switch.

The sentence names `Reachability.host(...)` rather than the backend's host, for
a reason worth keeping: it first named `api.anthropic.com` while the override
sent the connection somewhere else entirely, which is a test that lies about
what it tested.

## The shimmer line was invisible to accessibility, and that is why it was untestable

`ShimmerLabel` draws into `CATextLayer`s, so the one line that says what is
happening right now was missing from the accessibility tree, and
`LibraryWindow.writeShot` cannot help either: the conversation page is Liquid
Glass and comes out of a bitmap render as a white sheet. Between them there was
no way to read this state from outside the process at all.

`isAccessibilityElement`, `accessibilityRole` and `accessibilityValue` on the
label fix a real defect for anybody using VoiceOver and, incidentally, are what
made every claim above checkable:

```sh
ANTHROPIC_BASE_URL=http://192.0.2.1:443 LISTEN_PROBE_HOST=192.0.2.1 \
  LISTEN_LIBRARY=/tmp/scratch ./Listen.app/Contents/MacOS/Listen
# 6s:  "Working for 6s"  / "Thinking"
# 32s: "Working for 32s" / "Nothing back for 20s, and 192.0.2.1 is not answering."
```

One thing that does **not** work: setting `AXValue` on the composer's field and
posting a Return. The text lands in the cell, no edit ever starts, so there is
no field editor for the Return to reach and the send action never fires: the
question sits there looking sent. The app has to be activated and the
characters typed as `CGEvent`s. The send button itself is a plain `NSView` with
a target and action, so `AXPress` on it returns `-25206`, which is the same
`HoverRow` gap the root `CLAUDE.md` already records.

# The third backend: an OpenAI-compatible endpoint

Everything above is about driving somebody else's agent. This part is about the
case where there is no agent, only a model, and Listen has to be the harness
itself. `AgentChat.swift` is the whole of it.

Measured against Ollama 0.20.7 with `qwen3.5:35b`, and against OpenRouter's
live API, on this Mac.

## Claude and Codex are harnesses; an endpoint is one POST

This is the structural fact and everything else follows from it. A CLI is handed
a brief, an MCP config, a tool allowlist and a model, and it runs the loop: it
decides to call a tool, calls it, reads the result and carries on. An
OpenAI-compatible endpoint can only answer "I would like to call this tool", so
the loop, the tool execution, the conversation history and the streaming parse
are Listen's.

What did **not** have to change is the interesting half. `AgentRun.Event` was
already the seam, so the pane, the settings pane and `listen ask` consume the
same eight events and cannot tell which of the three backends produced them.
Adding this was an addition, not a rewrite, and the diff above the seam is
`var run: AgentRun?` becoming `var run: AgentSession?`.

`Question.session(on:onEvent:)` is the one place that picks an engine. A fourth
backend one day is a case there and nothing at any call site.

## `MCP.call` is a function, and stdio is one transport onto it

`MCP.tools` and `MCP.call` were `private`. They are internal now, and
`MCP.serve()` is one of two ways in: a pipe from a child process, or a direct
call from `AgentChat` in this process. `MCP.toolSchemas(_:)` is a mechanical
translation of `inputSchema`, which is already JSON Schema, into OpenAI's
function shape.

The property worth protecting is that both routes reach the library through the
same function. Two transports that resolved a recording differently would be a
bug nobody could reproduce from one side.

`MCP.call` reads the library off disk and is synchronous. Over stdio that cost
lands in another process; in-process it is the caller's job to be off the main
thread, which `AgentChat`'s work queue is.

## Every tool failure comes back as a result, never as an error

The difference between this backend and a CLI, in one rule. Claude does not hand
Listen malformed JSON or invent a tool name. A small local model does both. A
run that died on either would be a feature that works on frontier models and
nowhere else.

So: unparseable `arguments` return the parse error as the tool result, with an
example of the shape wanted. An unknown tool returns `MCP.call`'s own
"unknown tool: X". Told what it got wrong, in the place it is looking, a model
retries and usually succeeds.

Two caps for the same reason, and both say so rather than truncating quietly:

- **Twelve rounds.** The retrieval ladder is four steps and a thorough answer
  walks it more than once, so twelve is about three times the honest worst case.
  It exists for the model that answers every tool result by calling the same
  tool again. Hitting it fails with a sentence naming the cap, because an answer
  that stops silently is indistinguishable from one that finished.
- **24,000 characters per tool result**, with "call again with `offset`"
  appended. A transcript is about 5,500 tokens and a local context is often 4k,
  and overflowing does not fail loudly: it pushes the system prompt out of the
  window and the answer comes back confident and baseless.

## The history is the session, and only finished text turns are replayed

A CLI owns its thread and is handed `resume`. An endpoint is stateless and is
handed the messages, every time. `Question.resume` and `Question.history` are
exclusive rather than alternative: `AgentRun` ignores one and `AgentChat`
ignores the other, so a `Question` never has to say which kind it is.

Three rules in `buildMessages`, and each was a decision:

- **Tool traffic is not replayed.** Those are by far the most expensive tokens
  in a conversation, they are already summarised into the answer that follows
  them, and leaving them out makes every request valid by construction: a
  `tool_call` can never appear without its result, because neither ever appears.
- **`Step.activity` blocks are not replayed.** They are display text written for
  a reader, "Read notes, read the transcript", not something the model said.
- **A failed turn is skipped.** Its text is whatever got through before the
  failure, and replaying half a sentence as a complete assistant message teaches
  the model that half sentences are answers.

Verified by hand-writing a `chats/` file whose history contained a fact nothing
else could supply: "my favourite colour is teal", asked back in a new run with
`--resume`, answered "teal" with zero tool calls.

## The first turn is not the absence of a resume id

`AskView.start` scoped a question to the open recording when `resuming == nil`,
which was right while every backend was a CLI: a CLI has no id on question one
and has one from question two. An endpoint has no id ever, so that test is true
on every turn and it prefixed "About the recording …" onto question five of a
conversation that had been about that recording since question one.

**And history cannot replace it**, which is the half worth writing down. The
retry path exists for a CLI whose session the agent has forgotten: it starts
again knowing nothing while `chat.turns` is full, so keying off history would
lose the one sentence saying which meeting is being discussed. The test is
therefore asked of each backend in its own terms:

```swift
let opening = backend.isCLI ? resuming == nil : history.isEmpty
```

## `--print-request` printed a request nobody sends

The endpoint's answer to `--print-command`, and the first version was wrong in
both possible ways at once. It printed `"messages": []`, because messages are
filled in by `start()` and printing starts nothing, and `"stream": false`,
because it read the flag that decides whether the *reader* wants deltas rather
than what is negotiated on the wire.

Both were caught the first time it ran. The fix is that `requestBody()` is the
single function `startRound` sends and `--print-request` prints, which is the
only arrangement that cannot go stale. **A debugging tool that prints a request
nobody sends costs more time than having no debugging tool at all.**

The three-symptom table ports across intact: `--print-request` for the wrong
request, the tool calls on stderr for a backend that cannot reach the library,
and `--json` for a misread stream. `--json` matters more here than for the CLIs,
where a misread is a bug in reading somebody else's tested output; this parser
is new, so `AgentChat.onRawLine` taps the payloads before this file has had an
opinion about them.

## Answering is not the same as being signed in, and OpenRouter proves it

Detection is a `GET /models`. For OpenAI that requires the key, so a 401 there
is a real answer. **OpenRouter's model list is public**, so a bogus key probes
as reachable and lists 400 models, and the refusal only arrives at the first
question.

This is why every word for an endpoint says "answering" and never "signed in",
and why `AgentStatus.refused` is a field rather than something read back out of
the `account` prose. Nothing claims the key is good; the row claims the server
answered, which is literally what happened. The 401 at the first question is
clean and names the pane that fixes it.

The whole vocabulary splits per backend for this reason. A CLI is *installed*
and *signed in*; an endpoint is *configured* and *answering*. "Codex is not
configured" and "Ollama is not installed" are both sentences that send somebody
to do the wrong thing.

## Three answers to "is this local", not two

`AgentEndpoint.Exposure`: loopback, this network, or a named host. The third one
names the host rather than saying "remote", because the difference between
"transcripts go somewhere else" and "transcripts go to openrouter.ai" is the
difference between a warning somebody reads and one they skip.

A hostname that resolves to a private address is reported as `.elsewhere`, which
overstates the exposure rather than understating it. That is the right way round
for a sentence about where somebody's meetings go, and resolving would mean a
DNS lookup on every keystroke in a text field.

The sentence is live under the URL field as it is typed, not in a dialog on
save: "what does this URL mean" is the question somebody has while pasting one.
The confirmation dialog is only for a non-loopback URL, because that is the only
case that changes what the app claims about itself.

## The key is in the Keychain, and the cost argument inverts

Every other preference is in the `com.mgo.listen` domain, which is a plist in
`~/Library/Preferences`: readable by anything running as the user, copied into
every backup, printable with one `defaults read`. Right for a window width and
wrong for a credential. `AgentKey` keys by host, so changing the URL from a
local server to a hosted one and back does not lose either key.

`listen endpoint key` reads from stdin and never from an argument, because a key
in `argv` is in the shell history and in `ps` output while it runs.
`LISTEN_ENDPOINT_KEY` overrides the stored one, in the family of
`LISTEN_LIBRARY`: an environment variable, so a Finder launch inherits none of
it.

And the note above about cost needs one amendment. `Outcome.costUSD` is never
drawn because everybody on the CLI backends pays a flat monthly price, so a
figure reads as a meter on a plan that has none. **A metered API key genuinely
is a meter**, so that argument now holds for two backends out of three.
`promptTokens` and `completionTokens` are parsed and still not drawn, because
tokens are not money without a price list and Listen has no business keeping
one. Worth revisiting rather than worth assuming.

## `padding(toLength:)` truncates

`listen ask` with no question pads the backend name to a fixed 12 columns. The
endpoint is named by whoever configured it, and the first run with three
backends printed `Custom endpo`. The width is measured from the longest name
now. A fixed column width is a bug waiting for a longer string.

## A model that declares tool support will still answer from nothing

The worst failure this backend has, and it is not a crash. Asked "how many
recordings are in the library?" through OpenRouter,
`qwen/qwen3-30b-a3b-instruct-2507` called **no tools at all** and answered:

```
There are 1,247 recordings in the library.[rec:0001]
```

Confident, well formatted, cited, and entirely invented. The real answer was 5.
Asked again it said 124, with a different fabricated id, which is the tell.

**It cannot be filtered out in advance, and that was checked rather than
assumed.** That model declares `tools` in `supported_parameters` in OpenRouter's
own catalogue, as do 333 of its 400 models. Declaring it means the API accepts
the parameter, not that the model uses it. The identical request answered
correctly on a local `qwen3.5:35b` and on `anthropic/claude-sonnet-5`, so it is
a property of the model on the day, not of the catalogue.

So it is caught afterwards, by an invariant that is exactly true rather than
heuristic: **the tools are the only thing this backend can see**, which the
brief states. Zero tool calls and no prior conversation means nothing in the
answer came from the library.

```swift
outcome.toolCalls == 0 && question.history.isEmpty && !answer.isEmpty
```

The history clause is load-bearing, not defensive. A follow-up answered from
what was already said legitimately calls nothing: the "teal" conversation does
exactly that and must not be flagged. Both halves are verified, the fabrication
warned about and the follow-up left alone.

It emits a `.note` rather than failing the run, because "hello" and "what can
you do?" are real questions that need no tools and deserve their answers. The
note names the endpoint and says the answer is not grounded.

The lesson generalises past this app: **when a model's only route to the truth
is a tool, not calling the tool is the whole diagnosis.** Nothing else needs to
be understood about the answer to know it is worthless.

## The stored name only applies to the stored URL

`listen ask --to` points at another server for one run. `AgentChat.init` took
the display name from `Settings.endpointName` regardless, so a run against
OpenRouter was labelled "Ollama".

Cosmetic almost everywhere, and not in the one place it appeared: the warning
above, which names the thing to stop trusting. A sentence saying "Ollama
answered without reading anything" about an OpenRouter answer is worse than no
sentence. The name now comes from preferences only when the URL matches the
configured one, and is derived from the preset table or the host otherwise.

## What the notes spike already knew

`../listen-notes-spike` is a separate experiment about *writing* notes from a
transcript, not about answering questions, so its prompts and templates do not
apply here. Two things from its OpenRouter arm (`or_eval.py`) do, and both are
now in `AgentChat`:

- **Retry 429, 502 and 503**, three attempts, 3s then 6s. A hosted endpoint
  under load answers 429, and giving up on the first one fails a question that
  would have succeeded seconds later. Exactly those three statuses: retrying a
  400 asks the same wrong question twice. A retry does not count towards
  `maxRounds`, or a busy server would eat the model's allowance for thinking.
- **`usage.cost` is real money**, streamed by OpenRouter in the final chunk.
  Measured: `0.004878` for a two-message exchange on `claude-sonnet-5`. Summed
  across rounds, because one answer is several requests.

That second one settles the amendment above with a number. `Outcome.costUSD` is
metered-equivalent fiction for the CLI backends and an actual charge here, and
it is now populated for the endpoint. **Still drawn nowhere.** Capturing it is
what makes showing it a decision somebody can take with a real figure; drawing
it is a product change, and it must never appear under a Claude Code answer
where it would be fiction.

The spike also keeps its key at `~/.config/openrouter-key`, which is where the
end-to-end verification of this feature got one.

## Which Ollama model, measured

Four questions with checkable answers against a five-recording scratch library:
a count, a title, the speakers, and a search. Scored on whether tools were
called at all and whether the answer was right.

| model | size | score | typical |
|---|---|---|---|
| `gemma4:latest` | 9.6 GB | 3/4, then 4/4 | 2-8s |
| `qwen3.5:35b` | 23 GB | 4/4 | 7-18s |
| `qwen3.5:122b` | 81 GB | 4/4 | 21-50s |

**`qwen3.5:35b` is the one to recommend.** It matches the 81 GB model on every
question at roughly a third of the wall clock, and the extra 58 GB buys nothing
measurable on this task. Anything that reads a transcript is already the slow
shape; tripling it for the same answers is a bad trade.

`gemma4` is worth knowing about for its speed, and it is the model that found
the bug below.

## A tool that does not say what it returns will not be used

`gemma4`'s only failure was the count, and it did not get it wrong: it called
**nothing** and answered "I cannot provide the total number of recordings. The
available tools allow…". It had concluded there was no way to count.

`list_recordings` has always returned `pagination.total`, and nothing in its
description said so. One sentence naming the field took it from a refusal with
zero tool calls to 3/3 correct, in one call each.

The lesson is not about small models. **A description that says what a tool
*does* but not what it *returns* leaves the model to guess whether the answer is
reachable, and a cautious model guesses no.** The fix helps Claude and Codex
too, and it cost eleven words.

It is also the cheapest possible confirmation that the grounding check earns its
place: the refusal was ungrounded, was flagged as such, and the flag is what
made the cause obvious.

## OpenRouter is ZDR first and reliability-routed second

The built-in provider now sends `provider.zdr: true`,
`data_collection: deny` and `require_parameters: true` on every request. It
deliberately does not force `sort`: doing so disables OpenRouter's normal
load-balancing and fallback. Privacy still narrows the eligible endpoints; a
fast endpoint that retains the meeting is never an eligible optimisation.

The first library-wide repeated-turn fixture took 26 seconds with GPT-5 Mini
and 15 with GPT-5.4 Mini; DeepSeek V4 Flash initially exhausted all seven
rounds because Listen rejected its repeated valid evidence ID. After fixing
that validator, a direct recording-scope fixture large enough to fill the 64 KB
preload took 7 seconds with GPT-5.4 Mini, 18 with GPT-4.1 Mini, 21 with a failing
GPT-4.1 Nano and 116 with a failing GPT-5 Nano. Claude Haiku 4.5 had no eligible
ZDR endpoint. A corrected DeepSeek V4 Flash library run was grounded but took
about 80 seconds and four rounds. That is why GPT-5.4 Mini is the phone's
new-install default and why a `Flash` name is not a latency guarantee under a
strict ZDR plus tool-calling contract. An existing model preference is never
rewritten: opening a pane must not edit settings, as the measurement later in
this file already proved.

Forcing `sort: latency` later selected Azure and reduced the same GPT-5.4 Mini
run to 13 seconds, but it too exhausted all seven rounds without answering.
Reliability-aware routing is therefore part of the correctness contract, not
just a speed choice. The same live probe also caught a parameter spelling trap:
`max_tokens` plus `require_parameters` removed every ZDR endpoint, while the
current `max_completion_tokens` spelling retained the Azure endpoint.

Library and person questions now run the local recording and note searches
before their first request, just as recording and note scopes already preload a
bounded read. A deterministic test proves those results are in request one. A
live GPT-5.4 Mini run over the 500-turn fixture completed grounded in 7 seconds
of script wall time; the script includes app launch and two-second result
polling. OpenAI GPT-5 requests also use `reasoning.effort: minimal`: these are
retrieval and summary turns, and there is no reason to pay for a large invisible
reasoning budget before returning short cited prose. This is a cap, not a magic
latency fix: a second grounded run took 9 seconds, which is normal route
variance. OpenRouter's `:nitro` variant was also grounded but took 8 seconds on
the identical fixture, so prioritising output throughput did not improve this
small structured response enough to replace reliability-aware routing.

GPT-5.6 Luna later completed two small-context library runs in 5 and 8 seconds,
but took 12 seconds when a selected 500-turn recording filled the 64 KB preload;
GPT-5.4 Mini had completed that long shape in 7. The iPhone's new-install
`listen/automatic` choice therefore selects Luna below 24 KB of encoded provider
messages and GPT-5.4 Mini at or above it. The split is based on bytes, not the
scope label, so a long note and a short recording take the measured route too.
Concrete and custom model choices bypass this routing, and old explicit choices
are never rewritten.

While a request is in flight, the phone mirrors the Mac's inline activity
language and 1.6-second linear glimmer instead of leaving a generic spinner.
Reduce Motion receives the same status as a still accessible label. Capturing
successive simulator frames proved the highlight crosses “Drafting from 6
local excerpts…” while a monospaced elapsed timer advances, rather than merely
compiling an unused animation.

The slowest real-phone failure was not an OpenRouter timeout. A selected
42-minute recording reached round seven in 70,477 ms because the model cited
`ev-19` with a quote that did not exactly match its app-issued excerpt. Listen
returned only that generic error, so the model repeated the same bad quote and
the encoded request grew to 127,975 bytes. The phone now treats casing and
punctuation-only quote differences as the same contiguous words. A genuinely
invented quote receives one guided repair containing the exact local line, and
that repair request exposes only `submit_answer`; if it still fails, Listen
stops instead of permitting another read. A 300-turn scoped summary then
completed grounded in one provider round and eight seconds of script wall time.

Do not copy the Mac's visible token streaming mechanically. The phone requires
the final turn to be a `submit_answer` tool call, so OpenRouter streams chunks of
incomplete JSON arguments. Its answer text cannot be trusted until the complete
citations array has arrived and every evidence ID and quote validates. Showing
that field early would expose prose that Listen may then reject. Keep the final
answer atomic; the truthful perceived-progress surface is the changing shimmer.
A future SSE transport can measure time to first byte or switch the activity to
“Drafting answer…” without rendering unverified prose.

## OpenRouter is a case, not a preset

It began as one of five presets in the single endpoint slot, and that was wrong
for four reasons that are all about configuration rather than protocol:

- There is no URL to type. It has exactly one.
- It always needs a key, where a local server never does.
- Its catalogue is 400 models, so choosing one is a search rather than a menu.
  319 accept tools, filtered at the source with
  `?supported_parameters=tools`, which is the only list that stays true as
  models come and go.
- It is the case where transcripts leave the Mac, which deserves its own row
  rather than being a state another row can be put into.

`AgentBackend.openrouter` costs nothing structurally: the enum stays a
raw-value enum, so `chat.json` keeps its `backend` string, and the per-backend
settings keys and Keychain lookup work unchanged because both are keyed by the
raw value and the host. And it buys the thing one slot could not: Ollama and
OpenRouter configured at the same time, switched in the composer's menu.

**`probe(as:)` is the trap that came with it.** `AgentEndpoint.probe()`
hardcoded `backend: .endpoint`, so the OpenRouter probe returned a status
claiming to be the local endpoint. The visible symptom was a row labelled
"Ollama" pointing at `openrouter.ai`. The real one was two statuses with the
same backend in one list, which `cachedChosen`, the composer menu and the model
picker all key on: choosing a model for one would have set it for the other.

The picker for it is an `NSComboBox` rather than an `NSPopUpButton`. A menu of
319 items is one nobody can find anything in; a combo box completes as you type
and still accepts an id pasted from a model released after the list was fetched.

## Codex does not give an MCP server its own environment

Found while comparing four backends on one question, and it is the kind of wrong
that reports success. Pointed at a five-recording scratch library through
`LISTEN_LIBRARY`, the four answers to "how many recordings are in the library?"
were:

```
--claude       5
--codex        56          <- the real library
--endpoint     5
--openrouter   5
```

56 is the size of the real library on this Mac. Codex had read it, through
`listen mcp`, while every other part of the same test was pointed elsewhere.

Claude forwards its environment to an MCP server it starts and Codex does not,
so `listen mcp` came up with no `LISTEN_LIBRARY` and opened the default. The fix
is one more `-c`:

```
-c mcp_servers.listen.env.LISTEN_LIBRARY="…"
```

passed only when the variable is set, so nothing changes for an ordinary run.

Two things follow, and the second is the important one:

- To a user this is nearly harmless. They have one library and never set the
  variable.
- **To anybody testing this app it was silently corrupting every Codex
  measurement**, because the scratch library exists precisely so a test cannot
  touch the real one, and `CLAUDE.md` recommends exactly that arrangement. Any
  Codex result recorded against a scratch library before this fix was reading
  the wrong data and looked entirely normal.

The general rule this leaves: **an environment variable that scopes what an app
reads has to be proven to reach every process that does the reading**, and a
child process one hop down is not covered by the parent inheriting it. The test
is a question whose answer differs between the two libraries, which is why
"how many recordings" is the first thing to ask of any new backend.

## Providers are a list, and `AgentBackend` stopped trying to name them

The single-endpoint arrangement lasted about a day. What broke it was not the
protocol, which is identical for every one of them, but the configuration:
Ollama had a URL field, OpenRouter had a key field and a fixed URL, they shared
no code, and a third would have meant writing a third section.

**The enum was the thing in the way, and it was in the way for a good reason.**
`AgentBackend`'s raw value is written into every `chat.json` as `backend`, so
one case per provider would put a growing vocabulary onto disk. The resolution
is that the enum names a *kind* and stops trying to name a *server*:

- `AgentBackend` is `.claude`, `.codex`, `.endpoint`. Three cases, for ever.
- `Provider.id` names which server, and `AgentStatus.key` is the id for a
  provider and the raw value for a CLI. One string either way.
- `Chat.backend` stores that string, so nothing on disk changed shape.
- `Settings.agentChoice` and `agentModel_<key>` are keyed by the same string.

`AgentStatus` grew `provider`, `key`, `name` and `needsNetwork`. That last one
had to move off the backend: whether a question needs the network is a fact
about a URL, and `.endpoint` no longer knows one.

### The shape is anarlog's, and the lesson is the table

`../anarlog`'s `owhisper-client` carries **27 providers** in
`src/adapter/`, one directory each, over a shared `openai_compatible_batch.rs`
parameterised by six fields. Its `groq` adapter is **62 lines** and most of them
are boilerplate around filling those in. Its `enum Provider` answers about
twenty small questions per provider (`auth()`, `default_api_base()`,
`env_key_name()`, `default_batch_model()`), and its `enum Auth` has exactly
three shapes across all 27: bearer, a different header name, or a query
parameter.

The thing worth copying is not the code, it is the claim that **a provider is a
row in a table rather than an implementation**. Listen's catalogue is twelve
rows and adding a thirteenth is a URL and a sentence. `Provider.authHeader`
exists for the same reason anarlog's `Auth` does, and is nil for everything in
the catalogue today: Azure would need it, and it costs one optional string to
be ready rather than a refactor later.

### Three migration traps, all of them silent

The move from one slot to a list has to carry preferences keyed by the old
names, and every one of these reported success while losing something:

- **`agentModel_endpoint` belongs to no provider now.** Left alone, the model
  the user had chosen simply vanished and every question failed on "No model is
  chosen". Moved to `agentModel_<newid>`.
- **`agentBackend = "endpoint"` matches no key**, so `cachedChosen` fell
  through to the first usable backend. Somebody who had deliberately chosen
  Ollama was quietly switched to Claude Code. Rewritten to the new id.
- **OpenRouter had no URL to migrate**, because it was a hardcoded case. The
  only evidence it was ever set up is a key in the Keychain, so that is what
  the migration looks for.

The general rule: **a rename of a preference key is a migration, and a
preference that silently reverts to a default is worse than one that errors.**
Both of the first two were found by running the migration against a real
pre-migration state rather than by reading it.

### `agentModel(status.backend)` was right and became wrong

The same bug twice, in the CLI and in the settings pane's test question: the
model was looked up by backend, which for every provider is `.endpoint`, so it
read `agentModel_endpoint` and found nothing. Every provider question failed on
"No model is chosen" while `provider list` printed the model correctly two lines
earlier.

`Settings.agentModel(_ key: String)` is the real one now, and the
`AgentBackend` overload survives only for the two CLIs. If a third caller ever
wants it, the overload is the thing to delete.

### The composer's menu caps at twelve and says so

A provider can offer 318 models. A menu that long is one nobody can find
anything in, so the composer shows twelve per provider and a disabled row
reading "N more in Settings › Agent". The searchable picker lives in the pane,
where an `NSComboBox` completes as you type and still accepts an id pasted from
a model released after the list was fetched.

## A menu is for what you use; a picker is for finding

The composer's model menu listed the first twelve models a backend offered,
alphabetically. For Claude's three aliases and whatever Ollama has pulled that
is the whole list and it is correct. For OpenRouter's 318 tool-capable models it
produced this:

```
OpenRouter
  Default
  ai21/jamba-large-1.7
  aion-labs/aion-2.0
  aion-labs/aion-3.0
  aion-labs/aion-3.0-mini
  amazon/nova-2-lite-v1
  … five more amazon/nova …
  306 more in Settings › Agent
```

Twelve rows nobody chose, and 306 that could not be reached from the composer at
all. **Both halves are the same mistake**, which is asking one control to be a
catalogue and a shortcut at once. Sorting cannot fix it, because the problem is
not the order of the twelve.

So the menu became recency and the catalogue became a picker:

- **A list of fifteen or fewer is shown whole**, which is the behaviour Ollama
  and the CLIs already had and should never have lost.
- **A longer one shows what you have used**, most recent first, capped at six,
  with whatever is currently in use always present so that switching away from
  it is not a one-way door. No configuration, and correct after the first
  question.
- **"Choose a model…"** opens `ModelPicker`, a search field over everything,
  filtering on id *and* name because people know a model by its vendor path and
  by its marketing name and should not have to guess which the field wants.

A model is recorded as used when it is **chosen**, not when an answer succeeds.
One that turns out not to call tools is still one the user reached for, and
hiding it from the menu would make that failure awkward to retry. `listen
provider model` records it too, or the menu would be wrong for whichever path
you did not use.

### The catalogue had the answer all along

`/v1/models` carries `name`, `created`, `pricing` and `context_length` per
model, and none of it was being read. Using it is most of the difference between
a readable list and a column of vendor paths:

```
Claude Opus 5      anthropic/claude-opus-5   $5.00/Mtok   1000k context
```

**Sorted by `created`, never by name.** Newest first puts the current generation
at the top, which is the only ordering that answers "which of these did somebody
probably mean". `name` is often "Vendor: Model", and the vendor is already
visible in the id underneath, so the half after the colon is the part worth
setting in the larger face.

### The picker is a sheet, and that is a concession

A popover would sit closer to the composer and is what this wanted to be. It
would also have to take first responder for a search field to work, and
`appkit.md` records what that costs in this app: `AskView` already carries a
local event monitor because a click so often goes nowhere. A sheet is
unambiguous about focus, gets Escape for free, and is honest about its weight,
since picking one of 318 things is not a glance.

## A cached catalogue with no clock is a catalogue frozen at launch

`AgentCLI.cache` had no timestamp and no expiry. It was filled once by `warmUp`
and refreshed only by opening Settings › Agent or pressing "Check again". For
the two CLIs that is correct: their models are three aliases that outlive any
release. For a provider it is wrong in a way nobody would notice until they went
looking for a model that was not there.

Listen sits in the menu bar for weeks, and OpenRouter ships models
continuously. Measured across about an hour of this work, its tool-capable count
went from 318 to 319 without anybody doing anything. A list built at launch is
as old as the launch.

`refreshStaleProviders()` re-probes anything past its window, in the background,
and **providers only**. Re-running the CLI half on a timer would mean process
launches and possibly a login shell, which is exactly the freeze
`statuses(_:)` was split in two to avoid.

Two windows, because the two kinds of provider cost different things to ask:

- **Loopback: two minutes.** The probe is a millisecond and never leaves the
  Mac, and `ollama pull` is something people do mid-session and then expect to
  see. Verified with `ollama cp`, which makes a new tag with no download: the
  list went from 4 entries to 5.
- **Hosted: one hour.** A round trip to somebody else's server for a catalogue
  that moves about weekly, so this is already more often than the data changes.

### It has to be checked in two places, and neither is tidy on its own

`updateStatus` is the natural home, and it is event-driven: it runs on every
selection change and after every answer. An app left idle for a week and then
clicked *straight into the model menu* would never have run it, so `chooseModel`
checks too.

**The refresh lands for the next read, not the current one.** A menu that
blocked on the network to open would be a worse bug than one that is
occasionally a few minutes behind, and there is no version of this where a
main-thread caller waits on a provider.

### The cap that shaped a menu outlived the menu

`modelLimit = 30` was applied to every provider except OpenRouter, and it
existed because a pop-up had to list everything it knew. Once the menu showed
recents and `ModelPicker` searched the rest, that cap stopped being a shorter
menu and became models that could not be reached at all: the same complaint that
produced the picker, one provider over. Gone. `modelsCeiling` is a bound on a
malformed answer, not on choice.

The general shape of this mistake is worth keeping: **a limit justified by one
control outlives the control**, and the way to catch it is to ask what the
number is protecting rather than whether it is still a reasonable number.

### `LISTEN_DEBUG=1` prints what was refreshed

A background refresh that works and one that never fires look identical from
outside. Same switch capture state changes use.

## Opening the settings pane ran detection five times, on the main thread

Reported as the whole screen freezing with a spinning cursor, and it was
exactly that. `AgentCLI.chosen()` runs full detection: `--version` and an auth
probe for each CLI, three concurrent `claude` sessions to resolve what the
aliases currently mean, `codex debug models`, and an HTTP probe per provider
with a twenty second ceiling. **Measured at about three seconds a call.**

`AgentPane` called it **once per row** plus once in `fillList`, so four rows was
five detections and roughly fifteen seconds of blocked main thread.

The rule is written on `chosen()` itself and in this file, and it had already
been broken once before, in the Ask pane's status line. It came back the same
way both times: a settings row asking the entirely reasonable question "is this
the one in use?", which happens to be spelled as a function that probes the
world.

Three parts to the fix, and the middle one is the one that lasts:

- `AgentCLI.choose(from:)` is the selection rule as a **pure function over a
  list somebody already has**. `chosen()` and `cachedChosen()` both call it, so
  there is one rule; the pane calls it with `latest`, which detection has just
  produced, and pays nothing.
- `agentReport()` was running detection twice, once directly and once through
  `chosen()`. Measured: `listen ask` with no question went from 6.1s to 3.1s.
- **`statuses()` now writes to stderr when it runs on the main thread.**
  Unconditional rather than behind `LISTEN_DEBUG`, because it can only print
  when there is a bug and the message is the whole diagnosis. Verified: the old
  pane would have printed it five times per open, the new one prints nothing.

The general shape: **a cheap-looking question that is spelled as an expensive
function will be asked in a loop by somebody who does not know that.** The fix
is not vigilance, it is making the cheap spelling available and the expensive
one say so.

## A pane that edited settings by being looked at

Found while checking the freeze fix, and worse than the freeze. Opening
Settings › Ask silently changed the OpenRouter model from
`anthropic/claude-sonnet-5` to `deepseek/deepseek-v4-flash-0731` and pushed that
to the top of the recently-used list. Nothing was clicked.

`NSComboBox` is two controls in one and both of its "the user chose something"
notifications lie:

- `controlTextDidEndEditing` fires when a row is **torn down**, which
  `fillList` does on every refresh.
- `comboBoxSelectionDidChange` fires for a **programmatic** selection, which
  populating the box performs.

So the save path ran on events nobody caused, wrote whatever the box happened
to hold, and then `noteModelUsed` promoted that to the front of recents, which
is how a setting nobody touched became the default for the next question.

The fix is to record what each box held when it was built and refuse to save an
unchanged value. An incidental event carries the string it started with, so it
is ignored; a real edit does not. That is a smaller rule than trying to work out
which notifications are trustworthy, and it does not depend on being right about
AppKit.

**The lesson generalises past combo boxes: a control's "value changed" callback
answers "the value is different from before", not "a person changed it".** Any
save path hanging off one needs its own idea of what the user last saw.

## Ask is its own settings section now

It was in Advanced, beside Devices, on the argument that both were integrations
with something installed and signed into elsewhere. That was true of "drive a
CLI somebody happens to have" and stopped being true: with providers, a model on
this Mac and a key in the Keychain, asking the library is a third thing the app
does. Advanced is for things most people never open.

A group of one, which is `Dictation`'s own arrangement and its own argument. It
sits after Transcription and Dictation because that is the order things happen
in: record it, transcribe it, then ask about it.

And it is called **Ask**, not Agent. The window's mode is Ask, the CLI is
`listen ask`, and "agent" describes two of the four backends: Ollama and
OpenRouter are models Listen drives itself. The settings sidebar was the last
place still using the word.

One thing to know when testing: `LISTEN_PANEL=settings:<name>` matches on the
tab's **title**, so it is `settings:ask` now and `settings:agent` finds nothing
and silently falls back to General.

## The loading state belongs on the control that is about to answer

"Looking for an agent…" sat in the small grey status line under the composer,
which is the wrong place for it twice over. It is a long way from the thing it
describes, and it made the bar change height a second after launch for everybody
whose agent was working, so a normal launch had a visible settling.

The composer's model control is the thing that is about to say which model
answers, so it is the thing that should say it is finding out. It reads
"Loading…" while detection runs, disabled and with its chevron removed, because
a disclosure on a control that cannot be pressed is an offer the app cannot
keep. The status line stays empty.

`updateModelButton` has three states now, and the first two used to be one:

- **`AgentCLI.cached == nil`**, detection has not finished: "Loading…".
- **`cachedChosen() == nil`**, nothing usable: hidden, because `SetupNotice` is
  already up saying it properly and two messages about one problem means the
  small grey one is the one nobody reads.
- Otherwise the model's name, or the backend's when no model is chosen.

The accessibility label stays "Looking for an agent" rather than "Loading",
because a screen reader announcing a bare "Loading" on a button says nothing
about what is loading or why the button will not press.

## History belongs to the two screens that are about conversations

It was in the title bar of every screen except settings: over a meeting page,
over a person's card, over a note. On all of those it is a clock at the top of a
page about something else, offering a list of twenty conversations none of which
is open, next to a transcript it names nothing in.

The two places it says something are the two it is now in:

- **The home page**, which is the library with nothing selected. That screen is
  the greeting, the recent conversations and the composer under them, and it is
  already the one screen in this window that is about asking rather than about a
  document. `LibraryWindow.isHome` is the test, and it asks
  `detailHost.current === detail` as well as `sidebar.selectedRecording == nil`:
  a note or a person picked out of the sidebar leaves the selection nil while
  putting a page on screen, so the selection alone would have called both of
  those home.
- **The chat page**, `chatting`, where History is how you reach the other
  conversations from inside one. That half was already conditional and is
  unchanged.

A conversation opened as a card *over* a meeting keeps its own route regardless:
the drawer's title is a menu with the same rows in it, which is what
`fillHistory(_:forPullDown:)` serves twice.

The cost of making it conditional is a toolbar rebuild, and `sidebar.onSelect`
had a comment explaining why there is deliberately none: five items removed and
re-inserted on every row is a title bar that flickers while somebody reads down
a library. So `syncToolbarWithHome` compares `isHome` against `builtForHome` and
usually returns, and the rebuild happens only on the click that leaves the home
page or comes back to it. `builtForHome` is set in
`toolbarDefaultItemIdentifiers` rather than in `rebuildToolbar`, because AppKit
builds the first set itself and a flag written only by our own rebuilds would
say "not home" about a window that launched on the home page.

Measured through accessibility on the built app, over a scratch `LISTEN_LIBRARY`
of copied sidecars, reading the toolbar's children in each state:

```
home (nothing selected):  Settings  Sidebar  History  Record  Actions
row 1 selected:           Settings  Sidebar           Record  Actions
deselected:               Settings  Sidebar  History  Record  Actions
chat page:                Settings  Sidebar  Done  History  New chat
```

Selecting a **header** row rather than a recording is the trap in testing this:
it deselects, so the toolbar correctly does not change and the run looks like the
change did nothing.

## Try again replaces the attempt, and never appends to the conversation

A failure with no way back to the question is a dead end: the text has already
been cleared out of the composer, so the only route left was to type it again
from memory. `AnswerTurn` grows a **Try again** button beside Save as note,
shown only when the turn ended with a failure and no answer.

What it does is deliberately narrow. The failed answer is dropped from
`chat.turns` before the retry starts, and the same `AnswerTurn` is restarted in
place by `restart(with:)`. So:

- The **question bubble stays.** It was asked once, and asking it again is not
  a second question. Appending instead would leave a duplicate question and a
  red paragraph above an answer that worked.
- The failed attempt leaves **nothing on disk**. Measured on the finished file:
  after fail, retry-while-still-offline, and retry-once-back, `chat.json` holds
  exactly two turns, the question and the answer. A failure is a fact about an
  attempt, not about the conversation.
- Pressing it while still offline fails again and leaves **one** red paragraph
  and **one** button, not a growing stack.

The button disables itself on the way out, because the owner can decline the
press (a run is already going, the agent has gone away since) and a button that
can be pressed four times while nothing visibly happens is how one failed
question becomes four.

**Nothing retries by itself when the connection returns.** Listen knows the
moment it comes back and deliberately does not act on it: a question somebody
has stopped wanting is worse than one they press a button for, and by then they
may have typed a different one.

## Only the last turn may be retried

`AskView.redraw` sets `onRetry` on the last turn and no other, and `AnswerTurn`
hides the button while that closure is nil. A failure halfway up a reopened
conversation is history: re-asking it would put an old question *after*
everything said since and answer it with all of that as context. Verified both
ways against a hand-written `chat.json`: a failed last turn offers the button, a
failed turn with a successful exchange after it offers nothing and still shows
its red paragraph.

## `LISTEN_OFFLINE` also takes a path, because recovery is the interesting half

An environment variable cannot change under a running app, and Try again is
only worth anything when the retry *succeeds*. `LISTEN_OFFLINE=<path>` means
offline for as long as that file exists, so `rm` is the connection coming back,
mid-conversation, with the window still open.

Two traps in driving that test, both of which cost a run each:

- **`make_app.sh` does not build.** It wraps whatever is in `.xcbuild`, so a
  source edit followed by `make_app.sh` packages the *previous* binary. The
  symptom was an app that ignored `LISTEN_OFFLINE` entirely and quietly asked
  the question for real.
- **A second bundle identifier gets Sparkle's "Check for updates
  automatically?" prompt**, which is a modal on top of the window and eats every
  synthesised keystroke, so the composer looked broken. `defaults write
  com.mgo.listen-uitest SUEnableAutomaticChecks -bool false` before launching.

The test app is pinned with `defaults write com.mgo.listen-uitest agentBackend
claude`: the pre-flight refusal lives in `AgentRun`, which only runs the two
CLIs, and the shipped preference is now an endpoint. Testing this against the
default backend tests nothing, which is worth knowing before reading a green
result.

## A conversation you go back to opens as a page

Picking one out of History used to give a card, unless you were already on a
page: `onWantsOpen` read `if extent != .full { extent = .standard }`. On the
home page that is a panel resting over a greeting, which is a card doing the one
thing a card is for, resting over the page it is about, with nothing behind it
that the conversation is about. Reaching for History is asking to *read*
something, and the shape for reading is the page.

So `extent = .full`, unconditionally. It is the one hook that fires on opening a
stored conversation, which is what makes this a single line rather than a rule
four callers have to remember: `AskView.open(_:)` is reached from the History
menu on either screen, the recent list under the greeting, the "Also about this"
link on a meeting, and `LISTEN_CHAT` at launch. All four now land on the page.

**Starting** one is untouched and still belongs to wherever it was started, per
`newConversation`: a question typed over a meeting is about that meeting, and
taking the meeting off screen to ask it would be answering something else.

Driven through the real menu rather than reasoned about, because the extent is
decided three calls away from the click: `AXShowMenu` on the History toolbar
item, `AXPress` on the row, then read the toolbar back. "New chat" with no
Record beside it is the tell, being the swap only the page makes. Before, the
toolbar still had Record and the drawer's title button carried the
conversation's name, over a card 1017 points wide; after, a page of 1097. Note
that `AXShowMenu` needs a retry: it silently did nothing on one run in three
while the window was still settling.

### And that page has no way back, which is the point

`leaveChatItem` collapses a page onto the card it grew from, and a conversation
opened out of History never was a card. Offering it anyway would rest last
week's meeting over today's greeting, which is the state this whole change
exists to remove, so the toolbar leaves the item out: `overACard` is set true by
`toggleFull` and false by `onWantsOpen`, and `LibraryWindow` caches it beside
`chatting` off the same callback.

The comparison in `applyHeight` had to grow a second half. `becamePage` was
`page != pageNow`, and opening a second conversation from History while a page
is already up changes only `overACard`: without `collapsibleNow` the toolbar
would never be rebuilt and the way back would still be sitting there.

**A History-opened page therefore has no route back to the library**, short of
starting another conversation or deleting this one. The sidebar cannot do it
either: `AskView.show` returns early while a conversation is pinned, and opening
one from History pins it. That is the user's call, taken knowingly, and it is
recorded here because it looks exactly like an oversight from the code.

Only the History half is driven. Reaching a card at all now takes a real agent
run, since selecting a recording deliberately gives a fresh conversation, so the
card-grown-into-a-page case is checked by reading rather than by driving.

## The composer cleared the field before the guard, and the follow-up went nowhere

`send` did this, in this order:

```swift
field.stringValue = ""
ask(text)          // guard run == nil else { return }
```

So a question typed while an answer was streaming was wiped out of the field and
then dropped by the guard, in the same runloop pass, with nothing said. Nothing
on screen changed at all, which is why it reads as a keystroke that did not
register rather than as a refusal. The `Return` path was the only way in: the
button becomes Stop while a run is going, so pressing it stopped the answer
instead, and the bug was invisible to anybody who used the button.

The comment three lines below it already recorded this exact swallowing for the
`recording` guard that used to sit there, and that guard was removed for it. The
`run` guard survived because it looks like a legitimate "one at a time" rule,
which it is: the rule is fine and the clearing was the bug.

The order is now **accept, then clear**. `ask` returns `Bool`, `queue` returns
`Bool`, and `send` clears the field only when one of them says it took the text:

```swift
guard isRunning ? queue(text) : ask(text) else { return }
field.stringValue = ""
```

Everything else in this section follows from that one inversion.

## One question waits, and Stop is the way to take it back

**Queueing here cannot mean what it means in Claude Code.** That composer can
splice a message into a turn because the harness owns the agent loop. Listen
owns no loop for two of its three backends: a CLI question is one spawned
process carrying its own `--resume`, and the endpoint backend is one loop over
one question. None of the three can hear a second message mid-answer. So a
queued question is not "the agent has this too", it is "this goes next", and the
whole design follows from being honest about that difference.

- **One slot.** A second Return is refused, the text stays in the field, and the
  line under the composer says why. A stack of questions against a session that
  answers one at a time reads as a batch job, and the third would usually be
  stale or already covered by the second.
- **The bubble carries no control.** The first version put a cross in front of
  the waiting question. It is a second way to say stop, six points from the one
  the composer already has and pointing at something else, and it puts a control
  in a column that is otherwise entirely things somebody said. What is there
  instead is a caption where a timestamp would go: "Waiting for this answer to
  finish", 10pt, tertiary, right-aligned under a bubble at half the usual tint.
- **Stop takes it back**, and hands it to the composer rather than dropping it,
  because somebody pressing Stop is still in the conversation. Every other
  caller of `AskView.stop` is a context change (another meeting, another person,
  another conversation, a new one) and those drop it, because the question was
  about something no longer on screen. That is the whole difference between
  `stop` and `stopAndTidy` for the queue.
- **A failure does not dispatch it.** `finish` only sends the waiting question
  when `outcome.failure == nil`; otherwise it goes back to the composer with a
  line saying so. Firing it into a session that has just failed spends a second
  question on the same broken connection and leaves two red paragraphs where
  there was one problem, and it does it while nobody is necessarily looking. It
  is the same argument `retry` already makes: pressed by a person, or not at all.
- **Nothing about it is persisted.** `chat.json` is the record of what was
  actually asked, and a question that has not been sent is not that.
- **`returnToComposer` only writes into an empty field.** Somebody who has
  started typing something else is owed their own words more, and there is no
  way to hold both without inventing a second place to keep text.

The placeholder is the other half, and it is the only surface left that can say
what Return will do *before* somebody finds out by pressing it: the send button
is the Stop control for exactly as long as queueing is possible, so it cannot
also advertise it. It reads "Ask a follow-up. It goes when this answer finishes…"
while a run is in flight, through `placeholder(for:person:)`, which every site
that sets it now goes through.

Measured on the built app, driven by AX and CGEvent against a scratch library:
the follow-up survives the keystroke and appears as a waiting bubble, the field
clears, a second one is refused with the text left in place, the waiting question
is asked by itself when the first answer lands, and Stop returns it to the
composer with the run cancelled. The one thing the driver could not catch is the
refusal line, which the answer finishing clears a second later; it was read
straight out of the AX tree instead.

## The stop button drew itself as Ask for the whole run

`ask` called `updateSendButton` and *then* `start`, and `run` is set inside
`start`. `isStop = isRunning` therefore read false at the only moment anything
asked, so the button kept the up-arrow for the entire answer, and pressing it
still stopped the run because the press handler reads `isRunning` itself.

It corrected itself the moment anybody typed, because `controlTextDidChange`
asks again, which is exactly the case that used to be impossible to reach: the
field was cleared before the run started and a follow-up was swallowed, so a
pane nobody typed into while it worked was the only pane there was. Both calls
are kept, before and after `start`, in `ask` and in `retry`.

`SendButton` also grew `accessibilityPerformPress`. It is an `NSView` with a
`mouseDown` and it had already declared itself a button with a label, so it
announced a control that only a mouse could use. Survivable while Stop only
stopped; not survivable now that Stop is also how a waiting question is taken
back, which would have made that a pointer-only route. Pressed through AX in the
verification above, which is the same call VoiceOver makes.

## Every control on the Ask surfaces was silent until it was pressed

AppKit gives a bezelled push button a resting shape, a pressed state and a focus
ring for nothing, and gives a borderless one none of those. Every control on
these two screens is borderless, because they float over a meeting and a row of
grey bezels would be a toolbar lying on the page, so all of them had the same
problem at once: the model chooser, the send disc, the drawer's title, cross,
resize and new-conversation buttons, the disclosure on an answer, and the recent
conversations under the greeting, which are links in a text view and were the
accent colour and nothing else.

The two bezelled ones went the same way, because being a real push button turned
out not to be enough. Save as note and Try again *look* pressable and still
answer nothing until they are clicked, and they sit under an answer among things
that now do, which made them the quiet pair on the page.

`HoverButton` in `Hover.swift` is the shared half. It is `HoverRow` for a button
rather than a row, and the alphas are deliberately the same ones, so a chip and
a sidebar row light up by the same amount. Two looks:

- `.ink`, for a word or a glyph in a line of text, where a filled rectangle
  would read as a second object. The tint moves one step up, `secondaryLabel` to
  `label`, and never changes hue: a control that changes colour on hover reads
  as a state change rather than as a target.
- `.fill(idle:)`, for a control that is already a shape. `idle` is what is drawn
  when nothing is near it, which is 0.08 for the starter chips, because they are
  objects on the page, and zero for the drawer's glass discs, which already are
  one.

Four things that had to change to let it in:

**The chips are drawn rather than bezelled.** They were `.rounded` and
`controlSize = .large`, and a bordered `NSButton` draws its bezel over anything
the layer holds, so there is no way to add a hover to that shape from outside
it. 26 points tall with 13 either side is what the bezel measured, so the row it
sits in did not move. `ChipButton` is the shape, and the starter chips, Save as
note and Try again are all it: the same object with different words in it, which
is what it was already true to say about them before any of them could be
hovered.

`ChipButton` owns its label rather than setting `title`, and that is not tidiness
either. Save as note relabels itself to "Saved" with a checkmark the moment it is
pressed, which is the whole of how that press is confirmed, and it disables
itself so one answer cannot become two notes. **AppKit greys a disabled button's
plain title and leaves an attributed one alone**, so the spent chip read as a
live one. The width is ours for the same reason: the capsule is measured from
the title, and a checkmark added afterwards would be drawn into padding nobody
asked for.

**The three disc buttons are the disc.** Sized to their symbol they were a 14
point target inside a 30 point circle, so half of what looks like the control
did nothing, and a fill drawn by the button would have been a small blob
floating inside the glass rather than the disc lighting up.

**The send disc lightens rather than deepens.** It is already at full alpha when
it is live, so hover cannot be more of the accent: it is 16% white mixed into
it, which is the one direction left. Dimmed, it does not light up at all,
because pressing it then does nothing, and a control that answers a hover and
then ignores the click is worse than one that never answered.

**A reference card underlines its verb, not itself.** The whole card is the
button, so the obvious answer is a wash over all of it, and it is the wrong one:
three lines of that card are a title, a date and a list of speakers, none of
which goes anywhere on its own. "Open recording ›" is the line that names the
destination, so it takes the underline every other link in this app takes, and
the card keeps the pointing hand it already had. `ClickableCard` reports the
hover and `ReferenceCard.lightOpen` decides what it looks like, because the ink
belongs to the contents rather than to the frame.

`LISTEN_DEBUG=1` traces every hover in and out with the alpha it asked for and
the colour that actually resolved. That is not decoration either: the sidebar's
highlight shipped broken three times because a hover that draws nothing and a
hover that never fires are the same screenshot, and the fault was a colour that
changed no pixels in a vibrant appearance. `hoverTint` is the fix for that, and
the trace is how to tell which half is at fault in one run.

## The meeting being recorded has no composer

The card sat over the bottom of the recording screen, which is the one page
whose bottom edge is already spoken for: the two meters and the device row live
there, and "Ask about this meeting…" was drawn across the strip that says
whether your own voice is arriving. It was also offering something that cannot
happen yet, because nothing is transcribed until Stop.

`LibraryWindow.updateComposer` is the one owner of `showsComposer` now. It used
to be a single line inside `enter` reading `next != .settings`, and two screens
have no composer rather than one. The second is not a mode, it is a page, so the
test is the page and never `Capture.isRecording`: clicking away to read
yesterday's call while today's records keeps its composer, because that meeting
is finished and the question is about the one on screen. Called from a mode
change, a click in any of the three lists, `reload`, and both edges of capture.
`Recording.isLive` reads capture rather than a flag written when the screen was
built, so it goes false as Stop is pressed and the composer comes back on the
same meeting at the first moment there is anything to ask about.

**The extent survives the drawer going away, and that was a blank window.**
`applyHeight` hides the pane underneath while the conversation is a page
(`content.view.isHidden = page`), and nothing in either path that takes the
composer away puts the extent back to a bar. Leaving a conversation at full and
then opening Settings, or starting a recording, therefore hid the drawer and
left the pane hidden with it: a window with nothing in it and no error anywhere.
`page && showsComposer` is the fix, and it is the same sentence the two
callbacks at the end of that method already make, that nothing is covered and
nothing is a page while the drawer is away.

**`LISTEN_PANEL=live` has to say it itself.** The preview drives the recording
screen from a finished recording in the library, so `isLive` is false there and
every honest test of it says the composer belongs. It sets `showsComposer =
false` directly, next to the line that already makes the toolbar button read
Stop, and for the same reason: the one way to look at this screen without
holding a meeting must not be a picture of a state the app is never in.

Measured on the built app against a scratch `LISTEN_LIBRARY`, with File › New
Recording pressed through `AXUIElementCreateApplication(pid)` and `LISTEN_SHOT`
every 5 seconds. During the 8 second recording the bottom of the window is the
two meters and the device row with nothing over them; after Stop the same
meeting has its player, its transcript and the composer back.

## Delete is a verb on the conversation, so it is not on History

History is the list you open to get *back into* a conversation, and every row on
it opens one. Delete sat at the foot of that list, one place below rows that
read almost the same and do the opposite, which is the second time it has been
on the wrong menu: before that it was a submenu naming every conversation, and
that failed on its own data, because a conversation is titled by the first
question asked in it and the same question gets asked of different meetings, so
the list came out as four rows of which two pairs were identical.

Both failures are the same mistake. The chat page had no menu of its own, so the
one destructive thing you can do to a conversation went wherever there was room.
Every other screen in this window already has the place for it: an ellipsis at
the trailing end of the toolbar, holding the verbs on what is on screen. The
library has one about the selected recording, a person's card has one about
them, and `chatActionsItem` is the third. It goes after `newChatItem` because
the common move is read first everywhere else here.

The item is "Delete", `trash`, `NSColor.systemRed`, character for character the
recording's and the person's. It was briefly "Delete this conversation" with no
glyph in the label colour, and a fourth spelling of one decision makes it read
as a different kind of decision.

It parts company with those two on the alert: there isn't one. A conversation is
working-out rather than evidence, what it throws away is a question you can ask
again, and anything worth keeping was already saved as a note.

**The empty state is a sentence, not a dimmed Delete.** New chat on a page
leaves the page up with nothing in it, so this menu opens over no conversation,
and an attributed title's colour wins over the disabled look (`appkit.md` records
that against `contentTintColor`): the greyed-out item came out in full red and
read as live. So it is "No conversation", disabled, which is the row the
recording menu already puts up as "No recording selected".

Two traps carried over from `fillHistory` rather than rediscovered:
`NSMenuToolbarItem` eats item 0, so `fillChatActions` takes the same
`forPullDown` flag; and `autoenablesItems` is off, or `NSMenu` lights the item
back up from the responder chain. The menu is held on `DetailWithComposer` for
the reason `historyMenu` is: the toolbar rebuilds its items whenever the page is
entered or left, and `menuNeedsUpdate` tells the two apart by identity.

Measured on the built app against a scratch `LISTEN_LIBRARY` holding one seeded
`chats/seed.json`, driven through `AXUIElementCreateApplication(pid)`. History
opens with New conversation, a day heading and the conversation, and no delete
row. Opening it puts up the page toolbar as `History  New chat  Actions`, whose
menu is one enabled `Delete`; pressing it takes the file off disk and the
toolbar goes back to the library's. After New chat the same menu is one disabled
`No conversation`.

## The status line holds its slot, so a message never moves the composer

The small grey line under the composer is where the pane says what is true right
now: no internet connection, a question already waiting behind the running
answer, a note written, an answer that failed. Its height constraint was zero
until there was something to say, and the well hangs off the label's top
(`composer.bottom == status.top - 6`), so every one of those messages lifted the
composer 14 points and dropped it back when the message went.

That is the wrong way round. The composer is where the caret is and what the
pointer is aiming at, and all four of those messages arrive mid-question: they
are the exact moments the target must not move. A line of 10 point tertiary text
is worth less than the field staying still under a hand that is about to press
send.

So the 14 points are held whether or not anything is in them. `say` sets the
string and nothing else, and the label is positioned against the well rather
than the well against the label, which is what "absolutely positioned" means in
a layout that has no absolute positions.

It costs an empty 14 point strip under an idle composer, and it is a number the
pane had already committed to. `barHeight` has always been `ComposerWell.height
+ 6 + 14 + 12`, so the drawer's bar was sized for a line that was usually not
there; before this the slack went to the scroll view above the invitation, and
now the layout agrees with the number it reports. The two are one
`Self.statusHeight`, so they cannot disagree again.

Measured on the built app against an empty scratch `LISTEN_LIBRARY`, launched
twice with `LISTEN_PANEL=ask` and read through
`AXUIElementCreateApplication(pid)`. With and without `LISTEN_OFFLINE=1` the
field is at y=907 and the send button at y=900, and the only difference between
the two trees is the label's own string. Both runs are of the fixed build: the
14 points the empty case used to sit lower by are the label's height constraint,
not a second measurement.

## The bar's height has to count every gap, and the status line proved it did not

`barHeight` is what the drawer is told to be when the conversation is a bar, and
it was `ComposerWell.height + 6 + 14 + 12` plus the starters row and 8. That sum
is 14 points less than the constraints inside the pane require, and it worked
for as long as the status label was zero high with nothing to say: the label's
missing 14 was quietly paying for the gap above the starters, which is the
hidden scroll view's height.

Holding the status line's slot open spent the same 14 points twice. The pane was
then solved 14 short of its own contents, and what gave way was the top: the
starter chips came out flat against the drawer's top edge with nothing above
them, on the surface where they are the first thing anybody reads. Nothing was
logged, because a hidden scroll view has no intrinsic height to complain with.

So the sum is now written the way the constraints are, floor to ceiling: the
pane's 12 point inset inside the drawer, 6 under the status line, the line, 6
above it, the well, and 8 over the starters. `paneBottomInset` names the 12,
which is `DetailWithComposer`'s number and the reason this is a height for the
drawer rather than for the view reporting it.

Measured on the built app over a scratch `LISTEN_LIBRARY`, through
`AXUIElementCreateApplication(pid)`: with the composer focused over a meeting,
the chips report y=843 and the drawer's top edge is at 835, so the 8 points are
there and the row is even with the 8 below it. No constraint conflicts in the
run's stderr, which is the other half of the check: the old arithmetic was
resolved silently rather than reported.

## The library composer has four starters of its own, and so does a person

Clicking into the composer on the library screen drew a well and an empty frame.
The guard in `drawStarters` was `recording != nil`, which is right about
"Summarise" and wrong about the screen it left bare: the home page is where
somebody has the least idea what can be asked, and it was the one page that
offered no answer to that.

The four are not the meeting four a level up. A question about one meeting has
its answer in one transcript; a question about the library only earns the trip if
it crosses meetings, so these are the four shapes that do: `Catch me up`, `Open
items`, `Decisions`, `Recurring themes`. Summarising a library is summarising
nothing, so there is no `Summarise`.

Each prompt names its own window ("the last week", "the last two weeks", "the
last month") and asks for the meetings to be cited. Both are for the agent
rather than for the reader: the brief in `Agent.swift` is a retrieval ladder,
and the first thing an unbounded library question costs is a round trip spent
deciding how much to read.

A person was left out for a while longer, on the argument that a pane narrowed
to one name has a question in it already. That was the library's own mistake made
a second time: knowing *who* the pane is about is not knowing what it can be
asked, and somebody standing on a card that lists three calls has no way of
guessing that "what do I still owe them" is one of the things it answers.

So a person gets four too, built per name by `AskView.personStarters(for:)`:
`Catch me up`, `Open items`, `Next call`, `Their views`. They are the shapes only
a person makes answerable, which is what keeps them off the other two lists.
There is no `Summarise` for the library's reason, and no `Decisions` either: a
decision belongs to the meeting it was taken in rather than to one of the people
who were in it.

The prompts interpolate the name rather than leaning on the `About the person …`
sentence `start` prefixes on. That prefix is only added to an *opening* turn, so a
chip whose own text says who this is about is the one that still reads correctly
when the turn is retried, resumed from History, or edited into a follow-up. Each
one asks for the meeting behind a claim, for the reason the library four do.

Measured on the built app over a scratch `LISTEN_LIBRARY` of five sidecar-only
recordings, driven through `AXUIElementCreateApplication(pid)`: typing `Joris
Goossens` into the search field and selecting the Person row puts `Ask about
Joris Goossens…` on the composer, and the buttons on screen at that point are
`cancel, Person, Recordings, Person, Sonnet 5, Ask, Settings, Sidebar, Record`,
with no chips. Focusing the field adds `Catch me up, Open items, Next call, Their
views`, and pressing `Open items` puts `Go through my recordings with Joris
Goossens and list what is still outstanding between us: …` on the page as the
question. The meeting four (`Summarise, Action items, Decisions, Catch me up`)
and the library four are unchanged in the same run.

## A conversation full width is a mode, and the sidebar under it was live

Reading a conversation full width used to be a third size of the composer
drawer, `extent == .full`. The drawer covered the content pane and `applyHeight`
hid what was under it, and the sidebar beside it went on being the recording
list.

So a click in that list did happen: `sidebar.onSelect` ran, `detail.show` ran,
and the recording it drew was in a view with `isHidden = true`. Nothing on
screen moved, and the row highlighted itself under a page that was still the
conversation. Reported as "some routing issue", which is exactly what it looked
like from outside. The same swallowing hit every numbered reference in an
answer, because `ReferencePopover` opens a recording through
`LibraryWindow.open(recording:)`, which ends in that same selection.

It was not fixable by making the click leave the page, because the click has two
honest readings. `AskView.show` returns early for a pinned conversation, so the
selection moved the context and kept the conversation; unpinned it threw the
conversation away and *still* left the page up, now empty. One gesture, two
outcomes, neither of them on screen.

The page is `Mode.chat` now, beside `.settings`, `.people` and `.notes`. The
sidebar holds `ChatNav`, the masthead says "Chats", and the collapse control's
slot holds Back, which is settings' shape exactly and for settings' reason: the
list is the only navigation the screen has, so it is locked open and a control
that would always be disabled is not drawn. There is no recording list under the
page to swallow anything, because the list under the page is the conversations.

What the drawer keeps is its other two sizes. A card resting over the meeting it
is about is still the right shape for asking about that meeting, and `standard`
is untouched.

Measured on the built app over a scratch `LISTEN_LIBRARY` holding real `chats/`
and sidecar-only recordings, driven through `AXUIElementCreateApplication(pid)`:
pressing Chats swaps the toolbar from `Listen, Settings, Sidebar, Chats, Record,
Actions` to `Chats, Back, New chat, Actions`, and the sidebar table reads `Today
/ who are the top 2 people i spoke to last month / 10:26 · 7 questions ·
Kinsight catchup wiht Edgar / …`. Back restores both.

## The list is the sidebar, and History is what this page was asked

`fillHistory` listed every conversation in the library from whatever screen you
were on, and the note above it in this file argues for exactly that: a history
that hides most of itself depending on the page is a history you cannot trust.
That argument was about a menu that was the only route into any conversation.

It is not the only route any more, so the same control is free to answer the
narrower question the page it sits on actually raises. The toolbar's History is
now the conversations about the meeting selected (`Chat.about`), or about the
person whose card is open (`chat.person`), with "All conversations…" as the last
row, which enters the mode. The card's own title menu shows the same rows, since
they are the same question asked from two controls six points apart, and one
screen with two histories that disagree is worse than either.

It is uncapped where the flat list took twenty: a source has as many
conversations as somebody asked about it, which is single figures, and the
oldest may be the one being looked for.

Both menu traps still apply and are still paid for the same way: the pull-down
copy prepends a bare item because `NSMenuToolbarItem` eats item 0, and
`autoenablesItems` is off or `NSMenu` brings the day headings back as live rows.

A note gets no such menu. `Chat` records the recordings and the person a
question was about and has no field for a note, so a note page could only be
scoped by the meetings underneath it, which is a different claim wearing the same
words. The Notes collection therefore has no route into chat mode at all, which
is the cost of that and is taken deliberately.

## Where Back goes is where the conversation came from

Chat mode is reachable from the home page, from a meeting whose card was grown
by its resize disc, and from a person's card, so "back to the library" would be
wrong exactly when somebody was reading a conversation about the meeting they
were on. `enter(.chat)` records the mode it left in `chatReturn` and Back returns
to it.

`overACard` survives, with one job instead of two. It used to decide whether
there was a way out **at all**: the way back was a toolbar item that collapsed
the page onto its card, and a conversation opened from History had never been a
card, so it had no item, and no route to the library short of starting another
conversation or deleting this one. That hole is what the routing report ran
into. A mode has a Back button however it was entered, so `overACard` is left
deciding only where the drawer lands: over the meeting as a card, or as a bar.

Two rules on the way down, both about not losing work:

- **A running answer is never cancelled by leaving.** `composer.isRunning` puts
  the drawer down as a card rather than a bar, because a bar is what a fresh
  conversation is and getting there means `startNew`, which cancels the run. A
  forty-second answer thrown away by a click is the one loss on this path that
  reopening the conversation cannot undo.
- **Otherwise the conversation is let go, exactly as the cross lets it go.** Left
  loaded in a bar it would silently continue under a placeholder offering to
  answer about the meeting now on screen. Nothing is lost: it is the first row of
  the list one press of Chats away.

`leavePage(keepingCard:)` takes the flag rather than working it out, because the
window knows *why* it is leaving: Back is a return, and a reference clicked in an
answer is somebody asking for a different page, which must not arrive under a
card about the conversation they just left.

`LISTEN_CHAT=<id>` moved with all this. It used to open inside `build()`, which
is called *by* `show()`, and `show()` enters the library on the next line: the
conversation came up as a page and was put straight back down. It is recorded in
`launchChat` and opened at the end of `show()` instead, and `shootIfAsked` no
longer reveals a recording when it is set, since that is a navigation straight
back out of the thing being photographed.

## The meeting being recorded has no History either, and the toolbar had to be told twice

The same rule the composer already follows on that screen, and the same reason:
nothing is transcribed until Stop, so there is nothing to have asked about the
meeting being recorded and nothing that could be asked. The menu could only ever
open onto "Nothing asked about this meeting yet", next to the one control in the
window that must never be hunted for.

`isShowingLiveMeeting` names the test once and both callers use it:
`updateComposer` to take the drawer away, and `modeItemIdentifiers` to leave both
of the conversation controls out.

Leaving them out is half the fix. `syncToolbarWithHome` rebuilds only when what
is open changed which items belong, and it compared one bit, `isHome`. Clicking
from the meeting being recorded to yesterday's call changes neither the mode nor
that bit, so History would have stayed missing for the rest of the session. The
comparison is a `ContentShape` of the two bits that matter now, home and live.
The capture edges themselves were already safe: that handler ends in an
unconditional `rebuildToolbar()`, after the live recording has been selected.

Not verified by recording. Doing that means a second Listen opening the
microphone and the process tap on a Mac that is often already in a meeting, and
the rule is the one `updateComposer` has been making correctly on that screen all
along.

## The search field belongs where the list it swaps with keeps its own

`ChatNav` has no `CollectionPicker` above its search field, because the
conversations are not a fourth collection of the library. What went with the
picker was the 76 points it was paying for, and the field went to the top of the
pane: the window has a transparent full-size title bar, so it came up behind the
traffic lights, the word "Chats" and the Back button, all four drawn over each
other.

Stating 76 by hand fixed the overlap and was still wrong. That is what People and
Notes spend, because they have a picker (42 to clear the title bar, its own 24,
and 10 under it), and the list this one *swaps with* is the recordings list,
which has no picker either and states 42. Matching the wrong pair put the field a
control's height lower than the list it replaces, which reads as a jump the
moment you press Back.

So: 42, and the two lists' first rows are on one line. Measured through
accessibility on the built app, with the window at y=33: both search fields at
(17, 82), 272 by 26.
## An empty page needs the greeting the home page has

Chat mode with nothing open was a composer at the foot of a window-high
emptiness, which reads as a page that failed to load. The library's home page
answers exactly this moment with the mascot, "What's cooking, <name>?" and a line
saying what to do, and a second answer to it in another visual language would say
the two screens are different kinds of place.

`AskView.welcome` is that block: the same 64 point mascot, the same 26 point
semibold greeting and 13 point secondary line, the same 16 and 14 between them,
all taken from `DetailView` rather than invented. Not the same code, because that
one is the empty state of the pane a page hides.

It is a subview of the pane centred on the scroll view, not a row in the stack of
turns: in the stack it would sit at the top of a page whose whole point is that
there are no turns. Shown only when `isPage && !hasConversation`, so a card and a
bar never draw it and the first question takes it away. `redraw` is the hook,
which is also what brings it back on New chat.

The wording differs by one clause. The home page says "Select something from the
list, or ask about your library below" about the recordings; this says "Pick up a
conversation from the list", because that is what is in the sidebar beside it.

## The chats home page is the library's home page, and three numbers said otherwise

Both screens are a greeting over a composer with a list beside them, and the
difference is meant to be which list. Three things made the chat mode's read as a
different app, and all three are measured against the other screen rather than
chosen:

- **A scroll bar down the right-hand edge.** On a page `AskView`'s scroll view
  reaches both edges of the window, and a Mac set to show scroll bars always
  draws the track whether or not anything scrolls. A greeting and a composer do
  not. `autohidesScrollers` on that view and on `ChatNav`'s, which had the same
  full-height track down a list of nine conversations that fits twice over. The
  recordings list is deliberately left alone: it overflows, and its bar has a
  thumb in it that means something.
- **A 620 point composer in the middle of a 1512 point window.** The column
  exists so a line of an answer is readable and so the well lines up with the
  text above it. An empty page has neither, so it takes the width the same
  composer has on every other screen: `pageWide`, 40 points either side, which is
  the drawer's 16 plus this pane's 24, both of which go to zero on a page and are
  spent here instead.
- **The search field, one control's height too low.** See the note above.

`applyWidths` is what picks between the three sets, and it runs on `redraw` as
well as on `setPage`, because the third state depends on whether there are any
turns: asking the first question on the chats home page is exactly the moment the
composer stops being the home page's and becomes the conversation's. Everything
off before anything on, or two width constraints on one view are a conflict the
solver resolves by guessing.

Measured through accessibility on the built app, window (0, 33, 1512, 949). The
library home page and the chats page agree to the point: search field at (17, 82)
272 by 26 on both, composer field at (359, 893) 981 by 21 on both, and the only
scroll bar in either is the recordings list's.

## The toolbar's History is gone, and the menu under the card is the one that stays

Three controls opened onto one set of rows. `ChatNav` is the list, the card's own
title menu asks "what else did I ask here" from six points above where a question
is typed, and the toolbar's History asked the same thing from the far corner of
the window, on top of a note's, a person's or a meeting's own heading. That
corner is the first thing read on a page, and what belonged there was the page's
title rather than a clock about the conversations beside it.

So `historyItem` is gone, with `sourceHistoryMenu` and `fillSourceHistory`.
`appendSourceHistory` stays, because the title menu fills itself from it, and
`chatsItem` stays on the home page: that screen is about asking rather than about
a document, and "take me to my conversations" is the question it should answer.
Nothing else in the library, People included, has a control in that slot now.

`appendSourceHistory` gained one branch on the way past. It read the person off
`peopleNav` when `mode == .people`, which was the only way to a card when it was
written; a person picked out of the one list is `.library` with
`sidebar.selectedPerson` set, and on that screen the menu answered "Nothing asked
about this page yet" over somebody with a stack of conversations naming them.

Measured through accessibility on the built app: the toolbar reads Settings,
Sidebar, Chats, Record, Actions on the home page and Settings, Sidebar, Record,
Actions with a page open, where it used to carry History in both.

## "Install with npm" under an installed CLI reads as "not installed"

The settings row for a CLI that is installed and signed out printed
`installHint`, whose first words are "Install with `npm install …`". The
version and the path were on the line above, so to a developer the row was
complete; to anybody else it read as "not installed", and the first outside
install's owner concluded exactly that about a Mac that had `claude` 2.1.212
at `~/.local/bin` the whole time. The Claude desktop app puts the CLI there,
so installed-and-never-signed-in is the normal state on a non-developer's
Mac, not an edge case. `signInHint` now exists beside `installHint` and the
row for a signed-out CLI leads with "Installed. Run … and sign in".
`verify_ask_states.sh` pins both: the sign-in sentence present, "npm install"
absent.

## An unknown sign-in state was trusted for the life of the process

`usable` treats `signedIn == nil` as usable on purpose ("it will find out on
the first question"), but nothing ever re-asked: a probe that came back
unknown at launch stayed unknown until quit, so the composer chip named a
backend all day on a Mac where nobody had ever signed in, and the first
question failed on credentials. Two corrections, neither touching the benefit
of the doubt itself. `refreshStaleProviders` now re-probes any CLI whose
cached sign-in is nil, on a five-minute clock, and only the unknowns: a
resolved yes or no stays put, and "Check again" stays the way to re-ask
those. And a run that fails with sign-in-shaped text (`looksSignedOut`, prose
matching, deliberately narrow) corrects the cache through `noteSignedOut`
before `finish` runs `updateStatus`, so the setup card with the sign-in
command replaces the offer of a second identical failure. The end-to-end
case is in `verify_ask_states.sh`: a stub CLI that probes signed-in and then
refuses the run puts the card up.

## Ask setup is a choice, and the settings pane only ever stated facts

A Mac with the Claude app, no signed-in CLI and no provider showed accurate
facts on every surface and no path from "I want to ask about my meetings" to
a working composer. `AskSetupWizard` is the path: one sheet, four cards
(OpenRouter as the iPhone pairing, the CLIs, the Claude app, Ollama), each
stating its trade-off in the card body per the copy rule, ending on the same
test question the Agent pane uses so setup finishes on a real answer rather
than on "saved". It is reachable from the setup card's "Set up Ask…" and from
Settings › Ask, and deliberately not from first-run onboarding. It owns no
storage: every write goes through `Settings.addProvider`, `AgentKey.save`,
`Settings.agentChoice`, `Settings.setAgentModel`, so cancelling writes
nothing (asserted in `verify_ask_states.sh`). Picking OpenRouter sets
`agentChoice` explicitly, because automatic prefers a CLI and the Claude
app's signed-out `claude` on disk would outrank the provider the sheet just
finished setting up.

## The provider migration reads the Keychain, and an ad-hoc copy hangs on it

`Settings.providers` runs a one-time migration whose evidence check is
`AgentKey.has("openrouter.ai")`, a Keychain read. On the uitest bundle copy
that read raises the blocking permission prompt CLAUDE.md warns about, inside
`AgentCLI.statuses()`, so detection never finishes and the composer chip says
"Loading…" until a human answers a dialog. Measured with `sample`: the
cooperative thread sat in `Settings.migrateProviders`. The verify scripts
pre-plant `agentProviders` as `[]` (`defaults write … -data 5b5d`) so the
migration is already done and no Keychain is touched. The same shape applies
to any future launch-path Keychain read: on an ad-hoc copy it is a modal
prompt, not a lookup.

## The wizard's save path is not scripted, and the reason is the Keychain service

`AgentKey` stores every key under the one service `com.mgo.listen.endpoint`
with the host as the account, and `save` is delete-then-add. A verify script
driving the wizard's OpenRouter card with a fake key would therefore delete
the real OpenRouter key of whoever runs it. So `verify_ask_states.sh` drives
the wizard up to and around the save (opens from both entry points, options
laid out, cancel writes nothing) and leaves the save itself to the one-line
calls it makes into machinery the settings pane already exercises.


## Ask is off until somebody turns it on, and onboarding is where they are asked

Everything else in Listen works on a Mac that has configured nothing. Ask needs
a CLI installed and signed into, or a URL and a key, and until that is done
there is nothing for it to do. What it contributed to a first run was a
composer that could not answer, a card explaining why, and a Chats screen with
nothing in it, on top of a library that had no recordings yet either.

Reported from the first install on somebody else's Mac, in those terms: the
setup card was the largest thing on the home screen before there was a single
recording, and it was asking for a decision about a feature nobody had gone
looking for. The card's own copy assumed the reader already knew what Ask was
and led with what it *needed*.

So `Settings.askEnabled` gates the whole surface, off by default, and three
things move together through `LibraryWindow.askEnabledChanged`: the composer
drawer, the Chats toolbar item and the Chats menu row. Off for existing
installs too, which is deliberate rather than a gap in the migration: reading a
usable agent as consent would make the flag say "somebody chose this" for
people who never did, and it is one checkbox to turn back on.

**Selling it is the onboarding step's job, not a card's.** `Onboarding.Step.ask`
sits after dictation and is optional the way the calendar step is: value first,
in the words somebody would use themselves, then the cost, then a "Not now"
that costs nothing. It turns the switch on and leaves choosing a backend to the
card or to Settings, because `AskSetupWizard.present` needs
`LibraryWindow.sheetHost` and there is no library window during a first run.

That leaves the card one honest job, which is a person who said yes and has
nothing answering yet. It says so and stops selling.

## The setup card stands alone, and takes the composer's place rather than sitting over it

The card used to sit above a live "Ask about your library…" inside the drawer's
own rounded panel: a card in a card, offering a field that was known to be
unable to answer before anything was typed. It also drew its own border, a few
points inside the drawer's.

Now `showNotice` is the single call that swaps them. It hides the starter
chips, the composer well and the status line, and zeroes the well's and the
line's height constraints, because hiding a view leaves its constraints active
and the space with them. The card's own border is gone; the drawer's panel is
its frame.

Two buttons and not three. The third was "Check again", which re-ran detection
in place; it is inside the wizard as well, under the option it applies to, and
a card with three calls to action asks the reader to choose between them before
they have decided anything. The way out is "Not now", which turns Ask off
rather than hiding only the card: hiding the card alone would leave a composer
that cannot answer with nothing on screen saying why, which is the state the
card exists to prevent.


## The cross's `putAway` was inverted, and the bug it was chased for is still open

`closeConversation` set `putAway = false`. That contradicts `putAway`'s own
definition, "set when somebody collapses on purpose", the sentence above the
method saying a cross that reopens what it closed would be a lie about which of
the two it is, and `leavePage`, which sets it and names this method as its
reason. Clearing it disarms the guard in `applyHeight`, which re-expands a bar
whose `wantedHeight` is over `barCeiling`. It is now `true`.

**Corrected by reading, not by reproducing.** It was found chasing a report of
an Ask panel that opened itself after a recording and would not close, and it
is not known to be that bug. Three reproductions were built and measured, and
all three pass on 0.24.1, which is the build that shipped the symptom:

- a real conversation closed with the cross (`verify_ask_close.sh`)
- the setup card with no agent configured
- Chats mode with nothing in it

The last two never put the card's header on screen at all, on either build, so
there was no cross to press. What the first one showed is why the old line was
mostly harmless: `closeConversation` empties the composer before it collapses,
so the height reported next is an empty one and stays under the ceiling. What
is not established is that every path leaves it empty.

**So the reported symptom is still open**, and what is missing is the state it
happened in rather than more guesses. Worth asking for: whether the panel
covered the whole meeting page, and what was pressed just before it appeared.

## What could not be verified: the download stall

`ModelChoice.inFlightBytes` following its temp file through a stall is reasoned
from the reported reading (`41 KB of 2,47 GB`, which is exactly the two JSON
files in the hub cache) and not reproduced. Two attempts failed and both are
worth not repeating:

- Ageing the temp file's mtime past the ten second window does nothing,
  because URLSession is still writing to it and refreshes the mtime within a
  second. A test built on this passes on 0.24.1 as well, so it measures
  nothing, and it was deleted rather than kept.
- Suspending the process stops the poll as well as the writer, so there is
  nothing on screen to read.

A real stall needs the network taken away for more than ten seconds while the
transfer stays open. Until somebody arranges that, the fix stands on the code
rather than on a measurement.
