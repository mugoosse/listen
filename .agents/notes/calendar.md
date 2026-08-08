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
