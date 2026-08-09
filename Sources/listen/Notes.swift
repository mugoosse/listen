import Foundation

/// One note artifact, about one or more recordings.
///
/// The plural is the point. "Summarise everything with Edgar in June" spans four
/// meetings, and a note that could only belong to one of them had three bad
/// homes for that answer and no good one: pick a recording arbitrarily,
/// duplicate the note into all four and keep them in sync by hand, or do not
/// write it down. **A note with one source is the common case, not a special
/// case**, so `recordings` is an array all the way down and a single-meeting
/// note is an array of one.
struct Note {
    /// The filename stem, and the identity. Unique across the whole library,
    /// derived from the title when the note is created and never changed
    /// afterwards, so an edit cannot move a file out from under whoever is
    /// holding its name.
    var slug: String
    var title: String
    /// ISO 8601, the same shape `metadata.recorded_at` uses.
    var created: String
    var updated: String
    /// Who wrote it. One of `Notes.Source`, but stored as a string so a note
    /// written by something that does not exist yet still reads.
    var source: String
    /// What was asked for, when an agent wrote it.
    ///
    /// This is the template, and it is why there is no template feature. A
    /// prompt says what the note is for in the words somebody actually used,
    /// and it travels with the artifact rather than living in a settings pane.
    var prompt: String?
    /// The recordings this note is about, as ids, in the order they were given.
    ///
    /// Stated by whoever wrote the note and never inferred. Nothing here parses
    /// the body looking for links, and nothing guesses that two notes are
    /// related because they mention the same person.
    var recordings: [String]
    var body: String

    /// The whole file as it sits on disk, frontmatter included.
    var fileText: String { Notes.encode(self) }

    func isAbout(_ id: String) -> Bool { recordings.contains(id) }
}

/// Reading and writing the note artifacts in the library.
///
/// One owner, three callers: the CLI, the MCP server and the detail pane all
/// come through here, which is the rule `TranscriptEditor` already sets for
/// transcript edits. A second writer is a second idea of what a note is, and
/// with no test target nothing would catch the day the two stopped agreeing.
///
/// **They live beside the recordings rather than inside one**, at
/// `~/Library/Application Support/Listen/notes/<slug>.md`, which is the
/// arrangement `dictionary.json` and `contacts.json` already have and for the
/// same reason: they are about the library as a whole. A note filed under one
/// recording could only ever be about that recording.
///
/// Markdown files rather than one JSON blob, for the reason the library has no
/// database. A note is greppable, openable in any editor, and deleting one in
/// Finder is a supported operation rather than a corruption. The cost is that
/// the frontmatter parser has to survive a file somebody hand-wrote, which is
/// why `decode` falls back to treating a file with no frontmatter as a note
/// rather than refusing it.
enum Notes {
    /// The slug of the note the user types into, one per recording.
    ///
    /// The id is in the slug because slugs are unique across the library:
    /// two recordings would otherwise both want `yours.md` and the second
    /// would silently become `yours-2`, which nothing could find again.
    static func yoursSlug(for id: String) -> String { "\(id)-yours" }

    /// What the user's own note is called on screen.
    ///
    /// Not "private". That names a sharing model this app does not have, and
    /// would be a lie the day anything syncs. "Yours" is a claim about who
    /// wrote it, which is true now and stays true.
    static let yoursTitle = "Your notes"

    /// Who wrote a note. `agent` covers both MCP and anything else driving the
    /// CLI on an agent's behalf, because from the file's point of view they are
    /// the same writer.
    enum Source: String {
        /// An agent, through MCP.
        case agent
        /// A human at a terminal.
        case cli
        /// A human, in the window. **An agent may read these and not write
        /// them**, which is the one asymmetry in the note surface.
        case you
    }

    /// The user's own thinking, which nothing else may overwrite.
    static func isYours(_ note: Note) -> Bool { note.source == Source.you.rawValue }

