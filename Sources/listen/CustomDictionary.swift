import Foundation
import ListenKit

/// The user's own vocabulary: words to spell right, and text to replace.
///
/// Named `CustomDictionary` because `Dictionary` is `Swift.Dictionary`, and
/// shadowing that in a codebase full of `[String: Any]` would be a cruelty.
///
/// Ported from Speak, where the rules were tuned. All three of its mechanisms
/// are here now: a term is matched by sound, a term is also a spelling hint in
/// the polishing model's prompt, and a correction is a literal replacement. The
/// prompt half was dropped while Listen had no polisher and came back with
/// dictation. The other two are pure text over Foundation and need no model.
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
/// **One list, two pipelines.** A name Listen mishears in a meeting is the same
/// name it mishears in a dictation, so there is one file and one editor rather
/// than a second list to fix the same word in twice.
///
/// In `Pipeline.run`, once, on the segments that are about to be written to the
/// library. And in `Dictation.finish`, through `applyAround`, which runs the
/// corrections either side of polishing and the sounds-like pass only on the raw
/// transcript. The two entry points differ because the pipelines do: a meeting
/// has no model between its halves, and a dictation has one that rewrites the
/// very words the rules look for.
///
/// The meeting side is the stronger commitment, and it needs saying plainly: a
/// dictation is text you are about to paste and can see, while a meeting
/// transcript is an archive nobody may read for a week. A bad rule applied there
/// rewrites recordings quietly, and the only surviving evidence is the audio.
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
extension CustomDictionary {

    // -----------------------------------------------------------------------
    // Where the Mac's copy lives
    // -----------------------------------------------------------------------

    /// The shared half takes a library root, because the phone's is somewhere
    /// else entirely. On the Mac there is only one answer and fourteen callers,
    /// so it is spelled once here rather than at each of them.
    static var file: URL { file(in: Library.root) }
    static func load() -> [Entry] { load(in: Library.root) }
    static func save(_ entries: [Entry]) { save(entries, in: Library.root) }


    // -----------------------------------------------------------------------
    // Storage
    // -----------------------------------------------------------------------


    // -----------------------------------------------------------------------
    // Import and export
    // -----------------------------------------------------------------------


    // -----------------------------------------------------------------------
    // Applying
    // -----------------------------------------------------------------------


    /// Corrections then terms, with the counts.
    ///
    /// One entry point rather than two, so nothing downstream has to remember
    /// the order. Corrections first because an explicit rule the user wrote
    /// outranks a phonetic guess, and because a correction's replacement is then
    /// safe from being re-matched by a term that sounds like it.
    static func apply(to text: String, entries: [Entry]? = nil) -> Applied {
        let list = entries ?? load()
        guard !list.isEmpty else { return Applied(text: text) }
        var out = applyCorrections(to: text, entries: list)
        let terms = self.terms(in: out.text, entries: list)
        out.text = terms.text
        for (key, n) in terms.fired { out.fired[key, default: 0] += n }
        return out
    }


    /// Corrections around a polishing pass: once on the raw transcript, once on
    /// what came back.
    ///
    /// Dictation only. The meeting pipeline has no polisher between its two
    /// halves, so `apply` is the whole story there and this would be a second
    /// pass over the same text for nothing.
    ///
    /// Both runs are needed, and each fixes what the other cannot.
    ///
    /// Before, because polishing rewrites the very words the rules look for.
    /// Measured on a real dictionary: "pagament to the Portagens" was tidied
    /// into "payment to the Portagens" and "maxim Gusens" into "Maxim Gusens",
    /// and in both cases the rule written for the raw transcript then matched
    /// nothing. Correcting first also hands the model the right proper nouns,
    /// which is the difference between it keeping "Hetzner" and inventing a
    /// spelling for a word it does not know.
    ///
    /// After, because the model is free to change anything it was given, so this
    /// is what makes a rule the user wrote the final word.
    ///
    /// Sounds-like runs only on the raw transcript. Mishearings come from the
    /// microphone, not from the model.
    static func applyAround(_ text: String,
                            polish: (String) async -> String) async -> Applied {
        // Loaded once: the file is small, but the two passes must agree, and
        // re-reading between them would let an edit land in the middle.
        let entries = load()
        guard !entries.isEmpty else { return Applied(text: await polish(text)) }

        var out = applyCorrections(to: text, entries: entries)
        let sounded = terms(in: out.text, entries: entries)
        out.text = sounded.text
        combine(sounded.fired, into: &out.fired)

        let after = applyCorrections(to: await polish(out.text), entries: entries,
                                     again: true)
        out.text = after.text
        combine(after.fired, into: &out.fired)
        return out
    }


