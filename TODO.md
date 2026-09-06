# Listen: state of play

Where the project is, what is left, and what needs a decision. Update this in
the same commit as the work it describes.

Last updated: 6 September 2026, the Apple engine seam, the languages question
and an iPhone that reads its own recordings. See **Before 0.33.0 ships** below,
which is the live list. 0.32.2 is the last thing published.

Older sections have rotted: several entries under Known defects and Not yet
verified were closed months ago and say so nowhere. Read `.agents/notes/` first
for anything about transcription, speakers or capture; those are maintained.

## Milestones

| # | Milestone | State |
|---|---|---|
| 0 | Skeleton and build spine | done |
| 1 | ASR CLI | done |
| 2 | Capture | done |
| 3 | Diarization | done |
| 4 | Library and UI | done, being revised (see UI below) |
| 5 | Speaker labelling | done |
| 6 | Voiceprints | done, thresholds measured on real recordings |
| 7 | Settings, onboarding, permissions | done, onboarding still unrun on a clean account |
| 8 | CLI install, MCP | done |
| 9 | Release pipeline | done: 0.2.0 out, and an update proven installing |
| 10 | Notes | store, CLI, MCP tools, skills, UI and sidebar navigation in; unreleased |

## Notes

Unreleased, and the whole of it is in the working tree rather than in 0.2.0.

Notes live at `~/Library/Application Support/Listen/notes/<slug>.md`, one
markdown file each, with `recordings: [...]` in the frontmatter. `Notes` owns
read and write; the CLI, the MCP server and the window all go through it.

Two kinds. The user's own note, one per recording, `source: you`, editable in
the Notes tab and while the recording still runs. Notes an agent wrote, which
can name several recordings at once. An agent may read the user's note and may
not write it; everything else on the MCP surface is read-only.

Done:

- [x] `Notes` store: list, find, create, replace with an optional
      compare-and-swap, delete, and the one-time move out of the old
      per-recording layout (35 notes moved on the real library).
- [x] `listen notes list|read|write|delete`, with a repeatable `--recording`.
- [x] `list_notes`, `read_note`, `write_note`, `edit_note`, `delete_note` over
      MCP, plus note slugs on `get_recording`. `edit_note` and `delete_note`
      refuse a `source: you` note.
- [x] `.claude/skills/listen-library` and `.claude/skills/listen-note`.
- [x] Transcript/Notes toggle and the artifact switcher in `DetailView`, with
      `MarkdownText` rendering headings, lists, tables and inline emphasis.
- [x] Recordings / People / Notes segmented control in the sidebar; People
      removed from the toolbar.
- [x] The extractive outline: built, measured, and deleted before commit. 33
      outline notes removed. See `CLAUDE.md` for why.

Left:

- [ ] **A note is read-only in the Notes collection**, including the user's own.
      It is edited on the recording, and the sources are buttons that go there.
      Worth revisiting if that reads as broken rather than as deliberate.
- [ ] **Export does not include notes.** `LibraryWindow.exportSelected` and
      `listen export` both write the transcript only.
- [ ] **No note-level verbs in the toolbar** in the Notes collection. Deleting a
      note is CLI or Finder only.
- [ ] Local generation stays deferred. Measured at 5.9 GB and about 63 s per
      meeting for a two-pass 9B model, against a cloud call at a fifth of a
      cent. See `listen-notes-spike/` if it is ever revived.

## Blocking decisions

### Word-level timestamps (SPEC 10.1)

mlx-audio computes sub-word token timings and throws them away at the public
API boundary. `NemoAlignedResult.segments` projects each sentence to
`text`/`start`/`end`; `decodeChunk` is private; all three public entry points
return `STTOutput`. Confirmed against upstream `main`.

Consequence: speaker assignment is per sentence, so two people talking over
each other inside one sentence come out as one speaker. `Merge.assign` already
contains the word-level branch in full, so the day the timings are exposed it
starts running with no other change.

