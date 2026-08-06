<p align="center">
  <img width="110" alt="Listen blue monkey app icon" src="Assets/icon.png" />
</p>

# Listen

A meeting recorder, transcriber and speaker labeller for macOS that runs
entirely on your Mac.

Press record. Listen captures the call, writes it down, works out who said
what, and remembers voices between meetings so the people you talk to every
week name themselves after the first time.

No meeting bot. No calendar invite. No account. Your audio never leaves the
machine.

Listen is the blue half of the Good Pair: a listening monkey with its hands
behind its ears. In the menu bar, it uses the Good Pair's square listening
seal, carrying 聞 (hear): a quiet nod to the three wise monkeys' Japanese
roots that remains clear at 16 points.

<p align="center">
  <img width="860" alt="Listen showing a meeting: the recording list, the speakers and waveform above the transcript, and each turn attributed by name" src="docs/screenshot.png" />
</p>

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
- **Keeps your own notes**, typed during the call or after it, one per
  recording. An agent can read them and cannot change them.
- **Answers to an agent** over MCP. Ask about your own meetings, and have the
  answer written back as a note, which can name several meetings at once. Notes
  are the only thing an agent can write: it cannot rename a speaker, edit a
  transcript or delete a recording.

## Requirements

Apple Silicon, macOS 14 or later. System audio capture needs macOS 14.2; on
14.0 and 14.1 Listen records your microphone only.

## Download

