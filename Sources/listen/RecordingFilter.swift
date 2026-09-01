import Foundation

/// Which kind of row a search may produce.
///
/// This was three segments of a control at the top of the sidebar and is now a
/// word you type or a heading you click. The difference is not cosmetic: a
/// segment is a place you are in and have to leave, so there was no way to
/// express "all three", and pressing Notes on a library with none read as the
/// control being broken rather than as an empty answer. A lens is a state with
/// an off switch, and its absence is the whole library.
///
/// The raw values are what `kind:` accepts, and `alternates` is what somebody
/// types when they have not read anything. Singular because that is how a
/// person says it, `meeting` because that is what a recording is, and `speaker`
/// because that is the word the transcript uses.
enum LibraryKind: String, CaseIterable {
    case recordings, people, notes

    var label: String {
        switch self {
        case .recordings: return "Recordings"
        case .people:     return "People"
        case .notes:      return "Notes"
        }
    }

    private var alternates: [String] {
        switch self {
        case .recordings: return ["recording", "meeting", "meetings", "rec"]
        case .people:     return ["person", "speaker", "speakers"]
        case .notes:      return ["note"]
        }
    }

    /// The kind this word names, or nil.
    static func named(_ word: String) -> LibraryKind? {
        let wanted = word.lowercased()
        return allCases.first { $0.rawValue == wanted || $0.alternates.contains(wanted) }
    }
}

/// How the library is narrowed, in one place.
///
/// This predicate used to be written out three times, in the sidebar, in
/// `MCP.list_recordings` and in `listen list`, and the copies had already
/// come apart: the sidebar matched a speaker on the exact on-disk label while
/// MCP went through `SpeakerName.matches`, so a lens the window set and a
/// filter an agent asked for meant two different things. Adding tags to each
/// by hand would have made a fourth copy of a rule nobody owned.
///
/// The **order matters and is the reason this is a function rather than a
/// per-recording predicate**. `person` and `query` read every `turns.json` in
/// the library; the date bounds and the tags read nothing but the metadata
/// already in hand. Narrowing on the cheap ones first is the difference
/// between reading 33 transcripts and reading 3, and it can only be arranged
/// by something that sees the whole list.
struct RecordingFilter {
    /// Free text over the title and the transcript.
    var query = ""
    /// People who must **all** be in the recording, by label or display name.
    ///
    /// A list rather than one, because "the calls Ryan and Emily were both in"
    /// is a question somebody actually has and one name cannot ask it.
    var people: [String] = []
    /// Tags the recording must carry, **all** of them.
    ///
    /// AND rather than OR, here and for `people`, because that is what
    /// narrowing means and because OR is one term away from being the whole
    /// library back. "job hunt and follow-up" is a question; "job hunt or
    /// follow-up" is a list.
    var tags: [String] = []
    var after: Date?
    var before: Date?

    /// Only recordings with somebody in them nobody has named.
    ///
    /// The library's to-do list, asked as a lens rather than pushed at every row
    /// as a status. See `Labelling` for why the question goes to the transcript
    /// and not to `metadata.state`, which is wrong in both directions.
    var needsSpeakers = false

    /// Which kind of row the caller may show.
    ///
    /// **`apply(to:)` ignores this on purpose, and that is the whole point of
    /// the comment.** Every other field here is a question about a recording,
    /// so it can be answered one recording at a time. This one is a question
    /// about *which lists to consult at all*, and only something holding the
    /// recordings, the notes and the roster together can answer it. It lives
    /// here because the parser is the thing that must not be written twice, not
    /// because the predicate belongs to this type.
    ///
    /// So the CLI and the MCP server never set it and lose nothing: they are
    /// already asking about recordings by having called this at all.
    var kind: LibraryKind?

