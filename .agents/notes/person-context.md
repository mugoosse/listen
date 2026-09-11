# Person memory, temporal provenance and local retrieval

The implementation record is `docs/people-memory-implementation.md`; the dated
Hermes/Honcho source review is `docs/people-memory-review.md`. The review's
original prototype assessment is historical, not the current storage contract.

## Ownership and storage

`ContextDatabase`, `ContextLedger`, `ContextCard` and `ContextSync` are shared
ListenKit code, compiled by both apps. Mac ingestion lives in `ContextSources`,
`PeopleMemory`, `ContextStore`, `ContextProcessing` and `ContextConsolidation`.
`ContextRetrieval` adapts that ledger to the shared reading contract.

`context/memory.sqlite` uses WAL, full synchronous commits, bound SQL, FTS5 and
Float32 vector blobs. Sources, receipts, observations, transitions, entities,
reviewed aliases, summaries, overrides, jobs and usage have explicit tables.
The directory is private to the owner. Source recordings and notes remain
primary. Corrections are authoritative user data, not a rebuildable cache.

Legacy `memory.json`, `sources.json`, `search.json` and `dismissed.json` migrate
once in a transaction. Claim identities are translated and hidden preferences
preserved. Summaries citing old IDs are rebuilt. Legacy files are removed only
after commit. Unsupported schema versions fail closed. Never delete the whole
context directory to repair an index: it contains the user's corrections.

## The model proposes; Listen validates identity and evidence

Subjects use stable entity IDs and reviewed aliases. Explicit People renames
preserve identity; explicit merges transfer corrections. Similar spellings never
merge automatically. Whole-name mentions and reviewed aliases can associate a
note with someone. Generic pronouns, attendance and shared tags cannot establish
a relationship. `Me` in ordinary prose is not an identity match.

Extraction processes named passages even if another speaker is unidentified.
Every eligible passage has a receipt, including empty successful extraction.
Requests cover at most 8,000 characters of eligible passages, split near 1,500
characters, plus at most two adjacent passages for interpretation. Adjacent
context cannot be cited or assigned to an unidentified person. Long recordings
continue through separate batches; no truncated prefix can mark the whole source
reviewed. Generated Ask notes remain searchable navigation material and retain
their source groups; they are not extracted as independent witnesses.

Claims use a controlled vocabulary, exact quote/UTF16 offsets, source revision,
speaker and subject, recording offsets, recorded time and learned time, assertion
polarity/modality/attribution, and provider/requested/resolved model where known.
Source dates do not establish that a claim is currently true. Subject attribution
and relationship targets are verified against the supplied source and roster.
Matching a quotation proves occurrence, not perfect interpretation; model output
remains fallible and user corrections remain explicit.

Extraction, reconciliation and summaries each allow one bounded repair through
the identical validator. Failed extraction is quarantined, remains pending and
backs off. Successful retry removes the rejected response. Quarantine is removed
when its source changes or disappears. Never put private content in telemetry.

## The model proposes in writing now, and a person still applies it

"The model proposes" was true of extraction and false of everything after it. An
agent could read a claim, read the transcript under it, see the two disagree, and
had nowhere to put that: `get_person_context` hands out claim ids, and `correct`,
`pin` and `dismiss` were the window's and the CLI's alone. What it could do was
say so in an answer, which dies with the conversation.

`ContextSuggestions` is the inbox, modelled closely on `DictionarySuggestions`
because that file had already solved this shape: something notices a change worth
making, a human is the only thing allowed to make it. Same document, same
worklist behaviour, same encoder settings, including `dateDecodingStrategy =
.iso8601` on the **decoder** as well, which is the bug recorded in
`notes-tags-dictionary.md` that made every suggestion invisible.

Three properties are the whole design:

- **The wording only.** The one field carried is the replacement text, which is
  exactly what `context correct <claim-id> <text>` takes. Subject, predicate and
  evidence are unreachable from here, so the rule above is enforced by shape
  rather than by validation.
- **Accepting goes through the existing contract**, `ContextStore.override` and
  then `SemanticIndex.refresh`, which is what the person page and the CLI already
  call. A correction that did not reach the index is one search still disagrees
  with.
