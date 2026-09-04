import Foundation
import CloudKit

/// The same four operations, against a real container.
///
/// Written **after** `MemoryStore` on purpose. A store written against
/// `CKRecord` first would have leaked it upward into the sync core and there
/// would have been nothing left to fake, which is how a sync layer ends up
/// testable only against a network.
///
/// Everything here is translation. The decisions all live in `CloudSyncCore`,
/// and this file's only job is to make CloudKit answer the four questions that
/// protocol asks, with the same meanings the fake gives them.
public actor CloudKitStore: RecordStore {
    private let database: CKDatabase
    private var preparedZones: Set<CloudNaming.Zone> = []

    /// The server's copy of each record we have seen, kept because CloudKit's
    /// compare-and-swap needs the record instance rather than a version string.
    ///
    /// This is `lastKnownRecord` from the design, and the reason a save can
    /// refuse rather than clobber: a `CKRecord` carries an opaque
    /// `recordChangeTag` that cannot be synthesised, so the only way to say "I
    /// am updating the copy I read" is to hold that copy and modify it.
    private var lastKnown: [String: CKRecord] = [:]

    public init(containerID: String) {
        database = CKContainer(identifier: containerID).privateCloudDatabase
    }

    // MARK: - Bounding a call

    /// How long one call may take before it is given up on.
    ///
    /// **Nothing here used to set either of these, and CloudKit's default for a
    /// resource is seven days.** One asset transfer that stopped moving held a
    /// pass open indefinitely, and because a pass is guarded by a single flag,
    /// every later pass was dropped: new recordings stopped appearing until the
    /// app was relaunched. That was the whole of "quit and reopen it and they
    /// show up".
    ///
    /// Two numbers because the work is two shapes. A scalar record is a sealed
    /// blob under CloudKit's 1 MB field ceiling and a minute is already
    /// generous. An asset is tens of megabytes over whatever connection a phone
    /// happens to be on: ten minutes is roughly 86 MB at 1.2 Mbit, which is a
    /// bad hotel and not a broken transfer. Both are ceilings on a stall rather
    /// than budgets for the work, so being wrong costs a retry on the next
    /// pass, never a lost recording.
    enum Bound {
        case scalar, asset

        var resource: TimeInterval {
            switch self {
            case .scalar: return 60
            case .asset: return 600
            }
        }
    }

    /// A fresh configuration per operation. `CKOperation.Configuration` is a
    /// class, so one shared instance mutated later would mutate every operation
    /// still holding it.
    private func configuration(_ bound: Bound,
                               longLived: Bool = false) -> CKOperation.Configuration {
        let made = CKOperation.Configuration()
        made.timeoutIntervalForRequest = 60
        // **No resource ceiling on a long-lived upload, deliberately.** The two
        // settings fight: a long-lived operation is handed to the daemon so it
        // can outlast the app, and a resource timeout tells that daemon to give
        // up partway. Since the point of this one is to finish an 86 MB
        // transfer across a screen lock and an app switch, the ceiling that
        // ends a stall everywhere else is the wrong instrument here. What
        // bounds it instead is `CloudSyncCore.inflightGrace`, after which the
        // phone asks the container what actually happened.
        made.timeoutIntervalForResource = longLived ? 24 * 60 * 60 : bound.resource
        made.isLongLived = longLived
        return made
    }

    /// Whether this save must survive the app going away.
    ///
    /// **Only the phone's audio transfer**, and not "any record with assets".
    /// A recording record carries `transcript.json`, which is 314 KB and wants
    /// the immediate error that drives a readable retry; a master is 25 MB on a
    /// Mac that is not being suspended. Making either long-lived would trade a
    /// sentence somebody can act on for a promise nobody is watching.
    ///
    /// A claim writes to the same record type and is excluded by the asset
    /// test: since `ingest` reads the pipe without asset bodies, a claim's
    /// record carries none.
    private static func isLongLived(_ record: StoredRecord) -> Bool {
        record.type == .audioTransfer && record.assets["mic.wav"] != nil
    }

    /// Where an asset waits while an upload that can outlive this process reads
    /// it. Beside the sync state rather than in the library, because it is
    /// bookkeeping about a transfer and not part of anybody's recordings.
    private func stagingRoot() -> URL {
        let root = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ListenSync/staging")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return root
    }

    /// Drop staged files old enough that no upload can still want them.
    ///
    /// A day, which is well past `CloudSyncCore.inflightGrace`: by then the
    /// phone has asked the container directly and either stamped the offer or
    /// started again. Without this the directory grows by one whole recording
    /// every time an upload is interrupted by the app being killed, which is
    /// the exact case it exists for.
    private func sweepStaging() {
        let root = stagingRoot()
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in entries {
            let when = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let when, when < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Holds an operation across the cancellation handler.
    ///
    /// `onCancel` is `@Sendable` and runs off the actor, and `CKOperation` is
    /// not `Sendable`, so the obvious `onCancel: { operation.cancel() }` does
    /// not compile in the iOS target, which builds this file in Swift 6 mode
    /// while the Mac does not. The box also closes the ordering race: a task
    /// cancelled before `database.add` runs would otherwise cancel nothing and
    /// leave the continuation waiting for a callback that never comes, which is
    /// the same wedge with a different cause.
    private final class OperationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var operation: CKOperation?
        private var cancelled = false

        /// True when the task was already cancelled, so the caller must not add.
        func hold(_ made: CKOperation) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            operation = made
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let held = operation
            operation = nil
            lock.unlock()
            held?.cancel()
        }
    }

    // MARK: - Zones

    /// Zones are created on first use rather than at launch, so an app that
    /// never syncs never writes anything to anybody's iCloud account.
    private func prepare(_ zone: CloudNaming.Zone) async throws {
        guard !preparedZones.contains(zone) else { return }
        let id = CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
        do {
            _ = try await pacing {
                // `configuredWith` because the convenience API takes no
                // operation to configure, and an unbounded call here is the
                // same wedge as an unbounded call anywhere else. Four paths in
                // this file are this shape; the one that mattered is `changes`.
                try await database.configuredWith(configuration: configuration(.scalar)) {
                    try await $0.modifyRecordZones(saving: [CKRecordZone(zoneID: id)],
                                                   deleting: [])
                }
            }
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Already there, which is the ordinary case on every launch but
            // the first.
        }
        preparedZones.insert(zone)
    }

    private func zoneID(_ zone: CloudNaming.Zone) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
    }

    // MARK: - Throttling

    /// How long the server asked us to wait, when what it sent was a request
    /// to slow down rather than a failure.
    ///
    /// A burst of requests gets one HTTP 429, and CloudKit then refuses the
    /// operations behind it on the spot with "Operation throttled by previous
    /// server http 429 reply. Retry after 0.6 seconds." The wait it wants is
    /// usually under a second, so surfacing this as an error means alarming
    /// somebody over a pause shorter than the alert takes to read; a phone
    /// did exactly that, verbatim, over a pull-to-refresh. The retry-after
    /// field is asked first because the codes vary by path, and a partial
    /// failure is opened to ask the same of the errors inside it.
    static func askedToWait(_ error: Error) -> TimeInterval? {
        let nsError = error as NSError
        guard nsError.domain == CKErrorDomain else { return nil }
        let error = CKError(_nsError: nsError)
        if let seconds = error.retryAfterSeconds { return seconds }
        switch error.code {
        case .requestRateLimited, .zoneBusy, .serviceUnavailable:
            return 1
        case .partialFailure:
            return error.partialErrorsByItemID?.values
                .compactMap { askedToWait($0) }.min()
        default:
            return nil
        }
    }

    /// Run one CloudKit call, absorbing a single throttle.
    ///
    /// The wait is the server's own number, capped at five seconds so a
    /// misreported header cannot park a pass. One retry on purpose: a second
    /// refusal becomes `StoreError.busy`, which the sync core records as
    /// "come back shortly" rather than as an error anybody has to read.
    private func pacing<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch {
            guard let wait = Self.askedToWait(error) else { throw error }
            try? await Task.sleep(
                nanoseconds: UInt64(min(max(wait, 0.1), 5) * 1_000_000_000))
            do {
                return try await body()
            } catch {
                guard let wait = Self.askedToWait(error) else { throw error }
                throw StoreError.busy(wait)
            }
        }
    }

    // MARK: - Subscriptions

    /// Ask to be told when a zone changes, rather than asking every two
    /// minutes whether it has.
    ///
    /// A silent push: no alert, no badge, no sound, and nothing a person ever
    /// sees. It carries no content of its own, only the fact that there is
    /// something to fetch, which is why it is safe to let Apple deliver it for
    /// a product whose whole claim is that Apple cannot read the contents.
    ///
    /// **Per zone, which is how a device subscribes to some and not others.**
    /// A phone that does not keep voiceprints does not subscribe to that zone,
    /// so it is not woken by another Mac teaching itself a voice, and a Mac is
    /// not woken by a phone's heartbeat.
    ///
    /// Idempotent: a subscription that already exists comes back as
    /// `serverRecordChanged`, which is the ordinary case on every launch but
    /// the first.
    public func subscribe(to zones: [CloudNaming.Zone]) async {
        for zone in zones {
            guard (try? await prepare(zone)) != nil else { continue }
            let id = "sub-" + zone.rawValue
            let subscription = CKRecordZoneSubscription(zoneID: zoneID(zone),
                                                        subscriptionID: id)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true      // silent, and the point
            subscription.notificationInfo = info
            _ = try? await pacing {
                try await database.modifySubscriptions(saving: [subscription], deleting: [])
            }
        }
    }

    // MARK: - Save

    public func save(_ record: StoredRecord) async throws -> StoredRecord {
        try await save(record, progress: nil)
    }

    public func save(_ record: StoredRecord,
                     progress: StoreProgress?) async throws -> StoredRecord {
        // The record's own zone rather than its type's, because the audio
        // master is an `r5` that lives in `z5`. See `StoredRecord.zone`.
        try await prepare(record.zone)
        let id = CKRecord.ID(recordName: record.name, zoneID: zoneID(record.zone))

        // An update modifies the instance we last read, so CloudKit can tell
        // whether anybody wrote in between. A create is a fresh record with no
        // change tag, which the server refuses if the name is taken, and that
        // refusal is the same "somebody got there first" the fake reports.
        let subject: CKRecord
        if record.changeTag != nil, let known = lastKnown[record.name],
           known.recordChangeTag == record.changeTag {
            subject = known
        } else if record.changeTag != nil {
            // We hold a tag but not the record it came from, which happens
            // after a relaunch. Read it back so the comparison is real rather
            // than assumed. A throttle must not read as "not found": the
            // record is there, the server only wants a pause first.
            let fetched: CKRecord
            do {
                fetched = try await pacing {
                    try await database.configuredWith(
                        configuration: configuration(.asset)) {
                        try await $0.record(for: id)
                    }
                }
            }
            catch let busy as StoreError { throw busy }
            catch { throw StoreError.notFound }
            guard fetched.recordChangeTag == record.changeTag else {
                throw StoreError.changedOnServer(try translate(fetched))
            }
            subject = fetched
        } else {
            subject = CKRecord(recordType: record.type.rawValue, recordID: id)
        }

        subject["payload"] = record.payload as CKRecordValue
        subject["claimedBy"] = record.claimedBy as CKRecordValue?
        subject["claimExpires"] = record.claimExpires as CKRecordValue?
        subject["audioOn"] = record.audioOn as CKRecordValue?

        // **A long-lived upload outlives this process, and so must its file.**
        // A phone's audio transfer is handed to `cloudd` and continues after
        // the app is suspended or killed. `temporaryDirectory` is exactly the
        // place iOS is entitled to reclaim while that is happening, and nothing
        // on relaunch would recreate the file, so the upload would fail on a
        // file that no longer exists with nothing anywhere saying why. Durable
        // staging for that case, swept by age rather than by a `defer` that a
        // killed process never runs.
        let longLived = CloudKitStore.isLongLived(record)
        if longLived { sweepStaging() }
        var temporaries: [URL] = []
        defer {
            // Only what this process is still responsible for. Removing a
            // long-lived upload's file here would pull it out from under the
            // daemon in the ordinary case where the app happens to survive.
            if !longLived {
                for url in temporaries { try? FileManager.default.removeItem(at: url) }
            }
        }
        for (name, data) in record.assets {
            let url = (longLived ? stagingRoot() : FileManager.default.temporaryDirectory)
                .appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            temporaries.append(url)
            subject[CloudKitStore.field(for: name)] = CKAsset(fileURL: url)
        }
        // Only when there are some. **CloudKit cannot infer a field's type
        // from an empty list**, so writing `[]` into a record type that has
        // never carried assets fails with "should be more precise" rather
        // than creating an empty string list. A note has no assets, so every
        // note failed and every recording succeeded, which is the shape of
        // bug a fake store cannot have: a dictionary has no schema to infer.
        if !record.assets.isEmpty {
            subject["assetNames"] = Array(record.assets.keys).sorted() as CKRecordValue
        }

        do {
            let saved = try await pacing {
                try await saveRecord(subject,
                                     bound: record.assets.isEmpty ? .scalar : .asset,
                                     longLived: longLived,
                                     progress: progress)
            }
            let stored = try translate(saved)
            lastKnown[record.name] = saved
            return stored
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Both copies in hand, which is the whole point of this error and
            // the reason nothing here has to guess. `Sidecars.swift` records
            // what happens when a sync guesses with a clock instead.
            if let theirs = error.serverRecord {
                lastKnown[record.name] = theirs
                throw StoreError.changedOnServer(try translate(theirs))
            }
            throw StoreError.changedOnServer(record)
        } catch let error as CKError {
            throw StoreError.unavailable(error.localizedDescription)
        }
    }

    /// Use the operation API because the convenience async save does not
    /// expose `perRecordProgressBlock`, which is CloudKit's measured asset
    /// upload progress.
    private func saveRecord(_ record: CKRecord, bound: Bound, longLived: Bool = false,
                            progress: StoreProgress?) async throws -> CKRecord {
        let box = OperationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let operation = CKModifyRecordsOperation(recordsToSave: [record],
                                                         recordIDsToDelete: nil)
                operation.configuration = configuration(bound, longLived: longLived)
                operation.savePolicy = .ifServerRecordUnchanged
                operation.isAtomic = true
                operation.perRecordProgressBlock = { _, value in progress?(value) }
                operation.modifyRecordsCompletionBlock = { saved, _, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let saved = saved?.first else {
                        continuation.resume(throwing: StoreError.unavailable("no result"))
                        return
                    }
                    progress?(1)
                    continuation.resume(returning: saved)
                }
                progress?(0)
                guard box.hold(operation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                database.add(operation)
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: - Delete

    public func delete(_ name: String, in zone: CloudNaming.Zone) async throws {
        try await prepare(zone)
        let id = CKRecord.ID(recordName: name, zoneID: zoneID(zone))
        _ = try? await pacing {
            try await database.configuredWith(configuration: configuration(.scalar)) {
                try await $0.modifyRecords(saving: [], deleting: [id])
            }
        }
        lastKnown[name] = nil
    }

    // MARK: - Changes

    public func changes(in zone: CloudNaming.Zone,
                        since token: String?) async throws -> StoreChanges {
        try await changes(in: zone, since: token, withAssets: true)
    }

    /// The fields that are not asset bodies, which is the whole record bar the
    /// sidecars: the sealed blob with `metadata.json` inside it, the three
    /// typed fields a device that did not write the content has to read, and
    /// the list naming the assets that were left behind.
    ///
    /// Every one of these is small. A recording's row comes out of `payload`
    /// and the transcript never leaves the container until somebody asks.
    ///
    /// Only a recording is affected at all. A note and a library blob keep
    /// their whole contents in `payload`, so they arrive complete through this
    /// route and there is never anything owed for them.
    private static let keysWithoutAssets: [CKRecord.FieldKey] =
        ["payload", "claimedBy", "claimExpires", "audioOn", "assetNames"]

    public func changes(in zone: CloudNaming.Zone, since token: String?,
                        withAssets: Bool) async throws -> StoreChanges {
        try await prepare(zone)
        var serverToken = decode(token)
        var expired = false

        var changed: [StoredRecord] = []
        var deleted: [String] = []
        var more = true

        while more {
            do {
                let result = try await pacing {
                    // The listing that leaves asset bodies behind is small by
                    // construction, so it gets the tight ceiling. This is the
                    // call that carried the whole transfer zone every pass.
                    try await database.configuredWith(
                        configuration: configuration(withAssets ? .asset : .scalar)) {
                        try await $0.recordZoneChanges(
                            inZoneWith: zoneID(zone), since: serverToken,
                            desiredKeys: withAssets ? nil : Self.keysWithoutAssets)
                    }
                }
                for (_, outcome) in result.modificationResultsByID {
                    guard let record = try? outcome.get().record else { continue }
                    // **A partial record is never cached.** `lastKnown` exists
                    // so a save can compare change tags without a round trip,
                    // and it hands the cached `CKRecord` to the save as the
                    // subject to modify. A record fetched without its assets
                    // is the wrong subject: the one thing this whole route
                    // must never do is put a recording back with its
                    // transcript missing. Without the cache the save reads the
                    // record back first, which is the path a relaunch already
                    // takes and costs one fetch on a push this device is
                    // making anyway.
                    if withAssets { lastKnown[record.recordID.recordName] = record }
                    if var stored = try? translate(record) {
                        // Marked, so a caller that saves it back cannot be read
                        // as asking for the assets to go. Harmless here, where
                        // `save` re-reads the record before modifying it, and
                        // load bearing in `MemoryStore`, which stores what it
                        // is given. See `StoredRecord.partial`.
                        stored.partial = !withAssets
                        changed.append(stored)
                    }
                }
                for deletion in result.deletions {
                    deleted.append(deletion.recordID.recordName)
                    lastKnown[deletion.recordID.recordName] = nil
                }
                serverToken = result.changeToken
                more = result.moreComing
            } catch let error as CKError where error.code == .changeTokenExpired {
                // The server cannot resume from what we hold, so it will send
                // everything and describe no deletions. The caller has to be
                // told, because from here a record simply being absent is
                // indistinguishable from one this device never had.
                guard !expired else { throw StoreError.unavailable("token expired twice") }
                expired = true
                serverToken = nil
                changed.removeAll(); deleted.removeAll()
                more = true
            } catch let error as CKError where error.code == .zoneNotFound
                                            || error.code == .userDeletedZone {
                // Nothing has ever been written here, which is not a failure.
                return StoreChanges(token: nil)
            }
        }

        return StoreChanges(changed: changed, deleted: deleted,
                            token: encode(serverToken), refetchedEverything: expired)
    }

    public func fetch(_ name: String, in zone: CloudNaming.Zone) async throws -> StoredRecord? {
        try await fetch(name, in: zone, progress: nil)
    }

    public func fetch(_ name: String, in zone: CloudNaming.Zone,
                      progress: StoreProgress?) async throws -> StoredRecord? {
        try await prepare(zone)
        let id = CKRecord.ID(recordName: name, zoneID: zoneID(zone))
        do {
            let record = try await pacing {
                try await fetchRecord(id, bound: .asset, progress: progress)
            }
            lastKnown[name] = record
            return try translate(record)
        } catch let error as CKError where Self.isUnknownItem(error, for: id) {
            return nil
        } catch let error as CKError {
            throw StoreError.unavailable(error.localizedDescription)
        }
    }

    /// `CKFetchRecordsOperation` wraps even a one-record miss in
    /// `.partialFailure` on some accounts. The item-level error is the real
    /// answer; only an `unknownItem` for the id we asked for means "not there".
    /// Network, permission, and another record's failure remain failures.
    static func isUnknownItem(_ error: CKError, for id: CKRecord.ID) -> Bool {
        if error.code == .unknownItem { return true }
        guard error.code == .partialFailure,
              let nested = error.partialErrorsByItemID?[id]
        else { return false }
        return CKError(_nsError: nested as NSError).code == .unknownItem
    }

    /// Use the operation API for the matching measured asset download.
    private func fetchRecord(_ id: CKRecord.ID, bound: Bound,
                             progress: StoreProgress?) async throws -> CKRecord {
        let box = OperationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let operation = CKFetchRecordsOperation(recordIDs: [id])
                operation.configuration = configuration(bound)
                operation.perRecordProgressBlock = { _, value in progress?(value) }
                operation.fetchRecordsCompletionBlock = { records, error in
                    if let error { continuation.resume(throwing: error); return }
                    guard let record = records?[id] else {
                        continuation.resume(throwing: CKError(.unknownItem))
                        return
                    }
                    progress?(1)
                    continuation.resume(returning: record)
                }
                progress?(0)
                guard box.hold(operation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                database.add(operation)
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// A CloudKit field name for one asset.
    ///
    /// **Field keys may not contain a dot**, and every sidecar this app moves
    /// is called something like `transcript.json`, so the obvious
    /// `"asset_" + name` throws `NSInvalidArgumentException` at save time
    /// rather than returning an error. Only a real container says so: the fake
    /// store is a dictionary and a dictionary will happily key on anything.
    ///
    /// The real names still travel, in `assetNames`, because that is a value
    /// rather than a key and values have no such rule.
    static func field(for asset: String) -> String {
        "asset_" + asset.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }

    // MARK: - Translation

    private func translate(_ record: CKRecord) throws -> StoredRecord {
        guard let type = CloudNaming.RecordType(rawValue: record.recordType) else {
            throw StoreError.unavailable("unknown record type \(record.recordType)")
        }
        var assets: [String: Data] = [:]
        for name in (record["assetNames"] as? [String]) ?? [] {
            guard let asset = record[CloudKitStore.field(for: name)] as? CKAsset,
                  let url = asset.fileURL,
                  let data = try? Data(contentsOf: url) else { continue }
            assets[name] = data
        }
        return StoredRecord(
            name: record.recordID.recordName,
            type: type,
            payload: (record["payload"] as? Data) ?? Data(),
            assets: assets,
            claimedBy: record["claimedBy"] as? String,
            claimExpires: record["claimExpires"] as? Date,
            audioOn: record["audioOn"] as? String,
            changeTag: record.recordChangeTag,
            // Read back from the record rather than inferred from the type,
            // which is the only way an `r5` in `z5` survives a round trip.
            zone: CloudNaming.Zone(rawValue: record.recordID.zoneID.zoneName))
    }

    /// Tokens travel as strings because the store protocol says so and the
    /// fake's are counters. CloudKit's are opaque objects, so they are archived
    /// and base64'd rather than described.
    private func encode(_ token: CKServerChangeToken?) -> String? {
        guard let token,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token,
                                                           requiringSecureCoding: true)
        else { return nil }
        return data.base64EncodedString()
    }

    private func decode(_ token: String?) -> CKServerChangeToken? {
        guard let token, let data = Data(base64Encoded: token) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self,
                                                       from: data)
    }
}