    var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            && people.isEmpty && tags.isEmpty && after == nil && before == nil
            && !needsSpeakers && kind == nil
    }

    /// Where a query was found in a recording, and enough to show it.
    ///
    /// The range is into `text`, which is carried rather than looked up again:
    /// `storedTurns` re-reads and decodes `turns.json` on every access with no
    /// cache, and the search has already paid that once by the time this exists.
    struct Hit {
        /// Which paragraph, or nil for a match in the title.
        var turn: Int?
        var start: Double
        /// Already through `SpeakerName.display`.
        var speaker: String
        var range: NSRange
        var text: String
    }

    /// The library narrowed, and where the query was found in what survived.
    struct Found {
        var recordings: [Recording]
        /// Recording id to its hits. Empty when nothing was typed.
        var hits: [String: [Hit]]
    }

    /// The same narrowing as `apply(to:)`, keeping what it found.
    ///
    /// Two entry points and one predicate, which is what this type exists for:
    /// the CLI and the MCP server want a plain list and the window wants to
    /// show the sentence that matched, and a second copy of the rule would be
    /// the fourth thing this file's doc comment is about.
    func search(_ library: [Recording]) -> Found {
        var out = narrow(library)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return Found(recordings: out, hits: [:]) }

        var hits: [String: [Hit]] = [:]
        out = out.filter { recording in
            var found: [Hit] = []
            // The title first, so a row that matched only its own name can say
            // so by marking the words already on it rather than by growing a
            // line that repeats them.
            for range in Find.ranges(of: q, in: recording.displayTitle) {
                found.append(Hit(turn: nil, start: 0, speaker: "",
                                 range: range, text: recording.displayTitle))
            }
            // **Turn by turn, never over the joined string.** `transcriptText`
            // joins paragraphs with a space, so a query straddling two of them
            // matched text nobody said, and a hit found there has no speaker
            // and no timestamp to attribute it to. Scanning each turn fixes the
            // false positive and yields both for free.
            for (index, turn) in recording.storedTurns.enumerated() {
                for range in Find.ranges(of: q, in: turn.text) {
                    found.append(Hit(turn: index, start: turn.start,
                                     speaker: SpeakerName.display(turn.speaker),
                                     range: range, text: turn.text))
                }
            }
            guard !found.isEmpty else { return false }
            hits[recording.id] = found
            return true
        }
        return Found(recordings: out, hits: hits)
    }

    func apply(to library: [Recording]) -> [Recording] {
        search(library).recordings
    }

    /// Everything except the free text, which is the expensive half.
    private func narrow(_ library: [Recording]) -> [Recording] {
        var out = library

        if after != nil || before != nil {
            out = out.filter { recording in
                guard let at = Timestamps.parse(recording.metadata.recorded_at) else {
                    // A recording whose timestamp will not parse is kept rather
                    // than dropped. Being invisible to every dated query is a
                    // worse answer than being in the wrong one, and it would be
                    // invisible with nothing to explain it.
                    return true
                }
                if let after, at < after { return false }
                if let before, at > before { return false }
                return true
            }
        }

        if !tags.isEmpty {
            out = out.filter { recording in
                let carried = Tags.of(recording)
                return tags.allSatisfy { wanted in
                    carried.contains { Tags.matches($0, wanted) }
                }
            }
        }

        // First of the three that read `turns.json`, because it is by far the
        // most selective: measured on the development library it takes 31
        // recordings to 13, so the two below it read less than half as many
        // transcripts when it is on. It is also the cheapest of the three, being
        // the only one answered from a cache.
        if needsSpeakers {
            out = out.filter(Labelling.waits)
        }

        for person in people where !person.isEmpty {
            out = out.filter { $0.speaks(person) }
        }

        // The free text is not here any more: it is in `search`, which keeps
        // the ranges it found instead of throwing them away. `displayTitle` is
        // still what a title is matched against, so a search matches the words
        // on the row it is looking at, and the transcript is still searched,
        // because remembering what was said rather than what the recording was
        // called is the reason anybody has a meeting library at all.
        return out
    }

    // MARK: - Operators in a search field

    /// Every operator the search field understands, as the prefix it is typed
    /// with. Used here and by the field's completion, which must not invent a
    /// vocabulary this cannot read back.
    static let operators = ["tag:", "kind:", "is:"]

    /// Pull operators out of a search string, leaving the rest as the query.
    ///
    /// Three forms work for `tag:`, and they have to, because a tag can have a
    /// space in it and a search field has no other way to say where one ends:
    ///
    ///     tag:kinsight              one word
    ///     tag:"job hunt"            quoted, taken literally
    ///     tag:job hunt              greedy, against the tags that exist
    ///
    /// The third is what people actually type. It takes the longest run of
    /// following words that names a real tag, and one word when nothing does,
    /// so `tag:job hunt recruiter` filters on "job hunt" and searches for
    /// "recruiter" without anybody having to know the rule. Matching against a
    /// known vocabulary is what makes this unambiguous rather than clever: it
    /// is the same accept-what-they-meant rule `Notes.find` uses for a slug or
    /// a title.
    ///
    /// `kind:` and `is:` are the same word, and both are here because they are
    /// two different pieces of muscle memory: `is:` from GitHub and Gmail,
    /// `kind:` from Spotlight. A value neither of them recognises is left in
    /// the query rather than swallowed, so a typo searches for itself instead
    /// of silently filtering on nothing.
    ///
    /// `is:unnamed` sets `needsSpeakers`, which is the lens the to-do row above
    /// the list already sets. One state, two ways in.
    static func parse(_ text: String, knownTags: [String]) -> RecordingFilter {
        var filter = RecordingFilter()
        var words: [String] = []

        let tokens = tokenize(text)
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            let low = token.lowercased()

            if low.hasPrefix("kind:") || low.hasPrefix("is:") {
                let head = String(token[token.index(after: token.firstIndex(of: ":")!)...])
                if let kind = LibraryKind.named(head) {
                    filter.kind = kind
                } else if head.lowercased() == "unnamed" || head.lowercased() == "unlabelled" {
                    filter.needsSpeakers = true
                } else {
                    // Not a word this understands, so it stays a search term.
                    words.append(token)
                }
                i += 1
                continue
            }

            guard low.hasPrefix("tag:") else {
                words.append(token)
                i += 1
                continue
            }

            let head = String(token.dropFirst(4))
            guard !head.isEmpty else { i += 1; continue }

            // A quoted term arrives from `tokenize` with its space intact, so
            // there is nothing to guess at.
            if head.contains(" ") {
                filter.tags.append(head)
                i += 1
                continue
            }

            var best = head
            var take = 1
            var joined = head
            // Six words is past `Tags.maxLength` at any believable word length,
            // so the cap costs nothing and stops a long query being rescanned
            // from every position.
            for step in 1..<min(6, tokens.count - i) {
                let next = tokens[i + step]
                // Any operator ends the run, not just another `tag:`. Without
                // the other two, `tag:job kind:notes` reads "job kind:notes" as
                // a candidate tag name and the second operator disappears.
                if Self.operators.contains(where: { next.lowercased().hasPrefix($0) }) { break }
                joined += " " + next
                if knownTags.contains(where: { Tags.matches($0, joined) }) {
                    best = joined
                    take = step + 1
                }
            }
            filter.tags.append(best)
            i += take
        }

        filter.query = words.joined(separator: " ")
        return filter
    }

    /// Split on whitespace, except inside double quotes.
    private static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                continue
            }
            if character.isWhitespace, !quoted {
                if !current.isEmpty { out.append(current) }
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Is the operator at the end of this text still being typed?
    ///
    /// **The trap that made this necessary, found by prototyping the field
    /// rather than by reading it.** The search field lifts a finished operator
    /// out of itself and into a pill, and "finished" looked like "followed by a
    /// space". Typing `tag:job hunt` passes through `tag:job ` on the way,
    /// which satisfies that test, so the field lifted a `#job` pill matching
    /// nothing and left the word "hunt" stranded behind it. The greedy rule
    /// above cannot help: it needs words that have not been typed yet.
    ///
    /// So a value that is still a prefix of a longer known tag waits, and the
    /// completion list under the field is what says so. Return is the way to
    /// finish a value this holds, which is what somebody who really means a tag
    /// nobody has will press.
    static func isUnfinished(_ text: String, knownTags: [String]) -> Bool {
        guard let value = trailingTagValue(text) else { return false }
        let wanted = value.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return false }
        return knownTags.contains { $0.lowercased().hasPrefix(wanted + " ") }
    }

    /// Everything after the last `tag:` that starts a token, or nil.
    ///
    /// It runs to the end of the string rather than to the next space, because
    /// a tag value is the one operand here that can contain one. A quoted value
    /// returns nil: the quotes have already said where it ends, so there is
    /// nothing left for the caller to wait for.
    static func trailingTagValue(_ text: String) -> String? {
        var best: String?
        var from = text.startIndex
        while let found = text.range(of: "tag:", options: .caseInsensitive,
                                     range: from..<text.endIndex) {
            let startsToken = found.lowerBound == text.startIndex
                || text[text.index(before: found.lowerBound)].isWhitespace
            if startsToken { best = String(text[found.upperBound...]) }
            from = found.upperBound
        }
        guard let best, !best.contains("\"") else { return nil }
        return best
    }
}

