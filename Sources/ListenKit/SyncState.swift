import Foundation

/// What this device believed the other one had, at the end of the last sync.
///
/// Without it a note sync can compare only two things, local and remote, and
/// two values cannot distinguish "I am behind" from "we both changed". The
/// first pass at this compared timestamps alone and **silently destroyed an
/// edit made on the phone** when the Mac had also been edited: the phone's
/// copy was older, so it looked like a stale copy and was overwritten. It
/// reported success. That is the failure this file exists to make impossible.
///
/// Three values, so every case is nameable:
///
/// | base | local | remote | meaning |
/// |---|---|---|---|
/// | b | b | b | nothing to do |
/// | b | b | r | pull |
/// | b | l | b | push |
/// | b | l | r | **conflict**, touch neither |
///
/// A recording's sidecars need none of this. A transcript has exactly one
/// writer, the Mac that made it, and audio is written once and never again.
/// What needs it is anything two devices can edit independently: notes today,
/// and the library-level files in `DevicePolicy.blobs` as soon as there is a
/// second Mac, because `contacts.json` and `dictionary.json` are both edited on
/// whichever machine you happen to be sitting at.
///
/// So the map is keyed by kind rather than by slug. It was `noteBase[slug]`,
/// which could only ever answer for one of them.
public struct SyncState: Codable, Sendable {
    /// Key to the content digest both sides agreed on last time. Keys are
    /// `note:<slug>` and `file:<name>`; see `noteKey` and `fileKey`.
    public var base: [String: String] = [:]

    public init() {}

    public static func noteKey(_ slug: String) -> String { "note:" + slug }
    public static func fileKey(_ name: String) -> String { "file:" + name }
    public static func sentKey(_ id: String) -> String { "sent:" + id }
    /// A voiceprint record this device owes the container a delete for,
    /// because the recording's bank emptied or its file went with the folder.
    /// Its own prefix, disjoint from `sent:`, so the deletion scan in
    /// `pushDeletions` never mistakes one for a recording stamp.
    public static func r6DropKey(_ id: String) -> String { "r6drop:" + id }
    /// Which device the container last said holds a recording's audio.
    ///
    /// Bookkeeping about the container, like `sent:`, and part of no decision
    /// the sync takes: `audioOn` on the record is still the only thing the
    /// reclaim invariant reads. This is here so a device **without** the audio
    /// can say where it went, which nothing could do before. Its own prefix,
    /// disjoint from `sent:` and `note:`, because `pushDeletions` walks those
    /// two and treats a stamp whose folder has gone as a deletion to send.
    public static func audioOnKey(_ id: String) -> String { "audioOn:" + id }

    public subscript(note slug: String) -> String? {
        get { base[SyncState.noteKey(slug)] }
        set { base[SyncState.noteKey(slug)] = newValue }
    }

    public subscript(file name: String) -> String? {
        get { base[SyncState.fileKey(name)] }
        set { base[SyncState.fileKey(name)] = newValue }
    }

    /// What this device last put in the container for a recording, as a stamp
    /// over its own files. Not a three-way base and not part of any decision:
    /// purely "there is no point asking the server about this one".
    public subscript(sent id: String) -> String? {
        get { base[SyncState.sentKey(id)] }
        set { base[SyncState.sentKey(id)] = newValue }
    }

    /// The device id in the record's `audioOn`, as of the last pull that
    /// mentioned it. Nil means the container has never named a holder, which
    /// is a phone recording still in flight rather than one that has landed.
    public subscript(audioOn id: String) -> String? {
        get { base[SyncState.audioOnKey(id)] }
        set { base[SyncState.audioOnKey(id)] = newValue }
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey { case base, noteBase }

    /// Reads the old `noteBase` shape as well as the current one.
    ///
    /// Cheap, and worth it: dropping a state file loses every agreed version at
    /// once, and a note whose base is unknown while the two copies differ is
    /// reported as a conflict rather than resolved. The migration turns that
    /// from "a conflict on every note this device has ever edited" into
    /// nothing happening at all.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let current = try? c.decodeIfPresent([String: String].self, forKey: .base) {
            base = current
            return
        }
        let old = (try? c.decodeIfPresent([String: String].self, forKey: .noteBase)) ?? [:]
        base = Dictionary(uniqueKeysWithValues: old.map { (SyncState.noteKey($0.key), $0.value) })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(base, forKey: .base)
    }

    static func url(in library: Library) -> URL {
        library.root.appendingPathComponent(".sync-state.json")
    }

    public static func load(_ library: Library) -> SyncState {
        guard let data = try? Data(contentsOf: url(in: library)),
              let state = try? JSONDecoder().decode(SyncState.self, from: data)
        else { return SyncState() }
        return state
    }

    public func save(_ library: Library) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: SyncState.url(in: library), options: .atomic)
    }
}

/// What to do with one note this pass.
public enum NoteAction: Equatable, Sendable {
    case nothing
    case pull
    case push
    case conflict
}

/// The whole decision, as a function of three strings, so it can be reasoned
/// about and tested without a network.
public func decideNote(base: String?, local: String?, remote: String?) -> NoteAction {
    switch (local, remote) {
    case (nil, nil): return .nothing
    case (nil, .some): return .pull            // never seen here
    case (.some, nil):
        // Absent there. If we had agreed on a version it has been deleted on
        // the Mac, and deleting a note is not something this sync does, so
        // pushing it back is the safe reading rather than deleting it here.
        return .push
    case (.some(let l), .some(let r)):
        if l == r { return .nothing }
        guard let base else { return .conflict }   // both new, same slug
        if l == base { return .pull }
        if r == base { return .push }
        return .conflict
    }
}
