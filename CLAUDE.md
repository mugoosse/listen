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

#### The chunk length depends on the machine, so two Macs disagree

`ASR.chunkSeconds` is 600 above 12 GB of installed memory and 120 at or below
it. The 3.28 GB peak that made 600 s the answer was measured here, on 128 GB
with nothing else running. An 8 GB M1 Air is the entry Mac of the entire Apple
Silicon era, and on one of those, 3.28 GB alongside the browser and the video
call the meeting is *in* is the same Metal OOM that killed the whole-file pass.
It would land an hour in, after the recording, where it costs the transcript
rather than a retry.

120 s is not a guess at a safer number, it is Speak's, which has shipped on
8 GB machines throughout. The trade is real and it is the right way round: an
hour-long meeting on a small Mac carries about 33 corrupted words instead of 6,
which is worth paying when the alternative is no transcript at all. Nothing
changes on a machine with the memory to spare.

The consequence is that the same file transcribed on two Macs has a different
number of seams and therefore a different number of corrupted words, so
`listen transcribe` reports the chunk length and the seam count on every run.
Without that, "my transcript has more glitches than yours" has nothing behind
it to check. `LISTEN_CHUNK` still overrides both, and still exists for
measurement rather than for users.

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

### Changing the microphone mid-meeting silently ended the mic track

Reported from a real 49 minute call: the other speaker is at 100% of talk time
and the user is at 1%. "I started without my headphones then I switched to it,
so it only got the first sentence." Capture kept running, the file was valid,
and nothing anywhere reported an error.

Reproduced exactly by changing the input device's sample rate 8 s into a 26 s
recording: **mic 8.6 s against system 26.0 s**, no error, no warning, no trace.
`AVAudioEngine`'s tap simply stops being called and never resumes, so an hour
of the user's own voice is missing from a recording that looks finished.

**The obvious fix does not work, and this is the part worth reading.** Measured
against AppKit directly, one engine per row, with the input device pinned the
way `selectDevice` pins it:

| signal | when it fires |
|---|---|
| `AVAudioEngineConfigurationChange` | once, at `engine.start()`, and **never** at the hardware change |
| `engine.isRunning` | stays `true` for the whole outage |
| `kAudioDevicePropertyNominalSampleRate` listener | at the instant of the change |
| `kAudioDevicePropertyStreamFormat` listener | at the instant of the change |

So the notification every guide points at is the one thing that does not fire
here, and the engine reports itself healthy throughout. Core Audio's own
property listeners are the only signal, which is why `watchHardware` reaches
past `AVAudioEngine` to `AudioObjectAddPropertyListenerBlock`.

The tap does resume by itself if the device ever returns to the format the tap
was installed with. That is why the bug reads as "only the first sentence":
nobody switches back mid-call.

Three things hold it together:

1. **A watchdog on the symptom, not on the causes.** `checkForStall` rebuilds
   the engine after `stallGrace` (2 s) with no samples, whatever stopped them.
   The listeners are the fast path at about a third of a second; this is what
   covers the causes nobody has reproduced yet, which is the class this bug was
   in. `LISTEN_MIC_NO_LISTENERS=1` turns the fast path off so the backstop can
   be exercised at all, because otherwise the listeners always win and it can
   never be tested. Verified that way: frames frozen at 121033, idle climbing
   0.5 s to 2.5 s, then a restart.
2. **The gap is padded with silence, never closed up.** The two tracks are
   separate files with no timestamps in them, so a sample's position in the file
   **is** its position on the clock. Appending post-restart audio straight after
   pre-restart audio loses no word and moves every word after it earlier, which
   silently reattributes the rest of the meeting. `WAVWriter.pad(to:)` measures
   against the wall clock rather than against the last gap, so several restarts
   in one meeting cannot accumulate.
3. **It follows rather than merely survives.** `selectDevice` re-resolves
   `Settings.resolvedMicrophone` on every restart, so plugging in a headset moves
   the recording onto it. Only when no specific microphone was chosen: somebody
   who picked one in Settings meant it.

Counted rather than hidden, and logged to stderr rather than behind
`LISTEN_DEBUG`, for the reason the dictionary counts are. The gap is silence,
so a finished file is indistinguishable from somebody not talking, and the
seconds it costs are not recoverable from anything else on disk.

#### The two tracks did not share a zero

Found while measuring the above, and older than it. Each recorder timed from its
own first sample, and the system track starts second: it has a tap to create, an
aggregate device to create, and `deviceFormat` polling for up to two seconds.
Measured at **three seconds** behind the microphone on a busy machine, which is
three seconds of every turn being attributed to the wrong side, for the whole
meeting, with nothing downstream able to tell.

`Capture.start` now takes one `origin` and hands it to both, and each pads its
own head up to it. Measured after, over three runs: the two tracks land within
0.2 s of each other.

This is also why a mid-recording restart cannot simply anchor to "when the mic
started". Both files have to measure from the same instant or the padding fixes
one misalignment by introducing another.

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

### A sentence is edited, and a segment is what gets written

Right-click a sentence in the transcript, choose Edit Sentence, correct it, click
away. What lands on disk is one `LabelledSegment`, not the paragraph.

That is the whole design and it is not a detail. A turn is a fold over segments
(`Merge.turns`), nothing records the reverse, and `TranscriptEditor` rebuilds
`turns.json` from the segments on every speaker change. A correction written to
the paragraph would therefore survive until the next rename and then vanish, with
nothing on screen to explain where it went.

So `Merge.Sentence` carries `index`, the position of the segment it came from,
and `TranscriptEditor.retext` writes there. Sentence level rather than paragraph
level because `Merge.sentences` already locates every ASR sentence inside its
turn: the mapping is one to one, no diff is needed, and the timings and the
playhead highlight come through untouched.

`retext` is a **compare-and-swap**, not an index write. The index comes from a
pane rendered at some earlier moment and `.discard` removes segments, so an index
taken before one runs names a different sentence afterwards. The old text travels
with the edit and the write is refused if it no longer matches, rather than
applied to whatever moved into that slot. Both sides are trimmed, because the
window's copy is the substring `Merge.sentences` found in the turn and that
search uses the *trimmed* segment text: an imported transcript with surrounding
whitespace would otherwise fail the check and refuse every edit silently.

`change` therefore takes a closure returning `Bool`. A refused edit must not
leave a `.raw.json.bak` and a rewritten `turns.json` behind it.

#### The right-click never reaches the text field

This one is worth knowing before trying to do it another way. A selectable
`NSTextField` installs its **field editor on `rightMouseDown`**, before the
contextual menu is built, so hit testing lands on that `NSTextView` and an
override of `menu(for:)` on the field itself is never called. Measured directly,
because the opposite is the natural assumption:

    hitTest, unfocused:  TranscriptBody
    after rightMouseDown, currentEditor: NSTextView
    hitTest, focused:    NSTextView

So the menu is built by `TranscriptFieldEditor`, a field editor handed out by
`LibraryWindow.windowWillReturnFieldEditor(_:to:)` for `TranscriptBody` clients
and nothing else. That also settles how a click becomes a character: the field
editor is AppKit's own layout of that exact string at that exact width, so
`characterIndexForInsertion(at:)` cannot disagree with what is on screen. A
layout manager rebuilt on the side would differ by the cell's insets, which stays
invisible until a click near a sentence boundary quietly picks the neighbour.

The item is inserted at the top of `super.menu(for:)` rather than replacing it.
Look Up and Copy are why anybody right-clicks a transcript today.

#### The paragraph splits in three while one sentence is edited

Not an overlay on the sentence. A sentence in a wrapped paragraph starts mid-line
and ends mid-line, so it is not a rectangle and a field placed over it is either
the wrong shape or covers its neighbours. `TurnView` swaps its body for
`[before, field, after]` in a stack, with the two context labels dimmed. Every
word stays on screen and there is no doubt which part is live.

The width has to be stated: a vertical `NSStackView` sizes an arranged subview to
what it asks for, and a wrapping label with no definite width asks for one long
line, so `fill(with:)` pins each piece to the stack's width or the paragraph
stops wrapping the moment it goes in.

Two consequences that were nearly bugs:

1. **`highlight` no-ops while editing.** It runs twenty times a second and
   rewrites the paragraph's attributed string, which is not on screen then.
2. **`applyEdit` reloads rather than calling `show`.** `show` stops playback and
   puts the playhead back to zero, and correcting a word is something people do
   while listening to it. `renderTurns(scrollToTop:)` exists for the same reason:
   a reload that jumps to the top of an hour-long meeting loses the reader's
   place after every correction.

Clicking away commits, which needed the same fix the title field needed:
`NSView` does not accept first responder, so `DetailView.endEditing()` now lets
go of both fields and every control that swallows its own click calls it.

`listen edit <id> "<old>" "<new>"` drives the same `TranscriptEditor.retext`, for
the reason `listen label` exists. It matches on the old text rather than a
segment number, because a number is not something anybody has, and it refuses
rather than guesses when two sentences read the same. The window can edit those
two separately: `Merge.sentences` carries a cursor forward, so the first
occurrence in the turn maps to the first segment.

