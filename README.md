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
- **Reads your calendar, with no account to make.** A recording is named after
  the meeting it lines up with, and the people who were invited are offered when
  you name a speaker. Google and Microsoft calendars come through whatever you
  have already added in System Settings, so there is no sign-in, no
  subscription and no server in the middle.
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
[Speak](https://mugoosse.github.io/speak/), it is already on your disk** and
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

### Playing a recording back

The player above the transcript draws the whole meeting as a waveform, so the
quiet stretches and the busy ones are visible before you click. Click or drag
anywhere on it to move the playhead; scrubbing a paused recording leaves it
paused, because dragging through a meeting to find a moment is a way of reading
it rather than of listening to it.

While it plays, the turn being spoken is tinted and the sentence being spoken
is highlighted inside it, which is what keeps a five-minute paragraph readable
at the speed it is being said. The transcript follows along until you scroll,
and then it stays where you put it.

Clicking any turn plays from there.

### Naming speakers

Click a speaker's name in the transcript. Type a name, take one of the
suggestions ranked by voice, or take somebody off the invitation if this meeting
was in your calendar. Two repairs are there because diarization gets these two
things wrong often enough to need them:

- **Discard** drops a phantom speaker, the one that appears over a stretch of
  silence with a line of invented filler attached.
- **Merge into** reassigns one label onto another, for when one real person got
  split in two by changing seat or microphone.

Both write a one-time backup of the pipeline's own output before the first
edit. Renaming never re-transcribes.

### Correcting the transcript

Right-click the sentence that came out wrong and choose **Edit Sentence**. The
paragraph splits around it, you type, and clicking away saves. Escape leaves it
as it was.

One sentence at a time, because that is the unit the transcript is actually made
of: the correction goes back to the sentence the model produced, so its place on
the clock and its highlight while the recording plays both survive. The
surrounding paragraph stays on screen, dimmed, so you can see what you are
correcting it against.

Nothing re-transcribes, and the one-time backup of the model's own output is the
same one speaker edits write.

### Your own vocabulary

Settings, Dictionary. Speech models get the same proper nouns wrong the same
way every time, and a meeting is mostly proper nouns, so the list is worth
building once.

- A **term** is a word Listen should know: a name, a product, a piece of jargon.
  Anything that sounds like one and is not a word in its own right becomes it,
  so "Gusens" comes out as "Goossens". A single word needs five letters and is
  never swapped for a real English word, which is what keeps "Codex" from
  rewriting "codes". A phrase needs every word to match by sound in order, which
  is how "Claude Code" catches "Cloud coat".
- A **correction** is an exact replacement, for a mishearing that sounds nothing
  like the word you meant. The longest match wins, so a rule for a full name
  beats one for the first name.

It is applied once, when a meeting is transcribed, to what is written to the
library. Adding a rule does not touch transcripts you already have, and
re-transcribing applies the list as it stands then.

Because it edits an archive rather than something you are watching, every
transcript records which rules rewrote it and how often, and the pane totals
that across the library under **What it changed**. **Try it** runs your rules
over a line you type, which is the way to find out what a term does before it
does it to a meeting.

If you use [Speak](https://mugoosse.github.io/speak/), it keeps its own list and
one press copies it over. The file is not shared, deliberately: two apps
rewriting one document whole means the loser of a race loses entries. Export
writes the file Speak's own import reads, so the list travels back the other way
too, and imports from TypeWhisper are understood as well.

### Your calendar

Settings, Permissions, Calendar. Listen reads the calendars this Mac already
has, which includes any Google or Microsoft account you have added under System
Settings, Internet Accounts. **There is no account to make and nothing to sign
in to**, because macOS has already done that part. It only reads, and never
writes anything back.

Two things come of it. A recording is named after the meeting whose start is
within ten minutes of it, and the people on the invitation are offered when you
name a speaker.

Ten minutes is measured rather than picked. Across a real library of 47
recordings, ten, fifteen and twenty minutes all matched the same fourteen, and
widening to thirty added two matches that were both wrong: a call matched a solo
calendar block half an hour away. A name you typed yourself is never replaced.

Calendars mostly give you an email address rather than a name, so Listen keeps
its own small address book: when you take a suggestion, that address is filed
against the name you chose, and it is offered directly the next time. One person
can have as many addresses as they use. Nothing is written unless you pick
somebody, and typing a name from scratch files nothing.

This is optional, and refusing costs exactly those two things. Recording,
transcription and speaker labelling are unaffected.

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
listen dictionary <sub>           your own terms and corrections
listen calendar <sub>             the calendars on this Mac, and what they name
listen contacts <sub>             which address belongs to which person
listen calibrate                  voiceprint threshold report
listen mcp                        stdio MCP server, read-only
```

`listen calendar match <id>` is the one worth knowing about. Naming happens
silently, so it prints every meeting that could have been the one, how many
minutes each is away, and which one won:

```
$ listen calendar match 2026-08-03-160054-D478
Ryan Mitchell - Meridian
started 3 Aug 2026 at 16:00

→   -1m  Emily Carter and Ryan Mitchell
    Google / Home · 16:00 · 2 invited
    https://us02web.zoom.us/j/00000000000
    · Maxime Goossens <emily.carter@example.com>  [you]
    · Ryan Mitchell <ryan.mitchell@example.org>  [organizer]
```

`listen calendar backfill` does the same over your whole library and changes
nothing without `--apply`.

`listen transcribe some.wav` needs no permissions at all, which makes it the
fastest way to tell a model problem apart from a recording problem. It prints
what the model actually said: the dictionary applies to what goes into the
library and nothing else, so this command cannot be quietly editing its own
output.

```
listen dictionary list            every entry, and what each has changed
listen dictionary add <term>      a word to spell right, matched by sound
listen dictionary add <a> <b>     an exact replacement
listen dictionary test "<line>"   what your rules would do to a sentence
listen dictionary import --from-speak
listen dictionary export [<path>]
```

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
metadata.json      title, recorded_at, duration, source, state,
                   and the calendar event it was matched to
mic.wav            your track
system.wav         everyone else
mix.m4a            generated on demand for playback
waveform.json      the scrubber's envelope, also on demand
transcript.json    segments with speakers
turns.json         condensed per-speaker turns
embeddings.json    one voiceprint per speaker
```

Two lists sit beside the recordings rather than inside one, because they are
about the library as a whole: `dictionary.json` and `contacts.json`.

One folder per recording, and no database anywhere. The folders *are* the
library and the `embeddings.json` files *are* the voice bank, which means
deleting a recording in Finder is a supported operation rather than a way to
corrupt an index.

The guest list is copied into `metadata.json` rather than looked up when needed,
so a recording keeps answering after the meeting is deleted from the calendar or
you take the permission away again.

## What leaves your Mac

Two things, both declared in `InternetAccessPolicy.plist` for firewall tools
like Little Snitch:

- **huggingface.co**, once, to download the speech model.
- **github.com**, every two days, to check for an update.

That is all. Audio, transcripts and voiceprints are never uploaded, and there
is no telemetry. Reading your calendar adds nothing to this list: it is the
local calendar store, not a network call, which is the reason the feature needs
no account.

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

Copyright (C) 2026 Maxime Goossens.

Listen is free software under the [GNU Affero General Public License v3.0](LICENSE).
You may use, study, modify and redistribute it, and any distributed derivative
must also be AGPL 3.0 and ship its source.

The licence is deliberate rather than incidental. The claim this app makes is
that your audio never leaves your Mac, and a privacy claim nobody can check is
a marketing sentence. Being able to read the code, and to see
[`InternetAccessPolicy.plist`](InternetAccessPolicy.plist) name the only two
hosts it ever talks to, is the evidence.
