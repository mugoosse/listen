import AppKit
import ListenKit

/// Asking the people who were already here.
///
/// **Setup only runs on a first run, so the memory step reaches nobody who
/// already uses Listen.** `Settings.isFirstRun` is the absence of the
/// `onboarded` key, and every existing install has it, so an upgrade puts the
/// roster in Settings and changes nothing else: the feature stays off, and the
/// people most likely to conclude it does not exist are the ones who have been
/// here longest. The whole diagnosis this work started from was that nothing
/// ever asked. Shipping a fix that still does not ask them would be the same
/// bug with more code behind it.
///
/// So: once, when somebody comes back to the app, in the words the setup step
/// uses. `Updater.offerStagedUpdate` is the pattern and most of the guards are
/// its guards, for its reasons.
@MainActor
enum MemoryOffer {
    /// Whether this install has raised it. Local rather than in the library's
    /// settings file: it records that a screen was shown on this Mac, which is
    /// not a fact about the library and must not travel to another device that
    /// has its own screen and its own owner sitting at it.
    private static let shownKey = "memoryOfferShown"
    static var shown: Bool {
        get { Settings.defaults.bool(forKey: shownKey) }
        set { Settings.defaults.set(newValue, forKey: shownKey) }
    }

    /// A first run has already been asked by the setup step, so mark it done
    /// rather than asking twice. Called from `finish` and from the dismissal
    /// path, because both of those are somebody having seen the step.
    static func markAskedBySetup() { shown = true }

    /// Whether a scan is already in flight, and what the last one answered.
    ///
    /// **Both exist because the caller is an activation, not a screen.**
    /// `offerIfNeeded` runs from `appBecameActive`, which fires every single
    /// time somebody switches back to Listen, and the scan below is
    /// `ContextSources.all()`: every recording's turns, split into passages,
    /// mention-matched against the roster. `ContextEnrolment.Roster` says in so
    /// many words that callers of that pass are "expected to be a screen
    /// somebody opened rather than a timer", and an activation is the timer.
    ///
    /// Without `scanning`, switching away and back while one runs starts
    /// another beside it: `Updater.offerStagedUpdate` guards its own re-entry
    /// with `offering` for exactly this reason. Without `counted`, a library
    /// with recordings but no named speakers, which is the ordinary state of a
    /// library nobody has labelled yet, pays that whole pass on every switch
    /// back, for ever, and never has anything to show for it.
    ///
    /// So: at most one scan per launch, and a second activation answers from
    /// the count the first one left behind.
    private static var scanning = false
    private static var counted: Int?

    /// Whether the library carries no answer about memory, either way.
    ///
    /// **Its own function because it is the guard that can silently break, and
    /// the only one a script can check.** Offering to somebody who already
    /// said no is the failure that costs trust rather than a screen: it reads
    /// as an app that did not listen. The register names are the whole test,
    /// so a rename that forgets this is exactly the change that would nag
    /// every user who had declined. `ContextCLI.Coverage` reports it and
    /// `verify_memory_consent.sh` asserts it over a synthetic library.
    ///
    /// Deliberately not the whole decision: `shown` is a per-install defaults
    /// bool, and the rest of `offerIfNeeded` is about what is on screen right
    /// now. Neither of those is a fact about a library and neither belongs
    /// here.
    /// `nonisolated` because it reads a file and nothing else: the CLI asks it
    /// from no actor at all, and an offer decision that can only be made on the
    /// main thread is one a script cannot check.
    nonisolated static func neverAnswered(root: URL) -> Bool {
        let values = (try? MemoryPreferences.read(root: root)) ?? [:]
        return values["enrolNewPeople"] == nil
            && !values.contains { $0.key.hasPrefix("person:") && $0.key.hasSuffix(":automatic") }
    }

    /// Offer it, if this is somebody it has never been offered to.
    ///
    /// Every guard here is a state in which an alert would be wrong rather than
    /// merely early, so none of them are a delay to be tuned:
    ///
    /// - **Never on a first run.** Setup asks, and this must not ask again.
    /// - **Never over setup**, which is a flow with a position in it.
    /// - **Never while recording.** The one thing that must not be interrupted
    ///   is the meeting somebody is in, which is the rule the whole app keeps.
    /// - **Never when the answer already exists**, either way: somebody who
    ///   turned it on, or turned it off, has answered.
    /// - **Never with Ask off**, because automatic memory needs it and the
    ///   offer would be for something that cannot run.
    /// - **Never on an empty library**, where there is nobody to remember and
    ///   the offer is a feature tour rather than a question.
    static func offerIfNeeded() {
        guard !shown, !scanning, !Settings.isFirstRun, NSApp.isActive,
              !Onboarding.shared.isShowing, !Capture.shared.isRecording,
              Settings.askEnabled else { return }
        guard neverAnswered(root: Library.root) else { shown = true; return }

        // Already answered this launch. A scan that finished while somebody was
        // in another app leaves its count here, so the switch back that follows
        // presents from it rather than reading the library a second time.
        if let people = counted {
            if people > 0 { present(people) }
            return
        }

        // Off the main thread, because it reads every recording's turns, and
        // the answer decides whether there is anything to offer at all.
        scanning = true
        Task.detached(priority: .utility) {
            let people = ContextEnrolment.candidates(ContextSources.all()).count
            await MainActor.run {
                scanning = false
                counted = people
                guard people > 0, !shown, NSApp.isActive, !Capture.shared.isRecording else { return }
                present(people)
            }
        }
    }

    private static func present(_ people: Int) {
        shown = true
        let alert = NSAlert()
        alert.messageText = "Remember the people you talk to?"
        // The setup step's words, shortened to an alert. The cost is in it,
        // before the button rather than after it, for that step's reason.
        alert.informativeText = """
            Listen can keep a short brief on each person you record: what they \
            are working on, what they have asked you for, what changed since \
            last time. Every line is a quote from a real conversation with the \
            recording behind it.

            It would start with the \(people) \(people == 1 ? "person" : "people") \
            already in your library, and read in the background while Listen is \
            open. Reading is done by the same model that answers your questions, \
            so the passages about a person are sent to that provider.

            You can turn any one person off, and Settings, People & Memory \
            lists everyone at once.
            """
        alert.addButton(withTitle: "Remember People")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? MemoryPreferences.enrolNewPeople(true, root: Library.root)
        let model = ContextService.modelChoice()
        Task.detached(priority: .userInitiated) {
            ContextEnrolment.sync(ContextSources.all(), model: model)
            await MainActor.run {
                ContextService.shared.sourcesChanged()
                NotificationCenter.default.post(name: PeopleMemory.changed, object: nil)
            }
        }
    }
}
