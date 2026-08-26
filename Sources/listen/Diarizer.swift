import Foundation
import FluidAudio

/// One stretch of one speaker, as the diarizer sees it.
struct SpeakerTurn {
    var start: Double
    var end: Double
    /// The diarizer's own label, before relabelling to A, B, C.
    var label: String
}

/// Speaker turns and one embedding per speaker, over a single track.
struct DiarizationOutput {
    var turns: [SpeakerTurn]
    /// Averaged per speaker, which is what a voiceprint is.
    var embeddings: [String: [Float]]
    /// Total speech seconds per speaker, so the caller can refuse to trust a
    /// voiceprint built from two seconds of "mm-hm".
    var speech: [String: Double]
}

/// Speaker diarization through FluidAudio, on the Neural Engine.
///
/// Offline, whole-file, never the streaming diarizer. Streaming decodes without
/// future context and is measurably worse, and nothing here is live: the
/// transcript is built after capture has stopped, so there is no reason to give
/// up the accuracy.
actor Diarizer {
    /// The free-clustering manager, and the only thing `expecting: nil` may
    /// ever run on. A tuned manager used to be stored in this slot, and the
    /// order of the pipeline made that exactly wrong: `printUser` runs the mic
    /// with `expecting: 1` after every call, so the first recording of an app
    /// session clustered freely and every later system track ran with
    /// `numSpeakers = 1`, which is a command rather than a hint. An 89-minute
    /// webinar came back as one far-end voice that way. See
    /// .agents/notes/speakers.md.
    private var manager: OfflineDiarizerManager?
    /// The manager for a known speaker count, kept beside the free one so a
    /// prior lasts exactly as long as the runs that ask for it.
    private var tuned: OfflineDiarizerManager?
    private var tunedExpecting: Int?
    /// Loaded once and shared between managers, because the CoreML load is the
    /// expensive part and a different speaker count needs a different config
    /// but the same models.
    private var models: OfflineDiarizerModels?

    /// Where FluidAudio keeps its CoreML bundles.
    ///
    /// Not the Hugging Face hub cache, and not shared with Speak: these are
    /// different models in a different format. They are small next to Parakeet,
    /// tens to low hundreds of MB.
    static var modelsDirectory: URL { OfflineDiarizerModels.defaultModelsDirectory() }

    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelsDirectory.path)
    }

    /// Clustering settings, overridable for measurement.
    ///
    /// `threshold` is a cosine similarity over unit-normalized embeddings,
    /// which the library converts to a merge distance (sqrt(2 - 2s)) before
    /// cutting the dendrogram, so **larger splits more**: raise it toward 1
    /// and one person becomes two, lower it and two people become one. An
    /// earlier version of this comment had the direction backwards. Measured
    /// on a real webinar system track holding five people: 0.35 to 0.45 gave
    /// one cluster, 0.5 gave seven, 0.6 gave eight. The library default is
    /// 0.6. `LISTEN_DIARIZE_THRESHOLD` and `LISTEN_MIN_SPEAKERS` exist to
    /// sweep it against real recordings rather than guess.
    static func config(expecting: Int? = nil) -> OfflineDiarizerConfig {
        let env = ProcessInfo.processInfo.environment
        var clustering = OfflineDiarizerConfig.Clustering.community
        if let raw = env["LISTEN_DIARIZE_THRESHOLD"], let value = Double(raw) {
            clustering.threshold = value
        }
        if let raw = env["LISTEN_MIN_SPEAKERS"], let value = Int(raw) {
            clustering.minSpeakers = value
        }
        // A known speaker count is a much stronger signal than any threshold.
        // Enrolment has one: the imported transcript already says how many
        // people were named, so there is no reason to make the clusterer
        // rediscover it and get it wrong.
        if let expecting, expecting > 0 { clustering.numSpeakers = expecting }
        return OfflineDiarizerConfig(clustering: clustering)
    }

    func load(progress: (@Sendable (String) -> Void)? = nil) async throws {
        if manager != nil { return }
        if !Self.isDownloaded { progress?("downloading the diarization models") }
        let m = OfflineDiarizerManager(config: Self.config())
        // FluidAudio logs through OSLog rather than stdout, so unlike mlx-audio
        // this one does not need shielding from the transcript.
        try await m.prepareModels()
        manager = m
    }

    /// Point the diarizer at a known number of speakers.
    ///
    /// Rebuilds a manager, not the models: the CoreML load is the slow part
    /// and is reused, while the clustering config is cheap. The tuned manager
    /// must never be stored where the free one lives; see the trap on
    /// `manager` above.
    private func manager(expecting: Int?) async throws -> OfflineDiarizerManager {
        guard let manager else { throw DiarizerError.notLoaded }
        guard let expecting, expecting > 0 else { return manager }
        if tunedExpecting == expecting, let tuned { return tuned }
        if models == nil {
            models = try? await OfflineDiarizerModels.load(
                from: OfflineDiarizerModels.defaultModelsDirectory())
        }
        guard let models else { return manager }
        let built = OfflineDiarizerManager(config: Self.config(expecting: expecting))
        built.initialize(models: models)
        tunedExpecting = expecting
        tuned = built
        return built
    }

    /// Diarize one track.
    ///
    /// The system track always, and the microphone track two ways: freely when
    /// the recording is a room, and with `expecting: 1` on a call, where the
    /// answer is known and the pass is run for the embedding rather than the
    /// turns. The prior is the whole difference. Letting the clusterer loose on
    /// a track that holds one person is how one person becomes two, which is the
    /// most common diarization error there is.
    func run(_ url: URL, expecting: Int? = nil) async throws -> DiarizationOutput {
        let manager = try await manager(expecting: expecting)
        let result = try await manager.process(url)

        var turns: [SpeakerTurn] = []
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        var speech: [String: Double] = [:]

        for segment in result.segments {
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            guard end > start else { continue }
            turns.append(SpeakerTurn(start: start, end: end, label: segment.speakerId))
            speech[segment.speakerId, default: 0] += end - start

            // Average the per-segment embeddings into one per speaker. The
            // diarizer already clustered them, so this is a centroid of things
            // it decided were the same voice.
            guard !segment.embedding.isEmpty else { continue }
            if var running = sums[segment.speakerId] {
                for i in running.indices where i < segment.embedding.count {
                    running[i] += segment.embedding[i]
                }
                sums[segment.speakerId] = running
            } else {
                sums[segment.speakerId] = segment.embedding
            }
            counts[segment.speakerId, default: 0] += 1
        }

        var embeddings: [String: [Float]] = [:]
        for (label, sum) in sums {
            let n = Float(max(counts[label] ?? 1, 1))
            embeddings[label] = sum.map { $0 / n }
        }
        // The pipeline's own database wins where it exists: it is the library's
        // clustering rather than our arithmetic.
        for (label, vector) in result.speakerDatabase ?? [:] where !vector.isEmpty {
            embeddings[label] = vector
        }

        turns.sort { $0.start < $1.start }
        trace("diarized \(url.lastPathComponent): \(turns.count) turns, "
              + "\(embeddings.count) speakers")
        return DiarizationOutput(turns: turns, embeddings: embeddings, speech: speech)
    }
}

enum DiarizerError: Error, LocalizedError {
    case notLoaded
    var errorDescription: String? { "the diarization models are not loaded" }
}
