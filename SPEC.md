# Listen: build spec

Build a macOS app called **Listen**: a fully local meeting recorder, transcriber
and speaker-labeller. It replaces a stack of three tools the author currently
runs by hand (a Chrome extension recorder, the Blackbox recorder app, and a
Python transcription CLI with a browser dashboard) with one native app.

This document is the brief. Read every referenced repository before writing
code. Most of the hard decisions here were already made and validated somewhere
else, and the value of this project is in the assembly, not in re-deriving them.

---

## 1. Reference material

Read these first. They are on this machine unless marked otherwise.

| Path / URL | What to take from it |
|---|---|
| `/Users/mgo/Documents/coding/macos-apps/speak` | **The template.** Same author, same platform, shipping. Copy its build system, release pipeline, settings architecture, onboarding, and its MLX Parakeet integration. Read `CLAUDE.md` end to end before anything else: it is a list of traps already paid for. |
| `/Users/mgo/Documents/coding/chrome-extensions/meet_transcriptions` | **The logic being ported.** A working Python pipeline: `transcribe_call.py` (word-to-speaker assignment, transcript cleanup), `voiceprints.py` (cross-recording speaker recognition, with calibrated thresholds), `dashboard.py` + `dashboard.html` (the labelling UI this app replaces), `enroll_voiceprints.py` (backfill and calibration). |
| `https://github.com/fastrepl/anarlog` | **The UI and product reference.** Open source (MIT), Tauri + React. Do not port its code; match its shape. Relevant: `apps/desktop/src/settings/` (settings IA), `apps/desktop/src/settings/developers/cli.tsx` (CLI install button), `docs/reference/mcp.mdx` (MCP tool surface), `crates/local-stt-core/src/lib.rs` (on-device model catalogue). |
| Granola (granola.ai) | Product reference only, closed source. The interaction to match: no meeting bot, no calendar invite, you press record and notes appear. |
| Blackbox (macOS app) | The recorder being replaced. Match its capture reliability and its top-right floating indicator. Improve on it with the confirm step in §5.3. |

### What speak already proves

`speak` runs `mlx-community/parakeet-tdt-0.6b-v2` and `-v3` through
`mlx-audio-swift` on Apple Silicon, as a pure SwiftPM package built with
`xcodebuild`, signed, notarized, Sparkle-updated and distributed through a
Homebrew tap. That entire spine is transferable. Listen is speak with a
different front end and a longer pipeline behind it.

---

## 2. Non-negotiable constraints

1. **Apple Silicon, macOS 14+.** No Intel, no iOS. Gate anything needing macOS
   26 behind `#available` the way speak does.
2. **Fully local.** No network calls at runtime except model downloads and
   Sparkle update checks. Audio never leaves the machine. This is the product,
   not a preference.
3. **Reuse speak's model files.** See §4.1. A user with both apps installed
   must not download Parakeet twice.
4. **AppKit, not SwiftUI**, for consistency with speak and because the settings
   and list/detail patterns there are already debugged. SwiftUI is acceptable
   for isolated new views if it does not fragment the window management.
5. **No em dashes** anywhere: code, comments, docs, UI copy. Do not use the word
   "drift". Comments explain *why*, and most of them should mark a trap.
6. **Never lose a recording.** Every failure mode below must degrade to "the
   audio is still on disk" rather than "the meeting is gone".

---

## 3. Architecture

```
Listen.app
├── Capture          Core Audio process tap (system) + AVAudioEngine (mic)
├── Library          ~/Library/Application Support/Listen/recordings/<id>/
├── Pipeline         ASR (MLX Parakeet) → diarization (FluidAudio) → merge → voiceprints
├── Notes            markdown artifacts in the library, each naming one or
│                    more recordings. One per recording is the user's own.
├── UI               Apple Notes style: sidebar list + detail with player, transcript, notes
├── CLI              `listen` binary, installed on request from Settings
└── MCP              `listen mcp`, stdio, over the same library. Notes are the
                     only writable surface; everything else is read-only.
```

### 3.1 Package layout

Follow speak: one SwiftPM package, `Package.swift` at the root, sources under
`Sources/listen/`, built via `./build.sh` (an `xcodebuild` wrapper) because
`swift build` cannot compile MLX's Metal kernels and dies at runtime with
`Failed to load the default metallib`.

