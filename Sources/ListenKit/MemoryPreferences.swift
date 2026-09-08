import Foundation
import Darwin

/// Owner choices, independently merged per field. No credentials or source text.
/// Missing consent always means manual. Requests are explicit, durable actions;
/// a device receiving a brief does not thereby gain permission to generate one.
public enum MemoryPreferences {
    public static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
    public static let filename = "people-memory-settings.json"
    public struct Value: Codable, Sendable {
        public var text: String
        public var updated: String
    }
    public struct Policy: Sendable {
        public var automatic = false
        public var sources: Set<String> = []
        public var knownSources: Set<String> = []
        public var deletedBefore = ""
        public var model: Model? = nil
        public func includes(_ source: String) -> Bool {
            sources.contains(source) || (automatic && !knownSources.contains(source))
        }
    }
    public struct Model: Codable, Sendable, Equatable {
        public var provider: String
        public var model: String?
        public var name: String
        public var executor: String?
        public init(provider: String, model: String?, name: String, executor: String? = nil) {
            self.provider = provider; self.model = model; self.name = name; self.executor = executor
        }
    }
    public struct Request: Codable, Sendable, Identifiable {
        public var id: String
        public var personID: String
        public var person: String
        public var sources: [String]
        public var model: Model
        public var created: String
        public var state: String
        public var message: String?
        public var updated: String
    }
    public static func read(root: URL) throws -> [String: Value] {
        let url = root.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try decode(Data(contentsOf: url))
    }
    private static func decode(_ data: Data) throws -> [String: Value] {
        guard data.count <= 4_000_000 else { throw ContextDatabase.Failure(message: "Memory settings exceed their size limit.") }
        let values = try JSONDecoder().decode([String: Value].self, from: data)
        guard values.count <= 20_000, values.allSatisfy({ key, value in
            key.count <= 300 && value.text.utf8.count <= 100_000
                && ContextOverride.timestamp(value.updated) > -Double.greatestFiniteMagnitude
        }) else { throw ContextDatabase.Failure(message: "Memory settings contain an invalid entry.") }
        return values
    }
    public static func merge(_ a: [String: Value], _ b: [String: Value]) -> [String: Value] {
        var result = a
        for (key, right) in b {
            guard let left = result[key] else { result[key] = right; continue }
            let x = ContextOverride.timestamp(left.updated), y = ContextOverride.timestamp(right.updated)
            if y > x { result[key] = right }
            else if y == x {
                let consent = key.hasPrefix("person:") && key.hasSuffix(":automatic")
                result[key] = consent && (left.text == "false" || right.text == "false")
                    ? (left.text == "false" ? left : right)
                    : (right.text > left.text ? right : left)
            }
        }
        return result
    }
    @discardableResult
    public static func receive(_ data: Data, root: URL) throws -> Data {
        try write(decode(data), root: root)
        return try Data(contentsOf: root.appendingPathComponent(filename))
    }
    private static func write(_ values: [String: Value], root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.appendingPathComponent(".people-memory-settings.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ContextDatabase.Failure(message: "Cannot save memory settings.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ContextDatabase.Failure(message: "Cannot lock memory settings.") }
        let result = merge(try read(root: root), values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(result)
        _ = try decode(data)
        try data.write(to: root.appendingPathComponent(filename), options: .atomic)
    }
    public static func set(_ text: String, key: String, root: URL) throws {
        let previous = try read(root: root)[key]?.updated ?? ""
        let date = max(Date().timeIntervalSince1970, ContextOverride.timestamp(previous) + 0.001)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try write([key: Value(text: text, updated: f.string(from: Date(timeIntervalSince1970: date)))], root: root)
    }
    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
    public static func personID(_ name: String, root: URL) -> String {
        let values = try? read(root: root)
        if let id = values?["alias:" + ContextIdentity.normalized(name)]?.text { return canonicalID(id, root: root) }
        // The generated entity identity survives an explicit rename.
        if let cards = try? ContextSnapshot.load(root: root)?.cards,
           let card = cards.first(where: { $0.kind == "person" && ([$0.name] + $0.aliases).contains(where: {
               ContextIdentity.normalized($0) == ContextIdentity.normalized(name)
           }) }) { return canonicalID(card.id, root: root) }
        return ContextEntity(kind: "person", name: name).id
    }
    public static func canonicalID(_ id: String, root: URL) -> String {
        let values = (try? read(root: root)) ?? [:]
        var current = id, seen = Set<String>()
        while seen.insert(current).inserted, let next = values["redirect:" + current]?.text, next != current {
            current = next
        }
        return current
    }
    /// An explicit merge links notes and stops the old person's background work.
    /// It does not expand the surviving person's source consent.
    public static func redirect(_ id: String, to target: String, root: URL) throws {
        guard id != target else { return }
        try automatic(false, person: id, root: root)
        for request in try requests(root: root) where request.personID == id && ["pending", "running"].contains(request.state) {
            try cancel(request.id, root: root)
        }
        try set(target, key: "redirect:" + id, root: root)
    }
    public static func associate(_ name: String, id: String, root: URL) throws {
        try set(id, key: "alias:" + ContextIdentity.normalized(name), root: root)
    }
    public static func policy(_ id: String, root: URL) throws -> Policy {
        let values = try read(root: root), prefix = "person:\(id):"
        func strings(_ key: String) -> Set<String> {
            Set((values[prefix + key]?.text.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) }) ?? [])
        }
        return Policy(automatic: values[prefix + "automatic"]?.text == "true",
                      sources: strings("sources"), knownSources: strings("known"),
                      deletedBefore: values[prefix + "deleted"]?.text ?? "",
                      model: values[prefix + "model"]?.text.data(using: .utf8).flatMap { try? JSONDecoder().decode(Model.self, from: $0) })
    }
    public static func select(_ sources: Set<String>, known: Set<String>, person: String, root: URL) throws {
        try set(json(sources.sorted()), key: "person:\(person):sources", root: root)
        try set(json(known.sorted()), key: "person:\(person):known", root: root)
    }
    public static func automatic(_ enabled: Bool, person: String, model: Model? = nil, root: URL) throws {
        if enabled {
            guard let selected = try model ?? policy(person, root: root).model ?? self.model(root: root), selected.executor != nil else {
                throw ContextDatabase.Failure(message: "Choose a model on your Mac before enabling automatic briefs.")
            }
            try set(json(selected), key: "person:\(person):model", root: root)
        }
        try set(String(enabled), key: "person:\(person):automatic", root: root)
    }
    public static func deleteMemory(person: String, root: URL) throws {
        try automatic(false, person: person, root: root)
        try set(stamp(), key: "person:\(person):deleted", root: root)
        for request in try requests(root: root) where request.personID == person && !["complete", "cancelled"].contains(request.state) {
            try cancel(request.id, root: root)
        }
    }
    public static func model(root: URL) throws -> Model? {
        guard let text = try read(root: root)["model"]?.text else { return nil }
        return try JSONDecoder().decode(Model.self, from: Data(text.utf8))
    }
    public static func advertise(_ model: Model, root: URL) throws {
        if try self.model(root: root) != model { try set(json(model), key: "model", root: root) }
    }
    @discardableResult
    public static func request(person: String, name: String, sources: Set<String>, model: Model, root: URL) throws -> Request {
        guard !sources.isEmpty else { throw ContextDatabase.Failure(message: "Select at least one source for this brief.") }
        for previous in try requests(root: root) where previous.personID == person && ["pending", "running"].contains(previous.state) {
            try cancel(previous.id, root: root)
        }
        let now = stamp()
        let request = Request(id: UUID().uuidString, personID: person, person: name,
            sources: sources.sorted(), model: model, created: now, state: "pending", updated: now)
        try set(json(request), key: "request:" + request.id, root: root)
        return request
    }
    public static func requests(root: URL) throws -> [Request] {
        let values = try read(root: root)
        return values.filter { $0.key.hasPrefix("request:") }.compactMap { key, value in
            guard var request = try? JSONDecoder().decode(Request.self, from: Data(value.text.utf8)),
                  key == "request:" + request.id, UUID(uuidString: request.id) != nil, !request.sources.isEmpty, request.sources.count <= 5_000,
                  request.personID.count <= 200, request.person.count <= 300, request.model.provider.count <= 200,
                  request.sources.allSatisfy({ $0.count <= 300 && !$0.contains("..") }),
                  ["pending", "running", "complete", "failed", "cancelled"].contains(request.state) else { return nil }
            if values["cancel:" + request.id]?.text == "true" { request.state = "cancelled" }
            return request
        }.sorted { ($0.created, $0.id) < ($1.created, $1.id) }
    }
    public static func finish(_ request: Request, state: String, message: String? = nil, root: URL) throws {
        var request = request; request.state = state; request.message = message; request.updated = stamp()
        try set(json(request), key: "request:" + request.id, root: root)
    }
    public static func cancel(_ id: String, root: URL) throws {
        try set("true", key: "cancel:" + id, root: root)
    }
    /// Changes to exclusions invalidate in-flight AI history, without reading
    /// note bodies into a provider request.
    public static func excludedNotes(root: URL) -> Set<String> {
        let directory = root.appendingPathComponent("notes")
        return Set(((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" && !sourceAllowed("note:" + $0.deletingPathExtension().lastPathComponent, root: root) }
            .map { $0.deletingPathExtension().lastPathComponent })
    }
    public static func sourceAllowed(_ id: String, root: URL) -> Bool {
        guard id.hasPrefix("note:") else { return true }
        let slug = String(id.dropFirst(5))
        guard !slug.isEmpty, slug.count <= 96, slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let text = try? String(contentsOf: root.appendingPathComponent("notes/\(slug).md"), encoding: .utf8) else { return false }
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return true }
        return !lines[1..<end].contains { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            return parts.count == 2 && parts[0] == "exclude_from_ai" && parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).lowercased() == "true"
        }
    }
}
