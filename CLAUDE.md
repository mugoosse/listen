# Listen: working notes for coding agents

Local meeting recorder, transcriber and speaker labeller for macOS. Pure Swift,
fully local. Read `README.md` for user-facing behaviour and `SPEC.md` for the
brief. This file is about working on the code without re-learning things the
hard way.

Speak (`../speak`) is the template. Its `CLAUDE.md` is a list of traps already
paid for and most of them still apply here; this file records the ones that are
Listen's own.

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
whole file in one pass. It exists for the measurement below, not for users.

### The scheme has to exist before the first build

The first `./build.sh` on a fresh clone fails with `does not contain a scheme
named listen` even though `.swiftpm/.../listen.xcscheme` is committed.
xcodebuild registers the scheme only after the package graph resolves, and the
first run does both at once. Running it a second time works. This is why the
scheme is committed rather than generated: on a clean CI checkout xcodebuild
cannot write one, and the build fails permanently instead of on the first try.

## Things that will bite you

### mlx-audio does not expose word timings, only sentences

**This is load-bearing for speaker assignment.** SPEC section 4.4 assigns each
word to the overlapping speaker turn and splits a segment where the speaker
changes mid-sentence. Both need word timings.

The Parakeet decoder computes them. `NemoAlignedToken` carries `start` and
`duration` per sub-word token, finer than word level, and `NemoAlignedSentence`
keeps the whole token array. But `NemoAlignedResult.segments`, the only thing
that reaches `STTOutput`, projects each sentence down to `text`, `start` and
`end` and drops the tokens:

```swift
public var segments: [[String: Any]] {
    sentences.map { ["text": $0.text, "start": $0.start, "end": $0.end] }
}
```

`ParakeetModel` has exactly three public entry points, `generate`,
`generateBatch` and `generateStream`, and all three return `STTOutput`.
`decodeChunk`, which returns the aligned result, is `private`. So the
information exists and is thrown away one layer below where we can reach it.
Checked against upstream `main`, not just the pinned revision.

`ASR.segments(from:)` therefore reads a `words` key if one is ever present
rather than assuming it is not, and `Transcript.hasWordTimings` reports the
answer instead of anyone guessing. The CLI says so on every run. Do not build
word-level assignment on this until the exposure question is settled.

### One word is corrupted at every ASR chunk seam

Measured on synthesised speech numbering 60 sentences, so every word is
checkable:

| `LISTEN_CHUNK` | seams | result |
|---|---|---|
| 0 (whole file) | 0 | 60 sentences, in order, nothing missing or duplicated |
| 120 | 1 | sentence 56 came back as "number 50" |
| 60 | 2 | sentences 29 and 55 came back as "number 20" and "number 50" |

Exactly one corruption per seam, at the seam. The corrupted segment is also
short: 1.2 s against about 2.2 s for its neighbours, so the tail of the word
straddling the boundary is being dropped rather than mistranscribed.

mlx-audio chunks internally with a 2 second overlap and merges token sequences
on the longest contiguous match (`NemoAlignment.mergeLongestContiguous`). The
overlap is not enough to protect a word sitting on the boundary.

This matters more here than in Speak because a dictation is one chunk and a
meeting is not: at 120 s chunks an hour-long recording has 29 seams and
therefore about 29 corrupted words. Do not treat it as noise.

The principled fix is to cut chunks at silence rather than at a fixed offset,
so no word ever straddles a seam. mlx-audio ships `MLXAudioVAD`, so the parts
exist. Until then the chunk length is a trade against memory, measured below.

### A process tap with an empty include list records perfect silence

The worst bug in this codebase so far, because nothing anywhere reports an
error. `CATapDescription.processes` is an **include** list unless
`isExclusive` is set, and the SDK header is explicit: "True if this description
should tap all processes except the process listed in the 'processes'
property."

So `processes = []` with `isExclusive = false` asks to tap nothing. It does not
fail. `AudioHardwareCreateProcessTap` succeeds, the aggregate device reports a
sensible 48 kHz mono format, the IO proc fires at the right rate, and every
buffer is correctly sized and full of zeros. Measured: 143,696 samples,
`peak = 0.00000`, `nonzero = 0`. An hour-long meeting would record as a
9 MB file of silence and the only symptom would be an empty transcript.

Tapping everything is `processes = []` **plus** `isExclusive = true`. The two
properties have to move together, which is why they are adjacent in
`createTap()` with that comment between them.

Tapping everything is also the right scope for a meeting: participants' audio
comes out of a browser or the Zoom client, and narrowing to a guessed list of
bundle identifiers is the other way to record silence.

