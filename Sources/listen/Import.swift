import AVFoundation
import Foundation

/// Importing the library the Python pipeline built.
///
/// `meet_transcriptions` stores each recording as a folder with `audio.m4a`, a
/// `metadata.json`, and, once transcribed, three sidecars named
/// `<id>.local.raw.json`, `.turns.json` and `.embeddings.json`. The formats
/// overlap with Listen's by design, so most of this is renaming rather than
/// converting.
///
/// **The voiceprints are deliberately not imported, and that is the whole
/// subtlety here.** They come from pyannote; Listen's come from FluidAudio.
/// Both are 256-dimensional, so mixing them raises no error anywhere: cosine
/// similarity between a vector from one model and a vector from the other is
/// simply a meaningless number between -1 and 1, and it would flow straight
/// into the "sounds like" ranking as a confident-looking suggestion. Two
/// different spaces with the same dimension is the worst case, because nothing
/// catches it.
///
/// What *is* worth importing is the naming: 25 of the 55 speaker slots in the
/// legacy library have a human-supplied name on them, and that is the part
/// nobody wants to redo. So the names are applied to the transcript, and
/// `listen enroll` re-derives real FluidAudio voiceprints from the audio and
/// attaches those names to them.
enum LegacyImport {

    struct Candidate {
        var id: String
        var folder: URL
        var title: String
        var recordedAt: String
        var duration: Double
        /// The single mixed track the legacy recorder produced.
        var audio: URL
        var segments: [LabelledSegment]
        var turns: [Turn]
        /// Legacy speaker letter to human name, where one was given.
        var names: [String: String]

        var hasTranscript: Bool { !turns.isEmpty }
        var namedCount: Int { names.count }
    }