### The dictionary rewrites the library, and only the library

`CustomDictionary` is ported from Speak, where the rules were tuned. Speak has
three mechanisms; Listen has two, because the third is a spelling hint in the
polishing model's prompt and there is no polishing model here. What is left is
pure text: a **term** matched by sound, and a **correction** matched exactly.

The rule for where it applies is one sentence with no exceptions: **the
dictionary rewrites what goes into the library**. So it runs in `Pipeline.run`
and nowhere else. A bare `listen transcribe some.wav` prints what the model
actually said, because that command exists to separate a model problem from a
capture problem and a dictionary quietly editing its output would make it lie.
`listen dictionary test "<sentence>"` is how a rule is checked without a
recording, and it is not a nicety: whether "Gusens" becomes "Goossens" depends
on a consonant code and on `/usr/share/dict/words`, so nobody can predict it by
reading their own rule.

Applied **after** `Merge.clean`, deliberately. The cleanup counts exist to
answer whether Parakeet needs the Whisper-era repetition rules at all, and that
is only answerable against Parakeet's own output. Measuring it after the
dictionary had rewritten the text would count rules firing on words the model
never produced.

Per segment rather than over the whole transcript joined up: a segment is one
ASR sentence, so every real term sits inside one, and the alternative means
splitting the result back apart against text whose length changed.

**Everything is counted, and that is the load-bearing part.** Speak's transcript
is text you are about to paste and can see; Listen's is an archive of a meeting
nobody may read for a week. A bad rule here rewrites recordings quietly and the
only surviving evidence is the audio. So `apply` returns how often each rule
fired, `Pipeline` totals it into `StoredTranscript.dictionary`, and both the
Dictionary pane and `listen dictionary list` report it. Same arrangement as
`cleanup`, same reason: a rule nobody can measure is a rule nobody can argue
about. Unlike the cleanup counts it is logged to stderr rather than hidden
behind `LISTEN_DEBUG`, because cleanup is the app tidying up after the model and
this is the user's own list rewriting their own meeting.

#### Adding a field to `StoredTranscript` needs `init(from:)` by hand

Swift's synthesized decoder throws `keyNotFound` on a missing key **even when
the property has a default value**. Adding `dictionary` to the struct alone
would therefore have made every `transcript.json` written before it fail to
decode, and that failure is silent in the worst possible way: `storedTranscript`
returns nil on a decode error, so the whole library would have gone on looking
untranscribed with the transcripts still sitting on disk. Measured both ways on
a real 709-segment transcript: the synthesized decoder fails, the hand-written
`init(from:)` with `decodeIfPresent` reads it. The custom init lives in an
extension so the memberwise init survives.

#### Two dictionaries, not one shared file