### AVAudioEngine cannot be pointed at a tap-backed aggregate device

Setting `kAudioOutputUnitProperty_CurrentDevice` to the aggregate either fails
or yields silence, so `SystemAudioRecorder` drives
`AudioDeviceCreateIOProcIDWithBlock` on the aggregate directly. The microphone
path still uses `AVAudioEngine`, which is why there are two capture classes
rather than one.

### The aggregate device is not ready when it is created

Reading `kAudioDevicePropertyStreamFormat` immediately after creating the
aggregate returns a zero sample rate. An `AVAudioConverter` built from that
produces no output at all, so the failure surfaces an hour later as an empty
file rather than at setup as an error. `deviceFormat` polls for up to two
seconds. Measured here: it takes one poll, so anything that "simplifies" the
loop away will appear to work on this machine and fail on a busier one.

### Reading a duration after stopping gives zero

Both recorders close and release their `WAVWriter` in `stop()`, and the
duration is the writer's. `Capture.stop()` therefore samples the durations
before stopping, otherwise every meeting is recorded as zero seconds long.

### `withUnsafePointer(to:) { $0 }` returns a dangling pointer

Building an `AVAudioFormat` from an `AudioStreamBasicDescription` with
`AVAudioFormat(streamDescription: withUnsafePointer(to: asbd) { $0 })` crashes
with SIGTRAP. The pointer is only valid inside the closure. The working form
passes an `inout` and does the work inside:
`withUnsafePointer(to: &asbd, { AVAudioFormat(streamDescription: $0) })`.

### `RunLoop.current.run()` returns immediately

It returns as soon as the run loop has no input sources attached, so `listen
record` fell straight through to `exit`. The symptom was a recording that
stopped after 80 milliseconds with a system track containing nothing but a WAV
header, which is indistinguishable from a tap that does not work. The CLI runs
`run(until:)` in a loop instead.

### WAV headers are rewritten as the recording runs

`WAVWriter` exists instead of `AVAudioFile` because `AVAudioFile` finalises the
header on close. A crash or a power cut during an hour-long meeting would leave
a file whose RIFF and data chunks claim a length of zero: every sample on disk,
and nothing able to play them. `WAVWriter` patches the two length fields every
two seconds and `fsync`s, so the worst case is losing the last couple of
seconds rather than the meeting.

Format tag 3, not 1. These are floats, and a reader told they are integers
decodes noise at full scale.

### Only the system track is diarized

The microphone is the user by definition and the system output is everyone
else, so clustering is run over the system track only and the mic track is
labelled `Me` in one step. Running the diarizer over both would spend Neural
Engine time rediscovering something already known, and would occasionally split
the user into two people, which is the single most common diarization error.

`Pipeline.isSilent` skips a track with no signal. A meeting where nobody
touched the microphone leaves an hour of room noise, and Parakeet over room
noise produces confident invented sentences attributed to the user.

### The Whisper-era cleanup has not fired on Parakeet yet

`Merge.clean` is ported from `transcribe_call.py`, where it exists because
Whisper falls into repetition loops. Parakeet is claimed not to, so the port
counts rather than assumes: every run reports `cleanup fired: never` or the
rules that fired, and `StoredTranscript.cleanup` stores the counts.

So far it has fired **never**, on synthetic two-speaker audio and on 13 and 67
minute files. That is not yet enough evidence to delete it, because none of
that is real meeting audio with crosstalk and silence. Keep watching the
counts; when there is a real corpus behind the number, either delete the rules
and say so in the commit, or record why they stayed.

### A person is a name string, and that is the whole identity model

`People` groups the library by the label written in the transcripts. Nothing
cleverer, and deliberately not the voiceprints: those rank a voice against the
bank, and SPEC's own rule is that a suggestion is never applied on its own, so
two recordings hold the same person exactly when somebody said so by naming them
the same thing.

Placeholders are therefore never people. `A` in one meeting has nothing to do
with `A` in another, so `People.all` filters them out while `People.speakers`
keeps them: they really are in *this* recording, and the chip is how one gets
named. The same split as `VoiceBank.named`, for the same reason.

There is no index and no cache, for the reason there is no job table. Every call
re-reads `turns.json`, which is what the sidebar's transcript search already did
on every keystroke. If a library ever grows big enough for that to hurt, the fix
is a cache keyed on the file's modification date, not a database.

### Renaming somebody everywhere is the first edit that touches many recordings

`People.rename` loops and calls `TranscriptEditor.apply(.rename:)` per
recording, which is the same path the sheet and `listen label` take. It has to
be: that one function rewrites `transcript.json`, rebuilds `turns.json`, moves
the voiceprint with the name, and re-derives the state. Anything that
reimplemented one of those four here would be a fourth writer of the same files.

