# Calendar and the contact book

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments explain why, thresholds say where the number came from, and no em dashes. -->

How a recording gets a name and a guest list. Read this before touching `MeetingCalendar`, `CalendarEvent`, `ContactBook` or `MeetingLink`.

## The calendar needs no account, because macOS already has one

Anarlog supports three providers two ways. Apple Calendar is local EventKit and
works signed out. **Google and Outlook are neither**: OAuth is brokered by
Nango, a hosted third party (`apps/web/netlify/edge-functions/oauth-callback.ts`
is a 308 to `api.nango.dev`), the tokens live at Nango and never on the Mac, and
every read is proxied through Anarlog's own axum API behind a Supabase JWT
(`crates/api-calendar/src/google/routes.rs`) and gated on Pro billing. That is
an account, a backend, an OAuth client and a billing system for the privilege of
reading a calendar.

Listen needs none of it, because **macOS did the OAuth already**. An account
added in System Settings, Internet Accounts syncs into the system calendar
store, and EventKit hands it over with no distinction from iCloud. Measured on
the development machine: 16 calendars, including two separate Google accounts
arriving as calDAV, with attendee addresses and organizers on the events. One
TCC prompt, no network connection, and therefore no new entry in
`InternetAccessPolicy.plist`.

What is actually given up is one thing: somebody who has not added their work
account to macOS. The Permissions pane says where to do that. Server-side push
and sync tokens are given up too and replaced by `EKEventStoreChangedNotification`,
which is the better shape for a local app anyway.

`MeetingCalendar` is read-only and has no write path at all, deliberately: the
one thing worse than not naming a recording is editing somebody's calendar.

### Ten minutes, and the measurement that fixed it there

`MeetingCalendar.window` is 10 minutes, anchored on the **start** of the
recording rather than on overlap. Measured over the 47 recordings then in the
library, where `named` counts the seven somebody had titled by hand:

| window | matched | named | ambiguous |
|---|---|---|---|
| 5m | 9/47 | 3/7 | 1 |
| 10m | 14/47 | 6/7 | 2 |
| 15m | 14/47 | 6/7 | 2 |
| 20m | 14/47 | 6/7 | 2 |
| 30m | 16/47 | 6/7 | 4 |

Ten, fifteen and twenty are identical, so the widest of them buys nothing.
Thirty buys two matches and **both are wrong**: a WhatsApp call matched a solo
calendar block 26 minutes away called "Review the Q3 launch Reel".
Since the title is applied without asking, wrong is the expensive direction.

Anchored on the start because overlap is not evidence of anything on a Mac that
is switched on all day.

### Joining early is not in that table, and it is what a link invites

Every offset in the measurement above is between -9 and +0 minutes, so the
sample contains nobody who opened the invitation's Meet link well before the
meeting. That is not because it is rare. A real recording: link opened at 17:19,
detection started capture there, the calendar said 17:45. Twenty-six minutes, so
the window missed it by sixteen and the meeting stayed "Untitled" with no guest
list and therefore no speaker suggestions either.

`MeetingCalendar.candidates` now has a second rule: a meeting that **began while
the recording was running**. Three things about it are load-bearing:

1. **It is asymmetric, and that is the whole safety argument.** "The recording
   overlaps the event" would also match a recording that started inside somebody's
   hour-long focus block, which is exactly the wrong match the 30m row bought.
   This rule claims something much narrower: capture was already running at the
   minute the invitation said the meeting would start.
2. **It can only add a match, never change one.** Anything it finds is by
   definition further than `window` from the recording's start, so it sorts
   behind every first-rule candidate and the winner of a non-empty first rule is
   untouched. The fourteen above are still those fourteen.
3. **Somebody else has to be on the invitation.** It reaches as far as the
   recording is long, which on an 80 minute meeting is well past the 30 minutes
   already measured as too wide, so it wants a second piece of evidence that this
   is a meeting rather than a block. Measured over the 42 recordings now in the
   library: with and without that check the rule finds the **same one match**, so
   today it costs nothing and it bounds the looser rule.