Speak's is at `~/Library/Application Support/speak/dictionary.json` and Listen's
is beside its recordings. Sharing one file would save maintaining two lists of
the same people's names, and it would mean two apps rewriting a document that is
written whole every time, where the loser of a race loses entries rather than
getting a merge. Import and export carry the list across instead: `encode`
deliberately writes **Speak's** shape, and `decode` is deliberately liberal
(Speak's, a bare array, TypeWhisper's key names), so the two apps read each
other's exports and the trip works in both directions. `listen dictionary import
--from-speak`, and the Speak section of the pane, are the one-press version.

Measured: importing Speak's real dictionary brought over 5 terms and 35
corrections and skipped 3 already present.

A term too short to be matched by sound is stored and does nothing, which from
the outside is indistinguishable from the feature being broken. `eligible` is
therefore public, the pane greys those rows, and `listen dictionary add` says so
on the way in.

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

Three rules, all learned by measurement, all invisible from the code:

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
3. **A view that has *already* left the window does not close the popover, it
   crashes the app.** Rule 1 is the polite half of this and reads as though it
   were the whole of it. `showRelativeToRect:ofView:preferredEdge:` raises
   `NSInvalidArgumentException`, "view has no window. You must supply a view in
   a window", and nothing catches it.

It is also shown on the next runloop turn rather than inline, because a popover
put up from inside a control's own action arrives while the mouse event is still
being dispatched.

#### No window is the only thing that raises

Worth knowing exactly, because the natural fix for rule 3 is to start
sanity-checking the rectangle too, and there is nothing there to check. Measured
against AppKit directly, one popover per row:

| positioning view | result |
|---|---|
| in a window, own bounds | opens |
| never in a window, or removed from one | **raises** |
| hidden | opens, `isShown == false` |
| zero height, which is a collapsed chips row | opens, `isShown == false` |
| rect 4000 points outside its bounds | opens, `isShown == false` |
| `NSZeroRect` | opens, documented to mean the view's bounds |

So a rect that is wrong costs a popover nobody sees, and an anchor that is gone
costs the process.

#### The pane is the anchor, and the rect is taken before the edit is committed

Shipped in 0.2.0 and reported from a real session: rename a recording, click a
speaker in the transcript, `SIGABRT`. Reproduced against the same build,
identical frames, `-[NSPopover showRelativeToRect:ofView:preferredEdge:] + 244`
under `_dispatch_call_block_and_release`, which is the deferred block above.

Every speaker click calls `endEditing()` first, because a control swallows its
own click and the title field would otherwise keep the caret. That commits the
title, a committed title reloads, and a reload runs `renderTurns`, which empties
the transcript stack. So one line after `endEditing()` the view that was clicked
is out of the hierarchy, and it is *also* too late to call `convert(_:from:)` on
it: with no common ancestor left, the rectangle it returns is meaningless and
nothing reports that either.

`DetailView.editSpeaker` is therefore the one funnel for all three callers, and
it does the three steps in the only order that works: take the rect, then end
the edit, then point the popover at the pane, which is on screen for as long as
the transcript is. `PersonPopover.show` and `SpeakerPicker.show` additionally
refuse to show on an anchor with no window, with a `LISTEN_DEBUG` trace, so the
next caller to get this wrong loses a popover instead of the app.

Verified by driving the real window: the crash sequence now opens the contact
card, the unnamed-speaker picker and the chip's card, and the guard has not
fired once.

**Do not verify this with System Events.** `first application process whose
unix id is N` returned a *different* Listen when several were running, so the
first three attempts at this were inspecting the wrong process and reporting the
wrong library's contents. `AXUIElementCreateApplication(pid)` cannot pick the
wrong app.

### An `NSMenuToolbarItem` eats the first item of its menu

A pull-down takes item 0 as the button's own title and never draws it, and both
ellipsis menus in this window were built without knowing that. Measured on the
shipped 0.1.0 build by opening each one and reading it off the screen:

| menu | built | shown |
|---|---|---|
| recording, one selected | Export…, sep, Transcribe Again, Rename…, sep, Show in Finder, sep, Delete | Transcribe Again, Rename…, Show in Finder, Delete |
| recording, none selected | No recording selected | *nothing at all* |
| person | placeholder, Edit, Merge…, sep, Delete | Edit, Merge…, Delete |

So Export was missing for as long as the toolbar menu has existed, and the empty
case was worse than missing: one disabled item is the whole menu, AppKit does not
put up an empty menu, and pressing the button therefore did nothing and reported
nothing. `PersonPane` had already paid for this once ("Edit Contact was eaten and
the menu opened on Merge"), which is why its `menuNeedsUpdate` starts with a bare
`NSMenuItem()`.

`LibraryWindow` now does the same, but **only for the toolbar's menu**. The
sidebar's right-click menu shares that delegate and is an ordinary contextual
menu, which shows every item it is handed, blank one included. Hence
`recordingActionsMenu` is built once and kept: the identity check is what tells
the two callers apart.

### The status menu is Speak's, refilled in place

`App.refreshMenu` is a port of Speak's `refreshMenu`, down to the order: the app's
name with the mascot at 15 points, the verbs, whatever is wrong, the library, a
Recent list, then Settings, Check for Updates, About and Quit. The row that names
the app exists for Speak's reason and it is stronger here, because Listen's icon
is one of twenty in a menu bar and the only other place the app said its own name
was `About Listen`, eight items down.

Four things about it are load-bearing.

**One `NSMenu` for the life of the process.** `menuWillOpen` calls `refreshMenu`,
which does `removeAllItems` and refills; handing the status item a *new* menu from
that callback would swap the menu out from under the one being displayed. This is
also why `rebuildMenu` and `refreshMenu` are two functions. `rebuildMenu` follows
capture everywhere else it shows: the icon, the tooltip, the floating panel and
`LibraryWindow.recordingChanged()`, which rebuilds the sidebar and the toolbar.
None of that is something opening a menu asked for.

**The clock is only right because of `menuWillOpen`.** `Capture.onChange` fires on
the edges of capture and not per second, so `Recording, 0:00` drawn once at the
start stayed 0:00 for the length of the meeting. The library count and the Recent
list are re-read there for the same reason.

**`autoenablesItems` is off, and that is deliberate.** Left on, an item is enabled
whenever its target responds to its action, which silently ignores the one line in
this menu that says otherwise: Sparkle disables its own check while one is running,
and `Updater` has no `validateMenuItem` for AppKit to ask. So enablement is stated,
and the rows that only report something go through `info()`, which sets **both** a
nil action and `isEnabled = false`. Measured against the built app either way: the
rendering is identical, so the dimmed rows are not evidence that the old form was
doing the work.

**A recent row carries the recording's id in `representedObject`, not its index.**
The menu is rebuilt on every open and a recording can arrive or be deleted between
two of them, so an index taken from the menu drawn last time names a different
meeting by the time it is clicked. Speak's `copyRecent` keys on `tag` and is right
to: its five entries are re-read from the same file in the same handler.

Two differences from Speak, both because a meeting is not a dictation:

1. **Clicking a recent row opens the recording**, where Speak copies the text. A
   dictation *is* its text; a meeting is an hour of audio, a transcript and a set
   of speakers, and there is nothing useful to put on a pasteboard.
2. **The stamp is a time only for today**, and the date otherwise. Speak's history
   is the last five things you dictated, all minutes old; a library spans months,
   and `15:14` on a recording from Tuesday is a lie nothing on the row corrects.
   The cost is that the titles no longer line up in a column, which is what a tab
   stop in an `attributedTitle` would fix and is not worth an attributed string
   whose highlight behaviour would then need checking.

The recording in progress is deliberately **not** in Recent. It is the two rows at
the top of the same menu, and listing it twice puts one meeting under two verbs.

`LibraryWindow.open(recording:note:)` gained `activate` and `makeKeyAndOrderFront`
for this. Its first callers were note links inside a window that was already key,
so it built the window without ever showing it; from the menu bar that is a click
that appears to do nothing. Verified by closing the window through its accessibility
close button, pressing the first Recent row, and finding the library up with that
recording selected and its transcript rendered.

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

#### The app the call was in is a field, and never the title

Blackbox names the recording after it (`title: titlePrefix + appName`), which is
where the imported library's `2607-17-Google Chrome` comes from. Listen must not:
`Recording.isUntitled` is the literal string `Untitled`, and it is the gate on
calendar naming and on the grey placeholder in the detail pane. A recording
called "Google Chrome" is one the calendar will never name, so copying Blackbox
here would have switched off a feature two screens away.

So `Metadata.app_bundle_id` and `app_name`, shown in the detail subtitle, in
`listen show`, and as the app's **icon** in the sidebar row. An icon there
because that subtitle is already `18:04 · 33:12 · recording` inside a 280 point
sidebar and a fourth fact truncates.

Both fields, for the reason `calendar_people` is a snapshot: the identifier is
the stable fact, but `AppNames.display` resolves through `NSWorkspace` and an
uninstalled app resolves to nothing, so the fallback is the name it had at the
time rather than `net.whatsapp.WhatsApp` printed as though it were a name.
`AppNames` caches both lookups now: each is a Launch Services query plus a
filesystem read, and they are on the path of a sidebar rebuilt on every keystroke
of the search field.

Where the identifier comes from, per path:

| started by | source of the app |
|---|---|
| detection | the bundle id that fired it, already in hand |
| Record, or `listen record` | `MeetingDetector.activeCallers().first`, one HAL read |
| joined *after* Record | `Capture.noteApp`, from the detector's next poll |
| imported | `perAppBundleID` and `appName` from the legacy `metadata.json` |

`noteApp` writes once and never again. The first app seen is the one the
recording is of, and letting a later poll overwrite it renames the recording
after whatever made noise last. The poll that feeds it deliberately ignores the
skip list: that list says which app never to *ask* about, and the app a call is
in is a fact rather than a question being put.

**Detection used to write the bundle id into `source`**, which is otherwise
provenance (`manual`, `cli`, `imported`), and nothing ever read it. `source` is
now `detected` and the id has its own field, but recordings made before that are
on disk saying `source: "com.google.Chrome"`. `Recording.appBundleID` derives
across both rather than a migration pass rewriting every file to tidy a field
nothing had read, which is the same choice as `effectiveState`. A bundle
identifier has a dot in it and none of the four provenance words does.

`listen import <path> --apps-only` backfills the recordings imported before the
field existed, prints without writing under `--dry-run`, and fills only what is
empty. Measured on the real library: 35 recordings gained an app, and with the
`source` derivation covering the thirty-sixth, every recording now shows one. `avconferenced` is in there and has no
icon, because it is a daemon rather than an app: the row shows the name in the
detail pane and no icon in the list, which is the right answer rather than a
missing one.

### The calendar needs no account, because macOS already has one

Anarlog supports three providers two ways. Apple Calendar is local EventKit and
works signed out. **Google and Outlook are neither**: OAuth is brokered by
Nango, a hosted third party (`apps/web/netlify/edge-functions/oauth-callback.ts`
is a 308 to `api.nango.dev`), the tokens live at Nango and never on the Mac, and
every read is proxied through Anarlog's own axum API behind a Supabase JWT
(`crates/api-calendar/src/google/routes.rs`) and gated on Pro billing. That is
an account, a backend, an OAuth client and a billing system for the privilege of
reading a calendar.

Listen needs none of it, because **macOS did the OAuth already**. An account
added in System Settings, Internet Accounts syncs into the system calendar
store, and EventKit hands it over with no distinction from iCloud. Measured on
the development machine: 16 calendars, including two separate Google accounts
arriving as calDAV, with attendee addresses and organizers on the events. One
TCC prompt, no network connection, and therefore no new entry in
`InternetAccessPolicy.plist`.

What is actually given up is one thing: somebody who has not added their work
account to macOS. The Permissions pane says where to do that. Server-side push
and sync tokens are given up too and replaced by `EKEventStoreChangedNotification`,
which is the better shape for a local app anyway.

`MeetingCalendar` is read-only and has no write path at all, deliberately: the
one thing worse than not naming a recording is editing somebody's calendar.

#### Ten minutes, and the measurement that fixed it there

`MeetingCalendar.window` is 10 minutes, anchored on the **start** of the
recording rather than on overlap. Measured over the 47 recordings then in the
library, where `named` counts the seven somebody had titled by hand:

| window | matched | named | ambiguous |
|---|---|---|---|
| 5m | 9/47 | 3/7 | 1 |
| 10m | 14/47 | 6/7 | 2 |
| 15m | 14/47 | 6/7 | 2 |
| 20m | 14/47 | 6/7 | 2 |
| 30m | 16/47 | 6/7 | 4 |

Ten, fifteen and twenty are identical, so the widest of them buys nothing.
Thirty buys two matches and **both are wrong**: a WhatsApp call matched a solo
calendar block 26 minutes away called "Review the Q3 launch Reel".
Since the title is applied without asking, wrong is the expensive direction.

Anchored on the start because overlap is not evidence of anything on a Mac that
is switched on all day.

#### Joining early is not in that table, and it is what a link invites

Every offset in the measurement above is between -9 and +0 minutes, so the
sample contains nobody who opened the invitation's Meet link well before the
meeting. That is not because it is rare. A real recording: link opened at 17:19,
detection started capture there, the calendar said 17:45. Twenty-six minutes, so
the window missed it by sixteen and the meeting stayed "Untitled" with no guest
list and therefore no speaker suggestions either.

`MeetingCalendar.candidates` now has a second rule: a meeting that **began while
the recording was running**. Three things about it are load-bearing:

1. **It is asymmetric, and that is the whole safety argument.** "The recording
   overlaps the event" would also match a recording that started inside somebody's
   hour-long focus block, which is exactly the wrong match the 30m row bought.
   This rule claims something much narrower: capture was already running at the
   minute the invitation said the meeting would start.
2. **It can only add a match, never change one.** Anything it finds is by
   definition further than `window` from the recording's start, so it sorts
   behind every first-rule candidate and the winner of a non-empty first rule is
   untouched. The fourteen above are still those fourteen.
3. **Somebody else has to be on the invitation.** It reaches as far as the
   recording is long, which on an 80 minute meeting is well past the 30 minutes
   already measured as too wide, so it wants a second piece of evidence that this
   is a meeting rather than a block. Measured over the 42 recordings now in the
   library: with and without that check the rule finds the **same one match**, so
   today it costs nothing and it bounds the looser rule.

Measured after: 15/42 matched, the fourteenth-plus-one being the recording this
was written for. `listen calendar match` and `backfill` both print
`[began while recording]` on anything the second rule found, because a match
26 minutes out is otherwise impossible to reconcile with a documented window of
ten.

`Capture.stop()` writes `metadata.duration` **before** it asks the calendar
again. The recording's span is the whole of the second rule and it is zero until
that line runs, so attaching first judges a 33 minute recording as though it had
lasted an instant. The attempt at `start()` still has a zero span, deliberately:
capture has no length yet, so only the window rule applies there.

#### The title is applied silently, and two guards are what make that safe

`MeetingCalendar.attach` writes the title only when `Recording.isUntitled`, and
`Metadata.calendar_event_id` doubles as the "already looked" flag so a second
pass can never revisit a decision. `Capture` calls it twice: at `start`, so the
live sidebar row carries the meeting's name for the hour it is running rather
than saying "Untitled" throughout, and again at `stop` for the meeting that was
put in the calendar after it began. The second call is a no-op whenever the
first one found something, which is what protects a title edited mid-call.

**`isUntitled` is the literal placeholder and nothing cleverer**, and the
consequence surfaced immediately: `listen calendar backfill` matched 14 of the
50 recordings in the real library and renamed **none of them**, because every
one already carried a title from the legacy Python import
(`2607-17-Google Chrome` and the like). That is the right answer. Deciding which
existing titles are "really" machine-generated would be a heuristic, and a
heuristic that overwrites a meeting's name is the thing this design is avoiding.
New recordings start as `Untitled` and are named; imported ones keep what they
have and gain a guest list.

`backfill` is a dry run without `--apply`, and is deliberately not something
that happens at launch. Renaming fourteen recordings at once without being asked
is the surprise the rest of this app avoids.

#### The meeting link is in the notes, not in `event.url`

Measured: `event.url` was nil on **every** Google event on this machine, and the
Meet or Zoom link sat in the notes body. `MeetingLink` therefore searches the
notes and the location, with a bare `https?://` fallback after the known
patterns, which is Anarlog's `parse_meeting_link` and the same argument
`MeetingDetector` makes for not matching on a list of bundle identifiers.