**[Download Listen for macOS](https://github.com/mugoosse/listen/releases/latest/download/Listen.dmg)**

Open the downloaded file and drag **Listen** to Applications.

### Other ways to install

Prefer Homebrew?

```sh
brew trust --cask mugoosse/tap/listen
brew install --cask mugoosse/tap/listen
```

The first line is Homebrew 6.0 and later refusing to load a cask from a tap
that is not one of its own until you say so, which is the right default and
worth knowing about rather than meeting as an error. Install without it and
Homebrew stops and tells you the same thing.

The speech model is about 2.5 GB and downloads on first run, after you press
the button that says so. **If you already use
[Speak](https://mugoosse.github.io/speak/), it is already on your disk** and
Listen will find it: both resolve the same Hugging Face cache, so whichever
downloaded first paid for both.

## Using it

The sidebar holds three lists and a switch at the top of it: **Recordings**,
**People** and **Notes**. Recordings is the library by day. People is everybody
Listen has heard, with what they have been in. Notes is every note in the
library, including the ones that are about several meetings at once. Search
scopes to whichever you are in.

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

### What you are called

Settings, General. Your own track is written as `Me` and shown as whatever you
put there, in the transcript, the roster and to an agent.

The transcripts keep saying `Me` whatever you choose, which is what makes it
safe to change your mind: every recording you already have reads the same as the
ones you make next, nothing is rewritten, and clearing the field puts `Me` back.

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

## Notes

Two kinds, and the difference is the whole design.

**Your own note**, one per recording. Open a recording, click **Notes** beside
Transcript, and there is a cursor: no New Note button, no naming step, and nothing written to
disk until you type. It is plain markdown in a plain text view, because the
value is that it is attached to the meeting and readable by an agent, not that
it is a good editor. It is editable **while the recording is still running**,
which is when it is worth the most: "we should upsell them" is exactly the
context that is in no transcript and can never be reconstructed from one.

**Notes an agent wrote.** A summary, the decisions, the actions, whatever you
asked for. There is no model in Listen that summarises anything, and adding one
is not planned: an agent connected over MCP already has a frontier model, the
transcript, and the question you actually asked. See the MCP section below.

An agent may **read** your own note and may not write it. That asymmetry is the
point of having two kinds: the transcript is evidence, your note is your
thinking, and only the derived one is open to being rewritten.

Notes live in `notes/` beside the recordings rather than inside one, because a
note can be about **several meetings at once**. "Summarise everything with Edgar
in June" spans four recordings and belongs to all of them; the frontmatter names
every one. The Notes tab in the sidebar lists them all, and clicking a meeting
in a note goes to it.

Deleting a recording does not delete notes that mention it. A synthesis of four
meetings must not vanish because one was tidied up, so the note stays and shows
the missing meeting as an id it can no longer resolve.

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
listen notes <sub>                the notes, one or many recordings each
listen calendar <sub>             the calendars on this Mac, and what they name
listen contacts <sub>             which address belongs to which person
listen calibrate                  voiceprint threshold report
listen mcp                        stdio MCP server
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
    · Emily Carter <emily.carter@example.com>  [you]
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

```
listen notes list [<id>]          every note, or those about one recording
listen notes read <slug>          one note, body on stdout
listen notes write "<title>" --recording <id>    add one
listen notes delete <slug>        remove one
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

Opens no port, and the app does not need to be running: the library on disk is
the source of truth.

**Notes are the only thing an agent can write, and not all of them.** Everything
else is read-only, and that is a boundary rather than a milestone. An agent can
add, rewrite and delete the notes it wrote; it can read your own note and not
change it; and it cannot rename a speaker, correct a transcript or delete a
recording. The transcript is evidence of what was said and notes are derived
from it, so a wrong note is a wrong opinion and a wrong transcript edit is a
lost fact. Changing the evidence goes through you, in the window or at the
command line, where you can see it and undo it.

### The tools

| tool | what it answers |
|---|---|
| `list_recordings` | which meetings match, as metadata only |
| `get_recording` | who was in one meeting, whether it has a transcript, which notes |
| `get_transcript` | the speaker turns, paginated |
| `search_transcripts` | which turns anywhere contain a phrase |
| `list_people` | everyone the voice bank knows, and how much they talk |
| `list_notes` | the notes on one recording, or all of them, without their text |
| `read_note` | one note in full |
| `write_note` | add a note. Markdown body, free-text title, one or more recordings |
| `edit_note` | rewrite one, refused if it changed since you read it |
| `delete_note` | remove one |

`list_recordings` takes `query`, `person`, `after`, `before`, `limit` and
`offset`. They combine with AND:

```json
{"person": "Edgar", "after": "2026-07-01", "before": "2026-07-31"}
```

`after` and `before` take `YYYY-MM-DD` or a full ISO 8601 timestamp. A bare day
covers the whole of it, so `before: "2026-07-14"` includes everything recorded
on the 14th rather than stopping at midnight. Anything else is refused with a
message rather than quietly matching nothing.

`search_transcripts` takes `person` too, and it means something different there:
`list_recordings` with a person finds meetings they were **in**, and
`search_transcripts` with a person finds turns they **said**. "What has Edgar
said about pricing" is the second one.

Names are matched case-insensitively, and both the stored label and the name you
see work. Your own track is stored as `Me` whatever you have set your name to,
so both answer. `list_people` prints the name to use, and adds `label` on the
one row where the two differ.

### Working through a large library

Transcripts are long and there is no summary layer, so the tools are shaped to
be walked from cheap to expensive rather than read whole:

1. `list_people` or `list_recordings` with `person` and a date range. Metadata
   only, no transcript is read.
2. `get_recording` on the shortlist, to see who is in each and how long it ran.
3. `list_notes` and `read_note` on the ones that look promising. A note is a few
   hundred tokens against a transcript's several thousand, and your own note on
   a meeting is often the whole answer.
4. `get_transcript` on the few that matter, paginated.

`search_transcripts` short-circuits that when you already know the phrase.

For scale: an average meeting here is about 5,500 tokens, so a 200k context
holds roughly 36 of them in full. Four two-hour catch-ups with one person come
to about 79,000 tokens, which fits in one go. A library of 2,000 meetings is
around 30 MB of text in total, so the limit you will meet is the context window
rather than anything on disk.

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

```
~/Library/Application Support/Listen/notes/<slug>.md
```

One markdown file per note, with frontmatter saying who wrote it, what they were
asked for, and which recordings it is about. Beside the recordings rather than
inside one, for the same reason `dictionary.json` and `contacts.json` are: a
note can name four meetings, so it is about the library rather than about any
one folder in it.

Two lists sit beside the recordings rather than inside one, because they are
about the library as a whole: `dictionary.json` and `contacts.json`. So do the
notes, for the same reason.

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

The MCP server adds nothing either, because it opens no port and speaks over a
pipe. What it does do is hand transcript text to whatever is on the other end of
that pipe, and if that is a cloud model then those turns go wherever that model
runs. Listen cannot know and does not decide; connecting an agent is a choice
you make, and the notes it writes come back and stay local. Nothing connects on
its own.

## Screenshots

`./make_demo_library.sh` writes a library of invented meetings to
`/tmp/listen-demo`: made-up people, made-up companies, and speech synthesised
with `say`, so nothing published anywhere is a recording of anybody.

```sh
./make_demo_library.sh
LISTEN_LIBRARY=/tmp/listen-demo LISTEN_DEMO_NAME=Alex \
  Listen.app/Contents/MacOS/Listen
```

`LISTEN_LIBRARY` points the app at another library and touches nothing in
`~/Library/Application Support/Listen`. A Finder launch inherits no shell
environment, so the app has to be started from a terminal for it to be seen.

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
