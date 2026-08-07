# Notes, tags and the custom dictionary

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments explain why, thresholds say where the number came from, and no em dashes. -->

The three things written about a recording rather than extracted from it. Read this before touching `Notes`, `Tags`, `CustomDictionary`, `RecordingFilter` or `MarkdownText`.

## The dictionary rewrites the library, and only the library

`CustomDictionary` is ported from Speak, where the rules were tuned. Speak has
three mechanisms; Listen has two, because the third is a spelling hint in the
polishing model's prompt and there is no polishing model here. What is left is
pure text: a **term** matched by sound, and a **correction** matched exactly.

The rule for where it applies is one sentence with no exceptions: **the
dictionary rewrites what goes into the library**. So it runs in `Pipeline.run`
and nowhere else. A bare `listen transcribe some.wav` prints what the model
actually said, because that command exists to separate a model problem from a
capture problem and a dictionary quietly editing its output would make it lie.
`listen dictionary test "<sentence>"` is how a rule is checked without a
recording, and it is not a nicety: whether "Gusens" becomes "Goossens" depends
on a consonant code and on `/usr/share/dict/words`, so nobody can predict it by
reading their own rule.

Applied **after** `Merge.clean`, deliberately. The cleanup counts exist to
answer whether Parakeet needs the Whisper-era repetition rules at all, and that
is only answerable against Parakeet's own output. Measuring it after the
dictionary had rewritten the text would count rules firing on words the model
never produced.

Per segment rather than over the whole transcript joined up: a segment is one
ASR sentence, so every real term sits inside one, and the alternative means
splitting the result back apart against text whose length changed.

**Everything is counted, and that is the load-bearing part.** Speak's transcript
is text you are about to paste and can see; Listen's is an archive of a meeting
nobody may read for a week. A bad rule here rewrites recordings quietly and the
only surviving evidence is the audio. So `apply` returns how often each rule
fired, `Pipeline` totals it into `StoredTranscript.dictionary`, and both the
Dictionary pane and `listen dictionary list` report it. Same arrangement as
`cleanup`, same reason: a rule nobody can measure is a rule nobody can argue
about. Unlike the cleanup counts it is logged to stderr rather than hidden
behind `LISTEN_DEBUG`, because cleanup is the app tidying up after the model and
this is the user's own list rewriting their own meeting.

### Adding a field to `StoredTranscript` needs `init(from:)` by hand

Swift's synthesized decoder throws `keyNotFound` on a missing key **even when
the property has a default value**. Adding `dictionary` to the struct alone
would therefore have made every `transcript.json` written before it fail to
decode, and that failure is silent in the worst possible way: `storedTranscript`
returns nil on a decode error, so the whole library would have gone on looking
untranscribed with the transcripts still sitting on disk. Measured both ways on
a real 709-segment transcript: the synthesized decoder fails, the hand-written
`init(from:)` with `decodeIfPresent` reads it. The custom init lives in an
extension so the memberwise init survives.

### Two dictionaries, not one shared file

