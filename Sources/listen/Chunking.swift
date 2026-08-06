import Accelerate
import Foundation

/// Where to cut a long track so that no word straddles a seam.
///
/// mlx-audio chunks internally at a fixed offset and merges the token sequences
/// on the longest contiguous match, with two seconds of overlap. Measured on 60
/// numbered sentences, that overlap is not enough: exactly one word is corrupted
/// at every seam, and the corrupted segment is short, so what happens is that
/// the tail of the word sitting on the boundary is dropped. An hour at 120 s
/// chunks carries about 30 of them.
///
/// Cutting where nobody is speaking removes the problem instead of mitigating
/// it. There is no word on the boundary to lose, so the pieces need no overlap
/// and their transcripts need no merge, which is also what makes chunk-by-chunk
/// progress possible: the loop is here rather than inside the model, where
/// nothing was reported until the whole file was done.
///
/// Plain RMS rather than the VAD mlx-audio ships. This is not the general
/// speech-versus-noise problem a VAD solves: the search window is ten seconds of
/// a conversation and all that is wanted is the quietest moment in it. A VAD
/// would mean another model to download on first run, which is a poor trade for
/// a boundary that only has to avoid landing inside a word.
enum Chunking {
    /// One piece of a track, in sample indices.
    struct Piece {
        var start: Int
        /// Exclusive.
        var end: Int
        /// Whether the cut that **ends** this piece landed somewhere quiet
        /// enough to be a pause. False means the search found nothing but
        /// speech and fell back to a hard cut, which behaves like one of the old
        /// seams. Counted rather than hidden, for the reason the cleanup and
        /// dictionary counts are: nobody can hear a dropped word in an hour of
        /// audio they are not going to listen to again.
        ///
        /// True on the last piece, which ends at the end of the file and is
        /// therefore not a cut at all.
        var quiet: Bool
    }

    /// 20 ms, which is finer than the window a cut is chosen from and cheap
    /// enough to compute over a whole track in one pass.
    static let frameSeconds = 0.02

    /// How far back from a nominal boundary to look for a pause.
    ///
    /// Backwards only, never forwards, so a piece can never be longer than the
    /// chunk length it was asked for. That is what keeps the memory ceiling the
    /// chunk length was chosen for: 3.28 GB was measured at 600 s, and a rule
    /// that could overshoot would be a rule that occasionally asks for more than
    /// the machine was judged able to give.
    static let searchSeconds = 10.0

    /// The stretch that has to be quiet, not just the instant. A single quiet
    /// sample happens between two syllables.
    static let windowSeconds = 0.2

    /// How far below the track's speech level a window has to sit to count as a
    /// pause. 20 dB, against the 90th percentile frame rather than the mean,
    /// because on a track where one person talks for a fifth of the meeting the
    /// mean is much closer to the room than to the voice.
    static let quietRatio: Float = 0.1

    /// Cut `samples` into pieces of at most `chunk` seconds, preferring pauses.
    ///
    /// Returns one piece covering everything when the track is short enough to
    /// decode in one pass, which is the common case for a dictation-length clip
    /// and the whole of what the CLI usually sees.
    static func pieces(_ samples: [Float], rate: Double, chunk: Double) -> [Piece] {
        let total = samples.count
        let chunkSamples = Int(chunk * rate)
        guard chunk > 0, chunkSamples > 0, total > chunkSamples else {
            return [Piece(start: 0, end: total, quiet: true)]
        }

        let frame = max(1, Int(frameSeconds * rate))
        let frames = total / frame
        guard frames > 2 else { return [Piece(start: 0, end: total, quiet: true)] }

        // One pass for the whole track. Accelerate rather than a Swift loop:
        // an hour of 16 kHz mono is 58 million samples, and this runs before a
        // single chunk has been decoded, where it would read as the model
        // taking a while to start.
        var rms = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for f in 0..<frames {
                vDSP_rmsqv(base + f * frame, 1, &rms[f], vDSP_Length(frame))
            }
        }

        // Prefix sums, so the mean over any window is two lookups rather than a
        // loop. The search is 500 windows per boundary and there are 30 of them
        // in an hour, which is only cheap if each one is O(1).
        var prefix = [Float](repeating: 0, count: frames + 1)
        for f in 0..<frames { prefix[f + 1] = prefix[f] + rms[f] }

        let speech = percentile(rms, 0.9)
        let quietEnough = speech * quietRatio

        let windowFrames = max(1, Int(windowSeconds * rate) / frame)
        let searchFrames = max(windowFrames, Int(searchSeconds * rate) / frame)

        var pieces: [Piece] = []
        var start = 0
        while total - start > chunkSamples {
            let nominal = min(frames - 1, (start + chunkSamples) / frame)
            // Never back past the start of this piece, and always leave a whole
            // window to measure.
            let earliest = min(nominal, (start / frame) + windowFrames)
            let latest = max(earliest, nominal - windowFrames)
            let from = max(earliest, nominal - searchFrames)

            var best = latest
            var quietest = Float.greatestFiniteMagnitude
            if from <= latest {
                for w in from...latest {
                    let mean = (prefix[w + windowFrames] - prefix[w]) / Float(windowFrames)
                    if mean < quietest { quietest = mean; best = w }
                }
            }

            // The middle of the quiet window, so the pause is shared between the
            // piece that ends and the piece that begins rather than one of them
            // getting all of it.
            let cut = min(total, (best + windowFrames / 2) * frame)
            guard cut > start else { break }
            pieces.append(Piece(start: start, end: cut, quiet: quietest <= quietEnough))
            start = cut
        }

        // A tail of a second or two is not worth its own decode: Parakeet
        // degrades badly below about a second, and a piece that short is padded
        // with silence to reach it, so it would be mostly padding. Give it to
        // the piece before instead, which costs that piece a couple of seconds
        // over the chunk length and nothing else.
        let tail = total - start
        if tail < Int(2 * rate), var last = pieces.popLast() {
            last.end = total
            last.quiet = true
            pieces.append(last)
        } else if tail > 0 {
            pieces.append(Piece(start: start, end: total, quiet: true))
        }
        return pieces
    }

    /// The value `fraction` of the way up a sorted copy.
    ///
    /// A percentile rather than a maximum: one clipped sample, or a door
    /// slamming, would otherwise set the level the whole track is judged
    /// against and no window anywhere would look quiet.
    private static func percentile(_ values: [Float], _ fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1,
                        max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}
