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
/// **A recording's sidecars needed none of this, and that was wrong.** The claim
/// was that a transcript has exactly one writer, the Mac that made it. It has
/// one *author*; it has as many editors as there are devices showing the
/// transcript, because correcting who said a sentence rewrites `transcript.json`
/// and `turns.json` on whichever Mac you are sitting at.
///
/// What that cost, measured on a real library: a speaker was corrected at
/// 21:27:19, and at 21:28:14 `transcript.json` and `turns.json` were rewritten
/// by a pull with the container's older copy, while `metadata.json` kept its
/// 21:27 time because it had not changed. The correction was gone from the
/// screen while its author was looking at it. Nothing failed, nothing was
/// reported, and the push that followed found local and remote in agreement and
/// sent nothing.
///
/// The shape of it is exactly the one this file was written for. A pull runs
/// before a push, deliberately, so a Mac that has been shut for a week cannot
/// overwrite a week of work. Until the push lands, the container still holds
/// the pre-edit transcript, so any pass that re-fetches that record, and a
/// second Mac pushing its own copy is enough to cause one, sees local and
/// remote disagree with no way to tell which is newer. Two values cannot
/// distinguish "I am behind" from "I have an edit nobody has seen".
///
/// So sidecars are keyed here too, per file, and the table above applies to
/// them unchanged. `metadata.json` is the exception and keeps its own rule, the
/// `authored` guard in `pullRecording`.
///
/// The library-level files in `DevicePolicy.blobs` want this as well, as soon
/// as there is a second Mac, because `contacts.json` and `dictionary.json` are
/// both edited on whichever machine you happen to be sitting at.
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
    /// The digest of one of a recording's sidecars, as both sides last agreed
    /// it. Its own prefix, disjoint from `sent:` and `note:`, because
    /// `pushDeletions` walks those two and reads a stamp with no folder as a
    /// deletion to send.
    public static func sidecarKey(_ id: String, _ file: String) -> String {
        "sidecar:" + id + "/" + file
    }
    public static func sentKey(_ id: String) -> String { "sent:" + id }
    /// A voiceprint record this device owes the container a delete for,
    /// because the recording's bank emptied or its file went with the folder.
    /// Its own prefix, disjoint from `sent:`, so the deletion scan in
    /// `pushDeletions` never mistakes one for a recording stamp.
    public static func r6DropKey(_ id: String) -> String { "r6drop:" + id }
    /// A master record this device owes the container a delete for, because
    /// the recording it belonged to has gone. Its own prefix for the same
    /// reason `r6drop:` has one.
    public static func r5DropKey(_ id: String) -> String { "r5drop:" + id }
    /// The digest of the audio master this device knows is in the container.
    ///
    /// A stamp about the container, like `sent:`, and it is what stops every
    /// pass asking about every recording: a master is 25 MB and both "is it
    /// there" and "give it to me" cost the same fetch, so the cheap question
    /// has to be answered locally. Written after a push that landed and after
    /// a pull that verified, and cleared when the recording is deleted. Its
    /// own prefix, disjoint from `sent:` and `note:`, because `pushDeletions`
    /// walks those two and reads a stamp with no folder as a deletion to send.
    public static func masterKey(_ id: String) -> String { "master:" + id }
    /// A recording whose audio this device was **asked** to keep, one at a
    /// time, whatever the device-wide switch says.
    ///
    /// The device switch is a policy and this is an instruction, and the two
    /// have to be separable or the phone cannot have both. **Keep audio on
    /// this iPhone** is off by default and means "keep what I recorded"; it
    /// deliberately does not mean "download every meeting my Macs made", which
    /// is gigabytes. So asking for one recording's audio has to leave a mark
    /// that `reclaim` reads, or the next pass takes back what the tap just
    /// fetched and the button appears not to work.
    public static func pinKey(_ id: String) -> String { "pin:" + id }
    /// Which device the container last said holds a recording's audio.
    ///
    /// Bookkeeping about the container, like `sent:`, and part of no decision
    /// the sync takes: `audioOn` on the record is still the only thing the
    /// reclaim invariant reads. This is here so a device **without** the audio
    /// can say where it went, which nothing could do before. Its own prefix,
    /// disjoint from `sent:` and `note:`, because `pushDeletions` walks those
    /// two and treats a stamp whose folder has gone as a deletion to send.
    public static func audioOnKey(_ id: String) -> String { "audioOn:" + id }
    /// A recording whose row has arrived and whose sidecars have not.
    ///
    /// The two-phase pull takes the change feed without its asset bodies, so
    /// the title is on the screen while the transcript is still in the
    /// container. The change token has moved on by then, and the feed will
    /// never mention that record again, so this is the only thing that knows
    /// the transcript is still owed. It is cleared by the fetch that collects
    /// it, and it is what stops a push sending the half of the recording this
    /// device happens to hold. Its own prefix, disjoint from `sent:` and
    /// `note:`, because `pushDeletions` walks those two and reads a stamp with
    /// no folder as a deletion to send.
    public static func owedKey(_ id: String) -> String { "owed:" + id }

    public subscript(note slug: String) -> String? {
        get { base[SyncState.noteKey(slug)] }
        set { base[SyncState.noteKey(slug)] = newValue }
    }

    public subscript(file name: String) -> String? {
        get { base[SyncState.fileKey(name)] }
        set { base[SyncState.fileKey(name)] = newValue }
    }

    /// The agreed digest for one sidecar of one recording.
    ///
    /// Nil means the two sides have never been known to hold the same bytes,
    /// which is every file until the first pass that sends or receives it. A
    /// pull takes the remote copy in that case, because there is nothing to say
    /// the local one is an edit rather than an older copy, and stamps what it
    /// wrote so the next disagreement can be read properly.
    public subscript(sidecar id: String, file file: String) -> String? {
        get { base[SyncState.sidecarKey(id, file)] }
        set { base[SyncState.sidecarKey(id, file)] = newValue }
    }

    /// Forget every agreed digest for one recording, which is what a deletion
    /// leaves behind if nothing does it.
    public mutating func forgetSidecars(_ id: String) {
        let prefix = SyncState.sidecarKey(id, "")
        for key in base.keys where key.hasPrefix(prefix) { base[key] = nil }
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

    /// The digest of the master in the container, as far as this device knows.
    /// Nil means "ask", which is the state of every recording until a pass has
    /// either published one or fetched one.
    public subscript(master id: String) -> String? {
        get { base[SyncState.masterKey(id)] }
        set { base[SyncState.masterKey(id)] = newValue }
    }

    /// Whether this device was asked to keep this one recording's audio.
    public subscript(pinned id: String) -> Bool {
        get { base[SyncState.pinKey(id)] != nil }
        set { base[SyncState.pinKey(id)] = newValue ? "1" : nil }
    }

    /// Whether this recording's sidecars are still in the container.
    public subscript(owed id: String) -> Bool {
        get { base[SyncState.owedKey(id)] != nil }
        set { base[SyncState.owedKey(id)] = newValue ? "1" : nil }
    }

    /// Every recording still waiting for its contents, newest first.
    ///
    /// An id starts with the moment it was recorded, so sorting them backwards
    /// is chronological, and the order matters on a first sync: the recording
    /// somebody is waiting to read is the one at the top of the library, not
    /// the meeting from eleven months ago that happens to sort first.
    public var owing: [String] {
        base.keys
            .filter { $0.hasPrefix(SyncState.owedKey("")) }
            .map { String($0.dropFirst(SyncState.owedKey("").count)) }
            .sorted(by: >)
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