    /// The enabled terms as a comma-separated list for the polish prompt, capped
    /// at `capChars`.
    ///
    /// Capped because the model's context window holds the instructions, the
    /// transcript and the reply together: a long list would crowd out the text it
    /// is meant to help. Entries are taken in order, so the top of the list is
    /// the part that survives a cap.
    ///
    /// Terms do two jobs, and this is the weaker one. The repair happens in
    /// `terms(in:entries:)`, deterministically and with no model, which is what
    /// makes it work with polishing off. This stops the model rewriting words it
    /// does not know: measured in Speak, `flyinpublic.com` survived 0 of 6 runs
    /// without a hint and 5 of 6 with one.
    static func termHints(_ entries: [Entry]? = nil, capChars: Int = 600) -> String {
        let terms = (entries ?? load())
            .filter { $0.kind == .term && $0.enabled }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out = ""
        for term in terms {
            let addition = out.isEmpty ? term : ", " + term
            if out.count + addition.count > capChars { break }
            out += addition
        }
        return out
    }

    /// Build the word list before anybody is waiting on it.
    ///
    /// `lexicon` is lazy and reads `/usr/share/dict/words`, which is a fraction
    /// of a second nobody should spend between letting go of a key and seeing
    /// their words. Called when a dictation starts, alongside the polisher's own
    /// prewarm.
    static func warm() { _ = lexicon.isEmpty }

    // MARK: Corrections


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
    ///
    /// A silent "gh" says nothing, which Soundex proper does not know and which
    /// costs more here than anywhere else: English writes the sound at the end
    /// of "site" as "ight" about as often as it writes it "ite". A term spelled
    /// "Kinsight" coded to k5223 while every mishearing of it, "Kinsite",
    /// "Kinside", "Kingside", "Kinzite", coded to k523, so the sounds-like pass
    /// could never match the word it had been handed. Measured on a day of
    /// dictation history: six of the eight misheard instances of one product
    /// name, none of which the term could reach.
    static func phoneticKey(_ s: String) -> String {
        let letters = Array(s.lowercased().filter(\.isLetter))
        guard let first = letters.first else { return "" }
        var key = String(first)
        var previous = consonantClass(first)
        for i in 1..<letters.count {
            let c = letters[i]
            if isSilentGH(letters, at: i) { continue }
            if let d = consonantClass(c) {
                if d != previous { key.append(d) }
                previous = d
            } else if c != "h", c != "w" {
                previous = nil
            }
        }
        return key
    }

