import Foundation

/// The user's own vocabulary: words to spell right, and text to replace.
///
/// Named `CustomDictionary` because `Dictionary` is `Swift.Dictionary`, and
/// shadowing that in a codebase full of `[String: Any]` would be a cruelty.
///
/// Ported from Speak, where the rules were tuned, minus the one mechanism Listen
/// cannot use. Speak has three: a term is a spelling hint in the polishing
/// model's prompt, a term is also matched by sound, and a correction is a
/// literal replacement. Listen has no polishing model, so the prompt half is
/// dropped and the two that remain are pure text over Foundation. Nothing here
/// loads a model or needs one.
///
/// - A **term** is a word Listen should know: a name, a product, a piece of
///   jargon. Anything in the transcript that sounds like one, and is not a word
///   in its own right, becomes it.
/// - A **correction** is an exact replacement, for a mishearing that sounds
///   nothing like the word that was meant.
///
/// Corrections run first, then terms: an explicit rule somebody wrote outranks a
/// phonetic guess.
///
/// ## Where this runs, and why it counts itself
///
/// In `Pipeline.run`, once, on the segments that are about to be written to the
/// library. That is a stronger commitment than Speak makes, and it needs saying
/// plainly: Speak's transcript is text you are about to paste and can see, while
/// Listen's is an archive of a meeting nobody may read for a week. A bad rule
/// applied here rewrites recordings quietly, and the only surviving evidence is
/// the audio.
///
/// So every rewrite leaves a number behind. `apply` returns how often each rule
/// fired, `Pipeline` totals it into `StoredTranscript.dictionary`, and the
/// Dictionary pane reports it. That is the same "count rather than assume"
/// arrangement `Merge.clean` has, and for the same reason: a rule nobody can
/// measure is a rule nobody can argue about.
///
/// The rule for *where* it applies is one sentence with no exceptions: the
/// dictionary rewrites what goes into the library, and nothing else. A bare
/// `listen transcribe some.wav` prints what the model actually said, because
/// that command exists to separate a model problem from a capture problem and a
/// dictionary silently editing its output would make it lie. `listen dictionary
/// test` is how a rule is checked without a recording.
enum CustomDictionary {
    enum Kind: String, Codable {
        case term
        case correction
    }

    struct Entry: Codable, Equatable {
        var kind: Kind
        /// The term itself, or the text a correction looks for.
        var text: String
        /// Corrections only. Empty for terms.
        var replacement: String
        /// Corrections only. Off means "listen" also matches "Listen".
        var caseSensitive: Bool
        var enabled: Bool

        init(kind: Kind, text: String, replacement: String = "",
             caseSensitive: Bool = false, enabled: Bool = true) {
            self.kind = kind
            self.text = text
            self.replacement = replacement
            self.caseSensitive = caseSensitive
            self.enabled = enabled
        }

        /// The key this entry's firings are counted under.
        var countKey: String { "\(kind.rawValue):\(text)" }
    }

    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------

    /// Beside the recordings, in `~/Library/Application Support/Listen`.
    ///
    /// Listen's own file, deliberately not Speak's. Sharing one file would save
    /// maintaining two lists of the same people's names, and it would mean two
    /// apps writing a document that is rewritten whole every time, where the
    /// loser of a race loses entries rather than a merge. Import and export
    /// carry the list across instead, which is the same convenience without the
    /// shared-mutable-state half.
    static let file = Library.root.appendingPathComponent("dictionary.json")

    /// Where Speak keeps its own, for the one-press import.
    ///
    /// Read, never written. Speak is a separate app and its dictionary is its
    /// own; Listen offers to copy from it and nothing more.
    static let speakFile = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/speak/dictionary.json")

    static var speakDictionaryExists: Bool {
        FileManager.default.fileExists(atPath: speakFile.path)
    }

    private struct Document: Codable {
        var version: Int
        var entries: [Entry]
    }