Measured after: 15/42 matched, the fourteenth-plus-one being the recording this
was written for. `listen calendar match` and `backfill` both print
`[began while recording]` on anything the second rule found, because a match
26 minutes out is otherwise impossible to reconcile with a documented window of
ten.

`Capture.stop()` writes `metadata.duration` **before** it asks the calendar
again. The recording's span is the whole of the second rule and it is zero until
that line runs, so attaching first judges a 33 minute recording as though it had
lasted an instant. The attempt at `start()` still has a zero span, deliberately:
capture has no length yet, so only the window rule applies there.

### The title is applied silently, and two guards are what make that safe

`MeetingCalendar.attach` writes the title only when
`Recording.mayTitle(from: .calendar)`, and `Metadata.calendar_event_id` doubles
as the "already looked" flag so a second pass can never revisit a decision.
`Capture` calls it twice: at `start`, so the live sidebar row carries the
meeting's name for the hour it is running rather than saying "Untitled"
throughout, and again at `stop` for the meeting that was put in the calendar
after it began. The second call is a no-op whenever the first one found
something, which is what protects a title edited mid-call.

That guard used to be `Recording.isUntitled`, and the consequence surfaced
immediately: `listen calendar backfill` matched 14 of the 50 recordings in the
real library and renamed **none of them**, because every one already carried a
title from the legacy Python import (`2607-17-Google Chrome` and the like). That
is still the right answer, and `mayTitle` still gives it. Deciding which existing
titles are "really" machine-generated would be a heuristic, and a heuristic that
overwrites a meeting's name is the thing this design is avoiding. New recordings
start as `Untitled` and are named; imported ones keep what they have and gain a
guest list.

**What changed is that one bit could not answer the question any more.**
`isUntitled` says "has this a name", which is enough while the calendar is the
only automatic titler and is exactly why `DetailView` records that naming a
recording after its app "would break calendar naming outright": any second
writer puts a string here and locks the calendar out for ever. `AutoTitle` is
that second writer, so the answer moved to `Metadata.title_source`, and
`mayTitle` reads it. See `.agents/notes/titles.md`. The rule that matters here:
a calendar title outranks a derived one, so a backfill finding the invitation
months later correctly replaces "Call with Céline", and a typed title has no
source at all, which is what freezes it.

Anything asking "will the calendar name this" has to ask `mayTitle` and not
reimplement it. The backfill preview did not, for one build: it still read
`isUntitled`, so a recording carrying a derived title printed as "keeps its
name" and was then renamed by the next line. A dry run that disagrees with the
apply is worse than no dry run, because it is the thing somebody reads before
saying yes. `verify_title.sh` asserts the two agree.

`backfill` is a dry run without `--apply`, and is deliberately not something
that happens at launch. Renaming fourteen recordings at once without being asked
is the surprise the rest of this app avoids.

### The meeting link is in the notes, not in `event.url`

Measured: `event.url` was nil on **every** Google event on this machine, and the
Meet or Zoom link sat in the notes body. `MeetingLink` therefore searches the
notes and the location, with a bare `https?://` fallback after the known
patterns, which is Anarlog's `parse_meeting_link` and the same argument
`MeetingDetector` makes for not matching on a list of bundle identifiers.

### An attendee's name is usually their email address

The number that shaped the whole speaker-suggestion design. Over 72 events with
attendees on this machine:

    attendee entries  140
      human name       22
      email as name   118
      no name at all    0
      no mailto url    34
    organizers with a human name  32/72

So every entry yields either a name or an address and never nothing, and the
address is the reliable half. There is no public email property on
`EKParticipant`: it is `participant.url` with a `mailto:` scheme, which is also
where Anarlog reads it.

Two more things a real invitation did that the first version got wrong, both
fixed in `CalendarEvent.init`:

1. **The same person arrives more than once.** One event returned Ryan as
   organizer with no address, again as an attendee with no address, and a third
   time under a work address. Deduplication keys on the address when there is
   one and the name otherwise, which deliberately keeps two *different*
   addresses apart: whether a personal and a work address are one human is
   exactly the question the contact book exists to let somebody answer once.
