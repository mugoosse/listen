# Changelog

Newest first. The top section is the release being cut, and it is the **only**
place its notes are written: `release.sh` reads it for the GitHub release body
and for the "what's new" pane Sparkle shows before an update, and refuses to
publish when its version disagrees with `VERSION`.

A section starts at a heading that is `##` followed by a version number, so
headings inside an entry can be anything that is not one of those.

## 0.5.0 (2026-08-06)

### A meeting no longer records you as silence when you put on a headset

Reported from a real 49 minute call: the other speaker at 100% of talk time and
the user at 1%, because a headset was turned on a few seconds in. When the
microphone's format changes underneath it, AVAudioEngine stops calling its tap
and never resumes, so the rest of the meeting recorded as silence with nothing
logged anywhere.

The obvious fix does not work, which is the part worth knowing. With the device
pinned the way Listen pins it, the configuration-change notification every guide
points at fires once at startup and never at the hardware change, and the engine
reports itself running for the whole outage. Listen now watches Core Audio's own
property listeners, which do fire, and rebuilds the engine in about a third of a
second. A watchdog on the symptom catches whatever they miss at two seconds.

Reproduced by changing the input device's sample rate 8 seconds into a 26 second
recording: before, 8.6 seconds of microphone against 26.0 of system audio.

### Tag a recording with what it is about

A recruiter screen, a hiring manager chat and a referral catch-up share no word,
no attendee and no week, so free text, a person and a date range between them
cannot name "the job hunt calls". A tag is how a question says what it is about.

Tags are free text on the recording, filterable in the window, at the command
line and over MCP, and an agent may write one: it is somebody's filing of a
meeting, the same side of the evidence line a note is on. Filters stack, so
Maxime and Edgar together means both.

### Record moved to the corner it acts in

The New Recording row was at the top of the sidebar, so collapsing the sidebar
took the app's primary action off the screen with it, leaving only Cmd-N and the
menu bar. It is now a capsule floating over the bottom right of the content
pane, present whatever the sidebar is doing, and it is the stop control too:
start and stop are one toggle, and putting them in opposite corners means
crossing the window to undo a press.

Running, it is on every screen. Settings, People and Notes have no row with a
clock in them, so a meeting started an hour ago would otherwise have no visible
end from any of them.

### One library, two Macs

Listen has no account and no server, so there has never been anything to sync
with. But the library is ordinary folders with no database anywhere, which makes
it about the easiest thing there is to put behind Resilio Sync, Syncthing or a
network share. [`SYNC.md`](SYNC.md) is the guide.

Measured on a real 41-recording library: the audio is 8.3 GB and everything else
is 6.5 MB, and nothing but playback reads the audio. So the audio stays on the
Mac that recorded it and about 6.5 MB crosses, plus roughly 160 KB per new
meeting. Both Macs can record, and each transcribes only its own meetings.

Three things had to change in the app for that to be true rather than nearly
true. The transcription queue no longer picks up a recording whose audio is on
another Mac, which is what stops two machines transcribing the same meeting and
writing over each other's metadata. The player keeps its place and says where
the audio is, instead of vanishing and leaving a gap that reads as playback
being broken. And the window re-reads the library when you come back to the app,
so a meeting recorded on the other Mac appears without relaunching, which also
fixes a note or tag written by an agent not showing until something else
happened to reload the list.

Known limitations, both of them consequences of what sync means rather than
bugs. Deleting a recording anywhere deletes it everywhere, including the audio
on the machine that has it. And preferences do not sync, only the library does,
so a second Mac shows your own turns as `Me` until you run `listen me "Your
Name"` there and starts with an empty meeting-detection skip list.

### The MCP reference has its own page

The README had grown to 557 lines with MCP the largest section in it, so that
moved to [`MCP.md`](MCP.md): how to connect each client, what every tool takes,
and how to walk a large library without reading it whole. It gains per-client
setup for Claude Code and Hermes.

Two things worth knowing if you wire up an agent. Hermes profiles do not inherit
MCP servers, so a server added to the default profile is invisible from every
other one with nothing reported. And point any client at the installed app or
the `listen` symlink rather than a build directory: the config stores a path and
an update replaces the app at that same path, so a new version is picked up with
nothing to re-register.

## 0.4.0 (2026-08-06)

