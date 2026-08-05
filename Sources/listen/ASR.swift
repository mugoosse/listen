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

    /// Ten minutes, which is a measured compromise between two real failures.
    ///
    /// mlx-audio corrupts exactly one word at every chunk seam (see CLAUDE.md),
    /// so fewer seams is better. But decoding a whole file in one pass does not
    /// scale: measured on 67 minutes of speech, `chunkDuration: 0` reached
    /// 3.93 GB and died with a Metal `kIOGPUCommandBufferCallbackErrorOutOfMemory`,
    /// while 600 s chunks peaked at 3.28 GB and finished in 36.7 s. Speak's
    /// 120 s would work too, at 33 seams an hour instead of 6.
    ///
    /// So: the largest chunk that has been shown to survive an hour. The real
    /// fix is to cut at silence so no word ever straddles a seam, which would
    /// let this go back up.
    ///
    /// **Except on a small machine, where 3.28 GB is not affordable.** That
    /// figure was measured here, with 128 GB and nothing else running. An 8 GB
    /// M1 Air is the entry Mac of the whole Apple Silicon era and is most of
    /// what anyone still using a laptop from 2020 has; on one of those, 3.28 GB
    /// alongside the browser and the video call the meeting was *in* is the
    /// same Metal OOM that killed the whole-file pass, and it lands an hour in,
    /// after the recording, where it costs the transcript rather than a retry.
    ///
    /// 120 s is not a guess at a safer number: it is Speak's, which has shipped
    /// on 8 GB machines throughout. The trade is real and it is the right way
    /// round. Six seams an hour become 33, so an hour-long meeting carries
    /// about 33 corrupted words instead of 6, and that is worth paying on the
    /// machines whose alternative is no transcript at all. Nothing changes for
    /// a machine with the memory to spare.
    ///
    /// The threshold is 12 GB rather than 8 so that an 8 GB machine is not
    /// decided by whether `physicalMemory` reports slightly under its nominal
    /// size. Nothing ships between 8 and 16.
    static let chunkSeconds: Float =
        Float(ProcessInfo.processInfo.environment["LISTEN_CHUNK"] ?? "")
            ?? (ProcessInfo.processInfo.physicalMemory > 12 << 30 ? 600 : 120)

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

    /// Transcribe a whole file.
    ///
    /// Returns segments with whatever timings the engine exposes. Read the note
    /// on word timings below before building speaker assignment on this.
    func transcribe(_ url: URL) throws -> Transcript {
        guard let model else { throw ASRError.modelUnavailable("model not loaded") }

        let audio: MLXArray
        do {
            (_, audio) = try loadAudioArray(from: url, sampleRate: Int(SAMPLE_RATE))
        } catch {
            throw ASRError.audioUnreadable(url.path, error)
        }

        // Parakeet degrades badly on inputs shorter than about a second, which
        // a clip trimmed to one utterance easily is. Padding with silence is
        // cheaper than a wrong transcript.
        var samples = audio.asArray(Float.self)
        let minimum = Int(SAMPLE_RATE)
        let duration = Double(samples.count) / SAMPLE_RATE
        if samples.count < minimum {
            samples.append(contentsOf: repeatElement(0, count: minimum - samples.count))
        }

        let out = model.generate(
            audio: MLXArray(samples),
            generationParameters: STTGenerateParameters(chunkDuration: Self.chunkSeconds))

        return Transcript(
            text: out.text.trimmingCharacters(in: .whitespacesAndNewlines),
            segments: Self.segments(from: out),
            duration: duration,
            model: loadedRepo ?? "unknown")
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
