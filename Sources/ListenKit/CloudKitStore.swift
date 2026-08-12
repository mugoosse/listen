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

    // MARK: - Save

    public func save(_ record: StoredRecord) async throws -> StoredRecord {
        try await prepare(record.type.zone)
        let id = CKRecord.ID(recordName: record.name, zoneID: zoneID(record.type.zone))

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
            subject["asset_" + name] = CKAsset(fileURL: url)
        }
        subject["assetNames"] = Array(record.assets.keys).sorted() as CKRecordValue

        do {
            let (saved, _) = try await database.modifyRecords(
                saving: [subject], deleting: [], savePolicy: .ifServerRecordUnchanged,
                atomically: true)
            guard let result = saved[id] else { throw StoreError.unavailable("no result") }
            let stored = try translate(try result.get())
            lastKnown[record.name] = try result.get()
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
        try await prepare(zone)
        let id = CKRecord.ID(recordName: name, zoneID: zoneID(zone))
        guard let record = try? await database.record(for: id) else { return nil }
        lastKnown[name] = record
        return try translate(record)
    }

    // MARK: - Translation

    private func translate(_ record: CKRecord) throws -> StoredRecord {
        guard let type = CloudNaming.RecordType(rawValue: record.recordType) else {
            throw StoreError.unavailable("unknown record type \(record.recordType)")
        }
        var assets: [String: Data] = [:]
        for name in (record["assetNames"] as? [String]) ?? [] {
            guard let asset = record["asset_" + name] as? CKAsset,
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
            changeTag: record.recordChangeTag)
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
