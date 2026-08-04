import Foundation

/// What a recording folder knows about itself.
///
/// The keys are the Python pipeline's where they overlap (`title`,
/// `recorded_at`, `duration`), so the existing tools keep working against the
/// new app's output during the port.
struct Metadata: Codable {
    var id: String
    var title: String
    var recorded_at: String
    var duration: Double
    var source: String
    var state: String

    enum State: String {
        /// Captured but not confirmed by the user. Lives in `staging/`.
        case unconfirmed
        /// In the library, waiting for the transcription queue.
        case pending
        case transcribing
        /// Transcribed, speakers not yet named.
        case needsLabelling = "needs_labelling"
        case done
        case failed
    }

    var stateValue: State { State(rawValue: state) ?? .pending }

    static func makeID(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        // Four hex characters on the end, as the Python pipeline does, so two
        // recordings started in the same second cannot collide.
        let suffix = String(format: "%04X", Int.random(in: 0...0xFFFF))
        return f.string(from: date) + "-" + suffix
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// One recording on disk.
///
/// There is no database. A recording is a folder, and the files in it are the
/// state: audio with no transcript is pending, a transcript with unnamed
/// speakers needs labelling. That is what makes the pipeline resumable across a
/// quit without a job table, and it means deleting a folder in Finder cannot
/// strand a row anywhere.
struct Recording {
    let folder: URL
    var metadata: Metadata

    var id: String { metadata.id }
    var micURL: URL { folder.appendingPathComponent("mic.wav") }
    var systemURL: URL { folder.appendingPathComponent("system.wav") }
    var mixURL: URL { folder.appendingPathComponent("mix.m4a") }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.json") }
    var turnsURL: URL { folder.appendingPathComponent("turns.json") }
    var embeddingsURL: URL { folder.appendingPathComponent("embeddings.json") }
    var metadataURL: URL { folder.appendingPathComponent("metadata.json") }

    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }

    /// Every track that exists, for whatever wants to read audio.
    var tracks: [URL] {
        [micURL, systemURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    static func load(_ folder: URL) -> Recording? {
        let url = folder.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(Metadata.self, from: data)
        else { return nil }
        return Recording(folder: folder, metadata: meta)
    }

    /// Every recording in the library, newest first.
    static func all() -> [Recording] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Library.recordings, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap(load).sorted { $0.id > $1.id }
    }

    /// Recordings captured but never confirmed.
    static func staged() -> [Recording] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Library.staging, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap(load).sorted { $0.id > $1.id }
    }

    static func find(_ id: String) -> Recording? {
        (all() + staged()).first { $0.id == id }
    }

    /// Move a staged recording into the library.
    ///
    /// A move, not a copy: the audio is never duplicated and never rewritten,
    /// so confirming cannot fail halfway and leave two half-recordings.
    mutating func promote() throws {
        guard folder.deletingLastPathComponent() == Library.staging else { return }
        let destination = Library.recordings.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: Library.recordings, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder, to: destination)
        self = Recording(folder: destination, metadata: metadata)
        metadata.state = Metadata.State.pending.rawValue
        try save()
    }

    /// Record the outcome of a transcription run.
    ///
    /// One derivation, called by both the queue and the CLI. They used to each
    /// have their own idea: `listen transcribe` wrote the transcript and left
    /// `state` alone, so four recordings that had been through a failed run
    /// kept saying "could not transcribe" in the sidebar while their transcript
    /// sat next to them on disk.
    /// The state, reconciled against what is actually on disk.
    ///
    /// `metadata.state` is a cache and the files are the truth, which is the
    /// same principle that lets the queue be rebuilt by listing the library. A
    /// process killed mid-job leaves `transcribing` behind for ever, and an
    /// imported recording arrives saying `pending` whatever happens to it
    /// afterwards, so seven recordings sat in the sidebar claiming to be
    /// waiting or working while their finished transcript lay beside them.
    ///
    /// Deriving it here means no repair pass is needed and a future writer that
    /// forgets to update the field cannot reintroduce the same lie.
    var effectiveState: Metadata.State {
        let stored = metadata.stateValue
        guard hasTranscript else {
            // Staging is the one state the files cannot tell you, because it is
            // about which folder the recording is in rather than what is in it.
            return stored == .unconfirmed ? .unconfirmed : .pending
        }
        switch stored {
        case .pending, .transcribing, .failed:
            return storedTurns.isEmpty ? .done : .needsLabelling
        case .unconfirmed, .needsLabelling, .done:
            return stored
        }
    }

    mutating func markTranscribed(_ transcript: StoredTranscript) {
        // Nothing to label in a recording with no speech in it, so it is
        // finished rather than waiting on somebody.
        metadata.state = transcript.segments.isEmpty
            ? Metadata.State.done.rawValue
            : Metadata.State.needsLabelling.rawValue
        try? save()
    }

    func delete() throws {
        try FileManager.default.removeItem(at: folder)
    }
}

extension Library {
    /// Where a capture lives until the user says to keep it.
    ///
    /// Capture writes here from the first second, before anyone has confirmed
    /// anything. Waiting for a human to press something before recording loses
    /// the first minute of every meeting, every time.
    static var staging: URL { root.appendingPathComponent("staging") }

    static func prepare() throws {
        for dir in [recordings, staging] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Anything unconfirmed and older than this is deleted, which Settings
    /// states plainly rather than hiding.
    static let stagingLifetime: TimeInterval = 24 * 60 * 60

    /// Delete staged recordings nobody ever answered for.
    ///
    /// Returns what was removed, so the caller can say so rather than making
    /// files disappear silently.
    @discardableResult
    static func sweepStaging(now: Date = Date()) -> [String] {
        var removed: [String] = []
        for recording in Recording.staged() {
            guard let created = try? FileManager.default.attributesOfItem(
                atPath: recording.folder.path)[.creationDate] as? Date else { continue }
            if now.timeIntervalSince(created) > stagingLifetime {
                try? recording.delete()
                removed.append(recording.id)
            }
        }
        if !removed.isEmpty { log("swept \(removed.count) unconfirmed recording(s)") }
        return removed
    }
}