#### An attendee's name is usually their email address

The number that shaped the whole speaker-suggestion design. Over 72 events with
attendees on this machine:

    attendee entries  140
      human name       22
      email as name   118
      no name at all    0
      no mailto url    34
    organizers with a human name  32/72

So every entry yields either a name or an address and never nothing, and the
address is the reliable half. There is no public email property on
`EKParticipant`: it is `participant.url` with a `mailto:` scheme, which is also
where Anarlog reads it.

Two more things a real invitation did that the first version got wrong, both
fixed in `CalendarEvent.init`:

1. **The same person arrives more than once.** One event returned Ryan as
   organizer with no address, again as an attendee with no address, and a third
   time under a work address. Deduplication keys on the address when there is
   one and the name otherwise, which deliberately keeps two *different*
   addresses apart: whether a personal and a work address are one human is
   exactly the question the contact book exists to let somebody answer once.
2. **An entry with no name and no address at all**, which became a button
   reading "(unnamed)". Dropped.

#### The contact book is a second route to the identity Listen already has

`ContactBook` maps addresses to the label written in transcripts, **many
addresses per person**, which is the whole point: the same human is
`ryan@example.org` on one invitation and `ryan.mitchell@example.com` on the next.
It is not the macOS Contacts framework, which would cost a second TCC prompt and
can only find people already in the address book, which the far side of a work
meeting usually is not.

It is written **only when a human asserts something**. Picking a suggestion in
`SpeakerSheet` asserts which attendee this speaker is; typing a name freehand
asserts nothing and links nothing. Same standard as `People`: two recordings
hold the same person when somebody said so, not when a score agreed.

The pick stores the **address** and the field supplies the **name**, and keeping
them apart is what makes correcting a guess useful rather than destructive:
picking "Byjenna0x" and typing "Jenna" over it files that address under Jenna.

`People.rename` calls `ContactBook.rename`, and it has to. The book is keyed on
the transcript label, so without it a renamed person's addresses point at a name
nobody has any more and **nothing reports it**: the suggestions simply stop
appearing, which reads as the calendar having broken rather than as a stale key.
Verified with a round-trip rename on a real recording.

`ContactBook.suggestedName` is the weakest of the three sources and never
applied on its own: `emily.carter@` gives "Emily Carter",
`ryanmitchell@` gives "Ryanmitchell", and role addresses (`noreply`, `info`,
`updates`) return nil rather than becoming a person, because a book that learns
those starts suggesting them for real speakers.

#### One `EKEventStore`, and every read behind a lock

Anarlog ships a standalone reproducer for this
(`crates/apple-calendar/examples/repro_empty_calendars.rs`): concurrent event
and calendar reads make `list_calendars` return **zero**, which raises no error
and is indistinguishable from a Mac with no calendars on it. `MeetingCalendar`
keeps one store for the process and serializes every read through an `NSLock`.
Listen does not currently read concurrently, but that is a property of today's
callers rather than of the file, and the bug leaves nothing behind to debug
from.

The store is `internal` and not private for a related reason:
`Permissions.requestCalendar` must ask on **this** store. A grant landing on a
different instance leaves this one answering from the access it was created
with, and every read afterwards returns nothing.

#### Optional fields do not need a hand-written `init(from:)`

The trap recorded against `StoredTranscript` above is that Swift's synthesized
decoder throws `keyNotFound` on a missing key *even when the property has a
default value*. It does **not** apply to `Optional` properties: those are
decoded with `decodeIfPresent`, so `Metadata.calendar_event_id` and
`calendar_people` could be added without touching the memberwise init and every
`metadata.json` written before them still reads. Verified with `listen list`
over all 50 recordings rather than assumed. If either field ever becomes
non-optional with a default, that stops being true.

#### Onboarding has to ask, because nothing else will

The Settings pane is the **only** other place the calendar prompt can be raised
from, because macOS lists an app under Privacy, Calendars only once it has
requested. So without a setup step, anybody who never opens Settings never gets
asked and the feature is silently off for them, which is the same shape as the
installed CLI that is not on the `PATH`: present, and unreachable.

It sits between `systemAudio` and `model`, and its second button says "Not now"
rather than "Skip". Skip is what the microphone step offers, where declining
costs half of every recording; here it costs a name, and the wording should not
imply the two are the same.

`structuralKey()` had to gain `Permissions.calendar`. The prompt is answered
outside the window, there is no notification for it, and the 0.8 second poll
only re-renders when that string changes, so leaving it out means the pane goes
on saying "not granted yet" after the grant has landed.

The `done` pane mentions calendar naming **only when access was granted**. It is
there for the same reason the detection sentence is, because it happens without
being asked each time, and saying it to somebody who declined would be noise
about a feature they do not have.

#### `listen calendar` exists because matching leaves nothing behind

Same argument as `listen sources`. The title lands silently, so "why is my
meeting called that?" is otherwise unanswerable: the candidate that won, the
ones that lost, and the window they were judged in are all gone by the time
anybody looks. `listen calendar match <id>` prints all three, with the offset in
minutes per candidate, and it is what showed that two calendars on this machine
hold the same 15:00 meeting under different names ("Cowork Ryan" in Google,
"Kinsight: Ryan x Emily" in iCloud). Both tie at -1m, so the guest-list
tie-break decides, and which one wins is genuinely arbitrary. That is worth
knowing about rather than discovering through a title.

`backfill --refresh` re-reads a recording that is already attached, and only the
CLI passes it. The automatic path must not: a guest list that has already been
picked from is a decision, and replacing it with whatever the invitation says
today would quietly undo one.

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

#### One elapsed clock per screen, and the row is the one that always counts

Once the recording in progress had a row, the library counted the same seconds in
three places at once: the sidebar's Stop row, that row, and a toolbar button
sitting over the meeting's own title. Three copies of one number is not three
times the reassurance, it is a screen where nothing looks like the source.

The row keeps its clock, because it is the one place that is always on screen and
is about that recording rather than about the app. The toolbar's stop control
appears **only while the recording in progress is the one selected**, and takes
the place of People and Actions rather than the leading edge of the content: a
running recording has no transcript to export and no speakers to open, so on that
one screen stopping it is the only verb there is.

The sidebar's row stops being a control at all. It used to become a red Stop row
with a clock in it; it now keeps the words "New Recording" and greys, because the
only thing true of it during a meeting that is not said anywhere else is that
there is no second recording to start. A row that swaps its verb, its icon and
its colour is a row you have to read before you can trust what pressing it does,
and there were already two stop controls on screen. `SidebarRow.isEnabled` dims
the whole row and stops the hover and the action; the tooltip says where stopping
lives, because a greyed control with no reason beside it is the shape people read
as broken.

Red is on the state word alone, not on the line. `18:04 · 0:09 · recording` puts
the same clock and time every other row prints in the same colour every other row
prints them in, and colours the one word that is not. Colouring the line said the
clock was the alarming part rather than what it was reporting. `configure` builds
an attributed string for this, and each run has to carry the font: the monospaced
digits set on the field are not inherited, and without them the clock changes
width as it counts.

Two consequences:

1. **The toolbar is rebuilt on selection changes, but only during capture.**
   Which items belong now depends on what is selected. Outside a meeting that
   question has one answer, and rebuilding anyway is five items removed and
   re-inserted on every click in the list.
2. **`recordingChanged()` rebuilds last.** It selects the recording that just
   started, and `isShowingLive` is asked of the selection, so rebuilding before
   that leaves the stop control out for the length of the meeting.

Settings and People keep the stop control unconditionally while capture runs, and
so does the menu bar item. Those are now the only two ways to stop a meeting you
are not looking at, which is the trade this makes: one control on the screen that
is about that recording, rather than one on every screen.

### A sidebar reload is not somebody choosing a recording