### The menu bar says which app it is, and what you recorded

Listen's menu now opens with its own name and mascot. That row is there because
an icon in a menu bar of twenty is not a name, and the only other place the app
said what it was called was About Listen, eight items down.

Under it, the five most recent recordings. Clicking one opens it: the library
comes forward with that meeting selected and its transcript on screen, whether
or not the window was open when you reached for the menu. Each row is stamped
with the time if it was recorded today and with the date if it was not, so a
meeting from Tuesday does not read as one from this morning. The recording in
progress is deliberately not in that list, because it is already the two rows at
the top of the same menu.

A row now appears when a permission is missing, next to the one that has always
appeared when the speech model has not been downloaded. Both go straight to the
settings pane that can do something about it. The elapsed clock is also correct
now: it is read when you open the menu rather than when the recording started,
so it no longer reads 0:00 for the length of a meeting.

### About says whether you are up to date

Sparkle answers a check in a window that is then dismissed, taking the answer
with it, and a scheduled check that finds nothing says nothing at all, so "am I
on the latest version" had no answer that survived closing a dialog. About now
carries Check Now, a Check automatically switch, the result of the last check
and when it ran, alongside the app icon, the version and a line saying Listen is
free software under the AGPL 3.0 with a link to its source.

Nothing about what is sent changed. The check asks whether a newer version
exists and sends nothing about you, and every update is still verified against
Listen's signing key before it is installed.

### Still true from 0.1.0 through 0.3.0

About six words an hour are corrupted at chunk seams on a Mac with the memory
for 600 second chunks, and about 33 on a Mac with 12 GB or less, where the
chunks are 120 seconds. Speaker labelling is per sentence rather than per word,
so two people talking over each other inside one sentence come out as one
speaker. Meeting detection is on by default: it starts recording, then asks on
screen, and answering no deletes the audio straight away.

## 0.3.0 (2026-08-06)

### The notes you meant to write

Every recording now has a Notes tab. It is one plain Markdown note that is
yours: open it and type, during the meeting or afterwards. There is no new-note
button and nothing is saved until there is something to save. If Listen asks
whether a detected recording was a meeting and you say no, it asks again before
discarding a note you made during it.

An agent connected over MCP can read that note but can never change it. It can
write a separate Markdown note with the summary, decisions or open questions
you asked for, and file it against one or several meetings. It cannot rename a
speaker, alter a transcript or delete a recording. Agent-written notes can be
edited safely: Listen refuses an edit when the note changed after the agent read
it, rather than silently replacing somebody else's work.

Notes sit beside the recordings in the library, not inside one recording, so a
write-up spanning several calls stays attached to every call it used. Removing a
recording does not remove a note that also concerns other calls.

### Finding a meeting is no longer one long list

The sidebar now switches between Recordings, People and Notes. People groups
meetings by who was there; Notes puts every write-up in one place. Search stays
inside the collection you are looking at. Settings also has a name for your own
track, shown in the app while the stored recording label remains safely `Me`.

### A selection colour that belongs to Listen

Selected recordings, tabs and controls now use Listen's website blue rather
than the generic macOS blue. It is sampled from the app icon and retains dark
text for contrast.

### Still true from 0.1.0 through 0.2.0

About six words an hour are corrupted at chunk seams on a Mac with the memory
for 600 second chunks, and about 33 on a Mac with 12 GB or less, where the
chunks are 120 seconds. Speaker labelling is per sentence rather than per word,
so two people talking over each other inside one sentence come out as one
speaker. Meeting detection is on by default: it starts recording, then asks on
screen, and answering no deletes the audio straight away.

## 0.2.0 (2026-08-06)

One change, and it is a default rather than a feature.

### Listen opens at login on new installations

Meeting detection only runs while Listen is running. The checkbox for opening
it at login has been in Settings since 0.1.0, sitting unchecked, which meant
anybody who did not go looking for it had a recorder that quietly missed every
call and offered no account of why. That is the same silent failure that made
detection itself default to on, so the two defaults now agree.

New installations only. Upgrading from 0.1.0 or 0.1.1 changes nothing on a Mac
that is already set up, so if you want it there, the checkbox is in Settings,
General, under Startup. Turning it off is equally final: the decision is
recorded the first time it is considered, and no later launch overrides what
you chose, here or in System Settings, General, Login Items.

