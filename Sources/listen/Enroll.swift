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

    func run(_ recording: Recording,
             progress: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        guard let audio = recording.playbackTracks.first else {
            throw PipelineError.nothingToTranscribe
        }
        try await diarizer.load { progress?($0) }
        let diarization = try await diarizer.run(audio)

        let turns = recording.storedTurns
        var totals: [String: [String: Double]] = [:]      // diarized label -> name -> seconds

        // Match by overlap rather than by order. Diarization labels are
        // arbitrary and the transcript's are the imported ones, so the only
        // thing the two share is the clock.
        for turn in diarization.turns {
            for spoken in turns {
                let overlap = min(turn.end, spoken.end) - max(turn.start, spoken.start)
                guard overlap > 0 else { continue }
                totals[turn.label, default: [:]][spoken.speaker, default: 0] += overlap
            }
        }

        var bank: [String: Voiceprint] = [:]
        var named: [String: Double] = [:]
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
            // things that may not be the same recording conditions.
            if let existing = bank[best.key], existing.speech >= seconds { continue }
            bank[best.key] = Voiceprint(embedding: vector, speech: seconds)
            named[best.key] = seconds
        }

        guard !bank.isEmpty else { return Result(id: recording.id, named: [:],
                                                 unmatched: unmatched) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(bank).write(to: recording.embeddingsURL, options: .atomic)
        return Result(id: recording.id, named: named, unmatched: unmatched)
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