Speak's is at `~/Library/Application Support/speak/dictionary.json` and Listen's
is beside its recordings. Sharing one file would save maintaining two lists of
the same people's names, and it would mean two apps rewriting a document that is
written whole every time, where the loser of a race loses entries rather than
getting a merge. Import and export carry the list across instead: `encode`
deliberately writes **Speak's** shape, and `decode` is deliberately liberal
(Speak's, a bare array, TypeWhisper's key names), so the two apps read each
other's exports and the trip works in both directions. `listen dictionary import
--from-speak`, and the Speak section of the pane, are the one-press version.

Measured: importing Speak's real dictionary brought over 5 terms and 35
corrections and skipped 3 already present.

A term too short to be matched by sound is stored and does nothing, which from
the outside is indistinguishable from the feature being broken. `eligible` is
therefore public, the pane greys those rows, and `listen dictionary add` says so
on the way in.

## A tag is a name string, and the vocabulary is derived

`People`'s rule applied to subjects instead of speakers. `Tags.all()` groups the
library by the strings in `metadata.tags`; there is no `tags.json`, no create
step and nothing to keep in agreement with the recordings. **A tag nothing
carries does not exist**, so there is no orphan row and no tidying pass, and
`listen tags delete` is not a delete of anything: it takes the tag off every
recording, which is the whole of what deleting one can mean.

It exists because the three filters that were here could not name a subject. A
recruiter screen, a hiring manager chat and a referral catch-up share no word,
no attendee and no week, so free text, a person and a date range between them
cannot answer "the job hunt calls". A tag is how a question says what it is
about, which is also why an agent may write one.

### It lives on the recording, which is the opposite of the call `Notes` made

Deliberately, and the two arguments are the same argument pointing different
ways. A note moved out of the recording folder because a synthesis of four
meetings has four bad homes and no good one, and must survive one of them being
deleted. A tag is a claim about **one** recording with no meaning apart from it,
so it belongs in that folder and goes when the folder goes.

`var tags: [String]?`, and `Optional` is load-bearing for the reason recorded
against `Metadata.calendar_event_id`: the synthesized decoder throws
`keyNotFound` on a missing key even where the property has a default, and
`Recording.load` swallows decode errors with `try?`, so a non-optional
`[String] = []` would have made every recording already on disk vanish from
`all()` with nothing anywhere reporting it. Measured before writing a single
tag: `listen list` and `listen list --json` both returned 41 over a library
where no file had the key.

An empty list is written as **nil, not `[]`**, so taking the last tag off leaves
a file indistinguishable from one written before the field existed. Two ways to
spell "no tags" is one more than the number of things it can mean.

### Case is kept and matched loosely, and the library's spelling wins

`Tags.canonical` trims, collapses internal whitespace and strips a leading `#`,
because people type `#job hunt` and because `job  hunt` and `job hunt` are
indistinguishable in a pill. `Tags.matches` is `SpeakerName.matches`'s rule:
case-insensitive, so a filter cannot silently return nothing.

The part that is not obvious is that **`add` adopts the spelling already in the
library**. Typing `Job Hunt` onto a library holding `job hunt` files it under
the one that is there. Without it the list grows a second row that reads as an
exact duplicate of the first and neither one has all the recordings, which is
the failure a derived vocabulary is otherwise wide open to.

A comma is refused rather than escaped. No tag has one today, and forbidding it
now is what keeps a comma-separated form from ever being ambiguous; repeating a
flag rather than splitting on commas is already this CLI's rule, and this is the
other half of it. 40 characters, because a pill must never be the widest thing
in the header.

### The strip shares the speakers' band, and yields to them

The header above the transcript was already six deep, so a seventh band for a
feature most recordings will not use is what makes a window feel like a form.
`TagChips` is pinned to the **trailing** edge of the chips row and grows
leftward while the speakers grow rightward from the title, so the gap between
them is whatever is spare rather than a constant that is wrong at one width.

Three things follow, each of which was wrong once:

1. **The collapse is the pane's decision, not the strip's.** `TagChips.isEmpty`
   answers "no tags" and deliberately does not count its own `＋`. Answering
   "not empty, I have a button" kept a 34 point row open under the date of every
   recording in the library. `setChipsCollapsed(chips.isEmpty && tagChips.isEmpty)`
   is the condition, and inside it `tagChips.isHidden = collapsed` alone: when
   the band is open for the speakers, an untagged recording still needs its `＋`.
2. **Compression resistance is stated.** The tags yield first, because a
   speaker truncated to "Dan…" is a person you cannot identify while a tag in
   `+2` is one click away and still says how many. Left to the defaults the two
   compress in whatever order the engine likes, which is the same at one width
   and different at another.
3. **The overflow pill goes first in the row, not last.** The row reads right to
   left from the window's edge, so a count on the far right is the first thing
   seen and puts the tags it stands for in the middle of the row.

A recording whose band is collapsed has no `＋` at all, which is why "Tags…" is
in `menuNeedsUpdate`: one line there gives the toolbar's ellipsis and the
sidebar's right-click menu both, and the File menu carries the Cmd-T, because a
key equivalent only dispatches from the main menu bar.

### The tag popover stays open, and refreshing is not `show`

Two differences from `SpeakerPicker`, which it is otherwise a copy of.

It does not close on a pick. Filing a meeting is rarely one tag, "job hunt" and
"acme" arrive together, and dismissing after the first means four clicks back to
where you already were. It is `.transient`, so clicking elsewhere still
dismisses it, and the ticks are what says the write landed.

