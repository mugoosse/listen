import Foundation

/// One tag, across the whole library.
struct Tag {
    /// As written on disk, in the spelling the library settled on.
    let name: String
    /// Every recording carrying it, newest first.
    let recordings: [Recording]
    /// Every note carrying it, newest first.
    ///
    /// One vocabulary over two kinds of thing, which is the whole decision
    /// here: `kinsight` on a meeting and `kinsight` on the write-up of it are
    /// the same filing, so they share a spelling, a rename and a row in every
    /// list. What they do not share is inheritance. A note about a tagged
    /// meeting carries nothing until somebody tags the note, which is the rule
    /// `Notes` already keeps for `recordings`: it states its sources and
    /// nothing here guesses.
    let notes: [Note]

    /// Recordings only, because the four places that show this to somebody
    /// show it as a count of meetings.
    var count: Int { recordings.count }
    var noteCount: Int { notes.count }
    var total: Int { recordings.count + notes.count }

    /// "9 recordings", "9 recordings and 2 notes", "2 notes", for a list where
    /// the number is the only reason to pick one row over another.
    ///
    /// Both halves are named whenever both exist, and a tag only notes carry
    /// says so rather than reading as an empty row. That is the visible half of
    /// one shared vocabulary: a tag with no meetings under it still exists.
    var summary: String {
        let meetings = recordings.count == 1 ? "1 recording" : "\(recordings.count) recordings"
        let written = notes.count == 1 ? "1 note" : "\(notes.count) notes"
        if notes.isEmpty { return meetings }
        if recordings.isEmpty { return written }
        return meetings + " and " + written
    }
}

/// The one thing a tag can go on: a meeting, or a note about some.
///
/// An enum rather than a protocol, because there are exactly two and there is
/// not going to be a third. A tag is a claim about one artifact in this library
/// and those are the whole list, so a witness table would buy nothing that a
/// switch does not, and a reader would have to go and find the conformances to
/// learn what the list is.
///
/// It exists because four surfaces need to say "the thing being tagged" without
/// caring which: the CLI's `tags add`, the MCP resolver, the pill strip and its
/// popover. Before it, the strip was written against `Recording` and the only
/// way to give a note one was a second copy of the file.
enum Taggable {
    case recording(Recording)
    case note(Note)

    var tags: [String] {
        switch self {
        case .recording(let recording): return Tags.of(recording)
        case .note(let note):           return Tags.of(note)
        }
    }

    /// What to call it in a line about it.
    var id: String {
        switch self {
        case .recording(let recording): return recording.id
        case .note(let note):           return note.slug
        }
    }

    /// "Recording" or "Note", for the one menu item that names the kind.
    var kindWord: String {
        switch self {
        case .recording: return "Recording"
        case .note:      return "Note"
        }
    }

    /// The same thing read from disk again, or nil if it has gone.
    ///
    /// A write returns the new tag list, but the strip redraws from a subject,
    /// and the stale copy it was holding would show the tags it had before.
    var reloaded: Taggable? {
        switch self {
        case .recording(let recording):
            return Recording.find(recording.id).map(Taggable.recording)
        case .note(let note):
            return Notes.find(note.slug).map(Taggable.note)
        }
    }

    @discardableResult
    func adding(_ names: [String]) throws -> [String] {
        switch self {
        case .recording(let recording): return try Tags.add(names, to: recording)
        case .note(let note):           return try Tags.add(names, to: note)
        }
    }

    @discardableResult
    func removing(_ names: [String]) throws -> [String] {
        switch self {
        case .recording(let recording): return try Tags.remove(names, from: recording)
        case .note(let note):           return try Tags.remove(names, from: note)
        }
    }
}

/// What a library-wide tag edit actually reached.
///
/// A rename or a delete now touches two kinds of file, so a caller that
/// reported a count of recordings would under-report by exactly the notes it
/// had just rewritten. `People.rename`'s signature and its reason, one kind
/// wider.
struct Touched {
    var recordings: [String] = []
    var notes: [String] = []

