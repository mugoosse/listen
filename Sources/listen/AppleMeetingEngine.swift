import AVFoundation
import Foundation
import Speech

/// A whole meeting through Apple's on-device speech stack (macOS 26+).
///
/// The dictation engine's larger sibling, and a different job: `AppleEngine`
/// turns a few seconds of microphone into one string, this turns an hour of
/// file into segments with times that speaker turns can be lined up against.
///
/// Three things it has that Parakeet does not, and they are the reason it
/// exists rather than speed:
///
/// - **Nothing to download.** The assets are the system's, shared with Notes
///   and Voice Memos, so a first run transcribes instead of fetching 2.5 GB.
/// - **Word timings.** Results arrive as an `AttributedString` whose runs carry
///   `.audioTimeRange`, which is the thing `Merge.assign`'s word-level branch
///   has been waiting for since the port: mlx-audio throws the equivalent away
///   one layer below where we can reach it.
/// - **A locale.** The decoder is constrained to a language rather than
///   guessing, so `apple:nl-NL` is a fact about the run and not an inference
///   from the words. See `SpokenLanguage.declared`.
///
/// What it does **not** replace is everything Listen is actually about:
/// diarization, the voice bank, the two-track structure and the merge all sit
/// above this and are untouched by which engine produced the words.
///
/// Accuracy against this library's own meetings is **unmeasured**. That is the
/// number that decides anything, and `tools/measure_engines.sh` is how it gets
/// run.
@available(macOS 26.0, *)
actor AppleMeetingEngine: ASREngine {
    private var locale: Locale?

    /// The locale a run was asked for, ahead of `load`.
    ///
    /// `LISTEN_LOCALE` is measurement plumbing in the family of `LISTEN_CHUNK`
    /// and `LISTEN_ENGINE`: the Dutch calls in this library have to be
    /// transcribable as Dutch before anything can be said about whether Apple's
    /// engine reads them. An environment variable, so a Finder launch inherits
    /// no shell and can never see it.
    ///
    /// A per-recording locale is the real answer and is not here yet. When it
    /// arrives it is a field on the recording, read the way `asr_model` is.
    private static var requestedTag: String? {
        let raw = ProcessInfo.processInfo.environment["LISTEN_LOCALE"]?
            .trimmingCharacters(in: .whitespaces)
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    func load(_ choice: ModelChoice,
              progress: (@Sendable (String) -> Void)? = nil) async throws {
        // The choice carries a locale when a transcript is being reproduced
        // (`apple:nl-NL`); otherwise the environment, otherwise the Mac's own.
        let wanted = ModelChoice.appleLocaleTag(in: choice.repo) ?? Self.requestedTag
        let resolved: Locale
        if let wanted {
            // **A locale that was asked for and cannot be honoured is an error,
            // never a fallback to English.** This is the app's worst failure
            // wearing a new hat: an English decoder handed Dutch audio writes
            // fluent, confident English, nothing throws, and the only evidence
            // is that a human reads it. `SpeechTranscriber` covers 10 languages
            // and Dutch is not among them, so this branch is reachable on this
            // library's own recordings.
            guard let match = await AppleSpeech.supported(wanted) else {
                let available = await SpeechTranscriber.supportedLocales
                    .map { $0.identifier(.bcp47) }.sorted().joined(separator: " ")
                throw ASRError.modelUnavailable(
                    "Apple speech does not read \(wanted). It has: \(available)."
                    + " Parakeet v3 reads 25 languages including the ones missing"
                    + " here; `--model v3` is the way to transcribe this.")
            }
            resolved = match
        } else {
            // Nobody named a locale, so the languages the user says they speak
            // decide it. That is the whole reason `Settings.spokenLanguages`
            // exists: Parakeet is handed audio and guesses, Apple's engine is
            // told and cannot.
            resolved = await AppleSpeech.best(preferring: Settings.effectiveLanguages)
        }
        locale = resolved
        progress?("Apple speech, \(resolved.identifier(.bcp47))")

        // Installed once here rather than per file, against a throwaway module
        // configured exactly like the real ones: the installation request is
        // about the locale's assets, and every module below asks for the same
        // locale.
        try await AppleSpeech.install(for: Self.transcriber(for: resolved),
                                      locale: resolved, progress: progress)
    }

    /// A module per file, not one held across files.
    ///
    /// `SpeechTranscriber.results` is a single sequence that ends when its
    /// analyzer finishes, so a transcriber kept between the system track and the
    /// microphone track would have nothing left to yield on the second pass.
    /// Constructing one is cheap; what is expensive is the model behind it, and
    /// `.processLifetime` below is what keeps that resident between the two.
    private static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Final results only. Volatile results are for a live caption
            // redrawing itself; here they would arrive, be superseded, and cost
            // a segment list that has to be de-duplicated.
            reportingOptions: [],
            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    func transcribe(_ url: URL,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> Transcript {
        guard let locale else {
            throw ASRError.modelUnavailable("Apple speech is not loaded")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ASRError.audioUnreadable(url.path, error)
        }
        // From the file rather than from the last result, for the reason
        // `Transcript.duration` gives: a recording that ends in silence has more
        // of it than the transcript shows.
        let duration = Double(file.length) / file.fileFormat.sampleRate

        let transcriber = Self.transcriber(for: locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            // `.lingering` is the middle of the three, and it is the one that
            // matches this app's shape: the pipeline runs two tracks of the
            // same meeting seconds apart and should not pay for the model
            // twice, while `.processLifetime` would leave an app that
            // transcribed something this morning still holding it tonight.
            // Same argument as the cap on MLX's buffer pool, and the same
            // report behind it.
            options: SpeechAnalyzer.Options(priority: .userInitiated,
                                            modelRetention: .lingering))

        progress?(0)

        // Started before the analysis, because the sequence only yields while
        // the analyzer is running and finishes when it does.
        let collector = Task {
            var segments: [ASRSegment] = []
            for try await result in transcriber.results {
                // Belt and braces: with no `volatileResults` requested every
                // result is final already, and a partial one reaching the
                // segment list would show up as a sentence transcribed twice.
                guard result.isFinal else { continue }
                if let segment = Self.segment(from: result) { segments.append(segment) }
                if duration > 0 {
                    progress?(min(1, max(0, result.range.end.seconds / duration)))
                }
            }
            return segments
        }

        do {
            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            collector.cancel()
            throw error
        }

        let segments = try await collector.value
        progress?(1)

        return Transcript(
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            duration: duration,
            model: "apple:" + locale.identifier(.bcp47),
            // One pass over the file, so there is nothing to cut and no seam to
            // land in the wrong place. Both counters exist to make Parakeet's
            // chunking checkable, and here they are honestly zero.
            chunks: 1,
            hardCuts: 0)
    }

    /// One result, as a segment with whatever timings its runs carry.
    ///
    /// **Words are attached only when every run in the result has one.**
    /// `Merge.assign` rebuilds a split segment's text by concatenating
    /// `ASRWord.word`, so a run without a time range would not merely lose its
    /// timing, it would lose its words out of the transcript. The words
    /// therefore keep the run's characters verbatim, spacing included, so the
    /// concatenation is the original sentence exactly, and a result with any
    /// untimed run falls back to the sentence-level path that has always run.
    private static func segment(from result: SpeechTranscriber.Result) -> ASRSegment? {
        let attributed = result.text
        let text = String(attributed.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let start = result.range.start.seconds
        let end = result.range.end.seconds
        // Zero-duration rows are dropped here rather than in the cleanup pass:
        // a segment with no extent cannot overlap a speaker turn, so it would be
        // assigned arbitrarily. Same rule as `ASR.segments(from:)`.
        guard end > start, start.isFinite, end.isFinite else { return nil }

        var words: [ASRWord] = []
        var timed = true
        var confidenceTotal = 0.0
        var confidenceCount = 0

        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            if let confidence = run.transcriptionConfidence, !piece.trimmed.isEmpty {
                confidenceTotal += confidence
                confidenceCount += 1
            }
            guard let range = run.audioTimeRange else {
                timed = false
                continue
            }
            words.append(ASRWord(word: piece,
                                 start: range.start.seconds,
                                 end: range.end.seconds))
        }

        return ASRSegment(
            start: start, end: end, text: text,
            words: timed ? words : [],
            confidence: confidenceCount > 0 ? confidenceTotal / Double(confidenceCount) : nil)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
