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

## `delete_note` is on neither tool list

The server offers it, because the CLI and a human at an MCP client should be
able to undo a note. An agent answering a question in a chat box should not,
and the asymmetry is the point: everything else it can write is reversible by
hand in the window, and a deleted note is not.

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
`cachedChosen() == nil` are different states with different sentences: "Looking
for Claude Code or Codex…" and "No agent is set up."

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