The cost, plainly. Listen keeps a Dock icon and a window rather than living
only in the menu bar, so opening at login means the library window opens with
it. Suppressing that needs a way to tell a login launch from an ordinary one,
and the obvious candidate is not one: `NSApplicationLaunchIsDefaultLaunchKey`
never mentions login items and is also false for window restoration, so
trusting it would trade an unwanted window for the worse failure of opening
Listen and seeing nothing at all.

### Still true from 0.1.0 and 0.1.1

About six words an hour are corrupted at chunk seams on a Mac with the memory
for 600 second chunks, and about 33 on a Mac with 12 GB or less, where the
chunks are 120 seconds. Speaker labelling is per sentence rather than per word,
so two people talking over each other inside one sentence come out as one
speaker. Meeting detection is on by default: it starts recording, then asks on
screen, and answering no deletes the audio straight away.

## 0.1.1 (2026-08-05)

A fix for Macs with less memory, and the first update that arrives with its own
notes attached.

### Transcription now adapts to how much memory the Mac has

It used to work in 600 second chunks on every machine. That figure was measured
on a 128 GB Mac with nothing else running, where the pass peaks at 3.28 GB. On
an 8 GB M1 Air, alongside a browser and the video call the meeting is in, the
same pass can exhaust Metal memory and take the transcript with it. That lands
an hour in, after the recording, where it costs the meeting rather than a retry.

On Macs with 12 GB or less, chunks are now 120 seconds, which is the figure
Speak has shipped on 8 GB machines throughout. The cost is real and worth
saying plainly: one word is corrupted at every chunk seam, so an hour-long
meeting on a smaller Mac now carries about 33 corrupted words instead of about
6. That is worth paying when the alternative is no transcript at all.

Nothing changes on a Mac with the memory to spare.

Because two Macs can now disagree about the same file, `listen transcribe`
reports the chunk length and the seam count on every run. Without it, "my
transcript has more glitches than yours" has nothing behind it to check.

### Updates say what is in them

The update pane was blank in 0.1.0, so the only thing it gave you to decide on
was a version number. It carries these notes from now on.

### Installing with Homebrew takes one more line

Homebrew 6.0 refuses to load a cask from a tap that is not one of its own until
you say so:

```sh
brew trust --cask mugoosse/tap/listen
brew install --cask mugoosse/tap/listen
```

### Still true from 0.1.0

About six words an hour are corrupted at chunk seams on a Mac with the memory
for 600 second chunks, and about 33 on a smaller one. Speaker labelling is per
sentence rather than per word, so two people talking over each other inside one
sentence come out as one speaker. Meeting detection is on by default: it starts
recording, then asks on screen, and answering no deletes the audio straight
away.

## 0.1.0 (2026-08-05)

First release. Listen records a meeting from both sides, transcribes it, and
works out who said what. Everything runs on your Mac and nothing is uploaded.

### Before you start

- Apple silicon, macOS 14 or later. Capturing the other side of a call needs
  macOS 14.2; on 14.0 and 14.1 Listen records your microphone only.
- The speech model is about 2.5 GB. It downloads the first time you transcribe
  something, not during install.
- Two permissions on first launch: microphone, and audio recording. It asks for
  audio recording and **not** screen recording. Calendar access is optional and
  buys one thing, naming a recording after the meeting already in your diary.

### Worth knowing before you record a real meeting

- **Meeting detection is on by default.** Listen starts recording when it sees
  one app using the microphone and the speakers at once, and then asks on
  screen whether you are actually in a meeting. Answering no deletes the audio
  straight away. It over-triggers rather than under-triggers, on the grounds
  that a recorder you have to remember to switch on is switched off for the
  meeting you needed it for.
- **Speaker labelling is per sentence, not per word.** Two people talking over
  each other inside a single sentence come out as one speaker.
- **About six words an hour are corrupted** where the transcriber's chunks
  meet. Known, measured, and being fixed by cutting chunks at silence.
- Nothing asks "keep this recording?" at the end. A recording that exists is
  kept, and Delete in the library is how one goes away, where you can hear it
  first.

### If something goes wrong

`listen transcribe some.wav` needs no permissions at all, which makes it the
quickest way to tell a model problem from a capture problem.

Reports and confusion are both useful: https://github.com/mugoosse/listen/issues
