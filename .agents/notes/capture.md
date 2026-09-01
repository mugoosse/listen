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

### Dictating made Listen a call, and the guard was on the pid rather than on the app

A push-to-talk dictation with no meeting anywhere put "Are you in a meeting?
Recording · Listen" on screen, twice on 11 August 2026, and left two 6.4 second
recordings in the library stamped `app_bundle_id: com.mgo.listen` and
`source: detected`.

Two things had to be true at once, and each was written down here as safe.

**Dictation makes Listen match Blackbox's rule exactly.** The microphone is an
input stream and `Cue.start` plays a system sound as the microphone goes live,
so for as long as that sound lasts the app is running an input and an output
stream at the same time. This is the case the self-PID guard's own comment
predicted: the day capture plays anything at all, Listen starts matching its
own rule.

**The guard asked the wrong question.** `process.pid != me` is "is this me?"
when the question is "is this Listen?". A second copy of the app is a second
pid with the same bundle identifier, so it walked straight through. Detection
is per process; the thing being detected is an app.

Measured by firing the chord at two copies running side by side and sampling
the HAL four times a second from a third process:

| | |
|---|---|
| the dictating copy | `in y, out y, pid 88102, com.mgo.listen` |
| the rule as it was, on the pid | `com.mgo.listen` |
| the rule now, pid then app | `[]` |
| how long the two streams overlap | about 1.8 s, which is the length of the cue |
| how often detection polls | every 3 s |

The last two rows are why this was occasional rather than constant, which is
the part that made it hard to believe: a two second window against a three
second poll misses more often than it lands, so most dictations produced
nothing and the ones that did looked like the app inventing a meeting.

With the identifier compared, the same run leaves no recording and no staging
folder in either copy's library, and neither trace says `meeting detected`.

Both guards stay in `activeCallers`, because they fail apart: the identifier is
what covers a sibling process, and the pid is what still holds when `AppInfo`
cannot resolve an identifier to compare against, which is every unbundled
build.

`listen sources` prints the decision now, as `on a call by the rule, ignored
because it is Listen: com.mgo.listen (pid 88102)`. Without it a copy of Listen
sitting in that table with `* y y` and no prompt on screen reads as detection
being broken, which is the question the command exists to answer.

A copy signed with a different identifier, which is what the ui-test recipe in
`CLAUDE.md` builds, is a different app by this rule and would still be asked
about. That is the right answer for something calling itself
`com.mgo.listen-uitest`, and worth knowing before wondering why a test copy
asks.

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
   while capturing reports `in y / out -` (measured, pid 8859), so capturing
   alone does not match the rule. Dictating does, because of the cue, and the
   day it did is written up above: the guard on the pid was never enough by
   itself, and the one that carries the weight is on the bundle identifier.
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

## A closed lid switches the built-in microphone off and reports it healthy

The failure that cost an hour of a real WhatsApp call. The laptop was carried
to a desk, plugged into a monitor and an external microphone, and the lid was
shut. Listen was following the **system default input**, which macOS leaves
pointing at the built-in microphone, so it recorded 58 minutes of that.

Measured on the recording itself: `mic.wav` held 56,239,952 samples and not one
of them was nonzero, while `system.wav` was healthy throughout (99% nonzero,
-5.0 dBFS peak). The far side transcribed perfectly and was filed as a
one-speaker meeting at 99%.

**Nothing in Core Audio reports this.** With the lid shut the device stays in
`AudioDevices.inputs()`, stays the system default, and answers
`kAudioDevicePropertyDeviceIsAlive = 1`, `kAudioDevicePropertyMute = 0`,
volume `0.27`, 48 kHz mono, exactly as it does when it works. So:

- none of `MicRecorder.watchHardware`'s four listeners fire, because nothing
  they watch changes;
- `checkForStall` sees the file growing perfectly, because buffers arrive at the
  full rate. They are simply full of zeros.

The lid is the only thing that tells you, and it is not a Core Audio property.
`AudioDevices.lidClosed` reads `AppleClamshellState` off `IOPMrootDomain` in the
IO registry. It is absent on a desktop, which reads as false and is right.

Confirmed it is the lid and not a broken microphone by testing four ways in two
processes: the AT2020 over USB gave -44.7 dBFS through Listen's own HAL path and
-50.1 dBFS through `ffmpeg -f avfoundation`, while the built-in gave bit-exact
silence through both. TCC was never involved, which the USB result proves: a
denied app gets silence from every device, not one.

Two defences, and they are answering different questions.

