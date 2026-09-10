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
