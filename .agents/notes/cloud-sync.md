# Cloud sync

The library record carries metadata and permitted sidecars. Phone audio travels
through a separate transfer record, and the Mac acknowledges durable ingest by
setting `audioOn` on the library record. These are separate proofs and their
state keys must stay separate.

## The audio master has a zone of its own, because `z4` is listed whole

The plan said `z4`, which is where audio already travels, and it is wrong for
one measured reason.

`ingest` lists that zone whole on every pass, `since: nil`, deliberately: a
transfer whose ingest failed stays in the zone and has to be seen again, and a
change token would hide it for ever. A listing fetches each record **with its
assets attached**, so one master per recording in `z4` would have every Mac
downloading the entire audio library every two minutes. On this library that is
1.7 GB a pass.

So the masters live in `z5`, and the half of the constraint that is permanent is
kept: the record type is still `r5` and the bytes still ride `asset_mic_wav`.
Production schema is append-only for ever and a **record type or a field is part
of it**; a zone is not. Zones are created per account at runtime by
`CloudKitStore.prepare`, so `z5` costs nothing that cannot be undone and needs no
deploy.

Nothing subscribes to `z5` and nothing ever lists it. A master is fetched by name
by a device that has already decided it wants those bytes, which is the one shape
of traffic worth 25 MB. `listen sync inspect` therefore prints how many masters
*this Mac knows of* rather than what is in the zone, because summarising it would
download the library to print one line.

The side effect worth knowing: a Mac on an older build never sees a master at
all. In `z4` it would have claimed each one, failed to open it as a transfer,
logged an error, and re-claimed it on the next pass for ever, which is churn in
the one zone every device subscribes to.

Measured on a real meeting, 1.07 hours, with `listen audio <id> --build`:

    tracks   494.4 MB   Float32, 461 MB/h
    master    61.0 MB   12% of the tracks, 57 MB/h, built in 3.8 s

Two facts that three seconds of synthetic tones could not show. Building is
cheap, four seconds an hour, so the hour budgeted for a library's worth was
wrong by an order of magnitude. And it is not cheap in **memory**: both tracks
are read whole as `[Float]`, about a gigabyte resident at the peak. That is why
`pushMasters` builds three a pass rather than everything it is owed.

The master is also **deleted locally once it has landed**. The device that
published it holds the raw tracks by construction, and those are the better copy
in every way that matters here: playback reads them, the pipeline reads them, and
`hasAudio` is already true because of them. Keeping the master beside them would
add 12% to every recording on the one machine that never needs it, which on this
library is 1.5 GB to hold a second copy of audio it already has. Rebuilding one
is four seconds. So `listen audio` reading `masters here: 0` on the Mac that
recorded everything is the correct state rather than a missing one, and a Mac
that was *given* audio is the one where that number is not zero.

## A device frees audio on a live device's list, never on a latch

`audioOn` was the acknowledgement and could not go on being it.

It is one string on the recording, written by whichever Mac won the ingest, and
it is true for ever afterwards: after that Mac has been wiped, sold, or
reinstalled. It only ever answers for an ingest, so it could authorise a phone
to let go and had nothing at all to say about a meeting recorded on a Mac, which
is most of the library. And it is only reconsidered when that recording's record
changes, which is exactly what a stalled recording's record does not do.
`askWhoHoldsTheWaiting` exists because of the same blind spot.

`DeviceBlob.holdsAudio` replaces it: the ids whose audio is on that device's own
disk, republished from disk by every heartbeat, in the device zone, which is
pulled every pass and carries no audio. It goes stale the way a heartbeat does
rather than the way a latch does.

`reclaim` runs once a pass, over the whole local library, and frees a recording
only when **all** of these hold:

- **Another device says it holds it.** Not the container: iCloud is a replica
  and `Backups` exists because of it.
- **That device is live.** Seven days without a heartbeat and its list stops
  being evidence, which is much shorter than the thirty days the roster keeps a
  row: being listed is a convenience, being believed about somebody else's only
  copy is not.
- **That device keeps audio.** This is the one that is not obvious. Two devices
  that are both trying to get rid of the same recording each read the other as a
  safe holder and delete on the same pass, which is mutual deletion of the only
  two copies. A device that is keeping audio is not going to change its mind
  inside one pass. `FakeSync` proves both halves.
- **Nothing here still owes work on it.** A device that transcribes does not
  free audio it has yet to produce a transcript from, and `CloudSyncHost` names
  whatever `Queue` is holding. Without the first, a Mac with the switch off
  would ingest a memo, delete it before the job started, and the phone would
  offer it again six hours later, for ever.

`audioOn` is still written and still read. It is what the transfer pipe turns on
and what `sync inspect` prints; it decides no deletion any more.

The switch is per device: `Settings.keepAudio` on the Mac, on by default, and
**Keep audio on this iPhone**, off by default. The phone's meaning is
deliberately narrow and its footer says so: it keeps what this phone recorded and
it never downloads the meetings the Macs recorded. That library is 1.7 GB of
audio and the switch has never meant that.

## One record type, two zones, and why the zone is the cheap half

`StoredRecord.zone` is new. It defaults to `type.zone`, which is right for every
record but the master, and the two stopped being the same question the moment one
type had to live in two places.

The alternative was a new record type, `r7`. That is a Production schema change,
which is permanent, for a thing a runtime-created zone does for free. Worth
stating plainly because the obvious implementation is the expensive one:

    record type   permanent, deployed, never removable
    field         permanent, deployed, never removable
    zone          created per account at runtime, deletable

## The suite was not hermetic, and it passed once per scratch directory

`EngineState` lives beside the library, keyed on the library path, so removing
the scratch tree at the top of `FakeSync.run` does not clear it. Two of the
libraries were cleared by hand and the rest were not, so a second run against the
same `--at` directory started holding a change token issued by the first run's
store. A fresh `MemoryStore` has never heard of that token: nothing is fetched,
and the failure surfaces several assertions later as a missing `metadata.json` on
whichever library was unlucky.

It passed for as long as it did because every run used a fresh directory.
`scratchLibrary` clears the state directory now, which is what the file's own
header always claimed.

The same pass found a real flake in the lease seam: it asserted **which** of two
devices won a genuine race, and passed until the suite grew enough around it to
change the timing. What has to be true is that both devices name the same holder
and exactly one reads it as its own.

## A sidecar this device has edited is not a sidecar it is behind on