**Recommendation:** patch mlx-audio to add a `"tokens"` key to the existing
`[[String: Any]]` segment dictionaries. Purely additive, cannot break any
consumer, makes a clean upstream PR. Needs a decision on forking versus waiting
on upstream.

## Before 0.34.0 ships

Two apps, one release. What went in: **the voice bank reaches the iPhone**. It
holds the Macs' voiceprints, names the speakers in a recording it made without
waiting for a Mac, sends what it hears back, and lets a person say who somebody
is in a way that survives the Mac's own pass over the same audio. The
measurements are in `.agents/notes/speakers.md` and the sync rules in
`.agents/notes/cloud-sync.md`. This is only what is left.

**Nothing to deploy to CloudKit.** No record type, no field: `z2` and `r6`
already existed and the phone joined them. `DEPLOY-SCHEMA.md` is untouched.

### Blocking

- [ ] **A real pair of devices, on the real Apple Account.** Everything so far
      is the Simulator against a scratch container. The recipe is in
      `listen-ios/RUNNING.md` under *Watching the voice bank move between two
      real devices*; `LISTEN_DEBUG=1` prints `voice bank down:` and `voice bank
      up:` per pass. Two things to watch separately: `embeddings.json` arriving
      beside recordings the phone never made, and the phone's own bank turning
      up in a Mac's folder while that recording is still `pending`.
- [ ] **Name somebody on the phone, then let the Mac transcribe it.** The one
      path with no end-to-end coverage: `Pipeline.adoptNames` is unit-tested
      through `VoiceBankCore.adopt` and has never run against a real ingest.
      What should happen is the transcript comes back with the name on it and
      `LISTEN_DEBUG=1` logs `adopted 1 name(s) applied on another device`.
- [ ] **The naming sheet by tapping it.** Verified through the `LISTEN_NAME`
      launch hook, which proves the sheet and not the route to it. The
      Simulator's accessibility grant for `osascript` dropped out mid-session;
      see *Tapping the Simulator* in `listen-ios/RUNNING.md`.
- [ ] Write the `## 0.34.0` changelog section, bump `VERSION`,
      `./release.sh --publish`, dispatch the homebrew workflow. For the phone,
      bump the version and run `tools/release_testflight.sh`.

### Decided, with the argument written down

- **The bank travels both ways, and precedence settles the race.** The first cut
      made the phone read-only against `z2`; that threw away the window where
      its bank is the only one that exists. `CloudSyncCore.speaksFor` is the
      tie-break and is used on both sides of a pass on purpose.
- **A person's word outranks every machine pass**, including a Mac's, which is
      the third clause of `speaksFor` and the whole reason naming on the phone
      is worth anything.
- **`Recognise voices on this iPhone` is a real switch**: off drops every bank
      and every `bank:` stamp and unsubscribes from the zone, rather than
      keeping the material and declining to read it.

### Wanted next, not blocking

- **`listen calibrate` no longer separates cleanly** and the phone now applies
      the same thresholds, so a wrong one is wrong on two devices. See *Known
      defects*.
- **Naming a speaker on the Mac from the phone's suggestion list.** The phone
      shows `VoiceMatch` suggestions in a sheet; the Mac's `SpeakerPicker` is
      the older interface for the same question and the two now share the
      wording but not the shape.

## Before 0.33.0 ships

Two apps, one release. What went in: an engine seam so a meeting can be read by
Apple's `SpeechTranscriber` as well as by Parakeet, a languages question that
keeps its answer, and an iPhone that transcribes and diarizes its own
recordings. Every measurement behind them is in `.agents/notes/asr.md`,
`.agents/notes/speakers.md` and `listen-ios/spec/02-capture-and-transfer.md`.
This is only what is left.

### Blocking

- [ ] **A 60-minute capture on a phone Xcode is not holding.** Every capture
      test so far has been under the debugger, and the 5 September loss was
      DTServiceHub's RunningBoard assertion dropping and launchd sending signal
      9. Launch from the Home screen, lock the phone, leave it an hour. This is
      the test that decides whether the 26 August case (34 minutes recorded,
      14:17 kept, no debugger) is a real defect or the same artifact.
