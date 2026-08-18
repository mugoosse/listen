import Foundation

/// What a recording, a note or a blob looks like once it is a record.
///
/// **One sealed blob each, and almost nothing typed.** Nothing is queried
/// server-side, so nothing needs to be in plaintext: at 61 recordings the whole
/// scalar set is about 33 KB to fetch and decrypt in full, so the design is
/// seal everything, fetch everything, decide locally. Leaving titles readable
/// to make them queryable would mean Apple can see every meeting title, which
/// is most of what the sealing is for.
///
/// The second reason is not privacy and matters as much. Production schema is
/// **append-only for ever**: a field can be added and never removed or
/// retyped, and the container can never be reset. Everything inside the blob is
/// therefore free to change shape for the life of the product, and adding a
/// field to `metadata.json` never touches CloudKit. That is why only
/// `claimedBy`, `claimExpires` and `audioOn` are typed: each is written by a
/// device that is not the content's author, so each has to be legible without
/// opening the blob.
public enum CloudRecords {
    // MARK: - Recording

    /// A recording's blob: `metadata.json` **verbatim** plus what a receiver
    /// needs to decide without opening the assets.
    ///
    /// Verbatim is the lossiness problem solved by construction. There is no
    /// schema here to be narrower than the one that wrote the file, so `tags`,
    /// `calendar_event_id`, `calendar_people` and `app_name` survive because
    /// nothing is in a position to drop them.
    public struct RecordingBlob: Codable, Sendable {
        public var id: String
        /// The bytes of `metadata.json` as its author wrote them.
        public var metadata: Data
        /// Filename to SHA-256, so a receiver can tell what it is missing
        /// without downloading an asset to find out.
        public var digests: [String: String]
        /// A row icon is small enough to keep inside the sealed payload. This
        /// avoids adding a permanent CloudKit schema field for one tiny PNG.
        public var sourceIcon: Data?

        public init(id: String, metadata: Data, digests: [String: String],
                    sourceIcon: Data? = nil) {
            self.id = id; self.metadata = metadata; self.digests = digests
            self.sourceIcon = sourceIcon
        }
    }

    /// Build the record for one recording on disk.
    ///
    /// Assets rather than fields for the sidecars, because a record's non-asset
    /// fields have a size ceiling and `transcript.json` already reaches 314 KB
    /// on a real library with no upper bound on a long meeting.
    ///
    /// What this recording looks like locally, cheaply enough to ask on every
    /// pass about every recording.
    ///
    /// Reads the same files `recording(_:policy:key:)` would and digests them,
    /// and stops there: no sealing, no record, no network. That difference is
    /// the point. Sealing 71 recordings' sidecars and then asking the server
    /// about each one took a phone on cellular minutes per pass, during which
    /// the screen said "Sending 71 of 71" and the pull that the person was
    /// actually waiting for had not started, because it runs after the push.
    ///
    /// `hasAudio` is in here because it is not in the digests and it decides
    /// `audioOn`. Without it a Mac that had just ingested a recording would
    /// match its own last stamp and never tell the container it now holds the
    /// audio, which is the one flag the phone waits on before freeing its copy.
    public static func recordingStamp(_ recording: Recording,
                                      policy: DevicePolicy) -> String {
        var parts: [String] = [recording.hasAudio ? "audio" : "none"]
        for file in policy.files(for: recording.id).sorted() {
            let url = recording.folder.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else { continue }
            parts.append(file + ":" + sha256Hex(data))
        }
        return sha256Hex(Data(parts.joined(separator: "\n").utf8))
    }

    /// **`librarySidecars`, not `sidecars`.** Voiceprints have their own zone,
    /// and a device subscribes per zone, so putting `embeddings.json` in here
    /// would deliver it to every device that syncs the library even if that
    /// device then declined to write it to disk. The zone is what makes the
    /// split real; a client-side filter only makes it polite.
    /// What a file is called *inside a record*, which is not always what it is
    /// called on disk.
    ///
    /// Every sidecar has a fixed name except the raw backup, which is
    /// `<id>.raw.json.bak`. That is a problem twice over. A record's asset
    /// fields are named after the file, so a per-recording filename means a
    /// per-recording field, and **Production schema is append-only and
    /// locked**: the server refuses a field it has not seen, so every recording
    /// carrying a backup failed to push, for ever, with its edits stranded on
    /// the Mac that made them. Found by watching one recording fail the same
    /// way on every pass.
    ///
    /// It also put the id in the clear. `assetNames` is a plain list on the
    /// record, so `2026-08-13-155636-E172.raw.json.bak` handed Apple the exact
    /// minute of a meeting, which is the one thing `CloudNaming` exists to
    /// prevent.
    ///
    /// One recording has at most one backup, so a fixed name cannot collide.
    /// The field was deployed to Production on 13 Aug 2026; before that the
    /// backup could not be sent at all.
    public static func assetKey(_ file: String, id: String) -> String {
        file == DevicePolicy.rawBackup(for: id) ? "raw.json.bak" : file
    }