    /// Read from disk on every call.
    ///
    /// A few kilobytes is nothing against a transcription job, and a cache here
    /// would need invalidating from the Settings pane, from a hand edit of the
    /// file, and from the CLI running in a different process. Correctness is
    /// cheaper than the saving.
    ///
    /// `Pipeline` still loads once and passes the result down, because a
    /// thousand-segment transcript would otherwise be a thousand reads of the
    /// same file, and because the two passes over one recording must agree.
    static func load() -> [Entry] {
        guard let data = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        return doc.entries
    }

    static func save(_ entries: [Entry]) {
        try? FileManager.default.createDirectory(
            at: Library.root, withIntermediateDirectories: true)

        guard let data = encode(entries) else { return }
        // Atomic: a crash mid-write must not leave the user with neither the old
        // list nor the new one.
        try? data.write(to: file, options: .atomic)
    }

    // -----------------------------------------------------------------------
    // Import and export
    // -----------------------------------------------------------------------

    /// Read entries out of a file, accepting more shapes than `save` writes.
    ///
    /// Deliberately liberal. A dictionary is worth years of corrections, and the
    /// reason anyone has one to import is that they built it in another app, so
    /// refusing a file over a key name would defeat the point. Three shapes are
    /// understood:
    ///
    /// - Speak's `{"version": 1, "entries": [...]}`, which is also what Listen
    ///   writes.
    /// - A bare array of entries, which is what TypeWhisper exports.
    /// - Either of those with any of the three apps' key names, per entry.
    ///
    /// TypeWhisper calls the fields `type`, `original` and `isEnabled` where
    /// Speak and Listen call them `kind`, `text` and `enabled`, and its term
    /// entries carry a `ctcMinSimilarity` that neither has a use for and drops.
    ///
    /// Returns nil only when the file is not JSON in either shape. Entries that
    /// cannot mean anything, having no text to match, are skipped rather than
    /// failing the import.
    static func decode(_ data: Data) -> [Entry]? {
        let json = try? JSONSerialization.jsonObject(with: data)
        let array: [[String: Any]]
        switch json {
        case let list as [[String: Any]]:
            array = list
        case let object as [String: Any]:
            guard let entries = object["entries"] as? [[String: Any]] else { return nil }
            array = entries
        default:
            return nil
        }
        return array.compactMap(entry(from:))
    }

    private static func entry(from json: [String: Any]) -> Entry? {
        let text = (json["text"] ?? json["original"]) as? String ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let rawKind = (json["kind"] ?? json["type"]) as? String ?? ""
        // A replacement is what makes an entry a correction, so an unrecognised
        // or missing kind is decided by whether one is present. Guessing wrong
        // here would silently turn a correction into a hint that does nothing.
        let replacement = json["replacement"] as? String ?? ""
        let kind: Kind = Kind(rawValue: rawKind) ?? (replacement.isEmpty ? .term : .correction)

        return Entry(kind: kind,
                     text: text,
                     replacement: kind == .correction ? replacement : "",
                     caseSensitive: json["caseSensitive"] as? Bool ?? false,
                     enabled: (json["enabled"] ?? json["isEnabled"]) as? Bool ?? true)
    }

