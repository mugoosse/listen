import Foundation

/// Scores every named voiceprint against every other and reports how well
/// same-person pairs separate from different-person pairs.
///
/// Ported from `enroll_voiceprints.py --calibrate`. This is how the thresholds
/// in `VoiceBank` are supposed to be set: the Python's 0.50 and 0.65 were
/// measured against pyannote embeddings on 24 voiceprints across 8 people, and
/// FluidAudio uses a different model, so those numbers mean nothing here.
/// Carrying them over would be borrowing somebody else's measurement.
///
/// Because the names were applied by ear, this doubles as an eval set: a
/// same-person pair scoring like a stranger is either a mislabel or a hard
/// case, and both are worth looking at.
enum Calibrate {

    struct Sample {
        var name: String
        var vector: [Float]
        var recording: String
    }

    struct Report {
        var samples: Int
        var people: Int
        var same: [Float]
        var different: [Float]
        /// Worst same-person pairs, for spotting mislabels.
        var weakest: [(Float, String, String)]
        var threshold: Float
        var recall: Double
        var specificity: Double
    }

    /// Every named, evidence-grade voiceprint in the library.
    static func samples() -> [Sample] {
        var out: [Sample] = []
        for recording in Recording.all() {
            for (name, print) in recording.voiceprints {
                // Placeholders are not identities: "A" in one meeting has
                // nothing to do with "A" in another, so pairing them would
                // manufacture both false same-person and false different-person
                // pairs and poison the measurement in both directions.
                guard !VoiceBank.isPlaceholder(name), print.isEvidence else { continue }
                out.append(Sample(name: name, vector: print.embedding,
                                  recording: recording.id))
            }
        }
        return out
    }

    static func run() -> Report? {
        let all = samples()
        guard all.count >= 2 else { return nil }

        var same: [Float] = []
        var different: [Float] = []
        var weakest: [(Float, String, String)] = []

        for i in all.indices {
            for j in (i + 1)..<all.count {
                let a = all[i], b = all[j]
                // Two voiceprints from the same recording are trivially
                // separable: they were produced by the clustering step that
                // decided they were different people in the first place. Using
                // them would measure the diarizer agreeing with itself.
                guard a.recording != b.recording else { continue }
                let score = VoiceBank.cosine(a.vector, b.vector)
                if a.name == b.name {
                    same.append(score)
                    weakest.append((score, a.name, a.recording))
                } else {
                    different.append(score)
                }
            }
        }
        guard !same.isEmpty, !different.isEmpty else {
            return Report(samples: all.count, people: Set(all.map(\.name)).count,
                          same: same, different: different, weakest: [],
                          threshold: 0, recall: 0, specificity: 0)
        }

        same.sort()
        different.sort()
        weakest.sort { $0.0 < $1.0 }
        let best = bestThreshold(same: same, different: different)

        return Report(samples: all.count, people: Set(all.map(\.name)).count,
                      same: same, different: different,
                      weakest: Array(weakest.prefix(5)),
                      threshold: best.threshold, recall: best.recall,
                      specificity: best.specificity)
    }

    /// The threshold maximising balanced accuracy over the observed pairs.
    ///
    /// Balanced rather than raw accuracy because the two classes are wildly
    /// unequal: with n people there are far more different-person pairs than
    /// same-person ones, so plain accuracy is maximised by a threshold that
    /// never matches anybody.
    static func bestThreshold(same: [Float], different: [Float])
        -> (threshold: Float, recall: Double, specificity: Double) {
        var best: (Float, Double, Double, Double) = (0, 0, 0, -1)
        for candidate in Set(same + different).sorted() {
            let recall = Double(same.filter { $0 >= candidate }.count) / Double(same.count)
            let specificity = Double(different.filter { $0 < candidate }.count)
                / Double(different.count)
            let balanced = (recall + specificity) / 2
            if balanced > best.3 { best = (candidate, recall, specificity, balanced) }
        }
        return (best.0, best.1, best.2)
    }

    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let mid = values.count / 2
        return values.count % 2 == 1 ? values[mid] : (values[mid - 1] + values[mid]) / 2
    }

    /// The report, written out.
    static func print(_ report: Report) {
        Swift.print("named voiceprints: \(report.samples) across \(report.people) people")
        Swift.print("cross-recording pairs: \(report.same.count) same-person, "
                    + "\(report.different.count) different")

        guard !report.same.isEmpty, !report.different.isEmpty else {
            Swift.print("")
            Swift.print("Need at least one person appearing in two recordings to calibrate.")
            Swift.print("Name the same voice in two meetings, then run this again.")
            return
        }

        func line(_ label: String, _ v: [Float]) {
            Swift.print(String(format: "%@ min %+.3f  median %+.3f  max %+.3f",
                               label, v[0], median(v), v[v.count - 1]))
        }
        Swift.print("")
        line("same person      ", report.same)
        line("different people ", report.different)

        Swift.print("")
        Swift.print(String(format: "best separating threshold: %+.3f", report.threshold))
        Swift.print(String(format: "  same-person pairs above it:      %.0f%%",
                           report.recall * 100))
        Swift.print(String(format: "  different-person pairs below it: %.0f%%",
                           report.specificity * 100))

        Swift.print("")
        Swift.print(String(format: "configured: matchThreshold=%+.2f strongThreshold=%+.2f",
                           VoiceBank.matchThreshold, VoiceBank.strongThreshold))

        // The gap between the two distributions is the number that matters. A
        // threshold sitting inside an overlap is a coin toss dressed as a
        // measurement, and the honest thing is to say so rather than print a
        // confident-looking constant.
        let gap = report.same[0] - report.different[report.different.count - 1]
        Swift.print("")
        if gap > 0 {
            Swift.print(String(format: "clean separation: worst same-person pair (%+.3f) is "
                               + "above the best different-person pair (%+.3f), gap %+.3f",
                               report.same[0], report.different[report.different.count - 1],
                               gap))
            Swift.print(String(format: "suggested: matchThreshold=%+.2f strongThreshold=%+.2f",
                               report.different[report.different.count - 1] + gap * 0.33,
                               report.different[report.different.count - 1] + gap * 0.66))
        } else {
            Swift.print(String(format: "the distributions overlap by %+.3f. Any threshold here "
                               + "trades false matches against missed ones.", -gap))
        }

        if !report.weakest.isEmpty {
            Swift.print("")
            Swift.print("weakest same-person pairs (check these for mislabels):")
            for (score, name, where_) in report.weakest {
                Swift.print(String(format: "  %+.3f  %@  (%@)", score, name, where_))
            }
        }
    }
}
