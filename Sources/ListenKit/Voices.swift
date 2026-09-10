import Foundation

/// One speaker's voiceprint from one recording.
///
/// **Moved here from the Mac's `Pipeline.swift`, and the move is the feature.**
/// Both apps run the same FluidAudio speaker model, so a vector made on an
/// iPhone and a vector made on a Mac are directly comparable. They were not
/// comparable in practice while the type, the thresholds and the arithmetic
/// lived in a target the phone does not compile: a second implementation of
/// cosine and a second copy of `certainThreshold` is how two devices come to
/// disagree about who is speaking, and disagreeing about that is worse than
/// one of them declining to answer.
public struct Voiceprint: Codable, Sendable {
    public var embedding: [Float]

    /// Seconds of speech it was built from.
    ///
    /// Two floors, because asking and answering are different risks. See
    /// `minimumSpeechForEvidence` and `minimumSpeechForQuery`.
    public var speech: Double

    /// True when the bank named this speaker rather than a person doing it.
    ///
    /// `Optional`, and that is load-bearing for the reason recorded against
    /// `Metadata.calendar_event_id`: Swift's synthesized decoder throws
    /// `keyNotFound` on a missing key even where the property has a default, so
    /// a non-optional `Bool = false` would make every `embeddings.json` written
    /// before this field fail to decode, and `Recording.voiceprints` swallows
    /// that with `try?` and returns `[:]`. The whole voice bank would have
    /// emptied itself with nothing anywhere reporting it.
    ///
    /// Read by `VoiceBankCore.addEvidence`, which is what keeps an automatic
    /// name from becoming the evidence for the next one.
    public var auto: Bool?

    public init(embedding: [Float], speech: Double, auto: Bool? = nil) {
        self.embedding = embedding; self.speech = speech; self.auto = auto
    }

    /// How much speech a print needs before the bank will match *against* it.
    ///
    /// The expensive direction. Evidence is what every later recording is
    /// scored against, so one unreliable identity in here is not one wrong
    /// name, it is a wrong name that recruits the next one: this library has
    /// already had different-person pairs go from +0.371 to +0.871 off a single
    /// bad print. Nothing cheap is worth loosening this.
    public static let minimumSpeechForEvidence: Double = 15

    /// How much speech a print needs before the bank will ask *who it is*.
    ///
    /// **A third of the evidence floor, deliberately.** One number used to do
    /// both jobs, and it made the phone useless at the thing a phone is for: a
    /// nine-second memo is one voice saying one thing, which is the easiest
    /// identification in the library and the one Listen refused to make. A Mac
    /// never noticed because a meeting clears fifteen seconds in its first
    /// minute.
    ///
    /// Measured over all 81 named prints in the development library, scoring
    /// each against a bank built from every other recording. Under five seconds
    /// the top match was wrong both times it was tried (2.9 s and 4.4 s, both
    /// held back by `certainThreshold` rather than by any floor). At five
    /// seconds and above it was right every time, and the three that cleared
    /// both gates were all correct at +0.81 to +0.86. The two auto-assignments
    /// that *would* have been wrong came from 329 and 404 seconds of speech, so
    /// length was never what separated them: `autoAssignable` was.
    ///
    /// What makes the cheaper floor affordable is that a wrong answer here is
    /// visible and undoable. It is stamped `auto`, it never becomes evidence,
    /// the Mac records it in `auto_named`, and on the phone the speaker chip
    /// opens `SpeakerNameSheet` on one tap. A wrong entry in the evidence pool
    /// has none of those properties, which is why that floor does not move.
    public static let minimumSpeechForQuery: Double = 5

    public var isEvidence: Bool { speech >= Self.minimumSpeechForEvidence }

    /// Whether this print is worth asking the bank about.
    public var canQuery: Bool { speech >= Self.minimumSpeechForQuery }
}

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
public enum VoiceConfidence: Sendable {
    case possible
    case likely
    case almostCertain

    public var label: String {
        switch self {
        case .possible:      return "Possibly them"
        case .likely:        return "Likely them"
        case .almostCertain: return "Almost certainly them"
        }
    }
}

