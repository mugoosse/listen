import Foundation

/// How sure the voice bank is, in the only terms anybody can act on.
///
/// **This replaced a percentage, and the percentage was actively misleading.**
/// The number was a cosine similarity multiplied by a hundred, which reads as a
/// probability and is not one: on real voices the same person scores 0.64 to
/// 0.91 against their own centroid and different people top out at 0.37, so a
/// scale that runs 0 to 100 spends none of itself where the answer lives.
/// Reported from a real session, a correct and unambiguous match displayed as
/// "60% match" and was read as a coin flip. Nobody can act on 0.603 against
/// 0.867; everybody can act on "almost certainly".
enum VoiceConfidence {
    case possible
    case likely
    case almostCertain

    var label: String {
        switch self {
        case .possible:      return "Possibly them"
        case .likely:        return "Likely them"
        case .almostCertain: return "Almost certainly them"
        }
    }
}

/// One candidate match for an unnamed voice.
struct VoiceMatch {
    var name: String
    /// Cosine against that person's centroid, not against their best single
    /// print. See `VoiceBank.suggestions`.
    var score: Float
    /// How many recordings that name has a voiceprint in.
    var recordings: Int
    /// How far clear of the nearest rival this one is.
    ///
    /// Signed against the **best competitor**, not against the next one down,
    /// which makes it negative for everybody except the leader. That is not a
    /// nicety: with the gap measured downwards, the last candidate in a list has
    /// nothing below it, reports a huge margin, and reads as auto-assignable
    /// while sitting in second place. Measured on a bank holding one voice under
    /// two names, which is what a mislabel looks like: the runner-up printed
    /// `margin +0.828  -> would name automatically` underneath the leader it had
    /// just lost to. `autoAssign` only ever looks at the leader, so nothing
    /// wrong would have been written, but a diagnostic that says the opposite of
    /// what the code does is worse than no diagnostic.
    ///
    /// **The level alone is not enough to act on and the margin is what makes
    /// it safe.** A bank holding one bad print can put the same voice near two
    /// names at once, which is not a hypothetical: this library did exactly
    /// that for a day, with the user's own voice scoring +0.87 against somebody
    /// else's name. A high score says "this looks like Marcia"; a high score
    /// with a wide margin says "and it looks like nobody else".
    var margin: Float

    var confidence: VoiceConfidence {
        if score >= VoiceBank.certainThreshold { return .almostCertain }
        if score >= VoiceBank.strongThreshold { return .likely }
        return .possible
    }

    /// Whether this may be applied without asking. Both halves required.
    var autoAssignable: Bool {
        score >= VoiceBank.certainThreshold && margin >= VoiceBank.marginThreshold
    }

    /// What the labelling UI shows under the name.
    var summary: String { "\(name) · \(confidence.label.lowercased())" }
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

    /// Measured with `listen calibrate` on **real recordings**: 14 named
    /// voiceprints across 5 people, 27 same-person and 57 different-person
    /// cross-recording pairs.
    ///
    ///     same person       min +0.668  median +0.807  max +0.901
    ///     different people  min -0.091  median +0.136  max +0.371
    ///
    /// Clean separation, gap +0.297, so these sit one third and two thirds of
    /// the way across it.
    ///
    /// **These replace numbers measured on synthesised speech, which were
    /// wrong in a way worth remembering.** That earlier run gave same-person
    /// pairs of 0.979 to 0.995 and suggested a match threshold of 0.72. Real
    /// voices score far lower against themselves: the worst genuine same-person
    /// pair here is **0.668**, so the synthetic threshold would have refused to
    /// suggest a person the bank had heard four times. One TTS voice reading
    /// two scripts is nearly identical to itself; a person on two days, on two
    /// microphones, in two rooms, is not. Synthetic audio measures the model's
    /// ceiling, not the task.
    ///
    /// The different-person side moved too, and the other way: 0.597 synthetic
    /// against 0.371 real. Both errors pushed the same direction, toward a
    /// threshold too high to be useful.
    ///
    /// Re-run `listen calibrate` as the library grows. Five people is enough to
    /// separate cleanly and not enough to have met a confusable pair, so the
    /// different-person maximum is the number most likely to rise.
    static let matchThreshold: Float = 0.47
    static let strongThreshold: Float = 0.57