    /// Whether the "g" at `i` is the silent half of a "gh".
    ///
    /// Two conditions, and both are needed. A vowel before, because "Afghan"
    /// pronounces its g. A consonant after, or the end of the word, because
    /// that is what separates a silent "gh" from one starting a syllable of its
    /// own: "sight" and "though" against "doghouse" and "foghorn".
    ///
    /// The h itself needs no case here. It is already ignored, and ignored
    /// without breaking a run, everywhere in `phoneticKey`.
    private static func isSilentGH(_ letters: [Character], at i: Int) -> Bool {
        guard letters[i] == "g", i > 0, i + 1 < letters.count,
              letters[i + 1] == "h",
              consonantClass(letters[i - 1]) == nil
        else { return false }
        return i + 2 >= letters.count || consonantClass(letters[i + 2]) != nil
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
    static func isRealWord(_ w: String) -> Bool {
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

    /// How many spoken words a one-word term is allowed to take.
    ///
    /// Three, because that is the shape of the mishearing: a compound name is
    /// broken at its own seams and nowhere else, so "Kinsight" comes back as
    /// "kin site" and "flyinpublic" as "fly in public". Four would start gluing
    /// clauses together for the length guard in `accepts` to throw away again.
    private static let maximumJoin = 3

    /// One way a term may match: a run of `span` tokens, keyed either word for
    /// word or with the gaps closed up.
    private struct Candidate {
        /// How many tokens this consumes.
        let span: Int
        /// One key per word of the term, or the single key of the whole term
        /// when `closesGaps`.
        let keys: [String]
        /// Whether the span is keyed as one word rather than word by word.
        let closesGaps: Bool
        let entry: Entry

        /// `table[n - 1][i]` is the key of the `n` tokens starting at `i`.
        func matches(at i: Int, in table: [[String]]) -> Bool {
            closesGaps
                ? table[span - 1][i] == keys[0]
                : keys.enumerated().allSatisfy { table[0][i + $0.offset] == $0.element }
        }
    }

    /// Every way each enabled term may match, longest span first.
    ///
    /// A term of several words is matched word for word, which is the strong
    /// signal `accepts` leans on to allow a span of real words. A term of one
    /// word gets those spans too, but keyed as one word, because a compound
    /// name is precisely what an ASR splits and a one-token matcher could never
    /// see it: of eight misheard instances of "Kinsight" in a day of dictation
    /// history, two arrived as two words and nothing in the list could reach
    /// them.
    ///
    /// Longest first, so a term for "Claude Code" beats one for "Claude", and a
    /// two-word span of a compound name beats a one-word one.
    private static func candidates(from entries: [Entry]) -> [Candidate] {
        entries
            .filter { $0.kind == .term && $0.enabled && eligible($0.text) }
            .flatMap { entry -> [Candidate] in
                let keys = entry.text.split(separator: " ").map { phoneticKey(String($0)) }
                guard keys.count == 1 else {
                    return [Candidate(span: keys.count, keys: keys,
                                      closesGaps: false, entry: entry)]
                }
                return (1...maximumJoin).map {
                    Candidate(span: $0, keys: keys, closesGaps: true, entry: entry)
                }
            }
            .enumerated()
            // Explicit index tiebreak: sorted(by:) is not a stable sort, so
            // without it equal-span candidates would shuffle between runs.
            .sorted {
                $0.element.span == $1.element.span
                    ? $0.offset < $1.offset
                    : $0.element.span > $1.element.span
            }
            .map(\.element)
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
        let candidates = self.candidates(from: entries)
        guard !candidates.isEmpty, !lexicon.isEmpty else { return Applied(text: text) }

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

        // Every key the loop below can ask for, computed once rather than once
        // per term. Coding a token is the expensive half and it does not depend
        // on which term is being tried: 200 terms over 7500 words measured 3.2s
        // asking per term against 0.55s asking once.
        //
        // Only as many rows as there is something to match: a list of nothing
        // but multi-word terms never keys a run at all.
        let joins = candidates.contains { $0.closesGaps && $0.span > 1 } ? maximumJoin : 1
        let words = tokens.map(\.word)
        let table: [[String]] = (1...joins).map { n in
            (0..<tokens.count).map { i in
                i + n <= tokens.count ? phoneticKey(words[i..<(i + n)].joined()) : ""
            }
        }

        var out = ""
        var fired: [String: Int] = [:]
        var cursor = text.startIndex
        var i = 0
        while i < tokens.count {
            var advance = 1
            for candidate in candidates where i + candidate.span <= tokens.count {
                let span = Array(tokens[i..<(i + candidate.span)])
                // Punctuation inside the span means these words are not one
                // phrase: "the cloud. Coat rack" is not "Claude Code". The
                // tails cover punctuation stuck to a word.
                //
                // Anything standing between the words covers the rest, and it
                // is not the same guard. The token pattern has to start on a
                // letter, so a full stop with a space either side is in no
                // token's tail and no token's word: it is invisible here, and
                // the splice below replaces the whole span from the first
                // word's start to the last word's end, so it would be deleted
                // along with them. Measured on a corpus of 152 dictations
                // joined by " . ", where "Kinsite . Oh" keyed as "kinsiteoh"
                // and became one word.
                guard span.dropLast().allSatisfy({ $0.tail.isEmpty }),
                      zip(span, span.dropFirst()).allSatisfy({ a, b in
                          text[a.range.upperBound..<b.range.lowerBound]
                              .allSatisfy { $0 == " " }
                      }),
                      candidate.matches(at: i, in: table)
                else { continue }

                let phrase = span.map(\.word).joined(separator: " ")
                guard phrase.caseInsensitiveCompare(candidate.entry.text) != .orderedSame else {
                    advance = candidate.span       // already right, leave it alone
                    break
                }
                // A span that already contains the term is already right, and
                // replacing it deletes whatever else the span covered.
                // Measured on a real library: "you Kinsight to work for them"
                // matched "Kinsight to" as a gap-closed span and rewrote it as
                // "Kinsight", eating the "to". The shorter candidate that
                // follows matches the word itself and takes the line above.
                guard !span.contains(where: {
                    $0.word.caseInsensitiveCompare(candidate.entry.text) == .orderedSame
                }) else { continue }
                guard accepts(phrase: phrase, as: candidate.entry.text,
                              words: candidate.span,
                              joined: candidate.closesGaps && candidate.span > 1
                                  ? span.map(\.word).joined() : nil)
                else { continue }

                out += String(text[cursor..<span[0].range.lowerBound])
                    + candidate.entry.text + span.last!.tail
                cursor = span.last!.range.upperBound
                fired[candidate.entry.countKey, default: 0] += 1
                advance = candidate.span
                break
            }
            i += advance
        }
        return Applied(text: out.isEmpty ? text : out + text[cursor...], fired: fired)
    }

    /// Levenshtein distance, iterative and over two rows.
    ///
    /// Called on a gap-closed span, which is at most three short words against
    /// one term, and by `DictionarySuggestions.scan` on one word against one
    /// name. The quadratic cost is nothing at those sizes and the alternative
    /// would be a dependency.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty else { return y.count }
        guard !y.isEmpty else { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                current[j] = x[i - 1] == y[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            swap(&previous, &current)
        }
        return previous[y.count]
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

    /// An English word that sounds the same as `term`, if there is one.
    ///
    /// The one thing somebody adding a word cannot find out by reading their own
    /// rule, and the reason "Beehiiv" sat in a dictionary doing nothing: the
    /// sounds-like net refuses to swap a real word for a term, so a term whose
    /// sound collides with an English word never fires on the very mishearing it
    /// was added for. "beehive" is a word, so "bee hive" and "beehive" are both
    /// left alone, for ever, silently.
    ///
    /// The alternative to saying so in the sheet is finding out a week later, in
    /// an archive, by noticing the word is still wrong.
    ///
    /// One word only. A phrase is allowed to be made of real words, because
    /// every word has to match in sequence and that is a far stronger signal:
    /// see `accepts(phrase:as:words:joined:)`.
    ///
    /// **Sharing a key is not enough, and the first version said so out loud.**
    /// Soundex is lossy, so "knagged" codes the same as "Kinsight" and the sheet
    /// told somebody adding Kinsight that ordinary English would shield it,
    /// which is false: the term fires on "kinside" and "kin site" perfectly
    /// well. A collision worth warning about is one somebody might actually
    /// type, so the word also has to be within the same half-the-length edit
    /// bound the gap-closing guard uses. "beehive" is 2 from "Beehiiv" and
    /// stays; "knagged" is 6 from "Kinsight" and goes.
    static func englishSoundalike(for term: String) -> String? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), eligible(trimmed), !isRealWord(trimmed),
              let words = soundalikes[phoneticKey(trimmed)],
              let word = words.min(by: {
                  distance($0, trimmed.lowercased()) < distance($1, trimmed.lowercased())
              }),
              distance(word, trimmed.lowercased()) <= max(1, trimmed.count / 2)
        else { return nil }
        return word
    }

    /// The lexicon indexed by sound, built once and only if somebody asks.
    ///
    /// About 235,000 words, so it is a real cost and it is paid on a background
    /// queue by the one caller that wants it. `lexicon` itself is already loaded
    /// lazily for the same reason.
    ///
    /// Every word that codes alike, so the caller can pick the one closest to
    /// the term.
    ///
    /// Two wrong versions came first, and both failed the same way. Keeping the
    /// *shortest* word per key never showed "beehive" for "Beehiiv", because the
    /// code is lossy enough that "b1" is shared by hundreds of words and the
    /// shortest of them is three letters long. Capping the bucket at the twelve
    /// shortest failed for exactly the same reason. The word that explains a
    /// term is the one spelled like it, and length has nothing to do with it.
    ///
    /// So the buckets are whole. That is about 235,000 words in arrays beside
    /// the set they came from, built lazily and only when somebody opens the
    /// sheet, which is the one place in the app that asks.
    private static let soundalikes: [String: [String]] = {
        var out: [String: [String]] = [:]
        for word in lexicon where word.count >= minimumSoundsLike {
            let key = phoneticKey(word)
            guard !key.isEmpty else { continue }
            out[key, default: []].append(word)
        }
        return out
    }()

    /// `joined` is the span with its gaps closed up, and is set only for a
    /// one-word term that took several spoken words. nil when the term matched
    /// word for word.
    private static func accepts(phrase: String, as term: String, words: Int,
                                joined: String? = nil) -> Bool {
        // A phrase is allowed to be made of real words. "Cloud coat" is two
        // perfectly good English words and still obviously a misheard "Claude
        // Code"; requiring otherwise would make multi-word terms useless. The
        // protection is that every word has to match by sound in sequence, which
        // is a far stronger signal than one word matching alone.
        if words == 1 && isRealWord(phrase) { return false }
        // Closing the gaps is the weaker of the two signals, because it is one
        // key over a boundary the speaker did put in, so it keeps the real-word
        // guard on the thing it would be making: "in sight" is "insight", and
        // must not become somebody's product name.
        if let joined, isRealWord(joined) { return false }
        // And the real-word guard is not enough on its own, because the thing
        // being made is usually not a word at all. Soundex is deliberately
        // lossy: it keeps the first letter and codes the rest into groups, so
        // "knows the" and "know I said" both code exactly as "Kinsight" does
        // and neither "knowsthe" nor "knowisaid" is in the lexicon to be
        // refused. Measured over 75 real transcripts against a one-term
        // dictionary: 3 of 20 rewrites were this, and two of them destroyed a
        // sentence.
        //
        // So a gap-closed span also has to *look* like the term, not only sound
        // like it, and half the term's length is where the two groups actually
        // separate. Edit distance to "Kinsight", measured on the spans this
        // library produced:
        //
        //     kinsite   3     the case the feature was built for
        //     kinside   3     the same, one word
        //     cansite   5     already refused, and should stay refused
        //     knowsthe  6     "knows the"
        //     knowisaid 7     "know I said"
        //
        // So 4 for an eight-letter term: everything real is at 3, everything
        // wrong starts at 5. Spelling is a second opinion here rather than the
        // main one: it only ever applies to spans joined across a boundary the
        // speaker did put in, and single words are untouched, so "Gusens" still
        // becomes "Goossens".
        // A one-letter word in a gap-closed span is a pronoun or an article,
        // never a syllable of somebody's product name. "know I got" codes as
        // "Kinsight" and sits exactly on the distance bound below; "fly in
        // public" and "kin site", which the feature exists for, have no
        // one-letter word in them.
        if joined != nil, phrase.split(separator: " ").contains(where: { $0.count == 1 }) {
            return false
        }
        // The joined form when the span was closed up, the word itself when it
        // was not, because comparing "kim site" to "Kinsight" charges an edit
        // for the space the speaker put in and loses a real mishearing at 5.
        // Judged on the joined form it is 4, inside the bound, and stays.
        if distance((joined ?? phrase).lowercased(), term.lowercased())
            > max(1, term.count / 2) { return false }
        // A wild length difference means the codes collided rather than the
        // speaker being misheard.
        return Double(phrase.count) >= Double(term.count) * 0.6
            && Double(phrase.count) <= Double(term.count) * 1.6
    }
}

