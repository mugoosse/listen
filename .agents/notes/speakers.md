# Speakers: identity, transcript edits and voiceprints

<!-- Split out of CLAUDE.md, which is the index. Same rules apply: comments explain why, thresholds say where the number came from, and no em dashes. -->

Who said what, and how a human corrects it. Read this before touching `People`, `TranscriptEditor`, `SpeakerName`, `VoiceBank`, `Enroll`, `Diarizer` or the legacy import.

## A sentence is edited, and a segment is what gets written

Right-click a sentence in the transcript, choose Edit Sentence, correct it, click
away. What lands on disk is one `LabelledSegment`, not the paragraph.

That is the whole design and it is not a detail. A turn is a fold over segments
(`Merge.turns`), nothing records the reverse, and `TranscriptEditor` rebuilds
`turns.json` from the segments on every speaker change. A correction written to
the paragraph would therefore survive until the next rename and then vanish, with
nothing on screen to explain where it went.

So `Merge.Sentence` carries `index`, the position of the segment it came from,
and `TranscriptEditor.retext` writes there. Sentence level rather than paragraph
level because `Merge.sentences` already locates every ASR sentence inside its
turn: the mapping is one to one, no diff is needed, and the timings and the
playhead highlight come through untouched.

`retext` is a **compare-and-swap**, not an index write. The index comes from a
pane rendered at some earlier moment and `.discard` removes segments, so an index
taken before one runs names a different sentence afterwards. The old text travels
with the edit and the write is refused if it no longer matches, rather than
applied to whatever moved into that slot. Both sides are trimmed, because the
window's copy is the substring `Merge.sentences` found in the turn and that
search uses the *trimmed* segment text: an imported transcript with surrounding
whitespace would otherwise fail the check and refuse every edit silently.

`change` therefore takes a closure returning `Bool`. A refused edit must not
leave a `.raw.json.bak` and a rewritten `turns.json` behind it.

### The right-click never reaches the text field

This one is worth knowing before trying to do it another way. A selectable
`NSTextField` installs its **field editor on `rightMouseDown`**, before the
contextual menu is built, so hit testing lands on that `NSTextView` and an
override of `menu(for:)` on the field itself is never called. Measured directly,
because the opposite is the natural assumption:

    hitTest, unfocused:  TranscriptBody
    after rightMouseDown, currentEditor: NSTextView
    hitTest, focused:    NSTextView

So the menu is built by `TranscriptFieldEditor`, a field editor handed out by
`LibraryWindow.windowWillReturnFieldEditor(_:to:)` for `TranscriptBody` clients
and nothing else. That also settles how a click becomes a character: the field
editor is AppKit's own layout of that exact string at that exact width, so
`characterIndexForInsertion(at:)` cannot disagree with what is on screen. A
layout manager rebuilt on the side would differ by the cell's insets, which stays
invisible until a click near a sentence boundary quietly picks the neighbour.

The item is inserted at the top of `super.menu(for:)` rather than replacing it.
Look Up and Copy are why anybody right-clicks a transcript today.

### The paragraph splits in three while one sentence is edited

Not an overlay on the sentence. A sentence in a wrapped paragraph starts mid-line
and ends mid-line, so it is not a rectangle and a field placed over it is either
the wrong shape or covers its neighbours. `TurnView` swaps its body for
`[before, field, after]` in a stack, with the two context labels dimmed. Every
word stays on screen and there is no doubt which part is live.

The width has to be stated: a vertical `NSStackView` sizes an arranged subview to
what it asks for, and a wrapping label with no definite width asks for one long
line, so `fill(with:)` pins each piece to the stack's width or the paragraph
stops wrapping the moment it goes in.

Two consequences that were nearly bugs:

1. **`highlight` no-ops while editing.** It runs twenty times a second and
   rewrites the paragraph's attributed string, which is not on screen then.
2. **`applyEdit` reloads rather than calling `show`.** `show` stops playback and
   puts the playhead back to zero, and correcting a word is something people do
   while listening to it. `renderTurns(scrollToTop:)` exists for the same reason:
   a reload that jumps to the top of an hour-long meeting loses the reader's
   place after every correction.

Clicking away commits, which needed the same fix the title field needed:
`NSView` does not accept first responder, so `DetailView.endEditing()` now lets
go of both fields and every control that swallows its own click calls it.

`listen edit <id> "<old>" "<new>"` drives the same `TranscriptEditor.retext`, for
the reason `listen label` exists. It matches on the old text rather than a
segment number, because a number is not something anybody has, and it refuses
rather than guesses when two sentences read the same. The window can edit those
two separately: `Merge.sentences` carries a cursor forward, so the first
occurrence in the turn maps to the first segment.

## Discard is a delete, and the undo it was mistaken for did not exist

Reported, in full, because the shape of it is the lesson. Somebody named a
placeholder after their sister to see what the flow did. They then wanted that
undone, opened the speaker's menu, took "Not Céline Goossens…" because that is
what they meant, landed in `SpeakerSheet`, found the person they wanted was not
in the list, and pressed **Discard speaker**. They expected to be back at a
speaker they could name again. What they got was half the transcript deleted.

Three separate faults, and all three are fixed:

**1. The undo did not exist anywhere.** `People.unname` had done this
library-wide since the roster was built, and there was no way to do it to one
recording, which is the only scope anybody wants it at: getting one meeting's
attribution wrong says nothing about the others. `People.unname(_:in:)` is that
operation, and `freeLabel(in:)` is shared with the library-wide version so both
pick a letter the recording is not already using. Reusing one that is in the room
would silently merge two speakers, which is the one thing unnaming must not do.