    enum Failure: Error, LocalizedError {
        case noSuchNote(String)
        case emptyTitle
        case emptyBody
        case noRecordings
        case noSuchRecording(String)
        case changed(String)
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .noSuchNote(let name):
                return "no note `\(name)` in the library"
            case .emptyTitle:
                return "a note needs a title"
            case .emptyBody:
                return "a note needs a body. An empty note is a deletion, "
                    + "and deleting is its own verb."
            case .noRecordings:
                return "a note needs at least one recording to be about. "
                    + "A note nothing points at is one nothing can find."
            case .noSuchRecording(let id):
                return "no recording `\(id)`"
            case .changed(let slug):
                return "`\(slug)` has changed since you read it, so the edit was "
                    + "refused rather than applied on top of somebody else's. "
                    + "Read it again and rebase."
            case .cannotWrite(let message):
                return message
            }
        }
    }

    // MARK: - Reading

    /// Every note in the library, newest first.
    ///
    /// Newest first because an unfiltered list is a feed: the interesting note
    /// is the one somebody just asked for. A list filtered to one recording is
    /// a different question and comes back in a different order, see `list`.
    static func all() -> [Note] {
        // Reading anything is what triggers the one-time move of notes that
        // were written under the old per-recording layout.
        _ = migration

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Library.notes, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap(read)
            .sorted { ($0.created, $0.slug) > ($1.created, $1.slug) }
    }

    /// The notes about one recording: the user's own first, then oldest first.
    ///
    /// Oldest first because that is the order somebody reads them in: what they
    /// thought at the time, then what has been asked for since. Their own note
    /// is pinned rather than left to sort by date, because it is the default
    /// selection and it is written during the meeting, so a note added
    /// afterwards would otherwise displace it.
    ///
    /// No index and no cache, for the reason `People` has none: this reads one
    /// directory of small files, which is less work than the transcript search
    /// the sidebar already does on every keystroke.
    static func list(about recording: Recording) -> [Note] {
        let yours = yoursSlug(for: recording.id)
        return all()
            .filter { $0.isAbout(recording.id) }
            .sorted {
                if ($0.slug == yours) != ($1.slug == yours) { return $0.slug == yours }
                return ($0.created, $0.slug) < ($1.created, $1.slug)
            }
    }

    // MARK: - The user's own note

    /// What the user typed during this meeting, if they typed anything.
    static func yours(for recording: Recording) -> Note? {
        guard let note = find(yoursSlug(for: recording.id)), isYours(note) else { return nil }
        return note
    }

    /// The user's note for a recording, real or not yet written.
    ///
    /// Returns an unsaved note when there is no file, so the pane can put a
    /// cursor in front of somebody without a "New note" button and without a
    /// naming step. An empty note is not written to disk: a library of 36
    /// files nobody typed into is worse than none.
    static func yoursOrEmpty(for recording: Recording) -> Note {
        yours(for: recording)
            ?? Note(slug: yoursSlug(for: recording.id), title: yoursTitle,
                    created: "", updated: "", source: Source.you.rawValue,
                    prompt: nil, recordings: [recording.id], body: "")
    }

    /// Write what the user typed. Empty means delete.
    ///
    /// The whole lifecycle of their note is here, because the first keystroke
    /// creating a file and the last deletion removing one are the same
    /// decision seen from two ends. Deleting on empty is what keeps the library
    /// honest: a note somebody cleared is a note they do not have, and leaving
    /// an empty file behind would put a row in every list that says nothing.
    ///
    /// It does **not** go through `create`/`replace` guarded by `checked`,
    /// because their note exists while the recording is still in `staging/` and
    /// `Recording.all()` cannot see a staged recording. The id survives
    /// `promote()` unchanged, so a note keyed on it needs no fixing up when the
    /// meeting joins the library.
    @discardableResult
    static func setYours(_ body: String, for recording: Recording) throws -> Note? {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = yoursSlug(for: recording.id)
        let existing = find(slug)

        guard !body.isEmpty else {
            if existing != nil { _ = try delete(slug) }
            return nil
        }
        guard var note = existing else {
            let now = Metadata.iso(Date())
            let made = Note(slug: slug, title: yoursTitle, created: now, updated: now,
                            source: Source.you.rawValue, prompt: nil,
                            recordings: [recording.id], body: body)
            try save(made)
            return made
        }
        guard note.body.trimmingCharacters(in: .whitespacesAndNewlines) != body else {
            return note
        }
        note.body = body
        note.source = Source.you.rawValue
        note.updated = Metadata.iso(Date())
        if !note.isAbout(recording.id) { note.recordings.append(recording.id) }
        try save(note)
        return note
    }

    /// One note, by slug or by title.
    ///
    /// By title as well, because a slug is a thing this app invented and a
    /// title is the thing somebody has in front of them. Matching is
    /// case-insensitive for the same reason `SpeakerName.matches` is: the name
    /// is being passed through from something a human typed.
    ///
    /// `about` narrows the search to one recording's notes first, which is what
    /// makes a shared title work as a name: every recording has a note titled
    /// "Your notes" and only the slug says which.
    static func find(_ name: String, about recording: Recording? = nil) -> Note? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let everything = all()
        if let recording {
            let mine = everything.filter { $0.isAbout(recording.id) }
            if let hit = match(wanted, in: mine) { return hit }
        }
        return match(wanted, in: everything)
    }

    private static func match(_ wanted: String, in notes: [Note]) -> Note? {
        if let exact = notes.first(where: { $0.slug == wanted }) { return exact }
        return notes.first {
            $0.slug.caseInsensitiveCompare(wanted) == .orderedSame
                || $0.title.caseInsensitiveCompare(wanted) == .orderedSame
        }
    }

    /// The title of each recording a note is about, and the bare id for one the
    /// library no longer has.
    ///
    /// **An unresolved id stays on the page rather than being cleaned up.** A
    /// note about four meetings must not lose a quarter of its provenance
    /// because one of them was deleted, and silently dropping the id would make
    /// the note claim it was only ever about three.
    static func sources(of note: Note) -> [(id: String, title: String?)] {
        // Staged as well as in the library. The user's note is editable while
        // the meeting is still being recorded, and a recording in progress is
        // in `staging/` where `Recording.all()` cannot see it: without this its
        // own note would report the meeting it is being typed into as one the
        // library no longer has.
        let library = Recording.all() + Recording.staged()
        return note.recordings.map { id in
            (id: id, title: library.first { $0.id == id }?.metadata.title)
        }
    }

    // MARK: - Writing

    /// Create a note. Never overwrites: a colliding slug is numbered.
    ///
    /// Numbered rather than refused, because the caller most likely to hit a
    /// collision is an agent asked twice for "action items", and refusing it
    /// means it has to invent a name that is worse than the one it had. Nothing
    /// is lost either way, and this direction cannot destroy a note.
    ///
    /// `requiringSources` is the one thing a caller may relax, and only the
    /// window does. An agent writing over MCP is *stating* what its note is
    /// about, so a write with no `recordings` there is a claim it forgot to
    /// make. A person pressing `Save as note` on an answer about the whole
    /// library is making no such claim: there is no meeting to name, and
    /// refusing the note left the button doing nothing at all. A note about
    /// nothing is a page in its own right, which is what the sidebar's
    /// `pageless` already says.
    @discardableResult
    static func create(title: String, body: String, source: Source,
                       prompt: String? = nil, recordings: [String],
                       requiringSources: Bool = true) throws -> Note {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure.emptyTitle }
        guard !body.isEmpty else { throw Failure.emptyBody }
        let recordings = try checked(recordings, requiring: requiringSources)

        let now = Metadata.iso(Date())
        let note = Note(slug: unique(slug(for: title)), title: title,
                        created: now, updated: now, source: source.rawValue,
                        prompt: prompt?.isEmpty == true ? nil : prompt,
                        recordings: recordings, body: body)
        try save(note)
        return note
    }

    /// Rewrite an existing note.
    ///
    /// `expecting` is the compare-and-swap. The window and an agent can both be
    /// holding the same note, and the one who read it first would otherwise
    /// write over an edit it never saw, with nothing anywhere reporting that it
    /// happened. Pass the body as it was read and the write is refused if it no
    /// longer matches, which is `TranscriptEditor.retext` one layer up.
    ///
    /// It is optional rather than required because a person at a terminal is
    /// not a concurrent writer and cannot reasonably paste back the body they
    /// are replacing. The MCP surface requires it, which is the surface where
    /// two writers actually meet.
    ///
    /// `created` and the slug survive. An edit is the same artifact, and a note
    /// whose filename moved when its title was corrected would break every link
    /// to it. `recordings` survives too unless it is given: adding a paragraph
    /// is not a claim about what the note is about.
    @discardableResult
    static func replace(_ name: String, body: String, title: String? = nil,
                        prompt: String? = nil, source: Source? = nil,
                        recordings: [String]? = nil,
                        expecting: String? = nil) throws -> Note {
        guard var note = find(name) else { throw Failure.noSuchNote(name) }
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Failure.emptyBody }

        if let expecting {
            // Trimmed on both sides, for the reason `retext` trims: the copy
            // the caller is holding came back from `read`, which returns the
            // trimmed body, and a file hand-edited in another editor gains a
            // trailing newline that nobody typed.
            let now = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard now == expecting.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw Failure.changed(note.slug)
            }
        }

        note.body = body
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            note.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let prompt { note.prompt = prompt.isEmpty ? nil : prompt }
        if let source { note.source = source.rawValue }
        if let recordings { note.recordings = try checked(recordings) }
        note.updated = Metadata.iso(Date())
        try save(note)
        return note
    }

    /// Delete a note, and say which one went.
    @discardableResult
    static func delete(_ name: String) throws -> Note {
        guard let note = find(name) else { throw Failure.noSuchNote(name) }
        do {
            try FileManager.default.removeItem(at: url(for: note.slug))
        } catch {
            throw Failure.cannotWrite(
                "could not delete `\(note.slug)`: \(error.localizedDescription)")
        }
        return note
    }

    /// Every id must name a recording that exists **at the moment it is
    /// claimed**, and unless the caller says otherwise there must be at least
    /// one.
    ///
    /// Checked on the way in and never again. A note that outlives a recording
    /// keeps naming it, which is the point: a synthesis of four meetings must
    /// not lose a source because one was deleted. What this stops is a typo
    /// becoming a note nobody can find from any recording.
    private static func checked(_ ids: [String],
                               requiring atLeastOne: Bool = true) throws -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let library = Recording.all()
        for id in ids.map({ $0.trimmingCharacters(in: .whitespaces) }) where !id.isEmpty {
            guard library.contains(where: { $0.id == id }) else {
                throw Failure.noSuchRecording(id)
            }
            if seen.insert(id).inserted { out.append(id) }
        }
        guard !out.isEmpty || !atLeastOne else { throw Failure.noRecordings }
        return out
    }

    // MARK: - Files

    static func url(for slug: String) -> URL {
        Library.notes.appendingPathComponent(slug + ".md")
    }

    private static func read(_ url: URL) -> Note? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // The file's own date, for a note dropped in by hand with no
        // frontmatter. Without it such a note has an empty `created`, which
        // sorts before everything and shows no date on screen, and neither is
        // true: the filesystem knows when it arrived.
        let modified = try? url.resourceValues(
            forKeys: [.contentModificationDateKey]).contentModificationDate
        return decode(text, slug: url.deletingPathExtension().lastPathComponent,
                      modified: modified ?? nil)
    }

    private static func save(_ note: Note) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Library.notes, withIntermediateDirectories: true)
            // Atomic, for the reason every other write in this library is: a
            // note half-written by a crash is a note that reads as finished.
            try encode(note).data(using: .utf8)!
                .write(to: url(for: note.slug), options: .atomic)
        } catch {
            throw Failure.cannotWrite(
                "could not write `\(note.slug)`: \(error.localizedDescription)")
        }
    }

    /// A filename stem from a title.
    ///
    /// Lowercase ASCII words joined by hyphens, capped at 48 characters. The cap
    /// is not a filesystem limit, it is so `ls` in the notes folder stays
    /// readable: an agent asked for a note will happily title it a sentence.
    static func slug(for title: String) -> String {
        let folded = title
            .folding(options: [.diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        var out = ""
        var pendingHyphen = false
        for character in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(character), character.isASCII {
                if pendingHyphen, !out.isEmpty { out.append("-") }
                pendingHyphen = false
                out.unicodeScalars.append(character)
            } else {
                pendingHyphen = true
            }
            if out.count >= 48 { break }
        }
        // A title made entirely of characters this drops is a real possibility
        // once anybody writes in a script that is not Latin, and a file called
        // `.md` is not a file.
        return out.isEmpty ? "note" : out
    }

    /// The first slug in the `slug`, `slug-2`, `slug-3` series that is free.
    private static func unique(_ slug: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url(for: slug).path) else { return slug }
        for n in 2...99 {
            let candidate = "\(slug)-\(n)"
            if !fm.fileExists(atPath: url(for: candidate).path) { return candidate }
        }
        // A hundred notes with the same title is not a case worth a nicer
        // answer than a timestamp, but it must still not overwrite one.
        return "\(slug)-\(Int(Date().timeIntervalSince1970))"
    }

    // MARK: - Moving the old layout

    /// Runs exactly once per process, the first time anything reads a note.
    ///
    /// A `static let` is initialised lazily and exactly once by the runtime,
    /// which is the whole synchronisation this needs: `Notes` is read from the
    /// pipeline actor, the main actor and the CLI, and there is no single
    /// startup path that all three go through. Nothing writes to the old layout
    /// any more, so once per process is once.
    private static let migration: Int = migrate()

    /// Move `recordings/<id>/notes/*.md` to `notes/`, keeping every field.
    ///
    /// Moved rather than rewritten: `created`, `updated`, `source` and `prompt`
    /// all come across unchanged, so a note somebody edited arrives still
    /// looking edited.
    ///
    /// Idempotent, and free after the first run: with no `notes` directory
    /// inside any recording there is nothing to list.
    @discardableResult
    static func migrate() -> Int {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: Library.recordings, includingPropertiesForKeys: nil) else { return 0 }

        var moved = 0
        for folder in folders {
            let old = folder.appendingPathComponent("notes")
            guard let files = try? fm.contentsOfDirectory(
                at: old, includingPropertiesForKeys: nil) else { continue }
            let id = folder.lastPathComponent

            for file in files where file.pathExtension.lowercased() == "md" {
                guard var note = read(file) else { continue }
                // The slug it had, uniquified: it is the readable half of the
                // filename, and two recordings rarely name a note the same
                // thing.
                note.slug = unique(note.slug)
                note.recordings = [id]
                guard (try? save(note)) != nil else { continue }
                try? fm.removeItem(at: file)
                moved += 1
            }
            // Only when it is empty. A folder with something else in it is
            // somebody's, not ours.
            if let left = try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil),
               left.isEmpty {
                try? fm.removeItem(at: old)
            }
        }
        if moved > 0 {
            log("moved \(moved) note(s) out of the recording folders into "
                + Library.notes.path)
        }
        return moved
    }

    // MARK: - Frontmatter

    /// The file as it goes to disk: a YAML frontmatter block, then the body.
    ///
    /// Values are written double-quoted and escaped, always, rather than only
    /// when they need it. A title is free text and will eventually contain a
    /// colon, a leading `#`, or the word `yes`, each of which changes what an
    /// unquoted YAML scalar means. Quoting everything costs two characters and
    /// removes the class.
    static func encode(_ note: Note) -> String {
        var out = "---\n"
        out += "title: \(quoted(note.title))\n"
        out += "created: \(note.created)\n"
        out += "updated: \(note.updated)\n"
        out += "source: \(note.source)\n"
        if let prompt = note.prompt, !prompt.isEmpty {
            out += "prompt: \(quoted(prompt))\n"
        }
        // A flow sequence on one line, so `grep -l 2026-08-05 notes/*.md`
        // answers "which notes are about this meeting" without a parser.
        out += "recordings: [\(note.recordings.map(quoted).joined(separator: ", "))]\n"
        out += "---\n\n"
        return out + note.body + "\n"
    }

    /// Read a note file.
    ///
    /// A file with no frontmatter is still a note. The whole argument for
    /// markdown on disk is that somebody can drop a file into the folder in
    /// Finder, and refusing that file would make the promise false. It gets its
    /// title from its first heading or its slug, and `source: you`, because a
    /// file this app did not write was written by a person.
    static func decode(_ text: String, slug: String, modified: Date? = nil) -> Note? {
        var fields: [String: String] = [:]
        var listed: [String: [String]] = [:]
        var body = text

        // Line by line rather than by searching for the closing delimiter,
        // because the terminator is a line that is exactly `---` and a body
        // containing a horizontal rule must not be able to end the block.
        let lines = text.components(separatedBy: "\n")
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            var lastKey = ""
            for line in lines[1..<end] {
                // A block sequence under the previous key, which is how a person
                // writing this by hand would list recordings. The flow form on
                // one line is what `encode` writes; both are read.
                let bare = line.trimmingCharacters(in: .whitespaces)
                if bare.hasPrefix("- "), !lastKey.isEmpty {
                    listed[lastKey, default: []].append(
                        unquoted(String(bare.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                    continue
                }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                lastKey = key
                if !value.isEmpty { fields[key] = unquoted(value) }
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }

        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !fields.isEmpty else { return nil }

        let fallbackTitle = heading(in: body) ?? slug
        let fallbackDate = modified.map(Metadata.iso) ?? ""
        return Note(slug: slug,
                    title: fields["title"] ?? fallbackTitle,
                    created: fields["created"] ?? fallbackDate,
                    updated: fields["updated"] ?? fields["created"] ?? fallbackDate,
                    source: fields["source"] ?? Source.you.rawValue,
                    prompt: fields["prompt"],
                    recordings: listed["recordings"]
                        ?? sequence(fields["recordings"] ?? ""),
                    body: body)
    }

    /// `["a", "b"]`, or a bare `a`, into `["a", "b"]`.
    private static func sequence(_ value: String) -> [String] {
        var text = value.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), text.hasSuffix("]") {
            text = String(text.dropFirst().dropLast())
        }
        return text.split(separator: ",")
            .map { unquoted($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    /// The first ATX heading, for a hand-written file with no title field.
    private static func heading(in body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("#") else { continue }
            let text = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func quoted(_ value: String) -> String {
        var out = "\""
        for character in value {
            switch character {
            case "\\":   out += "\\\\"
            case "\"":   out += "\\\""
            case "\n":   out += "\\n"
            case "\r":   out += "\\r"
            case "\t":   out += "\\t"
            default:     out.append(character)
            }
        }
        return out + "\""
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }
        var out = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped {
                switch character {
                case "n":  out += "\n"
                case "r":  out += "\r"
                case "t":  out += "\t"
                default:   out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        return out
    }
}
