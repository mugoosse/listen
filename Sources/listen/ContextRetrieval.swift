import Foundation
import ListenKit

enum ContextRetrieval {
    private static func reviewedSources(_ document: MemoryDocument) -> Set<String> {
        Set(Dictionary(grouping: PeopleMemory.validReceipts(document), by: { $0.source.id }).compactMap { id, receipts in
            receipts.count >= (receipts.first?.batches ?? 1) ? id : nil
        })
    }
    private static func merged(_ cards: [ContextCard], document: MemoryDocument) throws -> [ContextCard] {
        guard var snapshot = try ContextSnapshot.load(root: Library.root) else { return cards }
        snapshot.overrides = ContextSync.merge(snapshot.overrides, try ContextStore.database().all(ContextOverride.self, in: .overrides))
        return snapshot.merging(local: cards, reviewedSources: reviewedSources(document), root: Library.root)
    }
    static func entities() throws -> [ContextEntity] {
        try ContextStore.database().all(ContextEntity.self, in: .entities).values.sorted { ($0.kind, $0.name, $0.id) < ($1.kind, $1.name, $1.id) }
    }
    static func listedEntities() throws -> [ContextEntity] {
        var values = Dictionary(uniqueKeysWithValues: try entities().map { ($0.id, $0) })
        for card in try cards() {
            var entity = values[card.id] ?? ContextEntity(kind: card.kind, name: card.name)
            entity.id = card.id; entity.aliases = Array(Set(entity.aliases + card.aliases + [card.name])).sorted()
            values[card.id] = entity
        }
        return values.values.sorted { ($0.kind, $0.name, $0.id) < ($1.kind, $1.name, $1.id) }
    }
    static func resolve(_ name: String, kind: String) throws -> ContextEntity {
        let matches = try entities().filter { entity in
            entity.kind == kind && (entity.id == name || entity.aliases.contains { ContextIdentity.normalized($0) == ContextIdentity.normalized(name) })
        }
        guard matches.count == 1 else { throw ContextProblem.message(matches.isEmpty ? "No \(kind) named \(name) has processed context yet." : "That name is ambiguous. Use the entity ID.") }
        return matches[0]
    }
    static func person(_ memory: PersonMemory) throws -> ContextCard {
        let db = try ContextStore.database()
        let entity = try db.transaction { try ContextLedger.entity(memory.person, kind: "person", db: db) }
        let observations = try db.all(ContextObservation.self, in: .observations)
        let sources = Dictionary(uniqueKeysWithValues: try ContextStore.catalog().map { ($0.id, $0) })
        let entries = (memory.facts + memory.relations).map { item in
            let endings = (item.transitions ?? []).filter { !$0.revoked && ["supersedes", "retracts"].contains($0.operation) && (item.observationIDs ?? []).contains($0.prior) }
            let conflicts = (item.transitions ?? []).filter { !$0.revoked && $0.operation == "contradicts" }
            let changes = Set((endings + conflicts).flatMap(\.supports)).sorted().compactMap { id -> ContextCard.Evidence? in
                guard let observation = observations[id] else { return nil }
                let evidence = observation.evidence
                return ContextCard.Evidence(source: evidence.source, title: sources[evidence.source]?.title ?? "Source",
                    recordedAt: evidence.recordedAt, quote: evidence.quote, speaker: evidence.speaker,
                    start: evidence.start, revision: evidence.revision, sourceGroups: evidence.sourceGroups, learnedAt: evidence.learnedAt)
            }
            return ContextCard.Entry(id: item.id, subject: item.subjectID ?? entity.id, subjectName: memory.name,
                predicate: item.attribute, text: item.value, object: item.objectID, objectKind: item.objectKind,
                status: item.status, time: item.time, evidence: item.evidence.map {
                    ContextCard.Evidence(source: $0.source, title: $0.title, recordedAt: $0.date, quote: $0.quote,
                        speaker: $0.speaker, start: $0.start, revision: $0.provenance?.revision ?? "",
                        sourceGroups: $0.provenance?.sourceGroups, learnedAt: $0.provenance?.learnedAt)
                }, corrected: item.corrected == true, pinned: item.pinned == true,
                attribution: item.attribution ?? "reported", modality: item.modality ?? "asserted", polarity: item.polarity ?? "positive",
                endingSupports: endings.map { $0.supports.compactMap { observations[$0]?.evidence.source } },
                conflictSupports: conflicts.map { Set($0.supports + [$0.prior, $0.next]).compactMap { observations[$0]?.evidence.source } },
                canonicalClaimIDs: item.canonicalClaimIDs,
                originalText: (item.observationIDs ?? []).sorted().compactMap { observations[$0]?.value }.first,
                changeEvidence: changes.isEmpty ? nil : changes)
        }
        return ContextCard(id: entity.id, kind: "person", name: memory.name, aliases: entity.aliases,
            brief: memory.summary.map { ContextCard.Sentence(text: $0.text, claims: $0.claims) }, entries: entries,
            updated: memory.updated, pending: memory.pending, failed: memory.failed)
    }
    static func people(document: MemoryDocument? = nil) throws -> [ContextCard] {
        let document = try document ?? PeopleMemory.load()
        let labels = Set(PeopleMemory.validReceipts(document).flatMap { $0.source.people }).sorted()
        return try labels.map { try person(PeopleMemory.person($0, document: document)) }
    }
    static func project(_ entity: ContextEntity, people: [ContextCard]) -> ContextCard {
        let matches = people.flatMap(\.entries).filter { item in
            item.object == entity.id || entity.aliases.contains { ContextSources.containsName(item.text, $0) }
        }
        let entries = Dictionary(grouping: matches, by: \.id).values.compactMap(\.first).sorted { $0.id < $1.id }
        let current = entries.filter { !["historical", "retracted"].contains($0.status) }
        let brief = current.filter { $0.object == entity.id }.prefix(4).map {
            var qualifiers = ContextPresentation.qualifiers(modality: $0.modality, attribution: $0.attribution)
            if $0.status == "conflicted" { qualifiers.append("Sources disagree") }
            if $0.status == "needs_review" { qualifiers.append("Needs review") }
            let relation = ContextPresentation.category($0.predicate, polarity: $0.polarity)
            let text = $0.corrected ? $0.text : relation + " " + entity.name
            return ContextCard.Sentence(text: $0.subjectName + " · " + text
                + (qualifiers.isEmpty ? "" : " (" + qualifiers.joined(separator: "; ") + ")"), claims: [$0.id])
        }
        return ContextCard(id: entity.id, kind: entity.kind, name: entity.name, aliases: entity.aliases,
            brief: brief, entries: entries, updated: people.compactMap(\.updated).max(),
            pending: people.filter { card in card.entries.contains { $0.object == entity.id } }.reduce(0) { $0 + $1.pending },
            failed: people.filter { card in card.entries.contains { $0.object == entity.id } }.reduce(0) { $0 + $1.failed })
    }
    static func cards() throws -> [ContextCard] {
        let document = try PeopleMemory.load()
        let people = try merged(people(document: document), document: document).filter { $0.kind == "person" }
        let localProjects = try entities().filter { $0.kind == "project" }.map { project($0, people: people) }
        return try merged(people + localProjects, document: document)
    }
    static func card(_ name: String, kind: String) throws -> ContextCard {
        let all = try cards()
        let matches = all.filter { $0.kind == kind && ($0.id == name || ($0.aliases + [$0.name]).contains { ContextIdentity.normalized($0) == ContextIdentity.normalized(name) }) }
        guard matches.count == 1 else {
            if kind == "person", matches.isEmpty { return try person(PeopleMemory.person(PeopleMemory.resolve(name))) }
            throw ContextProblem.message(matches.isEmpty ? "No \(kind) named \(name) has processed context yet." : "That name is ambiguous. Use the entity ID.")
        }
        return matches[0]
    }
    static func displayPerson(_ name: String) throws -> PersonMemory {
        var memory = try PeopleMemory.person(name)
        let card = try card(name, kind: "person")
        let localItems = Dictionary(uniqueKeysWithValues: (memory.facts + memory.relations).map { ($0.id, $0) })
        let items = card.entries.map { entry -> PersonMemory.Item in
            var item = PersonMemory.Item(id: entry.id, attribute: entry.predicate, value: entry.text, objectKind: entry.objectKind,
                evidence: entry.evidence.map { MemoryEvidence(source: $0.source, title: $0.title, date: $0.recordedAt, quote: $0.quote,
                    speaker: $0.speaker, start: $0.start, marker: "[\($0.source)]") }, status: entry.status)
            if let local = localItems[entry.id] {
                item.transitions = local.transitions; item.observationIDs = local.observationIDs
                item.evidence = item.evidence.map { evidence in
                    local.evidence.first { $0.source == evidence.source && $0.quote == evidence.quote } ?? evidence
                }
            }
            item.subjectID = entry.subject; item.canonicalClaimIDs = entry.canonicalClaimIDs; item.objectID = entry.object
            item.time = entry.time; item.polarity = entry.polarity; item.modality = entry.modality
            item.attribution = entry.attribution; item.corrected = entry.corrected; item.pinned = entry.pinned
            item.changeEvidence = entry.changeEvidence?.map { MemoryEvidence(source: $0.source, title: $0.title,
                date: $0.recordedAt, quote: $0.quote, speaker: $0.speaker, start: $0.start, marker: "[\($0.source)]") }
            return item
        }
        memory.facts = items.filter { $0.objectKind == nil }; memory.relations = items.filter { $0.objectKind != nil }
        memory.summary = card.brief.map { sentence in
            MemorySummary.Sentence(text: sentence.text, claims: sentence.claims,
                evidence: sentence.claims.flatMap { id -> [MemoryEvidence] in
                    guard let item = items.first(where: { $0.id == id }) else { return [] }
                    return item.evidence + (item.changeEvidence ?? [])
                })
        }
        memory.updated = card.updated; memory.pending = card.pending; memory.failed = card.failed
        return memory
    }
    static func packet(_ name: String, kind: String, question: String = "", tokenBudget: Int = 1500,
                       asOf: String? = nil, offset: Int = 0, limit: Int = 100) throws -> ContextPacket {
        try ContextBuilder.build(card(name, kind: kind), question: question, tokenBudget: tokenBudget,
                                 asOf: asOf, offset: offset, limit: limit)
    }