    public static func recording(_ recording: Recording, policy: DevicePolicy,
                                 key: PairingKey) throws -> StoredRecord {
        let metadataURL = recording.folder.appendingPathComponent("metadata.json")
        let metadata = try Data(contentsOf: metadataURL)

        var digests: [String: String] = [:]
        var assets: [String: Data] = [:]
        var sourceIcon: Data?
        for file in policy.files(for: recording.id) where file != "metadata.json" {
            let url = recording.folder.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else { continue }
            let stored = assetKey(file, id: recording.id)
            digests[stored] = sha256Hex(data)
            if file == DevicePolicy.sourceIcon {
                sourceIcon = data
            } else {
                assets[stored] = try key.seal(data)
            }
        }
        digests["metadata.json"] = sha256Hex(metadata)

        let blob = RecordingBlob(id: recording.id, metadata: metadata,
                                 digests: digests, sourceIcon: sourceIcon)
        return StoredRecord(
            name: CloudNaming.recordName(.recording, recording.id, key: key),
            type: .recording,
            payload: try key.seal(try JSONEncoder().encode(blob)),
            assets: assets)
    }

    /// Add content from a non-ingesting device without replacing what a Mac
    /// has already published.
    ///
    /// A phone creates the first record, but after that its full-record pushes
    /// are retries and additions. It may still hold the metadata-only copy it
    /// originally uploaded after the Mac has added a transcript. Replacing the
    /// record at that point erases the transcript from the container while the
    /// Mac's sent stamp says the richer copy is already there.
    ///
    /// Remote content wins for keys that already exist. That is the ownership
    /// boundary today: phone transcript and metadata views are read-only, while
    /// title and tag edits travel as patches. If the phone later authors
    /// transcripts, that needs an explicit content-version rule rather than
    /// silently changing this one.
    public static func addingPhoneContent(_ local: StoredRecord,
                                          to existing: StoredRecord,
                                          key: PairingKey) throws -> StoredRecord {
        let ours = try openRecording(local, key: key)
        let theirs = try openRecording(existing, key: key)
        guard ours.id == theirs.id else { return local }

        var digests = ours.digests
        for (name, digest) in theirs.digests { digests[name] = digest }
        var assets = local.assets
        for (name, data) in existing.assets { assets[name] = data }

        let blob = RecordingBlob(id: ours.id, metadata: theirs.metadata,
                                 digests: digests,
                                 sourceIcon: theirs.sourceIcon ?? ours.sourceIcon)
        var merged = local
        merged.payload = try key.seal(try JSONEncoder().encode(blob))
        merged.assets = assets
        return merged
    }

    /// Keep an icon this device could not have made.
    ///
    /// `source-icon.png` is the one sidecar a Mac can legitimately be unable to
    /// produce: `SourceIconExporter` resolves it from the installed
    /// application, so a Mac that does not have that app has no local copy and
    /// never will. `push` builds a record out of local files alone, so that
    /// Mac's push **removed** the icon from the container, and the Mac that
    /// could make it then skipped its own push because its `sent:` stamp said
    /// the record was already sent. Eleven recordings lost their row icon that
    /// way in a single pass, on a second Mac whose stamps had just been
    /// cleared, and it took a manifest diff between the two machines to see it.
    ///
    /// Only the icon, deliberately. A general "never remove a sidecar this
    /// device lacks" rule would also preserve `<id>.raw.json.bak`, whose
    /// *absence* is the evidence that a transcript carries no hand
    /// corrections, so a blanket rule would quietly change what
    /// `hasHumanEdits` answers on every other device. See `DevicePolicy`.
    public static func keepingSourceIcon(_ ours: StoredRecord, from existing: StoredRecord,
                                         key: PairingKey) throws -> StoredRecord {
        var mine = try openRecording(ours, key: key)
        let theirs = try openRecording(existing, key: key)
        guard mine.id == theirs.id, mine.sourceIcon == nil, let icon = theirs.sourceIcon,
              let digest = theirs.digests[DevicePolicy.sourceIcon]
        else { return ours }
        mine.sourceIcon = icon
        mine.digests[DevicePolicy.sourceIcon] = digest
        var merged = ours
        merged.payload = try key.seal(try JSONEncoder().encode(mine))
        return merged
    }