Three things it refuses, each because the failure is silent otherwise:

1. **A name that looks like a placeholder.** Renaming somebody to "A" puts every
   recording back into needs-labelling and drops them out of the voice bank,
   which reads as the rename having quietly failed.
2. **`Me` as a target.** The microphone track is you by construction rather than
   by name. Folding somebody into yourself in one recording is the existing
   per-recording Merge, which is a transcript edit and stays one.
3. Nothing at all when the name is unchanged, so a stray Return costs no writes.

Collisions are counted **before** the fact and said out loud. Renaming Sarah to
Anna where a recording already has an Anna merges two people there, `Merge.turns`
condenses their now-adjacent turns into one, and the result looks exactly as
though it had always been that way. `VoiceBank.rename` keeps whichever
voiceprint was built from more speech, because `isEvidence` is a threshold in
seconds and keeping the shorter one can drop a usable identity below it.

### `Me` stays `Me` on disk, whatever you call yourself

`Settings.userName` is a preference and `SpeakerName.display` resolves it on the
way to the screen. The transcripts keep saying `Me`. This is the same rule as
`Speaker A`: the label is the stable fact, and the interface is where it is made
legible.

Writing the chosen name into transcripts instead fails three ways that only
appear later. Recordings made before the name was set would keep saying `Me`
while later ones said "Emily". Changing your mind would not reach the history.
And `Me` would stop being a stable key, which `VoiceBank.isPlaceholder` and
`Enroll` both use to know which voice is the user's without being told.

The consequence is that two people can display the same name, and this library
really does contain that case: 19 recordings with `Me` and 8 with a hand-labelled
`Emily` from the import. They stay two people. `listen people` prints the disk
label after the name whenever the two differ (`Emily (Me)`), the popover says
"You, on the microphone track", and choosing a name that already exists says so
rather than merging anything.

### The CLI wrote its preferences into the wrong domain

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

### `NSPopover` and the row of chips

Two rules, both learned by measurement, both invisible from the code:

1. **A popover closes when its positioning view leaves the window.** The chips
   are rebuilt by `configure` on every reload of the pane, so a popover anchored
   to a chip is anchored to something with a lifetime shorter than itself.
   `SpeakerChips` therefore hands out the *row* as the anchor and the chip's
   rectangle within it.
2. **A popover that does not fit is closed, not moved.** The chips sit near the
   top of the window, so `preferredEdge: .maxY` asks for 362 points of popover
   in the hundred points between the row and the menu bar. It opened and closed
   inside the same `show(relativeTo:)` call, reporting `isShown == false`
   immediately afterwards with a close reason of "standard" and no other
   symptom. `.minY` is downward in an unflipped view, which is where the room
   is.

It is also shown on the next runloop turn rather than inline, because a popover
put up from inside a control's own action arrives while the mouse event is still
being dispatched.

### Listen is not `LSUIElement`, and Speak is

This is the one place the Speak template was deliberately reversed. Speak is a
menu bar utility with no primary window, so hiding it from the Dock is right.
Listen's main surface is a window people read transcripts in for minutes at a
time, and an app you cannot reach with Cmd-Tab or the Dock is an app you cannot
get back to once its window is behind a browser.

So: `.regular` activation policy, no `LSUIElement`, menu bar item kept for
start and stop, `applicationShouldTerminateAfterLastWindowClosed` returns false
because a recording may still be running, and `applicationShouldHandleReopen`
brings the window back.

The onboarding rule this reverses one reason for still holds. Windows must
float and re-activate after each permission prompt: a window behind a system
dialog is unrecoverable either way.

### Meeting detection asks while recording, not before

The rule is Blackbox's, not SPEC 5.3's: a process running **both** an input and
an output stream at once is on a call. SPEC 5.3 proposes a list of bundle
identifiers for Zoom, Meet, Teams and Slack, and that is the same mistake as
narrowing the tap's process list. A guessed list is wrong the first time
somebody joins a call in the fifth thing, and being wrong means no recording
with nothing on screen to explain why. The broad rule over-triggers instead,
which is survivable because the skip list makes over-triggering one click.

Capture starts on detection and the panel asks afterwards, which is SPEC 5.3
point 1: the minute spent answering is the minute where people say who they are.

Detection is **on** by default, reversing the original call. A recorder you have
to remember to enable is off for the meeting you needed it for. What makes that
defensible is that it asks on screen the moment it starts, and "No" deletes the
audio, so nothing is ever kept quietly. Onboarding says so on the last pane
rather than leaving it to be discovered.