2. **An entry with no name and no address at all**, which became a button
   reading "(unnamed)". Dropped.

### `bestName` read the snapshot before the book, so a rename never reached it

`calendar_people` is frozen at the minute the recording was matched, on purpose:
an event can be edited or deleted and the library has to keep answering. The
contact book is the opposite, the one place a human has said which person an
address belongs to, and `People.rename` moves the entry with the name. So the
book has to be asked **first**, and it was asked last.

The symptom is a name that has been correct everywhere else for days. Rename
Justadecisionpod to Joshua Daniels, every transcript is rewritten, the chips say
Joshua Daniels, and the speaker picker's In the invitation row still offers
Justadecisionpod, which if picked recreates the person who was just renamed.
Reported that way round, and reproducible: the snapshot on disk holds only
`justadecisionpod@gmail.com` with no name at all, so `bestName` fell through to
`ContactBook.suggestedName`, whose whole job is deriving a word from an address.

Order is now book, then the calendar's own name field, then `suggestedName`,
which stays last because it is the weakest by construction. The comment in
`SpeakerSheet` had said "the contact book first" since before any of this; it
was describing the intent rather than the code. Verified with
`listen calendar match`, which now prints `Joshua Daniels
<justadecisionpod@gmail.com>` for the same recording.

### The contact book is a second route to the identity Listen already has

`ContactBook` maps addresses to the label written in transcripts, **many
addresses per person**, which is the whole point: the same human is
`ryan@example.org` on one invitation and `ryan.mitchell@example.com` on the next.
It is not the macOS Contacts framework, which would cost a second TCC prompt and
can only find people already in the address book, which the far side of a work
meeting usually is not.

It is written **only when a human asserts something**. Picking a suggestion in
`SpeakerSheet` asserts which attendee this speaker is; typing a name freehand
asserts nothing and links nothing. Same standard as `People`: two recordings
hold the same person when somebody said so, not when a score agreed.

The pick stores the **address** and the field supplies the **name**, and keeping
them apart is what makes correcting a guess useful rather than destructive:
picking "Byjenna0x" and typing "Jenna" over it files that address under Jenna.

`People.rename` calls `ContactBook.rename`, and it has to. The book is keyed on
the transcript label, so without it a renamed person's addresses point at a name
nobody has any more and **nothing reports it**: the suggestions simply stop
appearing, which reads as the calendar having broken rather than as a stale key.
Verified with a round-trip rename on a real recording.

`ContactBook.suggestedName` is the weakest of the three sources and never
applied on its own: `emily.carter@` gives "Emily Carter",
`ryanmitchell@` gives "Ryanmitchell", and role addresses (`noreply`, `info`,
`updates`) return nil rather than becoming a person, because a book that learns
those starts suggesting them for real speakers.

### One `EKEventStore`, and every read behind a lock

Anarlog ships a standalone reproducer for this
(`crates/apple-calendar/examples/repro_empty_calendars.rs`): concurrent event
and calendar reads make `list_calendars` return **zero**, which raises no error
and is indistinguishable from a Mac with no calendars on it. `MeetingCalendar`
keeps one store for the process and serializes every read through an `NSLock`.
Listen does not currently read concurrently, but that is a property of today's
callers rather than of the file, and the bug leaves nothing behind to debug
from.

The store is `internal` and not private for a related reason:
`Permissions.requestCalendar` must ask on **this** store. A grant landing on a
different instance leaves this one answering from the access it was created
with, and every read afterwards returns nothing.

### Optional fields do not need a hand-written `init(from:)`

The trap recorded against `StoredTranscript` above is that Swift's synthesized
decoder throws `keyNotFound` on a missing key *even when the property has a
default value*. It does **not** apply to `Optional` properties: those are
decoded with `decodeIfPresent`, so `Metadata.calendar_event_id` and
`calendar_people` could be added without touching the memberwise init and every
`metadata.json` written before them still reads. Verified with `listen list`
over all 50 recordings rather than assumed. If either field ever becomes
non-optional with a default, that stops being true.