**Proactive.** `Settings.chooseMicrophone` declines the built-in microphone
while `lidClosed`, which is the only fix that costs nothing: the recording never
starts on a device that cannot record. This is the one place a device chosen in
Settings is overridden, and that is not a contradiction of "somebody who picked
a microphone meant it". That rule is about not moving somebody off a *working*
device. A device that cannot record is a fault, not a preference.

**Reactive.** `MicRecorder.checkForSilence` watches for a running device
delivering nothing and moves to the next candidate. Three things about it are
measured rather than chosen:

1. **The test is a floor, not a level.** Bit-exact zero was the first version
   and it is certain but not sufficient: a USB webcam microphone picking up
   nothing delivers dither around -85 dBFS, and `!= 0` called that "picking up
   again" and stopped looking. `signalFloor` is 0.0001, about 35 dB below a real
   microphone in a silent office, so no analogue front end sits under it and
   nobody can go quiet enough to fall under it either.
2. **A device is only ever abandoned before it has been heard from.**
   `heardSinceOpen` gates the switch. Once a microphone has produced audible
   audio a later silence is somebody listening, and moving them off a working
   mic mid-sentence would be a worse bug than the one being fixed. It also
   disposes of macOS Voice Isolation, which gates hard enough that a pause can
   look like a dead input until the first word.
3. **Silence is cleared by hearing something, never by the counter resetting.**
   `buildEngine` zeroes `silentFrames`, so the obvious test reports every device
   switch as a recovery: the tick after a switch sees a fresh counter and
   announces a working microphone over a file of bit-exact zeros. That shipped
   for ten minutes and the log said "picking up again" while `mic.wav` held not
   one nonzero sample.

The candidate filter is the dangerous half, because the input list on a working
Mac is full of things that are not microphones. On the machine this was written
for, "Microsoft Teams Audio" is a virtual loopback input: present, alive, and
every bit as silent as a closed lid. Switching onto it would have replaced one
hour of nothing with another and reported success. `AudioDevices.rank` therefore
allows only physical transports, and excludes Continuity Capture as well, which
works but means reaching across to somebody's phone unasked.

`exhausted` grows and never shrinks within a recording, which is what bounds
this: every failure removes one device from `candidates`, so a Mac where nothing
works tries each input once and then stops rather than cycling for an hour.
`Capture.stop` writes `mic_silent: true` when the track ended up holding
nothing, because after the audio is on disk a silent track and a meeting where
the user never spoke are byte-identical.

## The recording panel could not show any of this, because nothing on it moved

The clock was the only moving thing on screen for the whole hour. A clock
counting up looks exactly the same whether or not anybody's voice is arriving,
which is the lesson Speak already had written down and Listen's own iOS
`LevelMeter` states outright: "a muted microphone, a case over it and a headset
that walked out of range all produce a file of exactly the right length
containing silence, and all three look identical to a clock that is counting
up." A shut lid is the fourth item on that list.

`Meters.swift` is Speak's `Meters.swift`, ported with its constants intact: dB
mapping rather than linear (-55 to -14 dBFS onto 0...1), 32 ms windows rather
than per buffer, `Envelope`'s fast attack and slow release, and the level
callback reaching the main actor through `DispatchQueue.main.async` and never
`Task {}`, because a strip is a queue and a reordered sample is a bar in the
wrong place. It is a port rather than a rewrite on purpose: the two apps are
expected to merge, and two meters that disagree about what a level means would
make that a reconciliation instead of a move.

Two things Listen needs that Speak did not:

- **Two lanes, labelled.** The label is the diagnosis. One strip moving while
  the other is flat says which half of the recording is broken with nothing to
  remember; the same two strips unlabelled say only that something is wrong.
  Upper is the far side and lower is you, matching `TranscribingView`, so the
  picture does not change meaning when capture ends and reading begins.
- **An hour, not six seconds.** `RecordingView.end` and `setChromeHidden` both
  drop the level subscription and stop the strips, because a 60 Hz redraw of a
  view nobody can see is an hour of wakeups. `Capture.addLevelSink` is keyed by
  owner for the same reason: the screen and the panel both draw these tracks and
  neither is guaranteed to be visible.

There is no silence detector on the system track and that asymmetry is
deliberate. Bit-exact zero from a process tap is the ordinary state of a Mac
with nothing playing, so the test that is certain for a microphone means nothing
there. A quiet far side is a quiet far side.

`LISTEN_PANEL=live` and `LISTEN_PANEL=live:silent` put the screen up driven by a
synthetic speech envelope, in the same family as `transcribing:0.6`. The silent
one is the state this was all built for and the one no machine reproduces on
demand unless somebody shuts a laptop lid on it. The envelope is syllables
inside words inside phrases rather than a sine wave, because a sine exercises
neither the attack nor the release, which is the whole reason `Envelope` exists.