    /// Where a suggestion stops being a suggestion.
    ///
    /// Re-measured for **centroid** scoring, which is what `suggestions` now
    /// does and which separates far better than the pairwise numbers above.
    /// Leave one print out, score it against the centroid of that person's
    /// others and against every other person's centroid, over the whole
    /// library: 20 same-person and 112 different-person comparisons.
    ///
    ///     same person       min +0.642  p10 +0.746  median +0.863  max +0.914
    ///     different people  min -0.166  median +0.110  p99 +0.360  max +0.371
    ///
    /// Gap +0.271, and where 0.75 falls in it:
    ///
    ///     threshold  true matches auto-assigned  false pairs above it
    ///        0.65               90%                       0
    ///        0.75               85%                       0
    ///        0.80               75%                       0
    ///
    /// 0.75 rather than 0.65 because the five points of recall it gives up buy
    /// **0.379 of clearance** over the worst different-person pair, which is
    /// more than the whole gap. This number applies a name to an archive nobody
    /// may read for a month, so the direction to be wrong in is "asked when it
    /// need not have".
    static let certainThreshold: Float = 0.75

    /// How far clear of second place an automatic name has to be.
    ///
    /// The smallest margin observed on a *correct* top candidate was +0.436, so
    /// this costs nothing today and is not fitted to the sample. It exists
    /// because the sample is six people: as a bank grows, two people who
    /// genuinely sound alike will eventually both clear `certainThreshold`, and
    /// on that recording nothing should be applied silently. This library has
    /// already had the pathological version, where one mislabelled cluster put
    /// the user's own voice at +0.87 against somebody else's name.
    static let marginThreshold: Float = 0.15

    // MARK: - Reading

    /// Every named voiceprint in the library that counts as evidence.
    ///
    /// Placeholders are excluded: "A" in one meeting has nothing to do with
    /// "A" in another, and suggesting one for the other would be worse than
    /// suggesting nothing.
    ///
    /// **Automatically applied names are excluded too, and that is the rule
    /// that keeps this feature from compounding its own mistakes.** A name the
    /// bank chose is not somebody saying who this is, so letting it back in as
    /// evidence means one wrong assignment recruits the next, and the next, with
    /// each round more confident than the last. This library has already shown
    /// what a single wrong identity does to the bank from a *human* assertion:
    /// different-person pairs went from +0.371 to +0.871 and `listen calibrate`
    /// lost its separation entirely. The bank only ever grows from a person.
    static func named(excluding recording: Recording? = nil) -> [(String, Voiceprint)] {
        var out: [(String, Voiceprint)] = []
        for r in Recording.all() where r.id != recording?.id {
            for (label, print) in r.voiceprints
            where !isPlaceholder(label) && print.auto != true {
                out.append((label, print))
            }
        }
        return out
    }

    /// Rank the named voices in the library against one speaker here.
    ///
    /// **Scored against each person's centroid, not their best single print.**
    /// The max was measurably wrong in the direction that matters: a speaker
    /// whose person had five recordings in the library, only one of them
    /// labelled, was scored against that one, and it happened to be the least
    /// representative of the five. It returned +0.603 for a match whose centroid
    /// score is +0.828, which the interface then reported as "60%". The max is
    /// also the statistic a single bad print can carry on its own, which is
    /// exactly what an automatic assignment must not be exposed to.
    ///
    /// Each print is normalised before averaging and the mean is normalised
    /// again, so a person is one direction rather than one recording.
    /// Deliberately **unweighted** by speech seconds: the point of pooling is to
    /// average over rooms, microphones and days, and weighting by duration lets
    /// the single longest meeting decide what somebody sounds like.
    static func suggestions(for speaker: String, in recording: Recording) -> [VoiceMatch] {
        guard let mine = recording.voiceprints[speaker], mine.isEvidence else { return [] }
        let me = unit(mine.embedding)

        var prints: [String: [[Float]]] = [:]
        for (name, other) in named(excluding: recording) {
            // Below 15 seconds an embedding is stored but is not evidence: it
            // is too short to be an identity, and a confident wrong suggestion
            // is worse than none.
            guard other.isEvidence else { continue }
            prints[name, default: []].append(other.embedding)
        }

        // Everybody is scored and ranked before anything is filtered, because
        // the margin is a fact about the whole field. Dropping the sub-threshold
        // candidates first would report a runner-up at +0.46 as no runner-up at
        // all, and hand a wide margin to a match that has somebody sitting right
        // behind it.
        let ranked = prints
            .map { (name: $0.key, score: dot(me, centroid(of: $0.value)), count: $0.value.count) }
            .sorted { $0.score > $1.score }

        return ranked.enumerated().compactMap { i, entry in
            guard entry.score >= matchThreshold else { return nil }
            // The best *other* candidate: second place for the leader, first
            // place for everybody else. See `VoiceMatch.margin`.
            let rival = i == 0 ? (ranked.count > 1 ? ranked[1].score : 0) : ranked[0].score
            return VoiceMatch(name: entry.name, score: entry.score,
                              recordings: entry.count, margin: entry.score - rival)
        }
    }

