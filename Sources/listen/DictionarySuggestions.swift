import Foundation
import ListenKit

/// Words the dictionary should probably know, and where that was noticed.
///
/// ## The evidence was already in the app
///
/// Every hand edit of a sentence is a labelled pair: what the model wrote, and
/// what the person listening says it should have said. Nothing collected them.
/// So somebody corrected "Kinsite" in the transcript, and corrected it again in
/// the next meeting, and the dictionary that exists to stop exactly that only
/// learned about it if they remembered to go and type it in. `TranscriptEditor`
/// now hands each `.retext` here, and the pair with its sentence and its
/// recording is what a suggestion is.
///
/// The second source needs no edit at all: a word that is not in the system
/// lexicon, repeats across the library, and sounds like somebody on the roster
/// is almost always that person's name spelled the way the model guessed it.
/// That is `scan`, and it is how a library that has never been hand-corrected
/// still has something to offer.
///
/// ## Proposing, never adding
///
/// Nothing here writes to `dictionary.json` on its own. A dictionary rule
/// rewrites recordings quietly, and with the backfill it rewrites recordings
/// that already exist, so the one thing this must not do is add a rule nobody
/// read. Every suggestion is a row with two buttons, and dismissing one is
/// remembered so it is not offered again next week.
///
/// ## What is not kept
///
/// A dismissal is a key, not a sentence, and an accepted suggestion is deleted
/// rather than archived. This file is a worklist, not a second copy of the
/// transcript: the sentence it carries is the one excerpt needed to recognise
/// the change, and it goes when the row does.
enum DictionarySuggestions {

    enum Source: String, Codable {
        /// A sentence somebody corrected by hand.
        case edit
        /// A word that sounds like a name on the roster.
        case roster
    }

    struct Suggestion: Codable, Equatable {
        /// What the transcript said.
        var heard: String
        /// What it should say.
        var meant: String
        /// The two differ only in capitals, so the correction has to be
        /// case-sensitive or it matches its own replacement for ever.
        var caseOnly: Bool
        /// How many times this pair has been seen.
        var seen: Int
        /// Recording ids, newest last, capped: this is a worklist and the
        /// interesting part is that it happened more than once.
        var recordings: [String]
        /// One sentence it was seen in, for recognising it in the pane.
        var example: String
        var source: Source
        var first: Date
        var last: Date

        var key: String { DictionarySuggestions.key(heard: heard, meant: meant) }

        /// The entry accepting this suggestion would add.
        var entry: CustomDictionary.Entry {
            CustomDictionary.Entry(kind: .correction, text: heard, replacement: meant,
                                   caseSensitive: caseOnly)
        }
    }

    static func key(heard: String, meant: String) -> String { heard + "\u{0}" + meant }

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    private struct Document: Codable {
        var version: Int = 1
        var suggestions: [Suggestion] = []
        /// Keys of pairs somebody has said no to.
        var dismissed: [String] = []
    }

    static var file: URL { Library.root.appendingPathComponent("dictionary-suggestions.json") }

