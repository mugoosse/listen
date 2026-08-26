# What a recording is called

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments
explain why, thresholds say where the number came from, and no em dashes. -->

Read this before adding anything that writes `metadata.title`.
`Metadata.TitleSource`, `Recording.mayTitle`, `AutoTitle`, and the title half of
`MeetingCalendar.attach`. The calendar's own matching rules are in
`.agents/notes/calendar.md`.

## One bit could not hold two titlers

`Recording.isUntitled` was the whole guard for as long as the calendar was the
only thing that named a recording. It answers "has this a name", which is enough
to protect a name somebody typed and nothing else, and `DetailView` records what
it costs: naming a recording after the app it was in "would break calendar
naming outright", because the placeholder is gone and nothing can tell the app's
guess from a person's decision.

So the answer is `Metadata.title_source`, and it is the same split `auto_named`
and `room_auto` already make. An automatic decision must not be
indistinguishable from one a person made, and an inferred value is re-derived
while a chosen one is never re-decided.

- `nil` on a titled recording means **a person chose it**, and nothing
  automatic ever writes over it. `Recording.rename` clears the field
  unconditionally, so this needs no `user` case and cannot be forgotten.
- A value means **the app derived it**, and `Metadata.TitleSource` ranks the
  derivations: `people` < `model` < `calendar`. A source may write over one
  ranked below it, or refresh one of its own.
- `Untitled` is free for anything.

`Recording.mayTitle(from:)` is the one place that is decided. Reimplementing it
is what broke the `calendar backfill` preview for a build: it still asked
`isUntitled`, printed "keeps its name" for a recording carrying a derived title,
and then renamed it on the next line.

`model` has no writer yet. It is declared because the rank order is the thing
being designed and leaving a hole in it invites the next person to bolt a
generated title on at whatever rank happens to work that day.

## The placeholder is a key on disk and a word on screen

`Metadata.untitled` is `"Untitled"` and it is **not** what anybody reads. It is
the value `Recording.isUntitled` compares against, and `mayTitle` gates the
calendar and `AutoTitle` on that comparison, so it is an identity rather than
copy. Renaming it renames nothing already written: every recording carrying the
old string stops reading as unnamed, becomes indistinguishable from a title
somebody typed, and is never named automatically again. Silent, and only
findable by wondering why one recording refuses to get a title.

**It is also a required key**, which is worth knowing before writing a
`metadata.json` by hand. `Metadata.title` is a non-optional `String`, so a file
that simply omits it fails to decode and the recording disappears: measured by
deleting the key from a copy, `listen list` printed "no recordings yet" over a
folder holding four good sidecars, with nothing anywhere saying why. An untitled
recording is `"title": "Untitled"`, never a missing title. `verify_title.sh`
learned this the hard way when its fixtures were being reset to the untitled
shape.

What is shown is `Metadata.untitledDisplay`, currently `"New recording"`, and
every drawing of a title goes through `Recording.displayTitle`. That property
lives in `RecordingDisplay.swift`, whose header already states the rule this
follows: kept apart from the on-disk shape "so that changing the wording never
risks changing the format". Reword it as often as you like; no migration is ever
owed.

The line between them:

| | |
|---|---|
| the window, `listen list`, `listen show`, `calendar backfill`'s preview | `displayTitle` |
| `listen title <id>` read back, the MCP server, an export, `metadata.json` | the stored string |

`listen title <id>` with no text is documented as the read-back a script uses,
so it prints `Untitled` and says what that means on stderr. `RecordingFilter`
searches `displayTitle` too, or typing the words visibly on a row would find
nothing while typing the key would find every unnamed recording at once.

`verify_title.sh` asserts both halves, because collapsing them into one string
is the obvious tidy-up and it is the one that breaks the guard.

## The people title waits for the last speaker, and that is measured

`AutoTitle.fromPeople` refuses a recording with any placeholder left in it, so a
title lands the moment the last letter gets a name and not before.

The rule considered instead was a cap on how many speakers a recording may have,
which sounds equivalent. Measured over the 47 transcribed recordings in the real
library:

| rule | recordings titled |
|---|---|
| at least one name, at most three speakers | 28 |
| at least one name, no placeholders left | 26 |

