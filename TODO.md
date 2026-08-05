# Listen: state of play

Where the project is, what is left, and what needs a decision. Update this in
the same commit as the work it describes.

Last updated: Sparkle keypair generated and the update channel wired end to end.

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
| 7 | Settings, onboarding, permissions | done, never tested on a clean account |
| 8 | CLI install, MCP | done |
| 9 | Release pipeline | built and keyed, nothing published |

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

- **First run on a clean account.** Onboarding, both permission prompts and the
  model download have never been exercised on a machine that has not run
  Listen. SPEC 7 asks for exactly this.
- **Process tap over a real hour** (SPEC 10.3). Tested to 90 seconds with no
  leaks. Sleep, display change, device unplug and a call switching from Meet to
  a phone call are all untested.
- **v3 versus v2 on meeting audio** (SPEC 10.4). v3's language misdetection is
  a short-clip problem and meetings are not short, so v3 may behave far better
  here than in Speak. Unmeasured.
- **Whether the Whisper-era cleanup is needed at all** (SPEC 4.4 step 4). It
  has fired *never* so far. Counters are in place; delete it and say so once
  there is real meeting audio behind the number.
- **A Sparkle update installing.** The keypair exists and the feed is signed
  and verified against it (`sign_update --verify --account listen`), but no
  build has ever updated to another build. That needs two published releases,
  so it cannot be checked until after the first one.

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
- [ ] No empty state when the library has nothing in it at all.

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
