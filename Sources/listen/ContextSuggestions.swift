import Foundation
import ListenKit

/// Corrections an agent has proposed to a claim in person or project memory,
/// and nothing has applied.
///
/// ## Why this exists at all
///
/// `person-context.md` states the rule this file works around: the model
/// proposes, and Listen owns identity and evidence. An agent reading a
/// transcript can see perfectly well that a claim misreads it, and until now
/// had nowhere to put that. `get_person_context` hands out claim ids, and
/// `context correct` is the window's and the CLI's alone, so the agent's only
/// outlet was prose in an answer that dies with the conversation.
///
/// **`DictionarySuggestions` is the model, deliberately and closely.** That
/// file solved the same shape a fortnight earlier: something notices a rule
/// worth having, and a human is the only thing allowed to write it. Two stores
/// with the same job and different tempers would be two sets of bugs, so this
/// one is the same document, the same worklist behaviour and the same
/// encoder settings.
///
/// ## Proposing, never applying
///
/// Nothing here writes to the context store. A claim is quoted in answers and
/// carries dated evidence, so a correction nobody read would be worse than the
/// error it fixed: the wrong text would then be wearing the user's own
/// authority. Accepting routes through `ContextStore.override`, which is the
/// same call `listen context correct` makes and the same one the person page
/// makes, so there is one correction contract and this is a queue in front of
/// it.
///
/// ## What may be proposed, and what may not
///
/// The **wording only**. A suggestion cannot move a claim to another subject,
/// change its predicate, or touch its evidence, because those are the three
/// things `person-context.md` reserves. That is not enforced by validation so
/// much as by shape: the only field carried is the replacement text, which is
/// exactly what `context correct <claim-id> <text>` takes.
///
/// ## What is not kept
///
/// A dismissal is a claim id and nothing else, and an accepted suggestion is
/// deleted rather than archived. The evidence for every claim is still in the
/// recordings, so this file is a worklist and never a second copy of anything.
///
/// ## Local, like its model
///
/// Not in `DevicePolicy.blobs`. `dictionary.json` syncs because two devices
/// with different vocabularies produce differently corrected transcripts;
/// `dictionary-suggestions.json` does not, because a worklist is not a fact
/// about the library. The same is true here, and more so: the context store has
/// an owner projection with its own correction register, and a second,
/// unreviewed opinion travelling beside it would be a third thing to reconcile.
enum ContextSuggestions {

    struct Suggestion: Codable, Equatable {
        /// The claim this is about, as `get_person_context` returned it.
        var claim: String
        /// Who or what the claim is filed under, for the row to be readable
        /// without opening the card.
        var entity: String
        var entityName: String
        /// The claim as it stands, kept so a row can show both halves and so an
        /// acceptance can tell whether the claim moved underneath it.
        var was: String
        /// What the agent says it should say.
        var text: String
        /// Why, in the agent's words. The part a human actually reads before
        /// deciding, and the reason this is not just a diff.
        var why: String
        /// When it was proposed.
        var at: Date
    }

    private struct Document: Codable {
        var version: Int = 1
        var suggestions: [Suggestion] = []
        /// Claim ids somebody has said no to.
        var dismissed: [String] = []
    }

    static var file: URL {
        Library.root.appendingPathComponent("context-suggestions.json")
    }

    /// Read on every call, like `CustomDictionary.load` and for the same reason:
    /// the window, the CLI and a spawned `listen mcp` are three processes over
    /// one file, and a cache here would need invalidating from all of them.
    private static func read() -> Document {
        let decoder = JSONDecoder()
        // **The same strategy `write` encodes with**, which is the bug
        // `notes-tags-dictionary.md` records against the file this one copies: a
        // plain `JSONDecoder` reads dates as seconds since 2001 and throws on an
        // ISO-8601 string, `try?` turns that into an empty list, and every
        // suggestion ever written is invisible with nothing saying so.
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
    // Proposing
    // -----------------------------------------------------------------------

    /// Record a proposal, or say why it was not recorded.
    ///
    /// Dismissal wins over a repeat proposal, which is what makes the button
    /// worth pressing: an agent that re-reads the same transcript next week
    /// reaches the same conclusion, and somebody who has already said no should
    /// not be asked again. `DictionarySuggestions` remembers a dismissal for
    /// the same reason.
    ///
    /// A second proposal for a claim already queued replaces the first rather
    /// than stacking: the newer reading is the one drawn from more of the
    /// library, and a queue with two opinions about one claim is a queue
    /// somebody has to arbitrate before they can act on either.
    @discardableResult
    static func propose(_ suggestion: Suggestion) -> Bool {
        var doc = read()
        guard !doc.dismissed.contains(suggestion.claim) else { return false }
        doc.suggestions.removeAll { $0.claim == suggestion.claim }
        doc.suggestions.append(suggestion)
        write(doc)
        return true
    }

    // -----------------------------------------------------------------------
    // Reading and acting
    // -----------------------------------------------------------------------

    /// Everything waiting, newest first.
    static func pending() -> [Suggestion] {
        read().suggestions.sorted { $0.at > $1.at }
    }

    static func find(_ claim: String) -> Suggestion? {
        read().suggestions.first { $0.claim == claim }
    }

    /// Apply one through the same call the window and the CLI make.
    ///
    /// `ContextStore.override` and then a `SemanticIndex.refresh`, which is
    /// exactly what `listen context correct` does: a correction that did not
    /// reach the index is a correction that search still disagrees with.
    static func accept(_ suggestion: Suggestion) throws {
        try ContextStore.override(id: suggestion.claim, replacement: suggestion.text)
        try SemanticIndex.refresh()
        forget(suggestion.claim)
    }

    /// No, and do not offer this claim again.
    static func dismiss(_ claim: String) {
        var doc = read()
        doc.suggestions.removeAll { $0.claim == claim }
        if !doc.dismissed.contains(claim) { doc.dismissed.append(claim) }
        write(doc)
    }

    /// Take one off the list without remembering a refusal, which is what an
    /// acceptance is: the claim now reads correctly, so there is nothing left
    /// to offer and nothing to suppress.
    static func forget(_ claim: String) {
        var doc = read()
        doc.suggestions.removeAll { $0.claim == claim }
        write(doc)
    }
}
