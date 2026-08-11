import Foundation

/// Whether a sentence looks like the speaker restarted mid-way through it.
///
/// A deterministic gate in front of an expensive model call, and the reason the
/// repair pass is affordable at all. Repairing everything means a second model
/// request on every dictation, which roughly doubles the wait between letting go
/// of the key and the text appearing. Measured over a real 260-dictation
/// history: 88% of dictations contain no sentence that trips this, and gating on
/// it sends 13% of dictated characters to the repair model rather than 100%. On
/// a 2,201-character dictation, 17 sentences with 1 tripping the gate, polishing
/// went 6.7s ungated to 15.3s, and 6.7s to 8.2s gated.
///
/// This decides *whether to ask*, never what the answer is. It is allowed to be
/// wrong in one direction only: a false positive costs one model call that comes
/// back unchanged, while a false negative silently gives up a repair. So every
/// rule here is a signal of a restart, not proof of one, and none of them edits
/// anything. `Polisher.repairInstructions` still decides.
enum SpeechRepair {
    /// Determiners, because a restart re-opens the phrase with the same one.
    private static let determiners: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "its",
        "this", "that", "these", "those",
    ]

    /// Words that make a second determiner a list or a prepositional phrase
    /// rather than a restart: "the laptop **and** the charger" is not one.
    private static let joiners: Set<String> = [
        "and", "or", "but", "then", "plus", "with", "for", "to", "of", "in",
        "on", "at", "from", "by",
    ]

    /// What people say out loud when they correct themselves.
    private static let cues = [" sorry ", " i mean ", " rather "]

    /// Two kinds of restart deliberately have no rule here, though both look
    /// like they should, and both were written and then removed on measurement.
    ///
    /// **A word repeated verbatim** ("we should we should", "on on this
    /// screen"): the polish pass already deletes these on its own, every one
    /// tried. Gating on it sent 11 more sentences to the repair model for no
    /// change in output, and cost something: it is the rule that fires on
    /// deliberate repetition, and "Hello, dust, dust, dust" came back as "Hello,
    /// dust" with it in place.
    ///
    /// **A word cut off and restarted** ("once you m migrate", "not su
    /// sufficient"): polish repairs every one of those that the repair model
    /// can, and the one case polish misses ("the pro problem") the repair model
    /// misses too.
    ///
    /// The lesson generalises. Before adding a rule here, check what polishing
    /// alone already does with it, because the answer is often "fixes it".
    static func isLikely(in sentence: String) -> Bool {
        let words = words(in: sentence)
        return reopensAPhrase(words) || announcesACorrection(words)
    }

    /// Letters only, so punctuation and casing cannot hide a repeat. Apostrophes
    /// stay in, or "I'll" splits into a bare "ll" that matches nothing useful.
    private static func words(in sentence: String) -> [String] {
        sentence.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
    }

    /// "the doc the spreadsheet": the same determiner again within two words.
    ///
    /// The window is this tight on purpose. A restart re-opens the phrase almost
    /// immediately, so the abandoned noun phrase is one or two words long.
    /// Widening it to four words matched "at the top we wanna add the screen
    /// recording", which is two unrelated phrases in one sentence, and took the
    /// pass from a quarter of dictated text to two fifths without catching a
    /// single repair the narrow window missed.
    private static func reopensAPhrase(_ w: [String]) -> Bool {
        for (i, word) in w.enumerated() where determiners.contains(word) {
            let upper = min(i + 4, w.count)
            guard i + 2 < upper else { continue }
            for j in (i + 2)..<upper where w[j] == word {
                if w[(i + 1)..<j].contains(where: joiners.contains) { break }
                return true
            }
        }
        return false
    }

    /// "we should ask Tom sorry Tim about the invoice".
    private static func announcesACorrection(_ w: [String]) -> Bool {
        let joined = " " + w.joined(separator: " ") + " "
        return cues.contains { joined.contains($0) }
    }
}
