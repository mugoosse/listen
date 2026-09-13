# Reviews on iPhone, and one job instead of four

Scope, not a plan of record. Written 13 September 2026, after the Mac review
shipped and before any iOS work started. Numbers in it are measured on the real
library on that date and are the reason for most of the recommendations.

## 1. Why this is not a port

`WeeklyReview` is in the Mac target and reads `Recording.all()`,
`People.roster`, `PeopleMemory.person`, `Notes.all()`, `Chat.all()` and
`MeetingCalendar.upcoming()`. The phone has none of those. It reads the sealed
card projection through `ContextSync.readCards`, holds its own recordings, and
has no ledger, no `people-context.json` authorship and no EventKit access to
the Mac's calendars.

So the work is a **seam, not a copy**: everything above the fetch is already
shared-shaped, and the fetch is the only part that differs.

### The seam

Move the card building into ListenKit behind one protocol:

```swift
public protocol ReviewSource {
    func conversations(in: DateInterval) -> [ReviewConversation]  // id, title, when, people, seconds
    func notes(in: DateInterval) -> [ReviewNote]
    func claims(about: String?, in: DateInterval) -> [ReviewClaim] // text, quote, source, date, attribute, status
    func roster() -> [ReviewPerson]                                // label, display, count, lastSeen
    func upcoming(limit: Int) -> [ReviewMeeting]                   // may be empty
}
```

`WeeklyReview.build` becomes `ReviewBuilder.build(scope:window:source:)` in
ListenKit and stops importing anything Mac-only. `Scope`, `Card`, `Kind`,
`Stat`, `Item`, the ordering, the wording and every rule about which cards a
person gets move with it. Two conformances:

- **`LibraryReviewSource`** (Mac): what `WeeklyReview` does today, unchanged.
- **`CardReviewSource`** (iOS): recordings from the phone's own library; claims
  from `ContextSync.readCards` via the shared `ContextSearch`/`ContextBuilder`
  contract; notes from the synced notes; `upcoming` returns `[]` unless the
  phone is given calendar access, which is a separate consent and out of scope.

### What does not travel

- **The galaxy.** There is no Metal scene on the phone and building one is not
  this piece of work. The iPhone review is the deck alone, which is the right
  shape for a phone screen anyway.