    var isEmpty: Bool { recordings.isEmpty && notes.isEmpty }

    /// "3 recordings and 1 note", for a line that has to say how many.
    var summary: String {
        var parts: [String] = []
        if !recordings.isEmpty {
            parts.append(recordings.count == 1 ? "1 recording"
                         : "\(recordings.count) recordings")
        }
        if !notes.isEmpty {
            parts.append(notes.count == 1 ? "1 note" : "\(notes.count) notes")
        }
        return parts.isEmpty ? "nothing" : parts.joined(separator: " and ")
    }
}

/// What the recordings are about, in the user's own words.
///
/// The join key is the string written in `metadata.tags`, and nothing cleverer.
/// This is `People`'s rule applied to subjects instead of speakers: the
/// vocabulary is **derived** from the library on every call, so a tag nothing
/// carries does not exist. There is no `tags.json`, no create step, no orphan
/// row to clean up, and nothing that can disagree with the recordings.
///
/// The reason the field lives on the recording rather than in a library-level
/// file, which is the opposite of the call `Notes` made, is written on
/// `Metadata.tags`. In short: a note can be about four meetings and outlive all
/// of them, and a tag is a claim about one recording.
///
/// One owner, four callers: `listen tags`, the MCP tools, the tag strip in the
/// detail pane and the sidebar's lens all come through here. That is the rule
/// `Notes` and `TranscriptEditor` already set, and it matters more here than it
/// looks, because until this file existed **nothing owned a metadata edit at
/// all**: `metadata.title = …; try? save()` is written out in five places.
enum Tags {

    /// The longest a tag may be.
    ///
    /// Long enough for a phrase somebody would actually file under, short
    /// enough that a pill can never be the widest thing in the header. A tag is
    /// a name for a group of meetings; anything longer is a note.
    static let maxLength = 40

