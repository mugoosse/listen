# Changelog

Newest first. The top section is the release being cut, and it is the **only**
place its notes are written: `release.sh` reads it for the GitHub release body
and for the "what's new" pane Sparkle shows before an update, and refuses to
publish when its version disagrees with `VERSION`.

A section starts at a heading that is `##` followed by a version number, so
headings inside an entry can be anything that is not one of those.

## 0.18.0 (2026-08-24)

### A first Mac now makes the sync key

Turning sync on set a flag and nothing else: no production path ever created
the key, so a fresh install reported "No sync key yet" on every pass while its
iPhone waited for a key that did not exist. Macs already running Listen never
saw this, because they inherited a key from the older file.

There is now one place a key is made. The first Mac creates it, and a Mac that
can see another device in the container waits for iCloud Keychain instead of
minting a rival key, which would have split a library in two silently. The Sync
pane leads with the switch, says one thing per state, and shows a button only
when it can act; it also gains the typed-key fallback for a Mac where iCloud
Keychain never delivers. Setup asks about sync as its own step, so a new Mac
holds the key before an iPhone ever asks for it.

### About is a window, with the links in it

"About Listen" opened a page inside the library window, behind the settings
sidebar. It opens a window now: the icon, the version and build, and buttons
for the website, the documentation and the source. It also carries a share
sheet, a Copy Link button and a request to star the repository.

The website was missing rather than merely hard to reach. Until now the app
linked the author's site and the source repository and never Listen's own page,
so somebody trying to pass Listen on to a friend had nothing to send. That is
exactly how it was reported.

Listen also had no Help menu at all, which is the first place a Mac user looks
for a website. There is one now, holding the documentation, the website, the
source, a way to report an issue and Share Listen. Cmd-W closes a window, which
nothing in the app did before.

The settings section that used to be About keeps the version check and Run
setup again, is called Updates, and sits with the other app settings rather
than under Advanced. A button under the section list opens the About window, so
the menu bar is not the only way to it.

The documentation button opens the README on GitHub. That is where Listen's
documentation actually is today, and the button will point at a documentation
site when there is one.

### Fewer places pointing somewhere else

The author's personal site is a credit line rather than a link, now that Listen
has a page of its own for the app to point at.

Speak, the dictation app Listen grew out of, is no longer recommended anywhere
in the app: its dictation is part of Listen, so every route out to it offered a
download for something this app already does. Importing a dictionary from Speak
still works, and that section now appears only on a Mac that actually has the
file, which is the migration it always was.

One of those was not cosmetic. Requests to a hosted Ask provider carried
Speak's address in their attribution header, so Listen's traffic was credited
to a different app on OpenRouter's dashboards.

## 0.17.0 (2026-08-24)

### A phone recording shows its whole trip

An iPhone recording now reports when its audio is syncing, how far it has
travelled and which Mac is transcribing it. The Mac keeps its full waveform
while the compact iPhone row uses a percentage, and both replace vague idle
states with the work that is actually happening.

The same path now completes rather than only looking active. A new recording
is offered to iCloud, received by a Mac, transcribed there and returned to the
iPhone without a restart or a second recording to wake it up. A missing
CloudKit record was being reported as a batch failure and treated like an
outage, which left the audio safe on the phone but prevented the first record
from being created. Listen now distinguishes that normal first-sync case from
a real connection failure.

If a retry is necessary, one rotating sync icon sits beside the explanation
instead of a static retry icon and a second unrelated spinner. The recording
continues to say that its audio is safe while no Mac has accepted it.

### Transcription gives memory back when it is done

The MLX buffer pool is capped and released after a track finishes. This keeps
one completed transcription from reserving accelerator memory that the next
recording or another application needs. The model remains cached, so the next
transcription does not pay the full model-loading cost again.

## 0.16.0 (2026-08-18)

### Every device keeps a copy of the audio

Until now, only the Mac that recorded a meeting had its audio; every other
device had the transcript and nothing to play or re-transcribe. Listen can now
publish a lossless copy, mic and system audio kept apart in one stereo FLAC
file, so any device can play a recording or run it through the pipeline again.
Settings, Devices has a **Keep audio** switch and a roster of what each device
keeps and holds, so the choice to free local space is visible rather than
silent.

Measured on a 1.07 hour meeting: 494 MB of raw tracks becomes a 61 MB master
in 3.8 seconds, about an eighth of the size, with the two channels intact so
speaker separation still works on a re-transcribe. A device only frees its own
copy once another live device that is keeping audio reports actually holding
it, never on the strength of the network alone.

### The library says who is transcribing, and how long it took

A recording being worked on now names the Mac doing it and when it started, so
two devices never race to transcribe the same recording, and a finished one
carries "transcribed on \<device\> in \<time\>" once the library has more than
one device in it. `listen transcribe <id>` takes the same lease as the
background queue, so running it by hand no longer opens a second way in.