    /// Find everything importable under a `meet_transcriptions` checkout.
    ///
    /// Looks in `recordings/processed` first, then `recordings` itself for the
    /// ones that were captured but never transcribed. Those come in with no
    /// transcript and are picked up by the queue like any other pending
    /// recording, which is the point: the new pipeline can finish what the old
    /// one never got to.
    static func scan(_ root: URL) -> [Candidate] {
        let fm = FileManager.default
        let recordings = root.lastPathComponent == "recordings"
            ? root : root.appendingPathComponent("recordings")
        guard fm.fileExists(atPath: recordings.path) else { return [] }

        var found: [String: Candidate] = [:]
        for directory in [recordings.appendingPathComponent("processed"), recordings] {
            guard let entries = try? fm.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil) else { continue }
            for entry in entries {
                guard entry.hasDirectoryPath, entry.lastPathComponent != "processed",
                      let candidate = read(entry) else { continue }
                // A recording present in both places is the processed copy,
                // which is scanned first and has the transcript. Do not let the
                // bare one overwrite it.
                if let existing = found[candidate.id], existing.hasTranscript { continue }
                found[candidate.id] = candidate
            }
        }
        return found.values.sorted { $0.id > $1.id }
    }

    private static func read(_ folder: URL) -> Candidate? {
        let fm = FileManager.default
        let id = folder.lastPathComponent
        // The legacy id format is already Listen's: yyyy-MM-dd-HHmmss-XXXX.
        guard id.count >= 20, id.first?.isNumber == true else { return nil }

        let audio = [ "audio.m4a", "audio.mixed.m4a" ]
            .map(folder.appendingPathComponent)
            .first { fm.fileExists(atPath: $0.path) }
        guard let audio else { return nil }

        var title = id
        var recordedAt = ""
        if let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Verbatim. Some are real titles ("Catchup with Mauro") and some
            // are only the app that was making noise ("Google Chrome").
            // Inventing a replacement would destroy the good ones to tidy the
            // useless ones, and renaming is a click now.
            title = meta["title"] as? String ?? id
            recordedAt = meta["createdAt"] as? String ?? ""
        }

        var names: [String: String] = [:]
        if let data = try? Data(contentsOf:
                folder.appendingPathComponent("\(id).local.embeddings.json")),
           let bank = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let speakers = bank["speakers"] as? [[String: Any]] {
            for speaker in speakers {
                guard let label = speaker["label"] as? String,
                      let name = speaker["name"] as? String, !name.isEmpty else { continue }
                names[label] = name
            }
        }

        var duration: Double = 0
        var turns: [Turn] = []
        if let data = try? Data(contentsOf:
                folder.appendingPathComponent("\(id).local.turns.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            duration = object["duration"] as? Double ?? 0
            for raw in object["turns"] as? [[String: Any]] ?? [] {
                guard let start = raw["start"] as? Double,
                      let end = raw["end"] as? Double,
                      let text = raw["text"] as? String else { continue }
                let speaker = raw["speaker"] as? String ?? "unknown"
                turns.append(Turn(start: start, end: end,
                                  speaker: names[speaker] ?? speaker, text: text))
            }
        }

        var segments: [LabelledSegment] = []
        if let data = try? Data(contentsOf:
                folder.appendingPathComponent("\(id).local.raw.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            duration = (object["duration"] as? Double) ?? duration
            for raw in object["segments"] as? [[String: Any]] ?? [] {
                guard let start = raw["start"] as? Double,
                      let end = raw["end"] as? Double,
                      let text = raw["text"] as? String else { continue }
                let speaker = raw["speaker"] as? String ?? "unknown"
                segments.append(LabelledSegment(start: start, end: end,
                                                speaker: names[speaker] ?? speaker,
                                                text: text))
            }
        }
        // A transcript with turns but no raw segments still imports; the turns
        // are what the UI and the MCP server read.
        if segments.isEmpty, !turns.isEmpty {
            segments = turns.map {
                LabelledSegment(start: $0.start, end: $0.end,
                                speaker: $0.speaker, text: $0.text)
            }
        }

        if recordedAt.isEmpty { recordedAt = Self.dateFromID(id) }

        return Candidate(id: id, folder: folder, title: title, recordedAt: recordedAt,
                         duration: duration, audio: audio, segments: segments,
                         turns: turns, names: names)
    }

    /// The id encodes the time it was recorded, so a missing `createdAt` is
    /// recoverable rather than fatal.
    private static func dateFromID(_ id: String) -> String {
        let parts = id.split(separator: "-")
        guard parts.count >= 4 else { return Metadata.iso(Date()) }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let stamp = parts[0...3].joined(separator: "-")
        return Metadata.iso(f.date(from: stamp) ?? Date())
    }

    // MARK: - Importing

    struct Outcome {
        var imported: [String] = []
        var skipped: [String] = []
        var failed: [(String, String)] = []
        var bytes: Int64 = 0
    }

    /// Copy a candidate into the library.
    ///
    /// Copies rather than moves. The legacy app keeps working, which matters
    /// while the port is being checked: an import that is wrong is then a
    /// deletion away from being retried, rather than a restore from backup.
    static func run(_ candidates: [Candidate], dryRun: Bool,
                    replace: Bool = false) async throws -> Outcome {
        var outcome = Outcome()
        try Library.prepare()

        for candidate in candidates {
            let destination = Library.recordings.appendingPathComponent(candidate.id)
            if FileManager.default.fileExists(atPath: destination.path) {
                guard replace else {
                    outcome.skipped.append(candidate.id)
                    continue
                }
                try? FileManager.default.removeItem(at: destination)
            }
            let size = (try? FileManager.default.attributesOfItem(
                atPath: candidate.audio.path)[.size] as? Int64) ?? 0
            outcome.bytes += size ?? 0
            if dryRun {
                outcome.imported.append(candidate.id)
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: destination, withIntermediateDirectories: true)

                var recording = Recording(
                    folder: destination,
                    metadata: Metadata(
                        id: candidate.id,
                        title: candidate.title,
                        recorded_at: candidate.recordedAt,
                        duration: candidate.duration,
                        source: "imported",
                        state: Metadata.State.pending.rawValue))
                // The legacy recorder wrote both sides into one file as two
                // tracks: a stereo one for what the Mac was playing and a mono
                // one for the microphone. Split, an imported recording is the
                // same shape as one Listen captured itself, and the two-track
                // pipeline applies to it unchanged. Left unsplit it looks like
                // a single mixdown, and everything that reads it takes only the
                // first track: the diarizer heard exactly one person in an 80
                // minute two-person call and said so without complaining.
                let layout = await AudioExtract.classify(AVURLAsset(url: candidate.audio))
                if let system = layout.system {
                    try await AudioExtract.extract(track: system, from: candidate.audio,
                                                   to: recording.systemURL)
                }
                if let mic = layout.mic {
                    try await AudioExtract.extract(track: mic, from: candidate.audio,
                                                   to: recording.micURL)
                }
                if layout.system == nil, layout.mic == nil {
                    // One track only: a mixdown, and honest to keep as one.
                    try FileManager.default.copyItem(at: candidate.audio,
                                                     to: recording.mixURL)
                }

                if candidate.hasTranscript {
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let transcript = StoredTranscript(
                        segments: candidate.segments,
                        duration: candidate.duration,
                        // Named for what actually produced it. A transcript
                        // that claims to be Parakeet's when it is Whisper's
                        // would make any later comparison meaningless.
                        model: "imported: mlx-whisper + pyannote",
                        wordLevel: false,
                        cleanup: [:])
                    try enc.encode(transcript).write(to: recording.transcriptURL,
                                                     options: .atomic)
                    try enc.encode(candidate.turns).write(to: recording.turnsURL,
                                                          options: .atomic)

                    let unnamed = Set(candidate.turns.map(\.speaker))
                        .filter(VoiceBank.isPlaceholder)
                    recording.metadata.state = unnamed.isEmpty
                        ? Metadata.State.done.rawValue
                        : Metadata.State.needsLabelling.rawValue
                }

                try recording.save()
                outcome.imported.append(candidate.id)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                outcome.failed.append((candidate.id, error.localizedDescription))
            }
        }
        return outcome
    }
}