`autoDetectMeetings` reads `object(forKey:) as? Bool ?? true`, not
`bool(forKey:)`. The latter returns false for a key that was never written, so
it cannot tell "not set yet" from "turned off on purpose": a default of true
would be inexpressible, and anyone who turned detection off would have it
switched back on for them.

### Nothing asks "keep this recording?" any more

SPEC 5.3's Keep and Discard step is gone, in favour of the fallback SPEC 5.3
itself names: "Blackbox's behaviour, which is to keep everything with a Discard
button." A recording that exists is kept, and Delete in the library is how one
goes away, where you can see its length and play it before deciding.

The confirm panel was worse than no panel for two reasons that only showed up
once it was used. It arrived at the *end*, an hour after the context for the
question, and it offered no way to hear what it was asking about. And it also
appeared at launch for anything staged by a crash, which meant being asked
whether to keep an hour of audio you had no memory of recording.

So the only question left is "are you in a meeting?", which is asked at the
start, while the call is in front of you and the answer is obvious. "No" is
also the only thing in the app that deletes a recording without a confirmation
step, and that is deliberate: it is answering a question, not issuing a
command, and following one no with another is how you train people to click
through both.

The consequence for staging: a staged recording is no longer one somebody
declined to keep, it is one a crash or a quit interrupted. `adoptStaged()`
promotes it at launch, and it has to run **before** `Library.sweepStaging()`,
which deletes staged folders older than 24 hours. In the other order the sweep
destroys exactly the recording adoption exists to rescue.

Three things were measured with `listen sources`, which exists because
detection leaves nothing behind to inspect afterwards:

1. **A process tap is not an output stream on the tapping process.** Listen
   while capturing reports `in y / out -` (measured, pid 8859). So Listen does
   not match its own rule and the self-PID guard is not currently load-bearing.
   It stays: the day capture plays anything, the app detects itself forever.
2. **Every process that links CoreAudio gets a process object**, streams or
   not. `listen sources` lists 30 on this machine with two on any kind of
   stream, so filtering on the flags rather than on the list is the whole job.
3. **Processes with no bundle identifier are dropped before the prompt.** This
   is the `replayd` case: Apple's ReplayKit daemon opens input and output during
   any system dictation, and Anarlog really does ask "are you in a meeting?"
   about it. A daemon nobody has heard of asking that is the failure this
   feature is judged on, and there is nothing to skip if it never asks.

Helper bundle identifiers resolve to the parent, so Chrome is `com.google.Chrome`
and not `com.google.Chrome.helper.renderer`. Without it the prompt names
something unrecognisable, and worse, the skip list stores a per-renderer
identifier that skips nothing the next time.

### The recording in progress is not in the library

It is in `staging/`, and `Recording.all()` lists `recordings/`, so for the whole
length of a meeting the sidebar knew nothing about the meeting. Pressing Record
changed the toolbar button and nothing else: no row, no selection, nothing to
click. A list that looks identical before and after you press Record is
indistinguishable from a Record button that does not work, which is the one
doubt this app cannot afford.

`SidebarViewController.reload()` therefore prepends `Capture.shared.current`,
`LibraryWindow.recordingChanged()` rebuilds the list on both edges of capture
and selects the new row **once**, and the per-second tick that advances the
toolbar clock also re-renders that one row. One row and not `reloadData()`: a
full reload every second cancels a drag, fights the scroller and rebuilds every
cell in the library to advance one number.

Three consequences, all of which were bugs first:

1. **`Capture.stop()` re-reads `metadata.json` from disk.** It used to save the
   copy taken at `start()`, which was correct only while nothing could edit a
   recording that was still running. Now the row is selectable and the title is
   editable, so renaming a meeting while it records and then stopping wrote the
   hour-old copy back over it and the name was silently gone.
2. **The sidebar reads the live recording from disk too**, for the same reason:
   `Capture.current` holds the metadata as it was an hour ago.
3. **No player and no waveform while it records.** Both tracks exist and are
   growing, so a mixdown built now is of half a meeting, and `Waveform` would
   cache that half against a key that is only its format version. The pane says
   what is happening instead.

`SidebarViewController.reload()` calls `loadViewIfNeeded()` first. The list is
now rebuilt whenever capture changes, and capture can change before the window
has ever been shown, because `rebuildMenu()` runs at launch. `table` is created
in `loadView`, so without it the first reload is a nil unwrap.

### A recording nobody named is called "Untitled"

