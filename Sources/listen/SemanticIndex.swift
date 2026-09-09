import Foundation
import NaturalLanguage
import ListenKit

/// Apple's sentence models run on this Mac. Languages and revisions are part
/// of vector identity: Portuguese and English vectors cannot be compared even
/// when a future OS gives them the same dimension.
final class LocalTextEmbedding {
    struct Vector: Codable {
        var model: String
        var language: String
        var values: [Float]
    }
    private var models: [String: NLEmbedding] = [:]
    private var unavailable: Set<String> = []
    private var vectors: [String: Vector] = [:]

    func vector(_ text: String, query: Bool = false) -> Vector? {
        let key = "\(Settings.multilingualSearch):\(query):" + text
        if let vector = vectors[key] { return vector }
        guard let vector = encode(text, query: query) else { return nil }
        if vectors.count >= 2048 { vectors.removeAll(keepingCapacity: true) }
        vectors[key] = vector; return vector
    }

    private func encode(_ text: String, query: Bool) -> Vector? {
        if Settings.multilingualSearch { return MultilingualEmbedding.vector(text, query: query) }
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        let key = language.rawValue
        if unavailable.contains(key) { return nil }
        let model: NLEmbedding
        if let existing = models[key] { model = existing }
        else if let loaded = NLEmbedding.sentenceEmbedding(for: language) {
            models[key] = loaded; model = loaded
        } else { unavailable.insert(key); return nil }
        guard let raw = model.vector(for: text), raw.count == model.dimension,
              raw.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return Vector(model: "apple-sentence:\(key):\(model.revision):\(model.dimension)",
                      language: key, values: raw.map { Float($0 / norm) })
    }

    static func similarity(_ left: Vector, _ right: Vector) -> Double? {
        guard left.model == right.model, left.values.count == right.values.count,
              !left.values.isEmpty else { return nil }
        return Double(zip(left.values, right.values).reduce(Float(0)) { $0 + $1.0 * $1.1 })
    }
}

struct SemanticEntry: Codable {
    var id: String
    var kind: String
    var text: String
    var people: [String]
    var evidence: [MemoryEvidence]
    var sources: [ContextSource]
    var fingerprint: String
    var vector: LocalTextEmbedding.Vector?
    var canonicalClaimIDs: [String]? = nil
    var claimText: String? = nil
    var corrected: Bool? = nil
}

struct SemanticDocument: Codable {
    var version = 1
    var entries: [SemanticEntry] = []
    var updated: String = ""
}

struct ContextSearchResult: Codable {
    struct Match: Codable {
        var id: String
        var kind: String
        var text: String
        var people: [String]
        var evidence: [MemoryEvidence]
        /// A ranking score, never a confidence in the statement's truth.
        var score: Double
        var match: String
        /// Current assertion and change provenance, including user corrections.
        /// A source quote alone must not imply a negated or ended relationship.
        var memory: ContextSearch.Match? = nil
    }
    var matches: [Match]
    var mode: String
    var language: String?
    var indexedSources: Int
    var staleSources: Int
    var updated: String
    var asOf: String? = nil
}

enum SemanticIndex {
    private static let cacheLock = NSLock()
    private static var cached: (root: String, stamp: String, document: SemanticDocument)?
    /// A sidebar result must expire on a source edit even before indexing runs.
    /// Reading file attributes here does not load the original source text.
    static func freshnessKey() -> String {
        let catalog = (try? ContextStore.catalog()) ?? []
        let remote = (try? ContextSnapshot.load(root: Library.root))?.proofs.values.flatMap { $0.keys } ?? []
        let dependencies = Set(catalog.flatMap { $0.dependencies.keys } + remote)
        return ContextFiles.hash((["context/memory.sqlite", "context/memory.sqlite-wal", ContextSnapshot.filename, ContextSync.editsFilename] + dependencies.sorted())
            .map { $0 + ContextFiles.stamp($0) }.joined(separator: "\n"))
    }

