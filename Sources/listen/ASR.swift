import Foundation
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioSTT

// ---------------------------------------------------------------------------
// Transcript shapes
// ---------------------------------------------------------------------------

/// One word with its timing.
///
/// The key names are the Python pipeline's (`word`, `start`, `end`) so
/// `transcript.json` stays readable by `render_from_json.py` and the existing
/// dashboard while the port is in progress. Matching costs nothing here and is
/// worth real money during the transition.
struct ASRWord: Codable {
    var word: String
    var start: Double
    var end: Double
}

/// One ASR segment: a sentence as the decoder chose to end it.
///
/// `words` is empty when the engine did not expose word timings. It is not
/// optional-with-a-default because the difference matters: section 4.4 splits a
/// segment where the speaker changes mid-sentence, and that is only possible
/// with the word array. Code that needs it must be able to see it is missing.
struct ASRSegment: Codable {
    var start: Double
    var end: Double
    var text: String
    var words: [ASRWord] = []

    enum CodingKeys: String, CodingKey { case start, end, text, words }

    /// Omit `words` entirely when there are none, matching the Python's
    /// `normalize_local_segments`, which only sets the key when it has content.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(text, forKey: .text)
        if !words.isEmpty { try c.encode(words, forKey: .words) }
    }
}

struct Transcript: Codable {
    var text: String
    var segments: [ASRSegment]
    /// Seconds of audio, from the file rather than from the last segment: a
    /// recording that ends in silence has more of it than the transcript shows.
    var duration: Double
    var model: String

    /// How many pieces the track was cut into. One for anything short enough to
    /// decode in a single pass.
    var chunks: Int = 1

    /// How many of those cuts could not find a pause to land in.
    ///
    /// Zero on ordinary speech. Each one behaves like one of the old fixed-offset
    /// seams, so it is about one corrupted word. Reported rather than assumed to
    /// be zero, because the whole argument for cutting at silence is that this
    /// number is small, and an argument nobody can check is not one.
    var hardCuts: Int = 0

    /// True when every segment carries word timings.
    ///
    /// Checked rather than assumed. See the note in `ASR.transcribe`.
    var hasWordTimings: Bool { !segments.isEmpty && segments.allSatisfy { !$0.words.isEmpty } }
}

// ---------------------------------------------------------------------------
// The engine
// ---------------------------------------------------------------------------

/// Run `body` with anything written to stdout sent to stderr instead.
///
/// mlx-audio prints "Using cached model at: <path>" straight to stdout from
/// `ModelUtils`, with no flag to turn it off, and `STT.loadModel` resolves the
/// model again internally so it lands three times. On the CLI stdout is the
/// transcript, so that is three lines of library chatter in the middle of piped
/// output. The message is worth keeping, just not there.
///
/// Safe here only because loading is serialized by the `ASR` actor and nothing
/// else in the process writes to stdout while it runs. A concurrent writer
/// would have its output redirected too.
func withStdoutOnStderr<T>(_ body: () async throws -> T) async rethrows -> T {
    fflush(stdout)
    let saved = dup(STDOUT_FILENO)
    guard saved >= 0 else { return try await body() }
    dup2(STDERR_FILENO, STDOUT_FILENO)
    defer {
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
    }
    return try await body()
}

enum ASRError: Error, LocalizedError {
    case audioUnreadable(String, Error)
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .audioUnreadable(let path, let underlying):
            return "could not read audio at \(path): \(underlying)"
        case .modelUnavailable(let why):
            return why
        }
    }
}