    /// Open one, back into something a device can write to disk.
    public static func openRecording(_ record: StoredRecord,
                                     key: PairingKey) throws -> RecordingBlob {
        try JSONDecoder().decode(RecordingBlob.self, from: try key.open(record.payload))
    }

    /// One sidecar out of a record, unsealed. Separate from the blob because a
    /// device fetches these only when its digest disagrees.
    public static func openAsset(_ record: StoredRecord, _ file: String,
                                 key: PairingKey) throws -> Data? {
        guard let sealed = record.assets[file] else { return nil }
        return try key.open(sealed)
    }

    // MARK: - Note

    /// A note's blob: the serialised markdown sealed whole.
    ///
    /// Whole, rather than a struct of its fields, so hand-written frontmatter
    /// survives and so does every key a later version of Listen invents. That
    /// is the same rule the note parser had to learn twice: a document this
    /// device did not author is bytes, not a model.
    public struct NoteBlob: Codable, Sendable {
        public var slug: String
        /// The content digest. What every decision is made on, never a clock.
        public var version: String
        public var markdown: String

        public init(slug: String, version: String, markdown: String) {
            self.slug = slug; self.version = version; self.markdown = markdown
        }
    }

    public static func note(_ note: Note, key: PairingKey) throws -> StoredRecord {
        let blob = NoteBlob(slug: note.slug, version: note.version,
                            markdown: note.serialised())
        return StoredRecord(
            name: CloudNaming.recordName(.note, note.slug, key: key),
            type: .note,
            payload: try key.seal(try JSONEncoder().encode(blob)))
    }

    public static func openNote(_ record: StoredRecord, key: PairingKey) throws -> NoteBlob {
        try JSONDecoder().decode(NoteBlob.self, from: try key.open(record.payload))
    }

    // MARK: - Blob

    /// A library-level file: `contacts.json`, `dictionary.json`.
    ///
    /// The dictionary is the one that matters most, because it rewrites
    /// transcripts: two devices with different dictionaries produce differently
    /// corrected transcripts of the same audio.
    public struct FileBlob: Codable, Sendable {
        public var name: String
        public var version: String
        public var contents: Data

        public init(name: String, contents: Data) {
            self.name = name; self.contents = contents
            self.version = sha256Hex(contents)
        }
    }

    public static func blob(name: String, contents: Data,
                            key: PairingKey) throws -> StoredRecord {
        StoredRecord(
            name: CloudNaming.recordName(.blob, name, key: key),
            type: .blob,
            payload: try key.seal(try JSONEncoder().encode(FileBlob(name: name,
                                                                    contents: contents))))
    }

    public static func openBlob(_ record: StoredRecord, key: PairingKey) throws -> FileBlob {
        try JSONDecoder().decode(FileBlob.self, from: try key.open(record.payload))
    }

    // MARK: - Device

    /// One row in the settings pane, and **each device writes only its own**,
    /// so there is no merge to get wrong.
    public struct DeviceBlob: Codable, Sendable {
        public var id: String
        public var name: String
        public var kind: String
        public var lastSeen: String
        public var appVersion: String

        /// Whether this device has been asked to keep audio.
        ///
        /// The switch, not the outcome. A device with this on pulls the master
        /// for every recording it does not already have audio for; a device
        /// with it off frees what it holds as soon as somebody else says they
        /// have it.
        ///
        /// **Optional, and every consumer reads `keeps`.** Devices already in
        /// the container were written by a build that had never heard of this,
        /// and the synthesised decoder throws on a missing key for a
        /// non-optional. `openDevice` is called behind a `try?`, so throwing
        /// would not report anything: it would silently drop that machine out
        /// of the roster, which is the list the reclaim rule reads. The same
        /// lesson `Metadata` learned by making meetings disappear.
        public var keepsAudio: Bool?
        /// The recordings whose audio is on this device's own disk, right now.
        ///
        /// The answer to the only question the reclaim invariant asks: is
        /// there another device holding these bytes? A record in the container
        /// is not an answer to it, and neither is `audioOn`, which says a
        /// device once took the audio and stays true after that device has
        /// been wiped. This is republished every pass from what is actually
        /// on disk, so it goes stale the way a heartbeat does rather than the
        /// way a latch does.
        ///
        /// A list of ids rather than a count, because the question is per
        /// recording. At 61 recordings it is about 1.2 KB inside a sealed
        /// payload with a 1 MB ceiling.
        public var holdsAudio: [String]?