    /// Read on every call, like `CustomDictionary.load` and for the same reason:
    /// the window and the CLI are two processes over one file, and a cache here
    /// would need invalidating from both.
    ///
    /// A lost race costs a suggestion, never a transcript. Nothing downstream of
    /// this file is load-bearing: it is a list of things somebody might want to
    /// add, and the evidence for every one of them is still in the recordings.
    private static func read() -> Document {
        let decoder = JSONDecoder()
        // The same strategy `write` encodes with. A plain `JSONDecoder` reads
        // dates as seconds since 2001 and throws on an ISO-8601 string, and
        // `try?` turns that into an empty list: the file was written correctly,
        // every suggestion in it was invisible, and nothing anywhere said so.
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file),
              let doc = try? decoder.decode(Document.self, from: data)
        else { return Document() }
        return doc
    }

    private static func write(_ doc: Document) {
        try? FileManager.default.createDirectory(at: Library.root,
                                                 withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(doc) else { return }
        try? data.write(to: file, options: .atomic)
    }

    // -----------------------------------------------------------------------
    // Watching hand edits
    // -----------------------------------------------------------------------

    /// A sentence was corrected. Work out whether that says anything general.
    ///
    /// Called after the edit has been written, so a refused edit teaches nothing,
    /// which is right: the user was looking at a stale pane, not at this word.
    ///
    /// **Only a substitution in the middle of an otherwise unchanged sentence.**
    /// Rewriting half a paragraph is a person fixing the meaning, and turning
    /// that into a rule that rewrites the library would be absurd. The narrow
    /// case is the valuable one, and it is the common one: one word, wrong,
    /// again.
    static func observe(was: String, now: String, in recording: Recording) {
        guard let pair = difference(was: was, now: now) else { return }
        // Synchronous, deliberately. The obvious move is to push this onto a
        // background queue, since nothing is waiting on it and `covered` loads
        // `/usr/share/dict/words` the first time it runs. That was written, and
        // it silently did nothing at all: `listen edit` calls `exit(0)` on the
        // line after the edit, so the queued work never ran and a correction
        // made at the CLI taught the dictionary nothing.
        //
        // The cost it was avoiding is small enough to measure and dismiss: a
        // whole `listen dictionary test` process, lexicon load included, is
        // 0.07s, against an edit that has already rewritten two JSON files.
        record(pair, in: recording.id, sentence: now)
    }

    private static func record(_ pair: (heard: String, meant: String, caseOnly: Bool),
                               in recordingID: String, sentence now: String) {
        guard !covered(pair.heard, gives: pair.meant) else { return }

        var doc = read()
        let key = key(heard: pair.heard, meant: pair.meant)
        guard !doc.dismissed.contains(key) else { return }

        if let i = doc.suggestions.firstIndex(where: { $0.key == key }) {
            doc.suggestions[i].seen += 1
            doc.suggestions[i].last = Date()
            if !doc.suggestions[i].recordings.contains(recordingID) {
                doc.suggestions[i].recordings.append(recordingID)
            }
            // The newest sentence, not the first. A pair seen three times is
            // most recognisable in the meeting the reader has just been in.
            doc.suggestions[i].example = excerpt(now)
        } else {
            doc.suggestions.append(Suggestion(
                heard: pair.heard, meant: pair.meant, caseOnly: pair.caseOnly,
                seen: 1, recordings: [recordingID], example: excerpt(now),
                source: .edit, first: Date(), last: Date()))
        }
        write(doc)
    }

    /// The one changed run of words, or nil if this edit says nothing general.
    ///
    /// Walks in from both ends, which is what a reader does, and then insists on
    /// what is left being small on both sides. Three words is the ceiling
    /// because `CustomDictionary` matches a phrase of up to three, so a longer
    /// pair could not become a rule that fires anyway.
    static func difference(was: String, now: String)
        -> (heard: String, meant: String, caseOnly: Bool)? {
        let old = was.split(separator: " ").map(String.init)
        let new = now.split(separator: " ").map(String.init)
        guard !old.isEmpty, !new.isEmpty else { return nil }

        var head = 0
        while head < old.count, head < new.count, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head,
              old[old.count - 1 - tail] == new[new.count - 1 - tail] { tail += 1 }

        let heardWords = Array(old[head..<(old.count - tail)])
        let meantWords = Array(new[head..<(new.count - tail)])
        guard !heardWords.isEmpty, !meantWords.isEmpty,
              heardWords.count <= 3, meantWords.count <= 3 else { return nil }

        // Punctuation belongs to the sentence, not to the word, so a full stop
        // that moved must not become part of a rule. Trimmed from the outside
        // only: "flyinpublic.com" keeps its dot.
        let punctuation = CharacterSet(charactersIn: ".,;:!?\"'()[]…")
        let heard = heardWords.joined(separator: " ")
            .trimmingCharacters(in: punctuation.union(.whitespaces))
        let meant = meantWords.joined(separator: " ")
            .trimmingCharacters(in: punctuation.union(.whitespaces))
        guard !heard.isEmpty, !meant.isEmpty, heard != meant,
              heard.rangeOfCharacter(from: .letters) != nil,
              meant.rangeOfCharacter(from: .letters) != nil else { return nil }

        // A correction whose replacement still matches its own pattern rewrites
        // for ever and inflates its own count. Case is the one difference that
        // does that, and case-sensitive is the fix, so it is recorded rather
        // than refused.
        return (heard, meant, heard.lowercased() == meant.lowercased())
    }

    /// Whether the dictionary as it stands already turns `heard` into `meant`.
    ///
    /// Checked when a pair is noticed and again when the list is read, because
    /// the rule may have been added by hand in between and an offer to add what
    /// is already there reads as the feature being broken.
    private static func covered(_ heard: String, gives meant: String) -> Bool {
        let entries = CustomDictionary.load()
        guard !entries.isEmpty else { return false }
        return CustomDictionary.apply(to: heard, entries: entries).text == meant
    }

    /// A window of the sentence, around `word` when one is named.
    ///
    /// Around it, not the first 90 characters of the sentence: the excerpt is
    /// the evidence for the suggestion, and the first version of this printed
    /// "Celine -> Céline" beside a sentence about a spider, because the word it
    /// was evidence for sat 190 characters in and was cut off.
    private static func excerpt(_ sentence: String, around word: String? = nil,
                                limit: Int = 90) -> String {
        let clean = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        guard let word, let found = clean.range(of: word) else {
            return String(clean.prefix(limit)) + "…"
        }
        let before = clean.distance(from: clean.startIndex, to: found.lowerBound)
        let lead = max(0, before - limit / 3)
        let start = clean.index(clean.startIndex, offsetBy: lead)
        let end = clean.index(start, offsetBy: limit, limitedBy: clean.endIndex)
            ?? clean.endIndex
        return (lead > 0 ? "…" : "") + String(clean[start..<end])
            + (end < clean.endIndex ? "…" : "")
    }

    // -----------------------------------------------------------------------
    // Reading the list
    // -----------------------------------------------------------------------

    /// Everything still worth offering, most seen first.
    static func pending() -> [Suggestion] {
        let doc = read()
        let dismissed = Set(doc.dismissed)
        return doc.suggestions
            .filter { !dismissed.contains($0.key) }
            .filter { !covered($0.heard, gives: $0.meant) }
            .sorted {
                $0.seen == $1.seen ? $0.last > $1.last : $0.seen > $1.seen
            }
    }

    /// Add the rule and take the row away.
    ///
    /// The entry is a correction whatever the pair looks like. A term is matched
    /// by sound and this pair is evidence about one exact spelling, so promoting
    /// it to a term would claim more than was observed. The sheet in the pane is
    /// where somebody says "and anything that sounds like it".
    @discardableResult
    static func accept(_ suggestion: Suggestion) -> Bool {
        var entries = CustomDictionary.load()
        let result = CustomDictionary.merge([suggestion.entry], into: entries)
        entries.append(contentsOf: result.added)
        CustomDictionary.save(entries)
        forget(suggestion)
        return !result.added.isEmpty
    }

    static func dismiss(_ suggestion: Suggestion) {
        var doc = read()
        doc.suggestions.removeAll { $0.key == suggestion.key }
        if !doc.dismissed.contains(suggestion.key) { doc.dismissed.append(suggestion.key) }
        write(doc)
    }

    /// Drop a row without remembering the refusal, which is what accepting means.
    private static func forget(_ suggestion: Suggestion) {
        var doc = read()
        doc.suggestions.removeAll { $0.key == suggestion.key }
        write(doc)
    }

    // -----------------------------------------------------------------------
    // Scanning the library
    // -----------------------------------------------------------------------

    /// Words that repeat, are not English, and sound like somebody on the
    /// roster.
    ///
    /// The cheap half of the idea, and it needs no model and no network: a
    /// phonetic key over the transcript's own vocabulary against the names
    /// Listen already knows. "Selin" against "Celine" is the whole shape.
    ///
    /// **Sounding alike is nowhere near enough, and the first version proved it.**
    /// Run over this library with only the guards below, it offered "niet ->
    /// Nadia" 454 times, "maar -> Mauro" 344, "email -> Emily" 146 and "grote ->
    /// Geert" 21. Soundex codes t and d alike, and `/usr/share/dict/words` is
    /// English, so every common Dutch word in a bilingual library reads as a
    /// misspelt name. A list like that is worse than no list: it is a page of
    /// rules that would each rewrite hundreds of sentences.
    ///
    /// So four guards, and the last two are the ones that matter:
    ///
    /// - **Not a real word.** Otherwise every "seen" in the library is offered
    ///   as a misspelling of a person called Sean.
    /// - **At least `floor` occurrences.** A one-off is the model slipping, and
    ///   a rule for it would rewrite for ever on the strength of one sentence.
    /// - **It has to look like the name too**, within one edit per three
    ///   characters, which is the same second opinion the sounds-like matcher
    ///   takes on a gap-closed span. All four of the offers above are three or
    ///   more edits from the name they matched.
    /// - **Written as a name.** The models capitalise a word they took for a
    ///   name, so a lower-case word that sounds like one is a word.
    ///
    /// Not run automatically. It is a button, because a scan that proposed rules
    /// on its own would be the app adding to the dictionary while nobody watched.
    static func scan(in library: [Recording]? = nil, floor: Int = 3) -> [Suggestion] {
        let recordings = (library ?? Recording.all()).filter(\.hasTranscript)
        let names = People.roster()
            .filter { !$0.isYou }
            .map(\.display)
            .filter { !$0.contains(" ") && $0.count >= 4 }
        guard !names.isEmpty else { return [] }

        // Keyed once. The lookup is by sound, so the name's own spelling is the
        // answer and any transcript word that codes to the same key is a
        // candidate for it.
        var byKey: [String: String] = [:]
        for name in names { byKey[CustomDictionary.phoneticKey(name)] = name }

        var counts: [String: Int] = [:]
        var where_: [String: Set<String>] = [:]
        var example: [String: String] = [:]
        for recording in recordings {
            guard let transcript = recording.storedTranscript else { continue }
            for segment in transcript.segments {
                for raw in segment.text.split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
                    let word = String(raw)
                    guard word.count >= 4, word.first?.isUppercase == true,
                          !CustomDictionary.isRealWord(word) else { continue }
                    counts[word, default: 0] += 1
                    where_[word, default: []].insert(recording.id)
                    if example[word] == nil {
                        example[word] = excerpt(segment.text, around: word)
                    }
                }
            }
        }

        let dismissed = Set(read().dismissed)
        var out: [Suggestion] = []
        for (word, n) in counts where n >= floor {
            guard let name = byKey[CustomDictionary.phoneticKey(word)], name != word,
                  CustomDictionary.distance(word.lowercased(), name.lowercased())
                      <= max(1, name.count / 3),
                  !covered(word, gives: name),
                  !dismissed.contains(key(heard: word, meant: name)) else { continue }
            out.append(Suggestion(
                heard: word, meant: name,
                caseOnly: word.lowercased() == name.lowercased(),
                seen: n, recordings: Array(where_[word] ?? []).sorted(),
                example: example[word] ?? "", source: .roster,
                first: Date(), last: Date()))
        }
        return out.sorted { $0.seen == $1.seen ? $0.heard < $1.heard : $0.seen > $1.seen }
    }

    /// Run `scan` and keep what it found, so the pane and the CLI see one list.
    ///
    /// Merged rather than replacing: a pair somebody has already seen from an
    /// edit keeps the count that edit gave it, because "you corrected this
    /// twice" is stronger evidence than "it appears eleven times".
    @discardableResult
    static func absorbScan(in library: [Recording]? = nil) -> Int {
        let found = scan(in: library)
        guard !found.isEmpty else { return 0 }
        var doc = read()
        let known = Set(doc.suggestions.map(\.key))
        let fresh = found.filter { !known.contains($0.key) }
        doc.suggestions.append(contentsOf: fresh)
        write(doc)
        return fresh.count
    }
}
