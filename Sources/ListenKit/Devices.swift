import Foundation

/// A phone that has been paired, and when it was last heard from.
///
/// One shared key was enough to make sync work and is not enough to run it. A
/// key alone cannot answer "what is connected to my Mac", cannot be taken away
/// from a phone that was lost, and gives the Mac nothing to show. So every
/// request carries who is asking, and the Mac keeps a list.
public struct Device: Codable, Sendable, Identifiable, Equatable {
    public var id: String            // stable, generated once on the device
    public var name: String          // "iPhone, iOS 26.1"
    public var firstSeen: String
    public var lastSeen: String
    public var revoked: Bool = false

    public init(id: String, name: String, firstSeen: String, lastSeen: String,
                revoked: Bool = false) {
        self.id = id; self.name = name
        self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.revoked = revoked
    }

    /// "just now", "12 minutes ago", or a date. What a person wants from a
    /// last-seen column, rather than a timestamp they have to subtract.
    public var lastSeenPhrase: String {
        guard let then = Metadata.parser.date(from: lastSeen) else { return lastSeen }
        let seconds = Date().timeIntervalSince(then)
        switch seconds {
        case ..<90: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) minutes ago"
        case ..<86_400: return "\(Int(seconds / 3600)) hours ago"
        default:
            let f = DateFormatter()
            f.dateStyle = .medium; f.timeStyle = .short
            return f.string(from: then)
        }
    }
}

/// The list, on disk beside the library.
///
/// A plain JSON file rather than anything cleverer, for the same reason the
/// library is folders: two processes read it, `listen-sync` and Listen itself,
/// and a file both can open needs no protocol between them.
public struct DeviceRegistry: Codable, Sendable {
    public var devices: [Device] = []

    public init() {}

    public static func url(in library: Library) -> URL {
        library.root.appendingPathComponent("devices.json")
    }

    public static func load(_ library: Library) -> DeviceRegistry {
        guard let data = try? Data(contentsOf: url(in: library)),
              let registry = try? JSONDecoder().decode(DeviceRegistry.self, from: data)
        else { return DeviceRegistry() }
        return registry
    }

    public func save(_ library: Library) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: DeviceRegistry.url(in: library), options: .atomic)
    }

    public func isRevoked(_ id: String) -> Bool {
        devices.first { $0.id == id }?.revoked ?? false
    }

    /// Record that a device just spoke. Returns true if anything changed, so
    /// the caller can avoid rewriting the file on every single request.
    @discardableResult
    public mutating func seen(id: String, name: String) -> Bool {
        let now = Metadata.stamp(Date())
        if let i = devices.firstIndex(where: { $0.id == id }) {
            // A minute's resolution. Every request would otherwise rewrite the
            // file, and an upload is one request per 4 MB chunk.
            let previous = Metadata.parser.date(from: devices[i].lastSeen) ?? .distantPast
            if !name.isEmpty { devices[i].name = name }
            devices[i].lastSeen = now
            return Date().timeIntervalSince(previous) > 60
        }
        devices.append(Device(id: id, name: name.isEmpty ? "A device" : name,
                              firstSeen: now, lastSeen: now))
        return true
    }

    public mutating func revoke(_ id: String) {
        if let i = devices.firstIndex(where: { $0.id == id }) { devices[i].revoked = true }
    }

    public mutating func forget(_ id: String) {
        devices.removeAll { $0.id == id }
    }
}