It is on screen as **Leave Unnamed**, in the footer of the picker, where Discard
used to be for a named speaker. No confirmation: every word stays, the voiceprint
moves to the letter, and naming them again is the list the popover is already
showing. Confirming a reversible edit only teaches people to click through the
dialogs that matter.

**2. Discard was offered where it is never the right answer.** It exists for a
phantom: a stretch of silence the diarizer split off with filler written over it.
A phantom is unnamed by definition, so on a speaker somebody has named, Discard
can only ever be a mistake. The picker's footer is now built from the label:

| speaker | footer |
|---|---|
| placeholder | Discard |
| named | Leave Unnamed |

It stays one click away, because Leave Unnamed turns a named speaker back into a
placeholder and the footer then offers it.

**3. "Not X…" led to the wrong place.** It opened `SpeakerSheet`, the alert whose
whole list of answers is a name field, Merge and Discard. It now opens the
picker, which asks "Who is this really?" over the ranked candidates, the
invitation and the roster, and carries Leave Unnamed. The sheet is still the
fallback when there is no anchor to point a popover at, because a menu must not
depend on a popover appearing.

### Merge stopped being a button and became the first section of the list

The same complaint, one step further along, and worth stating as a rule: **a
list of who somebody might be that leaves out the people in the room is not a
list of who somebody might be.**

`gather` used to drop everybody already in the recording, from all three
sections, and the reasoning was about the data rather than about the question:
they are "accounted for, and naming two speakers the same thing is a merge,
which is the button at the bottom that says so". So a speaker who is really the
person two paragraphs above them could be answered only by knowing that the word
for it is Merge, pressing a button of that name, and choosing from a popup in a
modal. Reported on a call where a 1% speaker was plainly the 69% one.

They are now the first section, above the voice bank's ranking, because it is the
shortest list, the most concrete one, and the answer to the diarizer's commonest
mistake. Picking one is still a merge and writes exactly what the button wrote:
`.rename(speaker, to: label)` onto a label the transcript already has, which
`VoiceBank.rename` documents as the merging case and resolves by keeping
whichever voiceprint was built from more speech.

Three details that make it work:

1. **The row carries the bank's opinion when it has one.** A speaker this voice
   resembles who is *also in the room* is the split-in-two case saying so, and
   that suggestion used to be dropped for being "taken". The detail line is
   "Likely them · spoke for 4:33".
2. **`check` returns nil for any label already in the recording**, which is the
   one case that has to escape both refusals: `looksLikePlaceholder` would block
   folding into `Speaker B`, and `recordingHasYou` would block folding into `Me`,
   which is the far end coming back in through the microphone. Both were things
   the Merge button did without asking.
3. **Only when naming.** The reassignment picker is opened from a menu item
   reading "Someone Else…", under a submenu already listing everybody in the
   recording, so repeating them there would be the one list that contradicts the
   words that opened it.

A placeholder in that list wears its letter rather than its initials.
`InitialsDisc` ran "Speaker B" through the initials rule and got "SB", which
reads as a monogram and is the same two characters for every unnamed speaker in
the room. It only started mattering when placeholders began appearing in a list
built for people.

Merge survives in `SpeakerSheet` and in `listen label --merge-into`, which are
the routes that do not depend on a popover appearing.

### The confirmation counts what it is about to delete

"Their segments are removed from the transcript" is true and says nothing about
size. It now reads "This removes 8 turns · 0:39 from the transcript, and the
paragraphs on either side join up", the button says **Delete 8 turns · 0:39**
rather than "Discard", Return lands on Cancel so the destructive one has to be
aimed at, and the text names Leave Unnamed as the thing to do instead.

One implementation, `SpeakerSheet.confirmDiscard`, shared with the picker. Two
warnings about one destructive edit is how one of them ends up milder than the
other, and the mild one is the one somebody reads.

## Who said it is corrected at three sizes, and the middle two are new

Until this existed, every speaker edit was about a **speaker**: rename them,
merge them into somebody, discard them. All three act on everything that person
said in the recording, and none of them can fix the mistake the diarizer actually
makes. A cluster boundary in the wrong place gives one paragraph, or one sentence
inside a paragraph, to somebody who did not say it, while the rest of that
speaker's turns are right. Renaming to fix a paragraph destroys the rest.

So there are three sizes now, and each is where the thing it acts on is:

| size | where | writes |
|---|---|---|
| one sentence | right-click the sentence → Speaker for This Sentence | `.reassign(.sentence(index:text:))` |
| one turn | click the pill → Speaker for This Turn | `.reassign(.turn(start:end:))` |
| every turn they have | the pill or chip's Not X…, Merge, or a rename | `.rename` / `.merge` |

**The submenu offers the recording's own speakers first, and they are one
click.** The mistake is nearly always one person's words landing on another
person who is *also in the room*, so the answer is usually two names away and
should not cost a dialog. The speaker it is attributed to now is in the list,
ticked and disabled, because a menu of names with the current one missing makes
the reader work out which one is absent. Anybody else is one click further,
through `SpeakerPicker.choose`, which is the same controller that names a
speaker: same ranked candidates, same invitation rows, same roster, same "New
person" row. A second, smaller chooser built for this menu would be the first
place somebody stopped being suggested.

### Both buttons on a pill open the same menu, and the popover is its first item

A left click on a speaker's name in a transcript used to go straight to the
popover about them. That put the two questions a reader has about a name on
different buttons: *who is this*, on the left, and *who really said this*, on the
right. Nobody finds the second one that way, and the name over a paragraph is
exactly where the doubt about it appears. So the pill's ordinary click pops the
same menu the right button does, positioned the way `SpeakerChips.showOverflow`
positions its own.