The worst bug this app has had, and it is the shape `SyncState` was written to
make impossible for notes while recordings were left out of it on purpose. The
comment said a transcript has exactly one writer, the Mac that made it. It has
one *author*. It has as many **editors** as there are devices showing the
transcript, because correcting who said a sentence rewrites `transcript.json`
and `turns.json` on whichever Mac you are sitting at.

Measured on a real library, from the file times alone:

    metadata.json    21:27:19
    transcript.json  21:28:14
    turns.json       21:28:14

A speaker was corrected at 21:27:19, which is `TranscriptEditor.change` writing
the transcript, then the turns, then the metadata. Fifty-five seconds later the
first two were written again and the third was not, which is the signature of a
pull: `pullRecording` writes sidecars first and metadata only if it differs. The
correction went off the screen while its author was looking at it, nothing was
reported, and the push that followed found the two sides in agreement and sent
nothing.

Nothing exotic is needed to cause it. The pull runs before the push, on purpose,
so a Mac shut for a week cannot overwrite a week of work. Until the push lands,
the container still holds what this device had *before* the edit, so any pass
that re-fetches that record sees local and remote disagree, and two values
cannot tell "I am behind" from "I have an edit nobody has seen". A second Mac
pushing is enough to bring the record round again, and it does not have to touch
the transcript: renaming the recording republishes the record with its own older
transcript still attached.

So sidecars have a base now, per file, keyed `sidecar:<id>/<file>`, and the
four-line table at the top of `SyncState` applies to them unchanged:

| local vs base | remote | what happens |
|---|---|---|
| same | differs | take the remote, and agree on it |
| differs | anything | keep the local copy, report it, let the push carry it |
| unknown base | differs | take the remote, which is what this did before |

`agreeSidecars` writes the base after a push that landed and after a record that
already matched. `pullRecording` writes it per file, because a pull writes only
the files the manifest named and agreeing about the rest would be a claim it
cannot make.

**The unknown case is the migration and it takes the remote**, which is exactly
what the old code did, so the first pass after an upgrade behaves as before and
every pass after it is safe. `metadata.json` keeps its own rule, the `authored`
guard, which is a different question and was already answered.

Proved in `listen sync --fake`: a Mac edits a transcript, a second Mac with the
older copy republishes the record, the first Mac pulls and keeps its edit, and
the push that follows carries it to the second Mac. Disabling the guard fails
that case, which is how it was checked rather than assumed.

## The offline window had a deterrent nobody read

`takeTranscriptionLease` returns yes when the container is unreachable, and that
is right: Listen works with the network off and a Mac must still transcribe its
own recording. What was written down beside it, twice, was that `state:
transcribing` travelling in the metadata was the second deterrent for that
window. **Nothing read it.** A Mac that could not reach the container started
every job it had, whatever the last pull had told it about the other machine.

So the answer has three cases now instead of two. `.taken` is the container
agreeing, `.held(lease)` is somebody else having it, and `.unreachable` is a yes
with the caveat that nothing could refuse. `CloudSyncCore.othersRunLooksLive` is
the sentence, asked: another device named in `transcribed_by`, a state of
`transcribing`, no `transcribe_finished`, and a `transcribe_started` inside six
hours. Six hours is `claimGrace`'s number and its argument, and the failure it
avoids is the same one: a run that has shown nothing for that long is asleep,
stuck or on a machine that has been shut, and believing it for ever parks the
recording.

Four things are deliberately **not** evidence, and each is a seam: this device's
own run, a finished state, a run that recorded its own end, and a run with no
start time at all. The last one matters most: a `transcribing` with no clock
could be from any build and any month.

`listen transcribe <id>` was the other half of the hole. It is a second way into
the pipeline and it took no lease and wrote no provenance, so a Mac running it
while the other Mac's queue was on the same recording was exactly the race the
lease exists to stop. Both paths now go through `markTranscribeStarted` and
`markTranscribeFinished`, so the two cannot come to different conclusions about
a recording they both just transcribed.

## A switch is a policy, and a tap is an instruction

**Keep audio on this iPhone** is off by default and means "keep what I recorded
here". It has never meant "download every meeting the Macs made", which on this
library is 1.7 GB, and the footer says so. That left the phone with no way to
play back a meeting it did not record, which is most of them.

The missing piece was small and it is not the switch. `SyncState` gained `pin:`,
`reclaim` skips a pinned recording, and `fetchMaster` sets the pin. Without it
the next pass takes back what the tap just downloaded and the button appears not
to work: the phone keeps no audio by policy, and the Macs all report holding
those bytes, so every condition for freeing it is met within two minutes.

`freeMaster` is the other half and it refuses when nothing else reports holding
the recording. Wanting the space back is not wanting to lose the meeting, and a
button that can hand back the only copy is a button that will.

The same pair is in the Mac's actions menu, for a Mac whose switch is off.

## A one-channel master is two different things

A master built from a microphone track and a master built from an imported
mixdown are both one channel, and they go to opposite sides of the pipeline.
`Pipeline.run` reads `system.wav` as the everyone-track and `mic.wav` as the
user; `.agents/notes/speakers.md` records the trap in full as "An imported
recording has no mic track, and must not pretend otherwise". An `everyone`
master split back as `mic.wav` is an imported meeting transcribed as the user's
own voice, with every speaker in it labelled `Me`.

The channel count cannot tell them apart, so the **file name** does:
`master.flac` against `master-everyone.flac`. A recording is a folder and the
files in it are the truth, and a fact kept anywhere else is one that can be lost
while the audio survives. `MasterBlob.layout` carries it on the wire, optional,
because records published before it exist and every one of those was built from
tracks.

Until this, a mixdown-only recording got no master at all: `AudioMaster.make`
built from the two tracks and an import has neither, so those recordings could
never reach a second device in any playable form. The mixdown is decoded through
`AVAssetReader` rather than read straight, because a legacy m4a is whatever
sample rate and channel count that recorder used: reading a 44.1 kHz stereo file
as though it were already 16 kHz mono slows an hour of conversation to three.

The published master is kept on disk in this one case. There are no tracks
behind it to be the better copy, so removing it would leave the device that
published it holding an m4a its own pipeline reads and nothing else does.

## A pull cannot stamp a richer local folder as sent

A Mac can publish metadata and waveform before transcription finishes. If the
next pass pulls that earlier record after the Mac has written `transcript.json`
and `turns.json`, `pullRecording` deliberately leaves those unmentioned local
sidecars in place. The local folder is now richer than the record just pulled.

