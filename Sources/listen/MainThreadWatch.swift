import Foundation

/// Notices when the main thread stops answering, which is the one failure users
/// report and no event in this project could describe.
///
/// **Why it exists.** "When I open the app it makes my laptop freeze" is a real
/// report, and from the outside it is indistinguishable between a main-thread
/// block, a machine swapping under a transcription, and a library large enough
/// that drawing it takes a while. Those have different fixes, and nothing in the
/// app could tell them apart: the events say what finished, never what stopped.
///
/// **How it works.** A background thread posts a ping to the main queue every
/// second and measures how long the reply takes. If the main thread is busy the
/// reply waits, and the wait is the stall. That is the whole mechanism: it costs
/// one enqueue and one date per second, and it cannot itself block the thread it
/// is watching, which a timer *on* the main thread could not avoid.
///
/// **What it sends.** A bucket and a phase, edge-triggered per stall, so an app
/// that is wedged sends one event rather than one per second. No stack, no
/// symbol names, nothing about what the user was doing. It answers "does this
/// happen, to how many people, how badly, and roughly when", which is what
/// decides whether to go looking, and deliberately not "where", which is what a
/// profiler on a reproduction is for.
@MainActor
enum MainThreadWatch {
    /// Below this, nobody notices and everybody's Mac does it. Two seconds is
    /// where a pointer becomes a spinner.
    private static let floor: TimeInterval = 2

    /// What the app was doing, coarsely, so a stall at launch is not filed with
    /// one during a transcription.
    ///
    /// **Derived from what is running, not set by whoever spoke last.** These
    /// overlap: a pass finishes while a transcription is still going, and a
    /// setter would have filed every stall for the rest of that hour as `idle`.
    /// So callers say what started and what ended, and the phase is the most
    /// significant thing currently true.
    enum Phase: String {
        case launching, idle, transcribing, syncing
    }

    private static var active: Set<Phase> = [.launching]

    static func began(_ phase: Phase) { active.insert(phase) }
    static func ended(_ phase: Phase) { active.remove(phase) }

    /// Transcription first: it is the heaviest thing the app does and the most
    /// likely explanation for a machine that has stopped answering.
    private static var phase: Phase {
        for candidate in [Phase.transcribing, .launching, .syncing] where active.contains(candidate) {
            return candidate
        }
        return .idle
    }

    private nonisolated(unsafe) static var thread: Thread?
    /// The stall now in progress, so one stall is one event however long it
    /// lasts. Written on the watcher thread and read there too.
    private nonisolated(unsafe) static var reported = false

    static func begin() {
        guard thread == nil else { return }
        let watcher = Thread {
            while !Thread.current.isCancelled {
                let asked = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                // Waited for rather than polled, so the measurement is the
                // reply's own latency and not the resolution of a loop.
                _ = answered.wait(timeout: .now() + 60)
                let waited = Date().timeIntervalSince(asked)
                if waited >= MainThreadWatch.floor {
                    if !MainThreadWatch.reported {
                        MainThreadWatch.reported = true
                        let seconds = waited
                        Task { @MainActor in MainThreadWatch.report(seconds) }
                    }
                } else {
                    MainThreadWatch.reported = false
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
        watcher.name = "listen.mainthread.watch"
        // Low, because this thread must never be the reason anything else waits.
        watcher.qualityOfService = .utility
        thread = watcher
        watcher.start()
    }

    static func stop() {
        thread?.cancel()
        thread = nil
    }

    private static func report(_ seconds: TimeInterval) {
        trace("main thread stalled \(String(format: "%.1f", seconds))s during \(phase.rawValue)")
        Telemetry.mainThreadStalled(seconds: seconds, phase: phase.rawValue)
    }
}