### Checking any of this without holding a meeting

Four affordances, all in the `LISTEN_PANEL` / `LISTEN_SHOT` family, because
every state worth checking here lasts under a minute and needs a real call
first:

```sh
LISTEN_PANEL=live:silent  LISTEN_SHOT=/tmp/s ./.xcbuild/.../listen   # the screen
LISTEN_PANEL=recording:3725:silent LISTEN_SHOT=/tmp/p ...            # the panel, widest and tallest
LISTEN_PANEL=detected:silent LISTEN_SHOT=/tmp/d ...                  # the panel's tallest state
listen record --seconds 10                                           # the real path, no window
```

`NSView.writeShot` draws into a bitmap rather than photographing the screen, so
all of this works with the lid shut, which is the condition the bug happens
under and the one `screencapture` cannot see.

One thing it cannot photograph: Liquid Glass paints an opaque white block when
it is drawn offscreen and nothing inside it draws, so the library window's
sidebar and the Ask composer are blank rectangles in every shot. The panel and
the pill above are unaffected, being neither. `.agents/notes/appkit.md` has the
measurement and why there is no flag for it.

`recording:3725:silent` sets the clock **and** the silence, and that is not
convenience. The clock decides the panel's width and the warning line decides
its height, so a preview that shows one at a time leaves the combination nobody
has looked at. `TrackMeter.labelWidth` was found this way: measured from the
bare string it clipped the "m" off "Them", because `NSTextField.sizeToFit`
reports wider than the string it holds.

`listen record` prints `levels: you 0.770, them 0.000 (peak, 0...1)` beside the
file sizes, and that line exists because **"the audio arrived" and "the meter
moved" are separate claims**. They leave the same callback by different routes,
and a broken sink draws a flat strip over a perfectly good recording, which on
screen is indistinguishable from the dead microphone the strips exist to report.
A peak of 0 on a track whose file has audio in it means the meter is broken, not
the microphone.


## A dictation listens in on the meeting's microphone, and never opens a second unit

`MicRecorder.onSamples` hands every converted buffer to a second consumer, wired
and unwired by `Capture.beginDictationTap` / `endDictationTap`. It is nil except
while somebody dictates during a recording.

The alternative was a second capture unit on the same device, and it is not
available. The device is already held: a second claim on it is either refused
outright or renegotiates the Bluetooth profile the meeting is recording through,
which would break the recording to serve the dictation. So the meeting's capture
stays the only reader of the hardware and the dictation is a second consumer of
what it already has.

Two consequences, both deliberate. The sink is called *after* the writer, so a
dictation listening in cannot cost the meeting a sample. And what you dictate is
also in the meeting's microphone track, which the Dictation pane says out loud
rather than leaving to be discovered: it is your voice in the room, and a
recorder that quietly excised part of it would be lying about the hour.

`DictationRecorder` is the other path, for dictating with no meeting running. It
is a separate file carrying the same HAL ordering fix rather than a mode of this
one, because an hour of meeting and four seconds of dictation want opposite
things: streaming to a `WAVWriter` against holding samples in memory, and a
watchdog that switches devices against disposing the unit the moment the key
comes up. See `.agents/notes/dictation.md`.


## A dead tap and a quiet far side are the same silence, and only one is a failure

Three meetings on 2026-09-01 recorded almost none of the other person, and
nothing anywhere said so. Measured on the files afterwards:

| recording | far end has any signal | bit-exact zero |
|---|---|---|
| `2026-09-01-130009-8257` (38:32) | 12.6% of the call | 21 whole minutes |
| `2026-09-01-150027-035D` (8:46) | 28% | one run of 251 s |
| `2026-09-01-150917-C60E` (22:57) | 37% | one run of 75 s |

The microphone track was flawless through all three: steady -60 dB noise floor,
no gaps, no device changes. The far side was audible to the user throughout, and
the transcripts prove it. At 16:17 of the Emily call the user answers "what you
mentioned earlier, which is like I'll become like a CTO and managing a junior
dev" and minutes 15 and 16 are recorded as pure silence; nowhere in 38 minutes
does either person say "you're breaking up". `coreaudiod`'s own output meter
reports -17 to -20 dB RMS through every one of those silent minutes.

### The configuration, because the first attempt to reproduce it had the wrong one