**Nothing is lost, because the first item is what the click used to do.** That
took a parameter rather than an accident: `PersonPopover.menu(open:)` replaces
what the first item does, and `DetailView.turnMenu` passes `editSpeaker`. Without
it the menu's own first item would have run `SpeakerSheet`, so the shortest path
from a transcript to naming a voice would have been the alert the picker was
built to replace, and a named speaker's card would have opened with no playback
pointed at them.

The default is deliberately unchanged for `SpeakerChips`. A chip's menu is a
second route to a popover the chip itself already offers on a click, and it is a
route that deliberately does not depend on a popover appearing.

Verified in the window: pressing the pill opens the menu (the AX press reports
failure, which is the menu's own tracking loop, not the press), choosing Contact
Card raises the card with the transcript unmoved under it, and on a speaker
renamed to a letter, Who Is This? gives the picker popover with its Play row
rather than a separate alert window.

### A sentence is named by its index, a turn by a time window

Both have to survive a pane that was drawn before something else edited the
transcript, and they survive it differently.

`.sentence` is the index plus the text that index must still hold, which is
exactly `retext`'s compare-and-swap and refused the same way. `.turn` is a time
window, and **not** a list of the indices on screen, for two reasons. A paragraph
is a fold over however many segments happen to lie inside it, and those numbers
do not survive a `.discard` anywhere earlier in the file; and `Merge.sentences`
skips any segment whose text it cannot locate in the turn, so an index list built
from the screen would silently leave those behind under the old speaker. A window
is stated in the transcript's own units and catches them.

The window tests `start` only. The last segment of a turn can end after the turn
does when the timings disagree by a rounding, and testing both ends would drop
exactly the sentence a reader is most likely to be complaining about.

### The voiceprint is left alone unless the label goes

A print is built from everything one speaker said, so after a partial
reassignment it still describes the segments that stayed behind. What it stops
describing is a label that has gone from the transcript entirely, which happens
when somebody reassigns the last of it, and a bank entry for a speaker who is not
in the recording goes on being offered as a suggestion in the next one, on
evidence that was reassigned away. So `.reassign` re-reads the recording after
the write and calls `VoiceBank.remove` only when nothing of theirs is left. Same
rule `.merge` follows, arrived at from the other end.

### Everything else this decides

- **No confirmation, and that is not an oversight.** The words and the audio are
  untouched, both speakers are still in the transcript, and the way back is the
  same menu on the paragraph it just moved to. Compare `.discard`, which asks.
- **`Me` is allowed where the whole-speaker rename refuses it.**
  `People.checkSpeaker` refuses `Me` when the recording already has a microphone
  track, because at speaker scope that is a merge. At sentence scope it *is* the
  merge, and it is the exact repair for the far end coming back in through the
  microphone: see "The far end comes back in through the microphone" in `asr.md`.
  `SpeakerPicker`'s `Purpose.pick` therefore checks less than `.name` does. A
  bare letter is still refused, since every placeholder in the recording is
  already an item in the menu this popover was opened from.
- **The pill's menu is built when it opens.** `NSMenu` with a delegate and
  `menuNeedsUpdate`. An hour of meeting is hundreds of turns, and eagerly
  building a menu apiece, each holding a popover's worth of closures, for the one
  paragraph somebody right-clicks, is work paid on every render.
- **`listen label --move` and `--move-turn` drive the same edit**, for the reason
  `listen label` exists at all. Verified on a copy of two real recordings: moving
  segment 2 out of a `Me` turn split the paragraph and folded the sentence into
  the neighbouring speaker's; moving every `Edgar` segment to Joshua Daniels left
  `edgar left: 0` and dropped Edgar from `embeddings.json`; a window with none of
  the speaker's segments in it, and an index whose text no longer matches, both
  refused with nothing written.

## A person is a name string, and that is the whole identity model

`People` groups the library by the label written in the transcripts. Nothing
cleverer, and deliberately not the voiceprints: those rank a voice against the
bank, and SPEC's own rule is that a suggestion is never applied on its own, so
two recordings hold the same person exactly when somebody said so by naming them
the same thing.

Placeholders are therefore never people. `A` in one meeting has nothing to do
with `A` in another, so `People.all` filters them out while `People.speakers`
keeps them: they really are in *this* recording, and the chip is how one gets
named. The same split as `VoiceBank.named`, for the same reason.

There is no index and no cache, for the reason there is no job table. Every call
re-reads `turns.json`, which is what the sidebar's transcript search already did
on every keystroke. If a library ever grows big enough for that to hurt, the fix
is a cache keyed on the file's modification date, not a database.

### The card's one verb goes to the person, not to the list behind it

The foot of `PersonPopover` used to read "Show Recordings", and pressing it ran
`LibraryWindow.filter(bySpeaker:)`: the sidebar narrowed to that person and the
card closed. Two things were wrong with it as the card's only plain verb. It
acts on the list you were reading rather than on the person whose card is open,
so the popover's most prominent control pointed away from its own subject; and
the page that actually holds everything about them, People, was two levels down
behind the ellipsis, under an item worded the same way as the card's own "and N
more in People".

So the verb is `openInPeople` and the ellipsis is left holding Edit alone. The
filter is not gone: it is `Show Only <name>` on the chip's own menu
(`PersonPopover.menu`), which is where somebody who wants the library narrowed
is already asking for it, and it is one right-click from the same chip that
opens the card.

Verified against the built app with AX, on a scratch `LISTEN_LIBRARY` of three
copied recordings: pressing the chip gives a popover whose last button is
`Open in People` / "See everything about Céline in People", pressing that leaves
zero popovers on screen and the split view showing the People roster with
Céline's page beside it.

## Renaming somebody everywhere is the first edit that touches many recordings

`People.rename` loops and calls `TranscriptEditor.apply(.rename:)` per
recording, which is the same path the sheet and `listen label` take. It has to
be: that one function rewrites `transcript.json`, rebuilds `turns.json`, moves
the voiceprint with the name, and re-derives the state. Anything that
reimplemented one of those four here would be a fourth writer of the same files.

Three things it refuses, each because the failure is silent otherwise:

1. **A name that looks like a placeholder.** Renaming somebody to "A" puts every
   recording back into needs-labelling and drops them out of the voice bank,
   which reads as the rename having quietly failed.
2. **`Me` as a target.** The microphone track is you by construction rather than
   by name. Folding somebody into yourself in one recording is the existing
   per-recording Merge, which is a transcript edit and stays one.
3. Nothing at all when the name is unchanged, so a stray Return costs no writes.

Collisions are counted **before** the fact and said out loud. Renaming Sarah to
Anna where a recording already has an Anna merges two people there, `Merge.turns`
condenses their now-adjacent turns into one, and the result looks exactly as
though it had always been that way. `VoiceBank.rename` keeps whichever
voiceprint was built from more speech, because `isEvidence` is a threshold in
seconds and keeping the shorter one can drop a usable identity below it.

### Only the collision is worth an alert, and the rest was noise

`PeoplePane` and `PersonPopover` both put up a "Rename X to Y in N recordings?"
panel after Save. Both editors already carry the line *Renaming rewrites the
transcript in N recordings and moves their voiceprint with the name*, directly
above the button. So the panel restated, after the click, the sentence somebody
had just read and acted on, which is not a safety step but a click. It is the
argument that removed the keep-this-recording panel wearing different clothes: a
question asked away from the moment it belongs to gets answered without being
read.

What `confirm` still exists for is the half that is **not** on screen. Renaming
Sarah to Anna where a recording already has an Anna merges two people there,
`Merge.turns` condenses their now-adjacent turns, and the result looks exactly
as though it had always been that way. Nothing on the pane says it and nothing
afterwards shows it, so that one asks and says only that. Verified by driving
the real window: an ordinary rename saves silently and the transcript is
rewritten; a colliding one still puts up "One recording already has somebody
called Quinn."

## `Me` stays `Me` on disk, whatever you call yourself

`Settings.userName` is a preference and `SpeakerName.display` resolves it on the
way to the screen. The transcripts keep saying `Me`. This is the same rule as
`Speaker A`: the label is the stable fact, and the interface is where it is made
legible.

Writing the chosen name into transcripts instead fails three ways that only
appear later. Recordings made before the name was set would keep saying `Me`
while later ones said "Emily". Changing your mind would not reach the history.
And `Me` would stop being a stable key, which `VoiceBank.isPlaceholder` and
`Enroll` both use to know which voice is the user's without being told.

The consequence is that two people can display the same name, and this library
really does contain that case: 19 recordings with `Me` and 8 with a hand-labelled
`Emily` from the import. They stay two people. `listen people` prints the disk
label after the name whenever the two differ (`Emily (Me)`), the popover says
"You, on the microphone track", and choosing a name that already exists says so
rather than merging anything.

### The window refused a label the CLI had always accepted

`SpeakerPicker.apply` guarded on `People.check`, which is the **library-wide**
rename's rule and refuses `Me` outright, with "To fold somebody into yourself in
one recording, use Merge in that transcript." Applied to one speaker in one
transcript, two of its three rules survive the trip and that one does not.

The case that breaks it is the imported library, which is most of this one. A
legacy recording is a single mixed track, so `Pipeline` labels nobody `Me`
there, so there is no microphone side to Merge into and the advice points at a
button with nothing to offer. Renaming the speaker is the only route, and
`listen label <id> A Me` has always taken it. So the window and the CLI
disagreed about a rule that is supposed to have one owner, which is the failure
`listen label` exists to catch, and what found it was somebody picking a name
**the app itself had just suggested at 85%**: the voice bank offers `Me` in
Sounds like, and then the guard one layer down refused it.

`People.checkSpeaker(_:in:)` is the per-recording rule. It keeps empty and
placeholder, and replaces the blanket refusal with the one thing that is
actually true per recording: you can only be one speaker in it, so `Me` is
refused only where a microphone track is already present, and there Merge is
the button at the bottom of the same popover. Both halves verified by driving
the real picker: on the mix-only import it wrote `Me` and moved the voiceprint
with it; on a recording that already had one it said so and wrote nothing.

Two things came with it, because the same bug had a display half:

1. **`Candidate` carries a `label` and a `name`.** The Sounds like row read
   `Me`, the raw label, while every chip two inches above said "Maxime". Now it
   reads the display name and writes the label, and the initials disc takes its
   colour from the label so it matches the chip.
2. **Typing your own display name resolves back to `Me`.** Without it, "Maxime"
   typed into the field files a second person under a name already in the
   roster, and nothing on disk says the two are the same. Same
   accept-what-they-meant rule as `People.findByDisplayName`. The People
   section also stopped filtering `!person.isYou`: `taken` already excludes you
   wherever the microphone track is present, so the explicit test only ever
   removed you from the one kind of recording that needs you.

## Transcript edits do not live in the sheet that presents them

`TranscriptEditor` owns rename, discard and merge; `SpeakerSheet` only asks the
question. They are split so `listen label` exercises the exact code path the
window uses, rather than a second implementation that agrees with it right up
until it does not. There is no test target, so this is what verification of
speaker editing looks like.

The `.raw.json.bak` backup is written **once**, before the first edit. Writing
it on every edit would overwrite it with edited data the second time, and it
would no longer be a way back to what the model actually said.

## Voiceprint thresholds were re-derived, and the old ones would have been wrong

`listen calibrate` on 12 named voiceprints across 4 people (12 same-person and
48 different-person cross-recording pairs):

    same person       min +0.979  median +0.991  max +0.995
    different people  min +0.127  median +0.225  max +0.597

Clean separation, gap +0.382, top-1 identification 12/12. `matchThreshold` and
`strongThreshold` sit one third and two thirds across the gap, at 0.72 and 0.85.

The Python pipeline's 0.50 was measured against **pyannote** embeddings, where
different-person pairs topped out at 0.46. In FluidAudio's space they reach
0.597, so copying 0.50 across would have called strangers a match on a third of
the pairs measured here. This is exactly why SPEC 4.5 says to re-derive rather
than copy.

**Measured on synthesised speech**, which is the caveat that matters. One TTS
voice reading two scripts is far more self-consistent than a person on two days
with two microphones, so same-person scores above 0.97 are an upper bound on
separability rather than a real-world figure. Re-run `listen calibrate` against
a real library before trusting these numbers.

Two rules keep the measurement honest and are easy to break: pairs from the
same recording are skipped (they come from the clustering step that decided
they were different people, so using them measures the diarizer agreeing with
itself), and placeholder labels are excluded (`A` in one meeting has nothing to
do with `A` in another, and pairing them manufactures both false same-person
and false different-person pairs).

## The legacy voiceprints are a different space with the same dimension

`meet_transcriptions` stores pyannote embeddings; Listen uses FluidAudio. Both
are **256-dimensional**, which is the whole danger: importing the old vectors
into `embeddings.json` raises no error anywhere, produces no exception, and no
length check catches it. Cosine similarity between a vector from one model and
a vector from the other is simply a meaningless number between -1 and 1, and it
flows straight into the sounds-like ranking looking exactly like a real score.

So `LegacyImport` deliberately imports everything **except** the vectors. The
names come across, because 25 of the 55 speaker slots in the old library were
labelled by hand and that is the part nobody wants to redo. `listen enroll`
then re-derives real FluidAudio voiceprints from the imported audio and matches
them to those names by overlap on the clock, which is the only thing the two
labellings share.

The same trap applies to the thresholds, for the same reason. See the
calibration note above.

## An imported recording has no mic track, and must not pretend otherwise

The legacy recorder produced one mixed file. It lands as `mix.m4a`, which is
what it is, and `Pipeline.run` treats a mix-only recording as the
everyone-track: diarize it whole, discover every speaker, and label nobody
"Me". The two-track shortcut relies on the user being the one in `mic.wav`, and
in a mixed track that is not true of anybody, so applying it would attach the
user's name to whoever happened to be first.

### Re-transcribing an import swaps Whisper for Parakeet, and v2 has no Dutch

The trap that makes "just Transcribe Again on the imports" look obviously right
and be catastrophic on half of them. **A legacy transcript was produced by
Whisper, which is multilingual. Parakeet v2 is English only.** Nothing in the
window says so at the moment somebody presses the button, and the result is not
an error, it is a plausible English transcript of a Dutch conversation.

Measured over the 07-13 group, where the legacy text is the same calls in Dutch:

| recording | before | after, v2 |
|---|---|---|
| `2026-07-13-184129-4F3D` | 100 turns, 1289 words | 24 turns, 403 words, **-69%** |
| `2026-07-13-183719-8160` | 68 turns, 415 words | 1 turn, 97 words, **-77%** |
| `2026-07-13-182440-779C` | 13 turns, 152 words | 9 turns, 61 words, **-60%** |

And what survives is worse than the count suggests, because it is confident
nonsense rather than gaps:

    before   A   Hello? Hello. Have you had the Zandelion?
             A   Where's on top of the team? Have you FaceTimed? Have you seen the kids?
    after    A   Yes, Erisander Leinhardt? Ah, okay. And the kinches aren't in the kindergarten
             Me  Wow, could you not say button on Sidaki boot trap? Couldn't buttrap a bit or boot.

Not an audio problem: both split tracks peak near 1.0 with a p99 of 0.21 and
0.34, and 55% of samples above the noise floor. The same operation on an
**English** import is fine, measured on `2026-07-03-170153-CBDE`: 2723 words to
2764, **+2%**, with `Me` correctly separated onto the mic track for the first
time.

So the rule is: **check the language before re-transcribing an import**, and use
`--model v3` where it is not English. Dutch is one of v3's 25. Nothing enforces
this yet, and the Models pane's "English only" line is two screens away from
Transcribe Again, which is where it is needed.

## The legacy m4a holds two tracks, and everything reads only the first

This one cost the most to find, because every symptom pointed elsewhere.
`listen enroll` produced one name per recording when the transcripts clearly
had two, and the diarizer reported **1 speaker across 219 turns of an 80 minute
two-person call** without erroring.

A clustering threshold sweep came back completely flat: 1 voice at 0.6, 0.5,
0.4 and 0.3. A parameter that changes nothing is the tell. The audio really did
contain one voice, because the file has **two audio tracks**, a stereo one
carrying what the Mac was playing and a mono one carrying the microphone, and
`AVAsset` handed over only the first. Confirmed by transcribing each track: one
holds the far end and the other holds the user.

So `AudioExtract` splits them on import, into the same `system.wav` and
`mic.wav` a native recording produces, and the whole two-track pipeline applies
to an imported meeting unchanged. Classification is by channel count rather
than track index, because stereo-means-system and mono-means-microphone is a
property of what they are rather than of the order this recorder wrote them in.

## A known speaker count is a good prior, and a bad one applied to one track

`Diarizer.run(_:expecting:)` sets `numSpeakers`, which is far stronger than any
threshold when the number really is known. It has to be applied to the right
audio, though: forcing 2 onto a system track that holds only the far end split
that one person into two voices, and the numbers looked plausible (532 s and
99 s) rather than obviously wrong.

So the prior is used only where the count is actually known for that track: 1
for a microphone track, the transcript's named count for a single mixed track,
and nothing at all for a system track, whose population is exactly what is
being asked. `Enroll` then attaches the microphone's voiceprint to whichever
named speaker the system side did not account for, which is the user.

A room recording is the one case where the microphone gets no prior either. How
many people are around a table is exactly the question being asked, and it is
the number nothing here knows: the calendar counts invitations, not chairs.

## The bank knew everybody except its owner

`Me` was the one label in the library with **no voice behind it**. Nothing
diarized the microphone track, so nothing ever produced an embedding for it, so
`embeddings.json` held every other participant and never the user. That went
unnoticed for as long as the mic track was labelled in one step, because a label
that needs no evidence needs no voiceprint.

It is the print a room recording needs. A room arrives as letters and something
has to say which letter is you, and the only thing that can is a `Me` centroid
pooled across the recordings where the microphone genuinely held one person.

So `Pipeline.printUser` files one on every call, from the same clustering the mic
pass already ran (`expecting: 1`, or the free clustering when a room came back
holding one voice). Measured on a 33-minute call: `Me`, 1110 seconds, 256 dims,
beside the far end's 376. Nothing else in the pipeline changes: `Me` is not a
placeholder, so `VoiceBank.named` pools it like any other name and `autoAssign`
can apply it to a room cluster with the thresholds already calibrated.

Two consequences worth knowing. A library recorded before this change has **no**
`Me` prints, so the first room recording cannot name the user and asks instead.
`listen enroll <id>` back-fills one from a call already on disk, since `Enroll`
has always derived exactly this print and naming an id bypasses the
"no voiceprints yet" filter; prefer that to `--force`, which rewrites every bank
in the library and clears the `auto` flags that keep an automatic name from
becoming evidence. And a room misread as a call
writes a print averaged over several people, which is the one way this puts
something wrong into the bank. Correcting the recording corrects the bank in the
same gesture, because a re-run rewrites `embeddings.json` whole.

## Synthetic voices measured the model's ceiling, not the task

The voiceprint thresholds were first calibrated on `say`-generated speech,
which gave same-person pairs of 0.979 to 0.995 and a suggested match threshold
of **0.72**. Re-measured on 14 voiceprints from real meetings across 5 people:

    same person       min +0.668  median +0.807  max +0.901
    different people  min -0.091  median +0.136  max +0.371

The worst genuine same-person pair is **0.668**, below the synthetic threshold.
Shipping 0.72 would have refused to suggest a person the bank had already heard
four times, and it would have looked like the feature simply not working rather
than like a number being wrong.

One TTS voice reading two scripts is nearly identical to itself. A person on
two days, on two microphones, in two rooms, is not. The different-person side
moved the other way (0.597 synthetic against 0.371 real), so both errors pushed
toward a threshold too high to be useful.

The thresholds are now 0.47 and 0.57, one third and two thirds across the real
gap. The lesson generalises past this feature: synthetic audio is fine for
checking that a pipeline runs, and worthless for choosing a threshold.

### A suggestion is scored against the worst print, not the best evidence

Reported as "it says 60% and it is right, why so low". Measured on the real
library, and the number is doing three things at once that are worth keeping
apart.

**It is a cosine similarity printed as a percentage**, which invites being read
as a confidence and is not one. Real same-person pairs run 0.668 to 0.901; real
different-person pairs top out at 0.371. 0.603 is past `strongThreshold`, and
the runner-up for that speaker was 0.231, a gap of 0.372 that is wider than the
entire different-person range. `SpeakerPicker` prints `Int(score * 100)` and
nothing beside it says any of that.

**`suggestions` takes the max over a person's prints and does not pool them.**
One embedding per person per recording, no centroid.

**And the person had exactly one print.** Five recordings of the same voice, one
of them labelled. Worse, the labelled one is the outlier of its own cluster:

| voiceprint | vs the new speaker |
|---|---|
| 2026-07-16 `A`, unnamed | +0.867 |
| 2026-07-09 `A`, unnamed | +0.691 |
| 2026-07-02 `B`, unnamed | +0.667 |
| 2026-07-30, the only one named | **+0.603** |

It scores 0.49 to 0.61 against the other three, which score 0.61 to 0.71 against
each other. Not crosstalk from the microphone track, checked: -0.095 against the
user's own print from that recording. Just a worse day for that voice.

So the app compared against the single least representative recording it had,
because that was the only one anybody had named. Three levers, in order of size:
labelling the other four costs nothing and takes the score to 0.867; pooling the
prints into a centroid gives **+0.828** here and is robust to one bad print in a
way `max` is not; and offering the unnamed speakers that match a name somebody
has just applied would have surfaced those four without being asked.

The first two are now done and are the section below. The third, back-filling
the recordings that match a name somebody has just applied, is not.

### A person is a centroid, the number is a word, and the sure ones name themselves

The three things the section above asked for, measured together because they
only make sense together: pooling changes what the score means, the score being
meaningful is what lets it be a word instead of a number, and a word nobody has
to interpret is what makes acting on it without asking defensible.

**Scored against a centroid.** Every evidence-grade print for a name,
normalised, averaged, normalised again. Unweighted by speech seconds on purpose:
pooling exists to average over rooms, microphones and days, and weighting by
duration lets the single longest meeting decide what somebody sounds like. A
person with one print is unaffected, so nothing regresses.

Re-measured for this scoring, leave-one-out over the whole library, 20
same-person and 112 different-person comparisons:

    same person       min +0.642  p10 +0.746  median +0.863  max +0.914
    different people  min -0.166  median +0.110  p99 +0.360  max +0.371

Against the pairwise numbers in the section above (same-person min +0.520,
different max +0.393) that is a wider gap from a more stable statistic, which is
the whole argument for pooling.

**The percentage is gone.** `VoiceConfidence` is three words over the same
thresholds. The number was a cosine times a hundred, and on a scale where the
entire answer lives between 0.37 and 0.91 it spends most of itself where nothing
happens: a correct, unambiguous match displayed as "60% match" and was read as a
coin flip. The row now says how sure and how much was heard, and names the
runner-up **only when the margin is genuinely narrow**, because a ranked list
otherwise hides the one fact that would make somebody listen before choosing.

**A sure match names itself.** `VoiceBank.autoAssign` runs from
`Recording.markTranscribed`, the one call the queue and `listen transcribe`
share. Four properties, each of which is the reason it is safe rather than a
detail:

1. **Level and margin, not level alone.** `certainThreshold` 0.75 takes 85% of
   true matches with **zero** false pairs above it, and gives up five points of
   recall against 0.65 to buy 0.379 of clearance over the worst different-person
   pair, which is more than the whole gap. `marginThreshold` 0.15 sits far below
   the smallest observed correct margin (+0.436), so it costs nothing today and
   is not fitted to a six-person sample. It exists for the case this library has
   already had, where one bad print put the user's own voice at +0.87 against
   somebody else's name: two strong candidates means nothing is applied.
2. **An automatic name never becomes evidence.** `VoiceBank.named` skips prints
   flagged `auto`. Without this one wrong assignment recruits the next and each
   round is more confident than the last. Only a person renaming that speaker
   clears the flag, and "the name is still there" is deliberately not counted as
   somebody agreeing with it.
3. **It goes through `TranscriptEditor`**, the same write the window and `listen
   label` use, with `backup: false` so it does not leave a `.raw.json.bak`.
   That file is how `hasHumanEdits` knows to warn before Transcribe Again throws
   corrections away, and a recording that warns about work nobody did is how you
   teach somebody to click through the warning that matters. `hasHumanEdits`
   excludes `metadata.auto_named` for the same reason.
4. **It is written down.** `metadata.auto_named`, `listen show`'s `(by voice)`
   marker, and a line on stderr per assignment, which is the arrangement the
   dictionary counts have and for the stronger version of their reason: this
   writes somebody's name into an archive nobody may open for a month.

One thing it deliberately will not do: two placeholders in one recording cannot
both take the same name. That is either a diarizer split or a wrong match, and
neither is a thing to decide without being asked.

**Not built, and the gap worth knowing.** There is no way in the window to
*confirm* an automatic name, so its print stays out of the bank for good unless
somebody renames that speaker. That is the safe direction and it is not the
right end state.

## Naming a voice nobody has heard was the whole difficulty

Reported from real use, and it is the complaint the two sections above were
circling without landing on. `SpeakerPicker` asks "Who is Speaker A?" and offers
how long they spoke, what the voice bank ranks them against, and who was on the
invitation. Every one of those is inference. The evidence that settles it in two
seconds is the voice, and that was the one thing the popover did not offer.

Getting it meant dismissing the popover, finding one of that speaker's
paragraphs in the transcript and clicking it. On the recordings where this
matters most that is a search rather than a click: measured on this library, one
97 minute call has a speaker who talks for **0.0 minutes** and another for
**0.1**, and a 43 minute call has one at 2.6%. Those are also exactly the
speakers most likely to be a diarizer artefact rather than a person, which is a
judgement nobody can make without listening.

**The picker plays through the pane, and does not own a player.** `SpeakerPreview`
is four closures handed down from `DetailView.editSpeaker`. The pane already has
the recording open and its mixdown built or buildable, so a second `AVAudioPlayer`
here would be a second audio path to keep in agreement with the first. The side
effects are the argument as much as the saving: pressing Play moves the playhead
below the popover, colours the scrubber, and scrolls the transcript.

`isPlaying` deliberately reports **playing or about to be**, folding in
`DetailView.preparing`. The first press on an hour-long meeting spends seconds
mixing two tracks before there is a player at all, and a button that stays on
"Play" throughout reads as a press that did nothing.

The button is polled three times a second while the popover is open, which is
not laziness. Playback stops **on its own** at the end of that speaker's last
turn and nothing reports it back here, so a button drawn once would sit there
offering to pause something already stopped.

### Asking about a speaker points the player at them, and never takes the transcript away

Opening the popover about somebody makes play run through their turns in order
and picks their bars out of the waveform. Closing it, by dismissing it or by
applying a name, puts playback back. The transcript is untouched throughout.

Two ways in, and they differ by one click: a chip under the title opens the
popover directly, and a pill in the transcript opens a menu whose first item is
that popover. See "Both buttons on a pill open the same menu" above.

**It used to hide every paragraph but theirs, and that was the complaint it
earned.** Two versions of the same mistake, in order:

1. The filter outlived the popover, with a bar carrying a "Show everybody"
   button. The ordinary way out of a popover is to click away from it, so the
   ordinary outcome was a transcript with most of its paragraphs missing and
   nothing on screen still asking anything.
2. The filter was tied to the popover's lifetime, which fixed the orphan and not
   the filter. Clicking a name to find out who somebody is is a **question**, and
   answering it by deleting the meeting from the screen reads as the app having
   mislaid the transcript. Reported by the user as "don't do that", which is the
   right length of review for it.

What is left is the part that could not be had any other way, and it is about
audio rather than about reading: play runs through their turns, and the waveform
greys everybody else so a speaker with four words in an hour is findable. See
"The waveform dims everybody but one" in `window.md`, which was always the better
half of this feature.

`DetailView.focused` is what the state is called now. It may not filter `turns`,
`sentences` or `turnViews`, and that constraint has outlived the filter: `refresh`
indexes all three against each other twenty times a second and the sentence
editor writes back through the same indices.

Two things survive from the old design:

1. **Both kinds of chip go through it.** A named speaker's card gets the same
   treatment as the unnamed picker, through `PersonPopover.show(closed:)`, so
   there is one rule rather than two that agree today.
2. **The undo hangs off `viewWillDisappear`, not off a delegate.** It is the one
   hook both ways out go through: a `.transient` popover is dismissed by clicking
   anywhere and tells nobody, and applying a name closes it from the inside.

**The close is guarded by a token.** A transient popover reports its close
whenever it gets round to it, and clicking a second chip opens one popover while
closing another, so a late close from the one being replaced would clear what the
new one had just set. `DetailView.focusWhile` takes the next token and hands back
an undo that only fires for its own.

Verified by driving the real window over a scratch library: a 3 speaker, 48
paragraph meeting reports 48 paragraphs before opening a speaker's popover and 48
with it open, where the old build left 16.

### The skipping belongs to the button that names it, and there is no bar

There was one for a while, under the player: "Play runs through Edgar, skipping
everybody else · 16 turns · 1:32". It was honest, and it was **a line of layout
that appeared and vanished on a click**, so asking who somebody was pushed the
whole transcript down a row and let it back up again. That is a worse thing to do
to a reader than the sentence was a good thing to tell them, and it was reported
as such within a day.

So the bar is gone, and with it the case it existed to excuse. Skipping is now
gated on `DetailView.playingFocused`, which is true only while the **popover's
own Play** is what is running, and that button says "Play what they said,
skipping everybody else" in the tooltip and stands next to "Spoke for 0:11 of
this recording". Every other way to start playback means the meeting and clears
the flag: the pane's play button (`playPressed`, which exists only to do that
before calling `togglePlay`), a scrub, a click on a sentence, and closing the
popover.

