import Foundation

/// One candidate match for an unnamed voice.
struct VoiceMatch {
    var name: String
    var score: Float
    /// How many recordings that name has a voiceprint in.
    var recordings: Int

    var strong: Bool { score >= VoiceBank.strongThreshold }

    /// What the labelling UI shows. The number is included on purpose: a
    /// ranked list with no scores invites more trust than the ranking has
    /// earned, and these thresholds are not yet measured.
    var summary: String { "\(name) (\(Int(score * 100))%)" }
}

/// Cross-recording speaker recognition, over the sidecar files.
///
/// **There is no database.** The set of `embeddings.json` files next to the
/// recordings *is* the voice bank, which is what makes deleting a recording in
/// Finder safe: it cannot strand an entry, because the entry lived in the
/// folder that was deleted. Preserve this property; a cache would reintroduce
/// exactly the inconsistency it removes.
enum VoiceBank {

    // MARK: - Thresholds

    /// Measured with `listen calibrate` on 12 named voiceprints across 4
    /// people, 12 same-person and 48 different-person cross-recording pairs:
    ///
    ///     same person       min +0.979  median +0.991  max +0.995
    ///     different people  min +0.127  median +0.225  max +0.597
    ///
    /// Clean separation, gap +0.382, so these sit one third and two thirds of
    /// the way across it.
    ///
    /// **Re-derived, not copied, and the difference is not academic.** The
    /// Python pipeline used `MATCH_THRESHOLD = 0.50` against pyannote
    /// embeddings, where different-person pairs topped out at 0.46. In
    /// FluidAudio's space different-person pairs reach **0.597**, so carrying
    /// 0.50 over would have called strangers a match on a third of the pairs
    /// measured here. Different model, different space, and the numbers do not
    /// transfer.
    ///
    /// **The caveat, because it matters:** this was measured on synthesised
    /// speech, where one voice reading two different scripts is far more
    /// self-consistent than a person on two different days with two different
    /// microphones. Same-person scores above 0.97 are not a real-world figure;
    /// they are an upper bound on separability. Expect real recordings to sit
    /// lower and closer together, and re-run `listen calibrate` against a real
    /// library before trusting these. The failure they are tuned toward is the
    /// safe one: too high means no suggestion, and a suggestion is never
    /// auto-applied anyway.
    static let matchThreshold: Float = 0.72
    static let strongThreshold: Float = 0.85

    // MARK: - Reading

    /// Every named voiceprint in the library.
    ///
    /// Placeholders are excluded: "A" in one meeting has nothing to do with
    /// "A" in another, and suggesting one for the other would be worse than
    /// suggesting nothing.
    static func named(excluding recording: Recording? = nil) -> [(String, Voiceprint)] {
        var out: [(String, Voiceprint)] = []
        for r in Recording.all() where r.id != recording?.id {
            for (label, print) in r.voiceprints where !isPlaceholder(label) {
                out.append((label, print))
            }
        }
        return out
    }

    /// Rank the named voices in the library against one speaker here.
    ///
    /// Never auto-applied. A suggestion the user accepts is a decision they
    /// made; a name applied silently is one they have to notice is wrong.
    static func suggestions(for speaker: String, in recording: Recording) -> [VoiceMatch] {
        guard let mine = recording.voiceprints[speaker], mine.isEvidence else { return [] }

        var best: [String: (Float, Int)] = [:]
        for (name, other) in named(excluding: recording) {
            // Below 15 seconds an embedding is stored but is not evidence: it
            // is too short to be an identity, and a confident wrong suggestion
            // is worse than none.
            guard other.isEvidence else { continue }
            let score = cosine(mine.embedding, other.embedding)
            let existing = best[name]
            best[name] = (max(score, existing?.0 ?? -1), (existing?.1 ?? 0) + 1)
        }

        return best
            .map { VoiceMatch(name: $0.key, score: $0.value.0, recordings: $0.value.1) }
            .filter { $0.score >= matchThreshold }
            .sorted { $0.score > $1.score }
    }

    /// Cosine similarity. Both vectors come from the same model, so no
    /// normalisation beyond this is needed.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<n {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// True for a label the pipeline invented rather than a person's name.
    static func isPlaceholder(_ label: String) -> Bool {
        if label == "unknown" { return true }
        // A, B, ... Z, AA. Spreadsheet columns, which is what `Merge.letter`
        // produces. "Me" is not a placeholder: the mic track really is the
        // user, so it is a fact rather than something awaiting a decision.
        return !label.isEmpty && label.allSatisfy { $0.isUppercase && $0.isLetter }
            && label.count <= 2 && label != "Me"
    }

    static func currentName(of speaker: String, in recording: Recording) -> String? {
        isPlaceholder(speaker) ? nil : speaker
    }

    // MARK: - Writing

    /// Move a voiceprint to its new name, keeping the bank aligned with the
    /// transcript. Without this the embedding stays filed under "B" while the
    /// transcript says "Anna", and the next recording gets no suggestion.
    static func rename(_ speaker: String, to name: String, in recording: Recording) {
        var bank = recording.voiceprints
        guard let print = bank.removeValue(forKey: speaker) else { return }
        bank[name] = print
        write(bank, to: recording)
    }

    static func remove(_ speaker: String, in recording: Recording) {
        var bank = recording.voiceprints
        guard bank.removeValue(forKey: speaker) != nil else { return }
        write(bank, to: recording)
    }

    private static func write(_ bank: [String: Voiceprint], to recording: Recording) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(bank).write(to: recording.embeddingsURL, options: .atomic)
    }
}

extension Recording {
    var voiceprints: [String: Voiceprint] {
        guard let data = try? Data(contentsOf: embeddingsURL),
              let bank = try? JSONDecoder().decode([String: Voiceprint].self, from: data)
        else { return [:] }
        return bank
    }
}
