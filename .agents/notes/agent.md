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

Delete is one item at the foot and it acts on the **open** conversation, so the
rows above it only ever open. It was briefly a submenu naming every
conversation, and that failed on its own data: a conversation is titled by the
first question asked in it, the same question gets asked of different meetings,
and the list came out as four rows of which two pairs were identical. A delete
you cannot aim is worse than no delete, and it doubled the length of a menu
whose job is to get you back into a conversation with a second copy of the same
list doing the opposite.

Deleting a different one is still reachable and costs one more move: open it,
then delete it. That is the right price for the destructive half of a control
whose other half is one click, and it is why the item is disabled rather than
absent when nothing is open, so the menu keeps its shape.

It does not ask twice: a conversation is working-out rather than evidence, and
anything worth keeping was already saved as a note.

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
