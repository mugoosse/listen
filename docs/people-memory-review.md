# People memory: implementation review and recommended architecture

Reviewed 7 September 2026. Hermes checkout: `4810074d73d9419dc82545202d595507a73f4f0e`. Honcho checkout: `be54355545b64ddb10203829d323861f52423685`. This is a source review and proposed next architecture, not a claim that the full design below is implemented.

Implementation now follows this design; see [the implementation and verification record](people-memory-implementation.md) for current status and remaining verification. The original assessment below is retained as design history.

Build one native context engine inside Listen: a local evidence store, a bounded worker using the existing Ask providers, and compact person and project briefs. Borrow the separation of responsibilities from Hermes and Honcho. Bundling either agent or Honcho's service stack would add more operational machinery than this product needs.

## What is worth learning from

| Implementation | What it actually does | What Listen should take |
| --- | --- | --- |
| [Hermes background review](/Users/mgo/Documents/coding/ai-agents/hermes-agent/agent/background_review.py:119) | Reviews a conversation snapshot in an isolated agent; foreground turns interrupt it. It can route to an auxiliary model and has iteration/input budgets. | Separate background work from Ask conversations, preserve their prompt cache, give recording and interactive Ask priority, and expose a background model choice and work budget. |
| [Hermes curator](/Users/mgo/Documents/coding/ai-agents/hermes-agent/agent/curator.py:877) | Maintains reusable **skills**. Deterministic lifecycle changes precede optional LLM consolidation; it records run state, snapshots and reports. | A small, observable maintenance pass with no model call when there is nothing to reconcile. Preserve user edits and make transformations reversible. |
| [Honcho deriver](/Users/mgo/Documents/coding/ai-agents/honcho/src/deriver/deriver.py:41) and [representation storage](/Users/mgo/Documents/coding/ai-agents/honcho/src/crud/representation.py:74) | Extracts observations from speaker-labelled messages, associates message IDs, embeds observations, and deduplicates them. Observation and retrieval representations are separate. | Extract atomic observations once. Reuse them across person pages, project questions, search and summaries. |
| [Honcho dream orchestration](/Users/mgo/Documents/coding/ai-agents/honcho/src/dreamer/orchestrator.py:71) | Runs deduction followed by induction. Optional geometric novelty selects areas to investigate. | Consolidate new observations against relevant existing evidence in a separate stage. Start with factual reconciliation, not open-ended personality inference. |
| [Honcho card refresh](/Users/mgo/Documents/coding/ai-agents/honcho/src/dreamer/specialists.py:775) | Has only card-maintenance tools. Its rebuild mode withholds the old card after removals, so removed claims cannot be copied back from it. | A person brief is a derived projection. Regenerate it from current evidence after correction or deletion; never let an old summary become its own evidence. |
| [Hermes Honcho integration](/Users/mgo/Documents/coding/ai-agents/hermes-agent/plugins/memory/honcho/__init__.py:374) | Keeps a stable prompt header and separately refreshes base context and query-specific reasoning with cadence and latency bounds. | Separate inexpensive retrieval from optional reasoning. Keep ordinary MCP context reads free of LLM calls. |