`DetailView.refreshTags` redraws the strip and nothing else. `show(_:)` stops
playback and puts the playhead back to zero, and tagging is something people do
while listening, which is the argument `applyEdit` already makes next door.

Everything else about it is `editSpeaker`'s: take the rect, **then** end the
title edit, **then** anchor the popover to the pane. That order is the shipped
0.2.0 `SIGABRT`, and `beginEditingTags` additionally has to supply a real
rectangle when the band is collapsed, because a popover anchored to a
zero-height rect opens and closes inside the same call reporting
`isShown == false`.

### Lenses stack, and `RecordingFilter` is why there is not a fourth predicate

The sidebar's `speakerFilter` became a list of `Lens`, drawn as a row of
`SpeakerPill`s in the bar that used to hold one. **They are ANDed**, because
"the calls Ryan and Emily were both in" is a question one lens cannot ask and is
the ordinary reason to reach for this at all. So `filter(bySpeaker:)` and
`filter(byTag:)` *add* rather than replace, the way a row of tokens behaves
everywhere else, and replacing is dismissing the old one first. Adding the lens
already on is a no-op, because clicking a chip twice is something people do.

Three things about the row:

1. **A lens looks like the chip that set it**, because it *is* one: a person's
   takes their colour and a tag's takes the neutral wash. What this replaced was
   a hand-built capsule copying four of `SpeakerPill`'s numbers, two of which
   had already gone out of step with it.
2. **No "Only" in front of a name.** With one lens it read fine; with two,
   "Only Ryan" beside "Only Emily" claims each is the whole of the filter, which
   is the opposite of what ANDed lenses mean.
3. **Each pill is capped at an equal share of the row**, so a second lens
   truncates the first rather than pushing it off the side of a 280 point
   sidebar. The whole name stays in the tooltip.

The dismiss glyph is a **character in the pill's own attributed string**, not
the button's `image`. An `.imageTrailing` glyph is aligned to the title's
baseline, so `xmark` sat about two points below the centre of the letters beside
it, and every cure for that is a fight with `NSButtonCell`. A character shares
the font, the baseline and the paragraph style, so there is nothing left to
misalign. `imageHugsTitle` was the other half of that fight and is gone with it:
without it, `.imageTrailing` had pinned the cross to the button's edge and given
every spare point to the gap in the middle, measuring 11 points of margin on the
left, 16 in the middle and 3 after the cross.

`RecordingFilter` is the bigger half. The predicate that narrows the library was
written out three times, in `Sidebar.reload`, `MCP.list_recordings` and nowhere
in the CLI at all, and the copies had already come apart: the sidebar matched a
speaker on the exact on-disk label while MCP went through
`SpeakerName.matches`. Adding tags to each by hand would have made a fourth.

It is a function over the list rather than a per-recording predicate **because
the order is the point**: `person` and `query` read every `turns.json` in the
library and the dates and tags read only the metadata in hand, so the cheap ones
have to run first and only something seeing the whole list can arrange that.
`Recording.speaks` and `SpeakerName.matches` moved here from `MCP.swift`, which
is where they had been living for no reason but history.

`needsSpeakers` is the fourth lens, and it is a question about the library rather
than about something you arrived at holding: it narrows to the recordings with a
voice nobody has named. It runs **first of the three that read `turns.json`**,
which is where the ordering rule above puts it for two reasons. It is by far the
most selective, taking 31 recordings to 13 on the development library, so
`person` and `query` read less than half as many transcripts behind it. And it is
the only one of the three answered from a cache, since `Labelling` keys on the
file's modification date. See `.agents/notes/speakers.md` for why the predicate
reads the transcript rather than `metadata.state`, and `.agents/notes/window.md`
for the row that sets it.

`RecordingFilter.parse` handles `tag:job hunt` by taking the longest run of
following words that names a real tag, one word when none does, and the whole
string when quoted. Matching against a known vocabulary is what makes a space in
a tag unambiguous rather than clever, and it is the same accept-what-they-meant
rule `Notes.find` uses for a slug or a title.

## The server is no longer read-only, and notes and tags are the whole exception

This reverses a property `CLAUDE.md`, `README.md`, `SPEC.md`, the Developers
pane and the landing page all stated four different ways, so the reversal has to
be as narrow as the original claim was broad. `write_note`, `edit_note`,
`delete_note`, `add_tags` and `remove_tags` are the whole of it. An agent still
cannot rename a speaker, correct a sentence, retitle a recording or delete one,
and none of those is a missing feature waiting for a milestone.