The named side therefore no longer skips at all, because a contact card has no
Play button and never explained it. What a card still does is colour that
person's bars in the waveform, which moves nothing.

Measured on a 4:10 recording whose speaker A has turns at 18.9-20.8 and
42.3-67.9, sampling the transport clock twice a second:

    picker's Play    00:19 00:20 00:42 00:43 ...   jumps the gap
    pane's play      00:00 00:01 ... 00:06         plays it all, popover open

The second line is the whole point of the flag: before it, that press jumped
straight to 00:18 with only the bar to say why.

What is deliberately **not** here: no way to filter the transcript to one
speaker, from a menu or anywhere else. If reading one person ever becomes a real
need it is a mode with its own control and its own way out, not something a click
on a name does on the way past.

### Play starts at their first turn, not their longest

The first version started at the longest thing they said, on the reasoning that
identifying a voice wants continuous speech rather than important speech, and
that ranking turns by length picks the most rambling one, which is useless as a
summary and ideal as a voice sample. That reasoning is fine and the rule is still
wrong, for a mechanical reason: `focusStep` only ever moves **forward**, so
starting in the middle means the turns before it can never be reached, and two
presses of Play give two different halves of the same person.

One press plays all of them, from the beginning, which is the only behaviour that
needs no explaining. There is no offset into the first turn either: the jumps
between turns land on `start`, so an offset would make the first snippet the one
clipped differently from the rest.