        public init(id: String, name: String, kind: String,
                    lastSeen: String, appVersion: String,
                    keepsAudio: Bool? = nil, holdsAudio: [String]? = nil) {
            self.id = id; self.name = name; self.kind = kind
            self.lastSeen = lastSeen; self.appVersion = appVersion
            self.keepsAudio = keepsAudio; self.holdsAudio = holdsAudio
        }

        /// What this device asked for, with the answer an older build could
        /// not give. A device that has never said either way is treated as
        /// keeping its audio, because that is the assumption under which
        /// nothing is deleted.
        public var keeps: Bool { keepsAudio ?? true }

        /// Whether this device says it holds a recording's audio.
        ///
        /// A device that has never published the list answers **no** to every
        /// id rather than yes, which is the direction that cannot lose a
        /// recording: an old build authorises no deletions at all.
        public func holds(_ id: String) -> Bool { holdsAudio?.contains(id) ?? false }

        /// Whether its last heartbeat is recent enough to be evidence.
        ///
        /// A device that has said nothing for a week may have been wiped,
        /// reinstalled or thrown away, and its list is a claim about a disk
        /// nobody can see. Long enough to cover a laptop shut for a weekend
        /// and much shorter than the thirty days the roster keeps a row, on
        /// purpose: being listed is a convenience and being believed about
        /// somebody else's only copy is not.
        public func isLive(_ now: Date = Date(), within: TimeInterval = 7 * 86_400) -> Bool {
            guard let when = Metadata.parser.date(from: lastSeen) else { return false }
            return now.timeIntervalSince(when) <= within
        }

        /// When it last said anything, in words. A device list without this
        /// cannot be read: an install that has been replaced looks exactly
        /// like the phone in your pocket.
        public var seenAgo: String {
            guard let when = Metadata.parser.date(from: lastSeen) else { return "at an unknown time" }
            let ago = Date().timeIntervalSince(when)
            if ago < 120 { return "just now" }
            if ago < 3600 { return "\(Int(ago / 60)) min ago" }
            if ago < 86_400 { return "\(Int(ago / 3600)) h ago" }
            return "\(Int(ago / 86_400)) days ago"
        }
    }

    public static func device(_ device: DeviceBlob, key: PairingKey) throws -> StoredRecord {
        StoredRecord(
            name: CloudNaming.recordName(.device, device.id, key: key),
            type: .device,
            payload: try key.seal(try JSONEncoder().encode(device)))
    }

    public static func openDevice(_ record: StoredRecord,
                                  key: PairingKey) throws -> DeviceBlob {
        try JSONDecoder().decode(DeviceBlob.self, from: try key.open(record.payload))
    }

    // MARK: - Audio in flight

    /// A phone recording on its way to a Mac. Sealed audio and who sent it.
    ///
    /// Lives in its own zone so that purging a 25 MB asset after ingest does
    /// not churn the library's change feed, and deleted by whichever Mac
    /// ingests it, **but never before that Mac reports the audio on its own
    /// disk**. Between "upload finished" and "a Mac has it", this record is the
    /// only copy of that recording anywhere.
    public struct TransferBlob: Codable, Sendable {
        public var id: String
        public var from: String
        /// `metadata.json` as the recording device wrote it, so the Mac
        /// publishes the author's document rather than rebuilding one.
        public var metadata: Data

        public init(id: String, from: String, metadata: Data) {
            self.id = id; self.from = from; self.metadata = metadata
        }
    }

    public static func transfer(id: String, from: String, metadata: Data, audio: Data,
                                key: PairingKey) throws -> StoredRecord {
        StoredRecord(
            name: CloudNaming.recordName(.audioTransfer, id, key: key),
            type: .audioTransfer,
            payload: try key.seal(try JSONEncoder().encode(
                TransferBlob(id: id, from: from, metadata: metadata))),
            assets: ["mic.wav": try key.seal(audio)])
    }

    public static func openTransfer(_ record: StoredRecord,
                                    key: PairingKey) throws -> TransferBlob {
        try JSONDecoder().decode(TransferBlob.self, from: try key.open(record.payload))
    }

    // MARK: - The audio master

