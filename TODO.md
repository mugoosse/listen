# Listen: state of play

Where the project is, what is left, and what needs a decision. Update this in
the same commit as the work it describes.

Last updated: audio on every device, and who is transcribing, all six steps in.
All unreleased; 0.2.0 is the last thing published.

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

## Known defects

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