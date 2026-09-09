import Foundation

/// The recordings and notes this library has been told to delete.
///
/// **A deletion used to be an absence, and an absence is ambiguous.** Nothing
/// on disk said a person had meant it: `push` inferred one from "this device
/// has a `sent:` stamp and no folder", which cannot be told apart from a
/// library that failed to mount, a folder moved in the Finder, or a state
/// directory that outlived the tree it described. The inference needed a
/// heuristic to stay safe, and the heuristic could only ever be crude.
///
/// It was also undone by the ordinary shape of a pass. Every device pulls
/// before it pushes, but a device that has been asleep pushes work of its own,
/// and the recording loop had no branch for "gone from the container": it found
/// no record, sent one, and the deleted meeting was back on every device.
/// Measured on this library on 7 September 2026. Five recordings were deleted
/// at 11:55; the second Mac launched at 11:56 holding a freshly arrived audio
/// master for three of them, pushed before its pull had applied anything, and
/// those three had to be deleted a second time at 12:03. The activity log on
/// both Macs records it, and nothing in either app reported anything wrong.
///
/// So the deletion itself is data, exactly as a forgotten voiceprint is:
/// `VoiceprintTombstones` is the same shape for the same reason, and the two
/// files are deliberately near-identical so that neither can drift into a
/// different answer about the same race. Each entry is a kind, an id and when
/// it was deleted, replicated as one sealed r3 blob, merged per entry by latest
/// stamp, and applied on every device before it pushes anything. A record with
/// an active tombstone is never written by a pull, never sent by a push, and
/// never ingested from a phone's transfer.
///
/// **Delete wins over a concurrent edit.** A device that edited a recording it
/// had not yet sent still obeys the tombstone; the pass reports a conflict and
/// the copy goes to `Trash` for a fortnight, which is where every device's copy
/// goes now, including the one the deletion was made on. That is the trade this
/// makes and it is the right way round: an edit lost to a deletion is in the
/// trash and recoverable, and a meeting resurrected on four devices is a thing
/// somebody has to hunt down again.
///
/// Entries expire after 90 days, for the reason `VoiceprintTombstones` gives:
/// the list exists to outlive the propagation race, and one that only grew
/// would name every recording the user ever deleted, for ever. A device shut
/// for longer than that can resurrect one, and deleting it again is one action.
///
/// **It travels as a blob and never as a file**, which is the distinction
/// `.forgotten-voices.json` makes by staying out of every set: two devices'
/// lists have to meet through `merged`, and a byte-level sync would let the
/// newer file win whole and drop the other device's deletions. The difference
/// here is only where the merge hangs. This one is in `DevicePolicy.blobs`, so
/// it rides the r3 path that `contacts.json` uses, with `receive` on both the
/// pull and the push side exactly as `ContextSync` and `MemoryPreferences`
/// already do. No CloudKit schema changes for it: an r3 payload is opaque
/// bytes, and Production schema is append-only for ever.
public struct Deletions: Codable, Sendable, Equatable {
    /// What was deleted. A string rather than an enum, on purpose: this file
    /// crosses between two apps that are updated separately, and a kind a
    /// future Listen invents has to survive a round trip through this one
    /// rather than failing its decode. An unknown kind is carried and never
    /// applied, which is the same rule `Metadata` and `Note` follow for fields.
    public static let recording = "recording"
    public static let note = "note"

    public struct Entry: Codable, Sendable, Equatable {
        public var kind: String
        /// A recording id or a note slug, validated on arrival. See `receive`.
        public var id: String
        /// `Metadata.stamp` format, UTC. Fixed-width, so string order is time
        /// order and no parse is needed to pick a winner.
        public var at: String
        /// True on a restore. Optional so files written before the field
        /// existed still decode.
        public var removed: Bool?

        public init(kind: String, id: String, at: String, removed: Bool? = nil) {
            self.kind = kind; self.id = id; self.at = at; self.removed = removed
        }

        public var key: String { Deletions.key(kind, id) }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    /// What the file is called on disk, and the blob name it travels under.
    public static let filename = ".deletions.json"

    public static let lifetime: TimeInterval = 90 * 86_400

