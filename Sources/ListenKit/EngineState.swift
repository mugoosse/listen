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

    /// `~/Library/Application Support/ListenSync/<digest>/`, and on iOS the
    /// same path inside the app container. **Beside the library, not in it.**
    ///
    /// A digest of the library path rather than the path itself, because a
    /// library root can contain anything a directory name can and this has to
    /// be one path component.
    public init(library: Library) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        let digest = SHA256.hash(data: Data(library.root.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        // **A sibling of the library, never a child of it.** This started as
        // `Listen/Sync/…`, which put change tokens, device identity and the
        // ids-ever-seen set *inside* the very tree being replicated. Found by
        // cloning the real library and diffing it against one hydrated from
        // the container: `Sync` showed up as a directory that existed on one
        // side and not the other, which is what this whole type exists to
        // prevent and is the failure that hides itself, because two devices
        // sharing one device's change tokens looks exactly like sync working.
        root = support
            .appendingPathComponent("ListenSync")
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
                         kind: @autoclosure () -> String,
                         stableID: (() -> String)? = nil) -> Identity {
        if let data = try? Data(contentsOf: identityFile),
           let existing = try? JSONDecoder().decode(Identity.self, from: data) {
            return existing
        }
        // `stableID` is how a device that cannot rely on this file surviving
        // says so. On iOS the state directory is keyed on the library path, and
        // the library lives inside the app container, whose name changes when
        // the app is reinstalled: every install therefore arrived in the
        // devices list as a new phone. Three rows called "iPhone" for one
        // phone, and nothing ever removed the dead ones.
        let fresh = Identity(id: stableID?() ?? UUID().uuidString,
                             name: name(), kind: kind())
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

    /// Recheck recording records once after the pull-stamp repair.
    ///
    /// Older builds stamped the whole local folder after a pull, even though a
    /// pull writes only the files present in the remote manifest. If the Mac
    /// had just written a transcript, that richer local stamp was recorded as
    /// already sent and no later pass repaired the sparse cloud record. Drop
    /// only recording stamps so the next push fetches and compares them again.
    /// Audio-transfer stamps are separate and must survive, or a phone uploads
    /// every WAV it still holds a second time.
    public func repairSuppressedRecordingPushesOnce() {
        // V2 also repairs records a stale phone reduced after the first pull
        // repair had already run.
        let marker = "migration:recording-recheck-v2"
        var snapshot = base
        guard snapshot.base[marker] == nil else { return }
        for key in Array(snapshot.base.keys) where key.hasPrefix("sent:") {
            let id = String(key.dropFirst("sent:".count))
            if Metadata.isValidID(id) { snapshot.base[key] = nil }
        }
        snapshot.base[marker] = "1"
        base = snapshot
    }

    /// Take over a `.sync-state.json` left at the library root by the LAN
    /// transport, once, so the first CloudKit sync does not report a conflict
    /// on every note this device has ever edited. Remove it only after the
    /// external base exists, so a failed decode never destroys the recovery
    /// copy it would need.
    @discardableResult
    public func adoptLegacyBase(from library: Library) -> Bool {
        let legacy = library.root.appendingPathComponent(".sync-state.json")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return false }
        if !FileManager.default.fileExists(atPath: baseFile.path) {
            guard let data = try? Data(contentsOf: legacy),
                  let state = try? JSONDecoder().decode(SyncState.self, from: data)
            else { return false }
            base = state
        }
        guard FileManager.default.fileExists(atPath: baseFile.path) else { return false }
        try? FileManager.default.removeItem(at: legacy)
        return true
    }
}
