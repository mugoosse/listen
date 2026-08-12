import Foundation

/// A transcript segment that knows who said it.
struct LabelledSegment: Codable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

/// One speaker's uninterrupted stretch of speech, the condensed view.
///
/// Same shape as the Python's `consolidate_turns` output, so `turns.json` stays
/// readable by the existing tools.
struct Turn: Codable {
    var start: Double
    var end: Double
    var speaker: String
    var text: String
}

/// Word-to-speaker assignment and transcript cleanup.
///
/// Ported from `transcribe_call.py`, which is where the accumulated value in
/// the Python pipeline actually sits. The rules here were tuned against real
/// meeting recordings; changing one because it looks arbitrary is how you
/// rediscover why it is not.
enum Merge {

    // MARK: - Assignment

    /// Which speaker is talking at `time`.
    ///
    /// Falls back to the nearest turn rather than nil when nothing covers the
    /// instant, because a word in a gap still belongs to somebody, and dropping
    /// it loses transcript.
    static func speaker(at time: Double, in turns: [SpeakerTurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        var best: String?
        var bestDistance = Double.greatestFiniteMagnitude
        for turn in turns {
            if turn.start <= time && time <= turn.end { return turn.label }
            let distance = time < turn.start ? turn.start - time : time - turn.end
            if distance < bestDistance {
                bestDistance = distance
                best = turn.label
            }
        }
        return best
    }

    /// The speaker who holds the most of an interval.
    ///
    /// Used when there are no word timings, so a whole sentence has to go to one
    /// person. Overlap-weighted rather than midpoint-based: a sentence that
    /// starts in a short interjection and continues into a long answer belongs
    /// to whoever actually said most of it.
    static func bestSpeaker(from start: Double, to end: Double,
                            in turns: [SpeakerTurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        var totals: [String: Double] = [:]
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 { totals[turn.label, default: 0] += overlap }
        }
        if let winner = totals.max(by: { $0.value < $1.value })?.key { return winner }
        return speaker(at: (start + end) / 2, in: turns)
    }

    /// Assign speakers to ASR segments, splitting a segment where the speaker
    /// changes inside it.
    ///
    /// The split is the point of this function and it needs word timings. With
    /// them, each word goes to the speaker talking at its midpoint and a run of
    /// words by one speaker becomes one segment, so an interruption cuts the
    /// sentence in the right place. Without them the whole sentence goes to
    /// whoever holds most of it, which is coarser: two people talking over each
    /// other inside one sentence come out as one.
    ///
    /// mlx-audio does not currently expose word timings (see CLAUDE.md), so the
    /// second path is the one that runs today. The first is kept whole because
    /// it is the design, and because the moment the timings appear it is the
    /// only thing that has to change.
    static func assign(_ segments: [ASRSegment], to turns: [SpeakerTurn],
                       fallback: String) -> [LabelledSegment] {
        var out: [LabelledSegment] = []
        for segment in segments {
            guard !segment.words.isEmpty else {
                let who = bestSpeaker(from: segment.start, to: segment.end, in: turns) ?? fallback
                out.append(LabelledSegment(start: segment.start, end: segment.end,
                                           speaker: who, text: segment.text))
                continue
            }

            var current: LabelledSegment?
            for word in segment.words {
                let who = speaker(at: (word.start + word.end) / 2, in: turns) ?? fallback
                if current == nil || current!.speaker != who {
                    if let c = current { out.append(c) }
                    current = LabelledSegment(start: word.start, end: word.end,
                                              speaker: who, text: word.word)
                } else {
                    current!.end = word.end
                    current!.text += word.word
                }
            }
            if let c = current { out.append(c) }
        }
        for i in out.indices {
            out[i].text = out[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    // MARK: - Relabelling

    /// Tag a diarizer's labels with the track they came from.
    ///
    /// Two tracks are clustered now rather than one, and each run numbers its
    /// speakers from scratch: speaker 1 on the system track and speaker 1 on the
    /// microphone are different people wearing the same name. Tagging keeps them
    /// apart until `relabel` gives the whole meeting one alphabet, in the order
    /// people first speak, which is the order a reader expects and is not the
    /// order either track alone produces.
    ///
    /// These strings never reach disk. They exist between the diarizer and
    /// `relabel`, and they are readable rather than opaque because they show up
    /// in `LISTEN_DEBUG` traces in between.
    static func namespaced(_ turns: [SpeakerTurn], _ track: String) -> [SpeakerTurn] {
        turns.map {
            SpeakerTurn(start: $0.start, end: $0.end, label: namespaced($0.label, track))
        }
    }

    static func namespaced<T>(_ values: [String: T], _ track: String) -> [String: T] {
        var out: [String: T] = [:]
        for (label, value) in values { out[namespaced(label, track)] = value }
        return out
    }

    static func namespaced(_ label: String, _ track: String) -> String {
        track + ":" + label
    }

    /// A, B, C... in order of first appearance.
    ///
    /// The diarizer's own labels are arbitrary and not stable between runs, so
    /// they are never shown. Returns the mapping as well as applying it, because
    /// that mapping is what carries the voiceprints over to the letters the
    /// transcript uses.
    ///
    /// `keeping` is for labels the pipeline already knows the meaning of, which
    /// today is `Me` and nothing else. It maps to itself rather than being
    /// skipped, so a caller can remap voiceprints through the result without
    /// having to know which labels were spared, and it consumes no letter: with
    /// the user first to speak, the first person after them is still A.
    @discardableResult
    static func relabel(_ segments: inout [LabelledSegment],
                        keeping: Set<String> = []) -> [String: String] {
        var mapping: [String: String] = [:]
        var letters = 0
        for i in segments.indices {
            let raw = segments[i].speaker
            if mapping[raw] == nil {
                if keeping.contains(raw) {
                    mapping[raw] = raw
                } else {
                    mapping[raw] = letter(letters)
                    letters += 1
                }
            }
            segments[i].speaker = mapping[raw]!
        }
        return mapping
    }

    /// A...Z, then AA, AB. Spreadsheet columns.
    static func letter(_ index: Int) -> String {
        var n = index + 1
        var out = ""
        while n > 0 {
            let r = (n - 1) % 26
            out = String(UnicodeScalar(UInt8(65 + r))) + out
            n = (n - 1) / 26
        }
        return out
    }

    // MARK: - Cleanup

    /// Collapse a word repeated `threshold` times or more down to one.
    ///
    /// This exists because Whisper falls into repetition loops ("funding
    /// funding funding..."). **Parakeet largely does not**, so this is ported
    /// and measured rather than assumed: `Pipeline` counts how often it fires
    /// and `LISTEN_DEBUG=1` reports it. If it never fires on Parakeet output,
    /// delete it and say so.
    ///
    /// Four, not two: ordinary speech repeats a word twice or three times
    /// often enough ("no no no") that a lower threshold edits real transcript.
    static func collapseRepeats(_ text: String, threshold: Int = 4) -> String {
        let words = text.split(separator: " ").map(String.init)
        guard words.count >= threshold else { return text }

        func norm(_ w: String) -> String {
            w.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'")).lowercased()
        }

        var result: [String] = []
        var i = 0
        while i < words.count {
            var run = i + 1
            while run < words.count, !norm(words[i]).isEmpty,
                  norm(words[run]) == norm(words[i]) { run += 1 }
            if run - i >= threshold { result.append(words[i]) }
            else { result.append(contentsOf: words[i..<run]) }
            i = run
        }
        return result.joined(separator: " ")
    }

    /// Drop empty and impossible rows, and collapse cross-segment loops.
    ///
    /// Returns the cleaned segments and how many times each rule fired, so the
    /// question "does Parakeet need this at all" is answerable with numbers
    /// rather than an opinion.
    static func clean(_ segments: [LabelledSegment]) -> ([LabelledSegment], [String: Int]) {
        var fired: [String: Int] = [:]
        var cleaned: [LabelledSegment] = []

        for segment in segments {
            let original = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = collapseRepeats(original)
            if text != original { fired["collapsed_repeats", default: 0] += 1 }
            if text.isEmpty { fired["empty", default: 0] += 1; continue }
            // One word stretched over more than four seconds is a collapsed
            // repetition loop or an alignment artifact, not speech. Nobody says
            // a single word that slowly.
            if text.split(separator: " ").count == 1, segment.end - segment.start > 4 {
                fired["slow_single_word", default: 0] += 1
                continue
            }
            var kept = segment
            kept.text = text
            cleaned.append(kept)
        }

        // A run of four or more identical (speaker, text) segments is a
        // cross-segment loop, "Yeah." ten times over. Collapse to one spanning
        // the whole run.
        var merged: [LabelledSegment] = []
        var i = 0
        func key(_ s: LabelledSegment) -> String {
            s.speaker + "\u{1}" + s.text
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;: "))
                .lowercased()
        }
        while i < cleaned.count {
            var run = i + 1
            while run < cleaned.count, key(cleaned[run]) == key(cleaned[i]) { run += 1 }
            if run - i >= 4 {
                fired["collapsed_segment_run", default: 0] += 1
                var collapsed = cleaned[i]
                collapsed.end = cleaned[run - 1].end
                merged.append(collapsed)
            } else {
                merged.append(contentsOf: cleaned[i..<run])
            }
            i = run
        }
        return (merged, fired)
    }

    // MARK: - Turns

    /// One ASR sentence, and where its text sits inside its turn.
    struct Sentence {
        var start: Double
        var end: Double
        /// A UTF-16 range into the turn's text, which is what AppKit wants.
        var range: NSRange
        /// Which stored segment this is, as an index into the array passed to
        /// `sentences(in:from:)`.
        ///
        /// This is what makes a sentence editable. A turn is a fold over
        /// segments and nothing records the reverse, so without the index an
        /// edit made on screen could only be written back to `turns.json`, which
        /// `TranscriptEditor` rebuilds from the segments on the next speaker
        /// change. The correction would survive until somebody renamed a
        /// speaker and then vanish, with nothing to explain it.
        var index: Int
    }

    /// Find each sentence inside the turn that contains it.
    ///
    /// This is what makes the playhead readable inside a paragraph. A turn is a
    /// whole stretch of one person talking and can run for minutes; highlighting
    /// the turn says who is speaking but not where in it you are.
    ///
    /// Sentences, not words, because that is the finest timing the ASR exposes
    /// (see CLAUDE.md). If word timings ever arrive this is the function that
    /// gets a finer input, not a different design.
    ///
    /// The ranges are found by searching the turn text rather than rebuilt from
    /// the segments, so a `turns.json` that was assembled by something else,
    /// which is the case for every imported recording, still lines up. A
    /// sentence whose text is not found is skipped: the turn-level highlight
    /// still works, and a wrong range would highlight the wrong words while
    /// looking entirely deliberate.
    static func sentences(in turns: [Turn], from segments: [LabelledSegment]) -> [[Sentence]] {
        var out = [[Sentence]](repeating: [], count: turns.count)
        var index = 0
        for (t, turn) in turns.enumerated() {
            let text = turn.text as NSString
            var cursor = 0
            while index < segments.count {
                let segment = segments[index]
                // A segment ending before this turn began belongs to an earlier
                // turn or to none. Skipping rather than stopping is what keeps
                // one unplaceable segment from silently ending the highlight
                // for the rest of the recording.
                if segment.end < turn.start - 0.001 { index += 1; continue }
                guard segment.speaker == turn.speaker,
                      segment.start <= turn.end + 0.001 else { break }
                // Taken before the cursor moves on. This is the number an edit
                // is written back to, so it has to be this segment's own and not
                // the next one's.
                let position = index
                index += 1

                let body = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !body.isEmpty, cursor < text.length else { continue }
                let rest = NSRange(location: cursor, length: text.length - cursor)
                let found = text.range(of: body, options: [.literal], range: rest)
                guard found.location != NSNotFound else { continue }
                out[t].append(Sentence(start: segment.start, end: segment.end,
                                       range: found, index: position))
                cursor = found.location + found.length
            }
        }
        return out
    }

    /// How long a silence ends a paragraph, even when the same person carries on.
    ///
    /// **Measured over the 61 transcripts in the development library**, on the
    /// 14037 pairs of consecutive segments by one speaker:
    ///
    ///     p50 0.00s   p75 0.60s   p90 1.54s   p95 2.60s
    ///     p98 5.52s   p99 11.84s  p99.9 79.52s  max 188.08s
    ///
    /// Ten sits above the 98th percentile and below the 99th, so ordinary speech
    /// with its breaths and its thinking pauses stays in one paragraph, and the
    /// 1.18% of pairs that are further apart than this are somebody having been
    /// away for a while. Lower and a normal answer breaks in half; higher and the
    /// case below stops being caught at all.
    static let paragraphGap: Double = 10

    /// Condense consecutive segments by the same speaker into one turn.
    ///
    /// This is the LLM-friendly view and what the MCP server serves: a
    /// paragraph per speaker rather than a row per sentence.
    ///
    /// **A long silence ends the paragraph too, and that is not cosmetic.** A
    /// turn claims the whole span from its first segment's start to its last
    /// one's end, so joining across a gap produces a paragraph that says it
    /// covers time nobody was speaking in, with one timestamp for all of it.
    /// Discarding a speaker is where this showed: on a two-person call, removing
    /// one of them made the other's segments adjacent, and sixteen turns became
    /// **one** running the length of the recording. Nothing was lost, every word
    /// was still there, and it read exactly like the transcript having been
    /// destroyed. See `paragraphGap` for the number.
    static func turns(from segments: [LabelledSegment]) -> [Turn] {
        var out: [Turn] = []
        for segment in segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Overlaps come out negative here, which is smaller than the gap and
            // joins, as it should: two segments that overlap are one stretch of
            // speech the diarizer cut in the middle.
            if var last = out.last, last.speaker == segment.speaker,
               segment.start - last.end <= paragraphGap {
                last.text = (last.text + " " + text).trimmingCharacters(in: .whitespaces)
                last.end = max(last.end, segment.end)
                out[out.count - 1] = last
            } else {
                out.append(Turn(start: segment.start, end: segment.end,
                                speaker: segment.speaker, text: text))
            }
        }
        return out
    }
}