The line is between evidence and opinion. A transcript is a record of what was
said; a note is somebody's reading of it and a tag is somebody's filing of it. A
wrong note or a wrong tag is a wrong opinion sitting beside the recording that
disproves it, and a wrong transcript edit is a fact that is simply gone, because
the audio is an hour long and nobody re-listens. So anything that changes the
evidence goes through a human at the window or the CLI, where it is visible and
reversible, and everything derived from it is open.

Tags earn the writable side for a second reason notes do not need: they are how
a question says what it is about. "Summarise the job hunt calls" needs the job
hunt calls to be named, and an agent that can read a tag but never write one can
only answer questions somebody already did the filing for.

**The list of places asserting read-only was five and is six.** `MCP.md` was
missed the first time, because the original list was written from the places
that said "read-only" and `MCP.md` says it by describing the tools. The six:
this file, `README.md`, `SPEC.md`, `MCP.md`, the Developers pane
(`SettingsWindow.swift`), and the `mcp` line in the CLI usage text. The landing
page does not make the claim and never did, so it was on the list by mistake.
Two more in code: the `MCP` file comment, and `delete_note`'s own description,
which called itself "the only destructive tool here" and stopped being true when
`remove_tags` arrived.

**`Notes` is one owner with three callers**, which is the rule
`TranscriptEditor` already sets: `listen notes`, the MCP tools and `DetailView`
all go through it. The CLI came first, before any UI, because a store that can
be driven from a terminal is a store whose behaviour is settled before anything
renders it, and there is no test target.

### The compare-and-swap is required over MCP and optional at the CLI

`Notes.replace` takes `expecting:` and refuses the write when the body no longer
matches, which is `TranscriptEditor.retext` one layer up. `edit_note` makes
`was` a required parameter; `listen notes write --replace` makes `--was` a flag.

That is not an inconsistency. The window and an agent can be holding the same
note at the same time, and that is the surface where an unseen overwrite is
possible. A person at a terminal is one writer looking at what they are
replacing, and demanding they paste the previous body back would make the
command unusable rather than safe. `listen notes read` prints the body on stdout
and the provenance on stderr precisely so `--was-file` has something to be given:

```sh
listen notes read <id> outline > was.md
listen notes write <id> --replace outline --was-file was.md --file new.md
```

### A note belongs to the library, not to a recording

Notes started in `recordings/<id>/notes/` and moved to
`~/Library/Application Support/Listen/notes/<slug>.md` before anything was
committed. The reason is one use case: "summarise everything with Edgar in June"
spans four recordings, and under one-note-per-recording it had three bad homes
and no good one. Pick one of the four arbitrarily; duplicate it into all four
and keep them in sync by hand; or do not write it. **A note with one source is
the common case, not a special case**, so `recordings` is an array all the way
down and a single-meeting note is an array of one.

That is the arrangement `dictionary.json` and `contacts.json` already have, for
the same stated reason: they are about the library as a whole.

Three consequences, all deliberate:

1. **Slugs are unique library-wide**, so the user's own note is
   `<id>-yours` rather than `yours`: two recordings would otherwise both want
   the same file and the second would silently become `yours-2`, which nothing
   could find again.
2. **Deleting a recording no longer deletes notes about it.** A synthesis of
   four meetings must not vanish because one of them was tidied up. A note
   naming a deleted recording keeps naming it and shows the bare id as
   unresolved, in `Notes.sources`, in `listen notes read`, in the note pane and
   as `unresolved_recordings` over MCP. It is never cleaned up.
3. **There is no wiki-link parsing, no graph view and no automatic linking.**
   The agent states its sources in `recordings` and nothing guesses. A note that
   mentions a name is not a note about that meeting.

`Notes.migrate()` moves the old layout, keeping `created`, `updated`, `source`
and `prompt` so a note somebody edited arrives still looking edited. It runs
once per process, from a `private static let` initialiser, because there is no
single startup path the CLI, the app and the pipeline actor all go through and a
`static let` is initialised lazily and exactly once by the runtime. **35 notes
moved** on the real library.

### A note file has to survive being written by hand

