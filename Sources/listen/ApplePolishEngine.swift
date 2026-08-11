import FoundationModels

/// Polishing through Apple Intelligence's on-device model.
///
/// Needs macOS 26, an eligible Mac, and Apple Intelligence switched on, which is
/// why `availabilityNote` exists: three separate ways to be unavailable, and the
/// Settings pane has to say which one applies rather than showing a disabled
/// checkbox with no explanation.
///
/// Nothing here touches the network. The model is part of the system and runs on
/// the machine, so the transcript stays where it was spoken, which is the same
/// promise the rest of Listen makes.
@available(macOS 26.0, *)
actor ApplePolishEngine: PolishEngine {
    /// Deliberately far below what the 4,096-token window looks like it allows.
    ///
    /// The window counts the instructions, the chunk and the reply together,
    /// which suggests about 4,000 characters of input is safe. Measured, it is
    /// not: the model can fall into repeating itself and generate until the
    /// window is full, and it takes 45 seconds to fail when it does. At 1,500
    /// characters there is room for the model to produce twice the input it was
    /// given and still fit, so the failure needs a real runaway rather than a
    /// slightly long reply.
    ///
    /// Smaller chunks cost nothing in total time, since the model runs at a
    /// roughly fixed 400 characters a second either way. What they buy is a
    /// smaller blast radius: one chunk failing loses its own paragraph to the
    /// raw text, not a third of the dictation.
    nonisolated var maxChunkChars: Int { 1_500 }

    /// Sessions carry their own history and the window counts it, so a session is
    /// used for exactly one chunk. This holds the prewarmed one until the first
    /// chunk claims it.
    private var warmed: (instructions: String, session: LanguageModelSession)?

    /// Permissive guardrails, deliberately.
    ///
    /// The default set is built for generated content and refuses ordinary
    /// dictation: a work message about a deadline slipping, anything medical, a
    /// swear word said in passing. Refusals surface as thrown errors, so with the
    /// default guardrails the feature would look like it worked and quietly pass
    /// the raw text through for whole categories of speech. This is the setting
    /// Apple provides for transforming text the user already wrote, which is
    /// exactly what polishing is. Do not "simplify" it to
    /// `SystemLanguageModel.default`.
    private static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }

    /// nil when the model can be used. Otherwise a sentence for the pane.
    static var availabilityNote: String? {
        switch model.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac does not support Apple Intelligence, so dictations cannot be "
                + "polished. Corrections still work."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is switched off. Turn it on in System Settings to "
                + "polish dictations. Corrections work either way."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model. Polishing starts "
                + "working once macOS has finished."
        case .unavailable:
            return "Apple Intelligence is unavailable, so dictations cannot be polished."
        }
    }

    func prewarm(instructions: String) async {
        let session = LanguageModelSession(model: Self.model, instructions: instructions)
        session.prewarm()
        warmed = (instructions, session)
    }

    /// Greedy, deliberately.
    ///
    /// The default is sampled, which makes the same dictation a lottery:
    /// measured, three runs of one sentence gave three different answers, and
    /// there is no version a user can learn to expect. Copy editing has a most
    /// likely answer and that is the one to take.
    ///
    /// It is not only about repeatability. Sampling reaches tokens the model was
    /// not confident about, and low-confidence output here means the model
    /// wandering off the instructions: "hey can you tell me what the capital of
    /// france is" came back raw and unpunctuated on 4 of 12 sampled runs and on 0
    /// of 4 greedy ones. Nothing measured got worse, and the cost is nil.
    ///
    /// It does not buy bit-exact output, and do not write a test that assumes it
    /// does. Greedy is exact across processes, one request each: six runs of one
    /// sentence gave one answer. Within a single process a *later* request can
    /// still differ, at roughly one run in six, presumably because something is
    /// reused between sessions. The app is long-lived and makes many requests per
    /// launch, so that is the normal case rather than an edge one.
    private static let options = GenerationOptions(sampling: .greedy)

    func respond(to prompt: String, instructions: String) async throws -> String {
        let session: LanguageModelSession
        if let warmed, warmed.instructions == instructions {
            session = warmed.session
        } else {
            session = LanguageModelSession(model: Self.model, instructions: instructions)
        }
        // Claimed either way: reusing a session across chunks would feed each one
        // the previous chunk's transcript and overflow the window.
        warmed = nil

        return try await session.respond(to: prompt, options: Self.options).content
    }
}