    /// Explicitly enumerated owner projection. Jobs, vectors and usage stay local.
    static func export() throws {
        let db = try ContextStore.database()
        let document = try PeopleMemory.load()
        let people = try people(document: document)
        let projects = try entities().filter { $0.kind == "project" }
        let cards = try merged(people + projects.map { project($0, people: people) }, document: document)
        let old = try ContextSnapshot.load(root: Library.root)
        let usedSources = Set(cards.flatMap(\.entries).flatMap { $0.evidence + ($0.changeEvidence ?? []) }.map(\.source))
        var proofs = (old?.proofs ?? [:]).filter { usedSources.contains($0.key) }
        for receipt in PeopleMemory.validReceipts(document) {
            var paths = receipt.source.dependencies.keys.filter { !$0.hasPrefix("contact:") && !$0.hasPrefix("display:") }
            if receipt.source.kind == "contact" { paths = ["contacts.json"] }
            proofs[receipt.source.id] = Dictionary(uniqueKeysWithValues: paths.compactMap { path in
                ContextProofCache.shared.digest(Library.root.appendingPathComponent(path)).map { (path, $0) }
            })
        }
        let overrides = ContextSync.merge(old?.overrides ?? [:], try db.all(ContextOverride.self, in: .overrides))
        let snapshot = ContextSnapshot(cards: cards.sorted { $0.id < $1.id }, proofs: proofs, overrides: overrides,
            generatedAt: cards.compactMap(\.updated).max() ?? "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        if let old, try encoder.encode(old) == data { return }
        guard data.count <= 32_000_000 else { throw ContextProblem.message("The people projection exceeds its sync limit.") }
        let url = Library.root.appendingPathComponent(ContextSnapshot.filename)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