`SidebarViewController.reload()` rebuilds the list and puts the selection back on
the same recording. Both halves post
`NSTableViewSelectionDidChangeNotification`: `reloadData` drops the selection and
`selectRowIndexes` restores it. Reported as a selection change, that runs
`onSelect`, which is `DetailView.show`, which **stops playback, puts the playhead
back to zero and rebuilds every turn.**

So every reload was blanking the pane and rebuilding it, and renaming a recording
or correcting a sentence while listening silenced the recording being corrected.
Measured: paused at 00:03, rename, 00:00. That is exactly what `applyEdit`'s
"targeted reload, not `show`" exists to prevent, and it was undone by the
`onChanged?()` on the line after it.

`reloading` suppresses the callback while the list is being rebuilt. Landing
somewhere new is still reported, at the end of `reload`, because then it is true,
and the deliberate cases already call `onSelect` themselves: `select(_:)` does it
when the id differs, and `LibraryWindow.reload()` re-shows the selected recording
explicitly so a transcript that has just finished appears without anyone clicking
away and back.

`DetailView.onChanged` reloads the list only, and no longer the pane that just
wrote the change: the pane is already showing what it wrote, either a title it
has in hand or a sentence it re-rendered in place.

Measured after: paused at 00:03, rename, still 00:03, with the row in the list
carrying the new title.

### The floating panel is sized from its strings, and one of them changes

`RecordingIndicator.layout` measures every frame from the text it is drawing,
which is the right call for a label that carries an app name. The clock is the
exception: it is laid out once by `show`, when it reads "0:00", and then
`setElapsed` rewrites it twice a second without anyone re-measuring. From ten
minutes in, the label is a character too narrow and the panel spends the rest of
the meeting reading "33:1". A cut-off clock is worse than no clock, because it
still looks like a time.

`setElapsed` therefore re-lays the panel out when the string's **length**
changes, which for `monospacedDigitSystemFont` is exactly when its width does,
and re-positions it because the panel is pinned to the right edge of the screen.
Once per digit, not twice a second.

It took ten minutes of a real meeting to see, which is the actual bug:
`LISTEN_PANEL=recording` could only ever show "0:00", because a preview launch is
recording nothing. `LISTEN_PANEL=recording:1994` now seeds the clock, and
`RecordingIndicator.previewElapsed` is what the tick reads instead of `Capture`.
Same argument as the affordance itself: a state that cannot be put on screen on
demand is a state nobody checks.

**A preview launch also stops before it touches the library.** It used to adopt
staged recordings, sweep staging and resume the queue like any other launch, so
looking at a panel beside the running app meant two processes transcribing the
same audio. `MainMenu.install()` moved above the check so a preview still has a
Cmd-Q; everything after it is skipped.

### Setting `editing = false` is not what closes the person editor

`PersonPane.render` is, and for a long time the only thing that called it after
a save was the roster re-selecting the same person. A **rename** is exactly the
case where that cannot happen: `PeopleNav.reload` and the window both re-select
by label, and the label they are holding has just stopped existing. Nothing
re-selected, nothing re-rendered, and the edit fields sat there with Cancel and
Save still under them. Rename looked like it had done nothing, with the
transcripts already rewritten behind it.

Two halves to the fix, and both are needed:

1. **`saveEdits` calls `render()` itself.** The pane closes its own editor
   rather than depending on somebody else re-showing it.
2. **`onLandOn(label)` replaces `onMerged`.** A rename, a merge and an unnaming
   all leave the roster selecting a name that is gone, and all three now say
   where the person went. `PeopleNav.select` returns `false` when the label is
   not in the roster, so the window can show the empty page rather than leaving
   the last one frozen. It used to return silently, which is the same class of
   failure one layer down.

**A rename that rewrites nothing is refused rather than followed.** Landing on
a name nobody has empties the pane, and from the outside that reads as the app
having deselected the person, not as a rename that failed. So `saveEdits` stops
and says so when `People.rename` changes no recordings and there were
recordings to change. Found by driving the real UI against a hand-written
`transcript.json` that was missing `wordLevel`: `StoredTranscript` would not
decode, `hasTranscript` was true, the rename silently rewrote nothing, and the
person vanished from the page. Both the CLI and the window said nothing.

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

#### A recording with no audio is not a job waiting to happen

The sentence above is load-bearing and it stops being true the moment a second
Mac can see the library. `SYNC.md` documents putting the folder behind a file
sync tool with the WAVs excluded, which is the right split because the audio is
8.3 GB of an 8.4 GB library and nothing but playback reads it. The consequence is
that the second Mac holds recordings it can never transcribe, and a recording
synced from the other machine arrives as `metadata.json` **before** its
transcript exists, so for those minutes it has neither.

Read literally, "audio exists and a transcript does not" would queue every one of
them at launch, run a job per recording that can only fail, mark each `failed`,
and race the real transcript on its way over. `effectiveState` derives the state
from the files rather than trusting the field, so the wrong state heals itself
and the only surviving evidence is a fan spinning up. That is the worst shape a
bug can take here.

`Recording.hasAudio` is the guard, and it lives in `Queue.enqueue` rather than in
`resume` because there are three callers (launch, `Capture` keeping a recording,
and Transcribe Again) and one rule. `enqueue` returns `Bool` so a caller that is
a control can say why instead of appearing dead.

Three things about it are deliberate:

1. **It tests the audio, not which device recorded it.** A `device` field would
   work and would be a schema change, a migration and a fact that can be wrong.
   The audio is already on disk, it is the thing actually required, and the rule
   stays correct if the WAVs are ever synced too.
2. **The mixdown counts.** An imported recording has only `mix.m4a` and
   `Pipeline.run` transcribes it as the everyone-track, so testing `tracks` alone
   would refuse to transcribe every legacy import.
3. **`hasTranscript` is not the test to use instead.** It is false in exactly the
   window this is about.

`LibraryWindow.validateMenuItem` greys Transcribe Again on the same property.
Both copies of that item go through that one function, the File menu's because it
targets nil and the toolbar's because it is validated the same way, so they
cannot disagree. `DetailView` reads `Recording.hasAudio` too rather than keeping
its own reading of the same folder, and its empty state says the audio is on the
Mac that recorded it rather than "Not transcribed yet", which on that machine is
a promise nothing is going to keep.

Verified against a real launch rather than reasoned about, using `LISTEN_LIBRARY`
to point the app at a two-recording library, one with a track and one without:

    [Listen] not queueing 2026-01-01-000000-NOAUD: no audio on this Mac

and the one with a track went on to load the model.

### Transcript edits do not live in the sheet that presents them

`TranscriptEditor` owns rename, discard and merge; `SpeakerSheet` only asks the
question. They are split so `listen label` exercises the exact code path the
window uses, rather than a second implementation that agrees with it right up
until it does not. There is no test target, so this is what verification of
speaker editing looks like.

The `.raw.json.bak` backup is written **once**, before the first edit. Writing
it on every edit would overwrite it with edited data the second time, and it
would no longer be a way back to what the model actually said.

### The model is cached twice, and deleting one copy does not test anything

`ModelChoice` names two directories under the same hub root, and they are not
alternatives:

- `downloadDirectory`, `models--mlx-community--parakeet-tdt-0.6b-v2`, the
  Hugging Face blob cache the transfer streams into.
- `cacheDirectory`, `mlx-audio/mlx-community_parakeet-tdt-0.6b-v2`, mlx-audio's
  own unpacked copy, and **the only one `isDownloaded` looks at**.

So `bytesUsed` sums them and `bytesOnDisk` takes the maximum, which is why the
Models pane reports about 4.9 GB for a model whose download is 2.5 GB.

The consequence cost a testing round. Moving `mlx-audio` aside to force a
first-run download does not force one: the blob cache is still there, so
`resolveOrDownloadModel` finds it populated and re-copies locally, in seconds
and with no network. Measured on a second Mac, where the listing afterwards
held **both** `mlx-audio` and `mlx-audio.bak`, and the pane correctly reported
the model as present. That reads exactly like the pane lying, and it is not.

Forcing a real download means moving both, which also takes Speak's model away
when Speak is installed, because that is the whole point of a shared cache.

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

### The changelog is the only place release notes are written

`CHANGELOG.md`, newest first, each section starting `##` followed by a version
number. `release.sh` extracts the top section and uses it twice: the GitHub
release body, and the description embedded in the appcast, which is the pane
Sparkle shows before an update. Same argument as `sparkle.conf` holding the
account name and the public key together, and there was a `RELEASE_NOTES.md`
holding a copy until there wasn't.

Preflight refuses a top section that is missing, empty, or not `VERSION`. The
last is the one that matters: a changelog left at the previous version
publishes the previous release's notes under this one's name, and nothing
anywhere reports it, because the release page reads perfectly well. It just
describes a different build.

A section ends at the next heading that is `##` **followed by a version
number**, not at the next `##` of any kind. 0.1.0's notes carry three
sub-headings of their own, so a parser keyed on heading level would have
published the first paragraph and silently dropped the rest.

#### Sparkle needs the notes embedded, not linked

