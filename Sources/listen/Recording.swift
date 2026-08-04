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