    /// Pretty-printed, stably ordered, and in **Speak's** shape on purpose.
    ///
    /// The two apps read each other's exports because they write the same
    /// document, which is what makes "export here, import there" a complete
    /// answer in both directions rather than a one-way trip. Hand-editing the
    /// stored file is also a supported way to use it, and a diff of one changed
    /// word should be one changed line.
    static func encode(_ entries: [Entry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(Document(version: 1, entries: entries))
    }

    struct MergeResult {
        var added: [Entry]
        /// Entries already present, by kind and text. Reported rather than
        /// duplicated: importing the same file twice should be harmless.
        var duplicates: Int
    }

    /// Add `incoming` to `existing`, skipping ones already there.
    ///
    /// Merging rather than replacing, because replacing is one misclick away
    /// from destroying a list somebody built up over months, and merging is what
    /// importing usually means.
    ///
    /// Matching ignores case because the entries are text a person typed, and
    /// two rules differing only in the capitalisation of what they look for
    /// would both fire on the same words.
    static func merge(_ incoming: [Entry], into existing: [Entry]) -> MergeResult {
        var seen = Set(existing.map(key))
        var result = MergeResult(added: [], duplicates: 0)
        for entry in incoming {
            let k = key(entry)
            if seen.contains(k) {
                result.duplicates += 1
            } else {
                seen.insert(k)
                result.added.append(entry)
            }
        }
        return result
    }

    private static func key(_ e: Entry) -> String {
        "\(e.kind.rawValue)\u{0}\(e.text.lowercased())"
    }

    // -----------------------------------------------------------------------
    // Applying
    // -----------------------------------------------------------------------

    /// A rewritten string and the rules that rewrote it.
    struct Applied {
        var text: String
        /// How often each rule fired, keyed by `Entry.countKey`.
        var fired: [String: Int] = [:]
    }

    /// Corrections then terms, with the counts.
    ///
    /// One entry point rather than two, so nothing downstream has to remember
    /// the order. Corrections first because an explicit rule the user wrote
    /// outranks a phonetic guess, and because a correction's replacement is then
    /// safe from being re-matched by a term that sounds like it.
    static func apply(to text: String, entries: [Entry]? = nil) -> Applied {
        let list = entries ?? load()
        guard !list.isEmpty else { return Applied(text: text) }
        var out = corrections(in: text, entries: list)
        let terms = self.terms(in: out.text, entries: list)
        out.text = terms.text
        for (key, n) in terms.fired { out.fired[key, default: 0] += n }
        return out
    }

    /// Add one string's counts into a running total.
    static func combine(_ counts: [String: Int], into total: inout [String: Int]) {
        for (key, n) in counts { total[key, default: 0] += n }
    }

    // MARK: Corrections

    /// Apply every enabled correction, longest pattern first.
    ///
    /// Longest first because corrections overlap, and the specific one has to
    /// win. A real pair from an imported dictionary: "maxim" to "Maxime" and
    /// "maxim Gusens" to "Maxime Goossens". Run in list order, the short rule
    /// fires first, and by the time the long one is tried the text says "Maxime
    /// Gusens", which it no longer matches. The surname is then unfixable by any
    /// rule the user can add. Sorting by length makes the pair compose, and it
    /// needs no reordering UI or any awareness that ordering exists.
    ///
    /// Equal-length patterns keep the list's order, and each correction still
    /// sees what earlier ones produced.
    private static func corrections(in text: String, entries: [Entry]) -> Applied {
        let rules = entries
            .enumerated()
            .filter { $0.element.kind == .correction && $0.element.enabled }
            // Explicit index tiebreak: sorted(by:) is not a stable sort, so
            // without it equal-length rules would shuffle between runs.
            .sorted {
                let (a, b) = ($0.element.text.count, $1.element.text.count)
                return a == b ? $0.offset < $1.offset : a > b
            }
            .map(\.element)

        var out = Applied(text: text)
        for entry in rules {
            let pattern = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { continue }
            let result = replace(pattern, with: entry.replacement,
                                 in: out.text, caseSensitive: entry.caseSensitive)
            guard result.count > 0 else { continue }
            out.text = result.text
            out.fired[entry.countKey, default: 0] += result.count
        }
        return out
    }

    /// Whole-word replacement when the pattern's edge is a word character, plain
    /// substring replacement otherwise.
    ///
    /// The distinction matters at both ends independently. `\b` marks a
    /// transition between a word character and a non-word one, so anchoring
    /// "C++" with a trailing `\b` would stop it ever matching: the character
    /// after "+" is not a word character either, so there is no transition to
    /// find. Anchoring only the ends that are word characters gets "cat" leaving
    /// "category" alone while "C++" still matches.
    private static func replace(_ pattern: String, with replacement: String,
                                in text: String,
                                caseSensitive: Bool) -> (text: String, count: Int) {
        var expression = NSRegularExpression.escapedPattern(for: pattern)
        if pattern.first?.isWordLike == true { expression = "\\b" + expression }
        if pattern.last?.isWordLike == true { expression += "\\b" }

        guard let regex = try? NSRegularExpression(
            pattern: expression, options: caseSensitive ? [] : [.caseInsensitive])
        else { return (text, 0) }

        let range = NSRange(text.startIndex..., in: text)
        // Counted before replacing rather than by comparing the two strings: a
        // rule whose replacement equals what it matched changes nothing and
        // still fired, and that is exactly the rule worth reporting as useless.
        let count = regex.numberOfMatches(in: text, range: range)
        guard count > 0 else { return (text, 0) }
        return (regex.stringByReplacingMatches(
            in: text,
            range: range,
            // Escaped: an unescaped "$1" in someone's replacement would expand
            // to a capture group rather than the two characters they typed.
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)),
                count)
    }