`generate_appcast` embeds a notes file only when it is HTML, and emits a
`<sparkle:releaseNotesLink>` for anything else, including the `.md` the
changelog produces. Measured: without `--embed-release-notes` the feed pointed
at `releases/latest/download/Listen-0.1.0.md`, a file no release uploads, so
every updater would have fetched a 404 into the pane. With the flag it is
`<description sparkle:format="markdown">` inside the feed, and there is no
second file to keep published.

0.1.0's feed shipped with no description at all, so the only thing an updater
was given to decide on was a version number.

### `/release` is the shortcut, and it publishes nothing itself

`.claude/skills/release/SKILL.md`. It commits and pushes what is outstanding,
bumps `VERSION`, writes the changelog entry, confirms once, then calls
`./release.sh --publish` and dispatches the Homebrew cask. Every publishing
decision stays in `release.sh`, which CI calls too, so a local release and a CI
release cannot come apart. A skill that reimplemented any of it would be a
second publisher to keep in agreement with the first.

It must run `release.sh` in the background: the build is about ten minutes and
Apple's notarization queue has taken over an hour, so a foreground call hits
the ten minute tool timeout and reads as a hang.

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

#### A person filter has to match the name nobody stored

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

#### A bare date is a day, and a day has two ends

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

### The server is no longer read-only, and notes are the entire exception

This reverses a property `CLAUDE.md`, `README.md`, `SPEC.md`, the Developers
pane and the landing page all stated four different ways, so the reversal has to
be as narrow as the original claim was broad. `write_note`, `edit_note` and
`delete_note` are the whole of it. An agent still cannot rename a speaker,
correct a sentence or delete a recording, and none of those is a missing feature
waiting for a milestone.

The line is between evidence and opinion. A transcript is a record of what was
said; a note is somebody's reading of it. A wrong note is a wrong opinion sitting
beside the recording that disproves it, and a wrong transcript edit is a fact
that is simply gone, because the audio is an hour long and nobody re-listens.
So anything that changes the evidence goes through a human at the window or the
CLI, where it is visible and reversible, and everything derived from it is open.

The five places that asserted read-only are all updated. If a sixth appears,
that is the list to check.

**`Notes` is one owner with three callers**, which is the rule
`TranscriptEditor` already sets: `listen notes`, the MCP tools and `DetailView`
all go through it. The CLI came first, before any UI, because a store that can
be driven from a terminal is a store whose behaviour is settled before anything
renders it, and there is no test target.

#### The compare-and-swap is required over MCP and optional at the CLI

`Notes.replace` takes `expecting:` and refuses the write when the body no longer
matches, which is `TranscriptEditor.retext` one layer up. `edit_note` makes
`was` a required parameter; `listen notes write --replace` makes `--was` a flag.

That is not an inconsistency. The window and an agent can be holding the same
note at the same time, and that is the surface where an unseen overwrite is
possible. A person at a terminal is one writer looking at what they are
replacing, and demanding they paste the previous body back would make the
command unusable rather than safe. `listen notes read` prints the body on stdout
and the provenance on stderr precisely so `--was-file` has something to be given:

```sh
listen notes read <id> outline > was.md
listen notes write <id> --replace outline --was-file was.md --file new.md
```

#### A note belongs to the library, not to a recording

Notes started in `recordings/<id>/notes/` and moved to
`~/Library/Application Support/Listen/notes/<slug>.md` before anything was
committed. The reason is one use case: "summarise everything with Edgar in June"
spans four recordings, and under one-note-per-recording it had three bad homes
and no good one. Pick one of the four arbitrarily; duplicate it into all four
and keep them in sync by hand; or do not write it. **A note with one source is
the common case, not a special case**, so `recordings` is an array all the way
down and a single-meeting note is an array of one.

That is the arrangement `dictionary.json` and `contacts.json` already have, for
the same stated reason: they are about the library as a whole.

Three consequences, all deliberate:

1. **Slugs are unique library-wide**, so the user's own note is
   `<id>-yours` rather than `yours`: two recordings would otherwise both want
   the same file and the second would silently become `yours-2`, which nothing
   could find again.
2. **Deleting a recording no longer deletes notes about it.** A synthesis of
   four meetings must not vanish because one of them was tidied up. A note
   naming a deleted recording keeps naming it and shows the bare id as
   unresolved, in `Notes.sources`, in `listen notes read`, in the note pane and
   as `unresolved_recordings` over MCP. It is never cleaned up.
3. **There is no wiki-link parsing, no graph view and no automatic linking.**
   The agent states its sources in `recordings` and nothing guesses. A note that
   mentions a name is not a note about that meeting.

`Notes.migrate()` moves the old layout, keeping `created`, `updated`, `source`
and `prompt` so a note somebody edited arrives still looking edited. It runs
once per process, from a `private static let` initialiser, because there is no
single startup path the CLI, the app and the pipeline actor all go through and a
`static let` is initialised lazily and exactly once by the runtime. **35 notes
moved** on the real library.

#### A note file has to survive being written by hand

The frontmatter is emitted with every value double-quoted and escaped, always,
rather than only when it needs it. A title is free text and will eventually hold
a colon, a leading `#`, or the word `yes`, each of which changes what an unquoted
YAML scalar means. Two characters, one class of bug removed.

`Notes.decode` goes the other way and is deliberately liberal, same as
`CustomDictionary.decode`. A markdown file dropped into `notes/` in Finder with
no frontmatter at all is still a note: it takes its title from its first heading
or its filename and its source from nobody. Refusing it would make the whole
argument for markdown-on-disk false, and the promise that deleting one in Finder
is a supported operation only holds if creating one there is too.

The terminator is found by scanning for a line that is exactly `---`, not by
searching for `\n---\n` in the string. A note body containing a horizontal rule
would otherwise end the frontmatter block from inside the document.

### The outline was built, measured and deleted

A recording used to get an extractive `outline` note at the end of
`Pipeline.run`: duration, a talk-time table, the longest stretches with
timestamps, how it opened and closed. It shipped in the working tree, ran over
the whole library, and was removed before any of it was committed. **33 outline
notes were deleted.** Worth recording, because the argument for building one is
good and the argument against only appears once you read a real one.

1. **It is derived from the transcript, so it asks the reader to supply the
   intelligence and gives them more to read in exchange.** Everything in it was
   already on the screen next to it.
2. **The "Who talked" table duplicated the speaker chips**, which are in the
   header of the same pane, four inches away.
3. **"Longest stretches" selects the most rambling turn, not the most
   important one.** Ranking by word count is exactly a ranking of who went on
   longest without being interrupted. On a real recording the top entry was 843
   words beginning "yeah um no so sorry for the delay to getting ready here um".

The talk-time measurement it forced is still worth having: on a real 33:14
two-person call, talk time sums to **47m 40s** because 28 of its 48 turns end
after the next turn starts. The two tracks are captured and transcribed
separately, so a long system-track segment straddles several mic-track ones and
`Merge.turns` takes the `max` of the ends. Anything that reports per-speaker
seconds has to know that, including the chips, which use the same measure.

### The user's own note is the thing no transcript contains

What replaced the outline. One note per recording, `source: you`, slug
`<id>-yours`, and it is the default selection in the Notes tab. A transcript
records what was said; this records what somebody was thinking while it was
said, and "we should upsell them" is exactly the context an agent needs and had
no way to get.

Four properties, each of which is a decision:

1. **It materialises on the first keystroke.** No New Note button, no naming
   step. `Notes.yoursOrEmpty` returns an unsaved note so the pane always has
   something to put a cursor in, and `Notes.setYours` writes the file when there
   is a body and deletes it when there is not. An empty note is not a note, and
   a library with 36 empty files in it is worse than one with none.
2. **Plain markdown in a plain text view.** No rich text, no slash commands, no
   templates, and `isRichText`, the quote substitution and the dash
   substitution are all off: a curly apostrophe AppKit inserted on somebody's
   behalf is a character they did not type sitting in a file they will be quoted
   from. Anyone who wants a document already has a notes app.
3. **It is editable while the recording is still running**, and Notes is the
   default tab in that state because Transcript is an empty pane for the next
   hour. `Recording.promote()` moves `staging/<id>` to `recordings/<id>` with the
   id unchanged, so a library-level note keyed on that id needs no special
   handling at adoption. `Notes.setYours` deliberately skips the `checked`
   validation that every other write goes through, because `Recording.all()`
   cannot see a staged recording, and `Notes.sources` looks in `staged()` too or
   a live recording's own note would report its own meeting as missing.
4. **An agent may read it and may not write it.** `MCP.writable` refuses
   `edit_note` and `delete_note` on a `source: you` note, and says to write a
   separate note instead. This is the one asymmetry in the note surface, and it
   is the same line the transcript is on: that text was not derived from
   anything, so there is no way to get it back.

**Do not call it "private".** That names a sharing model this app does not have
and would be a lie the day anything syncs. `source: you` and "Your notes" are
claims about who wrote it, which stay true.

Deleting has to say so. `LibraryWindow.deleteSelected` names it in the alert,
and answering "No" to the meeting prompt, which is otherwise the one place a
recording is deleted without being asked about, now asks exactly when there is a
non-empty note: somebody who has typed into it has said this is a meeting more
clearly than the panel ever asked.

