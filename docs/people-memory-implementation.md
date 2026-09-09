# People and memory implementation

Updated 8 September 2026. This records the implemented architecture from
[the Hermes/Honcho review](people-memory-review.md), with verification and
remaining release checks kept separate.

## Implementation

- [x] Transactional SQLite store with WAL, FTS5, typed vectors and legacy migration.
- [x] Durable revision-keyed extraction, review and summary jobs, leases, crash recovery and retry backoff.
- [x] Stable person/project identities, explicit aliases, renames, merges and canonical user corrections.
- [x] Temporal observations with recorded, learned and supported effective times; immutable observation identity and source-backed transition history.
- [x] Bounded consolidation for changed people; paraphrase/support links, conflicts, supported supersession and retraction.
- [x] Source revision hooks with recovery scans, cancellation and foreground recording/Ask priority.
- [x] Independent background provider/model selection, enable/disable controls, automatic request limits and reported usage.
- [x] Shared question-ranked, budgeted person/project retrieval for Mac, iPhone, Ask, CLI and MCP, including effective-date queries.
- [x] Local lexical/Apple search and optional pinned multilingual E5 embeddings through native MLX.
- [x] Shared card search for generic Ask questions and native iPhone Library results; synced cards are searchable on another Mac before local indexing.
- [x] Explicit encrypted owner-device card projection and per-field corrections; native iPhone reading and correction UI.
- [x] Cleaner Mac Brief/Details/History presentation, source rows, project navigation and AI settings group.

The implementation lives in the new `Context*` ListenKit types and the Mac
`ContextStore`, `ContextProcessing`, `ContextConsolidation`, `ContextRetrieval`
and search modules. iPhone uses `MemoryView`, `ContextBuilder` and `ContextSearch`.
No Hermes or Honcho runtime is bundled.

## Person notes and explicit consent

A person page offers **Add Note** and **Create Brief**. Notes accept typed text or
local voice transcription into a draft, followed by **Save Note**. Saving writes
the ordinary Markdown note and a stable `about_person` identity. The author stays
the library owner: “she prefers…” can be attributed to the selected person,
while “I…” never becomes that person's voice. A rename/explicit merge preserves
the about link. Normal Ask answers do not become independent memory sources.

Memory starts manually for each person. Create/Update Brief opens a source
checklist and the same provider/model menu used by Ask. It sends only eligible
passages by/about that person, then uses previously validated details to review
changes and write the brief. Another participant does not get an extraction
merely because they attended. A successful unchanged source costs no new model
request. **Keep up to date for this person** is a separate optional consent;
it remembers deselected sources and permits newly linked sources. The Mac setting
**Allow automatic updates** is a master pause, never library-wide consent.

The Ask composer provides distinct Ask/Note intents. Note opens a reviewable
editor; Create Brief opens the explicit source/model boundary. iPhone queues an
owner request to the Mac/provider/model shown in its sheet, reports **Waiting
for your Mac**, and exposes cancellation. It never substitutes its OpenRouter
Ask model. Automatic consent binds a person to the selected Mac/model as well,
so a second Mac cannot silently take over background generation.

`people-memory-settings.json` is a bounded per-field register carried through the
existing encrypted owner blob transport. Requests retain source IDs, person ID,
provider/model/executor, state and timestamps, without credentials. A separate
cancellation register wins over late completion. An equal-clock automatic on/off
conflict resolves to off. The worker checks consent before every generation
stage, including repairs, and before committing results. Requests wait if their
selected recordings have not synced or completed transcription.

**Exclude from AI** keeps the note available to its owner and local text search,
while blocking memory, Ask and MCP access, including known note IDs and metadata
lists. Excluding existing evidence invalidates derived details immediately.
iPhone stops a provider loop if exclusions change; Mac endpoint rounds check
again and CLI sessions are cancelled when an exclusion changes. New Ask turns
start without old provider history when excluded notes exist. This cannot recall
text already sent to a provider before exclusion.