/// Parakeet through MLX.
///
/// An actor because the model is not safe to drive from two places at once, and
/// because the pipeline runs one job at a time on purpose: the models are GPU
/// and ANE bound, and parallel jobs fight over the same hardware rather than
/// finishing sooner.
actor ASR {
    private var model: (any STTGenerationModel)?
    private var loadedRepo: String?

    /// Two minutes, on every machine.
    ///
    /// This used to be 600 s above 12 GB of memory and 120 s below it, and the
    /// whole reason for the long chunk was that mlx-audio corrupts one word at
    /// every seam, so fewer seams was better. `Chunking` cuts at pauses instead,
    /// where there is no word to corrupt, and once a seam is free the argument
    /// for a long chunk disappears. What is left says short, on three counts:
    ///
    /// **Time.** Decode cost is strongly super-linear in chunk length, which is
    /// the conformer's attention being quadratic in the sequence it sees.
    /// Measured on the same 3643 s track, 600 s against 120 s, interleaved three
    /// times because the machine's load moved the absolute figures around by a
    /// factor of two: 71.5/25.8, 51.6/23.6, 48.6/21.8 seconds. The ratio is
    /// steady where the absolutes are not, and it is **over 2x in favour of the
    /// short chunk**. A quieter earlier run put it at 27.0 against 11.8.
    ///
    /// **Memory.** 600 s peaked at 3.28 GB here, which was affordable on 128 GB
    /// and was exactly the figure that made a second, smaller value necessary
    /// for an 8 GB M1 Air. One value that fits the smallest supported Mac is one
    /// fewer thing that behaves differently on somebody else's machine.
    ///
    /// **Progress.** The chunk is the unit progress is counted in, so an hour is
    /// 30 of them per track rather than 6.
    ///
    /// 120 s is not a guess: it is Speak's, which has shipped on 8 GB machines
    /// throughout. `LISTEN_CHUNK` still overrides it, and still exists for
    /// measurement rather than for users.
    static let chunkSeconds: Float =
        Float(ProcessInfo.processInfo.environment["LISTEN_CHUNK"] ?? "") ?? 120

    /// Load the weights, downloading them first if they are not on disk.
    ///
    /// The download is driven here rather than left to `STT.loadModel` because
    /// that one forwards no progress: left to itself it produces a silent
    /// multi-minute wait with no way to tell it apart from a hang. This writes
    /// into exactly the directory it checks, so the load below finds a
    /// populated cache and never touches the network.
    func load(_ choice: ModelChoice, progress: (@Sendable (String) -> Void)? = nil) async throws {
        if loadedRepo == choice.repo, model != nil { return }
        model = nil                      // drop the old weights before loading
        loadedRepo = nil

        guard let repoID = Repo.ID(rawValue: choice.repo) else {
            throw ASRError.modelUnavailable("not a Hugging Face repo id: \(choice.repo)")
        }

        if !choice.isDownloaded {
            progress?("downloading \(choice.title), \(ModelChoice.humanBytes(choice.approxBytes))"
                      + " into \(ModelChoice.hubRootDisplay)")
        }
        try await withStdoutOnStderr {
            _ = try await ModelUtils.resolveOrDownloadModel(
                client: HubClient(cache: .default),
                cache: .default,
                repoID: repoID,
                requiredExtension: "safetensors",
                // An empty handler, not nil: the library's default one prints a
                // file count to stdout every hundred milliseconds, and stdout is
                // where the transcript goes.
                progressHandler: { _ in })

            progress?("loading \(choice.title)")
            model = try await STT.loadModel(modelRepo: choice.repo)
        }
        loadedRepo = choice.repo
    }

    /// Transcribe a whole file, reporting how far through it is.
    ///
    /// `progress` is called with a fraction of this file, 0 before the first
    /// piece and 1 after the last. It fires once per piece, so on a two minute
    /// chunk an hour-long track reports thirty times.
    ///
    /// **The chunk loop is here rather than in mlx-audio, deliberately.**
    /// `ParakeetModel.generate` will cut a long file up itself, at a fixed
    /// offset with two seconds of overlap, and it returns nothing at all until
    /// the whole file is done. Doing it here buys two things that could not be
    /// had otherwise: the cuts land in pauses, so no word is lost at a seam, and
    /// there is somewhere to report from. Each piece is therefore handed over
    /// with `chunkDuration: 0`, meaning one pass and no chunking of its own.
    ///
    /// Returns segments with whatever timings the engine exposes. Read the note
    /// on word timings below before building speaker assignment on this.
    func transcribe(_ url: URL,
                    progress: (@Sendable (Double) -> Void)? = nil) throws -> Transcript {
        guard let model else { throw ASRError.modelUnavailable("model not loaded") }

        let audio: MLXArray
        do {
            (_, audio) = try loadAudioArray(from: url, sampleRate: Int(SAMPLE_RATE))
        } catch {
            throw ASRError.audioUnreadable(url.path, error)
        }

        let samples = audio.asArray(Float.self)
        let minimum = Int(SAMPLE_RATE)
        let duration = Double(samples.count) / SAMPLE_RATE

        let pieces = Chunking.pieces(samples, rate: Double(SAMPLE_RATE),
                                     chunk: Double(Self.chunkSeconds))

        // Kept as an `MLXArray` so a piece is a view rather than a copy. The
        // obvious form, slicing the Swift array and building an `MLXArray` per
        // piece, copies the whole track out and back again a piece at a time:
        // an hour is 233 MB of float, and mlx-audio's own loop slices the array
        // it was handed for exactly this reason.
        //
        // Parakeet degrades badly on inputs shorter than about a second, which a
        // clip trimmed to one utterance easily is, and padding with silence is
        // cheaper than a wrong transcript. Only ever the whole file: `Chunking`
        // gives a short tail to the piece before it, so a piece can be under a
        // second only when the recording is.
        var flat = audio.ndim == 1 ? audio : audio.reshaped([-1])
        if samples.count < minimum {
            var padded = samples
            padded.append(contentsOf: repeatElement(0, count: minimum - samples.count))
            flat = MLXArray(padded)
        }

        progress?(0)

        var segments: [ASRSegment] = []
        var text: [String] = []
        var hardCuts = 0

        for (index, piece) in pieces.enumerated() {
            let slice = pieces.count == 1 ? flat : flat[piece.start..<piece.end]
            let out = model.generate(
                audio: slice,
                generationParameters: STTGenerateParameters(chunkDuration: 0))

            // Every time in the piece is relative to the piece. The offset is
            // what puts it back on the recording's clock, and it has to reach
            // the words too: they are empty today, and the day mlx-audio exposes
            // them a missed offset here would be an hour-long recording whose
            // word timings are all in the first two minutes.
            let offset = Double(piece.start) / SAMPLE_RATE
            segments += Self.segments(from: out).map { segment in
                var moved = segment
                moved.start += offset
                moved.end += offset
                moved.words = moved.words.map {
                    ASRWord(word: $0.word, start: $0.start + offset, end: $0.end + offset)
                }
                return moved
            }

            let spoken = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !spoken.isEmpty { text.append(spoken) }
            if !piece.quiet { hardCuts += 1 }
            progress?(Double(index + 1) / Double(pieces.count))
        }

        return Transcript(
            text: text.joined(separator: " "),
            segments: segments,
            duration: duration,
            model: loadedRepo ?? "unknown",
            chunks: pieces.count,
            hardCuts: hardCuts)
    }

    /// Pull segments out of `STTOutput`'s untyped dictionaries.
    ///
    /// **Word timings are not available through this API.** The Parakeet
    /// decoder computes them: `NemoAlignedToken` carries `start` and `duration`
    /// per sub-word token, and `NemoAlignedSentence` keeps the token array. But
    /// `NemoAlignedResult.segments`, the only thing that reaches `STTOutput`,
    /// projects each sentence down to `text`, `start` and `end` and drops the
    /// tokens, and the three public entry points on `ParakeetModel` all return
    /// `STTOutput`. So the information exists and is thrown away one layer
    /// below where we can reach it. Confirmed against upstream main, not just
    /// the pinned revision.
    ///
    /// The consequence is section 4.4 step 2: splitting a segment where the
    /// speaker changes mid-sentence needs the word array. This parser therefore
    /// reads a `words` key if one is ever present rather than assuming it is
    /// not, so that exposing it upstream is the only change needed here.
    private static func segments(from out: STTOutput) -> [ASRSegment] {
        (out.segments ?? []).compactMap { raw in
            let text = (raw["text"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = raw["start"] as? Double ?? 0
            let end = raw["end"] as? Double ?? start
            // Zero-duration rows are dropped here rather than in the cleanup
            // pass: a segment with no extent cannot overlap a speaker turn, so
            // it would be assigned arbitrarily.
            guard end > start else { return nil }

            var words: [ASRWord] = []
            for w in raw["words"] as? [[String: Any]] ?? [] {
                guard let t = w["word"] as? String,
                      let s = w["start"] as? Double,
                      let e = w["end"] as? Double else { continue }
                words.append(ASRWord(word: t, start: s, end: e))
            }
            return ASRSegment(start: start, end: end, text: text, words: words)
        }
    }
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

enum TranscriptFormat {
    /// `01:23` under an hour, `1:01:23` over it. Meeting transcripts are read
    /// by someone looking for a moment, so the timestamp is the index.
    static func stamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    /// Markdown, one line per segment with a timestamp.
    ///
    /// Speaker names arrive at milestone 3. Until then every line is unlabelled
    /// rather than labelled with a guess.
    static func markdown(_ t: Transcript) -> String {
        var out = ""
        for s in t.segments {
            out += "**\(stamp(s.start))** \(s.text)\n\n"
        }
        return out.isEmpty ? t.text : out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plain(_ t: Transcript) -> String {
        t.segments.map { "[\(stamp($0.start))] \($0.text)" }.joined(separator: "\n")
    }

    static func json(_ t: Transcript) throws -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(data: try enc.encode(t), encoding: .utf8) ?? "{}"
    }
}
