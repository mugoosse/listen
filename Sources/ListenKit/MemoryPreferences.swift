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
        // A public struct's memberwise initialiser is internal, so this type
        // could be named from outside ListenKit but never built there.
        public init(text: String, updated: String) {
            self.text = text
            self.updated = updated
        }
    }
    public struct Policy: Sendable {
        public var automatic = false
        public var sources: Set<String> = []
        public var knownSources: Set<String> = []
        public var deletedBefore = ""
        public var model: Model? = nil
        /// Whether an automatic sweep may read this source for this person.
        ///
        /// `named` is whether they speak in it, or a note is explicitly about
        /// them; `ContextSource.names(_:)` is what answers that. A person
        /// somebody else merely mentioned is not disclosing anything, and once
        /// the whole roster is enrolled that distinction is the difference
        /// between a bounded queue and every meeting in the library times
        /// everybody whose first name occurs in it.
        ///
        /// An explicitly selected source is still read whatever `named` says,
        /// because that is somebody choosing it in the composer rather than
        /// the sweep helping itself.
        public func includes(_ source: String, named: Bool = true) -> Bool {
            sources.contains(source) || (automatic && named && !knownSources.contains(source))
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
    /// **Cached on inode, size and mtime**, in the same shape and for the same
    /// reason as `ContextSnapshotCache` and `ContextProofCache`.
    ///
    /// This is read far more often than its name suggests. `personID` reads it
    /// and then calls `canonicalID`, which reads it again, so resolving one
    /// name is two decodes; `ContextSnapshot.verified` calls `policy` once per
    /// entry, so verifying a card is one decode per claim on it. The Library
    /// screen does both while drawing, and measured against a 86-recording
    /// library on 12 September 2026 that was 198 ms of blocked main thread per
    /// body evaluation: 84 ms resolving forty speaker names and 111 ms
    /// verifying six cards, all of it this function, none of it new work.
    ///
    /// Nothing is invalidated by hand. Every writer goes through `write`, which
    /// replaces the file, and a replaced file has a new mtime or a new inode,
    /// so the next read misses and decodes. A file changed by another process
    /// (a sync pass landing a merged copy) is caught the same way.
    public static func read(root: URL) throws -> [String: Value] {
        let url = root.appendingPathComponent(filename)
        guard let stamp = SettingsCache.stamp(url) else { return [:] }
        return try SettingsCache.shared.values(url, stamp: stamp, decode: decode)
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
    /// Whether somebody nobody has answered for yet is enrolled automatically.
    ///
    /// One register for the library rather than a preference on each install,
    /// because generation consent is scoped to the library path: the answer
    /// belongs with the recordings it is an answer about, and it should reach
    /// a second Mac without being given again. Absent means no, like every
    /// other consent in this file.
    public static func enrolsNewPeople(root: URL) -> Bool {
        ((try? read(root: root))?["enrolNewPeople"]?.text) == "true"
    }
    public static func enrolNewPeople(_ enabled: Bool, root: URL) throws {
        try set(String(enabled), key: "enrolNewPeople", root: root)
    }
    public static func deleteMemory(person: String, root: URL) throws {
        try automatic(false, person: person, root: root)
        try set(stamp(), key: "person:\(person):deleted", root: root)
        for request in try requests(root: root) where request.personID == person && !["complete", "cancelled"].contains(request.state) {
            try cancel(request.id, root: root)
        }
    }
    /// **Legacy, and read-only from here on.** The advertisement moved to each
    /// device's own record; see `CloudRecords.DeviceBlob.summaryModel` for what
    /// a single shared key cost. This still reads, so a Mac that has not been
    /// updated yet goes on being usable from a phone that has.
    public static func model(root: URL) throws -> Model? {
        guard let text = try read(root: root)["model"]?.text else { return nil }
        return try JSONDecoder().decode(Model.self, from: Data(text.utf8))
    }

    /// How recently a Mac must have said something to count as awake.
    ///
    /// A heartbeat republishes when its sentence changes and hourly regardless,
    /// so a Mac that is open and syncing is never quiet for longer than the
    /// pass interval by much. Fifteen minutes is comfortably past that and
    /// comfortably short of "it will be a while": long enough not to call an
    /// open Mac asleep between two passes, short enough that a lid closed
    /// after lunch is not still being called awake.
    public static let awakeWithin: TimeInterval = 15 * 60

    /// A Mac's standing offer to run summaries.
    public struct Offer: Sendable {
        public var device: CloudRecords.DeviceBlob
        public var model: Model
        /// Whether it has been heard from recently enough to start now.
        public var awake: Bool
        public var name: String { device.name }
    }

    /// What a phone should do about a summary right now.
    ///
    /// **The preferred Mac is a preference and not a lock**, which is the whole
    /// design decision. A lock turns "the Mac I chose is shut" into a request
    /// that never runs and never says why, which is the failure this whole area
    /// has just been repaired for. Automatic substitution is no better: two Macs
    /// can offer different models from different providers, so quietly running
    /// somewhere else changes what the summary costs and what wrote it.
    ///
    /// So the preference decides who is asked, freshness decides who *can* be
    /// asked, and where the two disagree both are handed to the screen and
    /// neither is chosen here. See `PersonBriefView`.
    public struct Plan: Sendable {
        /// The offer a request would be addressed to, or nil when no Mac has
        /// advertised at all.
        public var use: Offer?
        /// An awake Mac that is not the preferred one, offered as the
        /// alternative when the preferred one is asleep. Nil when there is no
        /// disagreement to put to anybody.
        public var insteadOf: Offer?
        /// Every offer, for a settings list.
        public var all: [Offer]
    }

    public static let preferredKey = "preferred-device"

    /// The device id the owner picked, or nil for "whichever Mac is awake".
    ///
    /// The sync device id rather than the executor id inside the model, because
    /// this is a choice about a machine and the machine is what the settings
    /// list shows. The executor is read back off that machine's own row when a
    /// request is addressed, so a Mac that changes its Ask model keeps the
    /// preference pointed at it.
    public static func preferredDevice(root: URL) -> String? {
        let value = (try? read(root: root))?[preferredKey]?.text ?? ""
        return value.isEmpty ? nil : value
    }

    public static func setPreferredDevice(_ id: String?, root: URL) throws {
        try set(id ?? "", key: preferredKey, root: root)
    }

    public static func plan(_ devices: [CloudRecords.DeviceBlob], root: URL,
                            now: Date = Date()) -> Plan {
        let all = offers(devices, now: now).map {
            Offer(device: $0.device, model: $0.model,
                  awake: $0.device.isLive(now, within: awakeWithin))
        }
        guard !all.isEmpty else { return Plan(use: nil, insteadOf: nil, all: []) }
        guard let wanted = preferredDevice(root: root),
              let preferred = all.first(where: { $0.device.id == wanted }) else {
            // No preference, or it names a Mac that is not offering. The
            // freshest awake one, and the freshest of any when none is awake:
            // a request addressed to a shut Mac still runs when it opens.
            return Plan(use: all.first { $0.awake } ?? all.first, insteadOf: nil, all: all)
        }
        if preferred.awake { return Plan(use: preferred, insteadOf: nil, all: all) }
        // Asleep. Addressed to it anyway, because that is what was asked for,
        // and the awake alternative is handed up rather than taken.
        return Plan(use: preferred,
                    insteadOf: all.first { $0.awake && $0.device.id != preferred.device.id },
                    all: all)
    }

    /// Every device offering to run a summary, freshest heartbeat first.
    ///
    /// The device is returned beside the model because a phone cannot say
    /// anything useful without it. "Waiting for your Mac" is not an answer
    /// when there are two of them and one has been shut since Friday; the
    /// row's name and `seenAgo` are what turn it into one.
    public static func offers(_ devices: [CloudRecords.DeviceBlob], now: Date = Date())
        -> [(device: CloudRecords.DeviceBlob, model: Model)] {
        devices.filter { $0.isLive(now) }
            .compactMap { device in device.summaryModel.map { (device, $0) } }
            .sorted { $0.device.lastSeen > $1.device.lastSeen }
    }

    /// The offer a request should be addressed to, or nil when no Mac is
    /// offering one.
    ///
    /// The freshest live offer wins, because the machine that said something
    /// most recently is the one most likely to be awake to do the work. The
    /// legacy key is consulted only when the roster offers nothing at all,
    /// which is a library whose Macs have not been updated yet.
    public static func offered(_ devices: [CloudRecords.DeviceBlob], root: URL,
                               now: Date = Date()) -> Model? {
        if let best = offers(devices, now: now).first { return best.model }
        return try? model(root: root)
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

/// The decoded settings file, reused while inode, size and mtime agree.
///
/// Separate from `ContextSnapshotCache` rather than generic over both, because
/// the two hold different types and a shared generic cache would have to erase
/// them. Two twenty-line caches beat one clever one.
private final class SettingsCache: @unchecked Sendable {
    static let shared = SettingsCache()
    private let lock = NSLock()
    private var cached: [String: (String, [String: MemoryPreferences.Value])] = [:]

    /// Nil when the file is not there, which is an empty settings file and not
    /// an error: a library nobody has expressed a preference in yet.
    static func stamp(_ url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(a[.size] ?? 0):\(a[.systemFileNumber] ?? 0)"
    }

    func values(_ url: URL, stamp: String,
                decode: (Data) throws -> [String: MemoryPreferences.Value])
        throws -> [String: MemoryPreferences.Value] {
        lock.lock(); defer { lock.unlock() }
        if let value = cached[url.path], value.0 == stamp { return value.1 }
        let value = try decode(Data(contentsOf: url))
        // A device reads one library, and the Mac's fake-sync harness reads a
        // handful. Four is generous and the reset is cheap.
        if cached.count >= 4 { cached.removeAll() }
        cached[url.path] = (stamp, value)
        return value
    }
}
