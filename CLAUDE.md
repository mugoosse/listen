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

### `.agents/notes/capture.md` (16k)

How audio gets onto disk. `Capture`, `SystemAudioRecorder`,
`MicrophoneRecorder`, `WAVWriter`, `MeetingDetector`.

- A process tap with an empty include list records perfect silence
- AVAudioEngine cannot be pointed at a tap-backed aggregate device
- Changing the microphone mid-meeting silently ended the mic track
- The two tracks did not share a zero
- The aggregate device is not ready when it is created
- Reading a duration after stopping gives zero
- `withUnsafePointer(to:) { $0 }` returns a dangling pointer
- `RunLoop.current.run()` returns immediately
- WAV headers are rewritten as the recording runs
- Meeting detection asks while recording, not before
- The app the call was in is a field, and never the title
- Nothing asks "keep this recording?" any more

### `.agents/notes/asr.md` (32k)

How audio becomes a transcript. `ASR`, `Chunking`, `Pipeline`, `Queue`,
`TranscribingView`, and which model runs.

- mlx-audio does not expose word timings, only sentences
- The chunk loop is Listen's, and it cuts at pauses
- One chunk length for every Mac, and it is the short one
- Progress is counted, and there is no estimate anywhere
- A job advancing is not a queue change
- The head is a position, and it took three tries to say so
- The microphone is a room or a person, and the pipeline has to ask which
- A peak test cannot tell a chime from a conversation
- One voice on the microphone is the user, whatever the flag says
- Both tracks are clustered, so the letters are handed out once
- The far end comes back in through the microphone
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

### `.agents/notes/speakers.md` (37k)

Who said what, and how a human corrects it. `People`, `TranscriptEditor`,
`SpeakerName`, `VoiceBank`, `Enroll`, `Diarizer`, the legacy import.

- A sentence is edited, and a segment is what gets written
- The right-click never reaches the text field
- A person is a name string, and that is the whole identity model
- Renaming somebody everywhere is the first edit that touches many recordings
- `Me` stays `Me` on disk, whatever you call yourself
- The window refused a label the CLI had always accepted
- Transcript edits do not live in the sheet that presents them
- Voiceprint thresholds were re-derived, and the old ones would have been wrong
- Synthetic voices measured the model's ceiling, not the task
- A suggestion is scored against the worst print, not the best evidence
- A person is a centroid, the number is a word, and the sure ones name themselves
- Naming a voice nobody has heard was the whole difficulty
- Asking about a speaker narrows the page to them, for exactly as long as the asking lasts
- Play starts at their first turn, not their longest
- `metadata.state` cannot say who is waiting, and `effectiveState` inherits that
- The legacy voiceprints are a different space with the same dimension
- An imported recording has no mic track, and must not pretend otherwise
- Re-transcribing an import swaps Whisper for Parakeet, and v2 has no Dutch
- The legacy m4a holds two tracks, and everything reads only the first
- A known speaker count is a good prior, and a bad one applied to one track
- The bank knew everybody except its owner

### `.agents/notes/calendar.md` (15k)

How a recording gets a name and a guest list. `MeetingCalendar`,
`CalendarEvent`, `ContactBook`, `MeetingLink`.

- The calendar needs no account, because macOS already has one
- Ten minutes, and the measurement that fixed it there
- Joining early is not in that table, and it is what a link invites
- The title is applied silently, and two guards are what make that safe
- The meeting link is in the notes, not in `event.url`
- An attendee's name is usually their email address
- `bestName` read the snapshot before the book, so a rename never reached it
- The contact book is a second route to the identity Listen already has
- One `EKEventStore`, and every read behind a lock
- Optional fields do not need a hand-written `init(from:)`
- Onboarding has to ask, because nothing else will
- `listen calendar` exists because matching leaves nothing behind

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
- A note file has to survive being written by hand
- The outline was built, measured and deleted
- The user's own note is the thing no transcript contains

### `.agents/notes/window.md` (46k)

Listen's own window behaviour. `LibraryWindow`, `Sidebar`, `DetailView`,
`NotePane`, `WaveformView`, the settings mode.

