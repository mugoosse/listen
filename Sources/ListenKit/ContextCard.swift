import Foundation

/// The owner-device reading contract. No jobs, vectors, provider credentials or
/// library key belong in this projection.
public struct ContextCard: Codable, Sendable, Identifiable {
    public struct Evidence: Codable, Sendable {
        public var source: String
        public var title: String
        public var recordedAt: String
        public var quote: String
        public var speaker: String?
        public var start: Double?
        public var revision: String
        public var sourceGroups: [String]?
        public var learnedAt: String?
        public init(source: String, title: String, recordedAt: String, quote: String, speaker: String?, start: Double?, revision: String, sourceGroups: [String]? = nil, learnedAt: String? = nil) {
            self.source = source; self.title = title; self.recordedAt = recordedAt; self.quote = quote
            self.speaker = speaker; self.start = start; self.revision = revision
            self.sourceGroups = sourceGroups; self.learnedAt = learnedAt
        }
    }
    public struct Entry: Codable, Sendable, Identifiable {
        public var id: String
        public var subject: String
        public var subjectName: String
        public var predicate: String
        public var text: String
        public var object: String?
        public var objectKind: String?
        public var status: String
        public var time: ContextTime?
        public var evidence: [Evidence]
        public var changeEvidence: [Evidence]?
        public var corrected: Bool
        public var pinned: Bool
        public var attribution: String
        public var modality: String
        public var polarity: String
        public var endingSupports: [[String]]?
        public var conflictSupports: [[String]]?
        public var canonicalClaimIDs: [String]?
        public var originalText: String?
        public init(id: String, subject: String, subjectName: String, predicate: String, text: String, object: String?, objectKind: String?,
                    status: String, time: ContextTime?, evidence: [Evidence], corrected: Bool, pinned: Bool,
                    attribution: String, modality: String, polarity: String, endingSupports: [[String]]? = nil, conflictSupports: [[String]]? = nil, canonicalClaimIDs: [String]? = nil, originalText: String? = nil, changeEvidence: [Evidence]? = nil) {
            self.id = id; self.subject = subject; self.subjectName = subjectName; self.predicate = predicate; self.text = text
            self.object = object; self.objectKind = objectKind; self.status = status; self.time = time; self.evidence = evidence
            self.corrected = corrected; self.pinned = pinned; self.attribution = attribution; self.modality = modality; self.polarity = polarity
            self.endingSupports = endingSupports
            self.conflictSupports = conflictSupports
            self.canonicalClaimIDs = canonicalClaimIDs
            self.originalText = originalText
            self.changeEvidence = changeEvidence
        }
    }
    public struct Sentence: Codable, Sendable {
        public var text: String
        public var claims: [String]
        public init(text: String, claims: [String]) { self.text = text; self.claims = claims }
    }
    public var id: String
    public var kind: String
    public var name: String
    public var aliases: [String]
    public var brief: [Sentence]
    public var entries: [Entry]
    public var updated: String?
    public var pending: Int
    public var failed: Int
    public init(id: String, kind: String, name: String, aliases: [String], brief: [Sentence], entries: [Entry],
                updated: String?, pending: Int, failed: Int) {
        self.id = id; self.kind = kind; self.name = name; self.aliases = aliases; self.brief = brief
        self.entries = entries; self.updated = updated; self.pending = pending; self.failed = failed
    }
}

