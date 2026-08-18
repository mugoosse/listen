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
