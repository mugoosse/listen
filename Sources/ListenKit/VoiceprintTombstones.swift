import Foundation

/// The people whose voiceprints this library has been told to forget.
///
/// Forgetting is the one voiceprint operation a rewrite cannot carry on its
/// own. Every sync pass pulls before it pushes, so the Mac that just stripped
/// a name would pull the fat cloud copy straight back over its own rewrite,
/// and a second Mac whose file still holds the name would push it straight
/// back up. Both races were reasoned through rather than observed, and either
/// one is enough: a forget that can be undone by the next pass is not a
/// forget.
///
/// So the forget itself is data. Each entry is a name and when it was
/// spoken, replicated through the voiceprint zone as its own record, merged
/// per name by latest stamp, and applied to every bank on both the pull and
/// the push side. An `unforget` entry (`removed: true`) wins the same way,
/// so re-teaching a name is not silently stripped by its own old tombstone.
///
/// Entries expire after 90 days. The tombstone exists only to outlive the
/// propagation race; once every Mac has rewritten its files it is dead
/// weight, and a list that only grows would name for ever the people the
/// user asked to be forgotten, which is the opposite of the request. The
/// trade-off is real and accepted: a Mac shut for longer than 90 days can
/// resurrect a print, and a second forget removes it again.
///
/// The local file never syncs as a file (see `DevicePolicy.neverSynced`):
/// two devices' lists have to meet through `merged`, and a byte-level file
/// sync would make the newer file win whole, dropping the other device's
/// entries.
public struct VoiceprintTombstones: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        /// `Metadata.stamp` format, UTC. Fixed-width, so string order is time
        /// order and no parse is needed to pick a winner.
        public var at: String
        /// True on an unforget. Optional so files written before the field
        /// existed still decode.
        public var removed: Bool?

        public init(name: String, at: String, removed: Bool? = nil) {
            self.name = name; self.at = at; self.removed = removed
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    /// The r6 natural key. Opaque after HMAC, like every record name.
    public static let cloudKey = "forgotten-people"

    public static let lifetime: TimeInterval = 90 * 86_400

    static func url(in library: Library) -> URL {
        library.root.appendingPathComponent(".forgotten-voices.json")
    }

    public static func load(_ library: Library) -> VoiceprintTombstones {
        guard let data = try? Data(contentsOf: url(in: library)),
              let list = try? JSONDecoder().decode(VoiceprintTombstones.self, from: data)
        else { return VoiceprintTombstones() }
        return list
    }

    public func save(_ library: Library) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: VoiceprintTombstones.url(in: library),
                                    options: .atomic)
    }

    public mutating func forget(_ name: String, now: Date = Date()) {
        entries.removeAll { $0.name == name }
        entries.append(Entry(name: name, at: Metadata.stamp(now)))
    }

    public mutating func unforget(_ name: String, now: Date = Date()) {
        entries.removeAll { $0.name == name }
        entries.append(Entry(name: name, at: Metadata.stamp(now), removed: true))
    }

    /// The names a bank must not hold right now.
    public func activeNames(now: Date = Date()) -> Set<String> {
        let floor = Metadata.stamp(now.addingTimeInterval(-Self.lifetime))
        return Set(entries.filter { $0.removed != true && $0.at > floor }
                          .map(\.name))
    }

    /// Union by name, latest stamp wins, expired entries dropped.
    ///
    /// Dropping the expired on merge rather than on load is what keeps two
    /// long-lived devices from re-gifting each other entries neither applies
    /// any more.
    public static func merged(_ a: Self, _ b: Self,
                              now: Date = Date()) -> VoiceprintTombstones {
        let floor = Metadata.stamp(now.addingTimeInterval(-lifetime))
        var byName: [String: Entry] = [:]
        for entry in a.entries + b.entries where entry.at > floor {
            if let held = byName[entry.name] {
                if held.at > entry.at { continue }
                // Stamps have one-second resolution, so a forget and its
                // undo can tie. The unforget wins the tie: keeping biometric
                // data the user re-taught is recoverable, stripping it is not.
                if held.at == entry.at,
                   held.removed == true || entry.removed != true { continue }
            }
            byName[entry.name] = entry
        }
        return VoiceprintTombstones(entries: byName.values
            .sorted { $0.name < $1.name })
    }

    /// Remove the named people from a bank's bytes.
    ///
    /// JSON-level rather than through the app's voiceprint model, because
    /// this file is ListenKit and the model is the app's; the bank is a
    /// top-level dictionary keyed by name and that shape is the whole
    /// contract. Returns nil when nothing changed, and nil when the data does
    /// not parse: what cannot be read must never be rewritten or deleted.
    public static func strip(_ names: Set<String>, fromBank data: Data)
        -> (data: Data, empty: Bool)? {
        guard !names.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var bank = parsed as? [String: Any] else { return nil }
        let held = Set(bank.keys)
        let doomed = held.intersection(names)
        guard !doomed.isEmpty else { return nil }
        for name in doomed { bank[name] = nil }
        guard let out = try? JSONSerialization.data(withJSONObject: bank,
                                                    options: [.sortedKeys])
        else { return nil }
        return (out, bank.isEmpty)
    }

    /// Rewrite every bank in the library. A bank that empties is deleted,
    /// because a file holding `{}` would still be pushed as an r6 record and
    /// the point of emptying is that the record goes.
    public static func apply(_ names: Set<String>, to library: Library)
        -> (changed: [String], emptied: [String]) {
        guard !names.isEmpty else { return ([], []) }
        var changed: [String] = [], emptied: [String] = []
        let manager = FileManager.default
        for recording in library.all() {
            for file in DevicePolicy.voiceprintFiles {
                let url = recording.folder.appendingPathComponent(file)
                guard let data = try? Data(contentsOf: url),
                      let stripped = strip(names, fromBank: data) else { continue }
                if stripped.empty {
                    try? manager.removeItem(at: url)
                    emptied.append(recording.id)
                } else {
                    try? stripped.data.write(to: url, options: .atomic)
                    changed.append(recording.id)
                }
            }
        }
        return (changed, emptied)
    }
}
