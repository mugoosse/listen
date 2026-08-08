# Capture: the tap, the two tracks and meeting detection

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments explain why, thresholds say where the number came from, and no em dashes. -->

How audio gets onto disk. Read this before touching `Capture`, `SystemAudioRecorder`, `MicrophoneRecorder`, `WAVWriter` or `MeetingDetector`.

## A process tap with an empty include list records perfect silence

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

## AVAudioEngine cannot be pointed at a tap-backed aggregate device

Setting `kAudioOutputUnitProperty_CurrentDevice` to the aggregate either fails
or yields silence, so `SystemAudioRecorder` drives
`AudioDeviceCreateIOProcIDWithBlock` on the aggregate directly. The microphone
path does not use `AVAudioEngine` either, for the separate reason below, so
both classes now drive Core Audio directly and the split between them is about
what they record rather than about which API they use.

## AVAudioEngine picks the microphone before you can, and the first recording pays

`MicRecorder` builds a `kAudioUnitSubType_HALOutput` unit rather than an
`AVAudioEngine` because the engine chooses its input device the instant
`inputNode` is read, and nothing can get in front of that. Measured in Speak,
which ran the identical code, with music on a Bluetooth headset and the
built-in microphone chosen in Settings:

- reading `engine.inputNode` bound the unit to `CADefaultDeviceAggregate`,
  which wraps the system default devices rather than being a device, and
  dropped the headset from 44100 Hz to 16000 Hz. That is the hands-free
  profile: the music went mono and the headset announced a call, before either
  app had said which microphone it wanted;
- the `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` that
  followed returned `noErr` **and did not take effect**. The unit stayed on the
  aggregate and the tap delivered **0 buffers in 1.5 seconds**;
- the second recording bound correctly, which is why this survived: anybody
  testing by recording twice sees it work.

For Listen the middle point is the expensive one. A meeting whose first minute
went to a device nobody chose is not recoverable, and the watchdog does not
help, because a track that never starts is not a track that stalled.

A HAL unit takes its device before `AudioUnitInitialize`, so no default device
is ever opened. Verified here across two consecutive `listen record` runs: the
trace said `recording from MacBook Pro Microphone`, the headset held 44100 Hz
throughout and its input never ran, and the mic track measured 6.22 s with a
peak of -34.2 dBFS and 96.5% of samples above the noise floor, so it is real
audio rather than a well-formed silent file.

Three things hold this together and none is optional:

- **Disable the output bus.** A HAL unit with output enabled opens the default
  *output* device too, which on a Bluetooth headset is the other half of the
  same profile switch.
- **Dispose the unit in `teardownEngine`, do not keep it.** A merely stopped
  unit still holds its device, so a headset would sit in hands-free mode from
  the first meeting until Listen quit, and `restart` could not re-resolve onto
  a different microphone.
- **Selecting the device is fatal now.** It used to fall back to the default on
  failure, which was the right call when the fallback was a working engine. It
  is not the right call when the fallback is a unit with no device, and
  `watchHardware` no longer reads the device back for the same reason: a
  running unit is a unit on the device that was asked for.

## `AVAudioPCMBuffer` rebuilds its buffer list, so do not size it by hand

`AudioUnitRender` wants a buffer list whose `mDataByteSize` says how much room
there is, and the obvious way to say so does not work:

    let list = UnsafeMutableAudioBufferListPointer(scratch.mutableAudioBufferList)
    for i in 0..<list.count { list[i].mDataByteSize = frames * 4 }
    AudioUnitRender(unit, flags, ts, bus, frames, scratch.mutableAudioBufferList)

`AVAudioPCMBuffer` derives `mDataByteSize` from `frameLength` and recomputes it
on *every* access, so the second `mutableAudioBufferList` hands render a list
claiming zero bytes and it answers `paramErr` (-50) on every slice for ever.
Set `frameLength` first and touch nothing else:

    scratch.frameLength = frames
    AudioUnitRender(unit, flags, ts, bus, frames, scratch.mutableAudioBufferList)

Worth knowing what this looks like from outside, because it looks like anything
but a buffer bug. The device really is running, so macOS shows the microphone
indicator in the menu bar and the meeting appears to be recording, while the
track stays empty. `LISTEN_DEBUG=1` is the fastest way to tell the two apart:
`mic has signal` is the line that means a sample above 0.0001 actually arrived,
and its absence is the whole diagnosis.

## Changing the microphone mid-meeting silently ended the mic track

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

### The two tracks did not share a zero

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

## The aggregate device is not ready when it is created

Reading `kAudioDevicePropertyStreamFormat` immediately after creating the
aggregate returns a zero sample rate. An `AVAudioConverter` built from that
produces no output at all, so the failure surfaces an hour later as an empty
file rather than at setup as an error. `deviceFormat` polls for up to two
seconds. Measured here: it takes one poll, so anything that "simplifies" the
loop away will appear to work on this machine and fail on a busier one.

## Reading a duration after stopping gives zero

Both recorders close and release their `WAVWriter` in `stop()`, and the
duration is the writer's. `Capture.stop()` therefore samples the durations
before stopping, otherwise every meeting is recorded as zero seconds long.

## `withUnsafePointer(to:) { $0 }` returns a dangling pointer

Building an `AVAudioFormat` from an `AudioStreamBasicDescription` with
`AVAudioFormat(streamDescription: withUnsafePointer(to: asbd) { $0 })` crashes
with SIGTRAP. The pointer is only valid inside the closure. The working form
passes an `inout` and does the work inside:
`withUnsafePointer(to: &asbd, { AVAudioFormat(streamDescription: $0) })`.

## `RunLoop.current.run()` returns immediately

It returns as soon as the run loop has no input sources attached, so `listen
record` fell straight through to `exit`. The symptom was a recording that
stopped after 80 milliseconds with a system track containing nothing but a WAV
header, which is indistinguishable from a tap that does not work. The CLI runs
`run(until:)` in a loop instead.

## WAV headers are rewritten as the recording runs

`WAVWriter` exists instead of `AVAudioFile` because `AVAudioFile` finalises the
header on close. A crash or a power cut during an hour-long meeting would leave
a file whose RIFF and data chunks claim a length of zero: every sample on disk,
and nothing able to play them. `WAVWriter` patches the two length fields every
two seconds and `fsync`s, so the worst case is losing the last couple of
seconds rather than the meeting.

Format tag 3, not 1. These are floats, and a reader told they are integers
decodes noise at full scale.

## Meeting detection asks while recording, not before

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

### The app the call was in is a field, and never the title

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

## Nothing asks "keep this recording?" any more

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