    // MARK: Terms

    /// Terms shorter than this are left alone.
    ///
    /// Short words collide constantly under a phonetic code, and an entry like
    /// "R2" would match half the alphabet-and-digit pairs anyone says.
    private static let minimumSoundsLike = 5

    /// Consonant-class code, Soundex style but never truncated.
    ///
    /// Soundex proper stops after three digits, which is far too coarse here:
    /// "flyinpublic" and "flamboyant" both reduce to F451 and would be treated
    /// as the same word. Keeping the whole string separates them (f451142
    /// against f45153) while still ignoring the vowels, which is exactly where
    /// mishearings differ.
    ///
    /// Vowels break a run of equal codes, h and w do not, which is what makes
    /// "Goossens", "Gossens", "Goosens", "Gaussens" and "Gusens" all come out as
    /// g252.
    static func phoneticKey(_ s: String) -> String {
        let letters = s.lowercased().filter(\.isLetter)
        guard let first = letters.first else { return "" }
        var key = String(first)
        var previous = consonantClass(first)
        for c in letters.dropFirst() {
            if let d = consonantClass(c) {
                if d != previous { key.append(d) }
                previous = d
            } else if c != "h", c != "w" {
                previous = nil
            }
        }
        return key
    }

    private static func consonantClass(_ c: Character) -> Character? {
        switch c {
        case "b", "f", "p", "v":                     return "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": return "2"
        case "d", "t":                               return "3"
        case "l":                                    return "4"
        case "m", "n":                               return "5"
        case "r":                                    return "6"
        default:                                     return nil
        }
    }

    /// Every word macOS ships a spelling for.
    ///
    /// The guard that makes this safe: a word already in the language is never
    /// touched, however much it sounds like one of your terms. Without it a term
    /// of "Codex" would rewrite "codes", which is the kind of thing that would
    /// make the whole feature untrustworthy.
    ///
    /// Loaded once, and only when there is an eligible term to check against, so
    /// a library with no terms in it never pays for this at all.
    private static let lexicon: Set<String> = {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words",
                                     encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }()

    /// `words` is a 1934 word list with no plurals or verb forms, so "codes" and
    /// "dogs" are missing from it. Stripping common endings covers that without
    /// shipping a second dictionary.
    private static func isRealWord(_ w: String) -> Bool {
        let word = w.lowercased()
        if lexicon.contains(word) { return true }
        for (suffix, stem) in [("s", ""), ("es", ""), ("ed", ""), ("ed", "e"),
                               ("ing", ""), ("ing", "e"), ("d", ""), ("ies", "y"),
                               ("er", ""), ("est", ""), ("ly", "")]
        where word.hasSuffix(suffix) {
            if lexicon.contains(word.dropLast(suffix.count) + stem) { return true }
        }
        return false
    }