    /// Why a string cannot be a tag.
    enum Problem: LocalizedError {
        case empty
        case tooLong(String)
        case hasComma(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                return "A tag needs a name."
            case .tooLong(let name):
                return "\"\(name)\" is \(name.count) characters. A tag is a name for "
                    + "a group of meetings, so it stops at \(Tags.maxLength); "
                    + "anything longer belongs in a note."
            case .hasComma(let name):
                return "\"\(name)\" contains a comma. Tags are given one at a time, "
                    + "so a comma would only ever be read as a separator later."
            }
        }
    }

    // MARK: - The name

    /// Trim, drop a leading hash, and collapse internal whitespace.
    ///
    /// The hash goes because every other tag field anybody has used wanted one,
    /// so people type `#job hunt`. It is punctuation on the way in rather than
    /// part of the name, and keeping it would file `#job hunt` and `job hunt`
    /// as two tags that read identically in a pill.
    ///
    /// The whitespace collapse is the same argument: `job  hunt` and `job hunt`
    /// are indistinguishable on screen, and a tag pasted out of a document
    /// arrives with a newline in it.
    static func canonical(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("#") {
            text = String(text.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Check a tag before anything is written.
    static func check(_ raw: String) -> Problem? {
        let name = canonical(raw)
        if name.isEmpty { return .empty }
        if name.count > maxLength { return .tooLong(name) }
        // Refused rather than escaped. No tag today has a comma in it, and
        // forbidding one now is what keeps a comma-separated form from ever
        // being ambiguous. Repeating a flag rather than splitting on commas is
        // already this CLI's rule; this is the other half of it.
        if name.contains(",") { return .hasComma(name) }
        return nil
    }

    /// Does a stored tag answer to this name?
    ///
    /// Case and surrounding space are ignored, following `SpeakerName.matches`
    /// and for its reason: the name is passed through from something a human
    /// typed, and refusing `JOB HUNT` for `job hunt` would be a filter that
    /// silently returns nothing.
    static func matches(_ stored: String, _ wanted: String) -> Bool {
        let wanted = canonical(wanted)
        guard !wanted.isEmpty else { return false }
        return stored.caseInsensitiveCompare(wanted) == .orderedSame
    }

    /// Clean, deduplicate and sort a list of tags.
    ///
    /// Every read goes through here as well as every write, because a
    /// `metadata.json` is a file somebody can edit in a text editor and this is
    /// the same liberal-on-read rule `Notes.decode` and `CustomDictionary`
    /// follow. A hand-written duplicate or a stray empty string costs nothing
    /// rather than drawing an empty pill.
    static func tidy(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in names.map(canonical) where !name.isEmpty {
            guard seen.insert(name.lowercased()).inserted else { continue }
            out.append(name)
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Reading

    /// This recording's tags, cleaned and in the order they are drawn.
    static func of(_ recording: Recording) -> [String] {
        tidy(recording.metadata.tags ?? [])
    }

    /// This note's tags, cleaned the same way.
    ///
    /// `Notes.decode` has already tidied these, so this is the identity in
    /// practice. It exists so that a caller holding either kind of thing asks
    /// the same question of it, and so a hand-written file that reached here by
    /// some other route is not the one place the rule does not run.
    static func of(_ note: Note) -> [String] {
        tidy(note.tags)
    }

    /// Every tag in the library, most recordings first.
    ///
    /// **One vocabulary over recordings and notes.** Both are read here, so a
    /// tag only a note carries is a tag that exists, and `add` adopting the
    /// library's spelling works across the two: tagging a note `Kinsight` when
    /// a recording holds `kinsight` files it under the one that is there.
    ///
    /// `notes` is a parameter with a default for the same reason `library` is:
    /// the sidebar has already read both by the time it asks, and paying for a
    /// second directory walk per keystroke is the kind of thing that only shows
    /// up on somebody else's library.
    static func all(in library: [Recording] = Recording.all(),
                    notes: [Note] = Notes.all()) -> [Tag] {
        var carriers: [String: (recordings: [Recording], notes: [Note])] = [:]
        var spellings: [String: [String: Int]] = [:]
        for recording in library {
            for name in of(recording) {
                let key = name.lowercased()
                carriers[key, default: ([], [])].recordings.append(recording)
                spellings[key, default: [:]][name, default: 0] += 1
            }
        }
        for note in notes {
            for name in of(note) {
                let key = name.lowercased()
                carriers[key, default: ([], [])].notes.append(note)
                spellings[key, default: [:]][name, default: 0] += 1
            }
        }
        return carriers.map { key, carrying in
            // Two spellings of one tag should only ever come from a hand-edited
            // file, because `add` adopts whatever the library already holds. If
            // it happens, the commonest wins and the newest breaks a tie, which
            // is what `library` being newest-first gives for free.
            let name = (spellings[key] ?? [:])
                .sorted { $0.value > $1.value }
                .first?.key ?? key
            return Tag(name: name, recordings: carrying.recordings, notes: carrying.notes)
        }
        // Sorted on everything carrying it, so a tag on four notes and no
        // meetings outranks one on a single meeting. Ordering by recordings
        // alone would put every note-only tag at the bottom whatever its size,
        // which is the shared vocabulary quietly saying notes count for less.
        .sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// One tag by name, however it was capitalised, or nil if nothing carries it.
    static func find(_ name: String, in library: [Recording] = Recording.all(),
                     notes: [Note] = Notes.all()) -> Tag? {
        all(in: library, notes: notes).first { matches($0.name, name) }
    }

    /// Tags worth offering for what has been typed so far.
    ///
    /// Ones that start with it first, then ones that merely contain it, so
    /// typing `job` puts "job hunt" above "side job" rather than ordering the
    /// two by a count that has nothing to do with what was typed.
    static func suggestions(for prefix: String,
                            in library: [Recording] = Recording.all(),
                            notes: [Note] = Notes.all()) -> [Tag] {
        suggestions(for: prefix, among: all(in: library, notes: notes))
    }

    /// The same ordering over a vocabulary the caller already has.
    ///
    /// The popover needs this, because it draws a count on every row and
    /// deriving the vocabulary per row means walking the recordings **and** the
    /// notes once per row per keystroke. Two functions rather than one inlined
    /// copy of the ordering, so the rule cannot come apart from the rule.
    static func suggestions(for prefix: String, among vocabulary: [Tag]) -> [Tag] {
        let needle = canonical(prefix).lowercased()
        guard !needle.isEmpty else { return vocabulary }
        let matching = vocabulary.filter { $0.name.lowercased().contains(needle) }
        let leading = matching.filter { $0.name.lowercased().hasPrefix(needle) }
        return leading + matching.filter { !$0.name.lowercased().hasPrefix(needle) }
    }

    /// Names as the library spells them, validated, or a refusal.
    ///
    /// Split out of `add` and `set`, which both did this inline, so that
    /// `Notes` can reach the rule without copying it. It is the rule that makes
    /// a derived vocabulary survive contact with people: without it the list
    /// grows a second row reading as an exact duplicate of the first, and
    /// neither one has everything.
    static func adopted(_ names: [String], in library: [Recording] = Recording.all(),
                        notes: [Note] = Notes.all()) throws -> [String] {
        let known = all(in: library, notes: notes)
        var out: [String] = []
        for raw in names {
            if let problem = check(raw) { throw problem }
            let name = canonical(raw)
            out.append(known.first { matches($0.name, name) }?.name ?? name)
        }
        return tidy(out)
    }

    // MARK: - Writing one recording

    /// Add tags to a recording, and return what it carries afterwards.
    ///
    /// A tag already in the library is adopted in **its** spelling, so typing
    /// `Job Hunt` onto a library holding `job hunt` files it under the one that
    /// is there. Without this, the tag list grows a second row that reads as an
    /// exact duplicate of the first and neither one has all the recordings.
    @discardableResult
    static func add(_ names: [String], to recording: Recording,
                    in library: [Recording] = Recording.all()) throws -> [String] {
        try write(of(recording) + adopted(names, in: library), to: recording)
    }

    /// Take tags off a recording, and return what it carries afterwards.
    @discardableResult
    static func remove(_ names: [String], from recording: Recording) throws -> [String] {
        try write(keeping(of(recording), without: names), to: recording)
    }

    /// Replace a recording's tags outright, and return what it carries afterwards.
    @discardableResult
    static func set(_ names: [String], on recording: Recording,
                    in library: [Recording] = Recording.all()) throws -> [String] {
        try write(adopted(names.filter { !canonical($0).isEmpty }, in: library),
                  to: recording)
    }

    // MARK: - Writing one note

    /// The same three verbs against a note.
    ///
    /// Overloads rather than new names, because `Tags.add(names, to: thing)` is
    /// one idea and the two things it is done to are both artifacts in this
    /// library. A caller that holds either kind writes the same line.
    ///
    /// `Notes` owns the file and this owns the vocabulary, which is why the
    /// write goes back out through `Notes.setTags` rather than serialising a
    /// note here. There is exactly one place a note's frontmatter is written
    /// and it is not this one.
    @discardableResult
    static func add(_ names: [String], to note: Note,
                    in library: [Recording] = Recording.all(),
                    notes: [Note] = Notes.all()) throws -> [String] {
        try Notes.setTags(of(note) + adopted(names, in: library, notes: notes),
                          on: note, in: library, notes: notes)
    }

    @discardableResult
    static func remove(_ names: [String], from note: Note,
                       in library: [Recording] = Recording.all(),
                       notes: [Note] = Notes.all()) throws -> [String] {
        try Notes.setTags(keeping(of(note), without: names),
                          on: note, in: library, notes: notes)
    }

    @discardableResult
    static func set(_ names: [String], on note: Note,
                    in library: [Recording] = Recording.all(),
                    notes: [Note] = Notes.all()) throws -> [String] {
        try Notes.setTags(adopted(names.filter { !canonical($0).isEmpty },
                                  in: library, notes: notes),
                          on: note, in: library, notes: notes)
    }

    /// What is left of `carried` once `going` has been taken out of it.
    ///
    /// Shared by both `remove`s, and it is where the asymmetry with `add`
    /// lives: taking a tag off matches loosely and never validates, because a
    /// name that could not be added is a name that is not on anything and
    /// refusing it would make removing a hand-written mistake impossible.
    private static func keeping(_ carried: [String], without going: [String]) -> [String] {
        let leaving = going.map(canonical).filter { !$0.isEmpty }
        return carried.filter { name in !leaving.contains { matches(name, $0) } }
    }

    /// The only place `metadata.tags` is written.
    @discardableResult
    private static func write(_ names: [String], to recording: Recording) throws -> [String] {
        var updated = recording
        let cleaned = tidy(names)
        // An empty list is stored as nil rather than `[]`, so taking the last
        // tag off leaves a file indistinguishable from one written before this
        // field existed. Two ways to spell "no tags" is one more than the
        // number of things it can mean.
        updated.metadata.tags = cleaned.isEmpty ? nil : cleaned
        try updated.save()
        return cleaned
    }

    // MARK: - Writing the whole library

    /// Rename one tag everywhere it is carried.
    ///
    /// Returns what it changed, so a caller says how many rather than
    /// claiming success over a library it did not touch. That is
    /// `People.rename`'s signature and its reason.
    ///
    /// **Notes as well as recordings, and that is not an extra.** One
    /// vocabulary means one rename: leaving the notes behind would strand
    /// copies of the tag under the old name, and since a tag nothing carries
    /// does not exist, the old name would reappear in the list the moment the
    /// rename finished.
    ///
    /// Renaming onto a tag something already has merges the two, silently and
    /// harmlessly: `tidy` deduplicates, and unlike a speaker there is nothing
    /// behind a tag to lose in the merge.
    @discardableResult
    static func rename(_ old: String, to new: String,
                       in library: [Recording] = Recording.all(),
                       notes: [Note] = Notes.all()) throws -> Touched {
        if let problem = check(new) { throw problem }
        let target = canonical(new)
        let from = canonical(old)
        guard !from.isEmpty, from != target else { return Touched() }
        return sweep(library, notes) { current in
            current.contains { matches($0, from) }
                ? current.map { matches($0, from) ? target : $0 }
                : nil
        }
    }

    /// Take one tag off everything carrying it.
    ///
    /// **Not a delete of anything.** A tag has no existence apart from what
    /// carries it, so this is the whole of what "delete a tag" can mean, and
    /// nothing changes about a recording or a note but its tag list.
    @discardableResult
    static func delete(_ name: String, in library: [Recording] = Recording.all(),
                       notes: [Note] = Notes.all()) -> Touched {
        let going = canonical(name)
        guard !going.isEmpty else { return Touched() }
        return sweep(library, notes) { current in
            current.contains { matches($0, going) }
                ? current.filter { !matches($0, going) }
                : nil
        }
    }

    /// Apply one rewrite to every recording and note carrying the tag it is
    /// about, and report what actually moved.
    ///
    /// `change` returns nil for something this does not touch, which keeps the
    /// "does it carry it" test in one place for both callers rather than in
    /// four loops that could come apart.
    ///
    /// A failed write skips that file rather than abandoning the sweep half
    /// done, which is `People.relabel`'s behaviour: what comes back is what
    /// actually changed either way.
    private static func sweep(_ library: [Recording], _ notes: [Note],
                              _ change: ([String]) -> [String]?) -> Touched {
        var touched = Touched()
        for recording in library {
            guard let wanted = change(of(recording)) else { continue }
            if (try? write(wanted, to: recording)) != nil {
                touched.recordings.append(recording.id)
            }
        }
        for note in notes {
            guard let wanted = change(of(note)) else { continue }
            // The lists this sweep already holds, so a rename over the library
            // is one pair of directory reads rather than one pair per note.
            if (try? Notes.setTags(wanted, on: note, in: library, notes: notes)) != nil {
                touched.notes.append(note.slug)
            }
        }
        return touched
    }
}
