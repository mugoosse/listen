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
    private var manager: OfflineDiarizerManager?

    /// Where FluidAudio keeps its CoreML bundles.
    ///
    /// Not the Hugging Face hub cache, and not shared with Speak: these are
    /// different models in a different format. They are small next to Parakeet,
    /// tens to low hundreds of MB.
    static var modelsDirectory: URL { OfflineDiarizerModels.defaultModelsDirectory() }

    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelsDirectory.path)
    }

    func load(progress: (@Sendable (String) -> Void)? = nil) async throws {
        if manager != nil { return }
        if !Self.isDownloaded { progress?("downloading the diarization models") }
        let m = OfflineDiarizerManager()
        // FluidAudio logs through OSLog rather than stdout, so unlike mlx-audio
        // this one does not need shielding from the transcript.
        try await m.prepareModels()
        manager = m
    }

    /// Diarize one track.
    ///
    /// Called on the system track only. The microphone track is definitionally
    /// the user, so running a clustering model over it would be spending ANE
    /// time to rediscover something already known, and occasionally getting it
    /// wrong by splitting one person into two.
    func run(_ url: URL) async throws -> DiarizationOutput {
        guard let manager else { throw DiarizerError.notLoaded }
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