The default was "Recording, 5 Aug 2026 at 14:31", which repeats the day heading
and the time already printed on the same row, and makes an unnamed recording
look like a named one. The placeholder is stored rather than left blank so the
CLI, the MCP server and an export all have something to print, and
`Recording.isUntitled` is the one place that knows the string.

The detail pane shows it as an actual `placeholderString` with an empty field
behind it, so clicking the title gives you somewhere to type rather than a word
to delete first, and clearing the field un-names the recording rather than
being refused. `exportName` puts the date back for a filename, because a folder
of `Untitled.md`, `Untitled 2.md` is a folder nobody can read.

### A text field does not stop editing because you clicked away

Clicking the title, then clicking the transcript, left the caret blinking in the
heading. Nothing was broken: `NSView` does not accept first responder, so a
click on a plain view goes nowhere and the field keeps focus. Only a control
takes it away, which is why clicking the sidebar table always worked and
everything else did not.

`DetailView.mouseDown` ends editing, and catches every click that no subview
claimed, because `NSView.mouseDown` forwards up the responder chain. Clicks that
*are* claimed do not arrive there, so the play button, the waveform, a turn and
a speaker name each call `endEditingTitle()` themselves.

### The transcription queue has no database

A recording whose audio exists and whose transcript does not **is** pending.
That one sentence is the whole design: `Queue.resume()` rebuilds the queue by
listing the library at launch, so a job interrupted by a quit or a crash costs
one re-run rather than leaving a stuck row somewhere. Adding a job table would
reintroduce exactly the inconsistency the layout removes.

One job at a time, on purpose. Parakeet is on the GPU and FluidAudio is on the
Neural Engine, and two jobs contend for the same hardware rather than finishing
sooner. `dashboard.py` reached the same conclusion.

### Transcript edits do not live in the sheet that presents them

`TranscriptEditor` owns rename, discard and merge; `SpeakerSheet` only asks the
question. They are split so `listen label` exercises the exact code path the
window uses, rather than a second implementation that agrees with it right up
until it does not. There is no test target, so this is what verification of
speaker editing looks like.

The `.raw.json.bak` backup is written **once**, before the first edit. Writing
it on every edit would overwrite it with edited data the second time, and it
would no longer be a way back to what the model actually said.

### The cache root is not always `~/.cache/huggingface`

Inherited wholesale from Speak, and the reason models are shared between the
two apps for free. swift-huggingface resolves `HF_HUB_CACHE`, then `HF_HOME` +
`/hub`, then the standard path. `ModelChoice.hubRoot` repeats those rules
exactly, including the sandbox branch Listen does not currently take.

Speak shipped the disagreement once: it measured the standard path, reported
"already downloaded", then sat on "loading model" for four minutes while the
library fetched 2.4 GB into the other cache, with no progress bar because as
far as Speak knew nothing was being downloaded.

This machine has `HF_HOME=/Users/mgo/ComfyUI/.cache/huggingface` set, and
Parakeet v2 is now in **both** caches, 4.6 GB in each, which is what paying for
this bug looks like. A Finder launch inherits no shell environment, so it does
not reproduce from the GUI. `env -u HF_HOME` when testing from a terminal, or
expect a surprise download.

### mlx-audio prints to stdout, and stdout is the transcript

`ModelUtils.resolveOrDownloadModel` prints `Using cached model at: <path>`
with a bare `print()` and no flag to suppress it, and `STT.loadModel` resolves
the model again internally, so it lands three times. On the CLI that is three
lines of library chatter in the middle of piped output.

`withStdoutOnStderr` dups stdout to stderr around model loading. It is safe
only because loading is serialized by the `ASR` actor and nothing else in the
process writes to stdout while it runs.

### An unknown command must not launch the app

`CLI.wants` treats any bare first argument as the CLI, including one it does
not recognise, so `listen bogus` says so and exits 1. Gating on the known list
instead meant an unrecognised command fell through to `NSApplication.run` and
hung the terminal, which reads as the binary being broken rather than the
command being wrong.

Anything starting with `-` that is not one of ours still falls through to
AppKit on purpose: launch services and Xcode pass their own flags (`-psn_0_…`,
`-NSDocumentRevisionsDebugMode`), and refusing to start because of one would
break launching the app entirely.

### Signing decides whether permissions survive a rebuild

Straight from Speak, and it matters more here. Ad-hoc signing gives a
designated requirement of `cdhash H"…"`, pinned to one build, so **every
rebuild silently invalidates the permission** while System Settings still shows
the toggle on. On an app that records hour-long meetings, that failure is
expensive. `make_app.sh` signs with a real certificate when one exists.