**Delete Generated Memory** is separate from turning automatic updates off.
Turning off retains saved details. Deletion writes a synced person cutoff,
cancels queued requests, stops automatic work, and removes old derived memory
without deleting source notes/recordings or another person's memory. A later
explicit request can generate a fresh brief. Voice drafts are capped at two
minutes and temporary iPhone audio is removed after transcription or cancellation.

## What provenance means in the running feature

An observation retains source revision, exact quotation and offsets, named
speaker, subject, assertion polarity/modality/attribution, independent source
groups, extraction version and provider/model information when reported.
Reconciliation commits its supporting observation IDs, change quote, effective
date, actor/model/version and checkpoint in the same transaction.

A later recording cannot end an earlier role by itself. An explicit completed
handover with an unambiguous full date can. Importing an older conversation later
does not restore the former role. Deleting an ending's only support removes its
quotation, clears dependent brief text and marks the earlier claim for review.
Original and change sources remain separately navigable in the reading contract.
Relationships retain negation, plans, uncertainty and reported attribution in UI.

Corrections, pins, hiding and resets are authoritative per-field user edits.
They survive reviewed paraphrases, renames and explicit merges. A correction is
labelled as the user's wording; Ask cannot cite it as words from a recording.
Generated Ask notes do not become independent witnesses.

## Verification

The reproducible automated commands are:

```sh
./build.sh && ./make_app.sh
bash tools/verify_memory_core.sh
python3 tools/verify_context.py
bash ../listen-ios/tools/verify_ask.sh
bash ../listen-ios/tools/verify_library_search.sh
bash verify_note_tags.sh
LISTEN_LIBRARY=<scratch-library> LISTEN_NO_KEYCHAIN=1 Listen.app/Contents/MacOS/Listen sync --fake
```

All provider, migration, deletion, search and sync fixtures use isolated synthetic
libraries. Provider tests do not use the user's ordinary recordings.

Results on 8 September 2026:

| Check | Result |
| --- | --- |
| Optimized Mac build and app bundle | Passed |
| iPhone arm64 simulator build and isolated launch | Passed |
| Memory store, provenance, temporal, consent and sync-edit core | 93 checks passed |
| Built-app CLI/MCP, migration, deletion, search and provider-failure integration | 98 checks passed, including explicit person/source consent, note attribution, exclusion and rebuild after deletion |
| iPhone Ask suite | Passed, including compact memory prefetch, person-note identity, corrections, temporal changes and cancellation when a source becomes excluded |
| iPhone library search | Passed, including memory matches with type, tag and speaker filters |
| Notes/tags regression | 30 checks passed |
| Owner sync fake-store suite | Every seam passed, including encrypted assets, concurrent edits, selected Mac/model requests and cancellation winning over late completion |
| Live Claude Code and Codex with synthetic conversations | Two sources and one brief each; no failed or pending work |
| Native visual/interaction checks | Mac note saving/exclusion and source/model picker verified in an isolated library; iPhone note saving, source selection, durable request/cancellation and rendered saved brief verified. Physical voice capture remains a device check |

The live Claude run reported `claude-opus-5`. Codex did not report a resolved model;
that field remains unknown. These are smoke tests of the real provider path,
not a statistical claim of extraction accuracy. The resulting briefs correctly
kept ended roles in the past and possible future work unconfirmed.

[The evaluation artifact](people-memory-evaluation.json) contains the complete
15-query result set, timing samples and provider-reported usage. On an Apple M4
Max, the optional multilingual hybrid search found the expected passage first
for 11/15 queries and within the first three for 14/15. Warm query median was
6.2 ms on the original small-set run. The cross-device retrieval pass repeated
the same 15-query evaluation with unchanged rankings, a 14.3 ms warm median
on the small set and 211 ms at scale (768 ms first query). Both runs are retained
in the evaluation artifact. The 10,010-passage scale fixture indexed in 7.4 seconds
and had a 208 ms warm query median, with a 741 ms first query including model
and index loading. The scale fixture repeats the ten passages across 1,010
recordings; it measures storage/filter/ranking latency, not quality over ten
thousand unique topics.