The two in the difference are Hermes workshops 2 and 3, each of which would have
been called "Call with Nick" while a second person was still an unnamed letter.
All five recordings in the library with a letter left in them are workshops. So
the cap does not buy coverage, it buys exactly the wrong titles, and waiting
costs nothing because labelling the last speaker is itself the event that runs
the deriver.

The measured spread of non-`Me` speakers is 16 recordings with none, 24 with
one, 4 with two, and one each with three, four and five. The last three are
those workshops. Nothing in the library has ever reached the "and 2 others"
branch of `AutoTitle.list`.

## It is a view over the speakers, not a decision taken once

The hook is `TranscriptEditor.change`, which every rename, merge and discard in
the window, the CLI and `VoiceBank.autoAssign` already funnel through. That is
the whole answer to "what if the speaker is only labelled later": the title
follows the speaker list until somebody types over it and freezes it.

Three consequences, all asserted in `verify_title.sh`:

- Renaming a speaker renames the recording, twice over if you rename twice.
- Discarding the last named speaker puts `Untitled` back, and clears the source
  with it. A title naming somebody the transcript no longer contains is the app
  asserting something false about its own files.
- A typed title survives all of it, including the rename that finishes labelling.

`refresh` re-reads the folder rather than trusting the copy it was handed, the
same rule `markTranscribed` follows: on the `autoAssign` path it is called from
inside a loop that rewrites the transcript once per speaker. `Recording.load`
and not `Recording.find`, because `find` lists the whole library and this runs
per speaker rather than per recording.

`markTranscribed` calls it once more after `autoAssign`, for the transcript that
arrives with every speaker already named and will therefore never see a rename.
An import is the case that reaches it.

## "Call with" is a claim, and `app_bundle_id` is the evidence

Set only when an app was on a call when capture began or while it ran, so
without one this is a microphone in a room, which is a conversation and not a
call. Not the app's *name*, which stays in the subtitle where `DetailView`
argues it belongs, and which is what the imported `2607-17-Google Chrome` titles
came from.