- **A dismissal outranks a repeat.** An agent re-reading the same transcript next
  week reaches the same conclusion, and somebody who has already said no should
  not be asked again. `suggest_context_correction` refuses with that in words, so
  the model puts it in the answer instead.

A claim id is resolved against the store before anything is queued, so an
invented one is refused at the tool rather than found missing later by whoever
tries to accept it. The file is not in `DevicePolicy.blobs`: `dictionary.json`
syncs because two devices with different vocabularies transcribe differently, a
worklist is not a fact about the library, and the context store already has an
owner projection with its own correction register to reconcile.

Three surfaces act on one worklist, and all three go through
`ContextSuggestions.accept`: the row under the claim on a person's page, the
`listen context suggestions --accept` flag, and nothing else. The pane in
Settings counts what is waiting and names whose page to open; it deliberately
does not accept anything, because that decision needs the claim's own evidence
one disclosure away and the pane has none of it.

## A suggestion inside a collapsed disclosure is invisible

The row shipped, the pane counted it, and the page showed nothing. `Details` on
a person page opens collapsed, every claim lives inside it, and so did the
suggestion row. So the sentence the pane had just written, "open that page to
accept or dismiss", led somebody to a summary with no sign of what they came
for, which is the exact failure a worklist with no surface has.

Two changes, and both are needed. `reload` opens `Details` when anything under
it is waiting, set on load rather than in `render` so the reader can still close
the section afterwards. And the disclosure's own title carries the count,
`Details (4) · 1 suggested`, because a section that can be closed again should
still say there is something in it to answer.

**The test found this and then hid it.** The first version of the UI check
skipped with "is the display asleep?" whenever the row was missing, which is
true of a sleeping display and equally true of a row that is simply not there.
Separating the two is the rule `verify_dictionary.sh` already follows: the
window has to prove it is on screen, and past that line a missing row is a
failure. It reported a defect within a minute of being told the difference.

**A fixed wait reported a sleeping display on a Mac that was merely busy.** The
UI section runs straight after the headless half has spent a minute in the same
process, and seven seconds was not enough to open a window on a loaded machine.
It polls the tree until the window appears now, up to 25 seconds, which is the
one thing in this dance that is safe to repeat.

## Coverage is a number the agent could not see

`get_person_context` reports one entity's `pending`, and `listen context status`
reports the library's. Only the first was reachable, so an agent asked about
somebody with no facts could say "nothing recorded" and could not say why.
Measured on the real library: Edgar, 53 sources pending and no card at all;
`context status`, 321 pending and **2 recordings waiting for speaker names**,
which is the only number in either place that names something a person can go
and do.

`get_context_status` returns `ContextCLI.Coverage`, lifted out of the CLI's own
`status` case so the two cannot come to different totals. `list_context_entities`
carries the counts per row as well, because finding out who Listen knows anything
about otherwise costs one `get_person_context` per entity.

**An entity with no card still has a queue.** `cards()` builds one only for a
label appearing in a valid receipt, so somebody entirely unprocessed is missing
from it, and a row reading `claims: 0` with no `pending` would say "nothing known
and nothing coming". The fallback reads `PeopleMemory.person` for those, with the
document loaded once for the whole listing.

## Exclusion reaches search, and now there is a test that says so

`ContextSources` drops an `exclude_from_ai` note at source selection, and this
file says to check exclusion at retrieval rather than only at index construction.
`verify_context.py` asserted the card and the MCP note read, and not search.
It does now, and the answer was that the gate already holds: excluding a
processed note stops its passages coming back from `context search` in the same
pass that revokes its evidence from the card.

## Temporal changes have their own evidence

`ContextTime` preserves effective boundaries and original wording separately
from source/import times. Fully stated ISO or English/Portuguese/Dutch month-name
calendar dates can resolve to a day. Relative phrases, missing years and ambiguous
numeric dates remain wording only. Current source metadata lacks original locale
and zone, so resolving “next Friday” from the Mac's current settings would guess.