- [ ] **Re-test the three iPhone fixes on the device**: an interrupted capture
      appears by itself, playback is audible, a two-person memo splits into A
      and B with a one-word interjection on the right person.
- [ ] **The Mac verify suite**, which has only been run in part:
      `verify_language.sh` and `sync --fake` pass. `verify_onboarding.sh` is the
      one that matters most, because setup's model step was rewritten.
- [ ] Merge both branches to main, write the `## 0.33.0` changelog section, bump
      `VERSION`, `./release.sh --publish`, dispatch the homebrew workflow. For
      the phone, bump the version and build and run
      `tools/release_testflight.sh`.

### Shipping known, each with a measurement behind it

- **Apple's engine is not selectable in the Mac UI**, only `--model apple` and
  `LISTEN_ENGINE=apple`. It finds 71 of the 94 domain proper nouns v2 finds over
  12.9 hours of this library, so it should not be the default, and a control
  offering it needs a sentence saying that.
- **The phone's diarizer misses short interjections.** A 45-second memo split
  into A and B correctly; a 5-minute one where the second person only
  interjects came back as one speaker, at three thresholds, amplified, and with
  the speaker count forced to two.
- **Phone captures are about 13 dB quieter** than the ones this library was
  built on: peak -19.7 dBFS against -8 to 0. `.measurement` mode is doing
  exactly what it promises. Whether that costs speaker separation is untested
  and is the obvious next experiment.

### Decided, not done

- **Voiceprints on the phone.** Now possible: the objection in `DevicePolicy`
  was that the phone had nothing that reads one, and since it diarizes that is
  no longer true. The bank is 864 KB across 68 recordings, and `VoiceBank`'s
  thresholds are already measured and portable. The design that avoids the
  reversal that comment feared is **down-sync only**: the bank reaches the
  phone, the phone's own embeddings never leave it, because the Mac re-diarizes
  the audio anyway. What it costs is biometric material on a second device,
  which wants a switch and a line in the privacy copy rather than a silent
  default. Not before the interjection problem is understood: a name on a wrong
  letter is worse than a letter.

## Known defects

### The voice bank's thresholds were measured on five people and there are 23

`listen calibrate`, 6 September 2026, on the real library: 102 named
voiceprints across 23 people, 1110 same-person and 4005 different-person
cross-recording pairs.

    same person       min +0.077  median +0.732  max +0.968
    different people  min -0.243  median +0.072  max +0.942

The distributions **overlap by +0.866**, and the best separating threshold is
+0.361 against a shipped `matchThreshold` of +0.47. The numbers in
`VoiceBankCore` come from five people, where the gap was clean at +0.297 and no
different-person pair passed +0.371. That file says to re-run `calibrate` as the
library grows, and predicts exactly this: "the different-person maximum is the
number most likely to rise."

**Two prints are doing most of the damage, and they are findable.** Scoring
every human-named print against the centroid of that person's *other* prints,
86 prints, 16 disagree, and 14 of those are people the bank has heard exactly
once, so there is nothing to compare them against and the nearest stranger sits
at +0.27 to +0.46, below `matchThreshold`. They are not mislabels. Two are:

    2026-08-07-160656-EBA9   709 s filed as `Me`   +0.382 vs Me,  +0.756 vs Nick
                             transcript says B, C, Nick. There is no `Me` in it.
    2026-08-26-140435-53C7   744 s filed as `Me`   +0.685 vs Me,  +0.751 vs Nick
                             transcript says Me and Nick, so a merge is as
                             likely as a mislabel.

**They are merged prints, not mislabels, and they are historical.** Both are
from a pipeline that no longer runs. Re-transcribing 53C7 with today's build
splits the single 744-second `Me` into two clean clusters:

    before   Me 744s              +0.685 vs Me, +0.751 vs Nick
    after    A 404s   Nick +0.882 (then Me   +0.367)
             B 331s   Me   +0.849 (then Nick +0.328)

