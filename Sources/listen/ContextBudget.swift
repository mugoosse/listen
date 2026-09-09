import Foundation
import ListenKit

struct ContextModelChoice: Codable {
    var provider: String
    var model: String?
}

extension Settings {
    static var contextModelChoice: ContextModelChoice? {
        get { defaults.data(forKey: "contextModelChoice").flatMap { try? JSONDecoder().decode(ContextModelChoice.self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "contextModelChoice") }
    }
    static var contextDailyRequests: Int {
        get { max(1, min(500, defaults.object(forKey: "contextDailyRequests") as? Int ?? 40)) }
        set { defaults.set(max(1, min(500, newValue)), forKey: "contextDailyRequests") }
    }
    static var contextPartsPerPass: Int {
        get { max(1, min(16, defaults.object(forKey: "contextPartsPerPass") as? Int ?? 4)) }
        set { defaults.set(max(1, min(16, newValue)), forKey: "contextPartsPerPass") }
    }
}

struct ContextUsage: Codable {
    var id: String
    var day: String
    var automatic: Bool
    var provider: String
    var requestedModel: String?
    var resolvedModel: String?
    var inputCharacters: Int
    var promptTokens: Int?
    var completionTokens: Int?
    var apiEquivalentUSD: Double?
    var durationMS: Int?
    var state: String
}

enum ContextBudget {
    struct Exhausted: LocalizedError {
        var errorDescription: String? { "Today's automatic update limit has been reached. Updates resume tomorrow; manual updates remain available." }
    }
    @TaskLocal static var automatic = false
    static var day: String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: Date())
    }

    static func reserve(_ question: AgentRun.Question) throws -> ContextUsage {
        let db = try ContextStore.database()
        return try db.transaction {
            let characters = question.text.count + question.systemInstruction.count
            guard characters <= 64_000 else { throw ContextProblem.message("This memory request exceeds its input budget.") }
            let today = try db.all(ContextUsage.self, in: .usage).values.filter { $0.day == day && $0.automatic }
            guard !automatic || today.count < Settings.contextDailyRequests else {
                throw Exhausted()
            }
            let usage = ContextUsage(id: UUID().uuidString, day: day, automatic: automatic,
                provider: question.provider?.id ?? question.backend.rawValue, requestedModel: question.model,
                inputCharacters: characters, state: "started")
            try db.put(usage, in: .usage, id: usage.id); return usage
        }
    }
    static func complete(_ usage: ContextUsage, outcome: AgentRun.Outcome?, cancelled: Bool) throws {
        var usage = usage
        usage.resolvedModel = outcome?.resolvedModel; usage.promptTokens = outcome?.promptTokens
        usage.completionTokens = outcome?.completionTokens; usage.apiEquivalentUSD = outcome?.costUSD
        usage.durationMS = outcome?.durationMS
        usage.state = cancelled ? "interrupted" : (outcome?.failure == nil ? "complete" : "failed")
        try ContextStore.database().put(usage, in: .usage, id: usage.id)
    }
    static func today() throws -> [ContextUsage] {
        try ContextStore.database().all(ContextUsage.self, in: .usage).values.filter { $0.day == day }
    }
}
