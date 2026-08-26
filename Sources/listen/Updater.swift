import AppKit
import Sparkle

/// Sparkle wiring.
///
/// Sparkle shows its own windows and modal alerts. Every one of those
/// callbacks activates the app first, because an update prompt that opens
/// behind the meeting window someone is looking at is invisible, and an app
/// waiting on an invisible modal looks hung.
///
/// Listen is not `LSUIElement`, unlike Speak, so this is less dangerous here
/// than it is there. It is kept because the failure is the same shape and
/// costs one line to avoid.
final class Updater: NSObject, SPUStandardUserDriverDelegate, SPUUpdaterDelegate {
    /// One updater for the process. Sparkle's controller starts a scheduler on
    /// construction, so building a second one would schedule two.
    @MainActor static let shared = Updater()

    /// What the last finished check concluded.
    ///
    /// Sparkle answers a check in a window that is then dismissed, taking the
    /// answer with it, and a scheduled check that finds nothing says nothing at
    /// all. Settings keeps the outcome on screen so "am I on the latest
    /// version" has an answer that survives closing a dialog.
    enum Outcome: Equatable {
        case unknown
        case checking
        case upToDate(String)
        /// A newer version exists on the feed. Nothing has been fetched.
        case available(String)
        /// Downloaded, signature-checked and staged. Quitting applies it, and
        /// so does `installNow()`. Only automatic installing reaches this.
        case ready(String)
        case failed(String)
    }

    /// Built in `init`, not stored inline, because the controller needs `self`
    /// as its user driver delegate and that is not available until after
    /// `super.init()`.
    private var controller: SPUStandardUpdaterController!

    private(set) var outcome: Outcome = .unknown {
        didSet {
            if outcome != oldValue {
                remember()
                NotificationCenter.default.post(name: Self.outcomeChanged, object: self)
            }
        }
    }

    /// Posted on the main thread whenever `outcome` changes, so anything that
    /// shows the answer can follow a check it did not start itself.
    ///
    /// A notification rather than the single closure this was, because there
    /// are now two followers: the Updates pane, and the dot on the gear in the
    /// library's title bar. With one closure the second one to claim it
    /// silently unhooked the first, and the symptom would have been the pane
    /// going dead exactly when the toolbar was working.
    static let outcomeChanged = Notification.Name("ListenUpdaterOutcomeChanged")

