import Foundation

/// Fronts whichever speech engine turns a dictation into text.
///
/// Ported from Speak's `Transcriber`, and thinner than it: the Parakeet leg is
/// `ASR.shared`, which Listen already had for meetings, so there is one loader,
/// one cache and one copy of the weights. What is left here is the part that is
/// dictation's own, which is warming and the readiness a shortcut can be gated
/// on.
///
/// An actor for the reason `ASR` is one: the model is not safe to drive from two
/// places at once.
actor DictationEngine {
    /// True once the weights are resident and warmed, so the shortcut can
    /// refuse rather than open the microphone for a dictation that will land
    /// nowhere.
    private(set) var isReady = false

    /// Set while a load is running, so the second caller waits on the first
    /// instead of starting a duplicate. Both `applicationDidFinishLaunching` and
    /// the first press of the shortcut can arrive here within a second of each
    /// other on a cold launch.
    private var loading: Task<Void, Error>?

    /// The Parakeet model in use, which is deliberately the meeting model.
    ///
    /// One choice in Settings, Models, serving both. Two would mean two 2.5 GB
    /// downloads to say the same thing, and the question "which model should
    /// transcribe my voice" does not have two answers depending on whether the
    /// voice was in a meeting.
    private var choice: ModelChoice { Settings.model }

    /// Apple's engine, held as `AnyObject` so the property needs no availability
    /// annotation. The same trick `Polisher` uses for its own engine.
    private var apple: AnyObject?

    /// Load the weights if they are on disk, and warm the compute graph.
    ///
    /// **Never downloads.** `ASR.load` will fetch what is missing, and that is
    /// right when somebody pressed a button naming the size; it is wrong here,
    /// where the caller is a feature being switched on or an app finishing its
    /// launch. Downloading a model on the strength of a preference is how a
    /// laptop on a hotel connection spends 2.5 GB nobody asked for. The Models
    /// pane is where a download is agreed to.
    func prepare() async throws {
        if isReady { return }
        if let loading { return try await loading.value }

        let task: Task<Void, Error>
        switch Settings.dictationEngineChoice {
        case .apple:
            guard #available(macOS 26.0, *) else {
                throw NSError(domain: "Listen", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Apple speech needs macOS 26 or later",
                ])
            }
            let engine = AppleEngine()
            task = Task<Void, Error> { try await engine.load() }
            apple = engine

        case .parakeet:
            apple = nil
            let model = choice
            guard model.isDownloaded else { return }
            task = Task<Void, Error> {
                try await ASR.shared.load(model)
                // Warm the compute graph so the first real dictation is not the
                // slow one. A second of silence is the cheapest input that
                // compiles every kernel the real thing will use.
                _ = await ASR.shared.transcribe(
                    samples: Array(repeating: 0, count: Int(SAMPLE_RATE)))
            }
        }

        loading = task
        defer { loading = nil }
        try await task.value
        isReady = true
    }

    /// Text, or nil when nothing was heard. Never throws: a dictation that
    /// produced nothing is an ordinary outcome, not an error to present.
    func transcribe(_ pcm: [Float]) async -> String? {
        guard isReady else { return nil }
        if #available(macOS 26.0, *), let engine = apple as? AppleEngine {
            return await engine.transcribe(pcm)
        }
        return await ASR.shared.transcribe(samples: pcm)
    }

    /// Forget the loaded state, so the next `prepare` reloads.
    ///
    /// For a model change in Settings. `ASR.load` no-ops when the repo it holds
    /// is the one being asked for, so this is only about `isReady` and the warm
    /// pass, not about dropping weights.
    func invalidate() {
        loading?.cancel()
        loading = nil
        apple = nil
        isReady = false
    }
}

extension Settings {
    /// Which speech engine turns a dictation into text.
    ///
    /// Not the same question as the Models pane, which chooses *which Parakeet*
    /// and applies to meetings as well. This chooses whether dictation uses
    /// Parakeet at all, and it is dictation's alone: a meeting needs sentence
    /// timings to line up with speaker turns, and Apple's engine does not expose
    /// them.
    enum DictationEngineChoice: String {
        case parakeet
        case apple

        var title: String {
            switch self {
            case .parakeet: return "Parakeet"
            case .apple:    return "Apple Intelligence"
            }
        }

        /// What picking it costs, said on screen rather than hidden in a tooltip.
        var blurb: String {
            switch self {
            case .parakeet:
                return "The model Listen already uses for meetings. The most "
                    + "accurate, and it needs the download the Models tab names."
            case .apple:
                return "Built in, nothing to download, ready immediately. Less "
                    + "accurate on names and technical words."
            }
        }
    }

    private static let dictationEngineKey = "dictationEngine"

    /// Parakeet by default, and it stays the default even on a Mac that could
    /// run Apple's: dictation is mostly names, jargon and command lines, which
    /// is exactly where the accuracy difference shows.
    static var dictationEngineChoice: DictationEngineChoice {
        get {
            let stored = DictationEngineChoice(
                rawValue: defaults.string(forKey: dictationEngineKey) ?? "")
            // A choice this Mac cannot honour falls back rather than failing to
            // load: somebody who picked Apple Intelligence and then moved to a
            // Mac without it should still be able to dictate.
            guard let stored else { return .parakeet }
            if stored == .apple, !appleDictationAvailable { return .parakeet }
            return stored
        }
        set { defaults.set(newValue.rawValue, forKey: dictationEngineKey) }
    }

    static var appleDictationAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}