- The recording in progress is not in the library
- One elapsed clock per screen, and the row is the one that always counts
- A sidebar reload is not somebody choosing a recording
- The floating panel is sized from its strings, and one of them changes
- Setting `editing = false` is not what closes the person editor
- A recording nobody named is called "Untitled"
- Collection navigation is in the sidebar, not the toolbar
- A day heading that pins to the top is not a row that has vanished
- A convenience initialiser that shadows its superclass's calls itself
- The user's name is a preference, and nothing said where to set it
- The notes pane re-reads on activation, and only redraws when something changed
- Settings is a mode of the library window, not a second window
- A settings pane is as wide as the window, up to 620 points
- The About pane is Speak's, and the app name is one size down
- The transcript opened near the end of the meeting
- A peak envelope of a meeting is a solid block
- Sentence highlighting is search, not arithmetic
- The sentence field wraps, and still opened one line high
- Building the mixdown on the main thread froze the first press of play
- The narrowed transcript is a view state, never a filtered array
- The waveform dims everybody but one, and that is where a quiet speaker is
- The to-do list is a lens, and deliberately not a status on every row
- A hidden view held the divider, and the sidebar would not drag at all
- The gear and the way out are in the title bar, and the rows they replaced are gone
- The recording panel can be put away, and the dismissal has to survive a menu rebuild
- The poll owns every control on the setup pane, so nothing else may set one
- Continue on the model step means the model loaded, not that a file is the right size
- The notes prompt is not inside the notes pane, and stayed up over an empty one

### `.agents/notes/appkit.md` (19k)

Things AppKit does that no documentation warns about. These generalise past
this app, so read them before building any new window, menu or popover.

- `NSPopover` and the row of chips
- No window is the only thing that raises
- The pane is the anchor, and the rect is taken before the edit is committed
- An `NSMenuToolbarItem` eats the first item of its menu
- The status menu is Speak's, refilled in place
- Listen is not `LSUIElement`, and Speak is
- A text field does not stop editing because you clicked away
- `NSAttributedString(markdown:)` parses the structure and then throws it away
- An app with no nib has no menu bar, and it is not obvious
- An app with no nib has no key view loop either, and that one is quieter
- Cmd-Q is intercepted ahead of the menu, not rebound in it
- The sidebar width fought the split view

### `.agents/notes/cli-mcp.md` (6k)

`CLI`, `Settings`, `AppInfo`, `CLIInstall`, `MCP`.

- The CLI wrote its preferences into the wrong domain
- An unknown command must not launch the app
- `Bundle.main` is wrong when the CLI is run through its symlink
- An installed command that is not on the PATH says so
- The MCP server owns stdout completely
- A person filter has to match the name nobody stored
- A bare date is a day, and a day has two ends

### `.agents/notes/agent.md` (31k)

Asking questions about the library through an agent CLI the user already has.
`Agent`, `AgentCLI`, `AgentRun`, `AskView`, `AnswerTurn`, `AgentPane`,
`listen ask`.

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

### `.agents/notes/release.md` (5k)

`make_app.sh`, `release.sh`, `sparkle.conf`, `CHANGELOG.md`.

- Signing decides whether permissions survive a rebuild
- Sparkle's key is not in the default keychain account
- The changelog is the only place release notes are written
- Sparkle needs the notes embedded, not linked
- `/release` is the shortcut, and it publishes nothing itself

## Conventions

- No em dashes anywhere: code, comments, docs, UI copy.
- Do not use the word "drift".
- Comments explain *why*, especially where the obvious implementation is wrong.
  Most comments in this codebase mark a trap; keep them when editing nearby.
- UI copy states the trade-off rather than hiding it in a tooltip.
- Prefer measured numbers to remembered ones. Every threshold and size that came
  from a measurement says so.
- A new trap goes in the `.agents/notes/` file for its area, and its headline
  goes in the index above. A note nobody is pointed at is a note nobody reads.

## Testing

There is no test target, matching Speak. Verification is manual through the CLI
plus debug tracing. If you add one, note that MLX needs the Metal toolchain, so
tests must run through `xcodebuild`, not `swift test`.

### Driving the built app against a scratch library, without wrecking the real one

`LISTEN_LIBRARY` points the app somewhere else, and a scratch library needs only
the sidecars: copy `metadata.json`, `transcript.json`, `turns.json` and
`embeddings.json` out of a recording and leave the WAVs behind. Everything about
speakers, people and notes works on that; only playback and Transcribe Again do
not, and `Recording.hasAudio` already says so.

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

One gap to know about: `HoverRow` is a plain `NSView` with a target and action,
so every popover list row in this app is invisible to accessibility. A row
cannot be pressed through AX, and the way in is the text field beside it. That
is worth fixing on its own account, and until it is, a test that "clicks a
suggestion" is really testing the typed path.