Both wordings already appear in titles typed by hand in the real library ("Call
with Nadia", "Conversation with Andrew"), so neither is a phrase the app
invented for itself. The split between them is the app's, not a reproduction of
anybody's habit: the two hand-typed examples were both calls.

## The backfill exists because the deriver is driven by edits

`AutoTitle` only ever runs on a speaker edit, so a recording whose speakers were
all named before any of this existed will never see one and would stay unnamed
for ever with nothing on screen explaining why. `listen title backfill` is the
way in, dry unless `--apply`, which is the rule `listen calendar backfill`
already sets: renaming a library at once without being asked is the surprise the
rest of this app avoids.

`AutoTitle.Outcome` is why the preview and the apply cannot disagree. Both go
through `outcome(for:)`, and `refresh` is a switch over the same value the
printer formats. The alternative was tried and shipped broken for one build in
the calendar's own backfill: it worked out its preview with `isUntitled` while
`attach` had moved on to `mayTitle`, printed "keeps its name", and renamed the
recording on the next line.

Every recording is accounted for in the summary, including the ones it does
nothing to. A backfill printing only its hits leaves somebody counting rows to
work out what happened to the rest, and the per-recording reason is the useful
half: "waiting on a speaker" is something to act on, "nobody to name it after"
is not.

**`Outcome.notOurs` must never be printed as "named by hand".** It means a title
with no `title_source`, which is a typed title *and* every title written before
the field existed: the legacy Python imports and the calendar names from before.
On the real library that case was 49 of 57 recordings, and almost none of them
were typed by anybody. It said "named by hand" for one build. The wording is now
"have a title already, left alone", which is what is actually known.

The iPhone's `Memo, 8 August, 12:08` used to be in that count and is not any
more: `DeviceTitle` recognises it and stamps `device` on it, which is the section
below. Every other member of the set stays, because nothing can tell those from
a title somebody typed and the day something claims it can is the day a meeting
gets renamed out from under its owner.

## The phone named every memo, and the guard read that as a person

The phone writes `Memo, 26 August, 12:20` into `metadata.title` whenever nobody
types anything, which is most of them. `mayTitle` reads a title with no
`title_source` as one a person chose and refuses every automatic writer against
it, so naming the last speaker on a phone memo rewrote the transcript and left
the title alone, and the calendar could never reach one either. Measured on the
real library the day this was written: six of the eight phone recordings were
frozen that way, three of them still `needs_labelling`, so the failure was
silent and getting worse.

`Metadata.TitleSource.device` is the fix, and it goes at the **bottom** of the
rank: a device title is evidence of when a recording happened and nothing else,
which every row already shows beside the title anyway. The phone stamps it at
capture (`Recorder.stop`, in the iOS repo, from a `titled:` parameter on
`ListenKit.Metadata`'s creating initialiser rather than a guess from the string
later), and the raw value is duplicated as `ListenKit.Metadata.deviceTitleSource`
because the phone does not compile the Mac's enum. Two literals, one string, and
the comment on each names the other.

That fixes every memo made from that build onwards and none of the ones already
on disk, which is what `DeviceTitle` is for.

## The id carries the phone's wall clock, and `recorded_at` does not

`DeviceTitle` recognises a title the phone would have written, so a memo from an
older build, or from a phone nobody has updated, gets the field stamped on its
behalf. It rebuilds the string from the **recording id**, and that choice is the
whole of why it works.

`Metadata.makeID` stamps `yyyy-MM-dd-HHmmss` in the writing device's local time
and so does the title, so the two are renderings of one wall clock and comparing
them needs no timezone at all. `recorded_at` is UTC, so matching against it means
guessing where the phone was. Measured over the eight phone recordings in the
real library:

| rule | defaults matched | typed titles wrongly claimed |
|---|---|---|
| rebuilt from the id | 6 of 6 | 0 of 2 |
| `recorded_at` in this Mac's own zone | 5 of 6 | 0 of 2 |

The miss is `2026-08-17-041112-0ADB`, whose id says 04:11 and whose `recorded_at`
is 07:11Z: the phone was three hours from where the Mac is now, and that is not
an exotic case, it is one trip.

What is still a guess is the **month name**, because the phone formats it in its
own locale and nothing on disk records which that was. `candidates(for:)` tries
the current locale and then `en_US_POSIX`, which covers a Mac and a phone set the
same way and a phone left in English. A pairing neither covers is not recognised
and the recording stays exactly as frozen as it is today. That is the failure
this is allowed to have: it never invents a fact, and the three narrowing
conditions (`source` is `iphone`, `title_source` is absent, the string is one of
the candidates) are what keep it from being the heuristic
`Outcome.notOurs` exists to refuse.

Two callers, and no third:

- `Recording.markTranscribed`, before `AutoTitle.refresh`, because that is the
  one call the queue and `listen transcribe` share and because the Mac holding
  the audio is the device that authors an ingested recording's metadata (see
  `cloud-sync.md`).
- `listen title backfill`, which stamps **on a copy** for the dry run so the
  preview reports what `--apply` would do. Skipping that is exactly the bug the
  calendar's backfill shipped: it printed "has a title already, left alone" and
  named the recording on the next line.

## Unnaming goes back to the floor, not to the placeholder

Adding a rank below `people` broke the discard path before it was finished.
`refresh` used to write `Metadata.untitled` on `.unname`, so discarding the last
named speaker from a phone memo would have replaced `Memo, 26 August, 12:20`
with "New recording" and lost a string the device already knew. Today those
titles are frozen, so that would have been a regression introduced by the fix.

`DeviceTitle.floor(for:)` is the answer and it is deliberately the one
computation `outcome` and `refresh` share, for the reason `Outcome` exists at
all. It answers three things in order: a recording already at the placeholder
stays there, because `Untitled` is a decision too and a phone recording somebody
cleared by hand must not grow its memo title back on the next speaker edit; a
recording already wearing one of the device's strings keeps **that exact one**,
or a Mac and a phone set to different languages would rewrite each other's month
names for ever; and anything else gets the device's string if there is one and
the placeholder if there is not.

For every recording the Mac made, `candidates` is empty and the floor is
`Metadata.untitled`, so `outcome` asks the same question it always asked and
`verify_title.sh` passes unchanged. That is the check worth making on any edit
here: the phone is a case, not a new rule.

## What is deliberately not here

**No model title.** `.agents/notes/agent.md` is the constraint: Listen ships no
language model and calls no API, and a title generated per recording through the
user's own `claude` or `codex` costs their subscription for something they did
not ask for, measured at 19.9s and $0.21 for one question that read three
transcripts. The two routes that stay open are FoundationModels on macOS 26,
which most machines running a `.macOS(.v14)` app do not have, and a manual
"Suggest a title" that spends nothing until somebody presses it.