A correctly detected room takes the room path, which writes one print per voice
and no `Me` at all: `printUser` is never reached. Confirmed a second time on a
37-second two-person room, whose bank came back `A` and `B` with the same speech
seconds as the named prints beside it. **So there is nothing to fix in the code**
and a guard added here on 6 September was reverted for that reason: it sat on a
path a room never takes.

### Update, 6 September 2026: the re-transcribe happened and left the keys wrong

53C7 has since been re-transcribed and split exactly as predicted above, but the
two clean clusters were filed under the wrong names. Re-measured over all 81
named prints:

    2026-08-07-160656-EBA9   Me 329s  +0.410 vs Me,  +0.889 vs Nick
                             transcript B, C, Nick. `Me` is Nick's cluster.
    2026-08-26-140435-53C7   Me 404s  +0.364 vs Me,  +0.880 vs Nick
                             B  331s  +0.309 vs Nick, +0.849 vs Me
                             transcript Nick and Me, so the two are swapped.

So the transcripts are right and the bank keys are wrong, which is a smaller
problem than the merge was and a different shape from it. **Re-transcribing
again is not the repair** and would only re-roll the same dice; the trap in
`listen-ios`'s handover about re-transcribing two recordings in sequence still
stands.

Both are now findable by `listen voices --repair`, which grew two things:

1. **`Me` is an orphan like any other key.** The exclusion was there because
   `printUser` writes a `Me` print whether or not a `Me` ends up in the
   transcript, so the shape looked routine. Measured: 2 recordings of 76 have
   that shape, one is EBA9 and the other proposes no repair anyway, so the
   exclusion was costing the whole class it was written to catch and buying
   nothing. A `Me` key now only ever moves on a score, never on shape alone.
2. **`VoiceBank.misfiled`, for the swap the orphan search structurally cannot
   see.** The orphan search pairs a key no transcript uses with a name no key
   holds, so it needs a gap to aim at; a swap has no gap. Gated on both
   thresholds, skips a print that already matches its own label, drops the
   recording unless the moves form a permutation, and orders them so each
   target is free when its turn comes.

EBA9 is repaired. The remaining three are previewed and **not yet applied**:

    2026-09-01-150027-C0DE   A  -> Charlie  0.776
    2026-08-26-140435-53C7   Me -> Nick     0.893   (then B -> Me, 0.846)
    2026-08-18-170206-0912   A  -> Eduard   0.830

    listen voices --repair --apply

Then, and only then, re-derive the thresholds, remembering that `autoAssign`
scores against a *centroid* with a margin gate while `calibrate` reports
pairwise numbers, so the figures above are the pessimistic view of what the
gates actually see.

It matters more than it did: the iPhone applies the same thresholds through the
shared `VoiceBankCore`. `listen-ios/tools/voices_e2e.sh` prints the separation it
gets on real voices per run, which is the cheapest way to watch this move.


- **One word corrupted per ASR chunk seam.** Measured: none whole-file, one at
  120 s chunks, two at 60 s. At the shipped 600 s that is about six per hour.
  The fix is to cut chunks at silence so no word straddles a boundary;
  mlx-audio ships `MLXAudioVAD`, so the parts exist.
- **`listen record --stop` is not implemented.** Stopping a capture running
  inside the app from a second process needs IPC. It fails with a message
  saying so rather than silently doing nothing.

## Not yet verified

- **Onboarding on a clean account.** Narrowed, not closed, by a run on a second
  Mac that had never seen Listen. Downloaded through Chrome, so quarantine was
  really set (`0381;…;Chrome;…`) and Gatekeeper really was consulted: the DMG
  opened with **no dialog**, the app launched with none either, the designated
  requirement came back anchored on `subject.OU = BUZ45YDWYN` with no `cdhash`,
  and `transcribe` returned the sentence verbatim.
  What that run did not cover is most of what SPEC 7 asks for. The model was
  already in `~/.cache/huggingface` on that machine, so the 2.5 GB first-run
  download is still unexercised, and the app was driven from the command line,
  so onboarding and both permission prompts have still never run anywhere that
  had not already granted them.