extension Recording {
    /// Does this person speak in this recording?
    ///
    /// Matching is on the displayed name as well as the stored label, because
    /// the microphone track is stored as `Me` however the user chooses to be
    /// shown. Somebody who has set their name to Maxime and asks for
    /// `person: "Maxime"` means their own track, and matching only the disk
    /// label would return nothing with no way to tell that from "no such
    /// person". The same rule makes `Speaker A` findable by what the UI calls
    /// it rather than only by `A`.
    func speaks(_ person: String) -> Bool {
        speakers.contains { SpeakerName.matches($0, person) }
    }
}

extension SpeakerName {
    /// Does a stored speaker label answer to this name?
    ///
    /// Case and surrounding space are ignored: the name is passed through from
    /// something a human typed, and refusing "edgar" for `Edgar` would be a
    /// filter that silently returns nothing.
    ///
    /// The display name counts as well as the label, because the two differ for
    /// exactly the speakers anybody is most likely to ask about: the microphone
    /// track is `Me` on disk however the user has named themselves, and `A` is
    /// `Speaker A` everywhere it is read.
    static func matches(_ label: String, _ wanted: String) -> Bool {
        let wanted = wanted.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return false }
        return label.caseInsensitiveCompare(wanted) == .orderedSame
            || display(label).caseInsensitiveCompare(wanted) == .orderedSame
    }
}