    /// One entry's identity: a kind and an id, because a note slug and a
    /// recording id are different namespaces and nothing guarantees they never
    /// collide.
    public static func key(_ kind: String, _ id: String) -> String { kind + ":" + id }

    static func url(in library: Library) -> URL {
        library.root.appendingPathComponent(filename)
    }

    public static func load(_ library: Library) -> Deletions {
        guard let data = try? Data(contentsOf: url(in: library)),
              let list = try? JSONDecoder().decode(Deletions.self, from: data)
        else { return Deletions() }
        return list
    }

    /// The canonical bytes: one encoder, so what is written to disk and what is
    /// published are the same, and two devices holding the same entries agree
    /// on the digest `push` compares rather than re-sending the list for ever.
    public func serialised() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public func save(_ library: Library) {
        try? serialised().write(to: Deletions.url(in: library), options: .atomic)
    }

    public mutating func delete(_ kind: String, _ id: String, now: Date = Date()) {
        entries.removeAll { $0.kind == kind && $0.id == id }
        entries.append(Entry(kind: kind, id: id, at: Metadata.stamp(now)))
    }

    public mutating func restore(_ kind: String, _ id: String, now: Date = Date()) {
        entries.removeAll { $0.kind == kind && $0.id == id }
        entries.append(Entry(kind: kind, id: id, at: Metadata.stamp(now), removed: true))
    }

    /// The keys nothing may hold right now.
    public func active(now: Date = Date()) -> Set<String> {
        let floor = Metadata.stamp(now.addingTimeInterval(-Self.lifetime))
        return Set(entries.filter { $0.removed != true && $0.at > floor }.map(\.key))
    }

    public func isDeleted(_ kind: String, _ id: String, now: Date = Date()) -> Bool {
        active(now: now).contains(Deletions.key(kind, id))
    }

    /// Union by kind and id, latest stamp wins, expired entries dropped.
    ///
    /// Dropping the expired on merge rather than on load is what keeps two
    /// long-lived devices from re-gifting each other entries neither applies.
    public static func merged(_ a: Self, _ b: Self, now: Date = Date()) -> Deletions {
        let floor = Metadata.stamp(now.addingTimeInterval(-lifetime))
        var byKey: [String: Entry] = [:]
        for entry in a.entries + b.entries where entry.at > floor {
            if let held = byKey[entry.key] {
                if held.at > entry.at { continue }
                // Stamps have one-second resolution, so a delete and its
                // restore can tie. The restore wins the tie, for the reason
                // `VoiceprintTombstones.merged` gives about its own: putting
                // something back is recoverable and throwing it away is not.
                if held.at == entry.at,
                   held.removed == true || entry.removed != true { continue }
            }
            byKey[entry.key] = entry
        }
        return Deletions(entries: byKey.values
            .sorted { $0.key == $1.key ? $0.at < $1.at : $0.key < $1.key })
    }

    /// Merge another device's list into this library's and hand back the bytes
    /// to publish.
    ///
    /// The same contract as `ContextSync.receive`, so it plugs into the two
    /// hooks the blob paths already have: one on the way down in `pullBlob`,
    /// one before the push in `push`, which together are what make this
    /// converge rather than letting the last writer win.
    @discardableResult
    public static func receive(_ contents: Data, library: Library,
                               now: Date = Date()) throws -> Data {
        // A bound, because this is the one library file another device can make
        // arbitrarily long. 90 days of entries at about 80 bytes each is a few
        // hundred kilobytes for a library nobody could delete from that fast;
        // four megabytes is far past anything real and far below the point
        // where decoding it is a problem.
        guard contents.count <= 4_000_000 else {
            throw ContextDatabase.Failure(
                message: "The incoming list of deletions exceeds the size limit.")
        }
        let remote = try JSONDecoder().decode(Deletions.self, from: contents)
        let merged = Deletions.merged(load(library), remote.validated(), now: now)
        merged.save(library)
        return try merged.serialised()
    }