- **Process tap over a real hour** (SPEC 10.3). Tested to 90 seconds with no
  leaks. Sleep, display change, device unplug and a call switching from Meet to
  a phone call are all untested.
- **v3 versus v2 on meeting audio** (SPEC 10.4). v3's language misdetection is
  a short-clip problem and meetings are not short, so v3 may behave far better
  here than in Speak. Unmeasured.
- **Whether the Whisper-era cleanup is needed at all** (SPEC 4.4 step 4). It
  has fired *never* so far. Counters are in place; delete it and say so once
  there is real meeting audio behind the number.
- ~~A Sparkle update installing.~~ **Done, on a second Mac, 0.1.1 at build 49
  to 0.2.0 at 55.** Offered against the installed version, release notes
  rendered in the pane rather than the blank box 0.1.0 shipped, and Install
  and Relaunch came back reporting 0.2.0/55.
  The install is the half that counts. Fetching and parsing the appcast only
  proves the feed is reachable; Sparkle checks the EdDSA signature on the
  downloaded archive afterwards, so a feed signed with Speak's key would have
  offered the update exactly like this one and failed at that step. It did not.
  This was the last thing here that could not have been fixed afterwards: every
  installed copy only accepts what the key it shipped with signs, so a broken
  channel would have meant reaching every user by hand.

## UI feedback, round one

- [x] Sidebar snapping back when dragged. Was a bare `NSSplitView` with width
      constraints fighting it; now `NSSplitViewController` with min/max
      thickness, and the sidebar holds a higher priority than the detail pane
      so window resizes move the other edge. Verified: a width of 380 survives
      a relaunch.
- [x] Filter tabs dropped. An unnamed speaker reads as "Speaker A".
- [x] Recording title editable in place, and on double-click in the list.
- [x] Actions menu: export, transcribe again, rename, show in Finder, delete.
      In the toolbar and on right-click, both driven by the same builder.
- [x] Sidebar collapses, from the toolbar or Cmd-Ctrl-S.
- [x] New recording from the toolbar and Cmd-N.
- [x] App icon.
- [x] A main menu, which the app had none of. Found while testing renaming:
      without one, Cmd-C and Cmd-V do nothing in any text field and Cmd-Q does
      not quit.

Still worth doing on the list:

- [ ] The list groups by day but shows no relative heading beyond a week
      ("3 February" rather than "February"). Fine for now, worth revisiting
      with a real library in it.
- [ ] No empty state when the library has nothing in it at all. **Seen for real
      now**, on a second Mac with no recordings on it, and it is worse than this
      line suggests: the pane is a plain void beside a sidebar holding only New
      Recording and Settings. It is also the first thing every new user sees,
      which makes it the highest-value item on this list rather than the last.

## Legacy import

`listen import <path>` brings in a `meet_transcriptions` library: 45
recordings, 22 with transcripts, and the speaker naming that was done by hand.
`listen enroll` then re-derives FluidAudio voiceprints from the imported audio
and attaches the imported names to them.

The pyannote vectors are deliberately left behind. They are the same 256
dimensions as FluidAudio's and a completely different space, so importing them
would have produced confident nonsense in the sounds-like ranking with nothing
to catch it.

Done. The whole library is transcribed: **39 recordings with speech, 7 with
none, 0 pending, 51 voiceprints across the bank.** Thresholds re-measured on
real voices at 0.47 and 0.57.

- [ ] Imported titles are verbatim, so several read "Google Chrome" or
      "2607-13-WhatsApp". Renaming is a click but nothing suggests a better one.
