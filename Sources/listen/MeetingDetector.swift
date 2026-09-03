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

    /// Every poll that finds anything on a call, whether or not a recording is
    /// already running and whether or not the app is skipped.
    ///
    /// This is how a recording started by hand *before* joining learns which
    /// app it is of: `Capture` samples the callers once at `start`, which is
    /// empty for anybody who presses Record and then opens the meeting link,
    /// and this fills it in on the next poll. The skip list is deliberately not
    /// applied: it says which app never to *ask* about, and the app a call is
    /// in is a fact about the recording rather than a question being put.
    var onCallersSeen: (([String]) -> Void)?

    private var pollTask: Task<Void, Never>?
    /// True while something is on a call, so the start is reported on the edge
    /// rather than every three seconds.
    private var active = false
    /// Apps not to offer to record until they leave the call they are on.
    /// Re-arms when one goes quiet, so declining a call does not decline every
    /// later call from the same app.
    ///
    /// A set rather than one identifier, because `captureEnded` puts everything
    /// currently on a call into it and two apps can be on one at once: a Meet
    /// tab in Chrome with Zoom still open behind it suppressed only whichever
    /// of them was listed first.
    private var suppressed: Set<String> = []
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
        suppressed = []
        quietPolls = 0
    }

    /// Stop offering this app until it goes quiet again.
    ///
    /// This is "Not now", and it is deliberately not the same as the skip list.
    /// Without it, declining a call that is still running means being asked
    /// again three seconds later, forever.
    func suppress(_ bundleID: String) {
        suppressed.insert(bundleID)
        active = false
        quietPolls = 0
    }

    /// Called when capture ends for any reason, so the next call is detected as
    /// a new one rather than as a continuation of the one that just stopped.
    ///
    /// **Whatever is on a call at this moment is suppressed**, for the same
    /// reason "Not now" suppresses. Re-arming the edge while the call is still
    /// running means the very call that was just stopped is detected as a new
    /// meeting on the next poll: a second recording starts, the panel asks
    /// about it again, and stopping that one starts a third.
    ///
    /// Measured on 3 September 2026, demonstrating the app during a Google Meet
    /// call: pressing Stop in Listen without leaving the call left a new
    /// recording every three seconds until "No" was pressed, because "No" was
    /// the only route into `suppress`. Stopping by hand says the recording is
    /// over, not that the meeting is, and only the user restarting it or the
    /// call actually ending should start another.
    ///
    /// A meeting that ended on its own suppresses nothing, because by then
    /// nobody is on a call: two quiet polls are what got here.
    ///
    /// Sampling the callers here rather than reusing the last poll's list costs
    /// one walk of the process list on the main thread, which is what
    /// `Capture.start` already pays. The poll is up to three seconds stale, and
    /// three seconds is exactly the window somebody pressing Stop as a call ends
    /// lands in.
    func captureEnded() {
        active = false
        quietPolls = 0
        // Nothing to suppress and nobody to ask, so do not walk the process
        // list for it. This runs on every stop, including with detection
        // turned off, where there is no poll to re-arm.
        guard pollTask != nil else { return }
        let onACall = Self.activeCallers()
        if !onACall.isEmpty {
            suppressed.formUnion(onACall)
            trace("capture ended while \(onACall.joined(separator: ", ")) "
                + "is still on a call; not offering to record it again")
        }
    }

    // -----------------------------------------------------------------------

    private func evaluate(_ callers: [String]) {
        if !callers.isEmpty { onCallersSeen?(callers) }

        // Clear the suppression against the unfiltered set, so an app leaving
        // the call really does re-arm it.
        if !suppressed.isEmpty { suppressed.formIntersection(callers) }

        let eligible = callers.filter {
            !suppressed.contains($0) && !Settings.skippedBundleIDs.contains($0)
        }

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

    /// One audio process, as the detection rule sees it.
    struct Process {
        let bundleID: String?
        let pid: pid_t?
        let input: Bool
        let output: Bool
    }

    /// Every audio process the HAL knows about, unfiltered.
    ///
    /// Unfiltered on purpose: `listen sources` prints this, and a report that
    /// had already dropped everything uninteresting could not answer "why was
    /// my meeting not detected?", which is the only question it exists for.
    nonisolated static func report() -> [Process] {
        processObjects().map {
            Process(bundleID: bundleID($0),
                    pid: pid($0),
                    input: flag($0, kAudioProcessPropertyIsRunningInput),
                    output: flag($0, kAudioProcessPropertyIsRunningOutput))
        }
    }

    /// Listen's own identifier, resolved once.
    ///
    /// `AppInfo` rather than `Bundle.main`, for the reason `Settings` reads it
    /// that way: launched through the installed symlink, `Bundle.main` is
    /// `~/.local/bin` and has no `Info.plist` in it at all.
    private nonisolated static let ownBundleID = AppInfo.bundleID

    /// Bundle identifiers of every process currently running both an input and
    /// an output stream, with helper processes resolved to their parent app.
    ///
    /// `nonisolated` so the poll loop can run it off the main actor.
    nonisolated static func activeCallers() -> [String] {
        if let path = fakeCallers { return fakedCallers(path) }
        let me = ProcessInfo.processInfo.processIdentifier
        var seen: [String] = []
        for process in report() where process.input && process.output {
            // Whatever else is on a call, Listen is not, and that has to be
            // decided by the app rather than by the process.
            //
            // The pid was the whole of this guard and it asks the wrong
            // question: "is this me?" rather than "is this Listen?". Two copies
            // of the app is two pids with one bundle identifier, which is the
            // ordinary state of this machine while the app is being worked on
            // and is reachable by anyone who keeps a second copy anywhere.
            //
            // What makes Listen match its own rule is dictation: the
            // microphone is an input stream and `Cue.start` plays a system
            // sound as it goes live, so a Listen being dictated into runs both
            // at once for about the length of the cue. Capturing a meeting
            // never did, because a process tap is not an output stream on the
            // tapping process, and that measurement is where the comfortable
            // reading of this guard came from.
            //
            // It fired twice on 11 August 2026, over a push-to-talk with no
            // meeting anywhere: the other copy asked "are you in a meeting?"
            // and left two recordings on disk stamped
            // `app_bundle_id: com.mgo.listen`.
            //
            // Both guards stay, because they can fail apart. The identifier is
            // the one that covers a sibling process, and the pid is the one
            // that still holds when `AppInfo` cannot resolve an identifier to
            // compare against, which is every unbundled build.
            guard process.pid != me else { continue }
            // A process with no bundle identifier cannot be a meeting app, and
            // dropping it here is what keeps daemons out of the prompt. This is
            // the `replayd` case: Apple's ReplayKit daemon opens input and
            // output during any system dictation, and being asked "are you in a
            // meeting?" by a daemon you have never heard of is the failure this
            // whole feature is judged on. There is nothing to skip if it never
            // asks.
            guard let id = process.bundleID else { continue }
            let parent = parentBundleID(id)
            guard parent != ownBundleID else { continue }
            if !seen.contains(parent) { seen.append(parent) }
        }
        return seen
    }

    /// A file standing in for the process list, one bundle identifier per line.
    ///
    /// `LISTEN_FAKE_CALLERS=/tmp/callers` makes every read of the callers come
    /// from that file, re-read on each poll, so a call can be joined and left
    /// by writing to it. It is here for the reason `LISTEN_TAP_TEAR` is: the
    /// alternative is holding a real meeting to test a state machine, and the
    /// state machine is the part that has been wrong. `verify_meeting_stop.sh`
    /// is what uses it.
    ///
    /// A missing or empty file is nobody on a call, which is how a meeting ends.
    private nonisolated static let fakeCallers = ProcessInfo.processInfo
        .environment["LISTEN_FAKE_CALLERS"]

    private nonisolated static func fakedCallers(_ path: String) -> [String] {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var seen: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let id = line.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty && !seen.contains(id) { seen.append(id) }
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
    nonisolated static func parentBundleID(_ id: String) -> String {
        let parts = id.split(separator: ".")
        if let i = parts.firstIndex(of: "helper"), i > 1 {
            return parts[..<i].joined(separator: ".")
        }
        return id
    }
}

// ---------------------------------------------------------------------------

/// Bundle identifiers as people recognise them.
///
/// **Both lookups are cached, and that is not premature.** Each one is a
/// Launch Services query plus a filesystem read, and they are now on the path
/// of a sidebar row: the list is rebuilt on every keystroke of the search
/// field and the row of a running recording re-renders once a second, so an
/// uncached `display` is a disk touch per row per keystroke for the whole
/// length of a meeting. The cache is never invalidated, because the answer is
/// the app's name and icon, which do not change while the app is installed.
/// Written from the main thread only, like `MenuBarIcon`'s.
enum AppNames {
    /// Nil for an app that is not installed, which is a fact worth caching:
    /// `installedName` is what lets a caller with a stored name of its own
    /// prefer that over an identifier printed as though it were a name.
    private static var names: [String: String?] = [:]
    private static var icons: [String: NSImage?] = [:]

    /// The app's real name, or nil when it is not on this Mac any more.
    static func installedName(_ bundleID: String) -> String? {
        if let cached = names[bundleID] { return cached }
        let resolved = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map {
                FileManager.default.displayName(atPath: $0.path)
                    .replacingOccurrences(of: ".app", with: "")
            }
        names[bundleID] = resolved
        return resolved
    }

    /// "Zoom" rather than "us.zoom.xos".
    ///
    /// Falls back to the identifier rather than to something friendlier when
    /// the app cannot be found, because an uninstalled app in the skip list
    /// still has to be identifiable enough to remove.
    static func display(_ bundleID: String) -> String {
        installedName(bundleID) ?? bundleID
    }

    /// Listen's own icon, for a recording that was not made on a call.
    static var own: NSImage? {
        AppInfo.bundleID.flatMap(icon) ?? NSApp.applicationIconImage
    }

    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = image
        return image
    }
}
