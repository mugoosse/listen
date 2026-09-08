import Foundation
import ListenKit

/// Mac ingestion adapts the existing library to the shared evidence ledger.
/// User overrides are never replaced by a processing snapshot.
enum ContextStore {
    /// Called only for an explicit rename/merge in People. Similar names never
    /// trigger it. Original quotes remain unchanged and are revalidated normally.
    static func relabelPerson(_ oldName: String, to newName: String, merging: Bool) throws {
        let oldIdentity = MemoryPreferences.personID(oldName, root: Library.root)
        let db = try database()
        try db.transaction {
            var origin = try ContextLedger.entity(oldName, kind: "person", db: db)
            let key = "person:" + ContextIdentity.normalized(newName)
            let existing = try db.get(String.self, in: .aliases, id: key)
            if let existing, existing != origin.id {
                guard merging, var target = try db.get(ContextEntity.self, in: .entities, id: existing) else {
                    throw ContextProblem.message("This name already has memory. Merge the people to keep both histories.")
                }
                target.aliases = Array(Set(target.aliases + origin.aliases + [newName])).sorted()
                for alias in target.aliases { try db.put(target.id, in: .aliases, id: "person:" + ContextIdentity.normalized(alias)) }
                try db.put(target, in: .entities, id: target.id)
                for receipt in try db.all(MemoryReceipt.self, in: .receipts).values {
                    for claim in receipt.claims where claim.subjectID == origin.id || claim.objectID == origin.id {
                        let newID = ContextLedger.claimID(subject: claim.subjectID == origin.id ? target.id : claim.subjectID!,
                            predicate: claim.attribute, kind: claim.objectKind, quote: claim.quote,
                            object: claim.objectID == origin.id ? target.id : claim.objectID)
                        if var value = try db.get(ContextOverride.self, in: .overrides, id: claim.id) {
                            value.id = newID
                            let previous = try db.get(ContextOverride.self, in: .overrides, id: newID)
                            let merged = ContextSync.merge(previous.map { [newID: $0] } ?? [:], [newID: value])
                            try db.put(merged[newID]!, in: .overrides, id: newID)
                        }
                    }
                }
                try db.remove(.entities, id: origin.id)
            } else {
                origin.name = newName; origin.aliases = Array(Set(origin.aliases + [newName])).sorted()
                try db.put(origin, in: .entities, id: origin.id)
                try db.put(origin.id, in: .aliases, id: key)
            }
            try db.execute("DELETE FROM summaries")
        }
        let identity = try ContextLedger.entity(newName, kind: "person", db: db).id
        if merging { try MemoryPreferences.redirect(oldIdentity, to: identity, root: Library.root) }
        try MemoryPreferences.associate(oldName, id: identity, root: Library.root)
        try MemoryPreferences.associate(newName, id: identity, root: Library.root)
        try ContextSync.write(db.all(ContextOverride.self, in: .overrides), root: Library.root)
    }