### A stranded recording says so

A recording waiting on audio from another device could sit that way for hours
with nothing on screen to explain it. `listen sync inspect --recording <id>`
now shows who holds the audio, whether a transfer is in flight, and what the
manifest actually names, across every zone. A claim on a recording that goes
nowhere expires after six hours rather than parking it forever, and only the
device holding the audio writes that recording's metadata, so a stalled
recording can no longer be handed back to itself with its progress erased.

### Compliance and managed deployment

`docs/hipaa.html`, `docs/privacy.html` and `docs/security.html` document what
Listen sends where, what a security questionnaire will ask, and where it maps
onto HIPAA and GDPR obligations, for anyone deploying it in a regulated
setting. An organisation can now force Listen's settings through a standard
MDM configuration profile: iCloud sync off, Ask restricted to a local model
only, dictation history off, or backups redirected or disabled, each with a
sample `.mobileconfig` and `verify_compliance.sh` to check it took. The
activity log (`listen activity`) now records every tool call by name and id
only, never by content, and that claim is asserted rather than assumed.
Forgetting a person now leaves a tombstone, so a stale Mac pushing its old
voiceprints back can no longer bring a forgotten speaker back to life.

## 0.15.0 (2026-08-14)

### A phone recording comes back with its transcript

A memo can reach the Mac, finish transcribing there and still leave the iPhone
saying it is waiting. Two different races caused that. A sync requested while
another pass was running could be forgotten, and a later phone pass could put
its original metadata-only copy back after the Mac had published the finished
transcript. Requests are now remembered, and a phone can add missing content
without replacing the transcript, turns or details already published by a Mac.

The affected recordings are checked again once after updating. Measured on the
live 11:13 memo that exposed the problem, the transcript reached the physical
iPhone and remained byte-identical after a second forced phone sync. The audio
transfer zone was empty afterwards.

### Source applications look like themselves on every device

Listen now carries a small copy of the source application's icon with each
recording, sealed inside the same private iCloud payload as its other display
files. Rows on the Mac and iPhone can show Chrome, WhatsApp, QuickTime and other
source applications instead of a generic window.

Older recordings are filled in when a Mac that still has the source application
installed syncs them. If no syncing Mac can resolve an application, the row keeps
the generic fallback rather than inventing one.

## 0.14.2 (2026-08-13)

### Listen keeps copies of your library

A copy of your library is made once a day and kept for a week, and anything a
sync deletes is kept for a fortnight, so a mistake is not final. The copies
share their contents with the library, so they take almost no extra space.
Settings, Storage says when the last one was made and where they are.

They live on this Mac, so they protect you from mistakes rather than from the
disk itself failing. Time Machine is still the answer to that.

### Somewhere to save the key that opens iCloud

Everything Listen keeps in iCloud is sealed with a key only your devices have.
Settings, Sync can now show it, so you can keep a copy in a password manager
and still open what iCloud holds if you ever lose every device.

## 0.14.1 (2026-08-13)

### Deleting is undoable for a fortnight

A recording or note removed by a sync from another device is now kept in your
library for fourteen days before it is really gone. Whatever removed it, the
files are still there afterwards. `listen sync trash` lists what is being held
and where, and putting something back is a matter of moving the folder into
`recordings/` or `notes/`.

Listen also refuses to tell iCloud that everything has gone. A library that is
suddenly empty is far more likely to be a disk that did not mount, a folder
moved by hand, or a restore in progress than a decision to delete every
recording at once, so it says so and changes nothing.

### Corrections travel again

Renaming a speaker or correcting a sentence rewrites the transcript rather than
the recording's details, and only the details were being watched, so those edits
waited for the next scheduled sync instead of going immediately. Listen now
notices any change to the library, whatever made it, including edits from the
command line and from the MCP server.

One recording in the library had never reached iCloud at all: the copy of a
transcript kept from before your first correction is stored under a name derived
from the recording, and iCloud refuses names it has not seen before. Every edit
to that recording was refused along with it. Those backups now sync, and their
presence is what stops transcribing again from discarding your corrections
without asking.

## 0.14.0 (2026-08-12)

### Your library reaches every device through iCloud

Listen now keeps transcripts, notes, people, tags and its custom dictionary in
step through your private iCloud database. A meeting recorded on either Mac can
appear on the other Mac and the iPhone without both devices being awake or on
the same network. The existing wifi path remains available during the migration
and is still running until the final cutover is tested.

The contents are sealed before upload with a key held by your devices. Record
names, zone names and record types are opaque too, so titles and meeting times
are not left outside the sealed content. Audio recorded on a Mac stays on that
Mac. Audio from the phone is a temporary transfer and the phone keeps its copy
until a Mac has written the bytes to disk and named itself as their holder.

