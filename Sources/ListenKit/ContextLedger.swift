import Foundation
import CryptoKit

public enum ContextIdentity {
    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public struct ContextEntity: Codable, Sendable {
    public var id: String
    public var kind: String
    public var name: String
    public var aliases: [String]
    public init(kind: String, name: String) {
        id = ContextIdentity.hash(kind + ":" + ContextIdentity.normalized(name)); self.kind = kind; self.name = name; aliases = [name]
    }
}

/// Effective time is optional. Recording/import time never fills these fields.
public struct ContextTime: Codable, Sendable, Equatable {
    public var from: String?
    public var to: String?
    public var wording: String?
    public var precision: String?
    public var timeZone: String?
    public init(from: String? = nil, to: String? = nil, wording: String? = nil,
                precision: String? = nil, timeZone: String? = nil) {
        self.from = from; self.to = to; self.wording = wording
        self.precision = precision; self.timeZone = timeZone
    }
    public static func validDay(_ day: String) -> Bool {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        return day.count == 10 && formatter.date(from: day).map { formatter.string(from: $0) == day } == true
    }
    /// Unambiguous, fully stated calendar days. Relative phrases and dates with
    /// a missing year retain their wording until a source locale/zone is known.
    public static func statedDays(_ wording: String) -> Set<String> {
        let text = ContextIdentity.normalized(wording)
        let months = [
            ["january", "janeiro", "januari"], ["february", "fevereiro", "februari"],
            ["march", "marco", "maart"], ["april", "abril"], ["may", "maio", "mei"],
            ["june", "junho", "juni"], ["july", "julho", "juli"], ["august", "agosto", "augustus"],
            ["september", "setembro"], ["october", "outubro", "oktober"], ["november", "novembro"],
            ["december", "dezembro"]]
        var days: Set<String> = []
        func matches(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
                (0..<match.numberOfRanges).map { ns.substring(with: match.range(at: $0)) }
            }
        }
        for match in matches("(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])") where validDay(match[0]) { days.insert(match[0]) }
        for (index, names) in months.enumerated() {
            let month = "(?:" + names.joined(separator: "|") + ")"
            for pattern in ["\\b([0-9]{1,2})(?:st|nd|rd|th)? (?:de )?" + month + "(?:,| de)? ([0-9]{4})\\b",
                            "\\b" + month + " ([0-9]{1,2})(?:st|nd|rd|th)?[,]? ([0-9]{4})\\b"] {
                for match in matches(pattern) {
                    let day = String(format: "%04d-%02d-%02d", Int(match[2]) ?? 0, index + 1, Int(match[1]) ?? 0)
                    if validDay(day) { days.insert(day) }
                }
            }
        }
        return days
    }
    public func validate(quote: String) throws {
        if let wording, wording.isEmpty || !quote.contains(wording) {
            throw ContextDatabase.Failure(message: "Time wording must be copied from the supporting quote.")
        }
        if timeZone != nil {
            throw ContextDatabase.Failure(message: "A source time zone has not been established. Leave timeZone unset.")
        }
        guard from != nil || to != nil else { return }
        guard let wording, !wording.isEmpty, quote.contains(wording), precision == "day",
              [from, to].compactMap({ $0 }).allSatisfy({ Self.validDay($0) && Self.statedDays(wording).contains($0) }),
              from == nil || to == nil || from! <= to! else {
            throw ContextDatabase.Failure(message: "Effective dates require the exact, unambiguous date in the source. Keep ambiguous dates as wording only.")
        }
    }
}

public struct ContextProvenance: Codable, Sendable {
    public var source: String
    public var revision: String
    public var passage: Int
    public var quote: String
    public var quoteStart: Int
    public var quoteEnd: Int
    public var recordedAt: String
    public var learnedAt: String
    public var speaker: String?
    public var start: Double?
    public var end: Double?
    public var sourceGroups: [String]
    public var provider: String
    public var requestedModel: String?
    public var resolvedModel: String?
    public var extractorVersion: Int
    public init(source: String, revision: String, passage: Int, quote: String, quoteStart: Int,
                recordedAt: String, learnedAt: String, speaker: String?, start: Double?, end: Double?,
                sourceGroups: [String], provider: String, requestedModel: String?, resolvedModel: String?, extractorVersion: Int) {
        self.source = source; self.revision = revision; self.passage = passage; self.quote = quote
        self.quoteStart = quoteStart; quoteEnd = quoteStart + quote.utf16.count
        self.recordedAt = recordedAt; self.learnedAt = learnedAt; self.speaker = speaker
        self.start = start; self.end = end; self.sourceGroups = sourceGroups
        self.provider = provider; self.requestedModel = requestedModel; self.resolvedModel = resolvedModel
        self.extractorVersion = extractorVersion
    }
}

