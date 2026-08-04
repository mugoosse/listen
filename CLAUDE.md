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

### Sparkle has no keypair yet

`make_app.sh` omits `SUFeedURL` and `SUPublicEDKey` entirely unless
`SPARKLE_PUBLIC_KEY` is set. Sparkle then refuses to update rather than
accepting anything, which is the safe failure. The keypair is generated with
the rest of the release pipeline at milestone 9. Shipping a placeholder key
would be the dangerous option.

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