```sh
codesign -d -r- /Applications/Listen.app     # must not contain cdhash
```

### Sparkle's key is not in the default keychain account

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

## Conventions

- No em dashes anywhere: code, comments, docs, UI copy.
- Do not use the word "drift".
- Comments explain *why*, especially where the obvious implementation is wrong.
  Most comments in this codebase mark a trap; keep them when editing nearby.
- UI copy states the trade-off rather than hiding it in a tooltip.
- Prefer measured numbers to remembered ones. Every threshold and size that came
  from a measurement says so.

## Testing

There is no test target, matching Speak. Verification is manual through the CLI
plus debug tracing. If you add one, note that MLX needs the Metal toolchain, so
tests must run through `xcodebuild`, not `swift test`.

### Voiceprint thresholds were re-derived, and the old ones would have been wrong

`listen calibrate` on 12 named voiceprints across 4 people (12 same-person and
48 different-person cross-recording pairs):

    same person       min +0.979  median +0.991  max +0.995
    different people  min +0.127  median +0.225  max +0.597

Clean separation, gap +0.382, top-1 identification 12/12. `matchThreshold` and
`strongThreshold` sit one third and two thirds across the gap, at 0.72 and 0.85.

The Python pipeline's 0.50 was measured against **pyannote** embeddings, where
different-person pairs topped out at 0.46. In FluidAudio's space they reach
0.597, so copying 0.50 across would have called strangers a match on a third of
the pairs measured here. This is exactly why SPEC 4.5 says to re-derive rather
than copy.

**Measured on synthesised speech**, which is the caveat that matters. One TTS
voice reading two scripts is far more self-consistent than a person on two days
with two microphones, so same-person scores above 0.97 are an upper bound on
separability rather than a real-world figure. Re-run `listen calibrate` against
a real library before trusting these numbers.

Two rules keep the measurement honest and are easy to break: pairs from the
same recording are skipped (they come from the clustering step that decided
they were different people, so using them measures the diarizer agreeing with
itself), and placeholder labels are excluded (`A` in one meeting has nothing to
do with `A` in another, and pairing them manufactures both false same-person
and false different-person pairs).

### `Bundle.main` is wrong when the CLI is run through its symlink

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

### An installed command that is not on the PATH says so

`/usr/local/bin` does not exist on a Mac without Homebrew and creating it needs
an admin prompt this app deliberately does not raise, so the install usually
lands in `~/.local/bin`, which is frequently not on the PATH. An installed
command that cannot be run is worse than one that was never installed, because
nothing else would explain why. `CLIInstall.isOnPath` checks, and the
Developers pane says to add it to the shell profile.

A GUI launch inherits no shell environment, so `PATH` is empty there. The check
falls back to the default login list rather than reporting a false negative.

### The MCP server owns stdout completely

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

### An app with no nib has no menu bar, and it is not obvious

Listen builds its own `NSMenu` in `MainMenu.install()`. Without it there is no
menu bar at all, and the gap hides because the window looks finished: what is
actually missing is every standard keystroke. Cmd-Q does not quit, and Cmd-A,
Cmd-C and Cmd-V do nothing in any text field, because those are implemented by
menu items with key equivalents rather than by the fields. This surfaced as
"renaming a recording is unusable", which is several steps away from the cause.

The Edit menu items target `nil` on purpose, so they travel the responder chain
and land on whatever has focus.

### Cmd-Q is intercepted ahead of the menu, not rebound in it

`QuitConfirm` asks once before quitting, ported from Anarlog because Cmd-Q sits
next to Cmd-W and Cmd-Tab and the cost of hitting it by accident here is a
meeting that stops recording mid-sentence.

It works with a **local event monitor**, which runs before `NSApplication`
dispatches the event and therefore before the main menu matches its key
equivalents. Returning nil means the Quit item never sees the keystroke, so
`MainMenu` needs no change and there is no second Quit action to keep in
agreement with the first. Nothing else is ever swallowed: only Command and Q
with no other modifier held.

Three consequences, all measured on the running app with `LISTEN_DEBUG=1`,
which traces the state machine because an event monitor otherwise leaves nothing
behind to inspect:

1. **The first keydown is swallowed, so the matching keyup may never arrive.**
   The state can still be `held` when the second press lands, so a second press
   confirms from either state rather than only from `armed`.
2. **The status bar item's Quit is not intercepted.** Menu tracking runs its own
   event loop and does not go through `sendEvent`, so Cmd-Q with that menu open
   quits at once, as does clicking either Quit item. That is deliberate:
   reaching for a menu item is already a decision, and it means there is always
   an unconfirmed way out, so no hidden override keystroke is needed.