### Onboarding has to ask, because nothing else will

The Settings pane is the **only** other place the calendar prompt can be raised
from, because macOS lists an app under Privacy, Calendars only once it has
requested. So without a setup step, anybody who never opens Settings never gets
asked and the feature is silently off for them, which is the same shape as the
installed CLI that is not on the `PATH`: present, and unreachable.

It sits between `systemAudio` and `model`, and its second button says "Not now"
rather than "Skip". Skip is what the microphone step offers, where declining
costs half of every recording; here it costs a name, and the wording should not
imply the two are the same.

`structuralKey()` had to gain `Permissions.calendar`. The prompt is answered
outside the window, there is no notification for it, and the 0.8 second poll
only re-renders when that string changes, so leaving it out means the pane goes
on saying "not granted yet" after the grant has landed.

The `done` pane mentions calendar naming **only when access was granted**. It is
there for the same reason the detection sentence is, because it happens without
being asked each time, and saying it to somebody who declined would be noise
about a feature they do not have.

### `listen calendar` exists because matching leaves nothing behind

Same argument as `listen sources`. The title lands silently, so "why is my
meeting called that?" is otherwise unanswerable: the candidate that won, the
ones that lost, and the window they were judged in are all gone by the time
anybody looks. `listen calendar match <id>` prints all three, with the offset in
minutes per candidate, and it is what showed that two calendars on this machine
hold the same 15:00 meeting under different names ("Cowork Ryan" in Google,
"Kinsight: Ryan x Emily" in iCloud). Both tie at -1m, so the guest-list
tie-break decides, and which one wins is genuinely arbitrary. That is worth
knowing about rather than discovering through a title.

`backfill --refresh` re-reads a recording that is already attached, and only the
CLI passes it. The automatic path must not: a guest list that has already been
picked from is a decision, and replacing it with whatever the invitation says
today would quietly undo one.

## What is about to happen

The section at the top of the library, the page it opens, and the preparation
that outlives it. `MeetingCalendar.upcoming`, `EventTime`, `MeetingBrief`,
`EventCell`, `UpcomingPane`, `Sidebar.appendUpcoming`, `Chat.adopt`,
`listen calendar next`.

**Most of this lives in `ListenKit/Calendar.swift` now**, because the iPhone
grew the same feature and a rule with a measurement behind it is written once.
What stayed in `Sources/listen/MeetingCalendar.swift` is everything about a
*recording*: the ten minute window, the rule for a meeting that began while
capture ran, and the guarded write of a title and a guest list into
`metadata.json`. The phone does none of that. See "The phone lists the same
meetings" below.

Everything above this heading is about a meeting that has already happened.
This is the one part of the app that is not, and almost every rule here follows
from that: there is no folder, so nothing can be saved, corrected or deleted,
and the only durable thing anybody can do from the page is ask a question. That
is also why the conversation carries `Chat.event`.

### The list is a timeline, and this is the end of it that is still ahead

Not a fourth collection. There is no `kind:` for it, nothing searches it, and
it is gone the moment anything is typed in the field, because a search is a
question about what was said and none of this has been said yet. The same is
true of every lens: a section that survived `tag:kinsight` would be three rows
the filter had not considered sitting above the rows it had.

`sectionsByKind` already makes the same statement with its headings, which name
kinds while something is typed and days while nothing is, so `appendUpcoming`
tests the query, the lenses and the kind and returns on any of them.

### One filter, a vocabulary, and a cap

`couldBeAMeeting` is what keeps Birthdays, Holidays and every subscribed feed
out without anybody configuring a calendar, because they are all all-day. It
already existed for matching.

**The guest test was the second filter, and it was wrong here.** It was
`beganDuring`'s, hoisted as `hasGuests`: somebody other than you had to be
invited, on the evidence of the one wrong match this app has ever measured, a
solo block called "Review the Q3 launch Reel" that a thirty minute window
matched to a WhatsApp call.