    /// One direction standing for one person.
    static func centroid(of embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for e in embeddings {
            let u = unit(e)
            for i in 0..<min(sum.count, u.count) { sum[i] += u[i] }
        }
        return unit(sum)
    }

    /// A vector scaled to length one, so a dot product is a cosine.
    static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard n > 0 else { return v }
        return v.map { $0 / n }
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var out: Float = 0
        for i in 0..<min(a.count, b.count) { out += a[i] * b[i] }
        return out
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

    // MARK: - Naming without being asked

    /// Name the speakers the bank is sure about, and report what it did.
    ///
    /// Runs once, from `Recording.markTranscribed`, so it happens before anybody
    /// has been asked anything and covers both the queue and `listen
    /// transcribe` through the one call they share.
    ///
    /// Four things hold this together, and each is a way it could have gone
    /// wrong:
    ///
    /// 1. **Both gates, not one.** `autoAssignable` wants the level *and* the
    ///    margin. See `marginThreshold`.
    /// 2. **A name is claimed once.** Two placeholders in one recording cannot
    ///    both become Marcia. The second is left for a human, because two
    ///    speakers resolving to one person is either a diarizer split or a wrong
    ///    match, and neither is something to decide silently.
    /// 3. **It goes through `TranscriptEditor`**, the same write the window and
    ///    `listen label` use, so there is no second implementation of renaming a
    ///    speaker to disagree with the first.
    /// 4. **It is recorded as automatic**, in `metadata.auto_named` and on the
    ///    voiceprint, so it is visible, reversible, and never becomes evidence.
    @discardableResult
    static func autoAssign(in recording: Recording) -> [(speaker: String, name: String)] {
        var current = recording
        var applied: [(speaker: String, name: String)] = []
        var claimed = Set(recording.speakers)

        // Sorted, so the outcome does not depend on dictionary ordering. Two
        // runs over the same recording have to agree, or the same audio names
        // different people on two Macs.
        for speaker in recording.speakers.filter(isPlaceholder).sorted() {
            guard let top = suggestions(for: speaker, in: current).first,
                  top.autoAssignable, !claimed.contains(top.name) else { continue }
            guard TranscriptEditor.apply(.rename(speaker, to: top.name), to: current,
                                         backup: false) else { continue }
            claimed.insert(top.name)
            applied.append((speaker, top.name))
            markAuto(top.name, in: current)
            // Re-read: the edit rewrote the transcript and the sidecar, and the
            // next speaker is scored against what is on disk now.
            current = Recording.find(recording.id) ?? current
        }

        guard !applied.isEmpty else { return [] }
        var updated = current
        updated.metadata.auto_named =
            (updated.metadata.auto_named ?? []) + applied.map(\.name)
        try? updated.save()
        // The event stays on stderr unconditionally: this is the app writing
        // into an archive nobody may open for a month, and that has to be
        // visible. The name itself is behind `LISTEN_DEBUG`, because a GUI
        // launch sends stderr to the unified log, where a person's name would
        // sit in plain text for any diagnostic report to sweep up.
        for a in applied {
            log("named \(SpeakerName.display(a.speaker)) by voice "
                + "in \(recording.id)")
            trace("  as \(a.name)")
        }
        return applied
    }

    /// Mark a voiceprint as one the bank chose rather than a person.
    private static func markAuto(_ name: String, in recording: Recording) {
        var bank = recording.voiceprints
        guard var print = bank[name] else { return }
        print.auto = true
        bank[name] = print
        write(bank, to: recording)
    }

    // MARK: - Writing

    /// Move a voiceprint to its new name, keeping the bank aligned with the
    /// transcript. Without this the embedding stays filed under "B" while the
    /// transcript says "Anna", and the next recording gets no suggestion.
    static func rename(_ speaker: String, to name: String, in recording: Recording) {
        var bank = recording.voiceprints
        guard var moving = bank.removeValue(forKey: speaker) else { return }
        // A human has touched this speaker, so whatever the bank decided about
        // it earlier is now somebody's decision and counts as evidence again.
        // This is the only route back: nothing else clears the flag, which is
        // deliberate, because "the name is still there" is not somebody
        // agreeing with it.
        moving.auto = nil
        // Renaming into a name this recording already has merges two speakers,
        // so one person ends up with two voiceprints. Keep whichever was built
        // from more speech: `isEvidence` is a threshold in seconds, and keeping
        // the shorter one can drop a usable identity below it.
        if let existing = bank[name], existing.speech > moving.speech {
            bank[name] = existing
        } else {
            bank[name] = moving
        }
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