    /// Replace misheard words with the term they sound like.
    ///
    /// This is what makes a term worth having in an app with no polishing model
    /// to hint at. It asks nobody: a word that sounds like one of your terms and
    /// is not a word in its own right becomes that term.
    ///
    /// Worth more in a meeting than in a dictation, and worth watching for the
    /// same reason. A meeting is full of the same handful of proper nouns said
    /// forty times, which is the good case, and it is also an hour of text
    /// rather than twenty seconds, which is forty times as many chances for a
    /// rule to fire somewhere nobody expected. Hence the counts.
    private static func terms(in text: String, entries: [Entry]) -> Applied {
        let terms = entries
            .filter { $0.kind == .term && $0.enabled && eligible($0.text) }
            .map { (keys: $0.text.split(separator: " ").map { phoneticKey(String($0)) },
                    entry: $0) }
            // Longest first, so a term for "Claude Code" beats one for "Claude".
            .sorted { $0.keys.count > $1.keys.count }
        guard !terms.isEmpty, !lexicon.isEmpty else { return Applied(text: text) }

        guard let regex = try? NSRegularExpression(
            pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}._'-]*") else { return Applied(text: text) }

        // Trailing punctuation belongs to the sentence, not the word:
        // "flyinpublic.com." must not be compared with its full stop.
        let tokens: [(word: String, tail: String, range: Range<String.Index>)] =
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                let raw = String(text[range])
                let word = String(raw.reversed().drop { ".'_-".contains($0) }.reversed())
                return (word, String(raw.dropFirst(word.count)), range)
            }

        var out = ""
        var fired: [String: Int] = [:]
        var cursor = text.startIndex
        var i = 0
        while i < tokens.count {
            var advance = 1
            for term in terms where i + term.keys.count <= tokens.count {
                let span = Array(tokens[i..<(i + term.keys.count)])
                // Punctuation inside the span means these words are not one
                // phrase: "the cloud. Coat rack" is not "Claude Code".
                guard span.dropLast().allSatisfy({ $0.tail.isEmpty }),
                      zip(span, term.keys).allSatisfy({ phoneticKey($0.word) == $1 })
                else { continue }

                let phrase = span.map(\.word).joined(separator: " ")
                guard phrase.caseInsensitiveCompare(term.entry.text) != .orderedSame else {
                    advance = term.keys.count      // already right, leave it alone
                    break
                }
                guard accepts(phrase: phrase, as: term.entry.text, words: term.keys.count)
                else { continue }

                out += String(text[cursor..<span[0].range.lowerBound])
                    + term.entry.text + span.last!.tail
                cursor = span.last!.range.upperBound
                fired[term.entry.countKey, default: 0] += 1
                advance = term.keys.count
                break
            }
            i += advance
        }
        return Applied(text: out.isEmpty ? text : out + text[cursor...], fired: fired)
    }

    /// A term can only match by sound if it is long enough to be distinctive.
    static func eligible(_ term: String) -> Bool {
        let words = term.split(separator: " ")
        guard !words.isEmpty else { return false }
        let letters = term.filter(\.isLetter).count
        // A phrase has to clear a higher bar in total, but its individual words
        // do not: "Claude Code" is two five-letter words and unmistakable, while
        // a single "Code" would collide with half the language.
        return words.count > 1 ? letters >= 8 : letters >= minimumSoundsLike
    }

    private static func accepts(phrase: String, as term: String, words: Int) -> Bool {
        // A phrase is allowed to be made of real words. "Cloud coat" is two
        // perfectly good English words and still obviously a misheard "Claude
        // Code"; requiring otherwise would make multi-word terms useless. The
        // protection is that every word has to match by sound in sequence, which
        // is a far stronger signal than one word matching alone.
        if words == 1 && isRealWord(phrase) { return false }
        // A wild length difference means the codes collided rather than the
        // speaker being misheard.
        return Double(phrase.count) >= Double(term.count) * 0.6
            && Double(phrase.count) <= Double(term.count) * 1.6
    }
}

private extension Character {
    /// Matches what `\b` in ICU regex considers a word character, so the
    /// anchoring decision above and the regex engine agree.
    var isWordLike: Bool { isLetter || isNumber || self == "_" }
}