That evidence is about **naming a recording**, which `attach` does without
asking, and it still holds there and is untouched. A row in a list is not a
title: nothing is renamed by showing one. Reported the first evening this
shipped, on a real event, "Test with Dani" at 22:00 typed into the user's own
calendar with nobody invited, which is how most in-person meetings and every
held hour are entered. Hiding those was the expensive direction.

So `MeetingKind` replaced the yes-or-no: a `call` has guests and a link, an
`inPerson` has guests and nowhere to click, a `blocked` has nobody else in it.
Both apps list all three; the type is what lets a row say which it is, and what
lets either app change its mind without the other one guessing.

The cap is the third rule and the point of it is not performance. This sits
above the library, and a nine-meeting day would push every recording somebody
owns off the screen to say what is coming instead.

### Twelve hours forward and fifteen minutes back

`horizon` is 12 hours, not "the rest of today", which is the obvious rule and is
wrong twice a day: at 18:00 it says the calendar is empty when tomorrow starts
at 09:00, and by 23:00 it has been saying so for five hours. Twelve covers an
evening from the morning it belongs to and never reaches the day after
tomorrow.

`lateness` is 15 minutes, and it is not the length of the event. A meeting you
are five minutes late for is the one you most want the row for, because the
link is on it; a two hour block that began at nine would otherwise sit at the
top of the library until eleven, which is a calendar rather than a heads-up.
The row says "now" for the whole of that window: counting upwards ("12 min ago")
is a reproach rather than a fact.

### Faces rather than a comma list, and they are at the trailing edge

The row's second line was `in 12 min · Ryan Mitchell, Emily Chen`, which
truncates at the second name in a 280 point sidebar: the row spent its whole
subtitle saying half of something. It carries `InitialsDisc`es now, up to three
with a `+N` after them, and the second line is the countdown alone.

**The same disc, not a second one drawn to match.** `SpeakerColour` is a
function of the name, so a guest who has never been recorded already has the
colour they will have the moment they are: the face on an invitation and the
chip on the transcript of that meeting are the same mark. It also costs nothing
to build, which is what makes it affordable on a table cell: no roster, no
library read, one hash per name.

**Trailing, which is not where a face wants to go.** The leading column is 16
points at an inset of 8 and every title in this list starts after it;
`RecordingCell.icon` records that a cell inventing its own width there lands two
points off every other label, which reads as a mistake rather than as a margin.
Faces are wider than a glyph at any legible size (initials are drawn at 0.4 of
the diameter, so a 16 point disc puts two letters in six points and becomes a
coloured dot), so they went to the other end, which is where a calendar puts
them anyway.

Nothing is lost by dropping the names: they are in the tool tip, on the page,
and in the cell's accessibility label, which is what a reader who cannot see a
coloured circle gets and what `verify_upcoming.sh` asserts on.

### The meeting being recorded must not be in both halves of the list

`Capture` attaches the recording to its event at `start`, so from that moment
the same meeting is the live row pinned at the top of the library *and* an event
that has just begun. One of those is a recording somebody can stop and the other
is an invitation.

The exclusion is the sidebar's rather than `MeetingCalendar`'s, deliberately:
the event is still upcoming by every rule in that file, and the row is only a
duplicate because of what is drawn beside it. `upcoming()` therefore does not
consult `Capture` at all, and `listen calendar next` shows the same list the
sidebar would.

### A calendar list is the first thing here that goes stale on its own

Nothing in this app observed `EKEventStoreChangedNotification` before, because
everything that read the calendar read it once, when a recording started, and
answered a question about that instant. A list of what is coming up is wrong the
second somebody moves a meeting in Calendar, and there is no polling interval
short enough to hide that which anybody would defend.

So `MeetingCalendar.onChange` exists, and the sidebar also ticks once a minute,
which is the unit the row is written in. A row can therefore be up to a minute
stale and read "in 12 min" through the last seconds of the thirteenth; the row
that matters most is the one saying "now", and that one is right either way.

