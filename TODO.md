# Listen: state of play

Where the project is, what is left, and what needs a decision. Update this in
the same commit as the work it describes.

Last updated: notes built end to end, outline removed, sidebar navigation in.
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

Done: `AudioMaster` (build, split, both traps), the transcription lease and its
four seams, `Metadata.transcribed_by` / `transcribed_on` / `transcribe_started`
/ `transcribe_finished`.

Left, roughly in dependency order:

1. A durable master record in `z4`, pushed by any device holding audio and
   pulled by any device that wants it. `ingest` keeps the raw pipe it has, so
   the first transcription still reads the untouched tracks.
2. `keepsAudio` and `holdsAudio` on `DeviceBlob`, which is sealed and needs no
   schema, carried by the heartbeat that already runs every pass.
3. The reclaim rule above, replacing "a Mac said `audioOn`".
4. `Queue` taking, renewing and releasing the lease, and skipping a recording
   another live device holds. Renewal matters: a long meeting outlives any
   window short enough to be useful after a crash.
5. Mac: the transcribing-on and finished-in lines, the keep-audio switch, the
   device roster, and the warning when nothing is keeping a recording.
6. iOS: playback in the detail screen (there is none today, no `AVAudioPlayer`
   anywhere), the existing **Keep audio on this iPhone** switch wired to the
   new policy, and the same two lines.

One thing to decide when 4 lands: `takeTranscriptionLease` returns true when
the container is unreachable, so an offline Mac still transcribes its own
recording. `state: transcribing` travelling in the metadata is the only
deterrent in that window, and whether that is enough has not been measured.