/// Reading labels preserve assertion meaning even when a relationship's text
/// is only an entity name. These labels never change the stored source wording.
public enum ContextPresentation {
    public static func category(_ predicate: String, polarity: String = "positive") -> String {
        let negative = ["works_on": "Does not work on", "works_at": "Does not work at",
                        "collaborates_with": "Does not collaborate with", "reports_to": "Does not report to",
                        "mentors": "Does not mentor", "interested_in": "Not interested in"]
        if polarity == "negative", let value = negative[predicate] { return value }
        let text = predicate.replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
    public static func qualifiers(modality: String, attribution: String) -> [String] {
        var labels: [String] = []
        if modality == "planned" { labels.append("Planned") }
        if modality == "uncertain" { labels.append("Unconfirmed") }
        if modality == "question" { labels.append("Question, not confirmed") }
        if attribution == "reported" { labels.append("Reported") }
        return labels
    }
}

public struct ContextPacket: Codable, Sendable {
    public var entity: String
    public var kind: String
    public var name: String
    public var brief: [ContextCard.Sentence]
    public var entries: [ContextCard.Entry]
    public var asOf: String?
    public var pending: Int
    public var failed: Int
    public var updated: String?
    public var omitted: Int
    public var estimatedTokens: Int
    public var tokenBudget: Int
}

public enum ContextBuilder {
    /// Deterministic, bounded retrieval shared by Mac, iPhone, CLI and MCP.
    /// Unknown effective dates remain visible and explicitly unknown.
    public static func build(_ card: ContextCard, question: String = "", tokenBudget: Int = 1500,
                             asOf: String? = nil, offset: Int = 0, limit: Int = 100) throws -> ContextPacket {
        guard (256...16000).contains(tokenBudget), question.count <= 2000,
              asOf == nil || ContextTime.validDay(asOf!) else {
            throw ContextDatabase.Failure(message: "Use a 256–16000 token budget, a question up to 2000 characters and an optional YYYY-MM-DD date.")
        }
        let words = Set(ContextIdentity.normalized(question).split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func rank(_ entry: ContextCard.Entry) -> Int {
            let terms = Set(ContextIdentity.normalized(entry.text + " " + entry.subjectName + " " + entry.predicate).split { !$0.isLetter && !$0.isNumber }.map(String.init))
            return terms.intersection(words).count * 10 + (entry.pinned ? 5 : 0) + (["conflicted", "needs_review"].contains(entry.status) ? 3 : 0)
        }
        let eligible = card.entries.filter { entry in
            if let asOf {
                if let from = entry.time?.from, from > asOf { return false }
                if let to = entry.time?.to, to <= asOf { return false }
                return true
            }
            return !["historical", "retracted"].contains(entry.status)
        }.sorted {
            let a = rank($0), b = rank($1)
            if a != b { return a > b }
            let left = $0.evidence.first?.recordedAt ?? "", right = $1.evidence.first?.recordedAt ?? ""
            return left == right ? $0.id < $1.id : left > right
        }
        var result = ContextPacket(entity: card.id, kind: card.kind, name: card.name, brief: [], entries: [],
            asOf: asOf, pending: card.pending, failed: card.failed, updated: card.updated,
            omitted: eligible.count, estimatedTokens: 0, tokenBudget: tokenBudget)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func fits(_ packet: ContextPacket) throws -> Bool { try encoder.encode(packet).count <= tokenBudget * 3 - 16 }
        guard try fits(result) else { throw ContextDatabase.Failure(message: "Increase the context budget to include this entity's name and metadata.") }
        for var entry in eligible.dropFirst(max(0, offset)).prefix(max(1, min(100, limit))) {
            if asOf != nil && ["historical", "retracted"].contains(entry.status) { entry.status = "recorded" }
            entry.evidence = entry.evidence.prefix(1).map { evidence in
                var evidence = evidence; evidence.quote = String(evidence.quote.prefix(160)); return evidence
            }
            entry.changeEvidence = entry.changeEvidence?.prefix(1).map { evidence in
                var evidence = evidence; evidence.quote = String(evidence.quote.prefix(160)); return evidence
            }
            var candidate = result; candidate.entries.append(entry); candidate.omitted -= 1
            if try fits(candidate) { result = candidate }
        }
        if asOf == nil {
            let selected = Set(result.entries.map(\.id))
            for sentence in card.brief where Set(sentence.claims).isSubset(of: selected) && !sentence.claims.isEmpty {
                var candidate = result; candidate.brief.append(sentence)
                if try fits(candidate) { result = candidate }
            }
        }
        result.estimatedTokens = (try encoder.encode(result).count + 2) / 3
        // Account for the estimate's own digits in the final payload.
        while !(try fits(result)), !result.brief.isEmpty { result.brief.removeLast() }
        while !(try fits(result)), !result.entries.isEmpty { result.entries.removeLast(); result.omitted += 1 }
        result.estimatedTokens = (try encoder.encode(result).count + 2) / 3
        return result
    }
}

public struct ContextSnapshot: Codable, Sendable {
    public static let filename = "people-context.json"
    public var version = 1
    public var cards: [ContextCard]
    /// Source ID -> relative library path -> SHA256 of the actual bytes.
    public var proofs: [String: [String: String]]
    public var overrides: [String: ContextOverride]
    public var generatedAt: String
    public init(cards: [ContextCard], proofs: [String: [String: String]], overrides: [String: ContextOverride], generatedAt: String) {
        self.cards = cards; self.proofs = proofs; self.overrides = overrides; self.generatedAt = generatedAt
    }
    public static func load(root: URL) throws -> ContextSnapshot? {
        let url = root.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ContextSnapshotCache.shared.load(url)
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 32_000_000 else { throw ContextDatabase.Failure(message: "The synced memory is too large to read.") }
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.version == 1 else { throw ContextDatabase.Failure(message: "Update Listen to read this memory.") }
        guard Set(snapshot.cards.map(\.id)).count == snapshot.cards.count,
              snapshot.cards.allSatisfy({ card in
                  !card.id.isEmpty && card.name.count <= 500 && Set(card.entries.map(\.id)).count == card.entries.count
                    && card.entries.allSatisfy { !$0.id.isEmpty && $0.text.count <= 500 && ($0.evidence + ($0.changeEvidence ?? [])).allSatisfy { $0.quote.count <= 900 } }
              }) else { throw ContextDatabase.Failure(message: "The synced memory has invalid or duplicate entries.") }
        try ContextSync.validate(snapshot.overrides)
        return snapshot
    }
    public func card(named name: String, kind: String, root: URL) -> ContextCard? {
        let matches = cards.filter { $0.kind == kind && ($0.id == name || ($0.aliases + [$0.name]).contains { ContextIdentity.normalized($0) == ContextIdentity.normalized(name) }) }
        guard matches.count == 1 else { return nil }
        return verified(matches[0], root: root)
    }
    /// A second Mac may still be processing its library. Its partial projection
    /// cannot erase valid work from another owner device. Fully reviewed local
    /// sources are authoritative, including an explicit empty extraction.
    public func merging(local: [ContextCard], reviewedSources: Set<String>, root: URL) -> [ContextCard] {
        var result = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.entries.count >= b.entries.count ? a : b })
        for input in cards {
            let remote = verified(input, root: root)
            let retained = remote.entries.filter { entry in !entry.evidence.allSatisfy { reviewedSources.contains($0.source) } }
            guard !retained.isEmpty else { continue }
            guard var card = result[remote.id] else {
                var card = remote; card.entries = retained
                let ids = Set(retained.map(\.id)); card.brief = card.brief.filter { Set($0.claims).isSubset(of: ids) }
                result[remote.id] = card; continue
            }
            let localIDs = Set(card.entries.flatMap { ($0.canonicalClaimIDs ?? []) + [$0.id] })
            let additions = retained.filter { localIDs.isDisjoint(with: ($0.canonicalClaimIDs ?? []) + [$0.id]) }
            if !additions.isEmpty { card.entries += additions; card.brief = [] }
            card.aliases = Array(Set(card.aliases + remote.aliases)).sorted()
            card.updated = [card.updated, remote.updated].compactMap { $0 }.max()
            card.pending = max(card.pending, remote.pending); card.failed = max(card.failed, remote.failed)
            result[remote.id] = card
        }
        return result.values.sorted { $0.id < $1.id }
    }
    public func verified(_ input: ContextCard, root: URL) -> ContextCard {
        var card = input
        var changedSupport = false
        var validity: [String: Bool] = [:]
        func current(_ id: String) -> Bool {
            if let value = validity[id] { return value }
            let paths = proofs[id] ?? [:]
            let value = MemoryPreferences.sourceAllowed(id, root: root) && !paths.isEmpty && paths.allSatisfy { path, digest in
                !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
                    && ContextProofCache.shared.digest(root.appendingPathComponent(path)) == digest
            }
            validity[id] = value; return value
        }
        card.entries = card.entries.compactMap { input in
            var entry = input
            let cutoff = (try? MemoryPreferences.policy(entry.subject, root: root).deletedBefore) ?? ""
            if !cutoff.isEmpty && !entry.evidence.contains(where: { ContextOverride.timestamp($0.learnedAt ?? "") > ContextOverride.timestamp(cutoff) }) { return nil }
            entry.evidence = entry.evidence.filter { current($0.source) }
            entry.changeEvidence = entry.changeEvidence?.filter { current($0.source) }
            let userValues = Set((entry.canonicalClaimIDs ?? []) + [entry.id]).compactMap { overrides[$0] }
            guard !entry.evidence.isEmpty, ContextOverride.latest(userValues, field: "hidden")?.hidden != true else { return nil }
            if let sets = entry.endingSupports, !sets.isEmpty, !sets.contains(where: { !$0.isEmpty && $0.allSatisfy(current) }) {
                entry.time?.to = nil; entry.status = "needs_review"
                changedSupport = true
            }
            if entry.status == "conflicted", let sets = entry.conflictSupports, !sets.isEmpty,
               !sets.contains(where: { !$0.isEmpty && $0.allSatisfy(current) }) {
                entry.status = "needs_review"; changedSupport = true
            }
            if let replacement = ContextOverride.latest(userValues, field: "replacement")?.replacement {
                entry.text = replacement; entry.corrected = true
            } else if !userValues.isEmpty, let original = entry.originalText {
                if entry.text != original { changedSupport = true }
                entry.text = original; entry.corrected = false
            }
            if !userValues.isEmpty { entry.pinned = ContextOverride.latest(userValues, field: "pinned")?.pinned == true }
            return entry
        }
        let surviving = Set(card.entries.map(\.id))
        card.brief = card.brief.filter { !$0.claims.isEmpty && Set($0.claims).isSubset(of: surviving) }
        // Replacements invalidate generated wording, even if the ID survives.
        if changedSupport || card.entries.contains(where: \.corrected) { card.brief = [] }
        return card
    }
}

