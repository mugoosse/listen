import Foundation
import Darwin

/// Only explicit owner projections travel through the existing sealed blob
/// transport. A phone never publishes a stale generated snapshot over a Mac.
public enum ContextSync {
    public static let editsFilename = "people-context-edits.json"
    public static func edits(root: URL) throws -> [String: ContextOverride] {
        let url = root.appendingPathComponent(editsFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard data.count <= 8_000_000 else { throw ContextDatabase.Failure(message: "The memory corrections file exceeds its size limit.") }
        let values = try JSONDecoder().decode([String: ContextOverride].self, from: data)
        try validate(values); return values
    }
    public static func validate(_ values: [String: ContextOverride]) throws {
        guard values.allSatisfy({ key, value in
            key == value.id && !key.isEmpty && key.count <= 256 && (value.replacement?.count ?? 0) <= 500
                && (value.updated.isEmpty || ContextOverride.timestamp(value.updated) > -Double.greatestFiniteMagnitude)
                && value.updated.count <= 40 && (value.fieldUpdated ?? [:]).allSatisfy {
                    ["hidden", "replacement", "pinned"].contains($0.key) && $0.value.count <= 40
                        && ($0.value.isEmpty || ContextOverride.timestamp($0.value) > -Double.greatestFiniteMagnitude)
                }
        }) else { throw ContextDatabase.Failure(message: "The memory corrections contain an invalid entry.") }
    }
    public static func merge(_ local: [String: ContextOverride], _ remote: [String: ContextOverride]) -> [String: ContextOverride] {
        local.merging(remote) { a, b in
            var result = a
            result.fieldUpdated = [:]
            for field in ["hidden", "replacement", "pinned"] {
                let left = a.fieldUpdated?[field] ?? a.updated, right = b.fieldUpdated?[field] ?? b.updated
                func value(_ item: ContextOverride) -> String {
                    switch field {
                    case "hidden": return String(item.hidden)
                    case "pinned": return String(item.pinned)
                    default: return item.replacement.map { "1" + $0 } ?? "0"
                    }
                }
                let leftTime = ContextOverride.timestamp(left), rightTime = ContextOverride.timestamp(right)
                let chosen = rightTime > leftTime || (rightTime == leftTime && value(b) > value(a)) ? b : a
                switch field {
                case "hidden": result.hidden = chosen.hidden
                case "pinned": result.pinned = chosen.pinned
                default: result.replacement = chosen.replacement
                }
                result.fieldUpdated?[field] = ContextOverride.newer(left, right)
            }
            result.updated = ContextOverride.newer(a.updated, b.updated)
            return result
        }
    }
    public static func write(_ values: [String: ContextOverride], root: URL) throws {
        try validate(values)
        let lock = root.appendingPathComponent(".people-context-edits.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ContextDatabase.Failure(message: "Cannot lock memory corrections.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ContextDatabase.Failure(message: "Cannot lock memory corrections.") }
        let values = merge(try edits(root: root), values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(values), url = root.appendingPathComponent(editsFilename)
        guard data.count <= 8_000_000 else { throw ContextDatabase.Failure(message: "The memory corrections file exceeds its size limit.") }
        if (try? Data(contentsOf: url)) == data { return }
        try data.write(to: url, options: .atomic)
    }
    public static func edit(_ value: ContextOverride, root: URL) throws {
        try write([value.id: value], root: root)
    }
    public static func readCard(name: String, kind: String, root: URL) throws -> ContextCard? {
        guard var snapshot = try ContextSnapshot.load(root: root) else { return nil }
        snapshot.overrides = merge(snapshot.overrides, try edits(root: root))
        return snapshot.card(named: name, kind: kind, root: root)
    }
    public static func readCards(root: URL) throws -> [ContextCard] {
        guard var snapshot = try ContextSnapshot.load(root: root) else { return [] }
        snapshot.overrides = merge(snapshot.overrides, try edits(root: root))
        return snapshot.cards.map { snapshot.verified($0, root: root) }.filter { !$0.entries.isEmpty }
    }
    public static func receive(_ contents: Data, root: URL) throws -> Data {
        guard contents.count <= 8_000_000 else { throw ContextDatabase.Failure(message: "The incoming memory corrections exceed the size limit.") }
        let remote = try JSONDecoder().decode([String: ContextOverride].self, from: contents)
        try validate(remote)
        let merged = merge(try edits(root: root), remote)
        try write(merged, root: root)
        return try Data(contentsOf: root.appendingPathComponent(editsFilename))
    }
}
