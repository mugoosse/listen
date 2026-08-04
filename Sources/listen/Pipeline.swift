import Foundation

/// The stored transcript: segments with speakers, plus what produced them.
struct StoredTranscript: Codable {
    var segments: [LabelledSegment]
    var duration: Double
    var model: String
    /// Whether the segments carry word-level assignment. False today.
    var wordLevel: Bool
    /// How often each cleanup rule fired, so the Whisper-era cleanup can be
    /// judged on Parakeet output rather than assumed necessary.
    var cleanup: [String: Int]
}

/// Runs a recording through ASR, diarization and the merge, and writes the
/// results next to the audio.
///
/// One job at a time, by construction: the models are GPU and ANE bound and
/// parallel jobs fight over the same hardware rather than finishing sooner.
/// `Pipeline` is an actor, and `Queue` below serialises the whole app onto it.
actor Pipeline {
    private let asr = ASR()
    private let diarizer = Diarizer()

    /// What the user's own track is called before anyone names it.
    ///
    /// A word rather than a letter, because it is not a guess. The mic track is
    /// the user by definition, and calling it "A" would invite the labelling UI
    /// to ask a question that has no doubt in it.
    static let userLabel = "Me"

    /// Transcribe a whole recording: both tracks, diarized and merged.
    func run(_ recording: Recording,
             progress: (@Sendable (String) -> Void)? = nil) async throws -> StoredTranscript {
        try await asr.load(Settings.model) { progress?($0) }

        let fm = FileManager.default
        var hasSystem = fm.fileExists(atPath: recording.systemURL.path)
        let hasMic = fm.fileExists(atPath: recording.micURL.path)

        // An imported recording has neither track, only the mixdown the legacy
        // recorder produced. Treat that as the everyone-track: diarize it whole
        // and discover every speaker, including the user. There is deliberately
        // no shortcut labelling anybody "Me" here, because in a mixed track the
        // user is not distinguishable by which file they are in, and guessing
        // would be worse than asking.
        var everyone = recording.systemURL
        if !hasSystem, !hasMic, fm.fileExists(atPath: recording.mixURL.path) {
            everyone = recording.mixURL
            hasSystem = true
        }

        var labelled: [LabelledSegment] = []
        var embeddings: [String: [Float]] = [:]
        var speech: [String: Double] = [:]
        var wordLevel = false
        var model = Settings.model.repo

        // The system track carries everyone who is not the user, so it is the
        // only one worth diarizing. Doing both would spend ANE time to
        // rediscover something already known and occasionally get it wrong by
        // splitting the user into two people.
        if hasSystem {
            progress?("transcribing the other participants")
            let transcript = try await asr.transcribe(everyone)
            wordLevel = transcript.hasWordTimings
            model = transcript.model

            progress?("identifying speakers")
            try await diarizer.load { progress?($0) }
            let diarization = try await diarizer.run(everyone)
            embeddings = diarization.embeddings
            speech = diarization.speech

            var assigned = Merge.assign(transcript.segments, to: diarization.turns,
                                        fallback: "unknown")
            let mapping = Merge.relabel(&assigned)
            // Carry the voiceprints over to the letters the transcript uses,
            // otherwise the embeddings are filed under labels nothing displays.
            embeddings = Self.remap(embeddings, using: mapping)
            speech = Self.remap(speech, using: mapping)
            labelled += assigned
        }

        // The mic is the user. One step, no clustering, no doubt.
        if hasMic, !Self.isSilent(recording.micURL) {
            progress?("transcribing you")
            let transcript = try await asr.transcribe(recording.micURL)
            wordLevel = wordLevel || transcript.hasWordTimings
            labelled += transcript.segments.map {
                LabelledSegment(start: $0.start, end: $0.end,
                                speaker: Self.userLabel, text: $0.text)
            }
        }

        guard !labelled.isEmpty else { throw PipelineError.nothingToTranscribe }

        // Interleave the two tracks by time. They were captured together, so
        // their clocks agree and sorting is all the alignment needed.
        labelled.sort { $0.start < $1.start }
        let (cleaned, fired) = Merge.clean(labelled)
        if !fired.isEmpty { trace("cleanup fired: \(fired)") }

        let stored = StoredTranscript(
            segments: cleaned,
            duration: recording.metadata.duration,
            model: model,
            wordLevel: wordLevel,
            cleanup: fired)

        try write(stored, turns: Merge.turns(from: cleaned),
                  embeddings: embeddings, speech: speech, to: recording)
        return stored
    }

    /// Transcribe a bare file, with diarization but no track split.
    ///
    /// What `listen transcribe --diarize` uses. There is no mic and system
    /// distinction here, so every speaker is discovered rather than one of them
    /// being known in advance.
    func runFile(_ url: URL,
                 progress: (@Sendable (String) -> Void)? = nil) async throws -> StoredTranscript {
        try await asr.load(Settings.model) { progress?($0) }
        let transcript = try await asr.transcribe(url)

        progress?("identifying speakers")
        try await diarizer.load { progress?($0) }
        let diarization = try await diarizer.run(url)

        var assigned = Merge.assign(transcript.segments, to: diarization.turns,
                                    fallback: "unknown")
        Merge.relabel(&assigned)
        let (cleaned, fired) = Merge.clean(assigned)
        return StoredTranscript(segments: cleaned, duration: transcript.duration,
                                model: transcript.model,
                                wordLevel: transcript.hasWordTimings, cleanup: fired)
    }

    // MARK: - Writing

    private func write(_ transcript: StoredTranscript, turns: [Turn],
                       embeddings: [String: [Float]], speech: [String: Double],
                       to recording: Recording) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Atomic writes throughout. A transcript half-written by a crash would
        // look like a finished one to the next launch, and the recording would
        // never be picked up again.
        try enc.encode(transcript).write(to: recording.transcriptURL, options: .atomic)
        try enc.encode(turns).write(to: recording.turnsURL, options: .atomic)

        if !embeddings.isEmpty {
            // One embedding per speaker per recording, stored next to the audio.
            // There is deliberately no separate database: the set of sidecar
            // files is the voice bank, so deleting a recording cannot strand an
            // entry in it.
            let bank = embeddings.mapValues { vector in
                Voiceprint(embedding: vector, speech: 0)
            }
            var withSpeech = bank
            for (label, seconds) in speech {
                withSpeech[label]?.speech = seconds
            }
            try enc.encode(withSpeech).write(to: recording.embeddingsURL, options: .atomic)
        }
    }

    private static func remap<T>(_ values: [String: T],
                                 using mapping: [String: String]) -> [String: T] {
        var out: [String: T] = [:]
        for (key, value) in values { out[mapping[key] ?? key] = value }
        return out
    }

    /// True when a track holds no signal worth transcribing.
    ///
    /// A meeting where nobody used the microphone leaves a mic track of pure
    /// room noise, and running Parakeet over an hour of that produces confident
    /// hallucinated sentences attributed to the user. Cheaper and more truthful
    /// to skip it.
    ///
    /// Reads the file directly rather than decoding it: the writer's format is
    /// known, so this is a scan of floats.
    static func isSilent(_ url: URL, threshold: Float = 0.002) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        _ = try? handle.seek(toOffset: 44)
        guard let data = try? handle.readToEnd(), data.count >= 4 else { return true }
        var peak: Float = 0
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            // Sample rather than scan every value: an hour is 57 million floats
            // and the answer does not need all of them.
            let stride = max(1, floats.count / 200_000)
            for i in Swift.stride(from: 0, to: floats.count, by: stride) {
                peak = Swift.max(peak, abs(floats[i]))
            }
        }
        return peak < threshold
    }
}

/// One speaker's voiceprint from one recording.
struct Voiceprint: Codable {
    var embedding: [Float]
    /// Seconds of speech it was built from.
    ///
    /// Under 15 seconds the embedding is stored but not used as evidence: it is
    /// too short to be a reliable identity, and a confident wrong suggestion in
    /// the labelling UI is worse than no suggestion.
    var speech: Double

    static let minimumSpeechForEvidence: Double = 15

    var isEvidence: Bool { speech >= Self.minimumSpeechForEvidence }
}

enum PipelineError: Error, LocalizedError {
    case nothingToTranscribe
    var errorDescription: String? {
        "no audio in this recording that could be transcribed"
    }
}