private final class ContextSnapshotCache: @unchecked Sendable {
    static let shared = ContextSnapshotCache()
    private let lock = NSLock()
    private var cached: [String: (String, ContextSnapshot)] = [:]
    func load(_ url: URL) throws -> ContextSnapshot {
        lock.lock(); defer { lock.unlock() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = "\(attributes[.systemFileNumber] ?? ""):\(attributes[.size] ?? ""):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let value = cached[url.path], value.0 == stamp { return value.1 }
        let value = try ContextSnapshot.decode(Data(contentsOf: url))
        if cached.count >= 4 { cached.removeAll() }
        cached[url.path] = (stamp, value); return value
    }
}

/// File hashes are reused while inode/size/mtime agree. No network or model is
/// involved in checking a compact card against the locally synced library.
public final class ContextProofCache: @unchecked Sendable {
    public static let shared = ContextProofCache()
    private let lock = NSLock()
    private var values: [String: (String, String)] = [:]
    public func digest(_ url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { values[url.path] = nil; return nil }
        let stamp = "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(a[.size] ?? 0):\(a[.systemFileNumber] ?? 0)"
        if let cached = values[url.path], cached.0 == stamp { return cached.1 }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let digest = sha256Hex(data)
        if values.count > 10_000 { values.removeAll() }
        values[url.path] = (stamp, digest); return digest
    }
}
