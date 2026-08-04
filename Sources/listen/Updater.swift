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
        didSet { if outcome != oldValue { onChange?() } }
    }

    /// Called on the main thread whenever `outcome` changes, so Settings can
    /// follow a check it did not start itself.
    var onChange: (() -> Void)?

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