    /// Drop entries whose id would not be a name this library writes.
    ///
    /// An id here arrives from another device and is turned into a path by
    /// `Library.folder(for:)` or `notes/<slug>.md`, both of which resolve `..`.
    /// `Metadata.isValidID` and `Note.isValidSlug` are the same guards the
    /// record paths apply, and this is the boundary for this file. An unknown
    /// kind is kept unvalidated and never applied: nothing turns it into a
    /// path, and dropping it would mean an older Listen silently erasing a
    /// newer one's deletions every time the two met.
    func validated() -> Deletions {
        Deletions(entries: entries.filter { entry in
            switch entry.kind {
            case Deletions.recording: return Metadata.isValidID(entry.id)
            case Deletions.note: return Note.isValidSlug(entry.id)
            default: return true
            }
        })
    }

    /// Whether this device is holding a change to a recording that the
    /// container has not got.
    ///
    /// Asked when a deletion is about to take the recording away, so the pass
    /// can name what went into the trash rather than only counting it. It has
    /// to answer for a recording this device **pulled**, which is the ordinary
    /// case and the one a plain `sent:` comparison gets wrong in both
    /// directions: a pull deliberately leaves no `sent:` stamp, so every
    /// deletion would read as a lost edit and every device would report a
    /// conflict for every deletion, which is noise rather than information.
    ///
    /// A pull does stamp each sidecar it wrote, so those are the bases that
    /// answer properly for a pulled recording: one that disagrees with the file
    /// beside it is an edit made here since. `sent:` is the better answer when
    /// there is one, because it covers the whole folder at once.
    static func unsentEdit(_ recording: Recording, base: SyncState,
                           policy: DevicePolicy) -> Bool {
        if let sent = base[sent: recording.id] {
            return sent != CloudRecords.recordingStamp(recording, policy: policy)
        }
        for file in policy.files(for: recording.id) where file != "metadata.json" {
            guard let agreed = base[sidecar: recording.id, file: file],
                  let data = try? Data(contentsOf:
                    recording.folder.appendingPathComponent(file)) else { continue }
            if agreed != sha256Hex(data) { return true }
        }
        return false
    }

    /// What one application of the list did.
    public struct Applied: Sendable, Equatable {
        public var recordings: [String] = []
        public var notes: [String] = []
        /// Things that were edited here and not yet sent when the deletion
        /// arrived. Named rather than counted, because the copy is in the trash
        /// and somebody may want it back.
        public var conflicts: [String] = []

        public var didSomething: Bool { !recordings.isEmpty || !notes.isEmpty }
    }

    /// Take out of this library everything an active tombstone names.
    ///
    /// **Moved, not removed.** `Trash` states the rule and this is the same
    /// class of event it was written for: a deletion made somewhere else, on a
    /// device that cannot tell a deliberate one from a mistake. Fourteen days
    /// on every device, and the device the deletion was made on keeps its copy
    /// the same way, which it did not before.
    ///
    /// The sync state goes with the files. Leaving a `sent:` stamp behind would
    /// make the next push read the missing folder as a fresh deletion to send,
    /// and leaving the per-file bases behind is how a real library accumulated
    /// 57 keys for recordings it no longer had.
    public static func apply(_ active: Set<String>, to library: Library,
                             base: inout SyncState, seen: inout Set<String>,
                             key: PairingKey, policy: DevicePolicy) -> Applied {
        var applied = Applied()
        guard !active.isEmpty else { return applied }

        for recording in library.all()
        where active.contains(Deletions.key(Deletions.recording, recording.id)) {
            // Asked before the folder moves, because it reads the files.
            if unsentEdit(recording, base: base, policy: policy) {
                applied.conflicts.append(
                    "\(recording.id): deleted elsewhere, and edited here since it was sent")
            }
            Trash.accept(recording.folder, in: library)
            base.forgetRecording(recording.id)
            seen.remove(CloudNaming.recordName(.recording, recording.id, key: key))
            applied.recordings.append(recording.id)
        }

        for note in library.allNotes()
        where active.contains(Deletions.key(Deletions.note, note.slug)) {
            if let agreed = base[note: note.slug], agreed != note.version {
                applied.conflicts.append(
                    "\(note.slug): deleted elsewhere, and edited here since it was sent")
            }
            Trash.accept(library.notes.appendingPathComponent(note.slug + ".md"),
                         in: library)
            base.forgetNote(note.slug)
            seen.remove(CloudNaming.recordName(.note, note.slug, key: key))
            applied.notes.append(note.slug)
        }

        return applied
    }
}
