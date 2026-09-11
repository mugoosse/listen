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
                // A version that finishes downloading while somebody is
                // looking at Listen is offered there and then, rather than
                // waiting for a quit. Asynchronously, because this is set from
                // inside Sparkle's own delegate callback and an alert raised on
                // that stack runs a modal run loop inside it.
                if isReady {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated { self?.offerStagedUpdate() }
                    }
                }
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
        // Coming back to Listen is the moment to offer what is already on
        // disk. For an app that opens at login and is never quit, that is the
        // only "opening it again" there is, and it is the one other updaters
        // use. See `offerStagedUpdate`.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
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

    /// Ask once at launch, because opening an app is when somebody expects it
    /// to know whether it is current.
    ///
    /// **This is not the probe that was deleted, and the difference is the
    /// whole reason it is safe.** `checkForUpdateInformation` downloads
    /// nothing and rescheduled the next real check a full interval out, so a
    /// copy launched more often than the interval never installed anything;
    /// see `applicationDidFinishLaunching` and `.agents/notes/release.md`.
    /// `checkForUpdatesInBackground` **is** the check the scheduler would have
    /// run: it downloads and stages with automatic installing on, and puts
    /// Sparkle's own window up with it off. Sparkle's header names launch as
    /// the place to force one, "immediately after starting the updater, and
    /// only when automatic update checks are enabled", and `startUpdater:`
    /// says the same in its own comment: the cycle is started one runloop turn
    /// later precisely to leave the app that turn to check first.
    ///
    /// It is what closes the six hour hole on the far side of an install.
    /// Putting an update in place stamps `SULastCheckTime`
    /// (`SPUUpdater.updateWillInstallHandler`), so the copy that comes back up
    /// is not due a scheduled check for a full interval, which is exactly the
    /// moment somebody who ships several versions a day is most likely to be
    /// one behind again.
    func checkAtLaunch() {
        guard !fake, automaticallyChecks else { return }
        controller.updater.checkForUpdatesInBackground()
    }

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
        // The third thing a relaunch can throw away, and the only one measured
        // in gigabytes. It matters more now than when this list was two, because
        // installing is offered rather than only asked for.
        if ModelDownload.shared.isDownloading {
            return "Not while the speech model is downloading. Installing quits "
                + "Listen, and the download would be interrupted."
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

    // MARK: - Offering it to somebody who is looking

    /// When the staged version was last put in front of anybody.
    ///
    /// "Later" is honoured for an hour rather than for ever: the dot on the
    /// gear says the same thing in the meantime and asks for nothing, and an
    /// app somebody tabs in and out of all day would otherwise be asking on
    /// every visit.
    private var offeredAt: Date?
    private static let offerAgainAfter: TimeInterval = 3600

    /// The alert activates the app, and activation is one of the two things
    /// that raises the alert.
    private var offering = false

    @objc private func appBecameActive() {
        MainActor.assumeIsolated { offerStagedUpdate() }
    }

    /// Offer the version that is already on disk.
    ///
    /// **Why this exists.** `SUAutomaticallyUpdate` means "installed on the
    /// next quit", and Listen opens at login and is not quit for weeks, so a
    /// staged version could sit there indefinitely. Worse, Sparkle stops
    /// looking at the feed while one is staged (`checkForUpdates` and the
    /// scheduler both resume the download they already have rather than
    /// fetching the appcast), so everything published in the meantime is
    /// invisible until this one is in place. The staged window is the blind
    /// window, and this is what keeps it short.
    ///
    /// `force` is the explicit ask from the menu: it ignores the throttle and
    /// says why it cannot install rather than going quiet.
    @MainActor
    func offerStagedUpdate(force: Bool = false) {
        guard case .ready(let version) = outcome, !offering else { return }
        // Never to somebody who is in another app. An alert that takes the
        // keyboard away from the meeting somebody is in is how an updater gets
        // switched off.
        guard force || NSApp.isActive else { return }
        // Setup is a flow with its own position, and a relaunch loses it.
        guard force || !Onboarding.shared.isShowing else { return }

        if let blocker = installNowBlocker {
            guard force else { return }
            offering = true
            defer { offering = false }
            let alert = NSAlert()
            alert.messageText = "Listen \(version) is ready to install"
            alert.informativeText = blocker
            alert.runModal()
            return
        }

        if !force, let offeredAt,
           Date().timeIntervalSince(offeredAt) < Self.offerAgainAfter { return }

        offering = true
        defer { offering = false }
        offeredAt = Date()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Listen \(version) is ready to install"
        alert.informativeText = "Listen quits and comes straight back on the new "
            + "version, which takes a few seconds. Until it does it cannot see "
            + "anything published since: a version that is already downloaded is "
            + "the only one it can act on."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Re-read rather than trusted: a recording can start in the seconds the
        // alert is up, `installNow` re-checks and would refuse, and a press
        // that silently does nothing is the worst of the three outcomes.
        if !installNow(), let blocker = installNowBlocker {
            let refused = NSAlert()
            refused.messageText = "Listen \(version) was not installed"
            refused.informativeText = blocker
            refused.runModal()
        }
    }

    /// What the menu offers in place of a check while a version is waiting.
    ///
    /// Sparkle's own check is genuinely unavailable then, so the row used to be
    /// greyed, and a greyed row reads as "this app cannot check any more"
    /// rather than "there is nothing left to check for". This is the verb that
    /// is actually available, and it names the version.
    @MainActor
    @objc func installUpdate(_ sender: Any?) {
        // The status menu does not activate the app, so an alert raised from it
        // would open behind whatever is in front. Same line, same reason, as
        // `checkForUpdates`.
        NSApp.activate(ignoringOtherApps: true)
        offerStagedUpdate(force: true)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        // Under the fake there is nobody to ask: the delegate callbacks all
        // return early, so a check started here would leave "Checking…" on
        // screen for the rest of the launch.
        guard !fake else { return }
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
        guard !fake else { return }
        outcome = .available(item.displayVersionString)
    }

    /// **Every one of these guards on `fake`, and it is not paranoia.**
    /// `LISTEN_UPDATE_READY` fakes the outcome without stalling Sparkle, so
    /// Sparkle's own cycle still starts at launch and, on a copy with no
    /// `SULastCheckTime`, runs a real check about ten seconds in. Measured
    /// while writing `verify_update_offer.sh`: the alert and the menu row were
    /// right at nine seconds and gone at sixteen, because `.upToDate` had
    /// landed on top of the staged state. A seam that expires mid-test is
    /// worse than no seam.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        guard !fake else { return }
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
    /// update cycle: no further checks run until this one is applied. Sparkle
    /// would not look at the feed anyway while a download is staged, answered
    /// `true` or not, because both `checkForUpdates` and the scheduler resume
    /// the update they already hold rather than fetching the appcast. So the
    /// staged window is a blind window either way, and the answer is to keep it
    /// short rather than to give up the Install button: `offerStagedUpdate`
    /// asks whenever somebody comes back to the app, and the menu offers the
    /// install in place of the check it cannot run. Without that, a copy that
    /// staged 0.39.0 and was never quit could not see 0.40.0 at all, and the
    /// only evidence was a greyed Check for Updates.
    ///
    /// Without this the automatic path had no surface at all. Listen opens at
    /// login and watches for meetings, so "installs on the next quit" is a
    /// promise that can go unkept for weeks on a Mac that is only ever put to
    /// sleep, and nothing anywhere said a version was sitting there waiting for
    /// a quit that was not coming.
    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard !fake else { return false }
        installImmediately = immediateInstallHandler
        outcome = .ready(item.displayVersionString)
        return true
    }

    func updater(_ updater: SPUUpdater,
                 didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        guard !fake else { return }
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