    static func database() throws -> ContextDatabase {
        let db = try ContextDatabase(root: Library.root)
        if try db.get(Bool.self, in: .metadata, id: "legacyImported") != true {
            try db.transaction {
                if try db.get(Bool.self, in: .metadata, id: "legacyImported") == true { return }
                if var legacy = try ContextFiles.read(MemoryDocument.self, "memory.json") {
                    guard legacy.version == 1 else { throw ContextProblem.message("This memory needs a newer Listen version.") }
                    let hidden = try ContextFiles.read(Set<String>.self, "dismissed.json") ?? []
                    for key in Array(legacy.receipts.keys) {
                        guard var receipt = legacy.receipts[key] else { continue }
                        for i in receipt.claims.indices {
                            let old = receipt.claims[i].id
                            let subject = try ContextLedger.entity(receipt.claims[i].person, kind: "person", db: db)
                            receipt.claims[i].subjectID = subject.id
                            if let kind = receipt.claims[i].objectKind {
                                receipt.claims[i].objectID = try ContextLedger.entity(receipt.claims[i].value, kind: kind, db: db).id
                            }
                            let id = ContextLedger.claimID(subject: subject.id, predicate: receipt.claims[i].attribute,
                                kind: receipt.claims[i].objectKind, quote: receipt.claims[i].quote, object: receipt.claims[i].objectID)
                            receipt.claims[i].id = id
                            if hidden.contains(old) {
                                try db.put(ContextOverride(id: id, hidden: true, updated: Metadata.iso(Date())), in: .overrides, id: id)
                            }
                        }
                        legacy.receipts[key] = receipt
                    }
                    try db.replace(legacy.receipts, in: .receipts)
                    // Old summaries cite the old identities and must be rebuilt.
                }
                if let sources = try ContextFiles.read([ContextSource].self, "sources.json") {
                    try db.replace(Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) }), in: .sources)
                }
                if let search = try ContextFiles.read(SemanticDocument.self, "search.json") {
                    for entry in search.entries {
                        try db.put(entry, in: .search, id: entry.id)
                        try db.index(id: entry.id, text: entry.text, namespace: entry.vector?.model, vector: entry.vector?.values)
                    }
                    try db.put(search.updated, in: .metadata, id: "searchUpdated")
                }
                try db.put(true, in: .metadata, id: "legacyImported")
            }
        }
        if try db.get(Bool.self, in: .metadata, id: "immutableObservationIdentity") != true {
            try db.transaction {
                var observations = try db.all(ContextObservation.self, in: .observations)
                var translated: [String: String] = [:]
                for receipt in try db.all(MemoryReceipt.self, in: .receipts).values {
                    for claim in receipt.claims {
                        let oldID = ContextFiles.hash(claim.id + receipt.source.id + receipt.fingerprint + String(claim.ref))
                        guard var observation = observations.removeValue(forKey: oldID) else { continue }
                        let id = observationID(claim, receipt); observation.id = id
                        observations[id] = observation; translated[oldID] = id
                    }
                }
                try db.replace(observations, in: .observations)
                for var event in try db.all(ContextTransition.self, in: .transitions).values {
                    event.prior = translated[event.prior] ?? event.prior
                    event.next = translated[event.next] ?? event.next
                    event.supports = event.supports.map { translated[$0] ?? $0 }
                    try db.put(event, in: .transitions, id: event.id)
                }
                for subject in Set(observations.values.map(\.subject)) {
                    let key = "reconciled:" + subject
                    if let seen = try db.get(Set<String>.self, in: .metadata, id: key) {
                        try db.put(Set(seen.map { translated[$0] ?? $0 }), in: .metadata, id: key)
                    }
                }
                try db.put(true, in: .metadata, id: "immutableObservationIdentity")
            }
        }
        // After the transaction succeeds, remove obsolete content copies. The
        // migrated corrections live in SQLite and are included in owner export.
        for name in ["memory.json", "search.json", "sources.json", "dismissed.json"] {
            let url = ContextFiles.root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        let snapshot = try ContextSnapshot.load(root: Library.root)
        let stamp = ContextFiles.stamp(ContextSnapshot.filename)
        if let snapshot, try db.get(String.self, in: .metadata, id: "ownerProjectionIdentity") != stamp {
            try db.transaction {
                for card in snapshot.cards {
                    let keys = Array(Set(card.aliases + [card.name])).map { card.kind + ":" + ContextIdentity.normalized($0) }
                    let existing = try keys.compactMap { try db.get(String.self, in: .aliases, id: $0) }
                    guard existing.allSatisfy({ $0 == card.id }) else { continue }
                    if try db.get(ContextEntity.self, in: .entities, id: card.id) == nil {
                        var entity = ContextEntity(kind: card.kind, name: card.name)
                        entity.id = card.id; entity.aliases = Array(Set(card.aliases + [card.name])).sorted()
                        try db.put(entity, in: .entities, id: entity.id)
                    }
                    for key in keys { try db.put(card.id, in: .aliases, id: key) }
                }
                try db.put(stamp, in: .metadata, id: "ownerProjectionIdentity")
            }
        }
        let incoming = ContextSync.merge(snapshot?.overrides ?? [:], try ContextSync.edits(root: Library.root))
        if !incoming.isEmpty {
            let local = try db.all(ContextOverride.self, in: .overrides)
            let merged = ContextSync.merge(local, incoming)
            try db.transaction {
                for (id, value) in merged { try db.put(value, in: .overrides, id: id) }
            }
        }
        return db
    }

    static func load() throws -> MemoryDocument {
        let db = try database()
        return MemoryDocument(receipts: try db.all(MemoryReceipt.self, in: .receipts),
            summaries: try db.all(MemorySummary.self, in: .summaries),
            summaryRetryAfter: try db.get([String: Date].self, in: .metadata, id: "summaryRetry"))
    }

    static func observationID(_ claim: MemoryClaim, _ receipt: MemoryReceipt) -> String {
        let time = claim.time ?? ContextTime()
        let assertion = [claim.value, claim.polarity ?? "positive", claim.modality ?? "asserted",
            claim.attribution ?? "reported", time.from ?? "", time.to ?? "", time.wording ?? "", time.precision ?? ""]
        return ContextFiles.hash(([claim.id, receipt.source.id, receipt.fingerprint, String(claim.ref),
            String(receipt.promptVersion)] + assertion).joined(separator: "\n"))
    }
    static func provenance(_ claim: MemoryClaim, _ receipt: MemoryReceipt) -> ContextProvenance {
        ContextProvenance(source: receipt.source.id, revision: receipt.fingerprint, passage: claim.ref,
            quote: claim.quote, quoteStart: claim.quoteOffset ?? 0, recordedAt: receipt.source.date,
            learnedAt: receipt.processedAt, speaker: claim.speaker, start: claim.start, end: claim.end,
            sourceGroups: receipt.source.sourceGroups ?? [receipt.source.id], provider: receipt.backend,
            requestedModel: receipt.model, resolvedModel: receipt.resolvedModel, extractorVersion: receipt.promptVersion)
    }

    static func save(_ document: MemoryDocument, completing job: ContextJob? = nil) throws {
        let db = try database()
        try db.transaction {
            try db.replace(document.receipts, in: .receipts)
            try db.replace(document.summaries, in: .summaries)
            try db.put(document.summaryRetryAfter ?? [:], in: .metadata, id: "summaryRetry")
            let valid = PeopleMemory.validReceipts(document)
            var revisions: [String: String] = [:]
            var activeIDs: Set<String> = []
            for receipt in valid {
                revisions[receipt.source.id] = receipt.fingerprint
                for claim in receipt.claims {
                    let subject = try claim.subjectID ?? ContextLedger.entity(claim.person, kind: "person", db: db).id
                    let id = observationID(claim, receipt)
                    activeIDs.insert(id)
                    let observation = ContextObservation(id: id, subject: subject, predicate: claim.attribute,
                        value: claim.value, object: claim.objectID, objectKind: claim.objectKind,
                        polarity: claim.polarity ?? "positive", modality: claim.modality ?? "asserted",
                        attribution: claim.attribution ?? (claim.speaker == claim.person ? "direct" : "reported"),
                        time: claim.time ?? ContextTime(), evidence: provenance(claim, receipt))
                    try db.put(observation, in: .observations, id: id)
                }
            }
            try ContextLedger.prune(currentRevisions: revisions, activeIDs: activeIDs, db: db)
            if let job { try ContextLedger.finish(job, failure: document.receipts[job.source]?.failure, db: db) }
        }
    }

    static func catalog() throws -> [ContextSource] { Array(try database().all(ContextSource.self, in: .sources).values) }

    /// Source cleanup and metadata refresh run even when generation is off.
    static func refreshSources(_ sources: [ContextSource]) throws {
        let ownership: ContextLock
        do { ownership = try ContextLock("processing.lock") }
        catch ContextProblem.busy { return }
        defer { withExtendedLifetime(ownership) {} }
        var document = try load()
        let current = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
        var changed = false
        for key in Array(document.receipts.keys) {
            guard let old = document.receipts[key] else { continue }
            let source = current[old.source.id]?.scoped(to: old.source.subjectScope)
            guard var source = source, source.extractable, !PeopleMemory.deleted(old),
                  source.fingerprint == old.fingerprint, old.promptVersion == PeopleMemory.promptVersion else {
                document.receipts[key] = nil; changed = true
                try? FileManager.default.removeItem(at: ContextFiles.root.appendingPathComponent("rejected-\(ContextFiles.hash(key)).json"))
                continue
            }
            let filtered = PeopleMemory.filtered(old)
            if filtered.claims.count != old.claims.count { document.receipts[key] = filtered; changed = true }
            if source.dependencies != old.source.dependencies || source.title != old.source.title || source.tags != old.source.tags {
                source.batchCount = source.batches.count; source.passages = []
                document.receipts[key]?.source = source; changed = true
            }
        }
        if changed { document.summaries = [:]; try save(document) }
    }

    static func override(id: String, hidden: Bool? = nil, replacement: String? = nil, pinned: Bool? = nil) throws {
        let db = try database()
        try db.transaction {
            var value = try db.get(ContextOverride.self, in: .overrides, id: id) ?? ContextOverride(id: id, updated: "")
            if let hidden { value.hidden = hidden }
            if let replacement {
                guard replacement.count <= 500 else { throw ContextProblem.message("Keep the correction within 500 characters.") }
                value.replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : replacement
            }
            if let pinned { value.pinned = pinned }
            value.mark([(hidden != nil ? "hidden" : nil), (replacement != nil ? "replacement" : nil),
                        (pinned != nil ? "pinned" : nil)].compactMap { $0 }, at: Metadata.iso(Date()))
            try db.put(value, in: .overrides, id: id)
            // A correction must immediately invalidate cached generated text.
            try db.execute("DELETE FROM summaries")
        }
        NotificationCenter.default.post(name: PeopleMemory.changed, object: nil)
        try ContextSync.write(db.all(ContextOverride.self, in: .overrides), root: Library.root)
    }

    static func project(_ items: [PersonMemory.Item], receipts: [MemoryReceipt], asOf: String?) throws -> [PersonMemory.Item] {
        let db = try database()
        let observations = try db.all(ContextObservation.self, in: .observations)
        let events = Array(try db.all(ContextTransition.self, in: .transitions).values)
        let overrides = try db.all(ContextOverride.self, in: .overrides)
        let liveSources = Dictionary(grouping: receipts.filter { $0.source.isCurrent }, by: { $0.source.id })
        let liveIDs = Set(observations.values.filter { observation in
            liveSources[observation.evidence.source]?.contains(where: { $0.fingerprint == observation.evidence.revision }) == true
        }.map(\.id))
        let currentEvents = events.map { event -> ContextTransition in
            var event = event
            if !Set(event.supports).isSubset(of: liveIDs) || !liveIDs.contains(event.prior) || !liveIDs.contains(event.next) {
                event.revoked = true; event.quote = nil
            }
            return event
        }
        let claims = receipts.flatMap { receipt in receipt.claims.map { ($0, receipt) } }
        var grouped: [String: PersonMemory.Item] = [:]
        for var item in items.sorted(by: { $0.id < $1.id }) {
            let matching = claims.filter { $0.0.id == item.id }
            let ids = matching.map { observationID($0.0, $0.1) }
            let canonical = ids.map { ContextLedger.canonical($0, events: currentEvents) }.sorted().first ?? item.id
            let linkedClaimIDs = claims.filter { pair in
                ContextLedger.canonical(observationID(pair.0, pair.1), events: currentEvents) == canonical
            }.map { $0.0.id }
            let userValues = Set(linkedClaimIDs + [item.id]).compactMap { overrides[$0] }
            item.canonicalClaimIDs = Array(Set(linkedClaimIDs + [item.id])).sorted()
            if ContextOverride.latest(userValues, field: "hidden")?.hidden == true { continue }
            let correction = ContextOverride.latest(userValues, field: "replacement")
            item.corrected = correction?.replacement != nil
            item.pinned = ContextOverride.latest(userValues, field: "pinned")?.pinned == true
            if let replacement = correction?.replacement { item.value = replacement }
            item.observationIDs = ids
            if let first = matching.first {
                item.subjectID = first.0.subjectID; item.objectID = first.0.objectID
                item.time = first.0.time; item.polarity = first.0.polarity
                item.modality = first.0.modality; item.attribution = first.0.attribution
            }
            for index in item.evidence.indices {
                if let pair = matching.first(where: { $0.1.source.id == item.evidence[index].source && $0.0.quote == item.evidence[index].quote }) {
                    item.evidence[index].provenance = provenance(pair.0, pair.1)
                }
            }
            let relevant = currentEvents.filter { ids.contains($0.prior) || ids.contains($0.next) }
            item.transitions = relevant
            let endings = relevant.filter { !$0.revoked && ids.contains($0.prior) && ["supersedes", "retracts"].contains($0.operation) }
            if let end = endings.compactMap(\.effectiveDate).min() {
                if item.time == nil { item.time = ContextTime() }; item.time?.to = end
                if asOf == nil || asOf! >= end { item.status = endings.contains { $0.operation == "retracts" } ? "retracted" : "historical" }
            } else if relevant.contains(where: { $0.revoked && ids.contains($0.prior) && ["supersedes", "retracts"].contains($0.operation) }) {
                item.status = "needs_review"
            }
            if !["historical", "retracted"].contains(item.status), relevant.contains(where: { !$0.revoked && $0.operation == "contradicts" }) { item.status = "conflicted" }
            if let asOf {
                if let from = item.time?.from, from > asOf { continue }
                if let to = item.time?.to, to <= asOf { continue }
            } else if let to = item.time?.to, to <= String(Metadata.iso(Date()).prefix(10)), item.status == "recorded" { item.status = "historical" }
            if var existing = grouped[canonical] {
                existing.evidence += item.evidence.filter { e in !existing.evidence.contains { $0.source == e.source && $0.quote == e.quote } }
                existing.observationIDs = Array(Set((existing.observationIDs ?? []) + ids)).sorted()
                grouped[canonical] = existing
            } else { grouped[canonical] = item }
        }
        return Array(grouped.values)
    }
}
