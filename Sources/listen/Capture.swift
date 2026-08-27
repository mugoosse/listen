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

    /// How many times the microphone had to be rebuilt mid-recording, because
    /// the device changed underneath it. Zero for almost every meeting, and the
    /// only evidence that anything happened when it is not: the gap is padded
    /// with silence, so the finished file looks exactly like somebody not
    /// talking. See `MicRecorder.restart`.
    var micInterruptions: Int { mic.restarts }

    /// Which of the two tracks a level belongs to.
    ///
    /// Named for whose voice it is rather than for the API that captured it. The
    /// question anybody looks at a meter to answer is "is my voice going in",
    /// and "microphone" is one translation step away from that.
    enum Track { case you, them }

    /// Who wants the levels, keyed by owner so a view can unsubscribe the moment
    /// it goes off screen.
    ///
    /// More than one subscriber at a time is the ordinary case rather than the
    /// exception: the recording screen and the floating panel draw the same two
    /// tracks and neither is guaranteed to be on screen, so a single `onLevel`
    /// property would have them overwriting each other. Unsubscribing matters as
    /// much as subscribing, because a 60 Hz redraw of a hidden strip is an hour
    /// of wakeups for something nobody can see.
    private var levelSinks: [ObjectIdentifier: (Track, Float) -> Void] = [:]

    func addLevelSink(_ owner: AnyObject, _ sink: @escaping (Track, Float) -> Void) {
        levelSinks[ObjectIdentifier(owner)] = sink
    }

    func removeLevelSink(_ owner: AnyObject) {
        levelSinks.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// The microphone is open and hearing nothing at all. See
    /// `MicRecorder.checkForSilence` for what that means and why it is not the
    /// same question as "is the file growing".
    ///
    /// Changes are announced through `onChange` rather than a callback of their
    /// own, so everything that already follows capture state picks this up too:
    /// the menu bar, the panel and the recording screen all need it, and it
    /// changes once or twice in an hour.
    private(set) var micIsSilent = false

    /// What the microphone track is actually recording from, and why it is not
    /// the device Settings names. Both nil until capture starts.
    var micDeviceName: String? { mic.deviceName }
    var micDeviceNote: String? { mic.deviceNote }
    var micDeviceUID: String? { mic.currentUID }

    /// Record from this device from now on, mid-meeting. nil follows the system
    /// default again.
    ///
    /// Writes the setting *and* moves the running recording onto it. Writing only
    /// the setting would take effect on the next restart, which on a healthy
    /// microphone is never, so a control offered during a call would appear to do
    /// nothing for the rest of the call.
    func switchMicrophone(to uid: String?) {
        Settings.microphoneUID = uid
        guard isRecording else { return }
        mic.adoptChosenDevice()
    }

    /// One sentence about the microphone, or nil when there is nothing to say.
    ///
    /// Shared by the recording screen and the floating panel so the two cannot
    /// describe one state two ways. `short` is the panel's, which has 236 to 460
    /// points to say it in.
    ///
    /// The lid clause is gated on the device actually being the built-in one.
    /// Ungated it claimed "the built-in one is off while the lid is shut" about a
    /// USB microphone that had been unplugged, which is a true sentence about the
    /// wrong device and sends somebody to open a lid that was never the problem.
    func micNotice(short: Bool) -> String? {
        if micIsSilent {
            let name = micDeviceName ?? "Your microphone"
            guard mic.deviceIsBuiltIn, AudioDevices.lidClosed else {
                return short ? "\(name) is not picking anything up"
                             : "\(name) is not picking anything up."
            }
            return short
                ? "\(name) is off while the lid is shut"
                : "\(name) is off while the lid is shut. Open the lid, or pick another microphone."
        }
        guard let note = mic.deviceNote, let device = micDeviceName else { return nil }
        return short ? "Moved to \(device)"
                     : "\(note.prefix(1).uppercased() + note.dropFirst()). Recording from \(device)."
    }

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    private func broadcast(_ track: Track, _ level: Float) {
        for sink in levelSinks.values { sink(track, level) }
    }

    /// Highest level seen on each track, for `listen record`'s summary. A class
    /// because `addLevelSink` keys on an object's identity, and this is the only
    /// subscriber with no view behind it.
    @MainActor
    final class LevelPeaks {
        static let shared = LevelPeaks()
        var you: Float = 0
        var them: Float = 0
    }

    /// Fires whenever state changes, so the menu bar and the indicator can
    /// follow without polling.
    var onChange: (() -> Void)?

    // -----------------------------------------------------------------------
    // Dictating while a meeting is being recorded
    // -----------------------------------------------------------------------

    /// Listen in on the microphone track a running recording is already
    /// capturing. Returns false when there is no recording to listen in on, or
    /// when the microphone track failed to start.
    ///
    /// A dictation started while a meeting is running cannot open its own
    /// capture unit: the device is held, and a second claim on it is refused or
    /// renegotiated rather than shared. See `MicRecorder.onSamples`.
    ///
    /// Deliberately one listener. Two dictations at once is not a state that
    /// exists, and a dictionary of sinks here would be a general mechanism
    /// standing in for a thing that happens once.
    func beginDictationTap(_ sink: @escaping @Sendable ([Float]) -> Void) -> Bool {
        guard isRecording, mic.isRecording else { return false }
        mic.onSamples = sink
        return true
    }

    func endDictationTap() {
        mic.onSamples = nil
    }

    // -----------------------------------------------------------------------

    /// Begin capturing. Writes into staging from the first second.
    ///
    /// Deliberately does **not** ask permission first or wait for a confirm.
    /// A recording that starts when the user presses Keep has already lost the
    /// first minute of the meeting, and that minute is where people say who
    /// they are.
    @discardableResult
    func start(source: String = "manual", app: String? = nil) throws -> Recording {
        if let current { return current }
        try Library.prepare()

        let now = Date()
        let id = Metadata.makeID(now)
        let folder = Library.staging.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // Which app the call is in. Detection hands it over when it started
        // this recording; every other way in has to ask, and asking walks the
        // whole audio process list. That is why the detector's own poll runs
        // off the main actor, but this is one read at the moment somebody
        // pressed Record rather than one every three seconds for an hour.
        //
        // Empty for anybody who presses Record before joining, which is why
        // `noteApp` exists.
        let bundleID = app ?? MeetingDetector.activeCallers().first

        var recording = Recording(folder: folder, metadata: Metadata(
            id: id,
            title: Metadata.untitled,
            recorded_at: Metadata.iso(now),
            duration: 0,
            source: source,
            state: Metadata.State.unconfirmed.rawValue,
            app_bundle_id: bundleID,
            // `installedName` rather than `display`: the fallback in `display`
            // is the identifier itself, and storing that would leave a name
            // field holding `com.google.Chrome` for ever, which reads as a name
            // everywhere it is printed.
            app_name: bundleID.flatMap(AppNames.installedName)))
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
        // One instant both tracks call zero, taken here rather than inside each
        // recorder. They start seconds apart (the system track has an aggregate
        // device to wait for) and each pads its own head up to this, because two
        // files that measure from their own first sample do not line up and
        // nothing downstream can tell.
        let origin = Date()

        // Levels off the capture threads and onto the main actor *in order*.
        // `DispatchQueue.main.async` and never `Task {}`: a strip is a queue, so
        // a reordered sample is a bar drawn in the wrong place, and independent
        // Tasks have no ordering guarantee. Speak's `installHotkey` has the same
        // trap written up beside it, where losing the order truncated a chord.
        micIsSilent = false
        mic.onLevel = { [weak self] level in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.broadcast(.you, level) } }
        }
        system.onLevel = { [weak self] level in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.broadcast(.them, level) } }
        }
        mic.onSilenceChange = { [weak self] silent in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.micIsSilent = silent
                    // The menu bar too, not only whichever window happens to be
                    // open. This is the one warning worth interrupting somebody
                    // mid-meeting for, because it expires: once the call is over
                    // there is nothing left to fix.
                    self.onChange?()
                }
            }
        }

        do {
            try mic.start(writingTo: recording.micURL, from: origin)
        } catch {
            warnings.append("microphone: \(error.localizedDescription)")
            log("mic capture failed: \(error.localizedDescription)")
        }
        do {
            try system.start(writingTo: recording.systemURL, from: origin)
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

    /// Something is on a call while this recording runs, so name it.
    ///
    /// For the meeting joined *after* Record was pressed, which is the ordinary
    /// order for anybody who starts the recorder and then opens the link. It
    /// writes once and never again: the first app seen is the one the recording
    /// is of, and letting a later poll overwrite it would rename the recording
    /// after whatever made noise last.
    func noteApp(_ bundleID: String) {
        guard let started = current, started.appBundleID == nil else { return }
        // Re-read for the reason `stop` does: the recording is listed and its
        // title is editable while it runs, so writing back the copy taken at
        // `start` would undo a rename made during the call.
        guard var recording = Recording.load(started.folder) else { return }
        guard recording.appBundleID == nil else { return }
        recording.metadata.app_bundle_id = bundleID
        recording.metadata.app_name = AppNames.installedName(bundleID)
        try? recording.save()
        current = recording
        trace("capture \(recording.id) is in \(AppNames.display(bundleID))")
        // The sidebar row shows the app's icon, and the row for a recording in
        // progress is already on screen by now.
        onChange?()
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
        let interruptions = micInterruptions
        // Read before stopping, like the durations above, and for a sharper
        // reason: this flag is the only record that will ever exist. Once the
        // audio is on disk, a silent mic track is indistinguishable from a
        // meeting in which the user said nothing, and the transcript that comes
        // out reads exactly like a conversation where the other person did all
        // the talking. That is how an hour of a WhatsApp call was filed as a
        // 99%-one-speaker meeting with nothing anywhere marking it.
        let micHeardNothing = mic.isRecording && !mic.sawAudio
        mic.stop()
        system.stop()
        mic.onLevel = nil
        system.onLevel = nil
        mic.onSilenceChange = nil
        micIsSilent = false

        if interruptions > 0 {
            log("microphone changed \(interruptions) time"
                + (interruptions == 1 ? "" : "s")
                + " during this recording; the gaps are silent in the mic track")
        }

        // The length has to be written before the second attempt below, not
        // after it. `MeetingCalendar.candidates` matches a meeting that began
        // while the recording ran, and the recording's span is exactly this
        // number: attaching first would judge a 33 minute recording as though
        // it had lasted an instant, which is the case the rule was added for.
        recording.metadata.duration = captured
        // `true` or absent, never `false`: every recording made before this
        // field existed has no opinion, and writing `false` onto the ones made
        // after it would claim the check ran on the ones where it did not.
        if micHeardNothing { recording.metadata.mic_silent = true }

        // A second attempt, for the meeting that was put in the calendar after
        // it had already started, and for the one that was joined early enough
        // that the first attempt was still ten minutes short of it. `attach`
        // is a no-op once `calendar_event_id` is set, so a recording matched at
        // the start is left alone here and a title edited during the call
        // survives.
        if let named = MeetingCalendar.attachIfEnabled(to: recording) { recording = named }

        try? recording.save()

        // Counted here because every way a capture ends passes through this
        // point, whatever started it: detection, the record button, the CLI.
        // Imports count themselves in `Import`, and a recording arriving over
        // sync is never counted on this Mac at all; the device that made it
        // already did.
        Telemetry.recordingCompleted(recording)

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