/// One candidate match for an unnamed voice.
public struct VoiceMatch: Sendable {
    public var name: String
    /// Cosine against that person's centroid, not against their best single
    /// print. See `VoiceBankCore.rank`.
    public var score: Float
    /// How many recordings that name has a voiceprint in.
    public var recordings: Int
    /// How far clear of the nearest rival this one is.
    ///
    /// Signed against the **best competitor**, not against the next one down,
    /// which makes it negative for everybody except the leader. That is not a
    /// nicety: with the gap measured downwards, the last candidate in a list has
    /// nothing below it, reports a huge margin, and reads as auto-assignable
    /// while sitting in second place. Measured on a bank holding one voice under
    /// two names, which is what a mislabel looks like: the runner-up printed
    /// `margin +0.828  -> would name automatically` underneath the leader it had
    /// just lost to. Only the leader is ever applied, so nothing wrong would
    /// have been written, but a diagnostic that says the opposite of what the
    /// code does is worse than no diagnostic.
    ///
    /// **The level alone is not enough to act on and the margin is what makes
    /// it safe.** A bank holding one bad print can put the same voice near two
    /// names at once, which is not a hypothetical: this library did exactly
    /// that for a day, with the user's own voice scoring +0.87 against somebody
    /// else's name. A high score says "this looks like Marcia"; a high score
    /// with a wide margin says "and it looks like nobody else".
    public var margin: Float

    public init(name: String, score: Float, recordings: Int, margin: Float) {
        self.name = name; self.score = score
        self.recordings = recordings; self.margin = margin
    }

    public var confidence: VoiceConfidence {
        if score >= VoiceBankCore.certainThreshold { return .almostCertain }
        if score >= VoiceBankCore.strongThreshold { return .likely }
        return .possible
    }

    /// Whether this may be applied without asking. Both halves required.
    public var autoAssignable: Bool {
        score >= VoiceBankCore.certainThreshold && margin >= VoiceBankCore.marginThreshold
    }

    /// What the labelling UI shows under the name.
    public var summary: String { "\(name) · \(confidence.label.lowercased())" }
}

/// The half of cross-recording speaker recognition that is arithmetic: the
/// thresholds, the cosine, the centroid and the ranking.
///
/// **There is no database, on either device.** The set of `embeddings.json`
/// files next to the recordings *is* the voice bank, which is what makes
/// deleting a recording in Finder safe: it cannot strand an entry, because the
/// entry lived in the folder that was deleted. Preserve this property; a cache
/// would reintroduce exactly the inconsistency it removes.
///
/// What is deliberately **not** here is anything that writes. The Mac renames a
/// speaker through `TranscriptEditor` so that the transcript, the turns and the
/// bank move together, and the phone rewrites a provisional transcript that
/// never leaves it. Those are different writes over different files and they
/// stay in their own apps. What both share is the answer to "does this voice
/// belong to somebody the library already knows", and sharing it is the only
/// way the two devices can be relied on to give the same one.
public enum VoiceBankCore {

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
    public static let matchThreshold: Float = 0.47
    public static let strongThreshold: Float = 0.57

    /// Where a suggestion stops being a suggestion.
    ///
    /// Re-measured for **centroid** scoring, which is what `rank` does and
    /// which separates far better than the pairwise numbers above. Leave one
    /// print out, score it against the centroid of that person's others and
    /// against every other person's centroid, over the whole library: 20
    /// same-person and 112 different-person comparisons.
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
    ///
    /// **The same number on the phone, deliberately.** The phone reads a
    /// recording it has just made and the Mac reads it again properly an hour
    /// later, so a phone that named more freely would spend that hour showing
    /// names the Mac then quietly takes away, which reads as the Mac undoing
    /// good work. One threshold means the two devices reach the same answer or
    /// neither of them does.
    public static let certainThreshold: Float = 0.75

    /// How far clear of second place an automatic name has to be.
    ///
    /// The smallest margin observed on a *correct* top candidate was +0.436, so
    /// this costs nothing today and is not fitted to the sample. It exists
    /// because the sample is six people: as a bank grows, two people who
    /// genuinely sound alike will eventually both clear `certainThreshold`, and
    /// on that recording nothing should be applied silently. This library has
    /// already had the pathological version, where one mislabelled cluster put
    /// the user's own voice at +0.87 against somebody else's name.
    public static let marginThreshold: Float = 0.15

    // MARK: - Evidence

    /// True for a label the pipeline invented rather than a person's name.
    public static func isPlaceholder(_ label: String) -> Bool {
        if label == "unknown" { return true }
        // A, B, ... Z, AA. Spreadsheet columns, which is what the Mac's
        // `Merge.letter` and the phone's `LocalTranscribe.assign` produce.
        // "Me" is not a placeholder: the mic track really is the user, so it is
        // a fact rather than something awaiting a decision.
        return !label.isEmpty && label.allSatisfy { $0.isUppercase && $0.isLetter }
            && label.count <= 2 && label != "Me"
    }

