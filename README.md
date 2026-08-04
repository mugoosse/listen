# Listen

A meeting recorder, transcriber and speaker labeller for macOS that runs
entirely on your Mac.

Press record. Listen captures the call, writes it down, works out who said
what, and remembers voices between meetings so the people you talk to every
week name themselves after the first time.

No meeting bot. No calendar invite. No account. Your audio never leaves the
machine.

## What it does

- **Records both sides of a call**, on two separate tracks: your microphone,
  and everything your Mac is playing. It uses a Core Audio process tap, which
  asks for audio recording permission and **not** screen recording.
- **Transcribes locally** with NVIDIA's Parakeet through MLX. About 240 times
  faster than real time on an M4 Max, so an hour-long meeting is written up in
  well under a minute.
- **Separates the speakers** with FluidAudio on the Neural Engine, and labels
  your own track without guessing, because the microphone is definitionally
  you.
- **Recognises voices across meetings.** Name someone once and Listen suggests
  them the next time it hears them. Suggestions are ranked and never applied on
  their own.
- **Answers to an agent** over MCP, read-only, so you can ask about your own
  meetings without handing them to anyone.

## Requirements

Apple Silicon, macOS 14 or later. System audio capture needs macOS 14.2; on
14.0 and 14.1 Listen records your microphone only.

## Install

```sh
brew install --cask mugoosse/tap/listen
```

Or download the DMG from
[the latest release](https://github.com/mugoosse/listen/releases/latest).

The speech model is about 2.5 GB and downloads on first run, after you press
the button that says so. **If you already use
[Speak](https://github.com/mugoosse/speak), it is already on your disk** and
Listen will find it: both resolve the same Hugging Face cache, so whichever
downloaded first paid for both.

## Using it

Start a recording from the menu bar. When you stop, Listen asks whether to keep
it.

That question comes afterwards on purpose. Recording begins the moment you
press Start and writes to disk immediately, so nothing waits on a decision:
a recorder that starts when you confirm has already lost the minute where
everybody says who they are. If you walk away without answering, the audio sits
in a staging folder and is deleted after 24 hours.

Transcription starts on its own once a recording is kept, one job at a time.
Quit halfway through and it picks up where it left off, because a recording
with audio and no transcript simply *is* one that still needs transcribing.

### Naming speakers

Click a speaker's name in the transcript. Type a name, or take one of the
suggestions ranked by voice. Two repairs are there because diarization gets
these two things wrong often enough to need them:

- **Discard** drops a phantom speaker, the one that appears over a stretch of
  silence with a line of invented filler attached.
- **Merge into** reassigns one label onto another, for when one real person got
  split in two by changing seat or microphone.

Both write a one-time backup of the pipeline's own output before the first
edit. Renaming never re-transcribes.

## The command line

Install it from Settings, Developers. It is the same binary as the app,
symlinked rather than copied, so it never falls behind the app it came from.

```
listen transcribe <file|id>       transcribe a file, or a whole recording
listen record [--seconds N]       capture until stopped, or for N seconds
listen list [--limit N] [--json]  recordings as a table
listen show <id>                  metadata and transcript
listen export <id> [--format]     write a transcript out
listen label <id> <speaker> ...   name, merge or discard a speaker
listen calibrate                  voiceprint threshold report
listen mcp                        stdio MCP server, read-only
```

`listen transcribe some.wav` needs no permissions at all, which makes it the
fastest way to tell a model problem apart from a recording problem.

## MCP

```json
{
  "mcpServers": {
    "listen": {
      "command": "/usr/local/bin/listen",
      "args": ["mcp"]
    }
  }
}
```

Settings, Developers has this ready to copy with the right path filled in.

Read-only, opens no port, and the app does not need to be running: the library
on disk is the source of truth. Five tools: `list_recordings`,
`get_recording`, `get_transcript`, `search_transcripts`, `list_people`.
Transcripts are paginated, and the transcript is a separate call from the
metadata so an agent can decide what it needs before asking for all of it.

## Where things are kept

`~/Library/Application Support/Listen/recordings/<id>/`

```
metadata.json      title, recorded_at, duration, source, state
mic.wav            your track
system.wav         everyone else
mix.m4a            generated on demand for playback
transcript.json    segments with speakers
turns.json         condensed per-speaker turns
embeddings.json    one voiceprint per speaker
```

One folder per recording, and no database anywhere. The folders *are* the
library and the `embeddings.json` files *are* the voice bank, which means
deleting a recording in Finder is a supported operation rather than a way to
corrupt an index.

## What leaves your Mac

Two things, both declared in `InternetAccessPolicy.plist` for firewall tools
like Little Snitch:

- **huggingface.co**, once, to download the speech model.
- **github.com**, every two days, to check for an update.

That is all. Audio, transcripts and voiceprints are never uploaded, and there
is no telemetry.

## Building it

```sh
./build.sh      # xcodebuild wrapper
./make_app.sh   # wraps the binary in a signed .app
./install.sh    # both, then installs to /Applications
```

`swift build` produces a binary that dies at runtime with "Failed to load the
default metallib", because SwiftPM never compiles MLX's Metal kernels. Use the
scripts. `CLAUDE.md` has the rest of the traps.

## Credits

Parakeet by NVIDIA, run through [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)
and [MLX](https://github.com/ml-explore/mlx-swift). Diarization and speaker
embeddings by [FluidAudio](https://github.com/FluidInference/FluidAudio).
Updates by [Sparkle](https://sparkle-project.org). The process tap approach
follows [AudioTee](https://github.com/makeusabrew/audiotee).

## Licence

MIT.