`tickUpcoming` answers in two ways for `tickRow`'s reason: a reload every minute
would cancel a drag, fight the scroller and rebuild every cell in the library to
advance one number. Same ids means redraw those cells in place. A different list
means reload.

### An unauthorized Mac and a clear afternoon are the same empty list

`MeetingCalendar.upcoming` opens with `guard isAuthorized else { return [] }`,
which is right for a sidebar section that simply does not appear. It is wrong
for a tool. `list_upcoming` returning only an array would have an agent tell
somebody their day is free when Listen cannot see the calendar at all, and the
user has no way to tell those apart from the answer.

So the tool returns `authorized` beside the events, `get_event` refuses with
"this is a permission, not an empty calendar", and the description tells the
model to check the field before reporting nothing. The horizon and the lateness
come back too, so twelve hours ahead is stated rather than implied by an answer
that stops there.

**The branch cannot be reached from a shell.** A binary started from a terminal
is not the TCC subject, the terminal is, so `Listen.app/Contents/MacOS/Listen`
and a copy under a fresh bundle identifier both answer with whatever the
terminal was granted. `verify_mcp.sh` tries the copy and skips saying so. It is
reachable where the responsible process genuinely lacks the permission, which is
the app itself and a client such as Claude Desktop spawning `listen mcp`, and
that is exactly the population the field exists for.

## A meeting being recorded is marked on the list, not dropped from it

The sidebar excludes the live meeting because it shows the recording immediately
above it, and one meeting in two places is a wrong answer twice. A tool has no
second place. `list_upcoming` therefore carries `recording_id` on any event the
library already holds a recording of, built once from `Recording.all()` for the
whole list rather than per row, and "this is the meeting you are in, and here is
its id" is strictly more use to an agent than an event silently missing.

## The agent has no calendar, so the invitation travels in the question

It reaches the library through `listen mcp` and that is all. There is no
calendar tool and there should not be one: an upcoming meeting is a handful of
strings, and a tool that returns them is a tool the model has to be told to call
before it can answer the only question this page asks.

`MeetingBrief.invitation` is that paragraph. Two things in it are load-bearing:

1. **It says the meeting has not happened.** Without that clause the first move
   is a search for a transcript of this meeting, which cannot be there, and the
   honest report of that search is "I cannot find this meeting". One clause
   buys back a round trip and a wrong answer.
2. **The guests are named by `bestName`, with their addresses.** That asks the
   contact book first, so a guest whose invitation says
   `justadecisionpod@gmail.com` is named as whoever the user has said that
   address is, which is the string `list_people` and `get_person_context`
   actually answer to. The address goes too, because it is the reliable half.

### The agenda is one or two lines followed by twelve of dial-in

Measured on this machine's own calendar, which is the same measurement that put
the meeting link in the notes rather than in `event.url`: a Google invitation's
body is the agenda, then the join instructions, a phone number, a PIN and a
help link. `MeetingBrief.trimmedAgenda` cuts at the first boilerplate line and
caps what is left at 600 characters.

Prefixes rather than a regular expression, because the strings are fixed and
each provider writes the same opener every time. The one thing that must not
happen is a heuristic eating somebody's actual agenda.

`CalendarEvent.agenda` is read into memory and **never** snapshotted into
`metadata.json`, unlike `calendar_people`. The guest list is stored beside the
recording because the library has to keep answering after the event is edited or
deleted; the agenda is only useful before, and by the time there is a recording
the transcript is a better copy of what was discussed. It also keeps somebody
else's invitation body out of a file this app syncs.

### Prepare is a button, because a chip that waits for the caret is not enough

`AskView.drawStarters` only draws the chips once the field has focus, and that
rule is right where it was written: on a meeting page four unbacked chips lay on
the transcript with its text running through them, because the drawer draws no
panel until it has something to hold.

An upcoming meeting's page is the one screen whose entire reason to exist is the
question, so the first chip's prompt is also a button in its header, and the same
prompt is in the Actions menu. All three go through `AskView.ask(question:)`, so
a press with no agent configured raises the setup card rather than silently
doing nothing.