The missed query concerned a Portuguese paraphrase of a hiring budget blocker.
Other weaker rankings involved recruiting, launch delay and a project handover.
E5 therefore remains optional. These scores are retrieval measurements, never
truth or confidence scores. The profiling fixes preserve immediate source checks:
decoded vectors are cached, shared dependency stamps are reused within a query,
dates are parsed only for date filters, and POSIX file checks preserve the
existing Foundation timestamp format. Compatibility matched on 138 source files.

## Ask and search across devices

`ContextSearch` ranks current verified claims by words, reviewed aliases and
Apple sentence embeddings available on the reading device. No embedding API or
network fallback is used. It deduplicates claims shared by person/project cards,
keeps assertion qualifiers and original/change provenance, and bounds response
size. `as_of` uses the same half-open effective intervals as named card retrieval.

Mac search combines these cards with its local passage index and optional E5
ranking. Search results carry the current structured memory entry; indexed text
cannot override a received correction or revive an ended claim. Entity discovery
also includes verified synced cards. iPhone's Library shows related detail rows
that open the person/project or filtered recording/note. iPhone Ask prefetches
memory for generic questions when matching claims exist, and exposes
`search_context` for subsequent searches. Missing memory still falls back to
recordings and notes. Each new question reloads source-verified owner cards.

Source proof checks require the relevant small source files to have arrived in
the local library. Ask sends selected claims/quotes to the configured provider;
it does not fetch audio or send whole transcripts merely to use a saved card.
The saved cards and corrections travel through encrypted owner sync. Search
vectors and caches are rebuilt locally and are never synced. The optional E5
model remains Mac-only; iPhone uses available Apple embeddings and keywords.

## Intentional boundaries and release checks

- Generation orchestration remains on Mac. iPhone reads the verified owner
  projection, saves person notes, publishes corrections and queues explicit
  generation requests to the selected Mac. It does not run the background
  extraction worker.
- Fully stated ISO and English/Portuguese/Dutch calendar dates can resolve.
  Relative phrases, missing years and ambiguous numeric dates retain their
  wording. Existing source metadata does not establish original locale and
  timezone, so resolving them from the current device settings would invent
  precision.
- Apple's embeddings remain the zero-download default. The optional multilingual
  model is about 500 MB and is downloaded only by explicit action. Inference has
  no network fallback. The small evaluation set does not establish production
  accuracy, battery usage or broad language coverage.
- Claude Code and Codex model requests generally leave the Mac through the user's
  provider. Local storage and local embeddings do not make those requests offline.
  A configured local Ask endpoint is required for fully local generation.
- Owner CloudKit sync now uses an encrypted asset for larger card projections.
  The production `r3` asset fields must be deployed before distribution. Fake
  store tests cannot verify the production schema or a real account's transfer.
- Physical-device voice capture and local transcription still require a spoken
  end-to-end check on Mac and iPhone. The simulator verifies the written-note
  screen and consent controls but does not establish microphone/transcription
  behavior on an actual phone. No personal recordings were used for testing.
- The simulator previously logged a UIKit `UISearchBar` layout warning. The
  inspected search/person screens render correctly; it is not evidence of a
  memory pipeline failure.

The CloudKit schema change to review before distribution is confined to the
existing private-library blob record type:

| Container / record | Field | Required type |
| --- | --- | --- |
| `iCloud.eu.jacarandalabs.listen` / `r3` | `assetNames` | List of strings |
| `iCloud.eu.jacarandalabs.listen` / `r3` | `asset_context_json` | Asset |

The existing `payload` bytes hold the encrypted header. The new asset holds the
separately sealed projection or edits, checked against the header digest after
decryption. No new record type, index or sharing permission is required. Verify
the fields in Development and deploy the reviewed schema before a release, then
exercise a two-device transfer and a correction/deletion round trip.

No release, TestFlight upload, production schema deployment or installation into
`/Applications` is part of this work.