    /// Sparkle's own handle on an update that is downloaded and staged, held
    /// from `willInstallUpdateOnQuit`, which is the only place it is offered.
    ///
    /// Not cleared after use: from Sparkle 2.3 it may be invoked again if the
    /// termination it asks for is refused, and something in this app can refuse
    /// one.
    private var installImmediately: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        if !stageFakeUpdate() { recall() }
    }

    /// `LISTEN_UPDATE_READY=<version>` puts this into the state only a real
    /// staged download can otherwise produce.
    ///
    /// Same family as `LISTEN_OFFLINE`, and the same argument: the ready state
    /// needs a signed release newer than the one you are running, which means
    /// publishing one, so without a seam the Install button and the second
    /// tooltip ship having never been on screen. The block prints instead of
    /// relaunching, because the relaunch is the one part a fake cannot do.
    ///
    /// Nothing is persisted while it is set, or a single test run would leave a
    /// permanent dot on a real copy pointing at a version that does not exist.
    private func stageFakeUpdate() -> Bool {
        guard let version = ProcessInfo.processInfo.environment["LISTEN_UPDATE_READY"],
              !version.isEmpty else { return false }
        fake = true
        installImmediately = {
            FileHandle.standardError.write(Data("[Listen] would install \(version)\n".utf8))
        }
        outcome = .ready(version)
        return true
    }

    private var fake = false

    /// Sparkle disables its own menu item while a check is already running or
    /// the updater failed to start, so the menu mirrors that rather than
    /// offering a control that does nothing.
    var canCheck: Bool { controller.updater.canCheckForUpdates }

    /// Human-readable last check, for Settings.
    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Whether a found update is fetched in the background and installed on the
    /// next quit, rather than waiting behind a dialog.
    ///
    /// Sparkle refuses to turn this on while `automaticallyChecks` is off, and
    /// silently: `SPUUpdaterSettings.allowsAutomaticUpdates` falls back to the
    /// check setting, and the setter returns without writing. So the two
    /// controls are not independent, and Settings disables this one rather than
    /// offering a switch that would not move.
    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Something is waiting, fetched or not. What the dot on the gear means,
    /// and the reason that gear opens the Updates section rather than whichever
    /// one was last read.
    var isPending: Bool {
        switch outcome {
        case .available, .ready: return true
        default: return false
        }
    }

    /// Downloaded and staged, so there is a version to put in place right now.
    var isReady: Bool {
        if case .ready = outcome { return true }
        return false
    }

    // MARK: - What a launch knows before it asks anything

    /// The version the last check found, kept across launches.
    ///
    /// The outcome lives in this process and starts at `.unknown`, so without
    /// this a relaunch forgets that an update exists and the gear loses its dot
    /// until the next scheduled check. That gap is what a launch-time check used
    /// to paper over, and the cost of that check was the whole automatic
    /// install: see `applicationDidFinishLaunching`.
    private static let pendingKey = "updatePendingVersion"

    private func remember() {
        guard !fake else { return }
        switch outcome {
        case .available(let version), .ready(let version):
            Settings.defaults.set(version, forKey: Self.pendingKey)
        case .upToDate:
            Settings.defaults.removeObject(forKey: Self.pendingKey)
        // A check that failed and one that has not run learn nothing, so
        // neither may erase what the last successful one wrote.
        case .unknown, .checking, .failed:
            break
        }
    }

    /// Restore the dot without touching the network.
    ///
    /// Compared against the running version rather than trusted, because the
    /// obvious way for this key to be wrong is the update having been installed
    /// since it was written, and an app that says a version is available when
    /// you are already on it is worse than one that says nothing.
    ///
    /// `.available` rather than `.ready` even when the copy really is staged:
    /// the block that installs it does not survive a relaunch, so claiming a
    /// button exists that does not is the one lie available here.
    private func recall() {
        guard let version = Settings.defaults.string(forKey: Self.pendingKey) else { return }
        guard let running = AppInfo.version,
              SUStandardVersionComparator.default
                  .compareVersion(running, toVersion: version) == .orderedAscending else {
            Settings.defaults.removeObject(forKey: Self.pendingKey)
            return
        }
        outcome = .available(version)
    }

    // MARK: - Installing without waiting for a quit

    /// Why putting the update in place right now would cost something, or nil.
    ///
    /// Installing relaunches the app, and Listen is a recorder: the two things
    /// a relaunch can destroy are an hour of meeting that has not been written
    /// out yet and a transcription job that would start again from the top.
    /// Both are cheap to ask about and neither is recoverable afterwards.
    @MainActor
    var installNowBlocker: String? {
        if Capture.shared.isRecording {
            return "Not while a recording is running. Installing quits Listen, "
                + "and this meeting would end here."
        }
        if Queue.shared.isBusy {
            return "Not while a recording is being transcribed. Installing quits "
                + "Listen, and that job would start again from the beginning."
        }
        return nil
    }

    /// Put the staged update in place and come back on it. Answers whether it
    /// went, so a control can say why it did not.
    @MainActor
    @discardableResult
    func installNow() -> Bool {
        guard installNowBlocker == nil, let install = installImmediately else { return false }
        install()
        return true
    }

    @objc func checkForUpdates(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        // Set before asking, not in a delegate callback: a check that never
        // reaches the network still has to stop showing the previous answer.
        outcome = .checking
        controller.checkForUpdates(sender)
    }

    // MARK: - SPUStandardUserDriverDelegate

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // A scheduled check that found something must not steal focus silently;
        // activating here is what makes the release-notes window reachable.
        if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        outcome = .available(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        // Sparkle's own wording, which names the newest version on the feed and
        // covers the cases where a newer one exists but cannot run here: macOS
        // too old, Intel hardware, and so on. Writing our own would either
        // repeat that work or quietly claim "up to date" when it is not.
        outcome = .upToDate((error as NSError).localizedRecoverySuggestion
                            ?? "Listen is up to date.")
    }

    /// The update has been fetched, verified against Listen's key and staged,
    /// and Sparkle is about to go quiet until the app is quit.
    ///
    /// **Answering `true` is what buys the Install button.** It is the only way
    /// Sparkle hands out a handle that installs on demand, and its header states
    /// the half that makes it safe: "in either case Sparkle will always attempt
    /// to install the update when the app terminates". So quitting still works
    /// exactly as it did, and this only adds a second way in.
    ///
    /// The cost, also from the header, is that answering `true` stalls the
    /// update cycle: no further checks run until this one is applied. That is
    /// the right trade here, because there is nothing a later check could find
    /// that this copy could act on without first installing what it already
    /// has, and `canCheck` going false is what disables Check Now while a
    /// version sits waiting.
    ///
    /// Without this the automatic path had no surface at all. Listen opens at
    /// login and watches for meetings, so "installs on the next quit" is a
    /// promise that can go unkept for weeks on a Mac that is only ever put to
    /// sleep, and nothing anywhere said a version was sitting there waiting for
    /// a quit that was not coming.
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installImmediately = immediateInstallHandler
        outcome = .ready(item.displayVersionString)
        return true
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        // Only failures are recorded here. Finding an update and finding none
        // both arrive through their own callback first, and this one fires
        // again when a found update is dismissed or skipped, which must not
        // erase the line saying that update exists.
        guard let error = error as NSError?,
              error.code != Int(SUError.noUpdateError.rawValue) else {
            if outcome == .checking { outcome = .unknown }
            return
        }
        // A staged update outranks a failure. Nothing that happens after a copy
        // is on disk makes it less installed, and the Install button has to
        // survive the next check failing on a train.
        guard !isReady else { return }
        outcome = .failed(error.localizedDescription)
    }
}
