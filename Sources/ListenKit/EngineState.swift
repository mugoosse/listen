import Foundation
import CryptoKit

/// Everything this one device remembers about syncing, kept **outside the
/// library**.
///
/// That placement is the whole point of the type and it is not a tidiness
/// preference. `CKSyncEngine` persists change tokens and a pending-change
/// queue, which are per-device by definition. The library is the thing being
/// replicated. Put per-device state inside it and every device shares one
/// device's tokens, which during the phases where a diff between two copies is
/// the only oracle would look exactly like sync working, right up until it did
/// not.
///
/// The library already has scars from this: `staging/` is documented as fatal
/// to replicate for the same structural reason, and `.pairing-key`,
/// `devices.json` and `.sync-state.json` all sit at the library root today,
/// where the first of them was quietly replicating between two Macs.
///
/// Keyed by library root, so a `LISTEN_LIBRARY` scratch run gets its own state
/// and cannot collide with the real one or with another scratch run. **Device
/// identity lives here too**, and matters as much as the tokens: if a Mac's
/// device id lived in the library, both Macs would claim one row in the devices
/// zone and the settings pane would show two machines as one.
public struct EngineState: Sendable {
    public let root: URL

    /// `~/Library/Application Support/Listen/Sync/<digest>/`, and on iOS the
    /// same path inside the app container.
    ///
    /// A digest of the library path rather than the path itself, because a
    /// library root can contain anything a directory name can and this has to
    /// be one path component.
    public init(library: Library) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let digest = SHA256.hash(data: Data(library.root.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        root = support
            .appendingPathComponent("Listen")
            .appendingPathComponent("Sync")
            .appendingPathComponent(String(digest.prefix(16)))
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private var engineFile: URL { root.appendingPathComponent("engine-state.dat") }
    private var identityFile: URL { root.appendingPathComponent("device.json") }
    private var seenFile: URL { root.appendingPathComponent("ids-seen.json") }
    private var baseFile: URL { root.appendingPathComponent("base.json") }

    // MARK: - Engine serialization

    /// `CKSyncEngine.State.Serialization`, opaque to us and handed back
    /// unchanged. Nil the first time, which is how the engine knows to fetch
    /// everything.
    public var engineData: Data? {
        get { try? Data(contentsOf: engineFile) }
        nonmutating set {
            guard let newValue else { try? FileManager.default.removeItem(at: engineFile); return }
            try? newValue.write(to: engineFile, options: .atomic)
        }
    }

    // MARK: - Who this device is

    public struct Identity: Codable, Sendable {
        public var id: String
        public var name: String
        public var kind: String
    }

    /// Stable for the life of this install against this library. Generated
    /// once and kept: a value that changed per launch would fill the devices
    /// list with ghosts of the same machine.
    public func identity(name: @autoclosure () -> String,
                         kind: @autoclosure () -> String) -> Identity {
        if let data = try? Data(contentsOf: identityFile),
           let existing = try? JSONDecoder().decode(Identity.self, from: data) {
            return existing
        }
        let fresh = Identity(id: UUID().uuidString, name: name(), kind: kind())
        if let data = try? JSONEncoder().encode(fresh) {
            try? data.write(to: identityFile, options: .atomic)
        }
        return fresh
    }

    // MARK: - Ids ever seen

    /// Every record name this device has ever held, so a full refetch does not
    /// resurrect deleted meetings.
    ///
    /// When a change token expires, `CKSyncEngine` refetches everything, and at
    /// that moment a device cannot tell "deleted while I was away" from "never
    /// had it". This is the difference. It is a set of opaque record names
    /// rather than ids, so it says nothing on its own either.
    public var everSeen: Set<String> {
        get {
            guard let data = try? Data(contentsOf: seenFile),
                  let list = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(list)
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue.sorted()) else { return }
            try? data.write(to: seenFile, options: .atomic)
        }
    }

    // MARK: - Merge base

    /// What this device believed the other side had, at the end of the last
    /// sync. `SyncState` under a different roof: the map is identical, the
    /// three-way decision in `decideNote` is unchanged, and only the location
    /// moves, out of the library and into here.
    public var base: SyncState {
        get {
            guard let data = try? Data(contentsOf: baseFile),
                  let state = try? JSONDecoder().decode(SyncState.self, from: data)
            else { return SyncState() }
            return state
        }
        nonmutating set {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(newValue).write(to: baseFile, options: .atomic)
        }
    }

    /// Take over a `.sync-state.json` left at the library root by the LAN
    /// transport, once, so the first CloudKit sync does not report a conflict
    /// on every note this device has ever edited.
    @discardableResult
    public func adoptLegacyBase(from library: Library) -> Bool {
        let legacy = library.root.appendingPathComponent(".sync-state.json")
        guard FileManager.default.fileExists(atPath: legacy.path),
              !FileManager.default.fileExists(atPath: baseFile.path),
              let data = try? Data(contentsOf: legacy),
              let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return false }
        base = state
        return true
    }
}
