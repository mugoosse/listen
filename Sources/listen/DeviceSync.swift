import Foundation

/// Listen's read-only view of what `listen-sync` keeps.
///
/// Two files beside the library, and nothing else passes between the two
/// programs. No socket, no XPC, no shared framework: the agent is a separate
/// binary in a separate repository under a different licence, and a pair of
/// JSON files is the whole interface.
///
/// Read-only with two exceptions, both of which are a person deciding
/// something: removing a device, and starting again with a new key. Those write
/// the same files, and the agent picks them up on its next request because it
/// re-reads the registry every time rather than caching it.
enum DeviceSync {
    struct Device: Codable {
        var id: String
        var name: String
        var firstSeen: String
        var lastSeen: String
        var revoked: Bool = false

        var lastSeenPhrase: String {
            guard let then = DeviceSync.parser.date(from: lastSeen) else { return lastSeen }
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

    private struct Registry: Codable { var devices: [Device] = [] }

    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static var keyURL: URL { Library.root.appendingPathComponent(".pairing-key") }
    static var registryURL: URL { Library.root.appendingPathComponent("devices.json") }

    /// The pairing code, or nil when the agent has never run.
    static func pairingCode() -> String? {
        guard let text = try? String(contentsOf: keyURL, encoding: .utf8) else { return nil }
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    /// `listen://pair?k=…&h=…&p=…`, the same shape `listen-sync pair` prints.
    static func pairingURL(code: String, port: Int = 8787) -> String {
        var c = URLComponents()
        c.scheme = "listen"
        c.host = "pair"
        c.queryItems = [
            .init(name: "k", value: code),
            .init(name: "h", value: localAddress()),
            .init(name: "p", value: String(port)),
        ]
        return c.url?.absoluteString ?? ""
    }

    /// This Mac on the local network. Prefers `en`, because a Mac on ethernet
    /// with wifi also up would otherwise advertise an address the phone cannot
    /// reach.
    static func localAddress() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return "127.0.0.1" }
        defer { freeifaddrs(head) }
        var best: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let p = pointer {
            defer { pointer = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = p.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if String(cString: p.pointee.ifa_name).hasPrefix("en") { return ip }
            if best == nil { best = ip }
        }
        return best ?? "127.0.0.1"
    }

    static func devices() -> [Device] {
        guard let data = try? Data(contentsOf: registryURL),
              let registry = try? JSONDecoder().decode(Registry.self, from: data)
        else { return [] }
        return registry.devices.sorted { $0.lastSeen > $1.lastSeen }
    }

    private static func write(_ registry: Registry) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(registry).write(to: registryURL, options: .atomic)
    }

    static func revoke(_ id: String) {
        var registry = Registry(devices: devices())
        if let i = registry.devices.firstIndex(where: { $0.id == id }) {
            registry.devices[i].revoked = true
        }
        write(registry)
    }

    static func forget(_ id: String) {
        var registry = Registry(devices: devices())
        registry.devices.removeAll { $0.id == id }
        write(registry)
    }

    /// A new key, and every paired phone stops being able to read anything.
    ///
    /// The registry is cleared with it: a device list that survived a key
    /// change would be a list of phones that cannot connect, which is worse
    /// than an empty one because it looks like they still can.
    static func rotate() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, acc = 0, out = ""
        for b in bytes {
            acc = acc << 8 | Int(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(acc >> bits) & 31]) }
        }
        if bits > 0 { out.append(alphabet[(acc << (5 - bits)) & 31]) }
        let code = stride(from: 0, to: out.count, by: 4).map {
            String(Array(out)[$0..<min($0 + 4, out.count)])
        }.joined(separator: "-")

        try? code.write(to: keyURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: keyURL.path)
        write(Registry())
    }
}
