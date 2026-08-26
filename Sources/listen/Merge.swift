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

    // MARK: - Crumbs

    /// How little speech a cluster may hold before it stops being a person,
    /// and how small a part of its own track it may be.
    ///
    /// **Both, not either.** The seconds do the work and the share is what
    /// keeps them honest on a short recording: four seconds is a crumb in an
    /// hour and is somebody's whole contribution to a three-minute call, so a
    /// bare seconds cut would fold a real speaker out of the transcript the
    /// moment the meeting was brief.
    ///
    /// Measured over every placeholder speaker in the development library, as
    /// seconds of assigned transcript and as a share of the track:
    ///
    ///     2.0s  0.08%   workshop 1, E     fold
    ///     2.6s  0.10%   Telegram call, B  fold
    ///     6.7s  0.77%   workshop 4, D     keep
    ///     38.1s 1.55%   workshop 1, D     keep
    ///     29.1s 3.34%   workshop 4, A     keep
    ///      ... and nine more from 80.9s / 9.45% upwards
    ///
    /// So the crumbs and the people are separated by a gap from 2.6 to 6.7
    /// seconds, and five sits in the middle of it. 1% sits in the matching gap
    /// in share, 0.10% to 0.77%, and is the looser of the two guards: workshop
    /// 4's D passes it and is kept on seconds alone, which is the direction to
    /// be wrong in.
    ///
    /// The two that fold are three words each. The Telegram call's B was
    /// "Yeah.", "Yeah." and "What were you saying?", spread over 37 minutes,
    /// and it was enough to withhold the recording's title for ever: see
    /// `AutoTitle.fromPeople`, which waits for every speaker to be named, and
    /// .agents/notes/titles.md for why waiting is right when the speaker is a
    /// person.
    static let crumbSeconds: Double = 5
    static let crumbShare: Double = 0.01

    /// Fold a cluster too small to be a person into the voice it most
    /// resembles.
    ///
    /// A diarizer asked to separate voices will occasionally answer with a
    /// third one holding a backchannel: two "Yeah."s and a half-question,
    /// clipped off somebody who is already in the recording. It is not a person
    /// and it costs three things at once. It puts a "Speaker B · 1%" chip on
    /// the meeting, it holds the recording in `needs_labelling` for ever, and
    /// through `AutoTitle.fromPeople` it withholds the title from the two
    /// people who did the talking.
    ///
    /// **Folded, never dropped.** `bleedClusters` deletes, and is right to: the
    /// far end coming back in through the speakers is a duplicate, and the
    /// words are already in the transcript on the other track. A crumb is not a
    /// duplicate. "What were you saying?" was said once, by somebody, and
    /// deleting it loses transcript to tidy up a label.
    ///
    /// **Within a track, never across one.** The labels arriving here are
    /// namespaced by `namespaced(_:_:)`, and that prefix is the one hard fact
    /// about who a cluster can be: a crumb on the system track is a fragment of
    /// somebody on the far end, and folding it into a voice in the room would
    /// say the two were one person. `keeping` is spared for the same reason at
    /// the other end, and it carries `Me`, which is a track rather than a
    /// cluster.
    ///
    /// **Nearest by voice, and by time only when there is no voice to compare.**
    /// The embedding is the principled signal and it is also the one that just
    /// failed, which is why the crumb exists, so it is worth saying what it is
    /// still good for: on the Telegram call the three-word B sat at cosine
    /// 0.088 from Edgar and 0.037 from the microphone, which is weak evidence
    /// pointing the right way rather than none. A crumb the diarizer produced
    /// no embedding for falls back to whoever was talking nearest to it, which
    /// on a backchannel is nearly always the person being agreed with.
    ///
    /// Returns the folds it made, crumb to target, so the caller can move the
    /// voiceprints and the speech totals with them. Empty is the common case.
    @discardableResult
    static func foldCrumbs(_ segments: inout [LabelledSegment],
                           embeddings: [String: [Float]] = [:],
                           keeping: Set<String> = []) -> [String: String] {
        var spoken: [String: Double] = [:]
        var spans: [String: [(start: Double, end: Double)]] = [:]
        for segment in segments {
            let length = max(0, segment.end - segment.start)
            spoken[segment.speaker, default: 0] += length
            spans[segment.speaker, default: []].append((segment.start, segment.end))
        }

        // The track a label came off, which is everything before the colon
        // `namespaced` put there. Labels with no colon share one group rather
        // than each being their own: `runFile` never namespaces anything, and a
        // per-label group would make every share exactly 1 and quietly turn
        // this whole function off for `listen transcribe --diarize`. In the
        // two-track path the only un-namespaced label is `Me`, which `keeping`
        // already bars from folding and which nothing can fold into while it is
        // alone in its group.
        func track(_ label: String) -> String {
            guard let colon = label.firstIndex(of: ":") else { return "" }
            return String(label[..<colon])
        }

        var total: [String: Double] = [:]
        for (label, seconds) in spoken { total[track(label), default: 0] += seconds }

        let crumbs = spoken.filter { label, seconds in
            guard !keeping.contains(label) else { return false }
            guard seconds < crumbSeconds else { return false }
            let whole = total[track(label)] ?? 0
            return whole > 0 && seconds / whole < crumbShare
        }
        guard !crumbs.isEmpty else { return [:] }

        var folds: [String: String] = [:]
        for crumb in crumbs.keys.sorted() {
            // Another crumb is not somewhere to fold to. Two of them on one
            // track stay as they are rather than being merged into each other,
            // which would invent a speaker out of two fragments.
            // Sorted, so a tie breaks the same way twice. Dictionary order is
            // not stable in Swift, and two targets can genuinely tie on the
            // fallback below: a backchannel over crosstalk overlaps both, and
            // both score a gap of zero. Re-transcribing a recording must not
            // hand its sentences to a different person than last time.
            let targets = spoken.keys.filter {
                $0 != crumb && crumbs[$0] == nil && track($0) == track(crumb)
            }.sorted()
            guard !targets.isEmpty else { continue }

            if let mine = embeddings[crumb], !mine.isEmpty {
                let scored = targets.compactMap { label -> (String, Float)? in
                    guard let theirs = embeddings[label], !theirs.isEmpty else { return nil }
                    return (label, VoiceBank.cosine(mine, theirs))
                }
                if let best = scored.max(by: { $0.1 < $1.1 })?.0 {
                    folds[crumb] = best
                    continue
                }
            }
            // No embedding to compare, so whoever was speaking closest to it.
            // Distance from the crumb's own spans to the target's, zero for an
            // overlap, which is what a backchannel over an answer produces.
            let mine = spans[crumb] ?? []
            let nearest = targets.min { a, b in
                gap(mine, spans[a] ?? []) < gap(mine, spans[b] ?? [])
            }
            if let nearest { folds[crumb] = nearest }
        }
        guard !folds.isEmpty else { return [:] }

        for i in segments.indices {
            if let target = folds[segments[i].speaker] { segments[i].speaker = target }
        }
        return folds
    }

    /// The closest either set of spans comes to the other, zero if they touch.
    private static func gap(_ a: [(start: Double, end: Double)],
                            _ b: [(start: Double, end: Double)]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for one in a {
            for other in b {
                let overlap = min(one.end, other.end) - max(one.start, other.start)
                best = min(best, overlap >= 0 ? 0 : -overlap)
            }
        }
        return best
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
        fold(segments).map(\.turn)
    }

    /// The same fold, saying which segments each paragraph is made of.
    ///
    /// `turns(from:)` is for everything that *reads* a transcript. This is for
    /// the one thing that writes to a paragraph, `TranscriptEditor`'s
    /// reassignment at turn scope, and it exists because **a time window does
    /// not name a turn**.
    ///
    /// It looks as though it does. A turn runs from its first segment's start to
    /// its last one's end, so a window in the transcript's own units survives
    /// any renumbering, which is why the reassignment was written that way. What
    /// it does not survive is two turns by one speaker that touch: a turn ends
    /// where its segments stop reaching, the next one begins wherever the
    /// interruption between them left off, and on a two-track recording those
    /// two numbers are routinely the same instant or the wrong way round.
    ///
    /// Measured on a real 1h29m call, moving the paragraph at 88.32-98.40 to a
    /// new name:
    ///
    ///     4  Me  88.32  98.40   It's a 5k monitor. But I'll just ...
    ///     5  Nick 92.40 102.64  Yeah, I guess.
    ///     6  Me  98.40  106.16  It's gonna be better anyway.
    ///
    /// Rows 4 **and** 6 moved, because row 6's segment starts at 98.40 and 98.40
    /// is inside `[88.32, 98.40]`. Nobody had selected row 6, nothing said it had
    /// gone, and the way anyone would fix it is a whole-speaker repair on the
    /// name they had just made.
    ///
    /// So the window is resolved back through the fold that produced it rather
    /// than applied to the segments directly. That keeps the property the window
    /// was chosen for, since a fold over what is on disk now is exactly the
    /// paragraph on screen, and it keeps the other one the note about this made:
    /// a segment `sentences(in:from:)` could not place inside its turn is still
    /// in that turn here, so it moves with the rest instead of being left behind
    /// under the old speaker.
    static func fold(_ segments: [LabelledSegment]) -> [(turn: Turn, segments: [Int])] {
        var out: [(turn: Turn, segments: [Int])] = []
        for (index, segment) in segments.enumerated() {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Overlaps come out negative here, which is smaller than the gap and
            // joins, as it should: two segments that overlap are one stretch of
            // speech the diarizer cut in the middle.
            if var last = out.last?.turn, last.speaker == segment.speaker,
               segment.start - last.end <= paragraphGap {
                last.text = (last.text + " " + text).trimmingCharacters(in: .whitespaces)
                last.end = max(last.end, segment.end)
                out[out.count - 1].turn = last
                out[out.count - 1].segments.append(index)
            } else {
                out.append((Turn(start: segment.start, end: segment.end,
                                 speaker: segment.speaker, text: text), [index]))
            }
        }
        return out
    }
}