- [ ] 12 imported recordings still have unnamed speakers (A, B). They have
      voiceprints, so naming one is now a rename rather than another pass over
      the audio, and the bank should suggest who they are.
- [ ] Re-run `listen calibrate` as more people are named. Five people is enough
      to separate cleanly and not enough to have met a confusable pair, so the
      different-person maximum is the number most likely to rise.

## Later

- Waveform in the player, if it can be made cheap.
- Meeting detection has never been seen firing on a real call. Both Core Audio
  flags were verified separately (`out` while playing, `in` while recording),
  but no single process was observed running both, so the positive path is
  reasoned rather than measured. Run `listen sources` during the next real
  meeting; it prints every audio process, both flags, and what the rule makes
  of them.
- Mixdown is generated on first playback and can take a moment on a long
  meeting; no progress is shown while it does.

## Audio on every device, and who is transcribing

Asked for on 18 Aug 2026: every device keeps a playable, re-transcribable copy
of the audio; the iPhone plays it in the recording detail screen; a Mac that is
transcribing says so to the others so nobody does it twice; the screen names
that Mac and says when it started, finished and how long it ran; a per-device
switch keeps or frees the audio, and the devices tell each other so the library
can warn when **no** device is keeping it.

Decided, with the measurements that decided it:

- **FLAC, stereo, mic left and system right, one file per recording.** On this
  library, 24.4 h in 40 recordings: raw Float32 tracks 500 MB/h and 12.2 GB;
  FLAC stereo Int16 68 MB/h and 1.7 GB, lossless; AAC stereo 43 MB/h and 1.0 GB
  at 98.9% word agreement, against a model whose own run-to-run variance
  measured 0.0%. Lossless, because a device that frees its raw tracks has to be
  giving up nothing or "keep audio" is a quality decision in disguise.
- **A mono mixdown is not a candidate**, whatever it costs: `Mixdown` sums the
  tracks and the pipeline transcribes them separately on purpose.
- **No Production schema change.** The master rides `asset_mic_wav` on `r5`,
  the lease rides `claimedBy` and `claimExpires` on `r1` (deployed, and written
  by nothing before this), and provenance and per-device settings ride sealed
  payloads. Production schema is append-only for ever, so this is worth keeping
  true as the rest lands.
- **Free the local copy only when another device reports holding it**, not when
  the container has it. iCloud is a replica, and `Backups` exists because of it.

All six steps are in. 50 seams pass, twice against the same directory, and
both apps build.

- [x] **The durable master.** `z5` rather than `z4`, which is the one thing
      here that departs from the plan above and the reason is measured:
      `ingest` lists `z4` whole on every pass with no change token, on purpose,
      and a listing fetches assets, so masters in there would have every Mac
      downloading 1.7 GB every two minutes. The permanent half of the
      constraint is kept: still `r5`, still `asset_mic_wav`. A zone is created
      at runtime and is not schema. Pushed only by a device holding the raw
      tracks, three a pass; fetched by name, never listed, never subscribed to.
      `ingest` is untouched. The master is deleted locally once it lands: the
      device that published it holds the raw tracks, which are the better copy,
      and keeping both would add 1.5 GB to the one machine that never needs it.
- [x] **`keepsAudio` and `holdsAudio` on `DeviceBlob`**, both optional so an
      older device record still decodes, computed in `heartbeat` from the disk
      rather than taken from the caller.
- [x] **The reclaim rule.** Another live device that is *keeping* audio has to
      report holding it, and nothing here still owes work on it. `audioOn`
      decides no deletion any more.
- [x] **The lease in `Queue`.** Taken before anything is written, renewed every
      five minutes against a fifteen minute window, released on success and on
      failure. A recording another device holds is remembered with its expiry
      so `resume` stops asking. The four provenance fields are written at the
      start of the run rather than the end.
- [x] **Mac UI.** The transcribing-on line names the device and says when it
      started; the finished-in line is a subtitle fact, shown only on a library
      with more than one device in it. Keep audio is in Settings › Devices,
      beside a roster that says what each device keeps and holds, with the
      count of recordings nothing reports keeping. Playback falls back to the
      master.