Split into targets only if the CLI/MCP needs to build without AppKit. Prefer a
single executable with argument-dispatched modes, as speak does with
`--transcribe` and `--polish`, because it keeps one code path over the library.

### 3.2 Dependencies

| Package | For |
|---|---|
| `Blaizzy/mlx-audio-swift` | Parakeet ASR through MLX. Same as speak. |
| `FluidInference/FluidAudio` | Speaker diarization and speaker embeddings, CoreML on the Neural Engine, Apache 2.0. |
| `huggingface/swift-huggingface` | Model download with progress. Same as speak. |
| `sparkle-project/Sparkle` | Updates. Same as speak, including the inside-out signing in §9. |
| `modelcontextprotocol/swift-sdk` | MCP server. Evaluate first; a hand-rolled stdio JSON-RPC loop is acceptable if the SDK is heavy. |

---

## 4. The pipeline

### 4.1 Model storage and reuse

Parakeet weights live in the HuggingFace hub cache, which is what makes sharing
with speak free. Resolve the cache root exactly as speak's
`ModelChoice.hubRoot` does, in this order:

1. `HF_HUB_CACHE`
2. `HF_HOME` + `/hub`
3. `~/.cache/huggingface/hub`

**This is load-bearing.** Speak shipped a bug where it measured the standard
path, reported "already downloaded", then sat on "loading model" for four
minutes while the library fetched 2.4 GB into a different cache. Anyone with
local ML tooling has `HF_HOME` set, and a Finder launch inherits no shell
environment, so it does not reproduce from the GUI. Read speak's `Config.swift`
and copy the resolution rules rather than re-inventing them.

Detect and report shared models honestly in Settings: "Parakeet v2, 2.47 GB,
already on disk (shared with Speak)".

FluidAudio's diarization and embedding models are separate CoreML bundles and
are *not* shared with speak. They are small (tens to low hundreds of MB) and
download on first use with their own consent step.

### 4.2 ASR

Parakeet v2 and v3 through `mlx-audio-swift`, selectable in Settings, v2 as the
default.

- v2: `mlx-community/parakeet-tdt-0.6b-v2`, English only, 2.47 GB, 6.05% WER on
  the Open ASR Leaderboard.
- v3: `mlx-community/parakeet-tdt-0.6b-v3`, 25 European languages, 2.51 GB,
  6.34%.

v2 is the default for the same reason it is in speak: v3 will decode short
English audio as another language and `mlx-audio`'s `language` parameter does
nothing (it is copied into `STTOutput` and never reaches the decoder). Do not
add a language picker for Parakeet; it would be a control that silently does
nothing.

Long-form meeting audio is a different regime from speak's short dictations.
Chunk with overlap, and carry timestamps through. Word-level timestamps are
required by §4.4, so verify early that the MLX path exposes them. **If it does
not, that is a blocking finding: report it before building anything on top of
it**, since the whole speaker-assignment design depends on word timings.

### 4.3 Capture, and why it makes diarization easier

Record **two separate tracks**:

- **Mic** via `AVAudioEngine`, 16 kHz mono Float32. Copy speak's `Recorder.swift`
  wholesale, including `selectDevice` and its ordering rule: build the converter
  from the format read *before* selecting the device, or audio records
  pitch-shifted and garbled. Store devices by UID, not `AudioDeviceID`.
- **System audio** via Core Audio process taps (`AudioHardwareCreateProcessTap`,
  macOS 14.2+) into an aggregate device. Read AudioTee
  (`github.com/makeusabrew/audiotee`) as a working reference. Two known traps:
  `AVAudioEngine` cannot be retargeted to a tap-backed aggregate device, so
  drive `AudioDeviceCreateIOProcIDWithBlock` on the aggregate directly; and the
  tap needs audio recording permission but **not** screen recording permission,
  which is the entire reason to prefer taps over ScreenCaptureKit.

Keeping the tracks separate is not just for mixing. The mic track is
definitionally the user and the system track is definitionally everyone else,
which hands you a perfect first-level split for free. Diarize **only the system
track**, then label the mic track as the user in one step. This removes the
single most common diarization error (confusing the user with a participant)
and roughly halves the work.

