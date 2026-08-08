import Foundation

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

    var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty
            && people.isEmpty && tags.isEmpty && after == nil && before == nil
            && !needsSpeakers
    }

    func apply(to library: [Recording]) -> [Recording] {
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

        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            out = out.filter {
                // `displayTitle`, so a search matches the words on the row it
                // is looking at. Against the stored title, typing what an
                // unnamed recording visibly says would find nothing, and typing
                // the key it happens to be stored under would find every one.
                $0.displayTitle.lowercased().contains(q)
                    // The transcript too, which is the reason anybody searches a
                    // meeting library: you remember what was said, not what the
                    // recording was called.
                    || $0.transcriptText.lowercased().contains(q)
            }
        }

        return out
    }

    // MARK: - `tag:` in a search field

    /// Pull `tag:` terms out of a search string, leaving the rest as the query.
    ///
    /// Three forms work, and they have to, because a tag can have a space in it
    /// and a search field has no other way to say where one ends:
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
    static func parse(_ text: String, knownTags: [String]) -> RecordingFilter {
        var filter = RecordingFilter()
        var words: [String] = []

        let tokens = tokenize(text)
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            guard token.lowercased().hasPrefix("tag:") else {
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
                if next.lowercased().hasPrefix("tag:") { break }
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