Stamping that whole local folder after the pull marks unsent transcript files as
sent. Every later push skips them, so another device can hold the early sparse
record indefinitely even while the Mac shows a complete transcript.

`pull` therefore writes the remote manifest without writing a recording sent
stamp. The following `push` fetches and compares once. An exact match is a no-op;
a richer local folder replaces the sparse record. The one-time
`repairSuppressedRecordingPushesOnce` removes only existing recording stamps so
already affected installations perform that comparison again.

## A remembered audio upload is not an acknowledgement

`sent:audio:<id> = 1` means the phone saved a transfer record once. It does not
mean a Mac holds the WAV. A transfer can be absent while the phone still has the
only durable copy, so an unacknowledged phone must check the transfer and create
it again when it is missing.

The durable stop condition is `audioOn` on the library record. When the phone
pulls that acknowledgement it changes the audio marker to `acknowledged`. That
also keeps the **Keep audio on this iPhone** setting safe: retained WAVs do not
upload again every two minutes after a Mac has confirmed the bytes.

## A stranded recording is invisible, and the screen said the opposite

The 0.15.0 fix above repairs the device that updates. It does nothing for a
device that stays behind, and a Mac on the old build strands every recording it
ingests without anything anywhere noticing.

Measured, on the live container, on a memo recorded at 16:02 on 17 Aug 2026
and still untranscribed at 18:45:

    z1 r1  present, state pending, audioOn <the other Mac>, manifest metadata.json
    z4 r5  absent
    z2 r6  present, 10022 bytes
    devices  iPhone 1.0, this Mac 0.15.0, the other Mac 0.14.2

Read together those four lines are the whole diagnosis. The other Mac won the
claim, which it had never done before: every one of the other 39 recordings had
`audioOn` naming this Mac. It downloaded the audio, deleted the transfer, and
transcribed it, and the voiceprints prove it, because `pushVoiceprints` compares
against the container on every pass and carries no local stamp. Its `push` does
carry one, so the 0.14.2 `pull` stamped the folder after transcription had
enriched it and the transcript was never sent, for ever. **Embeddings present
and transcript absent is the signature**, and it is only visible if something
prints both.

Nothing printed either, so `listen sync inspect --recording <id>` exists now,
and the device list prints the app version the heartbeat has always carried.
Before them the only evidence was absence on this disk, and absence cannot tell
"no Mac has it" apart from "a Mac has it and never said so".

Three consequences worth keeping separate:

- **The audio was never at risk.** It is on the other Mac and still on the
  phone, which keeps it under **Keep audio on this iPhone**. The reclaim
  invariant did its job.
