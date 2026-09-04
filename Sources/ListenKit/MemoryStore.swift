import Foundation

/// A container in a dictionary, which is how every seam in the sync gets
/// proved without a network.
///
/// `roundtrip.sh` described itself as the whole sync architecture on one
/// machine in about a minute, and it did that by running the real engine
/// through a loopback server. **CloudKit has no loopback.** There is no local
/// container and no second path to keep the test alive on, so the replacement
/// is a fake store rather than an integration test.
///
/// That is better than what it replaces rather than a concession, and the
/// reason is that `roundtrip.sh` was never testing TCP. It was testing our sync
/// logic through a real transport, and the logic is the part worth protecting.
/// With this, the whole core runs against two scratch libraries with no
/// network, no container, no second process and no socket, which makes it
/// faster than the thing it replaces rather than slower.
///
/// What it cannot prove is that CloudKit behaves as documented. That is a
/// separate, slower pass against the Development container, run before releases
/// rather than on every change. Two layers, and the fast one is hermetic.
public actor MemoryStore: RecordStore {
    /// Per zone, so a device can subscribe to some and not others exactly as it
    /// does for real.
    private var zones: [CloudNaming.Zone: [String: StoredRecord]] = [:]
    /// A monotonic counter per zone, standing in for a change tag. Every write
    /// anywhere bumps it, and a record's tag is the value at the time it was
    /// written, which gives the same compare-and-swap semantics CloudKit's
    /// `recordChangeTag` does.
    private var clock = 0
    /// What changed at which tick, so `changes(since:)` can answer.
    private var history: [CloudNaming.Zone: [(tick: Int, name: String, deleted: Bool)]] = [:]

    /// Set to make the next `changes` call report that it could not resume.
    /// The token-expiry case is impossible to provoke against a real container
    /// on demand, and it is the one that resurrects deleted meetings, so the
    /// fake has to be able to stage it.
    public var expireNextToken = false

    /// Persisted, so a shell harness can drive two libraries in separate
    /// processes and still share one container.
    private let file: URL?

    public init(file: URL? = nil) {
        self.file = file
        // Parsed here rather than by calling a method, because an actor's
        // initialiser is not isolated and cannot call one that is. Swift 5
        // let this through and Swift 6 does not, and the iPhone app compiles
        // these files in Swift 6 mode while the Mac does not, so it is the
        // stricter of the two consumers that decides what is allowed here.
        guard let file, let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(OnDisk.self, from: data) else { return }
        clock = snapshot.clock
        for row in snapshot.rows {
            guard let zone = CloudNaming.Zone(rawValue: row.zone),
                  let type = CloudNaming.RecordType(rawValue: row.type) else { continue }
            zones[zone, default: [:]][row.name] = StoredRecord(
                name: row.name, type: type, payload: row.payload, assets: row.assets,
                claimedBy: row.claimedBy, claimExpires: row.claimExpires,
                audioOn: row.audioOn, changeTag: row.changeTag, zone: zone)
        }
        for event in snapshot.events {
            guard let zone = CloudNaming.Zone(rawValue: event.zone) else { continue }
            history[zone, default: []].append((event.tick, event.name, event.deleted))
        }
    }

    public func setExpireNextToken(_ value: Bool) { expireNextToken = value }

    /// Set to make the next store call answer the way CloudKit does mid
    /// throttle: refused, with a sub-second wait attached. Cleared by that
    /// call, because that is the shape of the real thing; the request after
    /// the pause sails.
    public var busyNextCall = false

    public func setBusyNextCall(_ value: Bool) { busyNextCall = value }

    /// Set to make the next `save` fail outright, the way a container does
    /// when the account is the problem rather than the pacing. A throttle is
    /// `busyNextCall` and stays quiet by design; this is the loud kind, and it
    /// exists so the suite can prove the loud kind reaches a screen with a
    /// sentence attached. Cleared by that save, so the retry after it works.
    public var failNextSave = false

    public func setFailNextSave(_ value: Bool) { failNextSave = value }

    private func refuseIfThrottled() throws {
        guard busyNextCall else { return }
        busyNextCall = false
        throw StoreError.busy(0.6)
    }

    /// How many times the container was asked or written, so the suite can
    /// prove a path stayed off the network rather than merely succeeded.
    public private(set) var fetchCount = 0
    public private(set) var saveCount = 0

    /// And how much crossed, so a claim about cost can be a number rather than
    /// a code path. A listing that leaves the asset bodies behind and one that
    /// brings them are the same sequence of calls and differ by 86 MB, which is
    /// invisible to a counter that only counts calls.
    public private(set) var bytesFetched = 0
    public private(set) var bytesSaved = 0

    private static func weight(_ record: StoredRecord) -> Int {
        record.payload.count + record.assets.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - RecordStore

    public func save(_ record: StoredRecord) async throws -> StoredRecord {
        try refuseIfThrottled()
        if failNextSave {
            failNextSave = false
            throw StoreError.unavailable("the fake container refused this save")
        }
        saveCount += 1
        bytesSaved += MemoryStore.weight(record)
        // The record's own zone, not its type's. One type lives in two zones:
        // see `StoredRecord.zone`.
        let zone = record.zone
        let existing = zones[zone]?[record.name]

        // The compare-and-swap, and the whole reason a lost update is not
        // possible. A nil tag on a record that exists is a caller who thinks it
        // is creating something; a stale tag is a caller who read it before
        // somebody else wrote it. Both get the winner's copy back rather than
        // a boolean, because a conflict the caller cannot see is a conflict
        // resolved by coin toss.
        if let existing, existing.changeTag != record.changeTag {
            throw StoreError.changedOnServer(existing)
        }
        if existing == nil, record.changeTag != nil {
            throw StoreError.changedOnServer(
                StoredRecord(name: record.name, type: record.type, payload: Data()))
        }

        clock += 1
        var saved = record
        // A record read without its asset bodies must not be able to delete
        // them by being written back. See `StoredRecord.partial`: this is the
        // line that makes the fake agree with CloudKit, which re-reads before
        // it modifies and so never had the chance to get this wrong.
        if record.partial, let existing {
            saved.assets = existing.assets.merging(record.assets) { _, new in new }
        }
        saved.partial = false
        saved.changeTag = "t\(clock)"
        zones[zone, default: [:]][record.name] = saved
        history[zone, default: []].append((clock, record.name, false))
        persist()
        return saved
    }

    public func delete(_ name: String, in zone: CloudNaming.Zone) async throws {
        try refuseIfThrottled()
        clock += 1
        zones[zone]?[name] = nil
        history[zone, default: []].append((clock, name, true))
        persist()
    }

    public func changes(in zone: CloudNaming.Zone,
                        since token: String?) async throws -> StoreChanges {
        try await changes(in: zone, since: token, withAssets: true)
    }

    /// Stripping rather than never loading, because a dictionary has no
    /// transport to save. What the fake has to reproduce is not the saving:
    /// it is what the *caller* then does with a record whose assets are
    /// absent, which is the half of the two-phase pull that can be wrong.
    public func changes(in zone: CloudNaming.Zone, since token: String?,
                        withAssets: Bool) async throws -> StoreChanges {
        try refuseIfThrottled()
        var result = try await fullChanges(in: zone, since: token)
        if !withAssets {
            result.changed = result.changed.map { record in
                var stripped = record
                stripped.assets = [:]
                stripped.partial = true
                return stripped
            }
        }
        bytesFetched += result.changed.reduce(0) { $0 + MemoryStore.weight($1) }
        return result
    }

    private func fullChanges(in zone: CloudNaming.Zone,
                             since token: String?) async throws -> StoreChanges {
        if expireNextToken {
            expireNextToken = false
            // Everything, and no deletions, which is exactly what a real
            // container does when it cannot resume: the records that still
            // exist, with no way to learn about the ones that do not.
            return StoreChanges(changed: Array(zones[zone]?.values ?? [:].values),
                                deleted: [], token: "t\(clock)",
                                refetchedEverything: true)
        }
        let since = Int(token?.dropFirst() ?? "0") ?? 0
        var changed: [StoredRecord] = []
        var deleted: [String] = []
        var seen = Set<String>()
        // Newest first, so a record written twice since the token is reported
        // once, in its latest state.
        for entry in (history[zone] ?? []).reversed() where entry.tick > since {
            guard seen.insert(entry.name).inserted else { continue }
            if entry.deleted { deleted.append(entry.name) }
            else if let record = zones[zone]?[entry.name] { changed.append(record) }
        }
        return StoreChanges(changed: changed.reversed(), deleted: deleted.reversed(),
                            token: "t\(clock)")
    }

    public func fetch(_ name: String, in zone: CloudNaming.Zone) async throws -> StoredRecord? {
        try refuseIfThrottled()
        fetchCount += 1
        let found = zones[zone]?[name]
        bytesFetched += found.map(MemoryStore.weight) ?? 0
        return found
    }

    // MARK: - Persistence

    private struct OnDisk: Codable {
        struct Row: Codable {
            var name: String, type: String, payload: Data
            var assets: [String: Data]
            var claimedBy: String?, audioOn: String?, changeTag: String?
            var claimExpires: Date?
            var zone: String
        }
        struct Event: Codable { var tick: Int, name: String, deleted: Bool, zone: String }
        var clock: Int
        var rows: [Row]
        var events: [Event]
    }

    private func persist() {
        guard let file else { return }
        var rows: [OnDisk.Row] = []
        for (zone, records) in zones {
            for record in records.values {
                rows.append(OnDisk.Row(
                    name: record.name, type: record.type.rawValue, payload: record.payload,
                    assets: record.assets, claimedBy: record.claimedBy,
                    audioOn: record.audioOn, changeTag: record.changeTag,
                    claimExpires: record.claimExpires, zone: zone.rawValue))
            }
        }
        var events: [OnDisk.Event] = []
        for (zone, entries) in history {
            for e in entries {
                events.append(OnDisk.Event(tick: e.tick, name: e.name,
                                           deleted: e.deleted, zone: zone.rawValue))
            }
        }
        let snapshot = OnDisk(clock: clock, rows: rows, events: events.sorted { $0.tick < $1.tick })
        try? JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
    }

}