Measured on the live library, the Production container holds 147 records: 71
recordings, 14 notes, 2 library files, 57 voiceprints and 3 devices. The audio
transfer zone is empty after completed ingests.

### A sync starts with what you are waiting for

On cellular, the phone could spend minutes saying "Sending 71 of 71" before it
asked iCloud for a transcript the Mac had already finished. A pass now fetches
incremental changes first. It also remembers a local stamp for each recording,
so unchanged files are no longer sealed and checked against the server on every
pass, and phone audio that has already been handed to a Mac is not uploaded
again when **Keep audio on this iPhone** is on.

Finished transcripts are sent a few seconds after the Mac writes them rather
than waiting for the two-minute fallback poll. Push notifications wake both
apps for changes, and pull to refresh on the phone uses iCloud whenever iCloud
is the selected transport.

### Sync says what it is doing

The Mac's Devices pane now shows live work such as "Fetching 15 of 71" and
"Sending 6 of 12", followed by when the last pass ran, what it changed and the
first error or note conflict. The same pane lists the devices on the iCloud
account. A new Mac fetches before it sends, so opening an older library cannot
overwrite newer recordings before it has learned what changed.

Hand-written markdown notes remain part of the library format. Notes with no
frontmatter, and notes whose `recordings` use a YAML block sequence, now run
through the same offline end-to-end suite as generated notes.

### Deleting something deletes it everywhere

A recording or note you delete on one device now goes from the others as well.
Until now a deletion was obeyed when iCloud reported one and never reported
when you made one, so a meeting deleted here stayed in iCloud and on every
other device. Deleted notes could also come back, because a device that still
held its own copy put it back the next time it sent anything.

A recording whose files cannot be read is never mistaken for one you deleted,
so a damaged file on one device costs nothing on the others.

## 0.13.0 (2026-08-12)

### Clicking a speaker no longer hides the meeting

It used to filter the transcript down to only their turns, which read as the
app having mislaid the rest of the conversation. Clicking a name is a
question, not a filter: the transcript now stays whole, and what changes is
where the waveform and the popover's own Play button point. Play there still
skips straight to that person, but the pane's play button always plays the
meeting.

### Correcting who said something, at three sizes

- **One sentence or one paragraph wrong**: reassign it to whoever actually
  said it, from the pill's menu, without touching the rest of the turn.
- **A whole speaker is really someone else already in the recording**:
  the speaker picker now lists everybody already in the meeting first, above
  the voice bank's own suggestions, so folding a stray speaker into an
  existing one is picking a name rather than knowing the word for it is
  "Merge" and finding the button.
