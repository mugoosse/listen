import Foundation
import ListenKit

/// Append-only JSONL log of what touched the library, for the person who has
/// to answer that question later.
///
/// The library's other readers leave no trace: an MCP client can walk every
/// transcript and nothing anywhere says it happened. For a personal library
/// that is fine; for a library that holds other people's meetings it is the
/// difference between "nobody looked" and "nobody can say". This file is the
/// modest version of an audit trail: events and ids, never names, questions
/// or transcript text, so the log is safe to read aloud and useless to an
/// attacker who only wants the content.
///
/// JSONL beside `dictations.jsonl`, greppable and app-independent, and in
/// `DevicePolicy.neverSynced` deliberately: a log another device can rewrite
/// is not an audit log. It rides the daily backup clone, and the sidecar
/// tarball picks it up so the durable copy holds it.
///
/// Not a SIEM. No signing, no tamper chain, one rotation at 5 MB. Anything
/// more belongs to the machine's owner, not to this app.
enum ActivityLog {
    static var file: URL { Library.root.appendingPathComponent("activity.jsonl") }
    private static let cap = 5 * 1024 * 1024

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func append(_ event: String, _ fields: [String: Any] = [:]) {
        try? Library.prepare()
        rotateIfNeeded()
        var obj: [String: Any] = ["at": iso.string(from: Date()), "event": event]
        for (key, value) in fields { obj[key] = value }
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.withoutEscapingSlashes, .sortedKeys]) else { return }
        var line = data
        line.append(0x0a)

        // O_APPEND, not open-and-seek: the app and a spawned `listen mcp` are
        // two processes writing one file, and only the kernel can make two
        // appends land whole. That holds for a single write well under the
        // pipe buffer, which is why an entry is always one line and carries
        // ids rather than content.
        let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try? handle.write(contentsOf: line)
    }

    /// One older generation, so the cap bounds the disk and a reader still
    /// has yesterday. Rotation happens on the writing side because there is
    /// no daemon to do it anywhere else.
    private static func rotateIfNeeded() {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: file.path))?[.size] as? Int,
              size > cap else { return }
        let older = Library.root.appendingPathComponent("activity.1.jsonl")
        try? manager.removeItem(at: older)
        try? manager.moveItem(at: file, to: older)
    }

    /// Most recent entries, oldest first, as raw dictionaries for the CLI.
    static func recent(_ n: Int) -> [[String: Any]] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(n).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    /// The recording ids named by a tool call's arguments, and nothing else
    /// out of them. Filtered through `isValidID` so a hostile argument cannot
    /// write arbitrary strings into the log.
    static func recordingIDs(in args: [String: Any]) -> [String] {
        var ids: [String] = []
        if let one = args["recording_id"] as? String { ids.append(one) }
        if let one = args["recording"] as? String { ids.append(one) }
        if let many = args["recordings"] as? [Any] {
            ids.append(contentsOf: many.compactMap { $0 as? String })
        }
        return ids.filter(ListenKit.Metadata.isValidID)
    }
}