Measured on a 48 minute call, one speaker with 50 turns: playback started at
00:34, which is their first turn at 33.7 s, and 9.6 seconds of real time covered
11 seconds of recording. The difference is exactly the gaps it skipped.

### `metadata.state` cannot say who is waiting, and `effectiveState` inherits that

`Labelling` puts the question to the transcript, and the reason is a measurement
rather than a preference. Over the 31 transcribed recordings in the development
library:

| stored state | recordings | of those, actually holding an unnamed voice |
|---|---|---|
| `needs_labelling` | 14 | 10 |
| `pending` | 3 | 3 |
| `done` | 14 | 0 |

So the field is wrong in **both** directions. It only becomes `done` when
`TranscriptEditor.apply` runs, and the imported half of this library was labelled
by a Python pipeline that never called it, so four recordings where every speaker
has a real name go on claiming to be waiting for somebody. `effectiveState` is
derived from the same field and reports 17 where the truth is 13.

A speaker is waiting exactly when its label is one `Merge.letter` invented, which
is what `VoiceBank.isPlaceholder` already answers, so that is the whole predicate.

Cached against `turns.json`'s modification date, and both halves of that matter.
The sidebar asks this of every recording on every reload, and a reload is every
keystroke in the search field, so the uncached form is a full JSON decode of
every transcript in the library per character typed. Keyed on the date rather
than held for the life of the process, because naming somebody rewrites that
file: a cache that never expired would be a to-do list that does not go down as
the work is done, which is worse than no list. Behind an `NSLock`, which is the
rule `MeetingCalendar` sets and for the same reason: the sidebar asks on the main
thread and the MCP server asks through `RecordingFilter` on another.
