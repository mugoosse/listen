import Foundation

/// Tidying that belongs to neither the dictionary nor the model.
///
/// Dictation only. A meeting transcript is prose and every sentence in it has
/// earned its full stop; this is about the one-word answer somebody dictates
/// into a search field.
enum Punctuation {
    /// A dictation of this many words or fewer is treated as a fragment.
    ///
    /// Four covers what people dictate into a field rather than a document:
    /// a name, a date, a search, a short reply. Five and up is usually a
    /// sentence, and a sentence has earned its full stop.
    static let fragmentWords = 4

    /// Drop the full stop a speech engine puts on the end of a short fragment.
    ///
    /// Parakeet punctuates as it transcribes and treats every utterance as a
    /// sentence, so dictating one word gives you "Claude." rather than
    /// "Claude". Counted over one real Speak history, 14 of 16 dictations of
    /// four words or fewer came back with terminal punctuation straight from
    /// the engine, before any polishing existed. This is not the polishing pass
    /// doing it, which is why the trimming runs whether or not polishing is on.
    ///
    /// Unconditional, and not a setting. A full stop on the end of a one-word
    /// answer is wrong in a search field, a form, a file name and a spreadsheet
    /// cell, and in prose it is a character the user can type. Offering the
    /// choice would be asking everyone to decide something that has an answer.
    ///
    /// Only a full stop is removed. A question mark or an exclamation mark
    /// carries meaning that a full stop does not, and dropping one would change
    /// what the words say.
    static func trimFragment(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".") else { return text }
        let body = String(trimmed.dropLast())
        guard !body.isEmpty else { return text }

        // A sentence break anywhere means this is prose, whatever its length.
        // Tested for as punctuation *followed by a space* so that a full stop
        // inside a domain does not disqualify it: "flyinpublic.com." is still
        // one fragment.
        guard !body.contains(". "), !body.contains("? "), !body.contains("! "),
              !body.contains(where: { $0 == "?" || $0 == "!" }),
              !body.contains("\n")
        else { return text }

        guard body.split(whereSeparator: \.isWhitespace).count <= fragmentWords
        else { return text }

        return body
    }
}
