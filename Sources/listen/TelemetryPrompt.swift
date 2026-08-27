import Foundation
import ListenKit

/// The one-time telemetry question for installs that predate the setup step.
///
/// New users answer inside setup; an existing install has been promised "no
/// telemetry" by every earlier version, so this asks once, in the app's own
/// words, before anything could ever be sent. It is the same screen setup
/// shows a new install, raised through `Onboarding.showTelemetryOnly()`
/// rather than a second implementation of the question: one look, whichever
/// way somebody arrives at it.
///
/// Once means once: the stamp is written whatever the answer, the guard
/// checks it before anything else, and Settings, Privacy is the only path
/// back afterwards.
@MainActor
enum TelemetryPrompt {
    static func showIfNeeded() {
        // Setup owns the question for a first run, and a forced or blocked
        // build must not ask a question whose answer it would ignore.
        guard Settings.onboarded,
              Telemetry.consent == nil,
              !Settings.telemetryPrompted,
              !Telemetry.blocked else { return }
        // One runloop turn later, so the library window is on screen and the
        // question appears over the app rather than instead of it.
        DispatchQueue.main.async {
            // Checked again on arrival: the async hop leaves a gap in which
            // Settings, Privacy could already have answered this.
            guard Telemetry.consent == nil, !Settings.telemetryPrompted else { return }
            Onboarding.shared.showTelemetryOnly()
        }
    }
}