Persist both tracks. Generate a mixdown lazily for playback, the way
`meet_transcriptions` already does (see its recent commit "Generate the playback
mixdown on demand, not just at transcription time").

### 4.4 Diarization and word assignment

FluidAudio for diarization over the system track, offline mode with whole-file
context. Do not use its streaming diarizer for the stored transcript: streaming
decodes without future context and is measurably worse.

Then port the merge logic from `transcribe_call.py`, which is the part with real
accumulated value:

1. Assign each word to the overlapping speaker turn.
2. Split an ASR segment whenever the speaker changes mid-segment.
3. Relabel raw `SPEAKER_00`/`SPEAKER_01` to `A`, `B`, `C` for stable display.
4. Clean up: collapse repetition-loop artifacts, drop empty and zero-duration
   rows.

Note that step 4 exists because Whisper hallucinates repetition loops. Parakeet
largely does not, so start by porting the cleanup, then measure whether it still
fires. If it never fires on Parakeet output, delete it and say so in the commit.

### 4.5 Voiceprints

This is the feature no competitor has, and the reason to build rather than adopt
Anarlog. Port `voiceprints.py` faithfully.

- One embedding per speaker per recording, from FluidAudio's speaker embeddings.
- Stored as `<id>.embeddings.json` next to the recording. **There is no separate
  database**: the set of sidecar files *is* the voice bank, so deleting a
  recording cannot strand an entry. Preserve this property.
- Ranked suggestions in the labelling UI, never auto-applied.
- Under 15 seconds of speech: store the embedding but do not use it as evidence.

**Thresholds must be re-derived, not copied.** The existing `MATCH_THRESHOLD =
0.50` and `STRONG_THRESHOLD = 0.65` were calibrated against pyannote embeddings
on 24 voiceprints across 8 people, where same-person pairs scored at or above
0.68 and different-person pairs at or below 0.46. FluidAudio uses a different
embedding model, so those numbers mean nothing in the new space. Port
`enroll_voiceprints.py --calibrate` as a CLI subcommand (`listen calibrate`) and
run it to set the constants. Ship the measured numbers in a comment next to
them, as the Python does.

### 4.6 Auto-transcription

Transcription starts automatically when a recording stops. Queue it: run one job
at a time, because the models are GPU and ANE bound and parallel jobs fight over
the same hardware. `dashboard.py` already made this decision; keep it.

Show progress on the recording's row in the sidebar. Survive quit and relaunch:
a recording whose audio exists but whose transcript does not is simply pending,
and gets picked up on next launch. Resumability falls out of the on-disk layout
rather than needing a job database.

---

## 5. UI

Match Anarlog and Granola's visual register: light, calm, generous whitespace,
a serif or handwritten accent for headings, content-first. Look at the Anarlog
screenshots and settings layout. This should not read as a developer tool.

### 5.1 Main window

Two panes, Apple Notes style.

**Left: the recording stack.** A vertical list, newest first, each row showing
title, date, duration, and state (pending, transcribing with progress, needs
labelling, done). Filter pills across the top with counts, as `dashboard.html`
does. Search over titles and transcript text. Rename in place; `metadata.json`
already carries a `title` field in the Python version, so keep that key.

No separate People tab. The author asked for this explicitly: recordings only.

**Right: the recording detail.**

- Audio player at the top, scrubbable, with the waveform if cheap.
- Transcript below as speaker-grouped turns with timestamps. Clicking a turn
  seeks the player. The playhead highlights the current turn.
- Each speaker name is clickable. Clicking opens the labelling affordance:
  a name field, a **sounds like** row ranking this voice against everyone
  already labelled, and the rest of the roster below it. One click for a
  recurring participant.
- Two destructive per-speaker actions, both already justified by real failure
  modes in `dashboard.py`: **discard** (drops a phantom speaker's segments,
  typically hallucinated filler over silence) and **merge into** (reassigns one
  label onto another when diarization split one real person). Both write a
  one-time `.raw.json.bak` before the first edit.

Renaming a speaker writes straight to the stored transcript and re-renders. It
never re-transcribes.

### 5.2 Storage layout

`~/Library/Application Support/Listen/recordings/<id>/`, one folder per
recording:

```
metadata.json      title, recorded_at, duration, source, state
mic.wav            the user's track
system.wav         everyone else
mix.m4a            generated on demand for playback
transcript.json    segments with word timings and speaker letters
turns.json         condensed per-speaker turns, the LLM-friendly view
embeddings.json    one voiceprint per speaker
```

Keep `turns.json` and `embeddings.json` byte-compatible with the Python tools
where it costs nothing. It means `render_from_json.py` and the existing
dashboard keep working against the new app's output during the transition, which
is worth real money while porting.

### 5.3 The recording indicator, and the confirm step

A floating panel, top right, like Blackbox. Copy speak's
`RecordingIndicator.swift` as the starting point: it exists because a menu bar
item is 16 points wide on a display you may not be looking at, and on a Mac with
a notch it can be hidden entirely. Same reasoning applies here, more so, because
a meeting recording runs for an hour.

The panel shows state (recording, transcribing), elapsed time, and the confirm
control.

**Confirm semantics.** The requested behaviour is that a recording is only saved
if the user confirms it. Implement it as follows, which gives that outcome
without ever risking the audio:

1. Capture starts and writes to disk immediately on meeting detection. Never
   wait for a human to press something before recording, or the first minute is
   always lost.
2. The panel appears asking, in effect, "recording this?" with **Keep** and
   **Discard**.
3. **Keep** promotes the recording into the library and it appears in the
   sidebar. **Discard** deletes the audio.
4. If neither is pressed, the recording stays in a staging area and the question
   is asked once more when capture stops.
5. Anything still unconfirmed after 24 hours is deleted, with that stated
   plainly in Settings.

This is the "record first, decide later" pattern. If it proves fiddly, the
acceptable fallback is Blackbox's behaviour, which is to keep everything with a
Discard button, and to say so.

**Meeting detection**: watch for Zoom, Meet, Teams and Slack huddles becoming
audio-active via the process tap's process list. This is also how the tap knows
what to capture. Manual record from the menu bar must always work regardless.

### 5.4 Settings

**In the library window, not a window of its own.** Anarlog's shape: settings is
a mode of the one window, where the sidebar swaps the recording list for a list
of sections and the content side swaps the transcript for a pane. Address
sections by name through a `SettingsTab` enum, never a literal index. The enum
carried a raw `Int` while a tab view indexed by it; that index is gone.

The sections are grouped, because nine rows in one flat list is a list you read
rather than scan:

| Group | Section | Contents |
|---|---|---|
| App | General | Launch at login. |
| | Storage | Library location, disk used, retention for unconfirmed recordings, reveal in Finder. |
| | Permissions | Microphone and system audio recording, with TCC checks and deep links to System Settings. Copy speak's `Permissions.swift`. |
| Recording | Meetings | Auto-detection on/off, and the never-ask list. |
| | Audio | Input device. |
| Transcription | Models | Parakeet v2 / v3 choice, download and delete with size and shared-with-Speak status, diarization model status. |
| | Dictionary | Terms and corrections, and what they changed. |
| Advanced | Developers | CLI install, MCP configuration. See §6 and §7. |
| | About | Version, author, credits, licence, update check. |

Getting in is the toolbar's gear, Cmd-, or the menu bar item. Getting out is the
toolbar's back button or Escape, and both land back on the recording that was
selected. A pane is as wide as the window up to a 620 point cap, so a line of
text stays readable on a large display.

**The sidebar cannot be collapsed while settings is open**, because a pane with
no visible section list is a pane you cannot navigate. There are three ways to
collapse it and blocking one of them is blocking none: the toolbar item is not
in the toolbar in this mode, View > Hide Sidebar validates to disabled, and
`canCollapse` closes the divider drag and double-click. A sidebar that was
collapsed beforehand is opened on the way in and collapsed again on the way out.

Keep it small. UI copy states the trade-off rather than hiding it in a tooltip.

### 5.5 Onboarding

A stepped first-run window, ported from speak's `Onboarding.swift`. Steps:
welcome, permissions (mic, then system audio), model choice, done.

Read speak's CLAUDE.md sections on onboarding before touching this. Three rules
there are load-bearing and were each a shipped bug:

- **Setup downloads nothing on its own.** The model step selects nothing until
  the user acts, and the primary button *is* the consent: "Download Parakeet v2
  (2.47 GB)". Starting a download without a press means everyone who wanted a
  different model pays for one they were about to replace.
- **`updateControls()` must never call `render()`.** They called each other
  until the stack died, and it only reproduced on machines without a cached
  model, which is every new user.
- **Windows must float** and re-activate after each permission prompt. An
  `LSUIElement` app has no Dock icon, so a window behind a system dialog is
  unrecoverable.

---

## 6. CLI

A `listen` command, the same binary as the app, dispatched on arguments.

```
listen record [--stop]           start or stop a capture
listen list [--limit N]          recordings as a table, or --json
listen show <id>                 metadata and transcript
listen transcribe <path|id>      run the pipeline over a file, print markdown
listen export <id> [--format md|json|txt]
listen calibrate                 voiceprint threshold report (see §4.5)
listen mcp                       stdio MCP server (see §7)
```

`listen transcribe <file>` is also the debugging escape hatch, exactly as
`speak --transcribe` is: it needs no permissions and separates a model problem
from a capture problem before anyone touches UI code.

**Install button** in Settings → Developers, matching Anarlog's
`installEmbeddedCli` flow: a row showing the command name, its state (not
installed / installed / failed), and an Install button that symlinks the binary
into `/usr/local/bin` (or `~/.local/bin` when that is not writable) and reports
which. Show the resulting path. Never install silently on first launch.

---

## 7. MCP

`listen mcp` speaks MCP over stdio. Local, and it opens no port. The app does
not need to be running; the library on disk is the source of truth. Model the
surface on `docs/reference/mcp.mdx` in the Anarlog repo.

**Notes are the only writable surface.** Everything else is read-only and
idempotent. An agent may create, rewrite and delete a note artifact; it may not
rename a speaker, edit a transcript or delete a recording. The transcript is
evidence and notes are derived from it, so changing the evidence stays with a
human, in the window or at the CLI.

Tools:

| Tool | Parameters |
|---|---|
| `list_recordings` | `query`, `person`, `after`, `before`, `limit` (default 20, clamp 1..200), `offset` |
| `get_recording` | `recording_id`. Metadata, participants, speaker names, note slugs. No transcript text. |
| `get_transcript` | `recording_id`, `offset`, `limit` (default 200, clamp 1..500), returns `pagination` with `next_offset` |
| `search_transcripts` | `query`, `person`, `limit`. Full-text across the library, returns matching turns with recording IDs. |
| `list_people` | Everyone in the voice bank, with recording counts. |
| `list_notes` | `recording_id` optional. Provenance only, no bodies. |
| `read_note` | `note` (slug or title), `recording_id` optional to narrow a shared title. |
| `write_note` | `recordings` (array, at least one), `title`, `body`, `prompt`. Never overwrites; a colliding slug is numbered. |
| `edit_note` | `note`, `body`, `was`, optional `title`/`recordings`/`prompt`. `was` is required and is a compare-and-swap. |
| `delete_note` | `note`. |

`edit_note` and `delete_note` refuse a note whose `source` is `you`: an agent
reads what the user typed and never rewrites it.

Resources: `listen://recordings/{id}` as `text/markdown`, and
`listen://recordings/{id}/transcript{?offset,limit}` as `text/plain`.

Settings → Developers shows the ready-to-paste MCP client config block with a
copy button, as Anarlog's `buildMcpConfiguration` does.

Transcripts are long. Pagination is not optional, and the transcript must be a
separate call from the metadata so an agent can decide what it needs.

---

## 8. Build order

Ship each milestone working before starting the next. Milestone 2 is the
riskiest and is deliberately early.

| # | Milestone | Done when |
|---|---|---|
| 0 | Skeleton | `Package.swift`, `build.sh`, `make_app.sh`, `install.sh` copied from speak and building a signed empty app. |
| 1 | ASR CLI | `listen transcribe file.wav` prints a transcript using Parakeet from the shared HF cache. No UI. Confirms word timestamps exist. |
| 2 | Capture | Mic and system audio to two files, menu bar start/stop, indicator panel. The highest-risk piece: the process tap API is sparsely documented. |
| 3 | Diarization | FluidAudio over the system track, merged with ASR words into `transcript.json` and `turns.json`. |
| 4 | Library and UI | Sidebar list, detail view, player, transcript rendering, auto-transcribe on stop. |
| 5 | Speaker labelling | Name fields, discard, merge, writes back to stored transcript. |
| 6 | Voiceprints | Embeddings, the sounds-like ranking, `listen calibrate`, thresholds set from measurement. |
| 7 | Settings, onboarding, permissions | First run works on a clean machine. Test on an account that has never run it. |
| 8 | CLI install, MCP | Both usable from Settings → Developers. |
| 9 | Release | Signed, notarized, Sparkle appcast, Homebrew cask, docs. |

---

## 9. Release pipeline

Port from speak, which has this working: `release.sh`, `.github/workflows/`
(`build.yml`, `release.yml`, `homebrew-tap.yml`), `RELEASING.md`, `VERSION`,
`docs/` with a landing page, and the tap at
`/Users/mgo/Documents/coding/macos-apps/homebrew-tap`.

Constraints the code depends on, all from speak's CLAUDE.md:

- `VERSION` is the single source of truth for the marketing version.
  `CFBundleVersion` derives from `git rev-list --count HEAD` so it always
  increases. Sparkle compares `CFBundleVersion`, so anything that makes it go
  backwards strands every installed copy.
- **Sign with a real certificate, not ad-hoc.** Ad-hoc signing pins the
  designated requirement to a `cdhash`, so every rebuild silently invalidates
  TCC permissions while System Settings still shows the toggle on. Verify with
  `codesign -d -r- /Applications/Listen.app`, which must not contain `cdhash`.
- Hardened Runtime is required for notarization, which is why an entitlements
  file exists. Listen needs `com.apple.security.device.audio-input`, and audio
  capture entitlements for the tap.
- **Submit and wait for notarization separately**, with `--resume <id>`. Apple's
  queue has taken over an hour, and a dropped connection during
  `notarytool submit --wait` kills the run with the submission already accepted.
- **Sparkle's nested code is signed inside-out**: XPC services, then helper,
  then updater app, then framework, then the app. They must not receive the
  app's entitlements or bundle identifier. Copy the framework with `ditto`, not
  `cp -R`, or version symlinks flatten and `codesign --verify --deep --strict`
  fails.
- Losing the Sparkle private key ends the update channel for every installed
  copy. Back it up per `RELEASING.md`.

Write `README.md`, `CLAUDE.md` and `RELEASING.md` for Listen in the same voice
as speak's. `CLAUDE.md` is specifically a running list of traps found the hard
way. Start it at milestone 2 and add to it as things bite.

---

## 10. Decisions to bring back

Do not guess these silently. Investigate, then report with a recommendation.

1. **Do the MLX Parakeet bindings expose word-level timestamps?** Blocking for
   §4.4. If only segment timestamps are available, the options are per-segment
   speaker assignment (coarser, probably acceptable) or a forced-alignment pass.
2. **FluidAudio and MLX in one process.** Both want the GPU and ANE. Measure
   whether running them sequentially in one process causes memory pressure on a
   16 GB machine, since Parakeet alone is roughly 2.5 GB resident.
3. **Process tap stability over an hour.** Blackbox exists because this is
   harder than it looks. Test sleep, display change, device unplug, and a call
   that switches from Meet to a phone call.
4. **Whether v3 is worth shipping at all** given §4.2's language-detection
   problem on short audio. Meeting audio is long, so v3 may behave far better
   here than it does in speak. Measure before deciding.

---

## 11. Working agreement

- Commit at each milestone, working, with a message in the imperative voice used
  in speak's history ("wait for the microphone to go live before saying so").
- When a trap is found, add it to `CLAUDE.md` in the same turn as the fix.
- Prefer measured numbers to remembered ones. Every threshold and size in this
  document that came from a measurement says so; keep that habit.
- No test target is required, matching speak. Verification is manual through the
  CLI plus debug tracing. `LISTEN_DEBUG=1` should trace capture state changes.
