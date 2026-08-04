import Foundation

/// Re-derives voiceprints for recordings that have names but no embeddings.
///
/// This exists because of the import. The legacy library carries real human
/// naming, 25 speaker slots that somebody sat down and labelled, but its
/// voiceprints are pyannote vectors and Listen's recognition runs on
/// FluidAudio. The two are both 256-dimensional and completely unrelated, so
/// the vectors cannot come across.
///
/// The names can. So: diarize the imported audio with FluidAudio, work out
/// which of the already-named speakers each diarized voice belongs to by
/// looking at who holds the same stretch of the transcript, and file the new
/// embedding under the name. The result is a voice bank in the right space
/// with the labelling work preserved.
///
/// Runs no ASR. The transcript is already there and re-transcribing would
/// replace a human-corrected one with a fresh guess.
actor Enroll {
    private let diarizer = Diarizer()

    struct Result {
        var id: String
        var named: [String: Double]      // name to seconds of speech
        var unmatched: Int               // diarized voices no name claimed
    }

    /// Recordings that would benefit: a transcript with at least one real name,
    /// audio to work from, and no voiceprints yet.
    static func candidates() -> [Recording] {
        Recording.all().filter { recording in
            guard !recording.playbackTracks.isEmpty else { return false }
            guard recording.voiceprints.isEmpty else { return false }
            return recording.speakers.contains { !VoiceBank.isPlaceholder($0) }
        }
    }

    /// Every recording with names, whether or not it already has voiceprints.
    static func forceCandidates() -> [Recording] {
        Recording.all().filter { recording in
            !recording.playbackTracks.isEmpty
                && recording.speakers.contains { !VoiceBank.isPlaceholder($0) }
        }
    }

    func run(_ recording: Recording,
             progress: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let fm = FileManager.default
        let turns = recording.storedTurns
        let named = Set(turns.map(\.speaker)).filter { !VoiceBank.isPlaceholder($0) }
        guard !named.isEmpty else { throw PipelineError.nothingToTranscribe }

        try await diarizer.load { progress?($0) }

        var bank: [String: Voiceprint] = [:]
        var unmatched = 0

        let hasMic = fm.fileExists(atPath: recording.micURL.path)
        let hasSystem = fm.fileExists(atPath: recording.systemURL.path)

        if hasSystem || hasMic {
            // Split recording, native or imported. The system track carries
            // everyone but the user and the mic track carries the user, so the
            // count is not the same on both and must not be forced from the
            // transcript: telling the clusterer to find two people in a track
            // that holds one splits that one person in half.
            if hasSystem {
                let system = try await diarizer.run(recording.systemURL)
                trace("enrol \(recording.id): system track, "
                      + "\(system.embeddings.count) voices")
                unmatched += attach(system, to: turns, into: &bank)
            }
            if hasMic {
                // Whoever the system side did not account for is the person on
                // the microphone. One voice, so say so rather than letting the
                // clusterer split a single speaker across a long meeting.
                let mic = try await diarizer.run(recording.micURL, expecting: 1)
                let remaining = named.subtracting(bank.keys)
                trace("enrol \(recording.id): mic track, "
                      + "\(mic.embeddings.count) voices, unaccounted: \(remaining)")
                if remaining.count == 1, let name = remaining.first,
                   let vector = mic.embeddings.values.first {
                    bank[name] = Voiceprint(embedding: vector,
                                            speech: mic.speech.values.reduce(0, +))
                } else {
                    unmatched += attach(mic, to: turns, into: &bank)
                }
            }
        } else if fm.fileExists(atPath: recording.mixURL.path) {
            // One mixed track, so every named speaker is in it and the count
            // from the transcript is the right prior.
            let mix = try await diarizer.run(recording.mixURL, expecting: named.count)
            trace("enrol \(recording.id): mixed track, \(mix.embeddings.count) voices")
            unmatched += attach(mix, to: turns, into: &bank)
        } else {
            throw PipelineError.nothingToTranscribe
        }

        guard !bank.isEmpty else {
            return Result(id: recording.id, named: [:], unmatched: unmatched)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(bank).write(to: recording.embeddingsURL, options: .atomic)
        return Result(id: recording.id, named: bank.mapValues(\.speech),
                      unmatched: unmatched)
    }

    /// File each diarized voice under the transcript name that holds the same
    /// stretch of the clock.
    ///
    /// Overlap, not order: diarization labels are arbitrary and the
    /// transcript's names came from a different tool, so the clock is the only
    /// thing they share.
    private func attach(_ diarization: DiarizationOutput, to turns: [Turn],
                        into bank: inout [String: Voiceprint]) -> Int {
        var totals: [String: [String: Double]] = [:]
        for turn in diarization.turns {
            for spoken in turns {
                let overlap = min(turn.end, spoken.end) - max(turn.start, spoken.start)
                guard overlap > 0 else { continue }
                totals[turn.label, default: [:]][spoken.speaker, default: 0] += overlap
            }
        }

        var unmatched = 0
        for (label, vector) in diarization.embeddings {
            guard let best = totals[label]?.max(by: { $0.value < $1.value }),
                  !VoiceBank.isPlaceholder(best.key) else {
                unmatched += 1
                continue
            }
            let seconds = diarization.speech[label] ?? 0
            // Two diarized voices can land on the same person, which is
            // ordinary: somebody who changes seat or microphone gets split.
            // Keep whichever heard them for longer rather than averaging two
            // recordings that may not sound alike.
            if let existing = bank[best.key], existing.speech >= seconds { continue }
            bank[best.key] = Voiceprint(embedding: vector, speech: seconds)
        }
        return unmatched
    }
}

extension Recording {
    /// Anything with audio in it, including an imported mixdown.
    ///
    /// `tracks` is the capture view: the two files Listen records. This is the
    /// "is there audio here at all" view, which an imported recording needs
    /// because it has only a mixdown.
    var playbackTracks: [URL] {
        let candidates = [systemURL, micURL, mixURL]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
