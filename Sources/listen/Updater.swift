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
        case available(String)
        case failed(String)
    }

    /// Built in `init`, not stored inline, because the controller needs `self`
    /// as its user driver delegate and that is not available until after
    /// `super.init()`.
    private var controller: SPUStandardUpdaterController!

    private(set) var outcome: Outcome = .unknown {
        didSet {
            if outcome != oldValue {
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

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
    }

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

    /// Ask the feed without showing anything.
    ///
    /// Sparkle's scheduler only checks once `SUScheduledCheckInterval` has
    /// elapsed, so a copy that is launched and quit inside that window learns
    /// nothing, and the interval is a floor on staleness rather than a period.
    /// This runs on every launch and shows no window at all: the answer arrives
    /// through the same delegate callbacks as any other check, which is what
    /// puts the dot on the gear. Anything that interrupts is still Sparkle's
    /// own scheduler, or the user pressing Check Now.
    func checkQuietly() {
        // Somebody who turned automatic checks off meant the network too, not
        // just the dialog. Silent is not the same as permitted.
        guard automaticallyChecks else { return }
        // Not while a real check is already in flight. `canCheckForUpdates` is
        // false during one, and starting a second would cancel the first, which
        // for a user-initiated check means their window closing on its own.
        guard controller.updater.canCheckForUpdates else { return }
        controller.updater.checkForUpdateInformation()
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
        outcome = .failed(error.localizedDescription)
    }
}