    /// The one durable copy of a recording's audio, so that a device which
    /// never had the bytes can have them and a device that has them can let go.
    ///
    /// **`r5` in `z5`, and the asset is called `mic.wav`.** Both are the same
    /// constraint wearing two hats: Production schema is append-only for ever,
    /// so a new record type or a second audio field would be permanent, while
    /// a zone is created per account at runtime and costs nothing. The bytes
    /// are a stereo FLAC and the field they ride is `asset_mic_wav`, which is
    /// a name rather than a claim about the contents. See `AudioMaster` for
    /// what is in it and `CloudNaming.Zone.masters` for why not `z4`.
    ///
    /// The natural key is prefixed, so a recording's master and a recording's
    /// transfer derive two different opaque names from the same id and can
    /// exist at the same time. They usually do: a phone memo is in flight and
    /// its master is published by the Mac that ingests it.
    public struct MasterBlob: Codable, Sendable {
        public var id: String
        /// The device that published it. Provenance, and read by nothing.
        public var from: String
        /// SHA-256 of the FLAC. What a receiver checks the bytes against, and
        /// what a sender compares before spending an upload on a file the
        /// container already holds.
        public var digest: String
        public var bytes: Int
        /// Two for a meeting, one for a voice memo. Here so a device can say
        /// what it is about to get without opening it.
        public var channels: Int
        /// What the channels **are**, which is a different question from how
        /// many there are and the one that decides where they are split back
        /// to. Optional because records published before this field existed
        /// carry none, and every one of those was built from separate tracks.
        /// See `AudioMaster.Layout`.
        public var layoutName: String?

        public var layout: AudioMaster.Layout {
            layoutName.flatMap(AudioMaster.Layout.init(rawValue:)) ?? .tracks
        }

        public init(id: String, from: String, digest: String, bytes: Int, channels: Int,
                    layout: AudioMaster.Layout = .tracks) {
            self.id = id; self.from = from; self.digest = digest
            self.bytes = bytes; self.channels = channels
            self.layoutName = layout.rawValue
        }
    }

    /// The asset key, which decides the CloudKit field.
    ///
    /// `mic.wav` maps to `asset_mic_wav`, which Production already has. A key
    /// of `master.flac` would ask for `asset_master_flac`, and that is a field
    /// deployed for ever to carry what an existing one already carries.
    static let masterAsset = "mic.wav"

    public static func masterName(_ id: String, key: PairingKey) -> String {
        CloudNaming.recordName(.audioTransfer, "master:" + id, key: key)
    }

    public static func master(id: String, from: String, audio: Data, channels: Int,
                              layout: AudioMaster.Layout = .tracks,
                              key: PairingKey) throws -> StoredRecord {
        let blob = MasterBlob(id: id, from: from, digest: sha256Hex(audio),
                              bytes: audio.count, channels: channels, layout: layout)
        return StoredRecord(
            name: masterName(id, key: key),
            type: .audioTransfer,
            payload: try key.seal(try JSONEncoder().encode(blob)),
            assets: [masterAsset: try key.seal(audio)],
            zone: .masters)
    }

    public static func openMaster(_ record: StoredRecord,
                                  key: PairingKey) throws -> MasterBlob {
        try JSONDecoder().decode(MasterBlob.self, from: try key.open(record.payload))
    }

    /// The FLAC itself, unsealed and checked against the digest it travelled
    /// with. Nil when the record carries no asset, which is a save that landed
    /// without its bytes and is worth ignoring rather than writing to disk.
    public static func openMasterAudio(_ record: StoredRecord, _ blob: MasterBlob,
                                       key: PairingKey) throws -> Data? {
        guard let sealed = record.assets[masterAsset] else { return nil }
        let audio = try key.open(sealed)
        guard sha256Hex(audio) == blob.digest else { return nil }
        return audio
    }

    // MARK: - Voiceprint

    /// `embeddings.json`, in a zone the phone does not subscribe to.
    ///
    /// The split survives only while the phone has nothing that reads a
    /// voiceprint, which is decision 6's narrow answer: the phone transcribes
    /// for itself and does not diarize. See `DevicePolicy`.
    public static func voiceprint(id: String, contents: Data,
                                  key: PairingKey) throws -> StoredRecord {
        StoredRecord(
            name: CloudNaming.recordName(.voiceprint, id, key: key),
            type: .voiceprint,
            payload: try key.seal(try JSONEncoder().encode(
                FileBlob(name: id, contents: contents))))
    }
}
