import Foundation

/// One record in the container, as far as anything above the transport cares.
///
/// A sealed blob, some assets, and the two fields that have to be readable by
/// a device that did not write the content. Everything else lives inside
/// `payload`, which is the discipline that keeps the permanent schema small:
/// adding a field to `metadata.json` never touches CloudKit, because
/// `metadata.json` is inside the blob.
public struct StoredRecord: Sendable, Equatable {
    public var name: String
    public var type: CloudNaming.RecordType
    /// The sealed body. Opaque here; `CloudRecords` knows what is in it.
    public var payload: Data
    /// Sealed too, and separate because a record's non-asset fields have a size
    /// ceiling and `transcript.json` already reaches 314 KB on a real library
    /// with no upper bound on a long meeting.
    public var assets: [String: Data]

    /// Which device is ingesting this, if any. **Typed** because it is written
    /// by a device that is not the content's author, and read to decide a race.
    public var claimedBy: String?
    /// When the claim expires, so a Mac that dies mid-ingest does not park a
    /// recording for ever.
    public var claimExpires: Date?
    /// Which device holds this recording's audio on its own disk. **Typed**
    /// for the same reason, and it is the acknowledgement the reclaim
    /// invariant turns on.
    public var audioOn: String?

    /// The store's own version marker. Ours to compare, never to interpret:
    /// CloudKit calls it a change tag and the fake calls it a counter.
    public var changeTag: String?

    public init(name: String, type: CloudNaming.RecordType, payload: Data,
                assets: [String: Data] = [:], claimedBy: String? = nil,
                claimExpires: Date? = nil, audioOn: String? = nil,
                changeTag: String? = nil) {
        self.name = name; self.type = type; self.payload = payload
        self.assets = assets; self.claimedBy = claimedBy
        self.claimExpires = claimExpires; self.audioOn = audioOn
        self.changeTag = changeTag
    }
}

/// What one fetch brought back.
public struct StoreChanges: Sendable {
    public var changed: [StoredRecord]
    public var deleted: [String]
    public var token: String?
    /// True when the server could not resume from the token it was given and
    /// started again. The moment a device cannot tell "deleted while I was
    /// away" from "never had it", which is what `EngineState.everSeen` exists
    /// for.
    public var refetchedEverything: Bool

    public init(changed: [StoredRecord] = [], deleted: [String] = [],
                token: String? = nil, refetchedEverything: Bool = false) {
        self.changed = changed; self.deleted = deleted
        self.token = token; self.refetchedEverything = refetchedEverything
    }
}

public enum StoreError: Error, Sendable, Equatable {
    /// Somebody else wrote this record since we read it. Carries their copy,
    /// so a caller can decide with both in hand rather than guessing.
    case changedOnServer(StoredRecord)
    case notFound
    case unavailable(String)
}

/// The four things the sync core needs a container to do.
///
/// Narrow on purpose. `spec/05-testing.md` promised a transport protocol with
/// a test double and the code never grew one, so `SyncEngine` held a concrete
/// client and the only way to test it was to run a real server. This is that
/// seam, made small enough that a fake is a few hundred lines rather than a
/// second implementation of CloudKit.
///
/// **Written before `CloudKitStore` deliberately.** A store written against
/// `CKRecord` first would leak it upward and there would be nothing left to
/// fake.
public protocol RecordStore: Sendable {
    /// Save, refusing if the record moved since `record.changeTag` was read.
    /// A nil tag means "this is new, refuse if it exists".
    func save(_ record: StoredRecord) async throws -> StoredRecord
    func delete(_ name: String, in zone: CloudNaming.Zone) async throws
    func changes(in zone: CloudNaming.Zone, since token: String?) async throws -> StoreChanges
    /// Fetch one, for the case where a claim has to be re-read before acting.
    func fetch(_ name: String, in zone: CloudNaming.Zone) async throws -> StoredRecord?
}
