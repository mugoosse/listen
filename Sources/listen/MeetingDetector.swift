import AppKit
import CoreAudio

/// Watches for a meeting starting, by asking Core Audio which processes are
/// listening and speaking at the same time.
///
/// The rule is Blackbox's: a process with **both** an input and an output
/// stream running is on a call. Nothing else on a Mac routinely does both at
/// once, and it needs no permission beyond the one the tap already has.
///
/// SPEC 5.3 suggests the other rule, a list of bundle identifiers for Zoom,
/// Meet, Teams and Slack. That is rejected here for the same reason
/// `SystemAudio.createTap` refuses to narrow its process list: a guessed list
/// is wrong the first time somebody joins a call in the fifth thing, and being
/// wrong means no recording, with nothing on screen to explain why. The
/// input-and-output rule over-triggers instead, which is the survivable
/// direction because the skip list makes over-triggering a one-click problem.
@MainActor
final class MeetingDetector {
    static let shared = MeetingDetector()

    /// Reported when a meeting starts, with the bundle identifier that caused
    /// it. Starting the capture is the delegate's job, not this class's: it
    /// already owns the panel and the confirm step, and a detector that also
    /// records would be a second path into `Capture` to keep agreeing with the
    /// first.
    var onMeetingStarted: ((String) -> Void)?
    /// Reported when everything that was on a call has stopped.
    var onMeetingEnded: (() -> Void)?

    private var pollTask: Task<Void, Never>?
    /// True while something is on a call, so the start is reported on the edge
    /// rather than every three seconds.
    private var active = false
    /// Answered "Not now" for this one. Re-arms when it goes quiet, so
    /// declining a call does not decline every later call from the same app.
    private var suppressed: String?
    /// Consecutive polls with nothing on a call. Two are required before a
    /// meeting is called over, because a single poll landing in a gap between
    /// speakers would otherwise end an hour-long recording halfway through.
    private var quietPolls = 0

    /// Poll rather than a property listener.
    ///
    /// `kAudioProcessPropertyIsRunningInput` does support
    /// `AudioObjectAddPropertyListenerBlock`, but only per process object, so
    /// following it means also listening to the process list and adding and
    /// removing listeners as apps launch and quit. Three seconds against a
    /// meeting that runs for an hour is not worth that much moving machinery.
    private static let interval = Duration.seconds(3)

    // -----------------------------------------------------------------------

    /// Begin watching, if the setting is on. Safe to call repeatedly; the
    /// settings pane calls it on every toggle.
    func refresh() {
        if Settings.autoDetectMeetings {
            guard pollTask == nil else { return }
            start()
        } else {
            stop()
        }
    }