    /// Whether a person, rather than a pass of the pipeline, has said who one
    /// of these voices is.
    ///
    /// The same two exclusions `addEvidence` applies, minus the speech floor: a
    /// name somebody typed over a nine-second voiceprint is still that person
    /// saying who it is, even where the print is too short to recognise them by
    /// later.
    ///
    /// Read by `CloudSyncCore.speaksFor`, which is what keeps a name applied on
    /// a phone from being quietly replaced by a Mac's machine pass over the
    /// same audio, and by the Mac's own pipeline, which adopts it.
    public static func holdsHumanName(_ bank: [String: Voiceprint]) -> Bool {
        bank.contains { !isPlaceholder($0.key) && $0.value.auto != true }
    }

    /// The human names in one bank, with the vectors they were applied to.
    public static func humanNames(_ bank: [String: Voiceprint]) -> [String: Voiceprint] {
        bank.filter { !isPlaceholder($0.key) && $0.value.auto != true }
    }

    /// Fold one recording's bank into a candidate set, keeping only what counts
    /// as evidence.
    ///
    /// Three exclusions, and each is a way the bank could poison itself:
    ///
    /// 1. **Placeholders.** "A" in one meeting has nothing to do with "A" in
    ///    another, and suggesting one for the other would be worse than
    ///    suggesting nothing.
    /// 2. **Automatically applied names.** A name the bank chose is not
    ///    somebody saying who this is, so letting it back in as evidence means
    ///    one wrong assignment recruits the next, and the next, with each round
    ///    more confident than the last. This library has already shown what a
    ///    single wrong identity does from a *human* assertion: different-person
    ///    pairs went from +0.371 to +0.871 and `listen calibrate` lost its
    ///    separation entirely. The bank only ever grows from a person.
    /// 3. **Prints too short to be an identity.** See
    ///    `Voiceprint.minimumSpeechForEvidence`.
    ///
    /// The second exclusion is what makes it safe for a phone to name a voice
    /// at all: everything the phone applies is marked `auto`, so nothing the
    /// phone decided can ever become the reason for the next decision.
    public static func addEvidence(from bank: [String: Voiceprint],
                                   to prints: inout [String: [[Float]]]) {
        for (name, print) in bank
        where !isPlaceholder(name) && print.auto != true && print.isEvidence {
            prints[name, default: []].append(print.embedding)
        }
    }

    /// Carry names a person applied to an earlier pass onto a fresh one's
    /// clusters.
    ///
    /// **The arithmetic behind a name typed on a phone surviving the Mac's own
    /// diarization of the same audio.** The phone names a voice, that lands in
    /// the recording's bank and travels; a Mac then runs the real pipeline over
    /// the same recording and is about to replace the file. This says which of
    /// its fresh clusters each human name belongs to.
    ///
    /// **Both vectors come from the same audio, which is what makes it safe.**
    /// A correct cross-recording match scores around +0.84; the same voice
    /// compared with itself on one recording scores around +0.95, so
    /// `certainThreshold` is a far wider margin here than where it was
    /// measured. A run that clustered differently enough to have no cluster
    /// above it genuinely has nowhere to put the name, and returning nothing is
    /// the right answer.
    ///
    /// A name is claimed once and only placeholders are replaced, both for the
    /// reasons `VoiceBank.autoAssign` gives. Sorted, so two runs over the same
    /// recording agree rather than depending on dictionary order.
    ///
    /// - Returns: cluster label to person's name, for the ones it is sure of.
    public static func adopt(_ applied: [String: Voiceprint],
                             onto clusters: [String: [Float]]) -> [String: String] {
        guard !applied.isEmpty, !clusters.isEmpty else { return [:] }
        var taken = Set(clusters.keys.filter { !isPlaceholder($0) })
        var moves: [String: String] = [:]
        for (name, print) in applied.sorted(by: { $0.key < $1.key }) {
            guard !taken.contains(name), !print.embedding.isEmpty else { continue }
            let best = clusters
                .filter { isPlaceholder($0.key) && moves[$0.key] == nil }
                .map { ($0.key, cosine(print.embedding, $0.value)) }
                .max { $0.1 < $1.1 }
            guard let best, best.1 >= certainThreshold else { continue }
            moves[best.0] = name
            taken.insert(name)
        }
        return moves
    }

    // MARK: - Ranking