- **The phone's acknowledgement was a one-way latch.** `sent:audio:<id> =
  acknowledged` was written when a pull saw any `audioOn`, and `upload` returns
  on it before it checks anything else. Nothing cleared it, so clearing
  `audioOn` in the container would **not** have made the phone offer the audio
  again, and the recovery could not be driven from the Mac missing the
  transcript. See "A claim is not a delivery" below. The recovery for this
  incident was to update the Mac holding it: `repairSuppressedRecordingPushes
  Once` clears its stamps and the next pass publishes what it made.
- **The window said the audio was coming from the iPhone**, because it inferred
  the holder from `metadata.source`. With one Mac that is always right; with two
  it is a coin toss, and here it named the one machine that was never going to
  do anything. `pull` now records `audioOn:<id>` in the sync state and
  `CloudSyncHost.audioHolder` turns it into the machine's own name, so a claimed
  recording says which Mac to go and open. The key is bookkeeping only: no
  decision reads it, and its prefix is disjoint from `sent:` and `note:` because
  `pushDeletions` walks those two and treats a stamp with no folder as a
  deletion to send.

## A claim is not a delivery

`audioOn` answers "which device holds the bytes". It does not answer "has
anything been made from them", and the latch read the first as the second.

So the marker has three values now. `acknowledged` is final and means a Mac has
published work: a `transcript.json` in the manifest, or a state of
`needs_labelling`, `done` or `failed`. `claimed:<stamp>` means a Mac took the
audio and has shown nothing for it, and it is believed for `claimGrace`, which
is **six hours**. Past that the phone offers the audio again, and the pull that
follows re-stamps the claim, so a Mac that is merely slow gets one offer per
window rather than one per pass.

`transcribing` is deliberately not a finished state. It says a Mac started,
which is the claim restated, and a run that dies leaves it behind: believing it
rebuilds the latch this replaces. A recording with no speech in it never gains a
transcript, which is why a finished state is the second half of the test rather
than a fallback.

**This helps a keep-audio phone and no other, and that is the design rather than
a gap.** A phone that lets go does so on `audioOn`, which is a Mac reporting
bytes on its own disk, and that report stays true when the transcript never
follows: the recording is on that Mac and is not lost. Nothing about the reclaim
invariant changed. `FakeSync` proves the window in both directions, and the
first draft of that seam used the ordinary phone core and failed, which is the
suite making the same point.

## Only the Mac holding the audio authors an ingested recording's metadata

`ingest` publishes the phone's `metadata.json` verbatim, because at that instant
the phone is still the author. The pipeline then runs on the ingesting Mac and
rewrites the file: `state` leaves `pending`, `asr_model` and `room` are decided,
`AutoTitle` may name it. The record still carries the pre-ingest snapshot until
the next push, and `pullRecording` was handing that Mac its own recording back
with the state reset, so the push that followed republished `pending` for work
that had finished hours earlier. Measured on the memo above: the record read
`state pending` for a recording that was transcribed, diarized and
speaker-labelled.

So a pull no longer overwrites `metadata.json` when `audioOn` names this device.
Narrow on purpose: every other device still stores the bytes verbatim, which is
the rule in `CLAUDE.md` and is what keeps fields this build has never heard of
alive. This is the one device that rule was wrong about, and `audioOn` is how it
says so rather than a guess from `metadata.source`.

It cannot lose a phone edit, because a phone edit already loses on the way up:
`addingPhoneContent` takes `theirs.metadata` whole, so a rename made on the
phone for a recording the container already holds does not reach the Mac at all.
That is a separate bug and `MetadataPatch` is the half-built answer to it, wired
into `Recording.patch` and into nothing on the wire.

## A Mac without the application strips the source icon

Found by causing it. Updating the stale Mac above ran
`repairSuppressedRecordingPushesOnce`, which clears **every** recording stamp,
so its next push re-compared the whole library against the container. That is
the intended behaviour and it published the missing transcript. It also
republished eleven recordings without `source-icon.png`, because that Mac does
not have those applications installed and `SourceIconExporter` can only export
an icon it can resolve from an installed bundle.

`push` builds a record out of local files alone, so a file a device can never
hold reads as a file that has been removed. And the Mac that *could* make the
icon did not repair it: its own `sent:` stamp still matched its unchanged local
folder, so `push` skipped those recordings entirely. Two devices, each correct
by its own rule, and the icon gone from the container.

Measured, by diffing the two libraries rather than by reading code:

    both Macs, source-icon.png on disk    29 and 18
    container, after the stale Mac pushed 18 manifests naming it

The repair was to copy the eleven PNGs to the second Mac, which changes its
local folder, which changes its stamp, which makes its next push send them.
Nothing needed to be re-derived and nothing was lost: the icon is a row
decoration.

`CloudRecords.keepingSourceIcon` now stops it happening again: a Mac's push
keeps an icon already in the container when it has none locally. **Only the
icon.** A general "never remove a sidecar this device lacks" rule would also
preserve `<id>.raw.json.bak`, whose absence is the evidence that a transcript
carries no hand corrections, so a blanket rule would change what
`hasHumanEdits` answers on every other device.

The wider point is worth keeping separate from the fix: **a push that clears
every stamp is a push that re-asserts this device's whole library**, and any
file it is missing for a legitimate local reason goes with it. Before clearing
stamps on a device, diff its recordings folder against another device's.

## A phone update cannot replace richer Mac content

The phone starts with the metadata it recorded, then the Mac adds the
transcript, turns and waveform. A later phone push can still carry that older
metadata snapshot. Saving it as a complete replacement erases the Mac sidecars
from CloudKit even though the Mac still has them locally and remembers sending
them.

Before saving a phone update, `CloudRecords.addingPhoneContent` merges it with
the current remote record. Existing remote metadata and sidecars win. The phone
can add content that is missing, but it cannot replace content the ingesting
Mac already published. `FakeSync` proves that a stale phone push preserves the
transcript, turns and Mac metadata.

## Source icons travel inside the sealed recording payload

Only a Mac can resolve an installed application's icon from its bundle ID. The
Mac exports a small `source-icon.png` beside the recording before its push. The
icon is stored inside the existing sealed `RecordingBlob`, not as a new
CloudKit field, so it remains encrypted and does not require a Production
schema change. A phone pull writes the PNG as an ordinary display sidecar.

The same phone merge rule preserves an existing remote icon when a stale phone
record has none. `FakeSync` verifies the icon bytes survive the sealed record
round trip.

## A forgotten voiceprint needs a tombstone, or the sync resurrects it

Stripping a person from every `embeddings.json` and pushing is not enough,
twice over. Every pass pulls before it pushes, so the Mac that just stripped
pulls the fat cloud copy back over its own rewrite. And a second Mac whose
file still holds the person sees remote version differ from local sha and
pushes the fat file straight back; the changeTag CAS does not help, because
its next fetch-then-save is consistent and succeeds.

So the forget is data: `VoiceprintTombstones`, per-person entries with a
stamp, replicated as its own r6 record under the opaque natural key
`forgotten-people`, merged per name by latest stamp, applied on **both** the
pull and the push side, expiring after 90 days. An unforget entry
(`removed: true`) wins a same-second tie, because keeping re-taught biometric
data is recoverable and stripping it is not. Banks that empty become
`r6drop:<id>` debts in the sync state, settled by `store.delete` wherever the
pass runs, and `pushDeletions` deletes the r6 alongside the r1 so a deleted
recording takes its voiceprint with it. The local `.forgotten-voices.json`
is in `DevicePolicy.neverSynced`: two devices' lists must meet through the
merge, never as bytes.

## `LISTEN_LIBRARY` scopes the library, and never the container

A scratch library is not a scratch device. `Library.mac()` honours
`LISTEN_LIBRARY` and every read and write follows it, which is what makes the
variable trustworthy for anything local. The CloudKit container does not follow
it and cannot: there is one container per iCloud account, `CloudAccount
.containerID` is a constant, and a sync pass run against a scratch library
therefore pushes that library's recordings into the same place the real one
lives.

Measured, by running the shipped app for about two minutes with
`LISTEN_LIBRARY` pointed at the output of `make_demo_library.sh`:

    real library before   38 recordings, 11 notes
    container before      r1×38 r2×13
    after                 41 recordings, 15 notes, r1×41 r2×17

Three invented meetings and four invented notes reached the real library, the
container, and from there both other devices. Nothing about the scratch library
was wrong. The pass simply had nowhere else to push to, and the pull that
followed wrote what it found into whichever library was active on the receiving
device, which was the real one.

**So a scratch run needs the sync off, not just the library moved**, and asking
somebody to remember that is not a fix. The consent was per install and the
library was not: `Settings.cloudSync` answers "is this Mac a syncing Mac", which
is a different question from "may this library be sent", and the second one is
the one every pass actually needs to ask.

`Config.cloudSyncLibrary` records the library the consent was given about, and
`cloudSyncApplies` is the question. Turning sync on stamps the active library;
a pass whose library is not that one is refused and says so on both paths:

    cloud sync: off for this library.
      consented:  ~/Library/Application Support/Listen
      active:     /tmp/listen-demo
    Turn it on for this one with `listen sync enable`.

Three things make it hold rather than merely exist. The check lives in
`CloudSyncHost.syncNow`, which is the choke point, because it started as five
caller-side guards and five places that must agree is a sixth caller waiting to
be written without one. The Devices pane ticks its box from `cloudSyncApplies`
rather than `cloudSync`, so the box cannot read "on" over a pane where nothing
is syncing, which is the reading that would have prevented the incident. And
the fallback for an install that predates the key is `defaultMacRoot`, never
the active library, so running the migration under `LISTEN_LIBRARY` cannot
quietly consent to a scratch library.

Verified by repeating the incident on the fixed build. Same script, same
two-minute launch, `r1×40 r2×13` and 40 recordings before and after, and no
`ListenSync/<digest>/` directory created at all, which is the proof no pass
ran rather than that a pass ran and pushed nothing.

A marker file inside the scratch library was the other candidate and is weaker:
it protects only the libraries somebody remembered to mark, which is the same
class of mistake as remembering not to run the command. The cost of the path
approach is that moving a real library asks the question again, and that is
honest rather than a wart. `EngineState` is already keyed on the path, so a
library at a new path is already a new device to the container.

Two claims in the source said the opposite and have been corrected, because
either one is enough to talk somebody into the run: `make_demo_library.sh` said
"this touches nothing in ~/Library/Application Support/Listen", and
`SyncCLI.cloud`'s "so a scratch CloudKit run remains isolated from the real
library" means isolated *from the library*, sitting above code that pushes into
the shared container. `make_demo_library.sh` also refuses outright when sync is
on and no library is recorded against it, which covers the build that has the
guard but has not been launched since, and the one that does not have it.

The recovery is worth knowing because it is not the obvious one. Deleting the
invented recordings from the receiving library does **not** remove them from
the container by itself, and a later pull can bring them back. What retracts
them is `pushDeletions`, which acts on `sent:` stamps whose folder has gone, so
the retraction has to be run by the device whose sync state holds those stamps.
Here that was the real library, because the real library is what pushed them:
deleting the seven folders and files there and letting one ordinary pass run
took the container back to `r1×38 r2×13`. Check `base.json` in
`~/Library/Application Support/ListenSync/<digest>/` to find out which device
that is before deleting anything. The digest is `SHA256(library path)`
truncated to 16 characters, over the **unresolved** path, so `/tmp/...` and
`/private/tmp/...` are two different state directories.

A scratch library that has served its purpose is retired state-first: remove
`ListenSync/<digest>/` before the library itself. With the stamps gone nothing
can be pushed as a deletion, which is the failure the "library that has lost
everything" guard in `pushDeletions` exists to catch and should not be relied
on to catch twice.

## Nothing ever created the key, and both sides said "waiting"

Turning sync on set `Settings.cloudSync` and nothing else. `KeyStore.shared
.load()` was the only production read of the key, and `PairingKey.generate()`
was called from `FakeSync` and nowhere else, so on a fresh install every pass
ended at "No sync key yet" while the phone showed "Waiting for the key from
your Mac": each device waiting for the other, for ever. The Sync pane made it
worse by printing that report twice, as the status and as the last error, over
a "Save your key" button that silently did nothing without a key.

It shipped that way because no machine that mattered ever ran keyless. The
developer's Macs got their key from the legacy file migration, which copied it
into iCloud Keychain before the file fallback was removed, so the missing
generation was invisible on every dogfooding device and cost the first real
outside install its whole first day. Found on a friend's fresh 0.17.0 and
build 57.

`KeyStore.provision` in `Sealing.swift` is now the one place a key is made,
and it asks the container before every creation. Records in the devices zone
mean a key exists somewhere, so this device must receive it rather than mint
a rival: two keys sealing one container is ciphertext each side half cannot
open, and iCloud Keychain keeping whichever was written last does not heal the
records already sealed under the loser. `mayCreate` is the Mac alone, which
is what keeps a Mac and a phone first-enabling minutes apart from racing to
be first author; the phone's waiting states name the repair instead
(`CloudSync.KeyStatus`). The typed-code fallback that `Sealing.swift` had
always promised finally has a surface on both platforms: "Enter key" on the
Mac's Sync pane and on the phone, validated as 32 Base32 bytes before it is
kept, because an almost-right key in the keychain fails every later open with
no hint that the key is the reason.

## The activity log is one line, appended with O_APPEND

`activity.jsonl` is written by two processes (the app and a spawned
`listen mcp`), so `ActivityLog.append` opens with `O_APPEND` rather than
seek-to-end: only the kernel can make two appends land whole. That holds for
a single write well under the pipe buffer, which is why an entry is always
one line and carries ids rather than content.

These incidents have deterministic seams in `FakeSync`:

```sh
./build.sh
.xcbuild/Build/Products/Release/listen sync --fake --at /tmp/listen-fake-sync
```

The suite must prove that a late transcript reaches a fresh phone, a stale
phone push cannot remove it, a missing unacknowledged transfer is uploaded
again, source icon bytes reach the phone, a device without the audio comes out
of a pull knowing which device has it, a claim that publishes nothing expires
into a fresh offer, and only the Mac holding the audio authors an ingested
recording's metadata.

For the audio master it must prove that a pull frees nothing, that an empty
roster, a stale device's list and a device that is itself letting go each
authorise nothing, that a live keeping device's list does, that a master reaches
a device with no audio and splits back into the two tracks sample for sample,
that the device which received it does not publish it back, that `z4` never
carries one, and that deleting a recording deletes its master.

It is hermetic and repeatable: run it twice against the same `--at` directory
before believing it.

## Two paths delete a note on somebody else's say-so, and only one trashed it

`deleteLocally` states the rule for the pull side: a deletion arriving over sync
was made on some other device, and this one cannot tell a deliberate one from a
bug or from a library that briefly looked empty, so the file is **moved, not
removed**, and `Trash` holds it for a fortnight.

The push side has its own branch for the same event, the one for a pass whose
pull failed on the network and whose push ran anyway. Its own comment calls it
"somebody else's deletion". It called `library.deleteNote`, which is a bare
`removeItem` with nothing behind it.

**Found on the real library, not by reading.** `activity.jsonl` held
`{"at":"2026-08-18T19:33:29Z","count":4,"event":"sync_deleted"}`, the library
had gone from four notes to none, and `listen sync trash` listed two recordings
and no notes at all. The backups still had them, which is the only reason they
were recoverable. `sync_deleted` is logged only for `report.deletedLocally`, and
`CloudSyncHost` justifies logging counts rather than ids by saying "the trash
holds the folders for a fortnight", which was true of recordings and false of
notes.

The trash's own instruction had been wrong for as long: `listen sync trash`
prints "Put one back by moving it into recordings/ or notes/", and nothing ever
put a note there.

`FakeSync` now drives that branch on purpose, by deleting the record behind the
receiving device's back so its pull has nothing to react to, and asserts the
`.md` is in the trash. Checked both ways: with `deleteNote` back in place the
assertion fails, which is what makes it a test rather than a decoration.

## An editor that rebuilds a note drops the field nobody told it about

`Note` is shared source, not a copy: `listen-ios` compiles 21 files straight out
of `../listen/Sources/ListenKit/`, `Sidecars.swift` among them. So a field added
here appears on the phone the moment it is rebuilt, with no porting step. That is
the good half.

The bad half is that every place which **constructs** a `Note` rather than
editing one silently resets whatever it does not name, because the memberwise
initialiser gives the newer fields defaults. `AppModel.saveNote` owned a title
and a body and rebuilt the whole note around them, hand-carrying `prompt`,
`chat`, `recordings` and `extra` across. Adding `tags` did not break it, which is
the problem: it compiled, said nothing, and unfiled the note on every edit made
on the phone.

**It would have been worse than the loss that pattern was already fixed for
once.** `prompt` and `chat` sit outside `Note.version`, so losing them leaves the
two sides agreeing on a digest while holding different files, and the damage sits
there until something else writes. `tags` is *in* the digest, so a wipe reads as
a deliberate edit and pushes: the device that dropped them hands that to the
other as the new truth.

The fix is not to name `tags` in the list. It is to stop rebuilding: start from
the note on disk, change the two fields the screen owns, write it back. A field
added next year is then carried by a line nobody has to remember to write.

`FakeSync` asserts the invariant from the sync's side, as "an edit that only
knows title and body keeps the filing", and checks the body really crossed so
the case cannot pass by moving nothing.

## A pass never re-offers an unchanged record, so `listen sync refetch` exists

`pull` asks `store.changes(in:since:)` with the token from the last pass, so a
record that has not changed since is never mentioned again. That is the whole
point of a change token and it is also a one-way door: **something lost locally
while its record survived in the container is gone for ever from that device.**

Measured on the real library. Fourteen notes vanished from the Mac, every note
record was still in the container (`r2×14` in `listen sync inspect`), and no
number of passes brought one back. Restoring the files from a backup on one Mac
did not propagate either: the restored copies matched the records exactly, so
`decideNote` said `.nothing` for thirteen of the fourteen and the push had
nothing to send. Only the one note whose record was genuinely absent travelled,
and it arrived as a new record, taking the container from 14 to 15.

Dropping the change token is the way back, and it can only add. The distinction
that makes it safe is `refetchedEverything`, which is set when the **server**
could not resume: that is the case where a record's absence has to be read as a
deletion, and `everSeen` is what tells a genuine expiry from a record this device
never held. A token dropped on purpose is not that. The fetch runs from the
beginning, every record arrives in `changed`, and the store reports no deletions,
so `gone` is empty and the pass has nothing it could remove.

Only the token goes. The `sent:` stamps stay, or this would turn into a re-upload
of the whole library, and `everSeen` stays because it is the deletion guard.

`FakeSync` proves both halves, which is what makes this a claim rather than a
hope: "an ordinary pass cannot bring back a note the container still holds", then
"and dropping the change token does, without deleting anything". The first of
those is the one that would quietly rot, so it asserts the note is **still
missing** after a normal pass.

## "Syncing transcript" outlived sync being off at all

`Queue` finished a transcription and stamped the recording's activity
`.sendingTranscript` unconditionally. The only thing that ever advances that
stage to `.ready` is a sync pass, `syncSoon` refuses to run when
`Settings.cloudSyncApplies` is false, and both the sidebar row and the
recording page draw whatever the last activity said. So on any Mac that never
enabled sync, every transcribed recording said "Syncing transcript" for ever,
which is how the first outside install read a finished recording as stuck.

The fix has two halves and both are needed. `Queue` now emits
`.sendingTranscript` only when a pass is actually going to run, and `.ready`
otherwise; and `CloudSyncHost.stop()` clears the sync-owned stages
(`sendingTranscript`, `retrying`, the transfer stages) so turning sync off
takes its promises off the screen with it. The queue's own stages stay through
a stop, because a job that is queued or transcribing is still true with sync
off and the queue is what ends those.

`FakeSync` grew `activitySeam` for the vocabulary's lifecycle (a clean push
says syncing then ready; a refused save says retrying, with a reason, and
heals on the next pass), and `verify_sync_status.sh` drives the built app over
a scratch library to assert the words never reach the window with sync off.

## A retry that never says why is a stall nobody can fix

Every `.retrying` activity always carried the error in `detail`, and no
surface showed it: the row said "Retrying sync", the page said the same, and
the sentence that named the actual problem existed only in memory. The first
outside install stalled that way for a day, and the diagnosis had to wait for
a house call.

Three changes, one idea: the reason travels as far as the stall does.
`SyncTrouble.plain` maps the CKError codes a private-database sync actually
hits into sentences a person can act on (storage full, not signed in, no
connection, managed account, too-old build), applied at the moment the error
object still exists, so `CloudActivity.detail` and `CloudReport.errors` carry
sentences everywhere they surface. The sidebar row exposes it as the row's
tool tip and the page prints it beside the verb for `.retrying` and
`.failed`. And the last pass is persisted (`EngineState.LastPass`,
`last-pass.json` beside the tokens) because `listen sync status` is a fresh
process: the one command a stalled install gets asked to run used to name the
account and the container and not the thing actually wrong.

## Which environment a build reaches is a property of how it was installed

TestFlight and a Developer ID .app reach Production; an Xcode Debug install
reaches Development (`listen-ios` sets it per configuration, `make_app.sh`
per profile). Two devices in different environments never see each other's
records and nothing anywhere says so. When a phone and a Mac cannot see each
other, ask `listen sync status` on the Mac and the Sync pane on the phone
which environment each is in before suspecting anything cleverer; the status
command prints it precisely because this question is otherwise unanswerable
in the field.

## An empty track threw out of the master build, and only the other Mac said so

Measured on 2026-09-03, on the live library. A 22-minute WhatsApp call recorded
on 2026-09-02 sat on mb-flame as "Retrying sync: Audio is not available in
iCloud yet" for a day, with the whole transcript on screen under it. The two
halves, read from the state directories:

    MacBook Pro  last-pass.json  audio 2026-09-02-123026-F884: … avfaudio -50
                 base.json       no master: stamp, alone among 61 recordings
    mb-flame     last-pass.json  "Up to date"
                 the folder      sidecars all present, no audio, no master.flac

The recording's `mic.wav` was 44 bytes, a header and no frames, because the
microphone never opened for that call. `AudioMaster.read` sized its buffer from
`file.length`, and `AVAudioFile.read(into:)` fails a zero-capacity buffer with
`Code=-50 … {false condition=buffer.frameCapacity != 0}` rather than reading
nothing. That threw out of `AudioMaster.make`, `pushMasters` never stamped
`master:<id>`, and the recording stayed owed and re-failed every pass for ever.

**The stall was invisible on the Mac that caused it and named on the Mac that
could do nothing about it.** The heartbeat republishes `holdsAudio` from disk
every pass, and this Mac does hold the raw tracks, so flame's `pullMasters`
correctly wanted the master, correctly fetched, and correctly got nothing. Its
sentence is true and points at the container; the error was two machines away in
`last-pass.json`. When a recording is stuck fetching audio, read the *author's*
last pass before believing anything on the screen in front of you.

The guard is one line in `read`, and the empty side still counts as a track: the
file exists, so `make` keeps `channels == 2` and the master splits back into a
silent `mic.wav` beside the real system track. Dropping to one channel would
have been the bug in "A one-channel master is two different things", with the
whole far side landing in `mic.wav` on every other device and every speaker in
it read as the user. Verified by compiling `AudioMaster.swift` and
`AudioFile.swift` on their own against the real 44-byte `mic.wav` and five
seconds of tone: before, `THREW: … -50`; after, `master.flac layout=tracks
channels=2`, splitting back to two tracks of 79861 frames.

No recovery step is needed for a recording already stuck this way. Nothing was
stamped, so it is still owed, and the first pass on the fixed build publishes it.
Measured on the recording above, from the two `last-pass.json` files:

    17:59:19  the old build's final pass      avfaudio error -50
    18:01:16  first pass on the fixed build   "sent audio for 1"
    18:02:31  mb-flame's next pass            "got audio for 1"

A day of "Retrying sync" ended 75 seconds after the first pass that could build
the file, and the master that landed is 22.0 MB, 2 channels, 1331.39 seconds
against the metadata's 1331.365.

## A phone's `holdsAudio` is not a master, and the Mac blamed iCloud for a day

The sentence a user read for a day, under a 45-minute memo whose audio was
still on her phone:

    The audio for this meeting is on iPhone.
    Retrying sync: Audio is not available in iCloud yet

Both lines are true and the second one points at the wrong place. It comes from
`receiveMaster`, reached from `pullMasters`, and it was generated by
construction rather than by anything going wrong:

- `heartbeat` publishes `holdsAudio` as `library.all().filter(\.hasAudio)`,
  which for a phone includes every recording it has made and not yet shipped.
  That field is about bytes on a disk and has to stay that way, because the
  reclaim invariant reads it and that is the one rule where being wrong loses a
  recording.
- `pullMasters` read it as "a master exists", asked, and got nothing, because
  the phone never publishes one. That is deliberate and commented in
  `listen-ios/App/CloudSync.swift`: publishing would send the same conversation
  up twice, since the Mac that ingests the transfer republishes it from the
  tracks it received.
- `keepAudio` defaults to **true**, so this ran on every Mac, every pass, for
  every un-ingested phone recording, for ever.

**The fix is per recording, not per device.** The obvious move is a
`publishesMasters` flag on `DeviceBlob`, and it is a no-op: its only possible
fallback for a device that has not shipped the new build is `kind != "iPhone"`,
which already decides the same answer, so the field costs a change to a sealed
payload and changes nothing. Filtering phones out of `holders` is worse than a
no-op, because it loses a case that works: a phone memo ingested by a Mac that
has since slept past the seven-day `isLive` window still has its master in the
container, and the phone is then the only live device reporting the bytes.

`canHaveMaster` asks the question that is actually being asked: `source ==
"iphone"` **and** `base[audioOn:]` nil means no Mac has ever held the tracks, so
nothing can have published a master. `SyncState`'s own doc for that subscript
already said so ("a phone recording still in flight rather than one that has
landed"). Gated on `source` as well as the nil because `audioOn` cannot tell
"asked, nobody holds it" from "never asked", and `CloudSyncHost.audioHolder`
reads the raw string and would print "your other Mac" for a sentinel.

**The Mac already had the right sentence and the phantom was hiding it.**
`DetailView.currentActivity` returns `.waitingForMac` with "Waiting for audio
from your iPhone" for exactly this case, below the `CloudSyncHost.activity(for:)`
check. Deleting the phantom brings it back, so no new `CloudActivity.Stage` was
needed: a case would have broken four exhaustive switches, two of them in the
other repo, and leaving it out of `syncOwned` would have reproduced
"'Syncing transcript' outlived sync being off at all" exactly.

The phone's half was the mirror image. `storedState == .pending` drew "Waiting
for your Mac" even when this iPhone still held the only copy, while the sentence
directly underneath it said the opposite and was right. The two halves of
`pending` have opposite repairs, and the heading gave both the same one.

## A miss with no stamp is a slot burned every pass

The second cost of the phantom, and the one that would have survived fixing only
the sentence. `pullMasters` takes `prefix(masterBatch)` and `library.all()` is
newest first, so the three newest recordings hold every slot in the batch. Phone
recordings waiting to be ingested are always the newest, and nothing was stamped
on a miss, so they held all three for ever and genuine masters behind them were
never reached at all.

`masterMiss:<id>` is that stamp, and three things about it are load bearing:

- **It is filtered before `prefix`, not after.** Filtering a `prefix(3)` leaves
  the three newest holding the slots and skipping, which is the same starvation
  in a smaller box.
- **It lives in `pullMasters` and not in `receiveMaster`**, which is shared with
  `fetchMaster`. A backoff in the shared function makes the Download audio
  button do nothing inside the window, which is "A switch is a policy, and a tap
  is an instruction" restated as a bug.
- **Only `absent` stamps it.** `receiveMaster` returns three outcomes now rather
  than a `Bool`, because a thrown error is usually the network and stamping on
  that would walk the whole library laying down ten-minute waits, then leave
  everything skipped for ten minutes after the connection came back.

Ten minutes, against a two-minute poll and three masters a pass: a second Mac
meeting a forty-recording library needs about fourteen passes, so twenty-eight
minutes, for the publisher to clear the queue. Ten re-asks about three times
across that window and keeps "the whole library within the hour"; thirty would
turn that hour into a day.

Both halves are in `FakeSync` as `phantomMasterSeam` and `masterBackoffSeam`,
and both were checked the other way round: with the skip removed the first seam
fails at "the genuine master never arrived: 0 pulled", and with the backoff
removed the second fails at "a miss inside the window asked the container
again". The starvation assertion is the one worth keeping, because a seam that
only checked the fetch count would have passed on the version that still
starved.

## Three things about the verification harness, none of them the code

**An id whose last field is not hexadecimal is invisible to `find` and visible
to `all`.** `Metadata.isValidID` requires four hex digits, `Library.all` lists
directories without validating, and `Library.find` returns nil for anything
else. A fixture id like `PH01` or `REAL` therefore passes every assertion made
through `all()` and fails only the ones made through `find`, which reads exactly
like the code under test having done nothing. `activitySeam`'s `ACT1` and `ACT2`
are invalid the same way and have never bitten, because that seam only ever goes
through `all()`.

**`listen sync --fake` is repeatable, except under a long scratch path.**
Measured on the released 0.31.1, build 324, so this is not a property of any
change: a second run against the same `--at` fails at the first push with "14
items are missing from this device and only 1 remain" when `--at` is a deep path
under `/private/tmp/claude-501/...`, and passes twice under `/tmp`, under `$HOME`
and with the default. Something about that path stops `scratchLibrary` clearing
the state it means to clear. Until somebody finds it, run the suite under `/tmp`
or with no `--at` at all, and treat a second-run failure under an unusual path
as the harness rather than as the code.

**`verify_sync_status.sh`'s positive control fails at HEAD.** "the recording's
row is on screen" fails while the two assertions it anchors both pass, which is
precisely the vacuous state that control exists to prevent: the script's own
comment says two of its three checks are about absence and one presence
assertion has to hold them up. Measured against the released 0.31.1, build 324,
by swapping `Listen.app` for `/Applications/Listen.app` and running it again, so
this is not a property of any change either. Until it is fixed the script's
"nothing says Retrying sync" result means nothing, and the honest reading of a
run is 5 passed, 1 failed, 2 unproven.

## Nothing bounded a CloudKit call, and the default for an asset is seven days

The other half of the day-long stall, and the answer to "I have to quit the Mac
app and open it again before new recordings appear".

`CKOperation` has two timeouts and this file set neither, so an asset transfer
that stopped moving could hold a pass open for a week. A pass is guarded by one
flag, and every later pass is dropped into `again` and forgotten, so nothing
new arrived until the process was restarted and the flag went with it.

Four things, and the order matters because each one is useless without the ones
before it.

**Bound every call.** `CKOperation.Configuration` reaches only operations, and
four paths in `CloudKitStore` used the convenience database API and kept the
default: `prepare`, `delete`, the read-back inside `save`, and `changes`, which
is the one carrying the whole transfer zone. `database.configuredWith` covers
them. Sixty seconds for a scalar and ten minutes for an asset, which is 86 MB
at 1.2 Mbit: a bad hotel rather than a broken transfer. A fresh `Configuration`
per operation, because it is a class and a shared instance mutated later
mutates every operation still holding it.

**Make cancellation real.** `withTaskCancellationHandler { operation.cancel() }`
does not compile as written: `onCancel` is `@Sendable`, `CKOperation` is not,
and the iOS target builds this file in Swift 6 mode while the Mac does not.
`OperationBox` is the `@unchecked Sendable` holder, and it also closes the race
where `onCancel` fires before `database.add`, which would cancel nothing and
leave the continuation waiting for a callback that never comes: the same wedge
with a different cause.

**Let the loops notice.** Every per-record loop in `CloudSyncCore` catches its
own errors and continues, so a cancelled store call was swallowed and the loop
walked the rest of the library making failed calls. `if Task.isCancelled
{ break }` in the five loops that matter.

**Then, and only then, a watchdog.** `endAStuckPass` cancels a pass past twenty
minutes. Cancelling rather than merely clearing the flag is the load-bearing
part: every core entry point is `var base = state.base` ... `defer { state.base
= base }`, so an abandoned step writes a snapshot taken before it stalled over
everything a newer pass has done since. The later it unwinds, the more it
destroys. It is also disowned, because cancellation is a request and waiting
for a call that cannot be ended to notice one is the wedge again with an extra
step; the generation guard on `syncNow`'s `defer` is what makes that safe.

It reports `sync.pass_timeout` through the existing `operation_failed` event,
which needs no schema change because `code` is a free string. So the stall that
was invisible for a day is now a number.

## A long-lived upload must not be startable twice

The phone's audio transfer is now `isLongLived`, which hands it to `cloudd` and
finishes it after the app is suspended or killed. That is what turns "keep
Listen open" into "put your phone in your pocket", and it introduces a state
nothing had to think about before: **sent, not yet landed, and nobody in this
process watching.**

The stop condition is the container, and the container has no record until the
upload completes. So between handing it over and it landing, every relaunch
looked exactly like "nothing has been sent" and enqueued another copy of the
whole recording. Then another. Whichever landed first would win and the losers
come back as `serverRecordChanged`, which reaches the screen as "another device
updated this first": a false sentence on top of an unbounded queue of 86 MB
uploads over somebody's cellular connection.

`inflight:<stamp>` is written **before** the save and flushed, because a kill in
the first second must still leave evidence. Thirty minutes of grace, from the
size: 86.6 MB over a poor but working 400 kbit link is about 29 minutes. Past
that the container is asked directly, which is the branch that already existed.
A save that throws *in this process* clears the marker instead, because it never
reached the daemon and there is nothing to wait out.

Three scoping decisions worth keeping:

- **Only the transfer.** Not "any record with assets": a recording record
  carries a 314 KB `transcript.json` and wants the immediate error that drives a
  readable retry, and a master is 25 MB on a Mac that is not being suspended. A
  claim writes the same record type and is excluded by the asset test, since
  `ingest` now reads the pipe without asset bodies.
- **No resource ceiling on it.** `isLongLived` and a short
  `timeoutIntervalForResource` fight: the second tells the daemon to give up
  partway through the thing the first exists to finish. What bounds it instead
  is `inflightGrace`.
- **Durable staging.** `CloudKitStore.save` wrote each asset into
  `temporaryDirectory` and removed it in a `defer`. A killed process never runs
  that `defer`, and `temporaryDirectory` is exactly what iOS reclaims while the
  daemon is still reading the file. Long-lived assets stage beside the sync
  state and are swept by age instead.

`beginBackgroundTask` around the pass is in there too and is **not** what
finishes the upload. It buys about thirty seconds, the same instrument
`Recorder` uses to get the microphone back, and it is there so a pass caught
mid-handover completes the handover rather than being cut off inside it.