    private func start() {
        // Seed the edge state from what is happening right now, so launching
        // during a call does not immediately claim the call just started. The
        // meeting was already running; the user did not do anything.
        active = !Self.activeCallers().isEmpty
        trace("meeting detection on, \(active ? "a call is already running" : "nothing on a call")")

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                if Task.isCancelled { return }
                // Off the main actor: reading the process list walks every
                // audio process and blocks while the HAL answers, and doing
                // that on the main thread every three seconds for an hour is
                // how a recorder makes the rest of the machine feel slow.
                let callers = await Task.detached(priority: .utility) {
                    Self.activeCallers()
                }.value
                self?.evaluate(callers)
            }
        }
    }

    private func stop() {
        pollTask?.cancel()
        pollTask = nil
        active = false
        suppressed = nil
        quietPolls = 0
    }

    /// Stop offering this app until it goes quiet again.
    ///
    /// This is "Not now", and it is deliberately not the same as the skip list.
    /// Without it, declining a call that is still running means being asked
    /// again three seconds later, forever.
    func suppress(_ bundleID: String) {
        suppressed = bundleID
        active = false
        quietPolls = 0
    }

    /// Called when capture ends for any reason, so the next call is detected as
    /// a new one rather than as a continuation of the one that just stopped.
    func captureEnded() {
        active = false
        quietPolls = 0
    }

    // -----------------------------------------------------------------------

    private func evaluate(_ callers: [String]) {
        // Clear the suppression against the unfiltered set, so an app leaving
        // the call really does re-arm it.
        if let s = suppressed, !callers.contains(s) { suppressed = nil }

        let eligible = callers.filter { $0 != suppressed && !Settings.skippedBundleIDs.contains($0) }

        if let first = eligible.first {
            quietPolls = 0
            guard !active else { return }
            active = true
            trace("meeting detected, \(first)")
            onMeetingStarted?(first)
            return
        }

        guard active else { return }
        quietPolls += 1
        guard quietPolls >= 2 else {
            trace("nothing on a call, waiting one more poll")
            return
        }
        active = false
        quietPolls = 0
        trace("meeting ended")
        onMeetingEnded?()
    }

    // -----------------------------------------------------------------------
    // Core Audio
    // -----------------------------------------------------------------------

    /// Bundle identifiers of every process currently running both an input and
    /// an output stream, with helper processes resolved to their parent app.
    ///
    /// `nonisolated` so the poll loop can run it off the main actor.
    nonisolated static func activeCallers() -> [String] {
        let me = ProcessInfo.processInfo.processIdentifier
        var seen: [String] = []
        for process in processObjects() {
            guard flag(process, kAudioProcessPropertyIsRunningInput),
                  flag(process, kAudioProcessPropertyIsRunningOutput)
            else { continue }
            // Listen holds the microphone and the tap while it records, so
            // without this it detects itself and never stops detecting itself.
            guard pid(process) != me else { continue }
            // A process with no bundle identifier cannot be a meeting app, and
            // dropping it here is what keeps daemons out of the prompt. This is
            // the `replayd` case: Apple's ReplayKit daemon opens input and
            // output during any system dictation, and being asked "are you in a
            // meeting?" by a daemon you have never heard of is the failure this
            // whole feature is judged on. There is nothing to skip if it never
            // asks.
            guard let id = bundleID(process) else { continue }
            let parent = parentBundleID(id)
            if !seen.contains(parent) { seen.append(parent) }
        }
        return seen
    }

    /// Every audio process object the HAL knows about.
    private nonisolated static func processObjects() -> [AudioObjectID] {
        var address = SystemAudioRecorder.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let sized = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
        guard sized == noErr else {
            // Said out loud rather than returned as an empty list. An empty
            // list is indistinguishable from "nobody is on a call", so a
            // detector that could never fire would look exactly like one that
            // simply had nothing to report.
            log("could not read the audio process list (\(sized)); meeting detection is off")
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        let read = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
        guard read == noErr else { return [] }
        return ids
    }

    private nonisolated static func flag(_ object: AudioObjectID,
                                         _ selector: AudioObjectPropertySelector) -> Bool {
        var address = SystemAudioRecorder.address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.stride)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    private nonisolated static func pid(_ object: AudioObjectID) -> pid_t? {
        var address = SystemAudioRecorder.address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.stride)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private nonisolated static func bundleID(_ object: AudioObjectID) -> String? {
        var address = SystemAudioRecorder.address(kAudioProcessPropertyBundleID)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        let id = value as String
        return id.isEmpty ? nil : id
    }

    /// `com.google.Chrome.helper.renderer` becomes `com.google.Chrome`.
    ///
    /// Chrome, Electron and Safari all put the audio in a helper process, and
    /// the helper's identifier is both unrecognisable in a prompt and useless
    /// in the skip list: it is per-renderer, so skipping the one you were shown
    /// skips nothing the next time. Blackbox resolves the same way.
    static func parentBundleID(_ id: String) -> String {
        let parts = id.split(separator: ".")
        if let i = parts.firstIndex(of: "helper"), i > 1 {
            return parts[..<i].joined(separator: ".")
        }
        return id
    }
}

// ---------------------------------------------------------------------------

/// Bundle identifiers as people recognise them.
enum AppNames {
    /// "Zoom" rather than "us.zoom.xos".
    ///
    /// Falls back to the identifier rather than to something friendlier when
    /// the app cannot be found, because an uninstalled app in the skip list
    /// still has to be identifiable enough to remove.
    static func display(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
