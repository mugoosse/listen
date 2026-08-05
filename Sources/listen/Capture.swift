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
            title: Metadata.untitled,
            recorded_at: Metadata.iso(now),
            duration: 0,
            source: source,
            state: Metadata.State.unconfirmed.rawValue))
        try recording.save()

        // Named from the calendar here rather than only at the end, so the row
        // that appears in the sidebar the moment Record is pressed carries the
        // meeting's name for the hour it is running rather than saying
        // "Untitled" throughout. The measurement supports doing it this early:
        // every offset observed in the real library was between -9 and +0
        // minutes, so the event is already in EventKit when capture begins.
        if let named = MeetingCalendar.attachIfEnabled(to: recording) { recording = named }

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
        guard let started = current else { return nil }
        // Re-read the metadata rather than saving the copy taken at `start`.
        // The recording is listed and selectable while it runs, so its title
        // may have been changed since, and writing an hour-old copy back over
        // it would silently undo the rename at the moment capture stops.
        var recording = Recording.load(started.folder) ?? started
        // Read the durations *before* stopping. Both recorders close and
        // release their writer in `stop()`, and the duration comes from the
        // writer, so asking afterwards records every meeting as zero seconds
        // long.
        let captured = max(mic.duration, system.duration)
        mic.stop()
        system.stop()

        // The length has to be written before the second attempt below, not
        // after it. `MeetingCalendar.candidates` matches a meeting that began
        // while the recording ran, and the recording's span is exactly this
        // number: attaching first would judge a 33 minute recording as though
        // it had lasted an instant, which is the case the rule was added for.
        recording.metadata.duration = captured

        // A second attempt, for the meeting that was put in the calendar after
        // it had already started, and for the one that was joined early enough
        // that the first attempt was still ten minutes short of it. `attach`
        // is a no-op once `calendar_event_id` is set, so a recording matched at
        // the start is left alone here and a title edited during the call
        // survives.
        if let named = MeetingCalendar.attachIfEnabled(to: recording) { recording = named }

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
}

extension CaptureError {
    static func nothingToRecord(_ warnings: [String]) -> NSError {
        NSError(domain: "Listen", code: 2, userInfo: [
            NSLocalizedDescriptionKey:
                "could not start either track. " + warnings.joined(separator: "; "),
        ])
    }
}
