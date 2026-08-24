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

    // MARK: - Zones

    /// Zones are created on first use rather than at launch, so an app that
    /// never syncs never writes anything to anybody's iCloud account.
    private func prepare(_ zone: CloudNaming.Zone) async throws {
        guard !preparedZones.contains(zone) else { return }
        let id = CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: id)],
                                                     deleting: [])
        } catch let error as CKError where error.code == .serverRecordChanged {
            // Already there, which is the ordinary case on every launch but
            // the first.
        }
        preparedZones.insert(zone)
    }

    private func zoneID(_ zone: CloudNaming.Zone) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.rawValue, ownerName: CKCurrentUserDefaultName)
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
            _ = try? await database.modifySubscriptions(saving: [subscription], deleting: [])
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
            // than assumed.
            guard let fetched = try? await database.record(for: id) else {
                throw StoreError.notFound
            }
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

        // Assets need a file on disk, so each one is written to a temporary
        // location that is removed as soon as CloudKit has read it.
        var temporaries: [URL] = []
        defer { for url in temporaries { try? FileManager.default.removeItem(at: url) } }
        for (name, data) in record.assets {
            let url = FileManager.default.temporaryDirectory
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
            let saved = try await saveRecord(subject, progress: progress)
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
    private func saveRecord(_ record: CKRecord,
                            progress: StoreProgress?) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: [record],
                                                     recordIDsToDelete: nil)
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
            database.add(operation)
        }
    }

    // MARK: - Delete

    public func delete(_ name: String, in zone: CloudNaming.Zone) async throws {
        try await prepare(zone)
        let id = CKRecord.ID(recordName: name, zoneID: zoneID(zone))
        _ = try? await database.modifyRecords(saving: [], deleting: [id])
        lastKnown[name] = nil
    }

    // MARK: - Changes

    public func changes(in zone: CloudNaming.Zone,
                        since token: String?) async throws -> StoreChanges {
        try await prepare(zone)
        var serverToken = decode(token)
        var expired = false

        var changed: [StoredRecord] = []
        var deleted: [String] = []
        var more = true

        while more {
            do {
                let result = try await database.recordZoneChanges(inZoneWith: zoneID(zone),
                                                                  since: serverToken)
                for (_, outcome) in result.modificationResultsByID {
                    guard let record = try? outcome.get().record else { continue }
                    lastKnown[record.recordID.recordName] = record
                    if let stored = try? translate(record) { changed.append(stored) }
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
            let record = try await fetchRecord(id, progress: progress)
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
    private func fetchRecord(_ id: CKRecord.ID,
                             progress: StoreProgress?) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: [id])
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
            database.add(operation)
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