Consolidation considers at most eight fresh observations plus 24 relevant earlier
ones per person, at most four people per pass and 16 operations per proposal.
It can add support, link a paraphrase, retain a conflict, supersede or retract.
An ending needs direct asserted change evidence, a stated effective date, the
supporting observation IDs and exact source quote. A negative assertion such as
“I stopped leading Atlas on 2026-02-12” can end its prior positive state. A
completed handover decision can end the corresponding role/project relation.
Plans and uncertain third-party reports cannot do this. Parallel roles coexist.
No model confidence or source-count heuristic decides truth.

Transitions, checkpoint and leased job completion commit in one transaction.
Temporal cycles and incompatible paraphrases are rejected. Canonical groups
retain source attribution, polarity, modality, times and relationship objects.
Corrections/pins/hides apply to reviewed equivalent IDs. Newer resets and unpins
must win too. Override timestamps compare actual instants, including old whole
seconds and newer fractional seconds. `mark` advances within a rapid same-second
edit, preventing a reset from losing to the old value in sync's tie-breaker.

Deleting/changing a source removes its observations and searchable content.
Unsupported events retain identifiers with their quote removed. A removed ending
or contradictory premise yields Needs Review and invalidates cached brief text;
it never silently restores a former current value. Alternative complete support
sets preserve an independently supported transition. Corrections survive source
removal. Briefs are generated from current ledger entries, including explicitly
labelled historical changes, never from their previous text.

## Hooks, consent and foreground priority

Content revisions exclude filing-only title/tag changes. Metadata refresh updates
source links without another model request. Resolve both URLs before deriving a
relative path: `/var` and `/private/var` can otherwise create permanently missing
source stamps. High-resolution modification time, inode and size invalidate Mac
reads immediately; owner projections verify actual file hashes with that cache.

Source-change hooks debounce for two seconds; a 30-second scan recovers missed
events. Generation consent is scoped to the library path. Automatic briefs also
respect Ask enablement; explicit manual/CLI updates authorize their own run.
Local indexing/deletion cleanup continue when generation is off. Capture and
interactive Ask preempt automatic work. A queued manual person request retains
its scope and authorization after indexing or foreground interruption.

A process lock serializes generation. Extraction/reconcile/summary jobs have
revision identity, a 600-second lease, atomic completion, retry backoff and
recovery after process death. Lease expiry exceeds two 180-second provider calls.
Cancellation and exhausted work budgets release leases without treating the
source as corrupt. New work supersedes obsolete pending reconciliation jobs.

Settings → AI → People & Memory owns Automatic Briefs, background model, daily
request/parts limits, usage and local search. The background picker reuses Ask's
provider/model menu with its own preference and an explicit Use Ask's Model
choice. Freeze the provider/model for each sweep; failure never silently changes
providers. Default limits are 40 daily requests and four extraction parts per
pass; repairs and summaries count as requests. Provider-reported usage includes
Claude cache input tokens. Unknown token/cost values stay unknown.

Ask's sessions retain their existing restrictions: Claude built-ins disabled,
Codex read-only sandbox, user hooks/global MCP suppressed, endpoint allowlists
and managed loopback policy. A CLI is usually a remote provider, despite running
locally. Only a configured local endpoint can make extraction fully offline.
The final stdout drain waits for in-flight readability callbacks before emitting
completion; otherwise short valid CLI JSON could appear empty and waste a repair.

## Reading and owner sync

`ContextBuilder` returns deterministic person/project context at a requested
256–16000 token budget (1500 default), optionally ranked for a question or filtered
by `as_of`. Validity intervals have exclusive ends. Unknown dates stay unknown.
A packet reports omitted entries and pending state, with original source quotes.
UI, Ask, CLI and MCP use this contract. Reading never invokes generation or an
index rebuild. iPhone Ask can answer from a saved card without sending transcripts.

`people-context.json` is the explicit owner projection: cards, source proofs and
user overrides. Jobs, usage, vectors, credentials and library key are excluded.
`people-context-edits.json` stores per-field owner corrections. Existing private
CloudKit sealing encrypts a small blob header and separate `context.json` asset,
avoiding the record-payload size limit. A phone cannot publish generated cards;
it merges and publishes explicit corrections. Incoming files are validated before
replacing a good copy. Larger-than-supported versions/sizes fail closed.