The [Honcho documentation](https://hermes-agent.nousresearch.com/docs/user-guide/features/honcho) describes the two retrieval layers clearly: a base representation/card and an optional query-specific reasoning supplement. Listen should generally answer from the base plus relevant evidence, invoking reasoning only when the question requires it.

There are also patterns to avoid copying. Curator's inactivity-based skill retirement is inappropriate for facts: an unused fact is not a false fact. Its backups and reports are best-effort; Listen's provenance updates must instead commit atomically with their audit records. Hermes background review can default to enabled when configuration fails; Listen should fail closed for consented model processing.

Honcho's [deduction prompt](/Users/mgo/Documents/coding/ai-agents/honcho/src/dreamer/specialists.py:548) tells the model to delete outdated observations. Listen needs supported temporal transitions and retained history instead. Its induction prompt assigns confidence partly by source count. Repeating one report across a recording, an AI note and a summary is still one underlying source, not three independent confirmations.

Honcho's [peer card](/Users/mgo/Documents/coding/ai-agents/honcho/src/crud/peer_card.py:55) is a list of strings stored on the observing peer, keyed by the observed peer. It is a useful compact representation, but is not itself a provenance-rich fact table. Listen needs the evidence layer beneath its card. For a personal library, speaker, subject and attribution are useful distinctions; maintaining a separate model of every person's beliefs about every other person is unnecessary.

The supplied Honcho deployment includes an API, worker, PostgreSQL/vector storage and Redis. Its [embedding client](/Users/mgo/Documents/coding/ai-agents/honcho/src/embedding_client.py:182) calls configurable OpenAI-compatible or Gemini transports. Hosting the server locally does not by itself make inference local. This is a reference architecture, not a dependency I recommend adding to the Mac app.

## Original review of Listen on 7 September 2026

The foundation is useful: original recordings remain authoritative, quotes and speakers are retained, source changes invalidate dependent results, model output is validated, summaries cite claims, and Ask/CLI/MCP share the same context. Local text embeddings are separate from voiceprints.

The current structure is still an extraction prototype, rather than a complete temporal memory system:

- [PeopleMemory](/Users/mgo/Documents/coding/macos-apps/listen/Sources/listen/PeopleMemory.swift) deduplicates exact normalized claim strings. Paraphrases can become duplicate facts, and a paraphrase can evade a hidden claim's identifier. A matching quote proves that the words occurred, not that the proposed interpretation follows from them.
- People and relationship targets primarily use labels or strings. Stable person/project IDs and reviewed aliases are needed for reliable renames, merges and project traversal.
- [ContextSources](/Users/mgo/Documents/coding/macos-apps/listen/Sources/listen/ContextSources.swift) fingerprints broad file dependencies. Filing metadata can trigger extraction again. Requiring every speaker to be named also blocks known speakers in a partially identified meeting.
- [ContextProcessing](/Users/mgo/Documents/coding/macos-apps/listen/Sources/listen/ContextProcessing.swift) scans on a timer, processes older work first, and summarizes up to 50 claims. It lacks a durable job ledger, a reconciliation stage, and balanced selection across identity, current work and commitments.
- [SemanticIndex](/Users/mgo/Documents/coding/macos-apps/listen/Sources/listen/SemanticIndex.swift) reads and rewrites a JSON vector index and scans candidates. The MCP search path can refresh that index synchronously. This needs measurement on larger libraries and separation of query work from indexing.
- Source dates exist, but effective dates, explicit supersession, conflicts, retractions and derivation dependencies are not yet modeled.

The UI feedback exposed a real failure: one unsupported relationship rejected a whole batch. The saved receipt used Claude Code with model selection `sonnet`. This revision adds one bounded repair attempt under the same validation gate. Invalid repaired output still remains pending. It also separates indexing from generation status, moves automatic controls into Settings, displays the model choice with a direct picker, and puts details behind disclosures. Source links use the recordings list's neutral rows and hover highlight. Those changes improve the current implementation; they do not replace the architecture below.

The previous automatic rule that made older roles/locations historical has been removed. A later recording alone does not establish that an earlier role or location ended. Until supported temporal transitions exist, these remain dated observations.

## The clean local design

```mermaid
flowchart LR
    A[Recording or note revision] --> B[Attributed observations]
    B --> C[Evidence-based reconciliation]
    C --> D[Person and project briefs]
    B --> E[Local lexical and vector index]
    C --> E
    D --> F[Budgeted context retrieval]
    E --> F
    F --> G[Person page, Ask, CLI and MCP]
```

Use one SQLite database with WAL and FTS5, accessed through a small Swift store. Keep source files authoritative. Store vectors as typed binary values with an embedding-model namespace. Start with filtered exact vector ranking, then add approximate indexing only if measured latency warrants it. No separate vector server or graph database is required.

The core records should be source revisions, passages, entities and aliases, observations, evidence links, reconciliation events, generated briefs, embeddings and jobs. User corrections and pins are authoritative data; protect and export them independently of rebuildable projections. Calling the entire database disposable would be incorrect.

Extraction should accept identifiable passages as they become ready, retaining adjacent context for pronouns while excluding unidentified claims. Attribute third-party reports explicitly. Never promote an AI-generated note or Ask answer to an independent witness: retain its original source chain, and label unsupported generated content accordingly.

Consolidation runs only for changed entities. Give it the new observations and a bounded set of relevant earlier ones. It proposes a small typed patch: add support, link a paraphrase, mark a conflict, or propose an explicitly supported transition. Listen validates identifiers, source availability and dependencies, then commits the patch and provenance together. The model never gets general filesystem or database mutation tools.

Build each brief from these records: a short orientation, relevant projects, open commitments where their status is supported, and meaningful recent changes. Every sentence points through claim IDs to original evidence. Keep the page compact; detailed facts, history and source quotations are progressive disclosures. A graph visualization should be optional, not the primary way to learn about someone.

## Temporal memory must be provenance-driven

Separate three times: **recorded_at** (when the source was created), **learned_at** (when Listen processed it), and **valid_from/valid_to** (when the claim applies, if established). Preserve the original temporal wording, date precision and timezone. Unknown effective dates stay unknown. Resolve “next Friday” relative to the conversation date and locale, preserving ambiguity when necessary.

For each observation, retain:

| Record | Required meaning |
| --- | --- |
| Identity | Stable subject ID, speaker/author ID, and attributed reporter when different. |
| Evidence | Source ID and revision, passage/turn ID, exact quote, text offsets and recording time range. |
| Assertion | Predicate, object/entity, polarity, modality, explicit/reported/inferred classification. |
| Time | Recorded, learned and effective times, precision, and the evidence for the effective time. |
| Derivation | Supporting observation IDs, independent source groups, extraction/reconciliation version, provider, requested model and resolved model when reported. |
| Transition | Prior observation IDs, operation, supporting evidence, actor and commit time. |

Example: in January Alex says “I lead Atlas.” In March Alex says “I handed Atlas to Priya on February 12.” Preserve January's observation, record March's transition evidence, and end the leadership interval on February 12. An imported January recording processed in April must not restore Alex as current lead. A third person saying “I think Alex still leads it” is an attributed conflicting report, not an automatic reversal.

Two jobs, a visit and a home address, an intention and an accomplished event can coexist. A planned departure does not prove the departure happened. Repeated quotation does not increase independent support. Model confidence and embedding similarity are never truth scores.

Represent `supports`, `contradicts`, `supersedes` and `retracts` as evidence-bearing relationships. A supersession is itself a claim that requires provenance. Preserve alternative support sets: deleting one source should remove only the conclusions that can no longer be supported, then recompute affected temporal views. If the source supporting a transition disappears, re-evaluate the earlier state instead of silently keeping the transition or blindly restoring a former “current” value.

Source deletion must remove its searchable content and dependent cached text, including old card text. An audit log can retain non-content event identifiers where appropriate; it must not secretly retain deleted quotations. A user correction should create an explicit override or rejection tied to a canonical claim, so re-extraction and paraphrasing cannot resurrect it. Keep the distinction between “the source says this” and “the user corrected this.”

## Scheduling, models and retrieval

Use source-change hooks with a periodic reconciliation scan as recovery. Persist jobs keyed by content revision and extractor version; distinguish content changes from title/tag changes. Claim a job with a lease, and commit its output only if its input revision is still current. Prioritize a person the user requested, then new conversations, then old-library backfill. Avoid retrying a poison source ahead of everything else.

For Listen, “dreaming” should mean bounded consolidation during idle time: only changed people/projects, a small request budget, cancellation at foreground activity, and resumable checkpoints. Do not run a general reasoning agent over the entire library every night. Add cost/token information when a provider reports it, and show unavailable values honestly.

Reuse Ask's provider/session implementation. Initially the selected Ask model can be the default, as it is today. Add an optional separate **Background model** choice so switching Ask for a difficult question does not unexpectedly increase the cost of a library backfill. Pin provider and model for each job; never silently change providers when an explicitly chosen one fails.

Provide one shared context builder for the UI, CLI and MCP. Extend person retrieval with a question, token budget and optional effective-date filter; add equivalent project retrieval. Return a short brief, query-relevant facts, one-hop relationships, conflicts, provenance references and freshness/pending state. Start with a roughly 1,500-token budget as a tuning target. A request for original evidence can expand a passage or recording afterward. Querying should not invoke extraction or a full index rebuild.

Keep the main Ask instructions stable. Supply retrieved context in the current request/tool results, and never rewrite an active conversation's old system prefix because a background brief changed.

## Embeddings

Keep Apple's current sentence embeddings as the zero-download baseline. They are local, but the language-specific spaces cannot be compared across languages, and unavailable languages fall back to keywords. The existing small English test is insufficient to choose a production relevance threshold.

My first candidate for multilingual retrieval is **multilingual-e5-small through MLXEmbedders**. Listen's resolved `mlx-swift-lm` package already contains this exact model in its [embedding registry](/Users/mgo/Documents/coding/macos-apps/listen/.xcbuild/SourcePackages/checkouts/mlx-swift-lm/Libraries/MLXEmbedders/ModelFactory.swift:57), so there is a native Swift path without a Python service. It is not currently linked into Listen's search feature.

The [publisher's model card](https://huggingface.co/intfloat/multilingual-e5-small) specifies 384 dimensions, multilingual training, a 512-token limit, query/passage prefixes and normalized pooling. Verify retrieval quality, memory, battery use and latency on Listen's own English/Portuguese/Dutch and mixed-language examples before choosing it as the default. Registration in MLX is evidence of an integration path, not a completed Listen benchmark.

Chunk on speaker and sentence boundaries, retain adjacent context, and avoid silently truncating model inputs. Index observations and source passages separately. Combine exact names/aliases and lexical matches with semantic ranking, deduplicate results, and return diverse evidence. Namespace vectors by model revision, tokenizer, pooling, dimensions and input format, and rebuild on a change. No network fallback for embeddings.

The database, scheduling and embeddings can all stay local. Claude Code or Codex generally still send model requests to their provider. Fully offline extraction requires a local Ask endpoint/model and its own quality evaluation. The interface must state that distinction plainly.

## Order of work

1. Finish the current clarity/recovery changes and conservative temporal handling.
2. Add stable identity, provenance records, canonical corrections and the temporal event model. Migrate existing receipts without inventing missing effective dates.
3. Move indexing and jobs to SQLite; add incremental processing and the bounded context builder.
4. Add constrained consolidation and materialized person/project briefs.
5. Benchmark multilingual embeddings, then build the shared read layer and native iPhone presentation. Keep generation orchestration on Mac initially; sync only an explicitly defined encrypted projection with deletion/correction propagation.

Acceptance should test negation, third-party reports, mistaken speaker labels, overlapping roles, delayed imports, corrections, deleted transition evidence, duplicate AI summaries, project aliases and multilingual retrieval. Measure evidence validity, wrong merges, unsupported “current” claims, retrieval precision/recall, latency and tokens per answer. Mechanical fixture tests and an attractive screenshot alone cannot establish that this memory is trustworthy.