    static func load() throws -> SemanticDocument {
        let db = try ContextStore.database()
        let root = Library.root.path
        let wal = Library.root.appendingPathComponent("context/memory.sqlite-wal")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? NSNumber)?.intValue ?? 0
        // A read-only connection can create an empty WAL with a fresh inode.
        // Only a nonempty WAL contains changes that invalidate decoded vectors.
        let stamp = ContextFiles.stamp("context/memory.sqlite") + (walSize > 0 ? ContextFiles.stamp("context/memory.sqlite-wal") : "")
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached, cached.root == root, cached.stamp == stamp { return cached.document }
        var entries = try db.all(SemanticEntry.self, in: .search)
        for row in try db.rows("SELECT id,namespace,dimensions,value FROM vectors") {
            let id = String(decoding: row[0], as: UTF8.self), namespace = String(decoding: row[1], as: UTF8.self)
            let count = Int(String(decoding: row[2], as: UTF8.self)) ?? 0
            guard row[3].count == count * 4, count > 0 else { continue }
            let bytes = Array(row[3])
            var values: [Float] = []
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let a = UInt32(bytes[i]), b = UInt32(bytes[i + 1]) << 8
                let c = UInt32(bytes[i + 2]) << 16, d = UInt32(bytes[i + 3]) << 24
                values.append(Float(bitPattern: a | b | c | d))
            }
            guard values.allSatisfy({ $0.isFinite }) else { continue }
            entries[id]?.vector = LocalTextEmbedding.Vector(model: namespace,
                language: namespace.hasPrefix("apple-sentence:") ? String(namespace.split(separator: ":")[1]) : "multilingual", values: values)
        }
        let document = SemanticDocument(entries: entries.values.sorted { $0.id < $1.id },
            updated: try db.get(String.self, in: .metadata, id: "searchUpdated") ?? "")
        cached = (root, stamp, document)
        return document
    }

    /// Reuse unchanged vectors. Source text, language model revision and claim
    /// identity determine validity; a timestamp alone cannot reuse an old vector.
    @discardableResult
    static func refresh() throws -> Int {
        let ownership = try ContextLock("search.lock")
        defer { withExtendedLifetime(ownership) {} }
        let old = try load()
        let previous = Dictionary(uniqueKeysWithValues: old.entries.map { ($0.id, $0) })
        let sources = ContextSources.all()
        try ContextStore.refreshSources(sources)
        var new: [SemanticEntry] = []
        let embedder = LocalTextEmbedding()
        for source in sources {
            try Task.checkCancellation()
            let retained = source.catalogEntry
            for passage in source.passages {
              for (sentence, text) in sentencePieces(passage.text).enumerated() {
                let id = "\(source.id)#\(passage.ref).\(sentence)"
                let fingerprint = ContextFiles.hash(source.fingerprint + text)
                let evidence = MemoryEvidence(source: source.id, title: source.title, date: source.date,
                    quote: text, speaker: passage.speaker, start: passage.start, end: passage.end, marker: source.marker)
                let before = previous[id]
                let vector = reusable(before, fingerprint: fingerprint) ? before?.vector : embedder.vector(text)
                new.append(SemanticEntry(id: id, kind: "passage", text: text, people: source.people,
                    evidence: [evidence], sources: [retained], fingerprint: fingerprint, vector: vector))
              }
            }
        }
        let memory = try PeopleMemory.load()
        let valid = PeopleMemory.validReceipts(memory)
        let sourceMap = Dictionary(grouping: valid, by: { $0.source.id })
        let people = Set(valid.flatMap { $0.claims.map(\.person) }).sorted()
        for label in people {
            try Task.checkCancellation()
            let person = try PeopleMemory.person(label, document: memory)
            for item in person.facts + person.relations where !["historical", "retracted"].contains(item.status) {
                let sourceList = item.evidence.compactMap { sourceMap[$0.source]?.first?.source }
                let text = SpeakerName.display(label) + ": " + item.attribute.replacingOccurrences(of: "_", with: " ") + " " + item.value
                let fingerprint = ContextFiles.hash("value-v2:" + text + sourceList.map(\.fingerprint).joined())
                let before = previous[item.id]
                let vector = reusable(before, fingerprint: fingerprint) ? before?.vector : embedder.vector(item.value)
                new.append(SemanticEntry(id: item.id, kind: item.objectKind == nil ? "fact" : "relationship",
                    text: text, people: [label], evidence: item.evidence, sources: sourceList,
                    fingerprint: fingerprint, vector: vector, canonicalClaimIDs: item.canonicalClaimIDs,
                    claimText: item.value, corrected: item.corrected))
            }
        }
        // No write for a no-op pass: the library watcher must not wake itself.
        let same = new.count == old.entries.count && new.allSatisfy {
            previous[$0.id]?.fingerprint == $0.fingerprint && previous[$0.id]?.vector?.model == $0.vector?.model
                && previous[$0.id]?.sources.map(\.dependencies) == $0.sources.map(\.dependencies)
                && previous[$0.id]?.evidence.map(\.title) == $0.evidence.map(\.title)
                && previous[$0.id]?.canonicalClaimIDs == $0.canonicalClaimIDs
        }
        let db = try ContextStore.database()
        if !same {
            try db.transaction {
                let ids = Set(new.map(\.id))
                for id in previous.keys where !ids.contains(id) {
                    try db.remove(.search, id: id)
                    try db.execute("DELETE FROM context_fts WHERE id=?", [.text(id)])
                    try db.execute("DELETE FROM vectors WHERE id=?", [.text(id)])
                }
                for entry in new {
                    var stored = entry; stored.vector = nil
                    try db.put(stored, in: .search, id: entry.id)
                    if previous[entry.id]?.fingerprint != entry.fingerprint || previous[entry.id]?.vector?.model != entry.vector?.model {
                        try db.index(id: entry.id, text: entry.text, namespace: entry.vector?.model, vector: entry.vector?.values)
                    }
                }
                try db.put(Metadata.iso(Date()), in: .metadata, id: "searchUpdated")
            }
        }
        let catalog = sources.map { source -> ContextSource in
            return source.catalogEntry
        }
        try db.transaction {
            try db.replace(Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) }), in: .sources)
        }
        try ContextRetrieval.export()
        return new.count
    }

    /// Sentence models lose a short topic inside a multi-topic paragraph.
    /// The recruitment fixture scores .167 as a turn, .274 as its hiring
    /// sentence. Keep the source and timestamps, but embed each sentence.
    private static func sentencePieces(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex).map {
            String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return sentences.isEmpty ? [text] : sentences
    }

    private static func reusable(_ entry: SemanticEntry?, fingerprint: String) -> Bool {
        guard let entry, entry.fingerprint == fingerprint, let vector = entry.vector else { return false }
        if Settings.multilingualSearch { return vector.model == MultilingualEmbedding.namespace && MultilingualEmbedding.available }
        let language = NLLanguage(rawValue: vector.language)
        let revision = NLEmbedding.currentSentenceEmbeddingRevision(for: language)
        return vector.model == "apple-sentence:\(vector.language):\(revision):\(vector.values.count)"
    }

    private static let stopWords: Set<String> = ["a", "an", "the", "is", "are", "was", "to", "of", "in", "on", "and", "or", "for", "what", "about", "with", "who", "how", "this", "that"]
    static func words(_ text: String) -> Set<String> {
        Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)).subtracting(stopWords)
    }

    static func search(_ query: String, person: String? = nil, limit: Int = 12,
                       kinds: [String] = [], tags: [String] = [],
                       after: Date? = nil, before: Date? = nil, asOf: String? = nil) throws -> ContextSearchResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 2_000 else { throw ContextProblem.message("Search needs between 1 and 2,000 characters.") }
        let document = try load()
        let overrides = try ContextStore.database().all(ContextOverride.self, in: .overrides)
        // A corrected claim must never leak its previous wording while the
        // background index catches up. Original passages remain cited history.
        var sourceValidity: [String: Bool] = [:]
        var sourceFilters: [String: Bool] = [:]
        var stamps: [String: String] = [:]
        func current(_ source: ContextSource) -> Bool {
            if let cached = sourceValidity[source.id] { return cached }
            let valid = !source.dependencies.isEmpty && source.dependencies.allSatisfy { path, expected in
                let actual = stamps[path] ?? ContextFiles.stamp(path)
                stamps[path] = actual
                return actual == expected
            }
            sourceValidity[source.id] = valid
            return valid
        }
        func matchesFilters(_ source: ContextSource) -> Bool {
            if let cached = sourceFilters[source.id] { return cached }
            let matches: Bool
            if !tags.allSatisfy({ tag in source.tags.contains { Tags.matches($0, tag) } }) { matches = false }
            else if after == nil && before == nil { matches = true }
            else if let date = Timestamps.parse(source.date) {
                matches = (after == nil || date >= after!) && (before == nil || date <= before!)
            } else { matches = false }
            sourceFilters[source.id] = matches
            return matches
        }
        let candidates = document.entries.filter { entry in
            let userValues = Set((entry.canonicalClaimIDs ?? []) + [entry.id]).compactMap { overrides[$0] }
            guard ContextOverride.latest(userValues, field: "hidden")?.hidden != true, !entry.sources.isEmpty,
                  entry.sources.allSatisfy(current), kinds.isEmpty || kinds.contains(entry.kind),
                  person == nil || entry.people.contains(where: { SpeakerName.matches($0, person!) }) else { return false }
            if let override = ContextOverride.latest(userValues, field: "replacement") {
                if let correction = override.replacement, entry.claimText != correction { return false }
                if override.replacement == nil && entry.corrected == true { return false }
            }
            return entry.sources.contains(where: matchesFilters)
        }
        let tokens = words(query)
        let fts = try ContextStore.database().lexical(tokens.sorted(), limit: 10_000)
        let lexicalRanks = Dictionary(uniqueKeysWithValues: fts.enumerated().map { ($0.element, $0.offset) })
        let vector = LocalTextEmbedding().vector(query, query: true)
        var lexical: [(Int, Double)] = [], semantic: [(Int, Double)] = []
        for (i, entry) in candidates.enumerated() {
            let textWords = words(entry.text)
            let overlap = tokens.intersection(textWords).count
            let exact = entry.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            if overlap > 0 || exact {
                lexical.append((i, lexicalRanks[entry.id].map { 1 / Double(1 + $0) } ?? (Double(overlap) / Double(max(1, tokens.count)) + (exact ? 1 : 0))))
            }
            // A retrieval floor, not a truth score. In the local verification
            // fixture recruitment paraphrases score .27-.42; unrelated text is
            // negative. Keyword results never depend on this threshold.
            if let vector, let stored = entry.vector,
               let score = LocalTextEmbedding.similarity(vector, stored), score >= (vector.model.hasPrefix("mlx:") ? 0.75 : 0.25) { semantic.append((i, score)) }
        }
        lexical.sort { $0.1 == $1.1 ? candidates[$0.0].id < candidates[$1.0].id : $0.1 > $1.1 }
        semantic.sort { $0.1 == $1.1 ? candidates[$0.0].id < candidates[$1.0].id : $0.1 > $1.1 }
        if vector?.model.hasPrefix("mlx:") == true, let strongest = semantic.first?.1 {
            // E5's cosine range is narrow. Keep the nearby candidates instead
            // of promoting every unrelated sentence above a universal floor.
            semantic = Array(semantic.filter { $0.1 >= strongest - 0.035 }.prefix(30))
        }
        var scores: [Int: Double] = [:]
        let lexicalIDs = Set(lexical.map { $0.0 }), semanticIDs = Set(semantic.map { $0.0 })
        // Reciprocal rank fusion keeps a proper name searchable even when the
        // embedding model knows nothing about it. Scores have no confidence UI.
        for ranked in [lexical, semantic] {
            for (rank, row) in ranked.enumerated() { scores[row.0, default: 0] += 1 / Double(20 + rank) }
        }
        let ranked = scores.keys.sorted {
            if scores[$0] != scores[$1] { return scores[$0, default: 0] > scores[$1, default: 0] }
            return candidates[$0].id < candidates[$1].id
        }
        let cards = try ContextRetrieval.cards()
        var matches = ranked.compactMap { index -> ContextSearchResult.Match? in
            let entry = candidates[index]
            // Indexed facts are only ranking hints. Materialize their current
            // meaning from verified cards, including changes received by sync.
            guard entry.kind == "passage", asOf == nil else { return nil }
            return ContextSearchResult.Match(id: entry.id, kind: entry.kind, text: entry.text,
                people: entry.people, evidence: entry.evidence.prefix(2).map { $0.compact() }, score: scores[index] ?? 0,
                match: lexicalIDs.contains(index) ? (semanticIDs.contains(index) ? "hybrid" : "keyword") : "semantic")
        }
        var tagsBySource: [String: [String]] = [:]
        if !tags.isEmpty {
            for recording in Recording.all() { tagsBySource["rec:" + recording.id] = recording.metadata.tags ?? [] }
            for note in Notes.all() { tagsBySource["note:" + note.slug] = note.tags }
        }
        var filteredCards = cards
        for i in filteredCards.indices {
            filteredCards[i].entries = filteredCards[i].entries.filter { entry in
                let kind = entry.objectKind == nil ? "fact" : "relationship"
                guard kinds.isEmpty || kinds.contains(kind),
                      person == nil || SpeakerName.matches(entry.subjectName, person!) || cards.contains(where: {
                          $0.id == entry.subject && $0.aliases.contains { SpeakerName.matches($0, person!) }
                      }) else { return false }
                return entry.evidence.contains { source in
                    guard tags.allSatisfy({ tag in (tagsBySource[source.source] ?? []).contains { Tags.matches($0, tag) } }) else { return false }
                    guard after != nil || before != nil else { return true }
                    guard let date = Timestamps.parse(source.recordedAt) else { return false }
                    return (after == nil || date >= after!) && (before == nil || date <= before!)
                }
            }
        }
        let memory = try ContextSearch.search(query, cards: filteredCards, limit: limit, tokenBudget: 16000, asOf: asOf)
        var memoryMatches = Dictionary(uniqueKeysWithValues: memory.matches.map { ($0.id, $0) })
        // Preserve the optional multilingual model's matches without returning
        // any stale indexed wording. Remote cards work before an index exists.
        let allowed = Dictionary(filteredCards.flatMap { card in card.entries.map { ($0.id, (card, $0)) } }, uniquingKeysWith: { a, _ in a })
        for index in ranked where candidates[index].kind != "passage" && asOf == nil {
            let indexed = candidates[index]
            guard memoryMatches[indexed.id] == nil, let (card, live) = allowed[indexed.id],
                  !["historical", "retracted"].contains(live.status), live.text == indexed.claimText,
                  let hit = try ContextSearch.search(live.text, cards: [ContextCard(id: card.id, kind: card.kind, name: card.name,
                    aliases: card.aliases, brief: [], entries: [live], updated: card.updated, pending: card.pending, failed: card.failed)],
                    limit: 1, semantic: false).matches.first else { continue }
            var value = hit; value.match = "semantic"; value.score = scores[index] ?? 0
            memoryMatches[indexed.id] = value
        }
        let orderedMemory = memoryMatches.values.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        let portable = orderedMemory.enumerated().map { rank, hit in
            ContextSearchResult.Match(id: hit.id, kind: hit.entry.objectKind == nil ? "fact" : "relationship",
                text: ContextSearch.text(hit.entry), people: Array(Set([hit.entry.subjectName] + (cards.first { $0.id == hit.entry.subject }?.aliases ?? []))).sorted(), evidence: hit.entry.evidence.map {
                    MemoryEvidence(source: $0.source, title: $0.title, date: $0.recordedAt, quote: $0.quote,
                        speaker: $0.speaker, start: $0.start, marker: "[\($0.source)]")
                }, score: 1 / Double(10 + rank), match: hit.match, memory: hit)
        }
        matches = Array((portable + matches).sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.prefix(max(1, min(limit, 50))))
        return ContextSearchResult(matches: matches, mode: vector == nil && memory.mode == "keyword" ? "keyword" : "hybrid",
            language: vector?.language, indexedSources: sourceValidity.values.filter { $0 }.count,
            staleSources: sourceValidity.values.filter { !$0 }.count, updated: document.updated, asOf: asOf)
    }
}
