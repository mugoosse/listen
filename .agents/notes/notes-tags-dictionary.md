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
writes the shape Speak wrote, and `decode` is deliberately liberal (that shape,
a bare array, TypeWhisper's key names), so a file from either app imports and an
export is exactly what an import reads.

Measured, when the one-press copy still existed: importing Speak's real
dictionary brought over 5 terms and 35 corrections and skipped 3 already
present.

**Nothing in the product names Speak any more, and that went in three stages.**
First the integration became a migration: Speak's dictation is part of Listen,
so a Mac with that file has a list left behind rather than a companion app to
stay in step with, and the "Get Speak" button, the paragraph explaining what
Speak was, and the empty-state that offered both went. Then the pane's
"Imported from Speak" section went, shown-only-when-the-file-exists and all,
because a settings pane naming an app nobody works on makes the reader stop and
ask what it is. Then `--from-speak` went too, with the same argument applied to
`listen dictionary --help`.

**What is deliberately kept is the format, not the name.** `encode` writes the
document `decode` reads, and that document is the one Speak wrote, so anybody
with the old file still gets their terms: `listen dictionary import
~/Library/Application\ Support/speak/dictionary.json` does exactly what the
flag did. Losing a convenience flag is cheap; losing years of somebody's
corrections is not, which is why the reader is liberal and always will be.

A term too short to be matched by sound is stored and does nothing, which from
the outside is indistinguishable from the feature being broken. `eligible` is
therefore public, the pane greys those rows, and `listen dictionary add` says so
on the way in.

### A silent "gh" is a consonant, so a term could not match its own name

`phoneticKey` is Soundex-shaped, and Soundex codes every letter it is handed.
English writes the sound at the end of "site" as "ight" about as often as it
writes it "ite", so a term spelled `Kinsight` coded to `k5223` while every
mishearing of it coded to `k523`:

| spelling | key |
|---|---|
| `Kinsight` | `k5223` |
| `Kinsite`, `Kinside`, `Kingside`, `Kinzite`, `Kinsyte` | `k523` |

Those never compare equal, so the sounds-like pass skipped the word it had been
given, and a user's own product name was unreachable by the one mechanism built
for exactly that. Shown rather than reasoned about, because the codes are not
something anybody can predict by reading their own rule: with the term spelled
`Kinsite` in a scratch library, `kinside`, `kinzite`, `kinsyte`, `kinnsite` and
`Kingside` are all rewritten, and with it spelled `Kinsight` none of them are.
Any name with `ight`, `ough` or `eigh` in it had this.

`isSilentGH` drops the g, and both of its conditions earn their place. A vowel
before, because "Afghan" pronounces its g. A consonant after, or the end of the
word, because that is what separates a silent "gh" from one starting a syllable
of its own: "sight" and "though" against "doghouse" and "foghorn". The h needs
no case at all, being already ignored, and ignored without breaking a run.

### A one-word term could only ever match one spoken word

`terms(in:)` split the *term* on spaces to get its keys and compared a span of
exactly that many tokens, so a term of one word was a one-token matcher. A
compound name is precisely the thing an ASR splits, and at its own seams, so
that was the other half of the mishearings: of eight misheard instances of one
product name in a day of dictation history, "kin site" and "can site" arrived as
two words and nothing in the list could reach them.

A one-word term now also gets the spans that close the gaps, up to
`maximumJoin` of 3, keyed as one word. Terms of several words are still matched
word for word, which is the strong signal `accepts` leans on when it allows a
span of real words: "Cloud coat" is two perfectly good English words and
obviously "Claude Code". Closing the gaps is the weaker of the two, one key over
a boundary the speaker did put in, so it keeps the real-word guard on the thing
it would be making: "in sight" is "insight", and must not become somebody's
product name.

Measured against the day of history that prompted it, eight misheard instances:
seven are now rewritten. "can site" is the one that is not, and it should stay
that way. Soundex keeps the first letter verbatim, so `c` is not `k`, and
relaxing that merges c, g, j, k, q, s, x and z into one opening sound and makes
the whole pass untrustworthy. That variant stays a correction.

**The span guard was not the tail guard, and the difference deleted text.** The
token pattern has to start on a letter or a digit, so a full stop with a space
either side is in no token's word and in no token's tail: it was invisible to
the "punctuation inside the span" check, which only ever read tails. The splice
replaces everything from the first word's start to the last word's end, so
whatever stood between them went with it. Found by running 152 real dictations
through the new matcher joined by " . ", where "Kinsite . Oh" keyed as
"kinsiteoh", matched, and became one word. The fix is a second guard: nothing
but spaces may separate the words of a span. It was a hole before this change
as well, reachable by a multi-word term over "cloud . coat", and unreachable in
practice only because a one-word term could not span anything.

**Keys are computed once per run of tokens, not once per term.** Coding a token
is the expensive half and it does not depend on which term is being tried, and
the spans would have made that three times worse. 200 terms over 7500 words:
3.2s asking per term, 0.55s asking once, which is also faster than the
word-by-word matcher was before any of this.

That corpus run is worth keeping as the shape of the check. The dictionary
rewrites an archive nobody may read for a week, so a change to the matcher is
measured by putting real prose through it and reading every difference, not by
trying the word that prompted it: 38.9 kB of dictation history, two rules fired,
five differences, all of them the name.

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

### `tag:job ` looks finished and is not, and the field lifted the wrong pill

The search field takes a finished operator out of itself and makes it a pill,
and the first version's test for "finished" was "followed by a space". Typing
`tag:job hunt` passes through `tag:job ` on the way, which passes that test, so
the field lifted a `#job` pill matching nothing and left the word "hunt"
stranded behind it. The greedy rule below cannot help: it needs words that have
not been typed yet.

`RecordingFilter.isUnfinished` is the fix. A value that is still a prefix of a
longer known tag waits, and the completion list under the field is what says so;
Return finishes a value it is holding, which is what somebody who really means a
tag nobody has will press. `trailingTagValue` is the half that finds the operand,
and it runs to the end of the string rather than to the next space, because a tag
value is the one operand here that can contain one. A quoted value returns nil:
the quotes have already said where it ends.

**Found by building the field as a throwaway prototype rather than by reading
the code.** It is the kind of bug that only exists between two rules that are
each correct, and neither `parse` nor the lift looks wrong on its own.

The same function is what the completion reads, deliberately: a completion
offering a word `parse` does not know is a filter that appears to work and
quietly searches for its own name.

### `kind:` is not a predicate on a recording, and `apply(to:)` ignores it

`RecordingFilter.kind` is a `LibraryKind`, and it is the one field on that struct
that `apply(to:)` does not consult. Every other field is a question about a
recording, so it can be answered one recording at a time; this one is a question
about *which lists to consult at all*, and only something holding the recordings,
the notes and the roster together can answer it. The sidebar does.

It lives on `RecordingFilter` anyway because the **parser** is the thing that
must not be written twice. The CLI and the MCP server never set it and lose
nothing: they are already asking about recordings by having called this at all.

`is:unnamed` maps to `needsSpeakers`, which is the lens the to-do row above the
list already sets. One state, two ways in.

**The greedy tag run has to break on every operator, not just on another
`tag:`.** Without that, `tag:job kind:notes` reads "job kind:notes" as a
candidate tag name and the second operator disappears into the first.

### Lenses stack, and `RecordingFilter` is why there is not a fourth predicate

The sidebar's `speakerFilter` became a list of `Lens`, drawn as a row of
`SpeakerPill`s in the bar that used to hold one. **They are ANDed**, because
"the calls Ryan and Emily were both in" is a question one lens cannot ask and is
the ordinary reason to reach for this at all. So the lenses *add* rather than
replace, the way a row of tokens behaves everywhere else, and replacing is
dismissing the old one first. Adding the lens already on is a no-op, because
clicking a chip twice is something people do.

**The speaker lens is gone**, asked for directly, and with it the example above:
what is left is `filter(byTag:)` and the unnamed lens. The stacking is unchanged
and still earns its keep on tags. See "Nobody wanted the library narrowed by a
speaker" in `speakers.md`.

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

## One vocabulary, two kinds of thing, and no inheritance

A note carries tags now. It was asked for as "tag all the calls and notes with
Edgar about the Kinsight project", which the app could do exactly half of: it
tagged the recordings, and had no tool that could refuse the rest, so it did
half the job and said nothing.

`Tags.all` reads `Recording.all()` and `Notes.all()` and groups both by the same
lowercased key, so **there is one vocabulary and a tag only a note carries is a
tag that exists**. That is what makes `Tags.adopted` work across the two:
tagging a note `Kinsight` where a recording holds `kinsight` files it under the
one that is there, and the other way round. Without it the two kinds would grow
parallel spellings of the same filing and neither would have everything, which
is the failure a derived vocabulary is always one step away from.

`rename` and `delete` therefore sweep both. Leaving the notes behind would
strand copies under the old name, and since a tag nothing carries does not
exist, the old name would reappear in the list the moment the rename finished.
They return `Touched` rather than a count of recordings for the same reason: the
three callers print how many, and one that said "3 recordings" after rewriting
four notes as well would be wrong in the one place somebody reads to decide.

**Nothing is inherited.** A note about a meeting tagged `kinsight` carries
nothing until somebody tags the note. This is `Notes`'s existing rule, the one
that says a note states its sources and nothing parses the body looking for
links: an inherited tag is a claim nobody made, and "why does this note have a
tag I never gave it" is a question with no answer anywhere in the file. It also
keeps `list_notes {tags}` and `list_recordings {tags}` two different questions,
which is what a caller actually wants: what is filed under this, and what was
said in meetings filed under this.

The cost is that filing a subject means tagging both, and the agent brief says
so in as many words, because a model that assumed inheritance would tag the
meetings and report the job done.

### A note's tags are in the digest only when it has any

`Note.version` is the compare-and-swap token and it was title, recordings and
body. Tags had to join it, and that is the one time this formula has moved.

Leaving them out was the alternative and it is silent loss, not saved traffic.
A tag added on the Mac would change no digest, so it would never push; the phone
would then edit the body, push markdown that never carried the tag, and the Mac
would pull it back with the tag gone and nothing anywhere reporting it. That is
precisely the failure the `extra` comment says this digest cannot detect. Tags
are not write-once provenance like `prompt` and `chat`: they are edited
repeatedly, by hand and by an agent.

**What it costs, stated rather than discovered later.** Two devices computing
`version` by different formulas push and pull the same note for ever, because
`pullNote` stamps the *sender's* digest into the base while push stamps its own,
so neither side ever agrees with itself. Traced:

1. Mac push: base `V_ios`, local `V_mac`, remote `V_ios`, so `remote == base`
   and it pushes.
2. Phone pull: `local == base`, so it pulls, and stamps `base = V_mac`, the
   sender's.
3. Phone push: it recomputes `V_ios` off its own disk, `remote == base`, pushes.
4. Mac pull: `local == base`, pulls. Back to 1.

The content never changes, because `extra` round-trips the key on the side that
does not model it, so this is wasted round trips rather than data loss. It stops
when the iOS app, which is a separate repo, computes the same string.

**Appending after the body and only when the list is non-empty is what bounds
it.** Every note written before this field existed produces the string it always
produced, so nothing already on disk re-syncs and the whole library does not move
at once; the churn covers only notes that actually carry a tag. `FakeSync` holds
the pre-change digest as a hard-coded constant for exactly this, and a second
consecutive pass asserting `pushedNotes == 0` is the churn check.

A separate tags digest in `NoteBlob` was considered and is worse: the deployed
client's `decideNote` does not consult it, so the phone still recomputes and
pushes its own version, and you pay a new field and a second digest to keep in
step for the same ping-pong.

### The empty list is written for a note and omitted for a recording

`Tags.write` stores a recording's empty tag list as nil, so a recording with no
tags is indistinguishable from one written before the field existed. Two ways to
spell "no tags" is one more than the number of things it can mean.

A note does the opposite: `tags: []` is written out. The reason is that a note
is the one sidecar **both devices serialise**, and `Library.writeNote` merges
`extra` with "absent means unchanged", which exists to stop a client dropping a
field it does not model. If an empty list were an absent key, clearing a note's
tags could never reach a peer still holding them in `extra`: the merge would put
them straight back, the two sides would agree on a digest while holding
different files, and the tag would come back from a device nobody had touched.
Writing the key makes a clear an instruction the merge can see. `FakeSync`
asserts the clear crosses.

Only the authoring device serialises a recording's `metadata.json`, which is why
the recording rule is safe and this one is not. The two comments point at each
other.

### Tagging a note does not touch `updated`

`updated != created` is what `MCP.brief` reports as `edited_by_hand`, and that
is how an agent knows a note is one to rewrite carefully or leave alone. Filing
a note is not editing its words, so an agent's own `add_tags` setting that flag
would be a lie it reads back on its next turn. `Notes.setTags` is the only write
path that leaves the clock alone.

Nothing downstream needs the clock: `version` is content and tags are in it, so
the sync sees a tag without a timestamp. One thing did, and it was invisible
from the outside. `DetailView.signature` keyed its redraw on `slug|updated`, so
a tag landing changed nothing it could see and the drawer sat showing the old
pills until something else happened to the pane. The tags are in the signature
now.

### `pageless` only earns its keep while recordings are in the list too

`Sidebar.pageless` answers "does this note already have a page to live on", and
it exists so the unfiltered library does not list every meeting twice, once as
itself and once as the note about that one meeting. That is a rule about a list
of everything and about nothing else, and it was being applied to two lists that
are not that. Both hid notes with nothing on screen to say so.

**The Notes collection was the bad one, and it was found by looking at a real
library.** `kind:notes` puts no recordings in the list at all, so there is
nothing for a note to double up with, and yet every note about exactly one
meeting was dropped from it. Most notes are about one meeting, so a list called
Notes was showing five of fourteen and reading as a library with almost no notes
in it. Reproduced on a scratch library with two notes: it listed one.

**A tag lens is the same mistake.** The list is then not everything, it is what
matches, and dropping a match because it also has a home elsewhere is a wrong
answer rather than a tidier one.

So the test is `pageless || !mayDoubleUp`, where a list may double up only when
it is showing recordings and no tag lens is narrowing it. The unfiltered library
is unchanged, which is the thing to check after touching this.

The comment this replaces said a note surviving a tag filter "would be a row the
filter did not consider rather than a row it kept", which was true only while a
note had no tags and is the exact claim this reverses. One thing did not change:
`is:unnamed` still hides notes entirely, because it asks something only a
recording can answer.

`noteLensesAllow` is gone with it. `filter.tags` and `filter.needsSpeakers`
already carry both the typed operators and the clicked lenses, and reading
`lenses` separately was how a typed `tag:` and a clicked pill could have come to
behave differently.

### The tags are text in the note row, and pills everywhere else

Full parity was asked for and this is where it stops, on purpose.
`Sidebar.heightOfRow` returns a flat 52 for every row and `NoteCell` is already
two lines in a 280 point sidebar, so pills there need a third line or variable
heights. The stronger reason is that **a recording row shows no tags at all**:
pills on note rows and nothing on meeting rows would have the list say a note is
more filed than the meeting it is about, which is the opposite of what one
vocabulary means. So the row gets `#name` in the `" · "` line it already has,
for no layout at all, and the whole list in its tooltip because that line
truncates and the tags are at the end of it.

Pills on both cells with a height that moves for both is a real option and a
separate change, worth its own measurement.

`TagChips` itself is shared rather than copied, over a `Taggable` enum. Only
about six lines of its 509 were recording-shaped, and the two things a copy
would have duplicated are both already-paid-for bugs: the picker's
`sendsActionOnEndEditing = false`, and the strip's `.defaultHigh` leading pin,
which is a measured fix for Auto Layout breaking the *trailing* one and running
the row 335 points off the pane. `maxChips` and `maxChipWidth` became instance
settings keeping the measured defaults, because those numbers were derived from
the leftover space in the transcript header after two speaker pills and the note
page's row shares with nothing.

Three places carry a strip now: the transcript header (the recording's), the
note page (a pageless note's), and the notes drawer inside a recording
(whichever note is being read). The third is not optional, because a note about
exactly one meeting is only ever read in that drawer and would otherwise be
taggable from the CLI and an agent and nowhere in the window.

### An agent may tag the user's own note, and still may not rewrite it

`add_tags` and `remove_tags` resolve through `MCP.note`, not `MCP.writable`.
That note is unwritable because its words were not derived from anything and
there is no way to get them back, which is the transcript argument applied to
the one document in the library nobody can reconstruct. A tag is filing rather
than wording: it is one click to remove in the window, and the argument for tags
being writable at all, that a tag is how a question says what it is about,
applies hardest to the note an agent most wants to find again. The tool
description says so, because it reads as a hole otherwise.

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

### A note may name no recording, and only the window may write one

`Notes.create` refused an empty `recordings` with "A note nothing points at is
one nothing can find", which was true when it was written and is not any more:
the sidebar lists a note with no single page to live on as a row of its own, and
`Sidebar.pageless` spells out that **zero means it is a page itself**. A
hand-written file in `notes/` with no frontmatter has always been such a note.

So `create` takes `requiringSources`, defaulting to true, and exactly one caller
turns it off: `AskView.saveAsNote`. The asymmetry is the point rather than a
convenience. An agent writing over MCP is *stating* what its note is about, so a
`write_note` with no `recordings` is a claim it forgot to make and is still
refused. A person pressing `Save as note` on an answer about the whole library is
making no such claim: there is no meeting to name, and refusing left the button
doing nothing at all, silently, on the screen the app opens on. See
`agent.md`.

Nothing downstream needed changing, which is the evidence that this was the
missing case rather than a new shape: `recordings: []` round-trips through
`encode`/`decode` (`sequence` drops empties), the sidebar and the Notes list both
already show it, and the note pane draws an empty source line.

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

## A note remembers the conversation it came from, and the older ones are found by their question

`Save as note` wrote the prompt and dropped everything else, so the artifact knew
what had been asked and not where the asking was kept. That makes a note page a
dead end from the one direction people actually arrive from: they read the note,
they want the working-out behind a line in it, and the conversation is somewhere
in the history under a title they have to recognise.

`Note.chat` is the id, one more optional frontmatter field, written by
`AskView.saveAsNote` from `chat.id`, which exists by then because every turn goes
through `persist` and the button is on an answer. `NotePane` puts the link on the
`Asked for:` text itself rather than on a row of its own: a note's provenance is
already two lines, and "what was asked" and "where it was asked" are one fact
written twice. It opens as a card over the note, the way a conversation opens
from anywhere else, so the note stays behind it.

**Every note written before the field has no id, which is the case that decides
the design.** `Chat.wrote(_:)` falls back to matching the prompt against the text
of a `you` turn, exact and trimmed: `saveAsNote` truncates the *title* to 60
characters and passes the question through untouched, so the stored prompt is the
turn character for character. Verified against the library's own notes:
`what-are-open-items-with-edgar.md` carries `prompt: "what are open items with
Edgar?"` and `chats/2026-08-11-114832-437B.json` opens with exactly that turn.
Never fuzzy, and never a link when nothing matched, because a near-match puts
somebody in the wrong conversation with nothing on the page to say so.

A note written over MCP or from the command line has no Listen conversation
behind it and gets no link, and neither does one whose conversation has been
deleted. Both are the same case on screen: the words stay, the link is absent.

Round-tripped through the CLI to check the field survives a writer that knows
nothing about it: `notes write --replace` re-encodes from `decode`, and
`chat: "2026-08-11-114832-437B"` is still in the file afterwards.