The composer needed nothing else: it belongs to the window, so it is already
under the page. What it needed was a fourth subject beside `recording`, `person`
and the library.

### Preparation that cannot be found afterwards is preparation nobody does twice

`Chat.event` holds the iCal UID, which is what `Metadata.calendar_event_id`
holds. `MeetingCalendar.attach` is the one moment anything knows a folder and an
invitation are the same meeting, and `Chat.adopt` is what it spends that on: the
recording id is appended to the conversation's `recordings`, so the back links
on the meeting page, the Chats tab's count and `Chat.about` all work with no new
query and no second index.

`touch: false`, so adopting does not reorder History. The conversation was last
spoken to before the meeting, and that is when it was last spoken to.

Idempotent, because `attach` runs twice for one recording (at `start`, and again
at `stop` for a meeting put in the calendar after it began) and because
`backfill --refresh` runs it again by hand.

### `LISTEN_FAKE_EVENTS`, because nobody will hold a meeting to test a list

Same argument as `LISTEN_FAKE_CALLERS` and `LISTEN_TAP_TEAR`. It stands in for
the calendar entirely, permission included, because a fixture is only useful if
it answers the question the real store would on a machine that has never been
asked for access.

Starts are written as **minutes from now** rather than as dates. Every claim
worth asserting here is relative ("in 12 min", listed at five minutes late and
gone at twenty), and a fixture with wall-clock times in it is one that passes
until midnight. `verify_upcoming.sh` is what uses it.

### `listen calendar next` reads two hours back, and the list reads fifteen minutes

The command prints the section and then everything nearby that did not make it,
with the rule that dropped each one, for the reason `listen calendar match`
exists: three rules quietly remove meetings and "where is my three o'clock?" is
otherwise unanswerable.

It sweeps two hours back rather than `lateness`, and the first version did not.
A meeting that began twenty minutes ago has just fallen off the list and is the
single most likely thing somebody is running this command to ask about; reading
the same window the list reads meant never seeing it, so the answer to that
question was silence. Found by `verify_upcoming.sh`, which is what it was
written for.

`--prompt` prints what pressing Prepare would send, which makes the window and
the CLI provably the same question:

```sh
listen ask "$(listen calendar next --prompt)"
```

### A store kept for hours answers from the cache the notification invalidated

`EKEventStoreChanged` says the store's cached objects are no longer valid, and
Apple's guidance is to reset the store when it arrives. Nothing here had ever
needed that: every previous read was one shot, in a process that had just
started, so a store that goes stale cost nothing. A library window left open
all day is the first thing in this app that keeps one for hours.

Without the reset the failure is silent and reads as the feature not working:
add a meeting in Calendar, the notification arrives, the sidebar re-reads, and
the answer is the list from before the meeting existed. `onChange` calls
`store.reset()` behind the same lock every read uses, because a reset racing a
read is the shape that returns zero calendars and reports nothing.

The minute poll deliberately does **not** reset. It is there for the clock on
the row, not to discover anything: EventKit posts this notification for
external changes including CalDAV syncs, so a poll that resets would be
throwing the cache away sixty times an hour to learn what it is told.

**Which is also the first thing to check when a new event does not appear, and
it is usually not this.** `listen calendar events --days 1` runs in a fresh
process with a fresh store, so it is the control: if the event is missing there
too, it is not in this Mac's store at all and no amount of refreshing in Listen
will find it. An event added on a phone or in a browser reaches the Mac when
macOS syncs the account, not when it is saved.

## The phone lists the same meetings

`ListenKit/Calendar.swift` is the shared half: `CalendarEvent`, `CalendarPerson`,
`MeetingLink`, `MeetingKind`, `EventTime`, `MeetingBrief`, and the reading half
of `MeetingCalendar` (the store, the lock, `events`, `upcoming`, `onChange`, the
fixtures). EventKit is the same framework on both platforms, so this is a move
rather than a port.

### The contact book is each app's, and it is a function

