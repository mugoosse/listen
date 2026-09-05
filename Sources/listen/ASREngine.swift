import Foundation

/// Whatever turns a file of speech into a transcript.
///
/// Two implementations. `ASR` is Parakeet through MLX and has been the only one
/// since the Python port. `AppleMeetingEngine` is `SpeechTranscriber` on macOS
/// 26, which arrived after this app's shape was settled and changes three
/// things Parakeet cannot: there is nothing to download, the phone could run
/// it, and it reports word timings (see `.agents/notes/asr.md`).
///
/// **The seam exists so the two can be measured over the same audio, not
/// because a swap has been decided.** Nothing in this library has been run
/// through Apple's engine yet, and the number that decides it is the proper
/// nouns: v3 lost 39% of them to v2, which is the whole reason there are two
/// Parakeets rather than one. `tools/measure_engines.sh` is that measurement.
///
/// `Actor` rather than a plain protocol: both engines drive hardware that is
/// not safe to enter twice at once, and saying so in the constraint is better
/// than saying it in a comment each conformer has to keep.
protocol ASREngine: Actor {
    /// Make the engine ready to transcribe with this choice.
    ///
    /// May download: Parakeet's 2.5 GB when the Models pane asked for it,
    /// Apple's per-locale assets when the locale has never been used. Both
    /// report through `progress` because both can take minutes and a silent
    /// wait is indistinguishable from a hang.
    func load(_ choice: ModelChoice,
              progress: (@Sendable (String) -> Void)?) async throws

    /// Transcribe a whole file, reporting a fraction of *this file* as it goes.
    ///
    /// 0 before anything lands and 1 when the last piece does. What the
    /// fraction counts differs by engine, and deliberately: `ASR` counts chunks
    /// it decoded, Apple's counts audio the analyzer has passed. Neither is an
    /// estimate of time remaining, which is the rule the progress UI is built
    /// on.
    func transcribe(_ url: URL,
                    progress: (@Sendable (Double) -> Void)?) async throws -> Transcript
}

/// Which engine a model choice means.
///
/// One place, because the choice reaches here from four directions: the CLI's
/// `--model`, the recording's own `asr_model`, `Settings.model`, and the
/// `LISTEN_ENGINE` override. A second rule anywhere would be a way for the
/// library to record one engine and run another.
enum ASREngines {
    static func make(for choice: ModelChoice) throws -> any ASREngine {
        guard choice.isApple else { return ASR.shared }
        guard #available(macOS 26.0, *) else {
            throw ASRError.modelUnavailable(
                "Apple speech needs macOS 26 or later. This Mac runs "
                + ProcessInfo.processInfo.operatingSystemVersionString + ".")
        }
        // A fresh one per job rather than a shared instance, which is the
        // opposite of `ASR.shared` and for the opposite reason. Parakeet is
        // shared because 2.5 GB of weights must be resident once; Apple's
        // assets belong to the system, so an engine here holds a locale and a
        // configuration and nothing worth keeping between jobs.
        return AppleMeetingEngine()
    }
}
