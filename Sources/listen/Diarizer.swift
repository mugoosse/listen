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
    /// The free-clustering manager for a track that carries one voice per
    /// microphone, and the only thing an open-population pass over a system
    /// track or an import may run on. A tuned manager used to be stored in this
    /// slot, and the order of the pipeline made that exactly wrong: `printUser`
    /// runs the mic with `expecting: 1` after every call, so the first
    /// recording of an app session clustered freely and every later system
    /// track ran with `numSpeakers = 1`, which is a command rather than a
    /// hint. An 89-minute webinar came back as one far-end voice that way. See
    /// .agents/notes/speakers.md.
    private var manager: OfflineDiarizerManager?
    /// The free-clustering manager for a room, which is the same clustering at
    /// a higher threshold. Kept apart from the one above for the same reason
    /// `tuned` is: a manager built for one kind of track must never answer for
    /// another. See `roomThreshold`.
    private var roomManager: OfflineDiarizerManager?
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

    /// Where one voice stops being two, on a track where every voice arrived
    /// on its own microphone.
    ///
    /// A cosine similarity over unit-normalized embeddings, which the library
    /// converts to a merge distance (sqrt(2 - 2s)) before cutting the
    /// dendrogram, so **larger splits more**: raise it toward 1 and one person
    /// becomes two, lower it and two people become one. An earlier version of
    /// this comment had the direction backwards. Measured on a real webinar
    /// system track holding five people: 0.35 to 0.45 gave one cluster, 0.5
    /// gave seven, 0.6 gave eight and matched the hand labels, 0.75 gave nine.
    /// The library default is 0.6, and the measurement agrees with it.
    static let separateThreshold = 0.6

    /// The same knob for a room, where **one** microphone carried everybody.
    ///
    /// **0.6 is measurably too low for far-field audio and this is the whole
    /// bug behind "only I was identified".** Two people at a table share a
    /// microphone, a distance and a room's reverberation, so their embeddings
    /// land far closer together than two people on separate calls do, and the
    /// dendrogram merges them. Measured on a 14-minute two-person phone memo:
    /// 0.5 and 0.6 gave **one** cluster, which the mic pass labels `Me` by
    /// design and so reads as a solo memo; 0.65 through 0.85 gave two; 0.9
    /// gave three. On a 2-hour workshop in a room, 0.6 put 73% of the session
    /// under a single voice and 0.7 to 0.75 split that into two speakers of
    /// 30% each.
    ///
    /// It is a separate number rather than a new default for both, because the
    /// two constraints do not overlap by much: the webinar's system track is
    /// right at 0.6 and over-splits at 0.75, and the room band starts at 0.65.
    /// Raising one number to satisfy both would leave it balanced on the edge
    /// of each. Guarded below by the fact that a genuinely solo room stays one
    /// cluster all the way to 0.8, measured on a 48-minute memo.
    static let roomThreshold = 0.75

    /// Clustering settings, overridable for measurement.
    ///
    /// `room` picks which of the two thresholds above applies, and carries the
    /// answer `Pipeline.decideRoom` reached. The microphone pass over a room is
    /// the one place it is true.
    ///
    /// `LISTEN_DIARIZE_THRESHOLD` and `LISTEN_MIN_SPEAKERS` exist to sweep
    /// against real recordings rather than guess, and override either.
    static func config(expecting: Int? = nil,
                       room: Bool = false) -> OfflineDiarizerConfig {
        let env = ProcessInfo.processInfo.environment
        var clustering = OfflineDiarizerConfig.Clustering.community
        clustering.threshold = room ? roomThreshold : separateThreshold
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

    /// The manager for one kind of pass: a known speaker count, a room, or
    /// neither.
    ///
    /// Rebuilds a manager, not the models: the CoreML load is the slow part
    /// and is reused, while the clustering config is cheap. Each kind gets its
    /// own slot and none of them may ever be stored in another's; see the trap
    /// on `manager` above, which is what happens when one is.
    ///
    /// A known count wins over `room`, because `numSpeakers` sets the answer
    /// outright and no threshold is consulted once it does. That is only ever
    /// `printUser` asking the microphone for one voice it already knows the
    /// count of, and `Enroll` asking a mixdown for the number the transcript
    /// named.
    private func manager(expecting: Int?,
                         room: Bool) async throws -> OfflineDiarizerManager {
        guard let manager else { throw DiarizerError.notLoaded }
        if let expecting, expecting > 0 {
            if tunedExpecting == expecting, let tuned { return tuned }
            guard let models = await models() else { return manager }
            let built = OfflineDiarizerManager(config: Self.config(expecting: expecting))
            built.initialize(models: models)
            tunedExpecting = expecting
            tuned = built
            return built
        }
        guard room else { return manager }
        if let roomManager { return roomManager }
        guard let models = await models() else { return manager }
        let built = OfflineDiarizerManager(config: Self.config(room: true))
        built.initialize(models: models)
        roomManager = built
        return built
    }

    /// The CoreML bundles, loaded once and shared by every manager.
    ///
    /// `load()` has already fetched them through `prepareModels()`; this is the
    /// handle on them a second manager needs to be initialized from, and it is
    /// the expensive part that must not be paid per configuration.
    private func models() async -> OfflineDiarizerModels? {
        if models == nil {
            models = try? await OfflineDiarizerModels.load(
                from: OfflineDiarizerModels.defaultModelsDirectory())
        }
        return models
    }

    /// Diarize one track.
    ///
    /// The system track always, and the microphone track two ways: freely when
    /// the recording is a room, and with `expecting: 1` on a call, where the
    /// answer is known and the pass is run for the embedding rather than the
    /// turns. The prior is the whole difference. Letting the clusterer loose on
    /// a track that holds one person is how one person becomes two, which is the
    /// most common diarization error there is.
    ///
    /// `room` says the track came off one microphone in a shared space, which
    /// is a different clustering problem and gets a different threshold. See
    /// `roomThreshold`: leaving it `false` on a room is how several people come
    /// back as one.
    func run(_ url: URL, expecting: Int? = nil,
             room: Bool = false) async throws -> DiarizationOutput {
        let manager = try await manager(expecting: expecting, room: room)
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
