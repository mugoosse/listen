import Foundation

/// The library, on whichever device is asking.
///
/// The same type on both, because the layout is the same on both. On the Mac
/// it points at `~/Library/Application Support/Listen` (or wherever
/// `LISTEN_LIBRARY` says); on the phone it points inside the app container.
/// There is no database on either, which is what makes a folder appearing out
/// of nowhere a complete and valid way to add a recording.
public struct Library: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    /// The Mac's real library, honouring `LISTEN_LIBRARY` exactly as Listen
    /// and its CLI do, so a scratch library works here too.
    public static func mac() -> Library {
        if let override = ProcessInfo.processInfo.environment["LISTEN_LIBRARY"], !override.isEmpty {
            return Library(root: URL(fileURLWithPath: override))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return Library(root: support.appendingPathComponent("Listen"))
    }

    /// The phone's library, inside the app container so it is covered by the
    /// device passcode and excluded from unencrypted backups by default.
    public static func phone() -> Library {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return Library(root: support.appendingPathComponent("Listen"))
    }

    public var recordings: URL { root.appendingPathComponent("recordings") }
    public var staging: URL { root.appendingPathComponent("staging") }
    public var notes: URL { root.appendingPathComponent("notes") }

    public func prepare() throws {
        for dir in [recordings, staging, notes] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Every recording, newest first. `compactMap` is load-bearing: a folder
    /// mid-transfer has no metadata yet and must be absent rather than broken.
    public func all() -> [Recording] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: recordings, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap(Recording.load).sorted { $0.id > $1.id }
    }

    public func find(_ id: String) -> Recording? {
        guard Metadata.isValidID(id) else { return nil }
        return Recording.load(recordings.appendingPathComponent(id))
    }

    /// Where a recording lives. **The caller must have checked the id**, with
    /// `Metadata.isValidID`, before this point: `appendingPathComponent`
    /// resolves `..`, so this happily addresses a directory outside the
    /// library. Every caller that takes an id from another device validates it
    /// at the boundary, and the accessors on this type that can report failure
    /// (`find`, `note`, `writeNote`, `deleteNote`) check it themselves.
    public func folder(for id: String) -> URL { recordings.appendingPathComponent(id) }

    // MARK: - Notes

    public func deleteNote(_ slug: String) {
        guard Note.isValidSlug(slug) else { return }
        try? FileManager.default.removeItem(at: notes.appendingPathComponent(slug + ".md"))
    }

    public func allNotes() -> [Note] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: notes, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { $0.pathExtension == "md" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return Note.parse(slug: url.deletingPathExtension().lastPathComponent, text,
                              modified: Library.modified(url))
        }.sorted { $0.updated > $1.updated }
    }

    public func note(_ slug: String) -> Note? {
        guard Note.isValidSlug(slug) else { return nil }
        let url = notes.appendingPathComponent(slug + ".md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Note.parse(slug: slug, text, modified: Library.modified(url))
    }

    /// When a file last changed, for a note that carries no timestamps of its
    /// own. A hand-written note has no frontmatter to say when it was made, and
    /// the filesystem is the only thing that knows.
    static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// Write a note, refusing if somebody else has written it since the caller
    /// read it.
    ///
    /// The compare-and-swap the MCP server already performs, in the one place
    /// both devices can reach. `expecting` is the `updated` the caller last
    /// saw; nil means "this is new, fail if it exists". Losing throws with the
    /// winning copy attached so the caller can show both, because a conflict
    /// the user cannot see is a conflict resolved by coin toss.
    ///
    /// **`stamp` decides who owns the timestamp, and it is not cosmetic.**
    /// A local edit is a new version and takes `now`. A note *arriving* from
    /// the other device must keep the timestamp it came with, or the receiver's
    /// copy is instantly newer than the sender's and pushes itself straight
    /// back on the next pass. Measured: with `stamp` unconditionally true, one
    /// pull produced a spurious push of unchanged content on every subsequent
    /// sync, for ever.
    public func writeNote(_ note: Note, expecting: String?, stamp: Bool = true) throws {
        guard Note.isValidSlug(note.slug) else { throw InvalidName.slug(note.slug) }
        var note = note
        if let existing = self.note(note.slug) {
            // Against `version`, never `updated`: see `Note.version`.
            guard let expecting, expecting == existing.version else {
                throw NoteConflict(theirs: existing)
            }
            // **Absent means unchanged, not deleted.**
            //
            // The last line of defence for provenance, and the one that works
            // against a device this version cannot fix. A caller that does not
            // model `prompt` or `chat` sends them absent, and writing that
            // literally is how they were being deleted: an older phone parses a
            // note, drops the two keys it has never heard of, and pushes back
            // something that looks like a deliberate erasure and is not.
            //
            // Nothing anywhere clears provenance on purpose, so treating absent
            // as "keep what is on disk" costs nothing and closes the hole for
            // every client, including the ones already installed.
            if note.prompt == nil { note.prompt = existing.prompt }
            if note.chat == nil { note.chat = existing.chat }
            note.extra = existing.extra.merging(note.extra) { _, incoming in incoming }
        } else if expecting != nil {
            throw NoteConflict(theirs: Note(slug: note.slug, title: note.title,
                                            created: note.created, updated: "",
                                            source: note.source,
                                            recordings: note.recordings, body: ""))
        }
        if stamp { note.updated = Metadata.stamp(Date()) }
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try note.serialised().write(to: notes.appendingPathComponent(note.slug + ".md"),
                                    atomically: true, encoding: .utf8)
    }
}

/// A name that would have become a path outside the library.
///
/// Its own error rather than a refusal string, because the two devices are not
/// the only callers: an id or a slug also arrives from a sealed record, and
/// whatever is holding it there needs to be able to tell this apart from a
/// conflict or a missing file. See `Metadata.isValidID` for what this guards.
public enum InvalidName: Error, LocalizedError, Sendable {
    case id(String)
    case slug(String)

    public var errorDescription: String? {
        switch self {
        case .id(let name): return "\"\(name)\" is not a recording id."
        case .slug(let name): return "\"\(name)\" is not a note name."
        }
    }
}