A partially processed second Mac preserves verified remote entries until its
own source is fully reviewed, including authoritative empty extraction. Original and change
quotes remain source checked; remote cards are never inserted as new observations.
Reviewed entity aliases and overrides can travel in the owner projection. No
public/shared-link context publication is added. CloudKit production deployment
must include `r3.assetNames` and `r3.asset_context_json` before distribution; local fake-store tests
cannot establish production schema availability.

Mac pages use Brief, quiet categories, neutral source rows, Details and History,
with source counts and an options menu. Correct, Pin, Use Source Wording, Hide and
Undo remain separate from source text. iPhone uses native List/disclosures/forms
and the same correction contract. Returning from Settings must restore the
selected person/note, and library reload must not reset its scoped Ask composer.

## Text embeddings are not voiceprints

Apple NLEmbedding is the zero-download baseline. Its language-specific spaces
cannot be compared; unsupported languages retain keyword search. Optional
multilingual-e5-small uses native MLXEmbedders and a pinned local model directory,
384-dimensional masked mean pooling, normalization and query/passage prefixes.
512-token limits are respected with bounded windows. Model namespace includes
revision/tokenizer/pooling/dimension/prefix format. Only the explicit download
accesses the network, about 500 MB; inference never has a remote fallback.
`recordings/*/embeddings.json` remains the independent speaker voiceprint format.

Index source sentences and observation values separately. FTS/lexical and exact
vector ranking combine with reciprocal rank fusion. Apple floor .25; E5 .75 and
within .035 of the best candidate, capped at 30 semantic candidates. These are
retrieval heuristics, never confidence. Corrections suppress stale indexed wording
until its replacement is indexed; original passages remain cited history.

The end-to-end synthetic hybrid evaluation reached 11/15 top-one and 14/15 top-three. It is
optional, not a benchmark-proven default. Hard negatives include hiring versus
budget approval and a handover versus someone merely being a designer. See the
implementation record for current performance/quality measurements and their
limits. Do not turn a small fixture score into a production quality claim.

## Verification commands

**`defaults delete` does not delete the file.** `verify_context.py` gives each
run its own preference domain and deletes it at the end, and left a 42 byte
plist in `~/Library/Preferences` every time regardless: cfprefsd writes the file
back out for a domain the app has touched, so the delete lands and the litter
stays. Forty-two had accumulated over four days before anybody looked. The
`finally` unlinks the file as well now.


- `./build.sh && ./make_app.sh`
- `bash tools/verify_memory_core.sh`
- `python3 tools/verify_context.py` (isolated app identity, synthetic library,
  stub provider, real Apple embeddings; `LISTEN_CONTEXT_KEEP=1` retains it)
- `LISTEN_LIBRARY=<scratch> Listen.app/Contents/MacOS/Listen sync --fake`
- `bash ../listen-ios/tools/verify_ask.sh`
- Regenerate the iOS project after adding shared files, then build the arm64
  simulator target. The existing FluidAudio archive lacks x86_64 simulator code.

Native visual checks and real CLI runs use isolated synthetic data. Do not send
the personal library to a provider just to verify a change. Current results and
remaining external verification belong in the implementation record.


## Search reads the current card, even before the second device has an index

`ContextSearch` in ListenKit is the shared bounded claim-search contract.
Callers must pass verified cards (`ContextSync.readCards` on iOS, merged
`ContextRetrieval.cards` on Mac). Keywords and reviewed aliases always work;
available Apple sentence models provide local semantic ranking. Cached vectors
never cross language/revision namespaces or sync to another device. Search uses
the effective wording, not original quotes after a correction, and preserves
polarity, modality, status, dates and separate original/change sources. Historical
search uses the same exclusive end date as `ContextBuilder`.

Mac's indexed facts are ranking hints only; results materialize current card
entries. `search_context` and `context search --as-of` return structured memory,
and entity discovery includes verified remote cards. A received correction or
hide must take effect without reindexing. Sidebar freshness includes the owner
snapshot, edits file and its source dependencies, as well as the local ledger.