All three were Google Meet in Chrome, with **AirPods Pro on output only, in
high quality A2DP, and an Audio-Technica AT2020USB-XP on input**. Two devices on
two clocks, chosen by hand in both Meet and Listen.

That distinction is the whole test. A headset that is *also* the input is in its
call profile, which is a different and much worse IO path, and reproducing that
instead came back clean and would have been read as "Bluetooth is fine". The
CoreAudio log named the AirPods as an input three times during the calls, which
is what the wrong guess was built on; the same log names `AT2020USB-XP` six
times, and that is what Listen was actually recording from. **The log says which
devices exist, not which one an app chose**, and `Settings.microphoneUID` is
where the second question is answered.

**The comment beside `onLevel` is why this was invisible, and it is still
right.** Bit-exact zero from a process tap really is the ordinary state of a Mac
playing nothing, so a silence detector on this track means nothing. What it
missed is that a dead tap produces the same zeros as a quiet room, so "no
detector" left the two indistinguishable for the life of the app.

`TapHealth` asks a different question with a certain answer: **are the zeros
interleaved with signal inside a single 10 ms window?** No resampler, codec or
converter produces that. It is an IO proc that missed its deadline and had part
of its buffer zero-filled underneath it. On 2026-09-01 the far end lost 39
samples of every 160 at 16 kHz on an exact 160-sample grid, and `coreaudiod`
logged 137 `HALS_OverloadMessage` events during that call, 80% of them within
two seconds of a torn second in a later one.

Validated against the whole library before it was wired in: **0 torn windows
across six healthy calls totalling four hours** (two Telegram, two WhatsApp, one
Discord, one Chrome), against 328 to 3005 on the three broken ones.

### The edge test is the whole reason it does not false-positive

A window straddling the instant speech starts is half zeros and half signal,
which is exactly the shape of damage, and a far side using DTX crosses that
boundary every time the other person pauses. So a window only counts as torn
when it carries signal in **both** its first and last quarter: an onset has
nothing in the first, an offset nothing in the last.

### Two phases, because holes on the grid look like an onset

The first live test caught 96.6% of injected tearing when the file was scanned
afterwards and **none of it as the audio arrived**. The injector aligned its
holes to the start of each flush batch, and the live scan aligned its windows
there too, so every hole sat in a window's first quarter and read as an onset.
`scan` now runs at two phases half a window apart and takes the worse answer.
The offline reading was only luckier, not better: a real tap whose holes land on
the grid would have been missed the same way.

### Silence only means something next to the microphone

Bit-exact zero on its own is not evidence. The gate is your own voice inside it,
and the numbers are measured rather than chosen: across the library the only two
silences over 45 seconds that are **not** failures are recording lead-ins with
zero speech in them, while every real one has 14 to 250 seconds of talking
inside it. So `Capture` warns at 45 s with 5 s of speech and rebuilds at 90 s
with 15 s, and `TapHealth.Report.lostRuns` applies the same gate to a finished
file so `listen audio --check` and the live warning cannot disagree.

## Rebuilding the tap from the IO proc's own queue deadlocks it

`AudioDeviceCreateIOProcIDWithBlock` is handed `queue`, so the IO proc runs
there. `AudioDeviceStop` blocks until the IO proc returns. Tearing the tap down
from `queue`, which is where both the drain timer and the health check live,
therefore hangs the recording it is trying to rescue. `restart` runs on a
separate `control` queue and asserts it with `dispatchPrecondition`, the way
`MicRecorder` already keeps one.

It also suspends the drain timer and then does `queue.sync {}` before touching
anything. Suspending a timer does not wait for a handler that is already
running, and that handler writes to the same file the rebuild is about to pad.

## The tap is bound to the output device it was born on

`createTap` passes `deviceUID = nil`, which means "the default output", and that
resolves **once**. Putting headphones on mid-meeting moved the audio to a device
the tap was not on, and nothing could follow it. `watchDefaultOutput` listens on
`kAudioHardwarePropertyDefaultOutputDevice` and rebuilds.

**Pinning the tap to the built-in output is not the fix, and would be worse.** A
tap only hears the device it is on. Somebody listening on a headset would get a
recording of perfect silence, because the meeting is coming out of the headset.
Following the route is the part that is always right; moving the route is the
user's decision and takes the call out of their ears.

Not verified on this Mac: there is only one usable output device here, and
setting the default to the Microsoft Teams virtual device returns `noErr` and
silently does not take. The rebuild path itself is verified through
`LISTEN_TAP_TEAR`; only the device-change trigger for it is not.

## `LISTEN_TAP_TEAR`, because waiting for a Mac to overload is not a test