- **A speaker was named by mistake**: Leave Unnamed puts them back to a
  letter, no confirmation needed, because it costs nothing to undo. Discard
  is now offered only for a speaker nobody has named, and its confirmation
  states exactly what it removes ("This removes 8 turns · 0:39 from the
  transcript"), because the alternative was somebody reaching for Discard
  meaning undo and deleting half a transcript with no way back.

### The paragraph that lights up while playing is the one actually sounding

Turns overlap in real recordings, and the highlight used to pick whichever
overlapping turn started earliest, which is usually the wrong one: measured
on one call, 59 of 105 clicks lit up a different paragraph than the one
playing. It is ranked differently now and gets all 105 right on the same
transcript.

### The transcript's scrollbar reaches the floor of the window

With the composer open, it used to stop well short of the bottom, a knob
resting a third of the way up with nothing under it. Fixed layout math that
was making room for the composer twice; the scrollbar now runs the full pane
and sits flush against the window's edge.

## 0.12.0 (2026-08-11)

### Listen dictates now, and Speak is retired

Press **fn + left shift** anywhere on the Mac, say what you want written, press
it again, and the words are typed into whatever you were using. Escape cancels,
and so does the trash button on the floating pill. Everything is in Settings,
Dictation: the shortcut, the engine, the sounds, the pill.

This is [Speak](https://mugoosse.github.io/speak/) folded in rather than
rebuilt. Listen was built from Speak as a template, so by the time dictation
moved the two already shared a microphone path, a speech model, a Hugging Face
cache, a custom dictionary, a settings framework and a release pipeline. What
dictation needed that meeting recording did not was a global shortcut and a way
to type. That is the whole difference, and it was not worth a second app, a
second menu bar icon, or a second 2.5 GB of weights held in memory.

It needs Accessibility, which is what lets Listen see the shortcut and type for
you. Recording meetings never uses it, so anyone who only wants the recorder can
ignore the whole feature and will not be asked for anything.

### One vocabulary, two pipelines

The custom dictionary now applies to dictations as well as meeting transcripts.
A name Listen mishears in a meeting is the same name it mishears when you
dictate, so one rule fixes both. Both halves of a term are live again: the
phonetic match, which needs no model and works on any macOS, and the spelling
hint that stops the polishing model rewriting a word it does not know.

### Tidying up what you said

On macOS 26 with Apple Intelligence, dictations can go through a copy-editing
pass before they reach the clipboard: punctuation and capitalisation added, um
and uh removed, paragraphs where the topic turns. Off by default, because it
costs about a second and rewrites your words.

It is a copy editor and never an assistant, which took some doing. Told it was
an assistant, the model answered the text: "what time is the meeting tomorrow"
came back as "The meeting tomorrow is at 3 PM", inventing the time. A dictated
question now comes back as a question, a sentence you cut off stays cut off, and
a reply that collapses or grows past what editing can explain is thrown away in
favour of what you actually said.

There is a second pass for false starts, where you begin a phrase, break off and
say it again. It runs only on sentences that look like that, which measured over
a real 260-dictation history is about one dictation in ten, so the other nine
pay nothing for it.

### Dictating during a meeting

Works, and your dictation is also on the meeting's microphone track, because it
is your voice in the room. Listen does not open a second microphone to do it:
the recording already holds the device, and a second claim on it would
renegotiate the Bluetooth profile the meeting is being recorded through.

One speech model serves both now instead of one each, which is the difference
between fitting and not fitting on an 8 GB Mac. A dictation asked for while an
hour-long recording is being transcribed no longer waits for the hour.

### Coming from Speak

The speech model carries over on its own: both apps always used the same
download, so there is nothing to fetch again. The configuration does not. Set
the shortcut again in Settings, Dictation, and bring your Speak dictionary
across in one press from Settings, Dictionary.

### Ask your library through a model on your own Mac

Questions about your recordings used to need Claude Code or Codex installed.
Any OpenAI-compatible endpoint answers them now, which covers the case this app
should be best at: a model running on the same Mac at
`http://localhost:11434/v1`, with no account anywhere and nothing leaving the
machine. Twelve are set up in a press each, among them Ollama, LM Studio,
llama.cpp, OpenRouter, OpenAI, Groq, Mistral and xAI. Any other URL can be
typed in, several can be configured at once, and the composer switches between
them.

Which local model, measured on four questions with checkable answers against a
five-recording library: `qwen3.5:35b` at 23 GB answered all four in 7 to 18
seconds, and the 81 GB model matched it at roughly three times the wall clock,
so the larger download buys nothing on this task. `gemma4` at 9.6 GB is faster
again and got three of four.

An agent CLI brings its own tool loop, and a provider is one stateless request,
so Listen runs the loop itself. Two consequences are worth knowing. A model that
advertises tool support will still answer from nothing, so an answer with no
tool call behind it and no earlier conversation to draw on is flagged rather
than trusted. And keys live in the Keychain, never in preferences: an endpoint
that is not on this machine says in words that your transcripts go to it, before
you save it.

The model menu lists the ones you have used, with a searchable picker behind it,
because a provider can offer 318 tool-capable models and the first twelve
alphabetically are ones nobody chose.

### A question that loses the network says so, and can be asked again

Neither agent CLI reports a connection that has gone away, which was measured
rather than assumed: against a blackholed API, `claude -p` ran 100 seconds with
nothing on stderr and no exit, and `codex exec` did the same. The pane said
"Thinking" until somebody pressed Stop. Listen now watches the network path and,
once a run has been quiet for 20 seconds, opens a connection to the backend's
own host, which is the only half that catches a router still handing out
addresses over a dead uplink.

Asking with no connection is refused with the reason. Losing it under a running
question turns the line amber and stops the sweeping highlight, which is there
to say the process is alive. Nothing is ever killed for a network reading, and
nothing retries by itself: a failed turn offers Try again, which replaces the
attempt rather than adding to the conversation.

### A conversation is a page, not a panel that grew

A question still starts in the composer at the bottom of whatever you are
reading, and a conversation can now take the whole window: the frame goes, the
text sits in a 620 point column, which is 105 characters of the body size, the
page scrolls rather than a panel inside it, and the sidebar underneath becomes
the list of conversations instead of going on listing recordings behind a view
nobody can see. History belongs to the two screens that are about conversations,
the home page and a conversation itself, and picking one out of it opens the
page rather than a card over an unrelated meeting.

With it: a follow-up typed while an answer is streaming waits its turn instead
of vanishing, and Stop hands it back to the composer; Delete is a verb on the
conversation's own menu and asks nothing first, because a conversation is
working-out and anything worth keeping was already saved as a note; and the
meeting being recorded has no composer at all, since that screen's bottom edge
is the meters that say whether your voice is arriving, and nothing is
transcribed until Stop.

### A note remembers the conversation it came from

Saving an answer as a note records which conversation it was promoted out of,
and the "Asked for" line on the meeting page opens that conversation again.
Notes written before this release are matched on their question instead.

The ellipsis in the title bar is about what is on screen rather than always
about a recording, so a note gets Open Conversation, Show in Finder and Delete,
and a person gets the verbs that belong to them. The sidebar's right-click had
the sharper half of the same bug, aiming a meeting's red Delete at a note.

### The recording panel goes where you drag it

An hour-long meeting spent that hour under a floating panel in one fixed corner,
and putting the panel away was the only answer to it covering the thing the
meeting is about. The whole face of it is a grab area now, buttons excepted.
What is stored is a corner and two insets rather than a point, so the panel
grows the right way as the clock reaches an hour and still lands on screen when
it is read back on a different display.

### Also

- Three new commands: `listen dictate <file>` runs the dictation pipeline over
  audio, `listen polish [text|-]` runs the text half, and `listen dictations`
  reads what you have said. The first two exist because dictation is otherwise
  only reachable by holding a key and talking, so a change to it could only be
  tested by hand.
- Dictation history is a plain JSONL file beside the library, including what the
  speech model said before anything rewrote it. Nothing reads it for the agent:
  a dictation is a keyboard, not a meeting.
- An Accessibility row in Settings, Permissions that says what it is for and,
  more usefully, what it is not for.
- Dictating could make Listen believe you were in a meeting and start recording
  one, because a dictation runs the microphone and a sound at the same moment,
  which is the rule that spots a call. Twice in one morning, for 6.4 seconds
  each. Listen is now never a meeting, whichever copy of Listen it is.
- The note box on a meeting page hid its own last line: it reserved room for a
  button that has been in the toolbar since 0.11.0, so an empty note showed 6
  points of its 30 and a three-line note 34 of its 58, with the leftover
  scroller appearing beside it as a sliver nothing explained.
- Every control on the Ask surfaces lights up under the pointer and says what it
  does, which none of them did: they are borderless because they float over a
  meeting, and AppKit gives a borderless button no resting shape and no hover.
- The library's home page has four starter questions of its own, all of them
  ones that only pay off across meetings: Catch me up, Open items, Decisions,
  Recurring themes.
- The status line under the composer holds its slot whether or not it has
  anything to say, so a message arriving mid-question no longer lifts the field
  you are typing into by 14 points.
- The expanded conversation held its column still. It slid sideways on the first
  scroll and stayed there, measured at 541.5 points opening and 756.0 after.

## 0.11.0 (2026-08-09)

### One list, and a meeting is one page

The sidebar's three-way picker is gone. The recordings list is the library:
notes sit among the meetings in the same days, and typing a name brings back
that person's card above the results as well as the transcripts they appear in.
A note is a row only when it has no single page to live on, which means a
synthesis of several meetings or a note about none; a note about exactly one
recording lives on that recording, because listing it here too would put every
meeting in the library twice.

Transcript and Notes have stopped being two tabs you choose between. They are
one page now, what you wrote above and what was said below. The transcript
keeps its own scroller, which is load-bearing: playback scrolls it to the
sentence being spoken, and a shared scroller would drag the note off the top of
the window every time somebody pressed play with a caret in it. The note takes
the height of its own text between three lines and six, measured against the
longest of the 11 notes in this library.

### Ask is always on screen, and a conversation is a document

The question bar belongs to the window rather than to a meeting, so a question
asked with nothing selected is a question about the library. That case had no
way to be asked before, and it is the one a library-wide answer exists for.

Conversations moved out of the recording folder into `chats/`, naming the
meetings they are about as a list. A question spanning four meetings had four
bad homes and a question about none had nowhere to go. Existing conversations
are moved on first launch, keeping their turns, their session and the time of
the last thing said in them rather than the time the move ran.

The answer arrives in a drawer over the page instead of replacing it, in three
sizes, and putting it away does not lose it. The composer always starts empty,
at launch and on every meeting: it used to load the newest conversation for
whatever you had arrived at, so opening the app put you inside an old
conversation nobody had asked for. History, in the title bar, is how you go
back, and it lists every conversation rather than the current page's. Delete is
one item at the foot of that menu acting on the conversation that is open,
because conversations are titled by their first question and a list of four
rows with two identical pairs is a delete you cannot aim.

### An answer cites what it read

Answers named recordings and left them dead. Each claim now carries a small
numbered reference; clicking it shows what is behind it, the recording with its
date, length and speakers, or a note, or a person, and the card is what opens
the page. Two clicks rather than one, deliberately: a citation is read in the
middle of a sentence, and a number that swaps the page under you is one nobody
presses twice.

The identity is the agent's, not a text match. It writes the recording's id
after the claim, so a library where most recordings are called "New recording"
cannot send you to the wrong meeting. A reference naming something the library
does not have is dropped rather than drawn, and the markers never reach a note
or a file on disk.

Measured against Claude Code, which cites unprompted once its brief asks for
it. Codex writes the same answers through the same brief but its compliance
has not been measured, so an answer from it may carry no numbers at all.

### Worth knowing

- **Save as note works on a conversation with nothing selected**, which is
  where most questions are asked. It used to write no file and say nothing. It
  now files the note against the meetings the conversation was about rather
  than whatever is on screen, and the button itself says "Saved".
- The empty pane opens with your name rather than an instruction, and a meeting
  page says what has already been asked about it.
- Missing agent configuration is announced in the composer, where the question
  is typed, instead of only in settings.

## 0.10.0 (2026-08-08)

### Ask a meeting a question, through an agent you already have

Listen ships no model and holds no key. A new Ask pane drives whichever of
Claude Code or Codex is already installed and signed in on this Mac, handing it
`listen mcp` as the only way to reach the library. So a question about a
recording costs nothing beyond the subscription already paid for, and never
leaves the machine by a route the agent does not already take.

Ask sits beside Transcript and Notes as a third mode: starter questions, the
work shown as one line that is replaced rather than appended to as it runs,
and Save as note to promote an answer into the library. `listen ask` is the
same engine from a terminal, and is how it was measured. When neither CLI is
installed or signed in, the pane now says which, instead of showing four dead
starter chips.

### Name a recording after the people in it

The calendar can only name a meeting that was scheduled, and most calls are
not: four recordings in this library sat at "Untitled" with the nearest
calendar event 51 and 32 minutes away, nothing for it to find. A recording is
now also named after whoever spoke, the moment the last unnamed speaker is
given a name. It follows further renames and stops the moment somebody types a
title of their own; a title typed while a recording is running now survives
stopping it, where it used to be discarded on reload.

Recordings whose speakers were already named before this update need `listen
title backfill` to pick it up; it is a dry run unless you pass `--apply`. An
unnamed recording reads "New recording" rather than "Untitled" on screen,
though the string stored on disk is unchanged.

### The microphone Listen records from is the one you chose

An hour of a call was captured with the laptop lid shut: macOS had switched
the built-in microphone off, and Listen followed the system default onto it
anyway, filing 56,239,952 silent samples as a healthy one-speaker meeting with
nothing on screen to say so. Recording now drives the chosen microphone
directly instead of asking `AVAudioEngine` for the system default, moves off a
device that has never been heard from mid-meeting, and a dedicated recording
screen shows one lane per track instead of three empty tabs, so a track that
never started is visible while it still matters. A finished recording that
captured no voice says that on its row.

### Worth knowing

- **The installed `listen` command can transcribe again.** Running it from
  `~/.local/bin`, which is what the Developers pane itself tells you to do,
  died with "Failed to load the default metallib" on every call that needed
  the model. It now re-execs the real binary inside the app bundle first.
- **Installing an update no longer kills the iPhone sync agent.** An
  unanchored process match took down `listen-sync serve` on every install,
  because the sync agent carries the app's path as an argument, not as its own
  identity. That could strand a phone's sync mid-upload until the app was
  force quit.
- The sentence edit field opens at the height of the whole sentence instead of
  showing its last line with the rest scrolled out of sight.
- The notes placeholder no longer lingers over an empty pane after a live
  recording, whose mode it belongs to, is stopped.

## 0.9.0 (2026-08-08)

### Setup could not download a model, and did not say so

Reported as "for some reason I can't download it", and then "nope" to whether
any error had appeared. That second answer was the accurate one: nothing
appeared.

Pressing Download did start the fetch. About half a second later the button
went back to reading "Download Parakeet v3 (2.51 GB)", because the setup pane
repaints on a timer and put the old title back, so a download that was running
looked like a press that had done nothing. Pressing again started a second
fetch over the same directory. Two fetches clearing and repopulating one cache
is how that Mac ended up being told `Key decoder.prediction.embed.weight not
found in ParakeetModel`, which is what mlx-swift says when the weights it wants
are not all there.

The step now has a progress bar and a line saying what it is doing, for the
whole of the download rather than for the first moment of it. The model buttons
are disabled while bytes are arriving, so switching cannot leave 2.5 GB coming
for a model nobody wants any more.

Continue no longer trusts the size of a directory. It used to, which meant that
after a failed attempt left something roughly the right size behind, pressing
Try again walked straight past the model step to "You are set" holding a model
that had just refused to load. Continue now loads the weights before moving on:
a second or two from a warm cache, and the only check worth anything, because a
directory of the right size still has to parse.

A copy short of the measured size is deleted before a retry rather than
accepted. A copy that is the right size and still will not load is replaced,
but only after it has failed once and only when you press the button again.
Throwing away 2.5 GB is not something to do on a hunch.

If a broken copy is already on disk from before this release, transcribing now
stops and says what is wrong and which button replaces it, instead of producing
an empty transcript. MLX reads the missing part of a short file as zeros
without complaining, so that failure had no other symptom.

### Pair an iPhone with this Mac

Settings has a Devices pane. It shows a QR code carrying the pairing key and
this Mac's address, so there is nothing to type on the phone, and under it the
phones that have connected, each with when it was last seen. There is a "Copy
the code instead" button for when pointing a camera at the screen is not
convenient.

Whoever scans that code can read every transcript in this library. Treat it the
way you would treat the screen it is on.

Removing a device stops this Mac answering it. It does not reach into the phone
to delete what already synced, and the pane says so rather than leaving you to
assume either way. "Forget every device and start again" rotates the key and
clears the list with it, because a list of phones that survived a key change is
a list of phones that cannot connect, which is worse than an empty one: it looks
like they still can.

**Listen does not do the sync itself, and this release does not ship the parts
that do.** A separate helper called `listen-sync` serves the library on your
local network as a LaunchAgent, and it lives in another repository under
another licence; the phone app is separate again. Until the helper is installed
on this Mac there is nothing for a phone to pair with, and the pane explains
that instead of showing an empty list that reads as a bug. What shipped here is
the Mac's half of the pairing.

### The window notices what arrives while you are looking at it

The library list re-reads every 3 seconds while the window is visible, and the
Devices list every 2. Both used to be read when they were built and again when
you came back to the app, which was enough when the only other writer was a
second Mac syncing a folder in the background. A phone is different: you are
holding it and watching this window at the same time, and a recording that
arrived and transcribed a minute ago while the list sat still reads as a sync
that did not work.

Only while the window is visible. A poll behind a closed window is work nobody
asked for.

### Worth knowing

- **The "Showing only X" bar has stopped appearing on memos.** Narrowing a
  transcript to the only speaker in it hides nothing and explains nothing, and
  every recording with one voice was getting a bar announcing that all of the
  transcript was visible.

## 0.8.0 (2026-08-07)

### Meetings recorded in a room

Until now Listen assumed every recording was a call: the microphone is you, the
system track is everyone else. Put the laptop on the table in a meeting room and
that assumption files four people under your name, with nothing on screen
suggesting anything went wrong. Reported from a 47-minute workshop whose
transcript read "speakers: Me".

Listen now works out which kind of recording it has, from the recording itself:
nothing was on a call, and nothing sustained came out of the speakers, so nobody
was remote, so the microphone is carrying the room. It then separates the people
around the table the way it separates a call. That workshop re-transcribes as
five voices across 180 turns instead of one.

One voice on the microphone is still just you, so a recording made alone at a
desk is unchanged, and so is every call.

The one case it cannot decide is the meeting that is half in the room and half
on a call, because a system track with speech in it looks the same either way.
Right-click the recording and tick **Recorded in the Room**; it offers to
transcribe again, which is when who said what is decided. `listen transcribe
<id> --room` is the same thing from the terminal, and `listen show` prints which
way a recording was read.

### Listen now knows what you sound like

Your own voice was the one thing the voice bank could not recognise. Nothing
ever clustered the microphone track, so `Me` was a label with no voiceprint
behind it, while every other participant had one.

Calls now file one. A room recording is what needs it: the people around a table
arrive as Speaker A and Speaker B, and a stored voiceprint is what lets Listen
say which of them is you without asking. It takes one transcribed call to
learn, so the first room meeting after updating will still ask. `listen enroll
<id>` takes the print from a call you already have.

### Worth knowing

- **A short clip will not separate.** Two people in 17 seconds came back as one
  voice: that is too little audio for the clustering model, and the exchange
  also arrived as a single sentence with nothing to cut between. Speaker
  labelling is still per sentence rather than per word.
- **Existing recordings are not re-read.** The decision is made while a
  transcript is built, so a meeting already transcribed keeps the speakers it
  has until you transcribe it again.
- **A silent system track is no longer transcribed.** An in-person meeting
  leaves an hour of an idle Mac on that track, and running the speech model over
  it could invent a participant who was never in the room.
- Two fixes found on the way: renaming a recording while it was transcribing had
  the old name written back at the end, and a recording made before Listen
  stored which app a call was in could be misread as a room.

## 0.7.0 (2026-08-07)

### The recording panel can be put away

The panel that floats in the top right corner for the length of a meeting now
carries a minus button after Stop. Pressing it hides the panel and does nothing
else: the recording carries on, and the menu bar icon still says so.

That corner is also where a screen share tends to put the thing somebody is
pointing at, and until now the only way to clear it was to stop recording.

It comes back two ways. The menu bar grows a "Show Recording Panel" row under
Stop Recording while the panel is hidden, and the next recording starts with the
panel visible again: hiding it applies to the meeting you are in, not to every
meeting after it. That is deliberate. A recorder running with nothing on screen
is only acceptable when somebody asked for it this time.

The one thing it will not hide is the question. When Listen has started
recording because it detected a call and is asking whether you are in a meeting,
the panel stays and the minus is not there, because that answer decides whether
the recording is kept and the panel is the only place to give it.

## 0.6.0 (2026-08-07)

### Words are no longer lost or doubled where the transcript is stitched

Long recordings are transcribed in pieces, and every release until this one cut
those pieces at a fixed number of seconds, which usually means cutting through
the middle of a word. Listen now slides each boundary back up to ten seconds to
the quietest 200 ms it can find, so a seam falls in a pause and the pieces need
no overlap and no merging.

Measured against 0.5.0 on a track of 300 numbered sentences at the same piece
length: 56 sentences missing and 50 transcribed twice, against nothing missing
and nothing duplicated. The known limitation carried since 0.1.0, about six
corrupted words an hour on a large Mac and about 33 on a small one, is what this
removes.

It is also faster. Decode cost grows sharply with the length of a piece, so once
a seam is free the reason to use a long one goes with it: every Mac now uses 120
second pieces, three at a time, which on a 3643 second recording is about twice
as fast as the 600 second pieces it replaces.

### A transcription in progress shows the meeting being read

The pane drew a spinner. It now draws the recording's own waveform in two lanes,
everybody else above and you below, each filling as its pass decodes. The
boundary is where the reading has got to, to the bar.

There is no time estimate anywhere, deliberately. A throughput figure measured on
one machine is a promise another cannot keep, so it counts pieces done out of
pieces to do and says nothing it cannot know.

### The speech model belongs to the recording

Transcribe Again is a submenu now: Parakeet v2 or v3, per recording, recorded in
the recording's own metadata rather than read from a setting that has since
changed. Re-transcribing discards hand corrections, so it asks first, which it
did not before.

Worth knowing before you re-run an old import: v3 handles more languages, v2 is
English only, and an imported recording transcribed elsewhere may have been in
neither.

### Voices are matched against everything known about a person

A suggestion used to be scored against the single best recording of somebody's
voice, which is only as good as that one recording. It is now scored against the
average of all of them. Measured leave-one-out over this library: the same
person scores +0.642 to +0.914 and different people up to +0.371, a wider gap
than the numbers it replaces, which had scored a correct match at +0.603 because
the one labelled recording of that voice was the least representative of five.

The percentage is gone. It was a similarity score times a hundred on a scale
whose whole useful range is 0.37 to 0.91, so a correct match displayed as "60%
match" and read as a coin flip. It says how sure it is in words instead, and
names the runner-up only when the margin is genuinely narrow.

When a voice clears +0.75 and beats second place by +0.15, Listen names it
without asking. At that cutoff 85% of true matches land and no wrong pair scores
above it. Three things keep that safe: an automatic name is never used as
evidence for the next one, so a mistake cannot spread; it is marked as automatic
in the recording's metadata and in `listen show`; and `listen voices` prints the
ranking, the margins and the thresholds, because a name applied without being
asked has to leave something to argue with.

### Hear a speaker before you name them

The picker asked "who is this" and offered only inference: how long they spoke,
what the voice bank thinks, who was on the invitation. It now has a Play button.
Two seconds of the voice settles what all of that is circling, and it plays
through the pane's own player, so the playhead moves and the transcript scrolls
to them.

Asking about somebody narrows the transcript to their turns, for exactly as long
as the asking lasts: close the popover, by dismissing it or by naming them, and
the whole meeting is back. The waveform greys everybody else at the same time,
across the whole recording rather than only the part already played, which is
how you find a quiet participant. This library holds a 97 minute call where one
speaker talks for 0.0 minutes and another for 0.1, and both were on screen and
invisible before this.

You can also answer "that is me" from the picker on an imported recording, which
has no microphone track to merge yourself into and so had no way to say it.

### The recordings still waiting on a name

A row above the sidebar list counts them, and is gone entirely when the count is
zero. Clicking it shows those recordings; View > Recordings Needing a Speaker
(⌘U) asks the same question when the row is not there to ask it from.

It is a count of what is actually in the transcripts rather than of what the
metadata claims, and those disagree: over the 31 transcribed recordings here the
stored state says 17 where the truth is 13, in both directions, because it is
only written by the window and half this library was labelled by a pipeline that
never touched it.

### Settings is in the title bar, and the sidebar drags again

The gear sits at the top of the sidebar next to the control that collapses it,
in all three collections, and the Settings row at the bottom of every list is
gone: the lists run to the bottom edge now. Settings itself takes the same
shape, its name where the app's name goes and the way back at the top right.

The sidebar could not be resized at all in Recordings, and could be in People
and Notes. That was a constraint belonging to the transcription picture above,
which is hidden almost all the time and was quietly holding the content pane at
exactly 700 points and the window between 799 and 1168. Both drag freely now,
between 298 and 468 points of sidebar.

### Still true

Speaker labelling is per sentence rather than per word, so two people talking
over each other inside one sentence come out as one speaker. Meeting detection
is on by default: it starts recording, then asks on screen, and answering no
deletes the audio straight away. Diarization runs on the system audio track
only, because your own track is you by definition.

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