3. **Quitting still goes through `applicationWillTerminate`**, which stops
   capture, so a confirmed quit mid-meeting finalises the WAV headers and leaves
   the recording in staging for `adoptStaged()` to promote at the next launch.
   The prompt says so on its second line rather than leaving it to be found out.

Synthesised keystrokes are a flaky way to test this: two `System Events`
keystrokes 0.4 s apart delivered only one press on the first attempt, which
looks exactly like the confirm step not working. The trace is what tells the two
apart.

### The sidebar width fought the split view

The first library window was a bare `NSSplitView` with
`widthAnchor` constraints on both sides. Dragging the divider snapped straight
back: the constraints and the split view were both trying to own the same
number and the constraints won on the next layout pass.

`NSSplitViewController` with `minimumThickness` and `maximumThickness` owns it
properly, and `DetailView` no longer carries a width constraint of its own.

Two things are easy to get backwards after that:

1. **Holding priority.** The sidebar's has to be *higher* than the content
   pane's, so resizing the window moves the right-hand edge. The default is the
   other way round, which rewrites the saved width on every window resize and
   looks exactly like the sidebar refusing to stay put.
2. **Ordering.** Set the window's frame autosave name before the split view's.
   Restoring the frame resizes the window, and a resize redistributes the
   split, so the other order overwrites the divider position with whatever the
   resize produced.

Verified by writing a width of 380 into the autosaved defaults, relaunching and
reading it back.

### The transcript opened near the end of the meeting

A freshly selected recording opened on its last few turns with half a paragraph
cut off above them, which reads as a rendering fault rather than as a scroll
position. `renderTurns` now scrolls to the top itself.

Two things are easy to get wrong here, and both were got wrong once:

1. **Use `scrollToVisible`, not the clip view's origin.** `scroll(to:)` has to
   be handed the document height *minus* the viewport height. Hand it anything
   else, the document height for instance, and the transcript goes entirely out
   of sight, leaving an empty pane under the player.
2. **The top is `stack.bounds.maxY`, not zero**, even though
   `TopAlignedClipView` is flipped. Flipping the *clip view* decides where a
   short transcript sits and which way the scrollers run; it changes nothing
   about the stack view's own coordinates, where the first turn is still the
   one with the highest y. The two flags read as if they should agree.
   Measured both ways on an 80 minute recording: y = 0 opens on the last turn,
   y = maxY - 1 on the first.

### A peak envelope of a meeting is a solid block

The scrubber's first version stored the peak amplitude per bucket, which is
what a waveform usually means. At 1400 buckets across an 80 minute meeting a
bucket is three and a half seconds, and the loudest instant in three and a half
seconds of speech is close to the loudest instant in the whole recording, so
every bar came out near full height and the waveform carried no information at
all.

`Waveform.make` stores **mean energy** per bucket instead, which separates
talking from pausing and is the shape somebody scrubbing a meeting is looking
for. `version` exists on the stored envelope precisely so a change like this
recomputes the caches rather than drawing old numbers under new rules.

Normalising it for display is also the opposite of the rule in `Mixdown`, and
deliberately so: playback volume has to stay true to the recording, but a
scrubber drawn at true amplitude is a flat line for anyone who recorded
quietly.

### Sentence highlighting is search, not arithmetic

The playhead highlights the sentence inside the turn, which needs to know where
each ASR sentence sits in the turn's text. `turns.json` and `transcript.json`
are written together, so the ranges could be rebuilt by repeating the join that
`Merge.turns` does, but an **imported** recording's turns were assembled by the
Python pipeline and its sentences would then land one word out.

`Merge.sentences` therefore searches the turn text for each segment's text,
carrying a cursor forward so a repeated sentence matches the right occurrence,
and skips anything it cannot find. Measured over the real library, 22
recordings and 12,600 segments: **12,596 located, every turn but one covered**.
The four misses are one-word segments whose text occurs earlier in the same
turn, and a miss costs that sentence its highlight and nothing else, which is
the point of skipping rather than guessing.

Sentences and not words because that is the finest timing mlx-audio exposes.
See the note above; if word timings ever arrive, this function takes a finer
input rather than being replaced.

### Building the mixdown on the main thread froze the first press of play

`Mixdown.make` reads both tracks and encodes an m4a, which for an hour-long
meeting is seconds of work. It used to run inline in the button's action, so
the window locked up with the play button stuck down and no sound. `withPlayer`
now does it on a detached task and creates the `AVAudioPlayer` back on the main
actor. The view keeps its own `position` rather than reading the player's, so
scrubbing moves the playhead immediately and the player is told where to start
when it finally exists.