### `NSAttributedString(markdown:)` parses the structure and then throws it away### `NSAttributedString(markdown:)` parses the structure and then throws it away

Handed a whole document it returns the text with inline emphasis applied and
nothing else: headings come back as plain paragraphs at body size, list items
lose their bullets, and a table's cells run together. A note whose headings and
bullets are gone is *less* readable than the raw file, and the raw file is what
is on disk, so rendering has to beat showing the source or it is not worth
doing.

`MarkdownText` therefore splits the job. Blocks are handled here, line by line,
and every line's inline markup goes through Foundation with
`.inlineOnlyPreservingWhitespace`, which is exactly what that option is for.
Bold, italic, code and links come back correct with no second parser to be wrong
in its own way, as an `.inlinePresentationIntent` attribute rather than as fonts,
so the caller's font is applied first and the traits are added on top. That is
what makes a bold word inside a heading a bold heading.

Three things it got wrong first, all visible only against a real note:

1. **A paragraph runs to the next blank line**, not to the end of the source
   line. Everything that writes these notes hard-wraps its prose, and one
   sentence rendered as two half-sentences with a gap down the middle.
2. **A list needs a hanging indent.** Without `headIndent` the second line of an
   item starts under the marker and a list of two-line items stops looking like
   a list.
3. **A numbered item keeps the number it was written with.** Counting them here
   would mean the file and the pane disagree about which one is item 3, and the
   file is editable in any editor.

Tables are padded monospaced text rather than tab stops, because the column
widths are known here and the pane's width is not: a tab stop set from a guess
comes apart when somebody drags the divider.

### Collection navigation is in the sidebar, not the toolbar

A three-way segmented control above the search field: Recordings, People, Notes.
People used to be a toolbar button and is not one any more.

**The rule it encodes: a toolbar holds verbs on the selected recording.** Export
this, transcribe this again, delete this. People was never a verb on a
recording, it is a peer collection of the whole library, and once a note can
name four recordings so are notes. A note referencing four meetings has no home
in a recording-centric sidebar at all, which is the sharp version: without this
the app can create something it cannot show.

Five things it has to get right:

1. **Above the search field, not below.** Search scopes to the active segment,
   so the scope selector comes first, and the placeholder changes with it
   ("Search recordings", "Search people", "Search notes"). Otherwise the first
   search in People returns people as a surprise rather than an expectation.
2. **Settings is not a fourth segment.** The segments are which part of the
   library you are looking at; settings is configuring the app. It keeps the
   gear at the bottom left.
3. **Each list carries its own copy of the control**, because the sidebar swaps
   its whole view controller through `PaneHost`. Same builder, same constraints,
   same position, so it does not appear to move. The cost is that they go out of
   sync: clicking Notes on the recordings list leaves *that* control reading
   Notes, so coming back showed the recording list with the Notes segment lit.
   Measured that way round. `enter()` sets all three, not just the one on
   screen.
4. **Do not touch `minimumThickness`, `maximumThickness` or the holding
   priorities on a segment change.** One `autosaveName` owns the divider, and
   moving the limits makes the split view redistribute and rewrite the saved
   width. `CLAUDE.md` already records this for the settings mode; a segmented
   control changes mode far more often than Settings does.
5. **Every list needs the Settings row, not just the recordings one.** It was
   the only list with a bottom row, because People was entered from the toolbar
   and left by a back row. Peers behind one control, a gear in one of them means
   being in People or Notes is being somewhere with no visible way to Settings.
   Found by looking for it and it not being there. `sidebarSettingsRow` builds
   the row, the hairline above it and its constraints once for all three.
6. **People and Notes no longer lock the sidebar open.** That lock existed
   because the roster was the only way out of the person page. The segmented
   control is now the way in and out of everything, so the lock was about
   navigation rather than about People, and the sidebar toggle is back in the
   toolbar in those modes. The masthead is in all three too: switching is one
   click now, and a title bar that empties as you move between segments reads as
   three different apps.

A note's sources are `SourceChip`s, and they took three goes. An `.inline`
button draws a flat grey capsule that reads as a tag, so nothing said the
meeting a note is about was also the way to it: zero signals. An accent-filled
capsule with a chevron said it far too loudly, and on a note whose body is one
sentence the loudest thing on the page was the navigation. What is there now is
a link: accent text, a chevron, a pointing hand, no fill.

The label in front of them went with the capsule. "Open a recording:" spent a
third of the row on a sentence introducing four things that already look like
links.

The header lost a line too. It carried who wrote it, when, and, on the user's
own note, a sentence saying it is edited on the recording, every time it was
shown for ever. That sentence is a thing somebody needs once, so it is the text
view's tooltip, and what is left is the same two facts the sidebar row already
prints in the same order.

A note's sources are links in a sentence, not a row of buttons. Buttons with a
trailing chevron each read as one step of a path, so four of them are a
breadcrumb trail claiming a hierarchy that does not exist: these are four peers.
`LinkLine` is an `NSTextView` that reports an intrinsic height, so a
comma-separated line of links wraps, underlines on hover and takes the pointing
hand for free. The `listen-recording:` scheme is made up and read back by the
delegate that owns the view, so an id in a note's provenance can never reach
`NSWorkspace`.

**An `NSTextView` reports no intrinsic size**, which is fine inside a scroll
view and wrong everywhere else: pinned into a stack of constraints with nothing
saying how tall it is, it took the whole pane and pushed the note body off the
bottom of the window. The symptom is a note that renders its header and nothing
else, which reads as an empty note.

The same line appears under a note shown beside a recording, as "Also about",
and it is links there too. `LibraryWindow.open(recording:note:)` is the one
entry point both use, and **they land on different tabs**.

From the Notes collection it lands on the Notes tab with that note beside the
recording: the whole page has changed, and a synthesis of four meetings has to
be walkable through its sources without losing your place in it.

From "Also about" it lands on the **transcript**. The note being read is about
that meeting too, so staying on the Notes tab put the same words under a
different title, and a page that does not visibly change is a click that did not
appear to work. The rule generalises: land where the change is visible.

**A leading heading that repeats the note's title is dropped when rendering.**
An agent asked for "Decisions" writes `# Decisions` as the first line, which is
right in a markdown file somebody may open in an editor and reads as a mistake
on a pane whose own title is two lines above it. The file keeps it.

**Every one of the user's notes is titled "Your notes"**, so the library list
was a column of identical rows told apart by a truncated second line. Those rows
lead with the meeting and put "Your notes" where the kind goes; an agent's note
is the other way round, because its title is the one thing that is its own.

Clicking one lands on the **Notes tab** of that recording, with the same note
selected. Landing on its transcript would be answering a
question nobody asked, and a synthesis of four meetings has to be walkable
through its sources without losing your place in it.

`NotePane` is read-only for every note, including the user's own, and that is a
choice rather than an omission. Their note is edited on the recording it belongs
to, where the audio and the transcript are, and two editors for one file would
be two writers of the thing this app is most careful about. The sources are
buttons, so the way to edit it is one click and the click also goes to the
meeting.

#### Reading the popup's selection after rebuilding its menu returns the old one

`pickNote` called `saveYours()` before reading `sender.selectedItem`, and
`saveYours` calls `rebuildNotePicker`, which re-selects the note that is on
screen. So picking a different note in the switcher read back the note you were
leaving, and the pane redrew what it was already showing. The symptom is a
control that appears to be dead, which is the hardest kind to attribute.

The choice is read first, before anything that could touch the menu. The wider
rule: an action handler that rebuilds its own control has to take what it needs
off the sender on the first line.

#### A day heading that pins to the top is not a row that has vanished

Reported as "the first recording of the day disappeared": the sidebar showed
"Today" with nothing beneath it and "Yesterday" immediately after. It was not a
bug. `NSTableView` floats group rows, so the heading of the group you are in
stays pinned while its rows scroll away underneath, and landing at the one
offset where Today's only recording had just gone past the top leaves exactly
that picture.

Three wrong theories went by before the measurement that settled it: the table
reported 58 rows before and after, and asking through accessibility returned the
right title for the row that was not on screen. Data right, drawing right,
heading in front of it.

**The fix is not `floatsGroupRows = false`.** That was tried, and it removes the
sticky heading and its separator, which are the thing that tells you which day
you are looking at halfway down a long library. Turning off a feature to
suppress a symptom is how a report of "this looks wrong" becomes a regression
nobody asked for. What put the list at that offset is `select`'s own
`scrollRowToVisible`, which is correct: arriving from a note has to bring the
recording into view.

#### A recording with no call shows Listen's own icon

`appBundleID` is nil for a recording started from the sidebar in a quiet room,
so its icon column was empty while every other row had one. `AppNames.own` fills
it, which is the true answer rather than a blank: that meeting was recorded by
this app and by nothing else. It also keeps one left edge down the list instead
of one that changes as you scroll.

#### The document toggle sits above the player, not below it

