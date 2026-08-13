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

        public init(id: String, metadata: Data, digests: [String: String]) {
            self.id = id; self.metadata = metadata; self.digests = digests
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
    public static func assetKey(_ file: String, id: String) -> String {
        file == DevicePolicy.rawBackup(for: id) ? "raw.json.bak" : file
    }

    public static func recording(_ recording: Recording, policy: DevicePolicy,
                                 key: PairingKey) throws -> StoredRecord {
        let metadataURL = recording.folder.appendingPathComponent("metadata.json")
        let metadata = try Data(contentsOf: metadataURL)

        var digests: [String: String] = [:]
        var assets: [String: Data] = [:]
        for file in policy.files(for: recording.id) where file != "metadata.json" {
            // The raw backup is held back until the schema says otherwise.
            //
            // Its asset field has never existed in Production, and Production
            // only accepts fields deployed to it from Development. So a record
            // carrying one is refused outright, and **every edit to that
            // recording was stranded**: a corrected speaker or a new title
            // failed with the rest of the record, on every pass, silently
            // except in the log.
            //
            // Held back rather than renamed, because renaming is what proved
            // the field itself is the problem rather than its per-recording
            // name. Syncing it needs a one-time schema deploy, and until then
            // one recording's safety copy is not worth every recording's edits.
            //
            // What is given up is real and is stated on `keepsRawBackup`: a
            // second Mac that pulls a corrected transcript without this file
            // answers "no human edits here", so transcribing again there does
            // not warn before discarding the corrections.
            if file == DevicePolicy.rawBackup(for: recording.id) { continue }
            let url = recording.folder.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else { continue }
            let stored = assetKey(file, id: recording.id)
            digests[stored] = sha256Hex(data)
            assets[stored] = try key.seal(data)
        }
        digests["metadata.json"] = sha256Hex(metadata)

        let blob = RecordingBlob(id: recording.id, metadata: metadata, digests: digests)
        return StoredRecord(
            name: CloudNaming.recordName(.recording, recording.id, key: key),
            type: .recording,
            payload: try key.seal(try JSONEncoder().encode(blob)),
            assets: assets)
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

        public init(id: String, name: String, kind: String,
                    lastSeen: String, appVersion: String) {
            self.id = id; self.name = name; self.kind = kind
            self.lastSeen = lastSeen; self.appVersion = appVersion
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