- **The reveal**, for the same reason.
- **Accept / Correct / Hide** travel, because the phone already has the
  correction contract (`.agents/notes/person-context.md`: "iPhone uses native
  List/disclosures/forms and the same correction contract").
- **Leave out** travels: per-person consent is a `MemoryPreferences` register
  and the phone already publishes explicit corrections.

### Shape on the phone

A fourth tab or a row on Library, opening a `TabView(.page)` of cards with the
native paging dots, which is the iOS idiom the Mac deck's rail is imitating.
Swipe rather than Next. `PRODUCT.md`'s principles apply: familiar controls,
quiet feedback, no invented spectacle.

### Order of work

1. ~~Lift the builder into ListenKit behind the protocol; Mac conforms;
   `verify_review.sh` passes unchanged.~~ **Done, 13 September 2026.**
   `Sources/ListenKit/Review.swift` holds `ReviewScope`, `ReviewCard`,
   `ReviewKind`, `ReviewStat`, `ReviewItem`, `ReviewRef`, the `ReviewSource`
   protocol and every card. `Sources/listen/WeeklyReview.swift` is now
   `LibraryReviewSource` plus a thin facade: 515 lines became 163, and the 352
   that moved are the ones the phone needs. The suite passed with the script
   byte-identical, which was the whole acceptance test.

   Three things the lift decided, worth knowing before writing the phone's
   source:

   - **Star references leave as `(kind, key)` pairs**, never galaxy ids. The
     builder has no idea what a galaxy is and must not: `ReviewRef.galaxyID` is
     an extension in the Mac target, and the phone will map the same refs to
     navigation destinations instead.
   - **Attendees are resolved to roster labels by the source**, not by the
     builder. Matching an email address to a person is a thing each platform
     does its own way, and `CalendarPerson` is EventKit's shape.
   - **`length` had to be copied rather than shared**, because
     `Recording.length` is a Mac display helper and the two appear on one
     screen. They are the same four lines and a comment says so; if either
     moves, both move.

   One trap it cost: `card.stars` stopped being `[String]` and
   `JSONSerialization` accepts Foundation types only, so `listen review --json`
   compiled and then threw "Invalid type in JSON write" at runtime. A Swift
   struct in a `[String: Any]` payload is a runtime failure, never a build one.
2. `CardReviewSource` on the phone, with a CLI-equivalent check on the Mac that
   runs the builder against a *synced card* source and compares card kinds.
3. The SwiftUI deck.
4. Regenerate the iOS project after adding shared files, then build the arm64
   simulator target (`person-context.md` records that the FluidAudio archive
   lacks x86_64 simulator code).

## 2. Processing everything at once

Shipped as part of this: `ContextService.catchingUp`, a
"Read Everything Now" button in Settings, People & Memory. The daily limit is a
pace rather than a permission, and a manual run has always bypassed it; what
was missing was a manual run covering the whole backlog instead of one person's
next four parts.

**Measured, 13 September 2026, 40 real requests:**

| | |
|---|---|
| Median passages per request | 8,008 characters |
| Median prompt | 12,149 tokens |
| Median cost | $0.034 |
| Median duration | 6 s |
| Backlog | 432 parts ≈ **$15 and ~49 minutes** |

The button prices itself from `ContextBudget.recent()`, which is this library on
this model rather than a constant, and says so only once there are at least five
priced rows to go on.

## 3. One job instead of four, and what the numbers actually say

The instinct is right and the reason is sharper than "fewer calls".

**8,008 characters of passages is about 2,000 tokens. The median request is
12,149. So roughly 83% of every request is the instruction and the prior claims,
re-sent every time.** The conversation is the small half. That reframes the
whole question: the waste is per-request overhead, not per-character.

Three consequences, in the order they are worth doing:

### a. One extraction per source when everybody in it is enrolled

Extraction is scoped per person because scope **is** the consent boundary:
`verify_context.py` asserts "a shared recording authorizes only the selected
person". That must not change. But now that enrolment is the default, the
common case is that every named speaker in a recording is already enrolled, and
then the scoping buys nothing and costs a whole request's overhead per person.

So: when every named speaker in a source is enrolled *and* has the same
executor and model, extract once for all of them. Fall back to per-person
scoping the moment one of them is not. A three-person meeting goes from six
requests to two, and each saved request was 83% overhead.

Receipts already key on subject scope, so this needs a scope that means "these
three" rather than "this one", and the ledger pruning note in
`person-context.md` is the thing to read first.

### b. The note comes out of the same call, not a fifth one

**This is table stakes before it is an optimisation.** Plaud, Pocket and Granola
all write a summary the moment a recording ends, so a user arriving from any of
them expects one and reads its absence as the feature being missing rather than
as a decision. That changes the priority: it is not a saving, it is a gap.

It should still be **off until somebody turns it on**, and the app already has
this exact shape three times over: `askEnabled`, memory enrolment and sync are
each off by default, each asked once during setup in the words of what they do
and what they cost, and each configurable afterwards. A fourth follows the same
pattern, and the memory step is probably where it is asked rather than a step of
its own, because they are the same sentence: *this reads your conversations with
your model.* One `Settings.autoSummary`, one line on that step, one control in
People & Memory.

**On paywalling it later: the cost argument that works for those three does not
work here, and that is worth knowing before pricing it.** Granola and Plaud
charge partly because they pay for the inference. Listen does not: the model is
the user's own, `.agents/notes/agent.md` records that Listen never sees a key,
and an auto-summary spends the user's provider budget rather than yours. So a
paywall on this is a paywall on convenience, polish, sync and support, not on
compute, and the honest version of it says so. The good news is that it is
cleanly separable: one setting, one job, no entanglement with recording or
transcription, which stay free and local whatever happens above them.

Now the engineering, which is the same either way: **not as a separate job, and
never as an input to memory.** Extraction is built on exact
quotes with UTF-16 offsets into a real transcript; a summary of a transcript
is not a witness, and reading memory out of one would launder the provenance
the whole system rests on. `person-context.md` already records that generated
notes "are not extracted as independent witnesses" for exactly this reason.

What works: have the extraction call return the note **alongside** the claims,
from the context it already has. One request, two artifacts, and the note is
written only when every speaker is named, which is the condition that makes it
worth reading. That is strictly cheaper than today, where the note does not
exist at all.

It also feeds the review directly: the "what happened" half of a card could
quote the note instead of the first claim.

### c. Prompt caching is probably the biggest single win, and is not architecture

If the 10,000 tokens of instruction and prior claims were cached rather than
re-sent, the per-request cost would collapse without changing the pipeline at
all. `person-context.md` notes that "provider-reported usage includes Claude
cache input tokens", so the plumbing to observe it exists. Whether the Claude
Code CLI path caches a repeated system instruction is **unmeasured**, and
measuring it is a morning's work with the numbers above as the baseline.

Do this before (a), because if caching already works the case for (a) is much
weaker, and if it does not, (a) and (c) compound.

### What not to do

Do not raise the 8,000-character batch cap to cut request count. It is a
quality boundary rather than a cost one, and trading extraction accuracy for
tokens is the wrong direction for a system whose whole claim is that every line
traces to something somebody actually said. If it is ever raised it needs the
measurement that set it, not an argument from arithmetic.
