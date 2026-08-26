# Listen: working notes for coding agents

Local meeting recorder, transcriber and speaker labeller for macOS. Pure Swift,
fully local. Read `README.md` for user-facing behaviour and `SPEC.md` for the
brief. This file is about working on the code without re-learning things the
hard way.

Speak (`../speak`, https://mugoosse.github.io/speak/) is the template. Its
`CLAUDE.md` is a list of traps already paid for and most of them still apply
here; this file records the ones that are Listen's own. Anywhere Speak is named
in user-facing copy it gets that link, because a reader who does not have it
cannot act on the sentence otherwise.

## Build and run

**`swift build` does not produce a working binary.** It links, then dies at
runtime with `Failed to load the default metallib`, because SwiftPM never
compiles MLX's Metal kernels. Always use the scripts:

```sh
./build.sh      # xcodebuild wrapper, checks the Metal toolchain first
./make_app.sh   # wraps the binary in a signed .app
./install.sh    # both, then installs to /Applications and relaunches
```

One-time setup on a new machine:

```sh
xcodebuild -downloadComponent MetalToolchain    # ~688 MB, separate in Xcode 26
```

`-skipPackagePluginValidation` is required because mlx-swift ships a `CudaBuild`
plugin Xcode refuses to run unattended. It is a no-op on Apple Silicon.

### Verifying a change without the GUI

```sh
Listen.app/Contents/MacOS/Listen transcribe some.wav
Listen.app/Contents/MacOS/Listen transcribe some.wav --format json   # timings
```

Needs no permissions, so it separates a model problem from a capture problem
before anyone touches UI code. `--format json` is the one that shows timings,
which is what most questions about the pipeline are really about.

`LISTEN_DEBUG=1` traces capture state changes to stderr.
`LISTEN_CHUNK=<seconds>` overrides the ASR chunk length; `0` means decode the
whole file in one pass. It exists for measurement, not for users.

### The scheme has to exist before the first build

The first `./build.sh` on a fresh clone fails with `does not contain a scheme
named listen` even though `.swiftpm/.../listen.xcscheme` is committed.
xcodebuild registers the scheme only after the package graph resolves, and the
first run does both at once. Running it a second time works. This is why the
scheme is committed rather than generated: on a clean CI checkout xcodebuild
cannot write one, and the build fails permanently instead of on the first try.

## Things that will bite you

They are in `.agents/notes/`, one file per area, and **this list is the index
rather than a summary**. A headline here is a claim with a measurement behind
it, and the measurement is the part that stops somebody re-deriving it, so read
the file for the area you are about to touch before you touch it.

Split out of this file when it passed 171k characters, which is loaded into
every session whether or not the session goes near the calendar. Nothing was
deleted. Use `Read`, not `@`: an `@path` line is inlined at load time and would
put the whole thing back.

### `.agents/notes/capture.md` (27k)

How audio gets onto disk, and how it is shown while it happens. `Capture`,
`SystemAudioRecorder`, `MicrophoneRecorder`, `WAVWriter`, `MeetingDetector`,
`AudioDevices`, `Meters`, `RecordingView`.

- A closed lid switches the built-in microphone off and reports it healthy
- A silent device is found with a floor, not with a level, and never abandoned
  after it has been heard from
- The input list is full of things that are not microphones
- The recording panel could not show any of this, because nothing on it moved
- A process tap with an empty include list records perfect silence
- AVAudioEngine cannot be pointed at a tap-backed aggregate device
- AVAudioEngine picks the microphone before you can, and the first recording pays
- `AVAudioPCMBuffer` rebuilds its buffer list, so do not size it by hand
- Changing the microphone mid-meeting silently ended the mic track
- The two tracks did not share a zero
- The aggregate device is not ready when it is created
- Reading a duration after stopping gives zero
- `withUnsafePointer(to:) { $0 }` returns a dangling pointer
- `RunLoop.current.run()` returns immediately
- WAV headers are rewritten as the recording runs
- Meeting detection asks while recording, not before
- Dictating made Listen a call, and the guard was on the pid rather than on the app
- The app the call was in is a field, and never the title
- Nothing asks "keep this recording?" any more

### `.agents/notes/asr.md` (32k)

How audio becomes a transcript. `ASR`, `Chunking`, `Pipeline`, `Queue`,
`TranscribingView`, and which model runs.

- mlx-audio does not expose word timings, only sentences
- The chunk loop is Listen's, and it cuts at pauses
- One chunk length for every Mac, and it is the short one
- Progress is counted, and there is no estimate anywhere
- The one lane is not always the everyone track
- A job advancing is not a queue change
- The head is a position, and it took three tries to say so
- The microphone is a room or a person, and the pipeline has to ask which
- A peak test cannot tell a chime from a conversation
- One voice on the microphone is the user, whatever the flag says
- Both tracks are clustered, so the letters are handed out once
- The far end comes back in through the microphone
- A paragraph ends at a ten second silence, and discarding a speaker is why
- The Whisper-era cleanup has not fired on Parakeet yet
- The transcription queue has no database
- A job that saves the copy it started with erases the hour it ran for
- A recording with no audio is not a job waiting to happen
- The model belongs to the recording, and the language is not a setting
- Transcribing again destroys hand corrections, and now says so
- The model is cached twice, and deleting one copy does not test anything
- The cache root is not always `~/.cache/huggingface`
- mlx-audio prints to stdout, and stdout is the transcript
- A silent track must not cost a transcript
- A model directory that exists is not a model, and both ways it can lie were measured
- A copy of the right size that will not load has to be replaceable
- MLX keeps every buffer it ever freed, until it is told a limit

### `.agents/notes/speakers.md` (37k)

Who said what, and how a human corrects it. `People`, `TranscriptEditor`,
`SpeakerName`, `VoiceBank`, `Enroll`, `Diarizer`, the legacy import.

- A sentence is edited, and a segment is what gets written
- The right-click never reaches the text field
- Discard is a delete, and the undo it was mistaken for did not exist
- Merge stopped being a button and became the first section of the list
- Who said it is corrected at three sizes, and the middle two are new
- The two sizes are one menu item and a checkbox, because two items were a guess
- The window names the turn, and it must not select the segments
- A selection is every sentence it touches
- Both buttons on a pill open the same menu, and the popover is its first item
- The skipping belongs to the button that names it, and there is no bar
- A named speaker opens with the box unticked
- A sentence can be deleted, and an emptied field still does not mean that
- A person is a name string, and that is the whole identity model
- The card's one verb goes to the person, not to the list behind it
- Nobody wanted the library narrowed by a speaker
- Renaming somebody everywhere is the first edit that touches many recordings
- `Me` stays `Me` on disk, whatever you call yourself
- The window refused a label the CLI had always accepted
- Transcript edits do not live in the sheet that presents them
- Voiceprint thresholds were re-derived, and the old ones would have been wrong
- Synthetic voices measured the model's ceiling, not the task
- A suggestion is scored against the worst print, not the best evidence
- A person is a centroid, the number is a word, and the sure ones name themselves
- Naming a voice nobody has heard was the whole difficulty
- Asking about a speaker points the player at them, and never takes the transcript away
- Play starts at their first turn, not their longest
- `metadata.state` cannot say who is waiting, and `effectiveState` inherits that
- The legacy voiceprints are a different space with the same dimension
- An imported recording has no mic track, and must not pretend otherwise
- Re-transcribing an import swaps Whisper for Parakeet, and v2 has no Dutch
- The legacy m4a holds two tracks, and everything reads only the first
- A known speaker count is a good prior, and a bad one applied to one track
- The prior outlived its pass, and every meeting after it had one voice
- The clustering threshold is a similarity, and the comment said distance
- The bank knew everybody except its owner

### `.agents/notes/calendar.md` (15k)

How a recording gets a name and a guest list. `MeetingCalendar`,
`CalendarEvent`, `ContactBook`, `MeetingLink`.

- The calendar needs no account, because macOS already has one
- Ten minutes, and the measurement that fixed it there
- Joining early is not in that table, and it is what a link invites
- The title is applied silently, and two guards are what make that safe
  (the guard is now `mayTitle`, see `titles.md`)
- The meeting link is in the notes, not in `event.url`
- An attendee's name is usually their email address
- `bestName` read the snapshot before the book, so a rename never reached it
- The contact book is a second route to the identity Listen already has
- One `EKEventStore`, and every read behind a lock
- Optional fields do not need a hand-written `init(from:)`
- Onboarding has to ask, because nothing else will
- `listen calendar` exists because matching leaves nothing behind

### `.agents/notes/titles.md` (8k)

What a recording is called, and which of the things that name it may write over
which. `Metadata.TitleSource`, `Recording.mayTitle`, `AutoTitle`,
`Recording.displayTitle`.

- One bit could not hold two titlers
- The placeholder is a key on disk and a word on screen
- The people title waits for the last speaker, and that is measured
- It is a view over the speakers, not a decision taken once
- "Call with" is a claim, and `app_bundle_id` is the evidence
- The backfill exists because the deriver is driven by edits
- What is deliberately not here: no model title

### `.agents/notes/notes-tags-dictionary.md` (25k)

The three things written about a recording rather than extracted from it.
`Notes`, `Tags`, `CustomDictionary`, `RecordingFilter`, `MarkdownText`.

- The dictionary rewrites the library, and only the library
- Adding a field to `StoredTranscript` needs `init(from:)` by hand
- Two dictionaries, not one shared file
- A tag is a name string, and the vocabulary is derived
- Lenses stack, and `RecordingFilter` is why there is not a fourth predicate
- The server is no longer read-only, and notes and tags are the whole exception
- A note belongs to the library, not to a recording
- A note may name no recording, and only the window may write one
- A note file has to survive being written by hand
- The outline was built, measured and deleted
- The user's own note is the thing no transcript contains
- A note remembers the conversation it came from, and the older ones are found by their question

### `.agents/notes/window.md` (71k)

Listen's own window behaviour. `LibraryWindow`, `Sidebar`, `DetailView`,
`NotePane`, `WaveformView`, the settings mode.

- The recording in progress is not in the library
- One elapsed clock per screen, and the row is the one that always counts
- A sidebar reload is not somebody choosing a recording
- The floating panel is sized from its strings, and one of them changes
- The panel is dragged by its whole face, and parked by a corner rather than a point
- Setting `editing = false` is not what closes the person editor
- A recording nobody named is called "Untitled"
- Collection navigation is in the sidebar, not the toolbar
- A day heading that pins to the top is not a row that has vanished
- A convenience initialiser that shadows its superclass's calls itself
- The user's name is a preference, and nothing said where to set it
- The notes pane re-reads on activation, and only redraws when something changed
- Settings is a mode of the library window, not a second window
- A settings pane is as wide as the window, up to 620 points
- About is a window, and the website was in neither of them
- The Updates pane follows the updater, not its own button
- A toolbar item will not draw an image you hand it, and accessibility says it did
- The transcript opened near the end of the meeting
- A peak envelope of a meeting is a solid block
- Turns overlap, so the first one spanning the playhead is the wrong one
- Sentence highlighting is search, not arithmetic
- The sentence field wraps, and still opened one line high
- Building the mixdown on the main thread froze the first press of play
- The transcript is never filtered, and the arrays are why it could not be
- The waveform dims everybody but one, and that is where a quiet speaker is
- The to-do list is a lens, and deliberately not a status on every row
- A hidden view held the divider, and the sidebar would not drag at all
- The gear and the way out are in the title bar, and the rows they replaced are gone
- The recording panel can be put away, and the dismissal has to survive a menu rebuild
- The poll owns every control on the setup pane, so nothing else may set one
- Continue on the model step means the model loaded, not that a file is the right size
- The notes prompt is not inside the notes pane, and stayed up over an empty one
- Stopping a recording is a reload, and it wiped the name being typed
- The meeting page's largest gap was a row holding nothing
- The drawer was never laid out until agent detection finished
- A meeting being transcribed is a loading state, and three things were still on it
- The note box reserved room for a button that left, and lost the last line of every note
- The ellipsis said "No recording selected" over a note, because the menu was the recording's
- The transcript's scroller is at the window's edge, and its margin is the document's
- The room the composer needs is the transcript's, not the scroll view's
- A drag across a paragraph starts playback, and playback moves the page
- The transcript stack is unflipped, and its frames are zero until layout runs
- Open at the top is the clip view's origin, not a point in the stack
- A reload that does not scroll still loses the reader's place

### `.agents/notes/appkit.md` (35k)

Things AppKit does that no documentation warns about. These generalise past
this app, so read them before building any new window, menu or popover.

- `NSPopover` and the row of chips
- No window is the only thing that raises
- The pane is the anchor, and the rect is taken before the edit is committed
- An `NSMenuToolbarItem` eats the first item of its menu
- The status menu is Speak's, refilled in place
- Listen is not `LSUIElement`, and Speak is
- `NSTextField(string:)` fires its action on losing focus, and `NSTextField()` does not
- A text field does not stop editing because you clicked away
- `NSAttributedString(markdown:)` parses the structure and then throws it away
- An app with no nib has no menu bar, and it is not obvious
- An app with no nib has no key view loop either, and that one is quieter
- An app with no nib has no Help menu either, and nothing had Cmd-W
- Cmd-Q is intercepted ahead of the menu, not rebound in it
- The sidebar width fought the split view
- `intrinsicContentSize` is four points narrower than the text
- A typed chevron is not aligned with the text beside it
- A tool tip is a tracking area, so clearing them all takes it with it
- An attributed title's colour wins over `contentTintColor`
- An attributed string brings its own truncation, which is none
- `glyphIndex(for:in:)` answers with the nearest glyph, however far away
- A disabled button greys its title, unless the title is attributed
- A leading image is laid out at the button's edge, not beside its title
- An `NSToolbarItem` lays out its own image and title, and has no gap to give
- A content inset is a scroll offset, and it will not hold a view in place
- Scroller insets are added to content insets, not instead of them
- A shot has to paint its own background, and drawing the cache over one wipes it
- Liquid Glass photographs as a white block, and nothing inside it draws

### `.agents/notes/dictation.md` (18k)

Push-to-talk: a chord, a microphone, and the words typed into whatever is in
front. `Dictation`, `DictationHotkey`, `DictationRecorder`, `DictationEngine`,
`DictationHUD`, `Cue`, `SecureInput`, `Punctuation`, `Polisher`, `SpeechRepair`,
`AppleEngine`, `DictationPane`. **Mostly Speak's measurements, kept here because
that repo is being archived.**

- The event tap must stay ordered and synchronous
- fn is invisible to NSEvent on Apple Silicon
- Secure input takes character key events away
- Two capture paths, and why they are not one
- One `ASR`, and a yield so dictation can get a word in
- Polishing answers the transcript unless you stop it
- Polishing finishes the sentence you did not
- The polisher sees only one kind of speech repair
- The repair pass is only affordable because of the gate
- Sentence units have to tile the text exactly
- Polish requests are greedy, not sampled
- FoundationModels needs permissive guardrails and small chunks
- The first polish request of the process costs about 50 seconds
- The full stop on a one-word dictation is Parakeet's
- A term is a phonetic rule, not just a prompt hint
- Corrections run either side of polishing
- The pill has to be driven by the microphone, not by a timer
- One column edge decides the pill's whole layout
- Signing decides whether the Accessibility grant survives a rebuild
- What is deliberately not here: no MCP tool, no import from Speak

### `.agents/notes/cli-mcp.md` (6k)

`CLI`, `Settings`, `AppInfo`, `CLIInstall`, `MCP`.

- The CLI wrote its preferences into the wrong domain
- An unknown command must not launch the app
- Naming a recording had no owner, and no route outside the window
- `Bundle.main` is wrong when the CLI is run through its symlink
- A workaround only helps the code that remembers it, and MLX does not
- An installed command that is not on the PATH says so
- The MCP server owns stdout completely
- A person filter has to match the name nobody stored
- A bare date is a day, and a day has two ends

### `.agents/notes/cloud-sync.md` (3k)

How a recording and phone audio cross CloudKit. `CloudSyncCore`, `EngineState`,
`CloudRecords`, `MemoryStore`, `FakeSync`, `AudioMaster`.

- A sidecar this device has edited is not a sidecar it is behind on
- The offline window had a deterrent nobody read
- A switch is a policy, and a tap is an instruction
- A one-channel master is two different things
- The audio master has a zone of its own, because `z4` is listed whole
- A device frees audio on a live device's list, never on a latch
- One record type, two zones, and why the zone is the cheap half
- The suite was not hermetic, and it passed once per scratch directory
- A pull cannot stamp a richer local folder as sent
- A stranded recording is invisible, and the screen said the opposite
- A claim is not a delivery
- Only the Mac holding the audio authors an ingested recording's metadata
- A Mac without the application strips the source icon
- A remembered audio upload is not an acknowledgement
- A phone update cannot replace richer Mac content
- Source icons travel inside the sealed recording payload
- A forgotten voiceprint needs a tombstone, or the sync resurrects it
- `LISTEN_LIBRARY` scopes the library, and never the container
- The activity log is one line, appended with O_APPEND
- Nothing ever created the key, and both sides said "waiting"

### `.agents/notes/agent.md` (144k)

Asking questions about the library, through an agent CLI the user already has
or through an OpenAI-compatible endpoint such as Ollama. `Agent`, `AgentCLI`,
`AgentRun`, `AgentChat`, `AgentEndpoint`, `AgentKey`, `AskView`, `AnswerTurn`,
`AgentPane`, `ChatNav`, `listen ask`, `listen endpoint`.

- The model is the user's, and Listen never sees a key
- The agent cannot reach the library except through `listen mcp`
- Codex will predict a command's output rather than run it
- Nothing of the user's own agent configuration runs
- A GUI launch has no PATH, and neither CLI installs where one would look
- `codex login status` says nothing on stdout
- Codex has two approval gates, and the second one is the one that matters
- The working directory is a choice, not a leftover
- The brief is the retrieval ladder, and without it the first move is wrong
- `delete_note` is on neither tool list
- No cost is shown anywhere, and that is a decision rather than an omission
- The Ask pane is a third mode, not a panel
- The record button is hidden while it is up, except when it is Stop
- Nothing on the main thread may run detection
- Four chips that do nothing were the whole no-agent state
- `LISTEN_PANEL=ask` is how the no-agent pane gets on screen
- An answer carries the question it came from
- The model menu is asked, never hardcoded
- The composer is Liquid Glass, and laid out by frame
- The send button is a button, not a tinted symbol
- Codex sends its preamble and its answer as separate messages
- An answer is a clock, some blocks, and one line that changes
- The shimmer is load-bearing, and it is layers not text
- A selectable label throws its attributes away when you click it
- Markdown built for a note is spaced wrong in a stack of labels
- A rotated chevron is only aligned in one of its two states
- Three ways a stack view lies about width, all in one pane
- The conversation is a sidecar, and a note is not
- Markdown is rendered at the end, not while streaming
- `listen ask` is the test mechanism, and it is the same engine as the window
- An empty row and the conversation shared one number, and the row took it
- The chips wait for the caret, and the drawer's panel comes with them
- The composer is always a fresh conversation, and History is how you go back
- History is every conversation, which reverses an earlier decision
- A reference is an id the model wrote, and a number the reader clicks
- Save as note did nothing on the screen most questions are asked from
- Clicking away gives up the caret, and the whole bar counts as inside
- New chat is a button on the card, and the chevron became a cross
- The height report is what reopened the card the cross had just closed
- Claude and Codex are harnesses; an OpenAI-compatible endpoint is one POST
- `MCP.call` is a function, and stdio is one transport onto it
- Every tool failure comes back as a result, never as an error
- The history is the session, and only finished text turns are replayed
- The first turn is not the absence of a resume id
- `--print-request` printed a request nobody sends
- Answering is not the same as being signed in, and OpenRouter proves it
- Three answers to "is this local", not two
- The key is in the Keychain, and the cost argument inverts
- `padding(toLength:)` truncates
- A model that declares tool support will still answer from nothing
- The stored name only applies to the stored URL
- What the notes spike already knew
- Which Ollama model, measured
- A tool that does not say what it returns will not be used
- OpenRouter is a case, not a preset
- Codex does not give an MCP server its own environment
- Providers are a list, and `AgentBackend` stopped trying to name them
- Three migration traps, all of them silent
- `agentModel(status.backend)` was right and became wrong
- A menu is for what you use; a picker is for finding
- The catalogue had the answer all along
- A cached catalogue with no clock is a catalogue frozen at launch
- The cap that shaped a menu outlived the menu
- Opening the settings pane ran detection five times, on the main thread
- A pane that edited settings by being looked at
- Ask is its own settings section now
- The loading state belongs on the control that is about to answer
- Expanded is a page, and a page has no frame around it
- The page scrolls, not a panel inside it
- A width nobody else may have an opinion about
- The document was as wide as the scroll view, and the scroller took the difference
- A width was all the document had, so the first scroll moved the column
- The page's controls are the window's toolbar
- Neither CLI says the network is gone, and both were measured saying nothing
- The path is certain and the probe is truthful, and neither is enough alone
- Twenty seconds of silence, and why that is not a guess
- A run is never killed for the network, and the line stops shimmering
- The failed turn had to end the turn, not just colour it
- `LISTEN_OFFLINE` and `LISTEN_PROBE_HOST`, because unplugging is not a test
- The shimmer line was invisible to accessibility, and that is why it was untestable
- Try again replaces the attempt, and never appends to the conversation
- Only the last turn may be retried
- `LISTEN_OFFLINE` also takes a path, because recovery is the interesting half
- History belongs to the two screens that are about conversations
- The composer cleared the field before the guard, and the follow-up went nowhere
- One question waits, and Stop is the way to take it back
- The stop button drew itself as Ask for the whole run
- Every control on the Ask surfaces was silent until it was pressed
- A conversation you go back to opens as a page
- The meeting being recorded has no composer, and an extent outlived its drawer
- Delete is a verb on the conversation, so it is not on History
- The status line holds its slot, so a message never moves the composer
- The bar's height has to count every gap, and the status line proved it did not
- The library composer has four starters of its own, and a person still has none
- A conversation full width is a mode, and the sidebar under it was live
- The list is the sidebar, and History is what this page was asked
- Where Back goes is where the conversation came from
- The meeting being recorded has no History either, and the toolbar had to be told twice
- The search field belongs where the list it swaps with keeps its own
- The chats home page is the library's home page, and three numbers said otherwise
- An empty page needs the greeting the home page has
- The toolbar's History is gone, and the menu under the card is the one that stays

### `.agents/notes/release.md` (10k)

`make_app.sh`, `release.sh`, `sparkle.conf`, `CHANGELOG.md`, `Changelog`,
`ChangelogWindow`.

- Signing decides whether permissions survive a rebuild
- Sparkle's key is not in the default keychain account
- How fast a new version is noticed is four settings, and three of them are defaults
- The changelog is the only place release notes are written
- Sparkle needs the notes embedded, not linked
- The notes are in the app now, and they stop at the version you have
- `/release` is the shortcut, and it publishes nothing itself

## Conventions

- No em dashes anywhere: code, comments, docs, UI copy.
- Do not use the word "drift".
- Comments explain *why*, especially where the obvious implementation is wrong.
  Most comments in this codebase mark a trap; keep them when editing nearby.
- UI copy states the trade-off rather than hiding it in a tooltip.
- Prefer measured numbers to remembered ones. Every threshold and size that came
  from a measurement says so.
- A device frees its audio only when another **live** device that is **keeping**
  audio reports holding that recording, in the `holdsAudio` list its heartbeat
  republishes from disk every pass. Upload completion, a claim, a transfer
  record, `audioOn` and the container holding a master are none of them
  durable-copy evidence. `audioOn` is still written and still read, for the
  transfer pipe and for saying where the bytes went; it decides no deletion.
- Only the device that authored a recording serialises its `metadata.json`.
  Every other device stores those bytes verbatim and parses them leniently.
- A new trap goes in the `.agents/notes/` file for its area, and its headline
  goes in the index above. A note nobody is pointed at is a note nobody reads.

## Testing

There is no test target, matching Speak. Verification is manual through the CLI
plus debug tracing. If you add one, note that MLX needs the Metal toolchain, so
tests must run through `xcodebuild`, not `swift test`.

One script stands in for one, over the app built in the working directory:

```sh
./verify_title.sh       # every claim in .agents/notes/titles.md, as assertions
./verify_compliance.sh  # the CLI's redaction, endpoint, managed-preference,
                        # backup-permission and activity-log claims
./verify_speakers.sh    # every size of speaker edit, and the turn window that
                        # used to move two paragraphs when asked for one
```

It builds a scratch `LISTEN_LIBRARY` out of copies of five real recordings and
never opens the real one for writing, which is the shape described below. It
earns its place: the `calendar backfill` preview disagreeing with `--apply` was
found by writing it, not by reading the code that had just been changed. Run
`./build.sh && ./make_app.sh` first, or it tests the last build.

**A fixture copied from a live library goes stale, so `reset` reshapes it.** Two
of the five are there to be *untitled*, and the app titles a recording the moment
its last speaker is named, so both had grown a "Call with ..." and six assertions
failed for that rather than for anything in the code. That is the worst kind of
failing test, because it points at the change in front of you: expect this and
check the fixture before believing a failure. `reset` now writes the placeholder
back into those two copies, which is a `"title": "Untitled"` and never a deleted
key, for the reason `.agents/notes/titles.md` gives.

### Driving the built app against a scratch library, without wrecking the real one

`LISTEN_LIBRARY` points the app somewhere else, and a scratch library needs only
the sidecars: copy `metadata.json`, `transcript.json`, `turns.json` and
`embeddings.json` out of a recording and leave the WAVs behind. Everything about
speakers, people and notes works on that; only playback and Transcribe Again do
not, and `Recording.hasAudio` already says so.

**`LISTEN_LIBRARY` scopes the library and not the container, and the app is what
knows that now.** There is one CloudKit container per iCloud account, so a
scratch library used to push into the same place the real one lives and the pull
that followed wrote what it found into whatever library was active on the
receiving device. Measured on 0.15.0: two minutes of `make_demo_library.sh`
output under `LISTEN_LIBRARY` put three invented meetings and four invented
notes into the real library, the container, and both other devices.

Sync is now consented per library rather than per install, so a pass over a
library that is not the consented one is refused and prints both paths. Check
it rather than assuming it, because the guard is a build old enough to have it:

```sh
LISTEN_LIBRARY=/tmp/listen-demo Listen.app/Contents/MacOS/Listen sync status
# sync:  off for this library, on for /Users/…/Application Support/Listen
```

`.agents/notes/cloud-sync.md` has the rest under "`LISTEN_LIBRARY` scopes the
library, and never the container", including how to retract from the container
if an older build has already sent something, which is not the obvious way
round.

**Launch the binary, never `open`.** Two traps stack, and together they cost a
real scare:

1. `open -na Listen.app` resolves through Launch Services, which prefers
   `/Applications/Listen.app` over the one in the working directory. The build
   under test is not the app that starts.
2. A Launch Services start inherits no shell environment, so `LISTEN_LIBRARY`
   is dropped and it opens the **real** library, where it adopts staged
   recordings, sweeps staging and resumes the queue.

So `LISTEN_LIBRARY=… ./Listen.app/Contents/MacOS/Listen` directly, in the
background, and check the pid is the one you meant before touching anything.

Drive it with `AXUIElementCreateApplication(pid)` and nothing else, for the
reason recorded against the popover crash. Useful shapes: press the status
menu's Recent row to open a recording without hunting the sidebar table, set
`kAXSelectedRowsAttribute` on a table to select a person, and read
`AXFocusedUIElement` after a synthesised Tab to check a key view loop.

### Running setup again without spending the real preferences

`LISTEN_LIBRARY` moves the library and nothing else. `Settings.onboarded`, the
model choice and everything else live in the `com.mgo.listen` defaults domain,
so driving first-run setup in the real app both rewrites those and, on the model
step, changes which model every future recording uses.

The way round it is a second bundle identifier. Copy the app, set
`CFBundleIdentifier` to something like `com.mgo.listen-uitest`, sign ad hoc, and
launch it with `LISTEN_LIBRARY` and `HF_HOME` pointing at scratch directories:

```sh
cp -R Listen.app /tmp/T.app
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mgo.listen-uitest" \
    /tmp/T.app/Contents/Info.plist
codesign --force --sign - --deep /tmp/T.app
defaults delete com.mgo.listen-uitest        # between runs
```

It gets its own defaults domain, so setup runs from the top every time, and
`HF_HOME` decides what the model step believes is on disk. The same trick on a
copy of `/Applications/Listen.app` is how the download bug was shown to be in
the shipped build rather than only in the reading of it, which is worth the two
minutes: a claim about a released binary is not something to make from a diff.

Do not press "Allow microphone" in that copy. A new bundle identifier is a new
TCC subject, so it raises a real system prompt; "Skip" reaches the model step
just as well.

**That copy also asks the user for the Keychain, on every launch, and the
prompt names the real app.** Ad-hoc signing gives the copy a different code
identity, and the ACL on `com.mgo.listen.endpoint` trusts the identity that
created it, so macOS puts up "Listen wants to use your confidential information
stored in com.mgo.listen.endpoint" for each run. It is the harness, not the
build, and Deny is the right answer: the endpoint key is only the Ask settings,
nothing else reads it at launch, and allowing it would add an ad-hoc copy to a
real ACL. Expect one prompt per launch, warn whoever is at the keyboard, and
delete the copy when finished rather than leaving it around to prompt again.

Context menus are reachable and worth using: `AXUIElementPerformAction(el,
"AXShowMenu")` on an `NSButton` opens its menu, the whole tree including submenus
is then readable, and `kAXPressAction` on an item runs it. That is how the
transcript pill's "Speaker for This Turn" was verified end to end. A synthetic
right-click over a **selectable `NSTextField`** opens nothing at all, so the Edit
Sentence menu cannot be reached this way; `/Applications/Listen.app` behaves the
same, which is the control that says it is the harness and not the build.

One gap to know about: `HoverRow` is a plain `NSView` with a target and action,
so every popover list row in this app is invisible to accessibility. A row
cannot be pressed through AX, and the way in is the text field beside it. That
is worth fixing on its own account, and until it is, a test that "clicks a
suggestion" is really testing the typed path.