`CalendarPerson.bestName` has to ask the book first: `calendar_people` is a
snapshot frozen when a recording was matched, and the book is the one place a
human has said who an address belongs to. That is a rule with a bug behind it,
recorded above.

But the two books are not the same object. On the Mac it is `ContactBook`,
keyed on the transcript label and living beside the library; on the phone it is
`PersonDirectory` read against that device's own root. So the shared type asks a
function, `MeetingCalendar.knownName`, installed once at launch: `main.swift` on
the Mac, `AppModel.init` on the phone. Unset, `bestName` falls through to the
invitation's own name field and then to `PersonDirectory.suggestedName`, which
moved out of `ContactBook` for the same reason and is the only one of the three
that cannot be wrong about a person, because it derives a word from an address
rather than claiming to know somebody.

### The phone records a meeting; the Mac names a recording afterwards

Tapping a row on the phone arms `Recorder.meeting` and switches to the record
tab, which is what starts capture. Arming rather than writing afterwards is
deliberate: `stop()` builds `metadata.json` once and publishing it is the last
thing it does, so the name and `calendar_event_id` go in that same pass. Written
afterwards there would be a window in which a recording of a meeting is on disk
claiming to be a memo, which is exactly what every reader on both devices would
see if the app died in between.

The title carries `title_source: calendar` rather than `device`, which is the
top of the Mac's ladder: it will not be renamed after its speakers, and a
calendar backfill that finds the same invitation later agrees with it rather
than fighting it. A name typed over the invitation is a person's title and
freezes as one, as everywhere else.

**The arming is on disk before the audio is.** `Recorder.meeting` is process
state and `AGENTS.md` opens with the rule that the process does not last: iOS
evicts an app that has been switched away from, and coming back is a cold
launch. `adoptUnfinished` is what publishes a capture that never reached its own
`stop()`, and with the meeting only in memory it could call that recording
nothing but `Memo, 8 August, 12:08`, which is exactly the meeting somebody most
wanted named: the long one they walked away from. So `start()` writes a
`meeting.json` beside the audio, `adoptUnfinished` reads it, and both `stop()`
and the adoption take it away again, because a file no device knows how to read
should not be in a recording that is about to sync. It is a sidecar of its own
rather than a field in `metadata.json` for the reason that file exists: writing
it is what publishes a recording, and a folder is not a recording until its
audio has stopped arriving.

**`calendar_people` is deliberately not written by the phone.** The shared
`Metadata` does not declare it, and the comment there says why: it was declared
`[String]?` once, it is a list of objects on disk, and every meeting matched to a
calendar event silently disappeared from the phone. The phone writes the event
id, which is the field that exists; `listen calendar backfill --refresh` on the
Mac is what fills in the guest list for those recordings.

### The row is words and two buttons, and the words open the invitation

The row was one big button that started a recording, which is the one control in
this app that costs something to press by mistake and, on a phone, the easiest
thing on screen to press by mistake. It is three targets now: the words, a
sparkles button and a record button.

**The words open a sheet**, which is the phone's answer to the Mac's brief page.
Everything the two lines have no room for is in it: who is coming and what this
library already holds about each of them, the agenda with the dial-in cut off,
the meetings with those people, and the three verbs as equal capsules. It costs
nothing until somebody wants it, and the tap that opens it is the cheap,
reversible one.

**Sparkles is absent on a block**, because every question `MeetingBrief` sends
is about the people invited and a block has none. The same test hides Join and
the Invited section in the sheet, which says what a block is instead.

**Words, not `Label`s, on the sheet's three buttons.** Three sharing 402 points
is about 110 each and a symbol eats a third of that: measured, it wrapped
"Prepare" to "Pre-pare" and "Record" to "Reco rd". The width goes on the label
rather than outside the button, or the capsules are three different sizes
floating in equal spaces.

### What the phone still does not have

No matching: a recording made on the phone knows which meeting it is because
somebody tapped it, so there is nothing to infer. And no `calendar_people`, for
the reason above.
