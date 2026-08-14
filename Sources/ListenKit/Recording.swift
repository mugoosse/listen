import Foundation

/// A recording as a folder, which is the whole interface between the two apps.
///
/// Mirrors `Recording` in the Mac app deliberately, including the rule that
/// absent audio is a normal state rather than a broken one. On the Mac the
/// missing-audio case is a second machine; here it is every recording the
/// phone did not make, which is most of them.
public struct Recording: Sendable, Identifiable {
    public let folder: URL
    public var metadata: Metadata

    public var id: String { metadata.id }

    public init(folder: URL, metadata: Metadata) {
        self.folder = folder; self.metadata = metadata
    }

    public var micURL: URL { folder.appendingPathComponent("mic.wav") }
    public var systemURL: URL { folder.appendingPathComponent("system.wav") }
    public var mixURL: URL { folder.appendingPathComponent("mix.m4a") }
    public var flacURL: URL { folder.appendingPathComponent("mic.flac") }
    public var metadataURL: URL { folder.appendingPathComponent("metadata.json") }
    public var transcriptURL: URL { folder.appendingPathComponent("transcript.json") }
    public var turnsURL: URL { folder.appendingPathComponent("turns.json") }
    public var waveformURL: URL { folder.appendingPathComponent("waveform.json") }
    public var embeddingsURL: URL { folder.appendingPathComponent("embeddings.json") }
    public var sourceIconURL: URL { folder.appendingPathComponent(DevicePolicy.sourceIcon) }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public var hasTranscript: Bool { Recording.exists(transcriptURL) }
    public var hasTurns: Bool { Recording.exists(turnsURL) }

    /// Whether any audio for this recording is on **this** device.
    ///
    /// False is ordinary here, not an error. The phone deletes its copy once
    /// the Mac acknowledges receipt, so after a few minutes even a recording
    /// the phone made itself answers false, and the transcript screen has to
    /// say where the audio went rather than appearing broken.
    public var hasAudio: Bool {
        [micURL, systemURL, mixURL, flacURL].contains(where: Recording.exists)
    }

    public var state: Metadata.State {
        metadata.effectiveState(hasTranscript: hasTranscript, hasTurns: hasTurns)
    }

    public var turns: [Turn] {
        guard let data = try? Data(contentsOf: turnsURL),
              let turns = try? JSONDecoder().decode([Turn].self, from: data)
        else { return [] }
        return turns
    }

    public var transcript: StoredTranscript? {
        guard let data = try? Data(contentsOf: transcriptURL) else { return nil }
        return try? JSONDecoder().decode(StoredTranscript.self, from: data)
    }

    /// Every distinct speaker, in the order they first appear.
    public var speakers: [String] {
        var seen = Set<String>(), order: [String] = []
        for turn in turns where !seen.contains(turn.speaker) {
            seen.insert(turn.speaker); order.append(turn.speaker)
        }
        return order
    }

    /// Write `metadata.json` from this struct.
    ///
    /// **Only for a recording this device authored.** Encoding rewrites the
    /// whole file from a struct that deliberately models fewer fields than the
    /// Mac's, so calling this on a recording that came from somewhere else
    /// erases every field this app has not heard of. `patch` is the one to use
    /// for those. See `DevicePolicy` for the rule and why it matters.
    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(metadata).write(to: metadataURL, options: .atomic)
        RecordingEvents.changed?()
    }

    /// Change a field or two in `metadata.json` without rewriting the rest.
    ///
    /// The edit is applied to the JSON object on disk rather than to a decoded
    /// struct, so keys this app does not model survive it. That is not a
    /// hypothetical tidiness: renaming a calendar-matched meeting on the phone
    /// went through `save()` and dropped `calendar_people`, `calendar_event_id`
    /// and `app_name` from the local copy every time.
    ///
    /// The Mac's copy is still the canonical one and still gets a
    /// `MetadataPatch` over the wire. This only keeps the local copy honest in
    /// the meantime, which matters because the local copy is what the next
    /// digest comparison is made against.
    public func patch(_ change: MetadataPatch) throws {
        guard let data = try? Data(contentsOf: metadataURL),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            // No file yet, or not an object. Nothing to preserve, so the
            // struct is as good as it gets.
            var copy = self
            change.apply(to: &copy.metadata)
            return try copy.save()
        }
        if let title = change.title { object["title"] = title }
        if let tags = change.tags { object["tags"] = tags }
        let out = try JSONSerialization.data(withJSONObject: object,
                                             options: [.prettyPrinted, .sortedKeys])
        try out.write(to: metadataURL, options: .atomic)
        RecordingEvents.changed?()
    }

    /// Load, or nil. Nil is the signal that a folder is not a recording yet,
    /// which is exactly what a transfer in progress looks like, so callers
    /// must treat it as ordinary rather than logging it.
    public static func load(_ folder: URL) -> Recording? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("metadata.json")),
              let meta = try? JSONDecoder().decode(Metadata.self, from: data)
        else { return nil }
        return Recording(folder: folder, metadata: meta)
    }
}

/// Told whenever a recording's `metadata.json` is rewritten.
///
/// One hook rather than a call at every mutation site, because there are
/// fourteen of them in the Mac app alone: renaming, auto-titling, tagging,
/// naming a speaker, matching a calendar event, finishing a capture, importing.
/// Sprinkling a sync call across all of those means the next one added quietly
/// does not sync, which is exactly what happened here: a recording titled after
/// its transcript arrived on the phone still called "Untitled", because nothing
/// between the rename and the two minute poll had any reason to speak.
///
/// Deliberately not called by the pull path, which writes `metadata.json`
/// straight to disk rather than through `save`. A hook that fired on arrival
/// would have every device answering every other device's sync for ever.
public enum RecordingEvents {
    /// Set once, by an app that syncs. `nonisolated(unsafe)` because it is
    /// written at launch and only read afterwards.
    public nonisolated(unsafe) static var changed: (@Sendable () -> Void)?
}

/// Writes a recording folder so that it becomes visible atomically.
///
/// **`metadata.json` is written last, and that is the entire concurrency
/// design.** `Recording.load` returns nil without it and `Library.all` is a
/// compactMap over `load`, so a folder that is still arriving is invisible to
/// every reader on both devices: no lock, no in-progress flag, no partial row
/// in a list, and nothing to clean up after a transfer that died halfway.
public struct RecordingWriter {
    public let folder: URL
    private var metadata: Metadata

    public init(folder: URL, metadata: Metadata) throws {
        self.folder = folder
        self.metadata = metadata
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    public func write(_ data: Data, as name: String) throws {
        precondition(name != "metadata.json", "metadata.json is written by finish()")
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    /// Publish the folder. Nothing sees the recording before this returns.
    @discardableResult
    public func finish() throws -> Recording {
        let recording = Recording(folder: folder, metadata: metadata)
        try recording.save()
        return recording
    }
}
