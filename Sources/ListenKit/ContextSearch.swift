import Foundation
import NaturalLanguage

/// Searches source-verified cards, never raw snapshots. The same compact
/// claims are used by the phone, Mac, Ask and automation clients. Embeddings
/// are an optional in-memory cache on this device and never leave it.
public enum ContextSearch {
    public struct Match: Codable, Sendable, Identifiable {
        public var id: String { entry.id }
        public var entity: String
        public var kind: String
        public var name: String
        public var entry: ContextCard.Entry
        public var score: Double
        public var match: String
    }
    public struct Result: Codable, Sendable {
        public var matches: [Match]
        public var omitted: Int
        public var asOf: String?
        public var mode: String
        public var estimatedTokens: Int
        public var tokenBudget: Int
    }

    private static let stopWords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "to", "of", "in", "on", "and", "or", "for",
        "what", "about", "with", "who", "how", "this", "that", "has", "have", "does", "do", "did",
        "me", "my", "tell", "can", "you", "any", "o", "os", "as", "de", "da", "do", "e", "que", "quem",
        "een", "de", "het", "van", "wie", "wat", "en", "over"
    ]
    public static func words(_ text: String) -> Set<String> {
        Set(ContextIdentity.normalized(text).split { !$0.isLetter && !$0.isNumber }.map(String.init))
            .subtracting(stopWords)
    }
    public static func text(_ entry: ContextCard.Entry) -> String {
        let qualifiers = ContextPresentation.qualifiers(modality: entry.modality, attribution: entry.attribution)
        return ([entry.subjectName, ContextPresentation.category(entry.predicate, polarity: entry.polarity), entry.text]
            + qualifiers + (entry.status == "recorded" ? [] : [entry.status.replacingOccurrences(of: "_", with: " ")])
            + (entry.corrected ? ["Your correction"] : [])).joined(separator: " · ")
    }
    public static func search(_ query: String, cards: [ContextCard], limit: Int = 12,
                              tokenBudget: Int = 3000, asOf: String? = nil,
                              semantic: Bool = true) throws -> Result {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 2000, (256...16000).contains(tokenBudget),
              asOf == nil || ContextTime.validDay(asOf!) else {
            throw ContextDatabase.Failure(message: "Use a query of 1–2000 characters, a 256–16000 token budget and an optional YYYY-MM-DD date.")
        }
        let tokens = words(query)
        let vector = semantic && cards.contains(where: { !$0.entries.isEmpty }) ? ContextSearchEmbedding.shared.vector(query) : nil
        var byClaim: [String: Match] = [:]
        for card in cards.sorted(by: { $0.id < $1.id }) {
            let aliases = card.aliases + [card.name]
            let named = aliases.contains { alias in
                let name = ContextIdentity.normalized(alias)
                let question = ContextIdentity.normalized(query)
                return !name.isEmpty && question.range(of: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
            }
            for var entry in card.entries where !entry.evidence.isEmpty {
                if let asOf {
                    if let from = entry.time?.from, from > asOf { continue }
                    if let to = entry.time?.to, to <= asOf { continue }
                } else if ["historical", "retracted"].contains(entry.status) { continue }
                // Search the effective wording. Original quotes and superseded
                // wording remain inspectable, but cannot match a current claim.
                let value = text(entry)
                let terms = words(value)
                let overlap = tokens.intersection(terms).count
                let lexical = Double(overlap) / Double(max(1, tokens.count))
                // Embed the claim's wording. Names and presentation labels
                // dilute short sentence vectors; keep them in lexical ranking
                // and the returned assertion instead. Relationships need their
                // predicate because their value can be just a project name.
                let semanticText = entry.objectKind == nil ? entry.text
                    : ContextPresentation.category(entry.predicate, polarity: entry.polarity) + " " + entry.text
                let similarity = vector.flatMap { ContextSearchEmbedding.shared.similarity($0, text: semanticText) } ?? 0
                let related = similarity >= 0.24
                guard overlap > 0 || named || related else { continue }
                let score = lexical * 2 + (named ? 1 : 0) + (related ? similarity : 0)
                if asOf != nil && ["historical", "retracted"].contains(entry.status) { entry.status = "recorded" }
                entry.evidence = entry.evidence.prefix(2).map { var source = $0; source.quote = String(source.quote.prefix(160)); return source }
                entry.changeEvidence = entry.changeEvidence?.prefix(2).map { var source = $0; source.quote = String(source.quote.prefix(160)); return source }
                let hit = Match(entity: card.id, kind: card.kind, name: card.name, entry: entry, score: score,
                    match: overlap > 0 || named ? (related ? "hybrid" : "keyword") : "semantic")
                // Project and person cards can carry the same claim. Prefer
                // the named card, otherwise the person, without duplicating it.
                if let old = byClaim[entry.id], old.score > score || (old.score == score && old.kind == "person") { continue }
                byClaim[entry.id] = hit
            }
        }
        let ranked = byClaim.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.entry.pinned != $1.entry.pinned { return $0.entry.pinned }
            return $0.id < $1.id
        }
        var result = Result(matches: [], omitted: ranked.count, asOf: asOf,
            mode: vector == nil ? "keyword" : "hybrid", estimatedTokens: 0, tokenBudget: tokenBudget)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Leave room for each surface's citation IDs and result envelope.
        for hit in ranked.prefix(max(1, min(limit, 50))) {
            var next = result; next.matches.append(hit); next.omitted -= 1
            if try encoder.encode(next).count <= tokenBudget * 2 { result = next }
        }
        result.estimatedTokens = (try encoder.encode(result).count + 2) / 3
        return result
    }
}

private final class ContextSearchEmbedding: @unchecked Sendable {
    static let shared = ContextSearchEmbedding()
    struct Vector { var namespace: String; var values: [Double] }
    private let lock = NSRecursiveLock()
    private var models: [NLLanguage: NLEmbedding] = [:]
    private var unavailable: Set<NLLanguage> = []
    private var cache: [String: Vector] = [:]
    func vector(_ text: String) -> Vector? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[text] { return cached }
        let language = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        guard !unavailable.contains(language) else { return nil }
        guard let model = models[language] ?? NLEmbedding.sentenceEmbedding(for: language) else {
            unavailable.insert(language); return nil
        }
        models[language] = model
        guard let values = model.vector(for: text), values.count == model.dimension, values.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 }); guard norm > 0 else { return nil }
        let vector = Vector(namespace: "\(language.rawValue):\(model.revision):\(model.dimension)", values: values.map { $0 / norm })
        if cache.count >= 4096 { cache.removeAll(keepingCapacity: true) }
        cache[text] = vector; return vector
    }
    func similarity(_ query: Vector, text: String) -> Double? {
        guard let document = vector(text), query.namespace == document.namespace,
              query.values.count == document.values.count else { return nil }
        return zip(query.values, document.values).reduce(0) { $0 + $1.0 * $1.1 }
    }
}