`LISTEN_TAP_TEAR=0.25` zeroes the head of every 10 ms window of the far-end
track, which is the measured shape of the real damage. `LISTEN_TAP_TEAR=1` is
the other failure, a tap gone deaf altogether, and it is the only way to reach
the `Capture` side of the gate. Same reasoning as `LISTEN_OFFLINE`: the recovery
is the interesting half and it cannot be reached by hoping.

Verified with it: tearing detected live and the tap rebuilt three times in 50 s
(the 20 s debounce holding), tracks still aligned at 50.2 s and 50.3 s; and a
deaf tap warned at 45 s and rebuilt at 90 s, with the clock resetting to 0
afterwards.

**Zero the tail too.** The first version stopped at the last whole window, which
left up to 159 samples of real audio in every batch. Inaudible, but it is
signal, and signal is exactly what the deafness clock watches for, so the track
looked healthy while being entirely destroyed.

## A level timestamped on the main queue is not a level timestamped in the audio

`secondsYouSpoke` asks "in the last 45 seconds". Stamping each level with
`Date()` where it is *delivered*, inside `DispatchQueue.main.async`, answers that
with when the main queue was free instead of when somebody was talking: it
counted 5 to 11 seconds of speech in a 45 second window through which `say` ran
almost continuously. The stamp is taken on the audio thread now.

**And it counts seconds, not callbacks.** Dividing a callback count by a nominal
31 per second reported 70 seconds of speech inside a 45 second window, because
`MicRecorder.report` emits a short extra window at the end of every buffer and
the true rate is neither 31 nor constant. A `Set` of whole seconds is
rate-independent, and seconds are the unit the thresholds were calibrated in.

## The route is measurable, and the overload messages are not the mechanism

`verify_tap_routes.sh` plays speech through a chosen output, records it with the
real capture path, and reports what arrived. Measured 2026-09-01, 300 s each,
four cores pinned, the AT2020 on input both times:

| output route | torn windows | where |
|---|---|---|
| AirPods Pro (bluetooth, A2DP) | 22 | two bursts at 01:24 and 01:47, each ~0.22 s |
| MacBook Pro Speakers (builtin) | 1 | 00:00.23, the tap starting up |

So the Bluetooth route does tear and the built-in route does not, which is the
first direct evidence for what had only been a correlation across the library.

**And it tore with zero `HALS_OverloadMessage` events.** The section above cites
137 of them in the Emily call with 80% landing within two seconds of a torn
second, which is true and was over-read: overloads accompany the severe
episodes, they do not cause the tearing and are not necessary for it. An IO proc
can be late without `coreaudiod` deciding the lateness is worth reporting.
Anything built on "no overloads logged, therefore the tap was fine" is wrong.

**The magnitude is not reproduced and that matters.** The three lost meetings
tore 16 to 30 seconds each; this reproduces 0.2 seconds in five minutes. Three
variables sit between the two and none is tested: Chrome's WebRTC pipeline,
screen sharing, and the Microsoft Teams HAL plug-in that was loaded inside
`coreaudiod` then and has since been removed. Do not read the 22 windows as an
explanation of the 30 seconds.

### A binary verdict was wrong in both directions

`Report.healthy` started as `counts.torn == 0`. That called the healthy 300 s
control broken over its single startup window, and gave a lost meeting the same
verdict as a route that dropped a fifth of a second. `Report.verdict` grades it
instead, on the measurements above: intact below 0.05% of what arrived, `minor`
up to 1%, `lost` beyond. Six healthy library recordings score 0, the fresh
control 0.003%, the reproduced Bluetooth fault 0.1%, and the three lost meetings
2.2%, 7.3% and 8.9%.

### The warning was verified on screen, not just in the CLI

Everything else here was measured through `listen record` and `listen audio
--check`, which is the wrong instrument for the one thing the user actually
complained about: that nothing on screen told them the far side was missing.
Driven with `LISTEN_TAP_TEAR=0.25` against a scratch library and read back
through `AXUIElementCreateApplication(pid)`, mid-recording:

- the floating panel: `The other side is breaking up`
- the recording screen: `The other side is being recorded with gaps in it.
  Listen is rebuilding the capture.`
- the log for the same run: `the far side is arriving torn; rebuilt the tap`

Both labels are `AXStaticText` and come back in a `texts` dump, so unlike
`HoverRow` this warning is testable and there is no excuse for the next change
to it going unchecked. `tools/axprobe.swift press <pid> record` starts the
recording; the toolbar's Record button answers to `AXPress`, unlike the
pull-downs the index warns about.
