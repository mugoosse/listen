# Cloud sync

The library record carries metadata and permitted sidecars. Phone audio travels
through a separate transfer record, and the Mac acknowledges durable ingest by
setting `audioOn` on the library record. These are separate proofs and their
state keys must stay separate.

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

These incidents have deterministic seams in `FakeSync`:

```sh
./build.sh
.xcbuild/Build/Products/Release/listen sync --fake --at /tmp/listen-fake-sync
```

The suite must prove that a late transcript reaches a fresh phone, a stale
phone push cannot remove it, a missing unacknowledged transfer is uploaded
again, and source icon bytes reach the phone.
