# Syncing Listen

Listen syncs through the user's private CloudKit database. There is no Listen
account, Listen server, LAN listener or shared library folder.

Every payload is sealed on a device before upload with a 256-bit key stored in
iCloud Keychain. CloudKit sees opaque record names and encrypted bytes. The only
plain fields are `claimedBy` and `audioOn`, which coordinate which Mac takes a
phone recording and when the phone may release its audio.

## What travels

- Metadata, transcripts, turns, waveforms, notes, contacts and the dictionary
  travel between Macs and iPhone.
- Voiceprints travel between Macs and, with **Recognise voices on this iPhone**
  turned on, to and from the iPhone. The phone can then name the speakers in a
  recording it made without waiting for a Mac, and the voices it hears reach
  the Macs. Where two devices have a print of the *same* recording, the Mac
  wins: it diarized the separated tracks with the full pipeline, so the phone's
  first pass stands down once a real transcript for that recording exists.
  Turning the switch off deletes the voiceprints from the iPhone and stops the
  subscription.
- A name a *person* applies outranks that. Saying who a voice is on the iPhone
  keeps that recording the iPhone's to speak for, and the Mac that transcribes
  the audio carries the name onto its own pass rather than replacing it, so the
  transcript that comes back has the person in it.
- Forgetting a person's voiceprints travels too: the forget is a sealed
  tombstone in the same zone, applied on every pass and on every device that
  holds a bank, so a stripped voice does not come back from a stale Mac or
  linger on a phone.
- Mac recordings keep their audio on the Mac that made them.
- Phone recordings keep their audio until `audioOn` names the Mac that has
  ingested it. The phone can keep another copy when its storage setting is on.
- Deleting a recording or a note is a sealed tombstone rather than an absence,
  so it survives a device that wakes up with work of its own and pushes before
  it has heard about the deletion. Every device applies the list before it
  sends anything, and a deletion beats an edit that had not been sent yet: the
  edited copy goes to that device's trash and the pass says so. Every device
  keeps a deleted recording for 14 days, including the one it was deleted on,
  and `listen sync trash --restore <id>` puts it back everywhere.
- Device-specific change tokens, merge bases and identity stay outside the
  library.

CloudKit is incremental. A device pulls changes first, then pushes local work.
It also polls while Listen is open, and silent pushes ask it to run sooner.
Devices do not have to be awake at the same time.

## Using it

Turn on **Sync this library through iCloud** in Listen for Mac and **Sync through
iCloud** on the iPhone. Both devices must use the same Apple Account with iCloud
Keychain enabled. The shared key arrives through iCloud Keychain, so there is no
QR code, network address or pairing screen.

Useful checks from the signed Mac app:

```sh
Listen.app/Contents/MacOS/Listen sync status
Listen.app/Contents/MacOS/Listen sync inspect
Listen.app/Contents/MacOS/Listen sync deletions
Listen.app/Contents/MacOS/Listen sync trash
Listen.app/Contents/MacOS/Listen sync --fake
```

`status` reports the CloudKit environment and account. `inspect` reports the
container's opaque record shapes without decrypting library content.
`deletions` lists what this library has been told to delete and therefore what
it will refuse to accept back; `trash --restore <id-or-slug>` puts one back on
every device. `--fake` runs the complete sync logic against `MemoryStore`, with
no CloudKit account or network access.

## Source builds need their own container

The committed identifiers belong to Listen's Apple Developer team and its
Production container. A source build signed by another team cannot use them.

A fork that needs sync must create its own CloudKit container, use app IDs and
provisioning profiles that grant both apps access to it, replace the container
identifier in `CloudNaming.containerID` and both apps' entitlements, then deploy
the `r1` through `r6` record schema to Production. Leaving sync disabled requires
none of that, and the local library continues to work normally.