The frontmatter is emitted with every value double-quoted and escaped, always,
rather than only when it needs it. A title is free text and will eventually hold
a colon, a leading `#`, or the word `yes`, each of which changes what an unquoted
YAML scalar means. Two characters, one class of bug removed.

`Notes.decode` goes the other way and is deliberately liberal, same as
`CustomDictionary.decode`. A markdown file dropped into `notes/` in Finder with
no frontmatter at all is still a note: it takes its title from its first heading
or its filename and its source from nobody. Refusing it would make the whole
argument for markdown-on-disk false, and the promise that deleting one in Finder
is a supported operation only holds if creating one there is too.

The terminator is found by scanning for a line that is exactly `---`, not by
searching for `\n---\n` in the string. A note body containing a horizontal rule
would otherwise end the frontmatter block from inside the document.

## The outline was built, measured and deleted

A recording used to get an extractive `outline` note at the end of
`Pipeline.run`: duration, a talk-time table, the longest stretches with
timestamps, how it opened and closed. It shipped in the working tree, ran over
the whole library, and was removed before any of it was committed. **33 outline
notes were deleted.** Worth recording, because the argument for building one is
good and the argument against only appears once you read a real one.

1. **It is derived from the transcript, so it asks the reader to supply the
   intelligence and gives them more to read in exchange.** Everything in it was
   already on the screen next to it.
2. **The "Who talked" table duplicated the speaker chips**, which are in the
   header of the same pane, four inches away.
3. **"Longest stretches" selects the most rambling turn, not the most
   important one.** Ranking by word count is exactly a ranking of who went on
   longest without being interrupted. On a real recording the top entry was 843
   words beginning "yeah um no so sorry for the delay to getting ready here um".

The talk-time measurement it forced is still worth having: on a real 33:14
two-person call, talk time sums to **47m 40s** because 28 of its 48 turns end
after the next turn starts. The two tracks are captured and transcribed
separately, so a long system-track segment straddles several mic-track ones and
`Merge.turns` takes the `max` of the ends. Anything that reports per-speaker
seconds has to know that, including the chips, which use the same measure.

## The user's own note is the thing no transcript contains

What replaced the outline. One note per recording, `source: you`, slug
`<id>-yours`, and it is the default selection in the Notes tab. A transcript
records what was said; this records what somebody was thinking while it was
said, and "we should upsell them" is exactly the context an agent needs and had
no way to get.

Four properties, each of which is a decision:

1. **It materialises on the first keystroke.** No New Note button, no naming
   step. `Notes.yoursOrEmpty` returns an unsaved note so the pane always has
   something to put a cursor in, and `Notes.setYours` writes the file when there
   is a body and deletes it when there is not. An empty note is not a note, and
   a library with 36 empty files in it is worse than one with none.
2. **Plain markdown in a plain text view.** No rich text, no slash commands, no
   templates, and `isRichText`, the quote substitution and the dash
   substitution are all off: a curly apostrophe AppKit inserted on somebody's
   behalf is a character they did not type sitting in a file they will be quoted
   from. Anyone who wants a document already has a notes app.
3. **It is editable while the recording is still running**, and Notes is the
   default tab in that state because Transcript is an empty pane for the next
   hour. `Recording.promote()` moves `staging/<id>` to `recordings/<id>` with the
   id unchanged, so a library-level note keyed on that id needs no special
   handling at adoption. `Notes.setYours` deliberately skips the `checked`
   validation that every other write goes through, because `Recording.all()`
   cannot see a staged recording, and `Notes.sources` looks in `staged()` too or
   a live recording's own note would report its own meeting as missing.
4. **An agent may read it and may not write it.** `MCP.writable` refuses
   `edit_note` and `delete_note` on a `source: you` note, and says to write a
   separate note instead. This is the one asymmetry in the note surface, and it
   is the same line the transcript is on: that text was not derived from
   anything, so there is no way to get it back.

**Do not call it "private".** That names a sharing model this app does not have
and would be a lie the day anything syncs. `source: you` and "Your notes" are
claims about who wrote it, which stay true.

Deleting has to say so. `LibraryWindow.deleteSelected` names it in the alert,
and answering "No" to the meeting prompt, which is otherwise the one place a
recording is deleted without being asked about, now asks exactly when there is a
non-empty note: somebody who has typed into it has said this is a meeting more
clearly than the panel ever asked.