public struct ContextObservation: Codable, Sendable {
    public var id: String
    public var subject: String
    public var predicate: String
    public var value: String
    public var object: String?
    public var objectKind: String?
    public var polarity: String
    public var modality: String
    public var attribution: String
    public var time: ContextTime
    public var evidence: ContextProvenance
    public init(id: String, subject: String, predicate: String, value: String, object: String?, objectKind: String?,
                polarity: String, modality: String, attribution: String, time: ContextTime, evidence: ContextProvenance) {
        self.id = id; self.subject = subject; self.predicate = predicate; self.value = value
        self.object = object; self.objectKind = objectKind; self.polarity = polarity
        self.modality = modality; self.attribution = attribution; self.time = time; self.evidence = evidence
    }
}

/// Each event is one alternative support set. All premises within it are
/// required; another valid event may independently support the same transition.
public struct ContextTransition: Codable, Sendable {
    public var id: String
    public var operation: String
    public var prior: String
    public var next: String
    public var supports: [String]
    public var effectiveDate: String?
    public var quote: String?
    public var actor: String
    public var committedAt: String
    public var revoked: Bool
    public var provider: String?
    public var requestedModel: String?
    public var resolvedModel: String?
    public var reconcilerVersion: Int?
    public init(operation: String, prior: String, next: String, supports: [String], effectiveDate: String? = nil,
                quote: String? = nil, actor: String, committedAt: String, provider: String? = nil,
                requestedModel: String? = nil, resolvedModel: String? = nil, reconcilerVersion: Int? = nil) {
        id = ContextIdentity.hash([operation, prior, next, supports.sorted().joined(), effectiveDate ?? ""].joined(separator: "\n"))
        self.operation = operation; self.prior = prior; self.next = next; self.supports = supports
        self.effectiveDate = effectiveDate; self.quote = quote; self.actor = actor; self.committedAt = committedAt; revoked = false
        self.provider = provider; self.requestedModel = requestedModel
        self.resolvedModel = resolvedModel; self.reconcilerVersion = reconcilerVersion
    }
}

public struct ContextOverride: Codable, Sendable {
    public var id: String
    public var hidden: Bool
    public var replacement: String?
    public var pinned: Bool
    public var updated: String
    public var fieldUpdated: [String: String]?
    public init(id: String, hidden: Bool = false, replacement: String? = nil, pinned: Bool = false, updated: String) {
        self.id = id; self.hidden = hidden; self.replacement = replacement; self.pinned = pinned; self.updated = updated
    }
    public mutating func mark(_ fields: [String], at time: String) {
        if fieldUpdated == nil { fieldUpdated = ["hidden": updated, "replacement": updated, "pinned": updated] }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let instant = max(Self.timestamp(time), Self.timestamp(updated) + 0.001)
        let stamp = formatter.string(from: Date(timeIntervalSince1970: instant))
        for field in fields { fieldUpdated?[field] = stamp }
        updated = stamp
    }
    public static func timestamp(_ value: String) -> TimeInterval {
        if value.isEmpty { return -Double.greatestFiniteMagnitude }
        let input = value.count == 10 ? value + "T00:00:00Z" : value
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: input) { return date.timeIntervalSince1970 }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: input)?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
    }
    public static func newer(_ left: String, _ right: String) -> String {
        timestamp(left) >= timestamp(right) ? left : right
    }
    /// A newer reset must beat an older correction, including across aliases.
    public static func latest(_ values: [Self], field: String) -> Self? {
        values.max {
            let left = $0.fieldUpdated?[field] ?? $0.updated
            let right = $1.fieldUpdated?[field] ?? $1.updated
            return (timestamp(left), $0.id) < (timestamp(right), $1.id)
        }
    }
}