- [x] **iOS.** `RecordingPlayer` and a transport in the detail screen, the same
      two lines, and the switch wired to the new policy with its copy corrected.

`listen audio [<id>] [--build]` is new, for the same reason `sync inspect` is:
this subsystem's whole state is files that are not there. `--build` is also how
the encoder was measured on real meetings.

### Measured, on a real 1.07 hour meeting

    tracks   494.4 MB   Float32, 461 MB/h
    master    61.0 MB   12% of the tracks, 57 MB/h, built in 3.8 s

Building is an order of magnitude cheaper than budgeted. Memory is not: both
tracks are read whole, about a gigabyte resident at the peak, which is why
`pushMasters` does three a pass. The encoder pads its final packet, so a master
is up to 4608 frames (32 ms of silence) longer than its tracks; nothing is lost
and nothing shifts.

### Closed since, and how

- **The offline lease window is measured.** `takeTranscriptionLease` answers
  three ways now rather than two: `.taken`, `.held(lease)`, and `.unreachable`,
  which is a yes with the caveat that nothing could refuse. `state:
  transcribing` used to be described as travelling in the metadata and
  **nothing read it**, so a Mac that could not reach the container started
  every job it had. `CloudSyncCore.othersRunLooksLive` is that sentence asked:
  another device's unfinished run, with a start time inside six hours, is a
  reason to leave the recording alone. Six hours is `claimGrace`'s number and
  its argument. Seven seams, against a store that throws on everything.
- **`listen transcribe <id>` takes the same lease** and writes the same four
  provenance fields, through `markTranscribeStarted` and
  `markTranscribeFinished` shared with `Queue`. It was a second way into the
  pipeline with neither, so a Mac running it while the other Mac's queue was on
  the same recording was the race the lease exists to stop.
- **The provenance line is on screen**, and it changed shape on the way. It was
  hidden unless the library had more than one device in it, on the grounds that
  naming a machine is noise on a single Mac. The naming is; the hour it took is
  not. So the duration shows everywhere and the machine is named only when it
  is not this one: `8 Aug 2026 at 08:27 · 0:36 · Parakeet v2 · transcribed in
  1 s`, photographed on a scratch library holding one real 36 second recording.
- **A device can be given one recording's audio.** `SyncState` gained `pin:`,
  `reclaim` leaves a pinned recording alone, and `fetchMaster` and `freeMaster`
  are the pair behind **Download the audio** in the iOS detail screen and
  **Download the Audio** in the Mac's actions menu. The device switch stays a
  policy and this is an instruction: **Keep audio on this iPhone** still means
  "keep what I recorded" and still never downloads the Macs' meetings.
  `freeMaster` refuses when nothing else reports holding the bytes, because
  wanting the space back is not wanting to lose the recording.
- **An import gets a master.** `AudioMaster.Layout` is `tracks` or `everyone`,
  the name on disk carries it (`master.flac` against `master-everyone.flac`),
  and the mixdown is decoded through `AVAssetReader` so a 44.1 kHz stereo m4a
  does not come back three times too slow. It matters which: an `everyone`
  master written back as `mic.wav` is an imported meeting transcribed as the
  user's own voice, with every speaker in it labelled `Me`.

56 seams, three times against the same directory. On the real container: 40 of
40 masters published, `z4` empty throughout, this Mac reporting `keeps audio,
holds 40`, and the pass settling to `Up to date`.

### Still open

- **The other two devices are on the old build.** They publish no `holdsAudio`,
  so they authorise no deletion anywhere, which is the safe direction and also
  means nothing is freed until they are updated.
- **Nothing has pulled a master on a real second device yet.** The push half is
  proven against the live container; the pull half is proven against the fake,
  plus a by-name fetch through `sync inspect --recording` which does open and
  verify a real blob.