    /// Rank the named voices in a bank against one unnamed voice.
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
    /// Everybody is scored and ranked before anything is filtered, because the
    /// margin is a fact about the whole field. Dropping the sub-threshold
    /// candidates first would report a runner-up at +0.46 as no runner-up at
    /// all, and hand a wide margin to a match that has somebody sitting right
    /// behind it.
    public static func rank(_ embedding: [Float],
                            against prints: [String: [[Float]]]) -> [VoiceMatch] {
        guard !embedding.isEmpty, !prints.isEmpty else { return [] }
        let me = unit(embedding)
        let ranked = prints
            .map { (name: $0.key, score: dot(me, centroid(of: $0.value)),
                    count: $0.value.count) }
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

    // MARK: - Arithmetic

    /// One direction standing for one person.
    ///
    /// Each print is normalised before averaging and the mean is normalised
    /// again, so a person is one direction rather than one recording.
    /// Deliberately **unweighted** by speech seconds: the point of pooling is to
    /// average over rooms, microphones and days, and weighting by duration lets
    /// the single longest meeting decide what somebody sounds like.
    public static func centroid(of embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        var sum = [Float](repeating: 0, count: first.count)
        for e in embeddings {
            let u = unit(e)
            for i in 0..<min(sum.count, u.count) { sum[i] += u[i] }
        }
        return unit(sum)
    }

    /// A vector scaled to length one, so a dot product is a cosine.
    public static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard n > 0 else { return v }
        return v.map { $0 / n }
    }

    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var out: Float = 0
        for i in 0..<min(a.count, b.count) { out += a[i] * b[i] }
        return out
    }

    /// Cosine similarity. Both vectors come from the same model, so no
    /// normalisation beyond this is needed.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
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

    /// Combine whole voiceprints, each weighted by the speech behind it.
    ///
    /// `average` is the per-segment case and weights every segment equally,
    /// which is right when the segments are what you have. This is the case
    /// where two *centroids* have to become one, and there weighting matters:
    /// `Join` puts two recordings of one conversation together, and a speaker
    /// who said four words before the interruption and four minutes after it
    /// must not count half. Weighting by seconds is what makes the result the
    /// vector the pipeline would have produced from the whole conversation.
    ///
    /// Here rather than in the app target for the reason stated at the top of
    /// this file: a second implementation of this arithmetic is how two devices
    /// come to disagree about who is speaking.
    public static func weighted(_ prints: [(embedding: [Float], speech: Double)]) -> [Float] {
        let usable = prints.filter { !$0.embedding.isEmpty }
        guard let width = usable.first?.embedding.count, width > 0 else { return [] }
        // A print with no speech behind it still says something about direction,
        // so it counts as a segment rather than as nothing. Falling to zero
        // would let one malformed sidecar erase a speaker's identity.
        let weights = usable.map { max($0.speech, 1) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return usable[0].embedding }
        var out = [Float](repeating: 0, count: width)
        for (print, weight) in zip(usable, weights) {
            let scale = Float(weight / total)
            for i in 0..<min(width, print.embedding.count) { out[i] += print.embedding[i] * scale }
        }
        return out
    }

    /// Average per-segment embeddings into one per cluster, which is what a
    /// voiceprint is.
    ///
    /// Shared so the two diarizers cannot drift: the Mac's `Diarizer.run` and
    /// the phone's `LocalDiarize` both hand FluidAudio segments to this, and a
    /// vector built one way on one device and another way on the other is a
    /// vector that scores against itself at less than one.
    public static func average(_ perSegment: [(label: String, embedding: [Float])])
        -> [String: [Float]] {
        var sums: [String: [Float]] = [:]
        var counts: [String: Int] = [:]
        for segment in perSegment where !segment.embedding.isEmpty {
            if var running = sums[segment.label] {
                for i in running.indices where i < segment.embedding.count {
                    running[i] += segment.embedding[i]
                }
                sums[segment.label] = running
            } else {
                sums[segment.label] = segment.embedding
            }
            counts[segment.label, default: 0] += 1
        }
        var out: [String: [Float]] = [:]
        for (label, sum) in sums {
            let n = Float(max(counts[label] ?? 1, 1))
            out[label] = sum.map { $0 / n }
        }
        return out
    }
}

extension Recording {
    /// This recording's slice of the voice bank, which is a file and not a row
    /// in anything.
    public var voiceprints: [String: Voiceprint] {
        guard let data = try? Data(contentsOf: embeddingsURL),
              let bank = try? JSONDecoder().decode([String: Voiceprint].self, from: data)
        else { return [:] }
        return bank
    }

    /// Replace it, or remove the file when nothing is left.
    ///
    /// An empty file and no file are the same fact and only one of them is
    /// worth keeping: `DevicePolicy.voiceprintFiles` is what decides whether a
    /// folder has voiceprint material in it, and an empty `{}` would answer
    /// yes for ever after the last print in it was forgotten.
    public func writeVoiceprints(_ bank: [String: Voiceprint]) {
        guard !bank.isEmpty else {
            try? FileManager.default.removeItem(at: embeddingsURL)
            return
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(bank).write(to: embeddingsURL, options: .atomic)
    }
}