public struct ContextJob: Codable, Sendable {
    public var id: String
    public var source: String
    public var revision: String
    public var stage: String
    public var state: String
    public var priority: Int
    public var lease: String?
    public var leaseUntil: Double?
    public var attempts: Int
    public var retryAfter: Double?
    public var provider: String?
    public var model: String?
    public var failure: String?
    public init(id: String, source: String, revision: String, stage: String, priority: Int) {
        self.id = id; self.source = source; self.revision = revision; self.stage = stage; self.priority = priority
        state = "pending"; attempts = 0
    }
}

public enum ContextLedger {
    /// Name resolution uses reviewed aliases. Similar spelling is not a merge.
    public static func entity(_ name: String, kind: String, db: ContextDatabase) throws -> ContextEntity {
        let alias = kind + ":" + ContextIdentity.normalized(name)
        if let id = try db.get(String.self, in: .aliases, id: alias),
           let found = try db.get(ContextEntity.self, in: .entities, id: id) { return found }
        let entity = ContextEntity(kind: kind, name: name)
        try db.put(entity, in: .entities, id: entity.id)
        try db.put(entity.id, in: .aliases, id: alias)
        return entity
    }
    public static func alias(_ name: String, entity id: String, rename: Bool = false, db: ContextDatabase) throws {
        try db.transaction {
            guard var entity = try db.get(ContextEntity.self, in: .entities, id: id), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ContextDatabase.Failure(message: "Choose an existing person or project and a name.")
            }
            let key = entity.kind + ":" + ContextIdentity.normalized(name)
            if let existing = try db.get(String.self, in: .aliases, id: key), existing != id {
                throw ContextDatabase.Failure(message: "That name belongs to another entity. Resolve the identity before adding the alias.")
            }
            if !entity.aliases.contains(name) { entity.aliases.append(name) }
            if rename { entity.name = name }
            try db.put(entity, in: .entities, id: id); try db.put(id, in: .aliases, id: key)
        }
    }

    /// Stable across model paraphrasing of the same attributed evidence.
    public static func claimID(subject: String, predicate: String, kind: String?, quote: String, object: String? = nil) -> String {
        let base = [subject, predicate, kind ?? "fact", ContextIdentity.normalized(quote)].joined(separator: "\n")
        return ContextIdentity.hash(base + (object.map { "\n" + $0 } ?? ""))
    }

    public static func apply(_ events: [ContextTransition], db: ContextDatabase, inTransaction: Bool = false) throws {
        guard events.count <= 16 else { throw ContextDatabase.Failure(message: "Too many reconciliation operations.") }
        let apply = {
            let observations = try db.all(ContextObservation.self, in: .observations)
            for event in events {
                guard ["supports", "paraphrase", "contradicts", "supersedes", "retracts"].contains(event.operation),
                      let prior = observations[event.prior], let next = observations[event.next], prior.id != next.id,
                      prior.subject == next.subject,
                      prior.predicate == next.predicate || (["supersedes", "retracts"].contains(event.operation) && next.predicate == "decision"),
                      !event.supports.isEmpty, event.supports.allSatisfy({ observations[$0] != nil }) else {
                    throw ContextDatabase.Failure(message: "Reconciliation referred to missing or incompatible observations.")
                }
                if ["supersedes", "retracts"].contains(event.operation) {
                    guard next.modality == "asserted", next.attribution == "direct",
                          let date = event.effectiveDate, ContextTime.validDay(date),
                          let quote = event.quote, ContextTime.statedDays(quote).contains(date),
                          event.supports.contains(next.id), next.evidence.quote.contains(quote),
                          next.time.wording.map { ContextTime.statedDays($0).contains(date) } == true,
                          prior.time.from == nil || prior.time.from! <= date else {
                        throw ContextDatabase.Failure(message: "A change needs direct, asserted evidence with an explicit effective date.")
                    }
                    let priorEvents = Array(try db.all(ContextTransition.self, in: .transitions).values)
                    var descendants: Set<String> = [next.id]
                    var added = true
                    while added {
                        added = false
                        for existing in priorEvents where !existing.revoked && ["supersedes", "retracts"].contains(existing.operation) && descendants.contains(existing.prior) {
                            if descendants.insert(existing.next).inserted { added = true }
                        }
                    }
                    guard !descendants.contains(prior.id) else { throw ContextDatabase.Failure(message: "Temporal transitions cannot form a cycle.") }
                }
                if ["supports", "paraphrase"].contains(event.operation) {
                    guard prior.polarity == next.polarity, prior.modality == next.modality,
                          prior.attribution == next.attribution, prior.time == next.time,
                          prior.object == next.object else {
                        throw ContextDatabase.Failure(message: "Different time, attribution or assertion cannot be merged.")
                    }
                }
                try db.put(event, in: .transitions, id: event.id)
            }
        }
        if inTransaction { try apply() } else { try db.transaction(apply) }
    }

    /// Delete source content and revoke only unsupported conclusions. A revoked
    /// event retains identifiers, never its quote or a deleted observation.
    public static func prune(currentRevisions: [String: String], activeIDs: Set<String>? = nil, db: ContextDatabase) throws {
        let all = try db.all(ContextObservation.self, in: .observations)
        let removed = Set(all.values.filter {
            currentRevisions[$0.evidence.source] != $0.evidence.revision || activeIDs?.contains($0.id) == false
        }.map(\.id))
        for id in removed { try db.remove(.observations, id: id) }
        for var event in try db.all(ContextTransition.self, in: .transitions).values
        where !event.revoked && (!removed.isDisjoint(with: event.supports) || removed.contains(event.next) || removed.contains(event.prior)) {
            event.revoked = true; event.quote = nil
            try db.put(event, in: .transitions, id: event.id)
        }
    }

    public static func canonical(_ id: String, events: [ContextTransition]) -> String {
        var group: Set<String> = [id], changed = true
        while changed {
            changed = false
            for event in events where !event.revoked && ["supports", "paraphrase"].contains(event.operation) {
                if group.contains(event.prior) || group.contains(event.next) {
                    if group.insert(event.prior).inserted { changed = true }
                    if group.insert(event.next).inserted { changed = true }
                }
            }
        }
        return group.sorted().first ?? id
    }

    public static func claim(_ job: ContextJob, db: ContextDatabase, now: Date = Date(), retry: Bool = false) throws -> ContextJob? {
        try db.transaction {
            var current = try db.get(ContextJob.self, in: .jobs, id: job.id) ?? job
            guard current.state != "complete",
                  current.leaseUntil ?? 0 <= now.timeIntervalSince1970,
                  retry || current.retryAfter ?? 0 <= now.timeIntervalSince1970 else { return nil }
            current.state = "running"; current.lease = UUID().uuidString
            current.leaseUntil = now.addingTimeInterval(600).timeIntervalSince1970
            current.provider = job.provider; current.model = job.model
            try db.put(current, in: .jobs, id: current.id); return current
        }
    }
    public static func finish(_ job: ContextJob, failure: String?, db: ContextDatabase, now: Date = Date()) throws {
        guard var current = try db.get(ContextJob.self, in: .jobs, id: job.id), current.lease == job.lease else {
            throw ContextDatabase.Failure(message: "This processing lease was replaced.")
        }
        current.state = failure == nil ? "complete" : "pending"
        current.lease = nil; current.leaseUntil = nil; current.failure = failure
        if failure != nil {
            current.attempts += 1; current.retryAfter = now.addingTimeInterval(min(3600, 30 * pow(2, Double(min(7, current.attempts))))).timeIntervalSince1970
        }
        try db.put(current, in: .jobs, id: current.id)
    }
    public static func release(_ job: ContextJob, db: ContextDatabase) throws {
        try db.transaction {
            guard var current = try db.get(ContextJob.self, in: .jobs, id: job.id), current.lease == job.lease else {
                throw ContextDatabase.Failure(message: "This processing lease was replaced.")
            }
            current.state = "pending"; current.lease = nil; current.leaseUntil = nil
            try db.put(current, in: .jobs, id: current.id)
        }
    }
}
