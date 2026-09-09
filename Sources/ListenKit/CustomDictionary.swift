import Foundation

/// The user's own vocabulary: the file, the entries, and the exact replacements.
///
/// **This half is shared with the phone; the sounds-like half is not, and that
/// is a decision rather than an omission.** A correction is pure string work. A
/// term is matched by sound, and the sound matching leans on
/// `/usr/share/dict/words` to refuse rewriting a real English word, which iOS
/// does not have. Ported without it, the phone would either do nothing at all
/// (the terms pass returns early on an empty lexicon) or, worse, rewrite
/// ordinary English with every guard disabled at once.
///
/// So the split is physical. The Mac target adds the terms half in an extension
/// of this type, and the phone cannot call what is not compiled into it. If the
/// word list is ever bundled for iOS, this file is where the two halves meet
/// again.
///
/// Both devices reading one `dictionary.json` is the point: a device with a
/// different vocabulary produces a differently corrected transcript of the same
/// audio, which is why `DevicePolicy` syncs the file at all.
public enum CustomDictionary {
    public enum Kind: String, Codable {
        case term
        case correction
    }

    public struct Entry: Codable, Equatable {
        public var kind: Kind
        /// The term itself, or the text a correction looks for.
        public var text: String
        /// Corrections only. Empty for terms.
        public var replacement: String
        /// Corrections only. Off means "listen" also matches "Listen".
        public var caseSensitive: Bool
        public var enabled: Bool

        public init(kind: Kind, text: String, replacement: String = "",
             caseSensitive: Bool = false, enabled: Bool = true) {
            self.kind = kind
            self.text = text
            self.replacement = replacement
            self.caseSensitive = caseSensitive
            self.enabled = enabled
        }

        /// The key this entry's firings are counted under.
        public var countKey: String { "\(kind.rawValue):\(text)" }
    }

    /// Beside the recordings, in `~/Library/Application Support/Listen`.
    ///
    /// Listen's own file, deliberately not Speak's. Sharing one file would save
    /// maintaining two lists of the same people's names, and it would mean two
    /// apps writing a document that is rewritten whole every time, where the
    /// loser of a race loses entries rather than a merge. Import and export
    /// carry the list across instead, which is the same convenience without the
    /// shared-mutable-state half.
    public static func file(in root: URL) -> URL {
        root.appendingPathComponent("dictionary.json")
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
    public static func load(in root: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: file(in: root)),
              let doc = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        return doc.entries
    }

    public static func save(_ entries: [Entry], in root: URL) {
        try? FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)

        guard let data = encode(entries) else { return }
        // Atomic: a crash mid-write must not leave the user with neither the old
        // list nor the new one.
        try? data.write(to: file(in: root), options: .atomic)
    }

    /// Read entries out of a file, accepting more shapes than `save` writes.
    ///
    /// Deliberately liberal. A dictionary is worth years of corrections, and the
    /// reason anyone has one to import is that they built it in another app, so
    /// refusing a file over a key name would defeat the point. Three shapes are
    /// understood:
    ///
    /// - `{"version": 1, "entries": [...]}`, which is what Listen writes and
    ///   also what Speak wrote, so an old file from that app still imports.
    /// - A bare array of entries, which is what TypeWhisper exports.
    /// - Either of those with any of the three apps' key names, per entry.
    ///
    /// TypeWhisper calls the fields `type`, `original` and `isEnabled` where
    /// Listen calls them `kind`, `text` and `enabled`, and its term entries
    /// carry a `ctcMinSimilarity` that Listen has no use for and drops.
    ///
    /// Returns nil only when the file is not JSON in either shape. Entries that
    /// cannot mean anything, having no text to match, are skipped rather than
    /// failing the import.
    public static func decode(_ data: Data) -> [Entry]? {
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

    /// Pretty-printed, stably ordered, and the same document `decode` reads.
    ///
    /// One shape both ways is what makes "export here, import there" a complete
    /// answer rather than a one-way trip, between two Macs and out of the app
    /// entirely. Hand-editing the stored file is also a supported way to use
    /// it, and a diff of one changed word should be one changed line.
    public static func encode(_ entries: [Entry]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(Document(version: 1, entries: entries))
    }

    public struct MergeResult {
        public var added: [Entry]
        /// Entries already present, by kind and text. Reported rather than
        /// duplicated: importing the same file twice should be harmless.
        public var duplicates: Int
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
    public static func merge(_ incoming: [Entry], into existing: [Entry]) -> MergeResult {
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

    /// A rewritten string and the rules that rewrote it.
    public struct Applied {
        public var text: String
        /// How often each rule fired, keyed by `Entry.countKey`.
        public var fired: [String: Int] = [:]

        /// Written out because Swift does not synthesise a public memberwise
        /// initialiser, and the terms half builds these from the other module.
        public init(text: String, fired: [String: Int] = [:]) {
            self.text = text
            self.fired = fired
        }
    }

    /// Add one string's counts into a running total.
    public static func combine(_ counts: [String: Int], into total: inout [String: Int]) {
        for (key, n) in counts { total[key, default: 0] += n }
    }

    /// Whether applying a correction to its own replacement changes it again.
    private static func growsItself(_ e: Entry, pattern: String) -> Bool {
        replace(pattern, with: e.replacement, in: e.replacement,
                caseSensitive: e.caseSensitive).text != e.replacement
    }

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
    /// `again: true` is the pass that runs *after* polishing. See `applyAround`.
    public static func applyCorrections(to text: String, entries: [Entry],
                                        again: Bool = false) -> Applied {
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
            // A rule whose replacement still contains its own pattern cannot run
            // twice: "Speak" to "Speak app" would give "Speak app app" on the
            // second pass. Skipped after polishing, where the first pass has
            // already done the work.
            if again, growsItself(entry, pattern: pattern) { continue }
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
}

extension Character {
    /// Matches what `\b` in ICU regex considers a word character, so the
    /// anchoring decision above and the regex engine agree.
    var isWordLike: Bool { isLetter || isNumber || self == "_" }
}