iPhone Ask searches memory before transcript fallback for generic questions,
not only when a name occurs. `search_context` is also available as a tool. Its
source registration preserves provenance while adding app-issued citation IDs;
user corrections get separate, non-recording evidence. Library memory results
obey type and source-tag filters and retain the existing incompatible People/tag
and Needs a speaker behavior. Native results open the person/project or the
recording/note requested by the active scope.


## Per-person consent and authored notes

`MemoryPreferences` stores source selection, automatic consent, frozen Mac/model,
requests/cancellation, aliases and deletion cutoffs as per-field owner registers.
Missing per-person consent is manual; the legacy global switch now only pauses
already opted-in people. Calling ContextService.refresh is never authorization.
Cancellation is a separate register so a late completion cannot override it;
off wins equal-clock automatic-consent conflicts. Background extraction,
consolidation, repair and summary must all pass the same current consent guard.

Person notes carry `about_person` separately from `speaker`. Note passages are
spoken/written by `Me`, so claims about the linked person are reported, not
self-disclosure. The explicit about link permits pronouns but cannot establish
an unsupported relationship. `exclude_from_ai` is a versioned note field, and
false must be persisted when clearing it; omission would preserve a peer's true
value. Check exclusion at retrieval, not just during index construction. Compact
cards, full-note MCP reads, note lists and active Ask histories all need this gate.

One source may contain several people. Scoped extraction filters both the list
of target people and their eligible passages. Receipt keys include subject scope,
but source content revisions stay shared: a per-person fingerprint breaks ledger
pruning when two independently consented people use one recording. Catalogues
retain per-person batch counts so partial source scope does not appear forever
pending. A new extraction after deletion uses fractional learned timestamps and a receipt/job key containing the deletion generation. Otherwise an old complete job refuses the new lease even though its receipt was correctly removed.

Do not discard local observation/transition provenance when adapting a merged
cross-device card for the full history UI/CLI. A compact reading card is not the
full local audit trail. Integration tests assert the transition quote and model.

The iPhone submits a durable request, never a substitute cloud generation. Model
metadata and requests use the already sealed owner blob asset transport, with
no new CloudKit record fields. Voice draft capture is independent of speaker
identification and Ask; saving a note alone never opts anyone into generation.

The iPhone reading view must mount a loading or empty row before its async card read. A `.task` on an initially empty `Group` inside `List` never started in the simulator: search and the controls saw five entries, but the brief stayed invisible. Keep the read on the always-mounted Brief section; verify actual person navigation, not only shared retrieval tests.

**A preferred Mac is a preference, not a lock.** Two Macs can offer different
models from different providers, so quietly running somewhere else changes what
wrote the summary and what it cost; and a hard pin turns "the Mac I chose is
shut" into a request that never runs and never says why, which is the failure
this area was repaired for in September 2026. `MemoryPreferences.plan` therefore
addresses the preferred Mac even when it is asleep, and hands the awake
alternative up as `insteadOf` for the screen to offer. Nothing substitutes on
anybody's behalf. A waiting request can be handed to another Mac from the person
page, and only while it is still `pending`: one a Mac has claimed is running
somewhere, and re-addressing it would put two Macs on the same conversation.

**A Mac that is recording does not begin, and the screen did not say so.**
`ContextService.refresh` returns on `!Capture.shared.isRecording` before it
looks at anything, so an explicit request addressed to this Mac sits at
`pending` for the whole call: its 30 second timer ticks and does nothing, and
Create Summary pressed during a meeting enqueues a request whose own
`refresh(manual: true)` returns on that same line. Measured on 10 September
2026: a nine source request created at 18:21, five minutes into a call, was
never touched again (`updated` still equal to `created`) while the person page
read "Waiting for this Mac to begin...". True, and useless, and the same
"never runs and never says why" that the preferred-Mac paragraph above exists
to prevent. The guard itself is right, because nothing should compete with the
meeting being recorded, so the fix is the sentence and not the schedule: the
pending line names the recording when the request's executor is this Mac and
this Mac is recording, and the next tick after Stop picks the request up
without anybody pressing anything again.
