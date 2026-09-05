import AVFoundation
import Speech

/// Dictation via Apple's on-device speech stack (macOS 26+).
///
/// The draw is that there is nothing to download: the assets are system managed
/// and usually already present because system dictation uses them, so somebody
/// who does not want 2.5 GB of Parakeet on disk can still dictate. In exchange,
/// accuracy is noticeably below Parakeet on anything technical, and the
/// available locales are whatever macOS has installed.
///
/// Dictation only, and that is now a division of labour rather than a limit.
/// A meeting goes through `AppleMeetingEngine`, which is the same stack asked a
/// different question: a file rather than a buffer, and segments with times
/// rather than one string. The timings this used to be said to lack are there,
/// on `Result.range` and on each run's `.audioTimeRange`; what is dictation's
/// own is warming, readiness and the microphone.
@available(macOS 26.0, *)
actor AppleEngine {
    private var transcriber: SpeechTranscriber?
    private var locale: Locale = .current

    /// True when this Mac can run it at all.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// Locales with assets already on disk, so no download is needed.
    static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    func load() async throws {
        // The picking rules live in `AppleSpeech` because meetings need the
        // same ones, and an ordering this fiddly (see `AppleSpeech.best`) is
        // not something two engines can be trusted to keep saying the same way.
        //
        // A saved locale this Mac no longer supports falls back here, where a
        // meeting refuses: the stakes are different. The saved tag was picked
        // from a list of what this Mac had, so a mismatch means the list
        // changed under it, and a dictation shortcut that stops working is
        // worse than one that answers in the wrong English. A meeting is an
        // hour of somebody's audio and gets the strict rule.
        if let saved = Settings.dictationAppleLocale,
           let match = await AppleSpeech.supported(saved) {
            locale = match
        } else {
            if let saved = Settings.dictationAppleLocale {
                log("Apple speech no longer offers \(saved); choosing another locale")
            }
            locale = await AppleSpeech.best()
        }
        let t = SpeechTranscriber(locale: locale, preset: .transcription)
        try await AppleSpeech.install(for: t, locale: locale)
        transcriber = t
    }

    func transcribe(_ pcm: [Float]) async -> String? {
        guard let transcriber else { return nil }

        // Write a temp file rather than hand-rolling an AnalyzerInput stream: the
        // file path is a single call and the clips are seconds long.
        guard let url = writeTempWAV(pcm) else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let file = try AVAudioFile(forReading: url)

            // Collect before finalizing: results arrive as an async sequence and
            // stop once the analyzer finishes.
            let collector = Task { () -> String in
                var parts: [String] = []
                for try await result in transcriber.results {
                    parts.append(String(result.text.characters))
                }
                return parts.joined()
            }

            _ = try await analyzer.analyzeSequence(from: file)
            try await analyzer.finalizeAndFinishThroughEndOfInput()

            let text = try await collector.value
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            log("Apple speech failed: \(error)")
            return nil
        }
    }

    private func writeTempWAV(_ pcm: [Float]) -> URL? {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: SAMPLE_RATE,
            channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("listen-dictation-\(UUID().uuidString).wav")

        guard let file = try? AVAudioFile(
            forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(pcm.count))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: pcm.count)
        }
        try? file.write(from: buffer)
        return url
    }

    var localeName: String {
        locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }
}

extension Settings {
    private static let dictationAppleLocaleKey = "dictationAppleLocale"

    /// BCP-47 tag for the Apple engine, or nil to choose automatically.
    ///
    /// Only meaningful for Apple Intelligence: `SpeechTranscriber` takes a locale
    /// that genuinely constrains recognition. Parakeet has no such control, so
    /// this is deliberately not offered for it. mlx-audio's `language` parameter
    /// is copied into the output struct and never reaches the decoder, so a
    /// picker for it would be a control that silently does nothing.
    static var dictationAppleLocale: String? {
        get {
            let v = defaults.string(forKey: dictationAppleLocaleKey)
            return (v?.isEmpty ?? true) ? nil : v
        }
        set { defaults.set(newValue ?? "", forKey: dictationAppleLocaleKey) }
    }
}