### The legacy voiceprints are a different space with the same dimension

`meet_transcriptions` stores pyannote embeddings; Listen uses FluidAudio. Both
are **256-dimensional**, which is the whole danger: importing the old vectors
into `embeddings.json` raises no error anywhere, produces no exception, and no
length check catches it. Cosine similarity between a vector from one model and
a vector from the other is simply a meaningless number between -1 and 1, and it
flows straight into the sounds-like ranking looking exactly like a real score.

So `LegacyImport` deliberately imports everything **except** the vectors. The
names come across, because 25 of the 55 speaker slots in the old library were
labelled by hand and that is the part nobody wants to redo. `listen enroll`
then re-derives real FluidAudio voiceprints from the imported audio and matches
them to those names by overlap on the clock, which is the only thing the two
labellings share.

The same trap applies to the thresholds, for the same reason. See the
calibration note above.

### An imported recording has no mic track, and must not pretend otherwise

The legacy recorder produced one mixed file. It lands as `mix.m4a`, which is
what it is, and `Pipeline.run` treats a mix-only recording as the
everyone-track: diarize it whole, discover every speaker, and label nobody
"Me". The two-track shortcut relies on the user being the one in `mic.wav`, and
in a mixed track that is not true of anybody, so applying it would attach the
user's name to whoever happened to be first.

### The legacy m4a holds two tracks, and everything reads only the first

This one cost the most to find, because every symptom pointed elsewhere.
`listen enroll` produced one name per recording when the transcripts clearly
had two, and the diarizer reported **1 speaker across 219 turns of an 80 minute
two-person call** without erroring.

A clustering threshold sweep came back completely flat: 1 voice at 0.6, 0.5,
0.4 and 0.3. A parameter that changes nothing is the tell. The audio really did
contain one voice, because the file has **two audio tracks**, a stereo one
carrying what the Mac was playing and a mono one carrying the microphone, and
`AVAsset` handed over only the first. Confirmed by transcribing each track: one
holds the far end and the other holds the user.

So `AudioExtract` splits them on import, into the same `system.wav` and
`mic.wav` a native recording produces, and the whole two-track pipeline applies
to an imported meeting unchanged. Classification is by channel count rather
than track index, because stereo-means-system and mono-means-microphone is a
property of what they are rather than of the order this recorder wrote them in.

### A known speaker count is a good prior, and a bad one applied to one track

`Diarizer.run(_:expecting:)` sets `numSpeakers`, which is far stronger than any
threshold when the number really is known. It has to be applied to the right
audio, though: forcing 2 onto a system track that holds only the far end split
that one person into two voices, and the numbers looked plausible (532 s and
99 s) rather than obviously wrong.

So the prior is used only where the count is actually known for that track: 1
for a microphone track, the transcript's named count for a single mixed track,
and nothing at all for a system track, whose population is exactly what is
being asked. `Enroll` then attaches the microphone's voiceprint to whichever
named speaker the system side did not account for, which is the user.

### Synthetic voices measured the model's ceiling, not the task

The voiceprint thresholds were first calibrated on `say`-generated speech,
which gave same-person pairs of 0.979 to 0.995 and a suggested match threshold
of **0.72**. Re-measured on 14 voiceprints from real meetings across 5 people:

    same person       min +0.668  median +0.807  max +0.901
    different people  min -0.091  median +0.136  max +0.371

The worst genuine same-person pair is **0.668**, below the synthetic threshold.
Shipping 0.72 would have refused to suggest a person the bank had already heard
four times, and it would have looked like the feature simply not working rather
than like a number being wrong.

One TTS voice reading two scripts is nearly identical to itself. A person on
two days, on two microphones, in two rooms, is not. The different-person side
moved the other way (0.597 synthetic against 0.371 real), so both errors pushed
toward a threshold too high to be useful.

The thresholds are now 0.47 and 0.57, one third and two thirds across the real
gap. The lesson generalises past this feature: synthetic audio is fine for
checking that a pipeline runs, and worthless for choosing a threshold.

### A silent track must not cost a transcript

FluidAudio throws "No speech detected in audio" rather than returning nothing,
and plenty of recordings genuinely contain a silent track: a webinar nobody
spoke into, a call taken on mute. That exception used to abort the whole
recording, so a meeting with one live track produced neither voiceprints nor,
in `Pipeline`, a transcript.

Both now catch it. `Enroll` takes whatever the other track gives; `Pipeline`
keeps the transcript and puts everybody under one label, because a transcript
with imperfect speakers is worth enormously more than no transcript.
