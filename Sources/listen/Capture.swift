import AppKit
import Foundation

/// Drives both tracks and owns the recording folder.
///
/// The rule this whole class exists to enforce is SPEC constraint 6: never lose
/// a recording. Concretely that means capture starts writing to disk
/// immediately, both tracks are independent so one failing does not take the
/// other with it, and stopping is idempotent.
@MainActor
final class Capture {
    static let shared = Capture()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    private(set) var current: Recording?
    private(set) var startedAt: Date?

    /// Set when a track failed to start, so the UI can say which one rather
    /// than pretending the recording is whole.
    private(set) var warnings: [String] = []

    var isRecording: Bool { current != nil }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    /// Fires whenever state changes, so the menu bar and the indicator can
    /// follow without polling.
    var onChange: (() -> Void)?

    // -----------------------------------------------------------------------

    /// Begin capturing. Writes into staging from the first second.
    ///
    /// Deliberately does **not** ask permission first or wait for a confirm.
    /// A recording that starts when the user presses Keep has already lost the
    /// first minute of the meeting, and that minute is where people say who
    /// they are.
    @discardableResult
    func start(source: String = "manual") throws -> Recording {
        if let current { return current }
        try Library.prepare()

        let now = Date()
        let id = Metadata.makeID(now)
        let folder = Library.staging.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var recording = Recording(folder: folder, metadata: Metadata(
            id: id,
            title: Self.defaultTitle(now),
            recorded_at: Metadata.iso(now),
            duration: 0,
            source: source,
            state: Metadata.State.unconfirmed.rawValue))
        try recording.save()

        warnings = []

        // Each track starts on its own. A Mac with no working microphone should
        // still capture the meeting, and a machine where the tap is refused
        // should still capture the user, because half a recording is worth
        // enormously more than none.
        do {
            try mic.start(writingTo: recording.micURL)
        } catch {
            warnings.append("microphone: \(error.localizedDescription)")
            log("mic capture failed: \(error.localizedDescription)")
        }
        do {
            try system.start(writingTo: recording.systemURL)
        } catch {
            warnings.append("system audio: \(error.localizedDescription)")
            log("system capture failed: \(error.localizedDescription)")
        }

        guard mic.isRecording || system.isRecording else {
            try? FileManager.default.removeItem(at: folder)
            throw CaptureError.nothingToRecord(warnings)
        }

        current = recording
        startedAt = now
        trace("capture started \(id), mic=\(mic.isRecording) system=\(system.isRecording)")
        onChange?()
        return recording
    }

    /// Stop both tracks and finalise the folder. The recording stays in staging
    /// until it is confirmed.
    @discardableResult
    func stop() -> Recording? {
        guard var recording = current else { return nil }
        // Read the durations *before* stopping. Both recorders close and
        // release their writer in `stop()`, and the duration comes from the
        // writer, so asking afterwards records every meeting as zero seconds
        // long.
        let captured = max(mic.duration, system.duration)
        mic.stop()
        system.stop()

        recording.metadata.duration = captured
        try? recording.save()

        current = nil
        startedAt = nil
        trace("capture stopped \(recording.id), \(Int(recording.metadata.duration))s")
        onChange?()
        return recording
    }

    /// Keep: promote into the library so it appears in the sidebar.
    @discardableResult
    func keep(_ recording: Recording) throws -> Recording {
        var r = recording
        try r.promote()
        trace("kept \(r.id)")
        onChange?()
        return r
    }

    /// Discard: delete the audio.
    func discard(_ recording: Recording) throws {
        try recording.delete()
        trace("discarded \(recording.id)")
        onChange?()
    }

    private static func defaultTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Recording, " + f.string(from: date)
    }
}

extension CaptureError {
    static func nothingToRecord(_ warnings: [String]) -> NSError {
        NSError(domain: "Listen", code: 2, userInfo: [
            NSLocalizedDescriptionKey:
                "could not start either track. " + warnings.joined(separator: "; "),
        ])
    }
}
