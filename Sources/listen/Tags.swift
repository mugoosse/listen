import Foundation

/// One tag, across the whole library.
struct Tag {
    /// As written on disk, in the spelling the library settled on.
    let name: String
    /// Every recording carrying it, newest first.
    let recordings: [Recording]

    var count: Int { recordings.count }

    /// "9 recordings", for a list where the number is the only reason to pick
    /// one row over another.
    var summary: String {
        recordings.count == 1 ? "1 recording" : "\(recordings.count) recordings"
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

    /// Every tag in the library, most recordings first.
    static func all(in library: [Recording] = Recording.all()) -> [Tag] {
        var recordings: [String: [Recording]] = [:]
        var spellings: [String: [String: Int]] = [:]
        for recording in library {
            for name in of(recording) {
                let key = name.lowercased()
                recordings[key, default: []].append(recording)
                spellings[key, default: [:]][name, default: 0] += 1
            }
        }
        return recordings.map { key, carrying in
            // Two spellings of one tag should only ever come from a hand-edited
            // file, because `add` adopts whatever the library already holds. If
            // it happens, the commonest wins and the newest breaks a tie, which
            // is what `library` being newest-first gives for free.
            let name = (spellings[key] ?? [:])
                .sorted { $0.value > $1.value }
                .first?.key ?? key
            return Tag(name: name, recordings: carrying)
        }
        .sorted {
            if $0.recordings.count != $1.recordings.count {
                return $0.recordings.count > $1.recordings.count
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// One tag by name, however it was capitalised, or nil if nothing carries it.
    static func find(_ name: String, in library: [Recording] = Recording.all()) -> Tag? {
        all(in: library).first { matches($0.name, name) }
    }

    /// Tags worth offering for what has been typed so far.
    ///
    /// Ones that start with it first, then ones that merely contain it, so
    /// typing `job` puts "job hunt" above "side job" rather than ordering the
    /// two by a count that has nothing to do with what was typed.
    static func suggestions(for prefix: String,
                            in library: [Recording] = Recording.all()) -> [Tag] {
        let needle = canonical(prefix).lowercased()
        guard !needle.isEmpty else { return all(in: library) }
        let matching = all(in: library).filter { $0.name.lowercased().contains(needle) }
        let leading = matching.filter { $0.name.lowercased().hasPrefix(needle) }
        return leading + matching.filter { !$0.name.lowercased().hasPrefix(needle) }
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
        let known = all(in: library)
        var wanted: [String] = []
        for raw in names {
            if let problem = check(raw) { throw problem }
            let name = canonical(raw)
            wanted.append(known.first { matches($0.name, name) }?.name ?? name)
        }
        return try write(of(recording) + wanted, to: recording)
    }

    /// Take tags off a recording, and return what it carries afterwards.
    @discardableResult
    static func remove(_ names: [String], from recording: Recording) throws -> [String] {
        let going = names.map(canonical).filter { !$0.isEmpty }
        let kept = of(recording).filter { name in
            !going.contains { matches(name, $0) }
        }
        return try write(kept, to: recording)
    }

    /// Replace a recording's tags outright, and return what it carries afterwards.
    @discardableResult
    static func set(_ names: [String], on recording: Recording,
                    in library: [Recording] = Recording.all()) throws -> [String] {
        for raw in names where !canonical(raw).isEmpty {
            if let problem = check(raw) { throw problem }
        }
        let known = all(in: library)
        let adopted = names.map(canonical).filter { !$0.isEmpty }.map { name in
            known.first { matches($0.name, name) }?.name ?? name
        }
        return try write(adopted, to: recording)
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

    /// Rename one tag in every recording carrying it.
    ///
    /// Returns the ids it changed, so a caller says how many rather than
    /// claiming success over a library it did not touch. That is
    /// `People.rename`'s signature and its reason.
    ///
    /// Renaming onto a tag a recording already has merges the two, silently and
    /// harmlessly: `tidy` deduplicates, and unlike a speaker there is nothing
    /// behind a tag to lose in the merge.
    @discardableResult
    static func rename(_ old: String, to new: String,
                       in library: [Recording] = Recording.all()) throws -> [String] {
        if let problem = check(new) { throw problem }
        let target = canonical(new)
        let from = canonical(old)
        guard !from.isEmpty, from != target else { return [] }

        var changed: [String] = []
        for recording in library {
            let current = of(recording)
            guard current.contains(where: { matches($0, from) }) else { continue }
            // A failed write skips that recording rather than abandoning the
            // rename half done, which is `People.relabel`'s behaviour: the
            // returned ids are what actually changed either way.
            if (try? write(current.map { matches($0, from) ? target : $0 },
                           to: recording)) != nil {
                changed.append(recording.id)
            }
        }
        return changed
    }

    /// Take one tag off every recording carrying it.
    ///
    /// **Not a delete of anything.** A tag has no existence apart from the
    /// recordings that carry it, so this is the whole of what "delete a tag"
    /// can mean, and nothing about any recording changes but its tag list.
    @discardableResult
    static func delete(_ name: String,
                       in library: [Recording] = Recording.all()) -> [String] {
        let going = canonical(name)
        guard !going.isEmpty else { return [] }

        var changed: [String] = []
        for recording in library {
            let current = of(recording)
            guard current.contains(where: { matches($0, going) }) else { continue }
            if (try? write(current.filter { !matches($0, going) }, to: recording)) != nil {
                changed.append(recording.id)
            }
        }
        return changed
    }
}