The player belongs to the transcript. A transcript is a thing you read while
listening; a note is a thing you write. Under the player the toggle read as a
control on the recording rather than a choice of document, and switching to
Notes left 58 points of transport on screen with nothing to transport.

So `modeBar` is between the chips and `playerCard`, and the player is collapsed
in notes mode through the same two-constraint pattern the chips row uses. It is
also collapsed when there is no audio, which closes a gap that had been there
since before any of this and that nobody had noticed.

Switching to Notes stops playback, which is the rule `enter(.settings)` already
follows: a transport nobody can see is a transport nobody can pause. The cost is
that you cannot listen back while typing, which is a real thing somebody might
want and is worth revisiting if it comes up.

#### A convenience initialiser that shadows its superclass's calls itself

`SourceChip` is an `NSButton` subclass, and its first version was:

```swift
convenience init(title: String, target: AnyObject, action: Selector) {
    self.init(title: title, target: target, action: action)   // itself
```

`NSButton` already has `init(title:target:action:)`, so `self.init` resolves to
the subclass's own initialiser and not the superclass's. It compiles clean, and
crashes the first time a note is selected: `EXC_BAD_ACCESS`, "thread stack size
exceeded due to excessive recursion", **74,609 frames** of
`SourceChip.__allocating_init(title:target:action:)`.

Any argument label that is not `title` sends it to `NSButton`, so the parameter
is `recording:`. The general rule: a `convenience init` on a subclass must not
have the same signature as an initialiser it means to call.

Two things made this cost more than it should have. It only fires on a code path
a click reaches, so a build and a launch both look fine, and every screenshot
taken before that click is evidence of nothing. And the fix is one word, which
is the shape of bug worth writing down rather than remembering.

### The user's name is a preference, and nothing said where to set it

`Settings.userName` has existed since the label design was settled: the
transcripts keep saying `Me` and `SpeakerName.display` resolves it on the way to
the screen, so the name can change without rewriting anything. The person page's
editor already wrote it, and so did `listen me`.

What did not exist was any way to find that out. The Me page's heading said
"Me", the roster said "Me", and nothing anywhere admitted that was a placeholder
or that it could be changed, so the reasonable conclusion from looking at it is
that the app does not know who you are. Settings, General now has the field, and
the Me page carries one dimmed line saying where it is, **only while the name is
unset**.

It was first put inside the `·` list in the person's subtitle, which read badly:
a sentence with a full stop in it, wedged between a job description and a
duration. A hint that is not one of the facts does not belong in the list of
facts.

### The notes pane re-reads on activation, and only redraws when something changed

An agent writes a note while the window is open and nothing on disk announces
it. Coming back to the app is when somebody expects to see it, so `DetailView`
listens for `didBecomeActiveNotification` and re-lists one directory, which is
cheap.

Redrawing is not cheap, though, because rebuilding the text view scrolls it back
to the top. `notesSignature` is every note's slug and `updated` joined up, and an
unchanged signature returns without touching the view. Losing your place in a
note because you switched to another app and back is the same failure
`renderTurns(scrollToTop:)` exists to avoid next door.

The mode itself survives a selection change, the way `DictionaryPane.showing`
does: reading notes down a list of meetings is a mode, not a choice being
repeated. `reloadNotes` puts it back to the transcript when a recording with no
notes arrives, so the mode can never leave anybody on an empty pane.

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

### Settings is a mode of the library window, not a second window

Anarlog's shape, and the reason is the one the two-window version kept paying:
a settings window is a second toolbar idiom, a second thing to manage, and a
fixed 560 x 500 box that cannot use the space it has. `LibraryWindow` now has a
`Mode`, and both split view items hold a `PaneHost` whose child is swapped:
recording list or section list on the left, transcript or pane on the right.

**A `PaneHost` rather than swapping the split view item's view controller**,
because `NSSplitViewItem.viewController` cannot be changed afterwards and
removing and re-inserting items throws away the divider position that
`splitView.autosaveName` exists to keep. The host's view must draw nothing:
`NSSplitViewItem(sidebarWithViewController:)` puts its material behind whatever
it is given, and a host with a background covers it.

**Do not touch `minimumThickness`, `maximumThickness` or the holding priorities
on a mode change.** One `autosaveName` owns the divider, and moving the limits
makes the split view redistribute and rewrite the saved width, which is the
trap directly above wearing a different hat. Measured across a settings visit:
`defaults read com.mgo.listen "NSSplitView Subview Frames ListenSplit"` returns
the same 280 before and after.

**There are three ways to collapse a sidebar, so blocking one is blocking
none.** The toolbar item is not in the toolbar in settings mode;
`LibrarySplitViewController` overrides `toggleSidebar` and validates View >
Hide Sidebar to disabled, which is where the menu item lands because it targets
nil; and `canCollapse = false` closes the divider drag and the double-click.
`validateMenuItem` is a *conformance* here and not an override: the compiler
says plainly that `NSSplitViewController` does not implement it, so there is no
super to call.

A sidebar collapsed before settings opened is expanded on the way in and
collapsed again on the way out, with `isCollapsed` set directly rather than
through `animator()`: the content is being swapped underneath, and a sidebar
sliding open around a list that has already changed reads as a glitch.

Four more things, each of which was got wrong once:

1. **`show()` always enters library mode.** It is what the Dock icon, Cmd-0 and
   "Open Listen" mean. `showSettings(_ tab: SettingsTab? = nil)` takes nil so
   Cmd-, pressed while already in settings keeps the section you were on.
2. **No window subtitle for the section name.** It draws immediately above the
   pane's own 22 point heading, so the window read "Audio" twice, one line
   apart, which looks like a bug rather than a title.
3. **`selected` returns nil in settings mode**, so the Actions menu says "No
   recording selected" instead of acting on a row nobody can see. That needed
   `NSMenuItemValidation` on `LibraryWindow`, which nothing had: the File menu's
   recording items were permanently enabled and quietly did nothing.
4. **The record control stays in both modes.** Stopping a meeting must never
   mean leaving the screen you are on first, and the button is the only place
   the elapsed clock is written.

`trace()` reports every mode change under `LISTEN_DEBUG=1`, because a mode leaves
nothing behind to inspect. It earned itself immediately: "the window went back
to the library on its own" turned out to be a test script moving the window
under a stationary pointer, which pressed the back button. The stack trace said
`NSControlTrackMouse`, and nothing else would have.

### A settings pane is as wide as the window, up to 620 points

`Pane` was built for a non-resizable 560 point window, so `note`, `separator`,
the skip rows and the MCP box all sized themselves from a `paneWidth` constant.
In a window that resizes, every one of those is a view that stretches to
whatever the display is, and a note running 1400 points across is a line nobody
can track back to its start.

`widthCapped` replaces the constant: a low-priority equality to the stack's
width with a required maximum, which resolves to the smaller of the two. The
stack is leading-aligned and does not stretch what it arranges, so anything
meant to span the pane has to ask.

Two traps around it:

1. **`preferredMaxLayoutWidth` has to be updated before the height is
   measured.** An `NSTextField` computes its height from that and not from the
   width it was given, so a note left at the old width reports the old height
   and loses its last line as the window narrows.
2. **It has to be guarded on change.** Setting it dirties layout, and setting it
   unconditionally from `viewDidLayout` is a layout pass that schedules another
   one forever.

`skipRow` is added to the list *before* `widthCapped` is applied to it, because
the constraint is against the pane's stack and two views with no common ancestor
yet is an exception rather than a layout that sorts itself out.

### The About pane is Speak's, and the app name is one size down

`AboutPane` follows Speak's section for section: identity header, Updates, Setup,
Made by, Built on, then the licence and the source link. The Updates block is the
part that was missing rather than merely differently worded, and the argument for
it is Speak's own: Sparkle answers a check in a window that is then dismissed,
taking the answer with it, and a scheduled check that finds nothing says nothing
at all, so "am I on the latest version" had no answer that survived closing a
dialog. Before this, About offered one `Check for Updates` button and reported
none of what came back.

Three things are Listen's own:

1. **The name is 17pt, not Speak's 22.** The pane draws its own section title at
   22 immediately above, and the previous version of this file records why there
   is no `Listen` heading here: two 22pt words one line apart read as a mistake
   rather than as a title. The 72 point app icon beside it is what makes this an
   identity block instead of a repeated heading, so the header came back and the
   size did not.
2. **`refreshUpdates` does not call `resizeDocument`.** The result line appearing
   does change the pane's height, but `sizeDocument` already runs on every layout
   pass and a text field whose string changed schedules one. The public one also
   scrolls the pane back to its first control, and a scheduled check finishing
   while somebody is reading the credits is not a reason to move the page.
3. **`Updater.onChange` is claimed in `viewWillAppear` and released in
   `viewWillDisappear`.** A check can be started from the menu bar or by the
   scheduler, so following the button alone would leave the pane showing the
   previous answer.

Verified end to end against the real feed by pressing Check Now through
accessibility on a `LISTEN_PANEL=settings:about` launch, which touches nothing in
the library: Sparkle's "You're up to date" window, then the green result line and
`Last checked Today at 15:30` in the pane behind it.

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
