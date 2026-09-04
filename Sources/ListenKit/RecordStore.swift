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

    /// Whether the asset bodies were left behind when this record was read.
    ///
    /// **The one thing a store may never do with a partial record is take its
    /// empty `assets` as an instruction to remove them.** `changes(withAssets:
    /// false)` exists so a device can decide what it wants before paying for
    /// tens of megabytes, and the deciding usually ends in a save: `claim`
    /// writes two fields back onto the very record whose audio is the only copy
    /// of somebody's memo. `CloudKitStore` never had this problem, because it
    /// re-reads the record before modifying it and CloudKit sends only the
    /// fields that changed. `MemoryStore` stores whatever it is handed, so
    /// without this flag the fake would silently drop the audio, and the fake
    /// is what the seam suite is made of.
    ///
    /// Set by the read, honoured by the write, and false on anything a store
    /// hands back: what is stored is always complete.
    public var partial: Bool = false

    /// Where this record lives.
    ///
    /// Defaults to the type's usual zone, which is the answer for every record
    /// but one. **The audio master is an `r5` in `z5`**, because a record type
    /// is permanent Production schema and a zone is not: adding `r7` would be a
    /// deploy that can never be undone, while `z5` is created per account at
    /// runtime. So the type says what a record is and this says where it is,
    /// and the two stopped being the same question the moment one type had to
    /// live in two places. See `CloudNaming.Zone.masters`.
    public var zone: CloudNaming.Zone

    public init(name: String, type: CloudNaming.RecordType, payload: Data,
                assets: [String: Data] = [:], claimedBy: String? = nil,
                claimExpires: Date? = nil, audioOn: String? = nil,
                changeTag: String? = nil, zone: CloudNaming.Zone? = nil) {
        self.name = name; self.type = type; self.payload = payload
        self.assets = assets; self.claimedBy = claimedBy
        self.claimExpires = claimExpires; self.audioOn = audioOn
        self.changeTag = changeTag; self.zone = zone ?? type.zone
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
    /// The server asked this device to slow down, and for how long. Not a
    /// failure: nothing is wrong with the record or the account, the container
    /// is pacing its callers, and the honest response is to wait and go again.
    /// Kept apart from `unavailable` so a report can schedule a quiet retry
    /// instead of alarming somebody with CloudKit's internal phrasing about
    /// http 429 replies. See `CloudKitStore.askedToWait`.
    case busy(TimeInterval)
}

extension StoreError: LocalizedError {
    /// Spelled out, because these are strings a report shows a person and the
    /// default `localizedDescription` of a Swift enum is "StoreError error 2".
    public var errorDescription: String? {
        switch self {
        case .changedOnServer: return "another device updated this first"
        case .notFound: return "not in the container"
        case .unavailable(let why): return why
        case .busy: return "iCloud asked this device to slow down"
        }
    }
}

/// Progress through one record transfer, from 0 to 1.
public typealias StoreProgress = @Sendable (Double) -> Void

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
    /// The same save, with transport progress when the store can report it.
    func save(_ record: StoredRecord,
              progress: StoreProgress?) async throws -> StoredRecord
    func delete(_ name: String, in zone: CloudNaming.Zone) async throws
    func changes(in zone: CloudNaming.Zone, since token: String?) async throws -> StoreChanges
    /// The same feed with the asset bodies left behind, for a device that
    /// wants to know what exists before it spends the bytes on the contents.
    ///
    /// A recording's title lives in `payload`, which is a field of a few
    /// hundred bytes, and its transcript is an asset of up to a few hundred
    /// kilobytes. Asking for both is why a first sync shows nothing at all
    /// until every transcript in the library has landed. Asking for the first
    /// alone puts every row on the screen in one small request, and leaves
    /// the contents to `fetch`, one recording at a time, with progress.
    ///
    /// The change token still advances, so what is skipped here is skipped
    /// for good as far as this feed is concerned: a caller that takes this
    /// route owes itself a record of what it has yet to collect. See
    /// `SyncState.owed` and `CloudSyncCore.collectOwedSidecars`.
    func changes(in zone: CloudNaming.Zone, since token: String?,
                 withAssets: Bool) async throws -> StoreChanges
    /// Fetch one, for the case where a claim has to be re-read before acting.
    func fetch(_ name: String, in zone: CloudNaming.Zone) async throws -> StoredRecord?
    /// The same fetch, with transport progress when the store can report it.
    func fetch(_ name: String, in zone: CloudNaming.Zone,
               progress: StoreProgress?) async throws -> StoredRecord?
}

/// Stores without a byte-aware transport still expose honest endpoints. The
/// real CloudKit store overrides these methods with operation progress.
public extension RecordStore {
    /// A store that cannot separate the two brings everything, which is
    /// wasteful and never wrong.
    func changes(in zone: CloudNaming.Zone, since token: String?,
                 withAssets: Bool) async throws -> StoreChanges {
        try await changes(in: zone, since: token)
    }

    func save(_ record: StoredRecord,
              progress: StoreProgress?) async throws -> StoredRecord {
        progress?(0)
        let saved = try await save(record)
        progress?(1)
        return saved
    }

    func fetch(_ name: String, in zone: CloudNaming.Zone,
               progress: StoreProgress?) async throws -> StoredRecord? {
        progress?(0)
        let record = try await fetch(name, in: zone)
        progress?(1)
        return record
    }
}
