# Sharing one library between two Macs

Listen has no account and no server, so there is nothing built in to sync with.
What there is instead is a library made of ordinary folders with no database
anywhere, and that turns out to be the easiest thing in the world to put behind
a file sync tool.

This guide uses [Resilio Sync](https://www.resilio.com/sync/), which is
peer-to-peer and needs no third party to hold anything. Syncthing, Dropbox,
iCloud Drive or a network share will all work the same way, with the caveat in
[Placeholders](#placeholders-and-why-they-are-dangerous-here) at the end, which
is not optional reading.

Everything below was measured on a real 41-recording library, not estimated.

## What you get

Your transcripts, notes, people, contact book and dictionary on both Macs, so
`listen` and [the MCP server](README.md#mcp) answer on either one. An agent on
the second Mac can read every meeting you have ever recorded.

## The measurement that decides the whole setup

| | size |
|---|---|
| `mic.wav` and `system.wav` | **8.3 GB** |
| everything else | **6.5 MB** |

The audio is 99.92% of the library and **nothing reads it except playback.**
Not the transcript, not the CLI, not a single one of the MCP server's ten tools.
So the audio stays on the Mac that recorded it, and what crosses is about 6.5 MB
for 41 meetings, plus roughly 160 KB per new meeting.

This is not a compromise to save space. It is the correct arrangement: the audio
is the one part that is expensive, irreplaceable and useless to an agent.

## Setting it up

### 1. Move the library somewhere a sync tool is happy with

Listen reads `~/Library/Application Support/Listen`. That path is awkward in
most sync tools' folder pickers and sits near things macOS protects, so move the
library out and leave a symlink behind. Listen follows it without noticing, and
so does the CLI.

Quit Listen first. Then, on the Mac that has your recordings:

```sh
mkdir -p ~/Resilio
mv ~/Library/Application\ Support/Listen ~/Resilio/Listen
ln -s ~/Resilio/Listen ~/Library/Application\ Support/Listen
```

Both paths are on the same volume, so this is a rename rather than a copy: it is
instant, nothing is rewritten, and moving it back is the same command reversed.

Check it worked before going further:

```sh
listen list        # should print every recording you had
listen notes list  # and every note
```

### 2. Do the same on the second Mac

Listen creates an empty `recordings/` and `staging/` on first launch. Replace
that skeleton with a symlink to where the synced copy will land:

```sh
rm -rf ~/Library/Application\ Support/Listen     # only if it is still empty
mkdir -p ~/Resilio/Listen
ln -s ~/Resilio/Listen ~/Library/Application\ Support/Listen
```

### 3. Add the folder in Resilio, then stop

On the first Mac: **+ → Standard Folder**, choose `~/Resilio/Listen`.

Do not share it yet. The ignore list has to exist before another machine
connects, because Resilio's own documentation is explicit that it "will not work
with files that have already been synced."

### 4. Write the ignore list, on every Mac

Append this to `~/Resilio/Listen/.sync/IgnoreList`:

```
# The audio. Measured 8.3 GB of an 8.4 GB library, and nothing but playback
# reads it.
*.wav
*.m4a

# The recording in progress. See below.
/staging
```

**On every Mac, not just the first.** The ignore list does not travel between
peers. Miss one and that machine asks for files the others are refusing to send,
which shows up as `Cannot download 83 files` and never resolves. 83 was exactly
the 76 WAVs and 7 mixdowns in the library it was measured on.

A leading `/` anchors to the root of the synced folder, a bare `*.wav` matches at
any depth, and `/` is the separator on macOS. The list is case sensitive.

Restart Resilio afterwards so it re-reads the file.

### 5. Share it

Right-click the folder → Share → **Read & Write**, not Read Only. Read Only means
notes written on the second Mac never come back.

Paste the key on the second Mac with **+ → Enter a key or link**, pointing it at
the `~/Resilio/Listen` you made in step 2, and leave **Selective Sync off**. See
[Placeholders](#placeholders-and-why-they-are-dangerous-here).

### 6. Register the MCP server on the second Mac

```sh
claude mcp add listen -- /Applications/Listen.app/Contents/MacOS/Listen mcp
```

## What the second Mac can and cannot do

**Can:** read every transcript, search across all of them, list people, read and
write notes, everything in `listen` that does not touch audio, and the whole MCP
surface.

**Cannot:** play a recording back, redraw a waveform, or transcribe anything. The
audio is not there. Listen knows this and says so rather than failing: the player
is hidden, "Transcribe Again" is greyed out, and a recording waiting on its
transcript reads *"The audio is on the Mac that recorded this."*

You can leave the app open on both Macs. The queue will not pick up a recording
whose audio is on the other machine, which is what stops two Macs transcribing
the same meeting at once. See
[CLAUDE.md](CLAUDE.md#a-recording-with-no-audio-is-not-a-job-waiting-to-happen)
for why that guard is on the audio rather than on which device recorded it.

## Recording on both Macs

This works. Each Mac keeps its own audio and transcribes only its own meetings,
and both libraries end up holding every transcript.

The thing to know is that **deleting a recording anywhere deletes it
everywhere**, including the audio on the Mac that has it. That is what sync
means, and it is worth knowing before you tidy up on the machine that cannot see
what it is throwing away.

## Why `staging/` must never sync

A recording in progress lives in `staging/`, with its WAV headers rewritten every
two seconds so a crash costs seconds rather than the meeting.

If that folder reaches another Mac, two things happen there, both bad. `Listen`
adopts staged recordings into the library at every launch, so the second Mac
promotes and starts transcribing a meeting that is still being recorded. And
anything left in staging for 24 hours is swept, so the second Mac may delete your
live recording out from under the first.

One line in the ignore list closes both.

## Placeholders, and why they are dangerous here

**Turn off Selective Sync, Smart Sync, Files On-Demand, Optimise Mac Storage, or
whatever your tool calls it.** All of them replace a file with a stub that
downloads when something opens it.

Listen reads a recording by reading its `metadata.json`, and a recording whose
metadata cannot be read is skipped rather than reported. So a placeholder that
has not materialised, or has materialised but the machine is offline, makes that
meeting **disappear from the library entirely**: not an error, not a greyed-out
row, simply absent from the sidebar, from `listen list` and from the MCP server.

The saving is worthless here anyway. The whole synced set is 6.5 MB.

This is the same hazard as macOS eviction in iCloud Drive, which since Sonoma
leaves a dataless file that reports its full size and has no data in it. If you
use iCloud Drive for this, turn Optimise Mac Storage off.

## Undoing it

```sh
rm ~/Library/Application\ Support/Listen
mv ~/Resilio/Listen ~/Library/Application\ Support/Listen
```

Remove the folder from Resilio first, and keep in mind that removing a folder in
Resilio does not delete it, which is the behaviour you want here.

## What this is not

It is not a backup. Two Macs holding the same library means a mistake on one
arrives on the other within seconds, and Resilio's `.sync/Archive` keeps deleted
versions for 30 days rather than forever.

It is also not the audio. Every recording exists in full on exactly one Mac, and
if that Mac dies the transcripts survive and the recordings do not. Copy
`~/Resilio/Listen/recordings` somewhere with a real backup if the audio matters
to you.
