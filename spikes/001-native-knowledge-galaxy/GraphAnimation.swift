import Foundation

/// Ambient motion is presentation only, never evidence of source or agent activity.
struct GraphAnimationState {
    var enabled = true
    var visible = false
    var reducedMotion = false
    var lowPower = false
    var interacting = false
    var runs: Bool { enabled && visible && !reducedMotion && !lowPower && !interacting }
    /// Deliberate focus flights pause ambient interaction but still honor motion policy.
    var focusAnimationEligible: Bool { enabled && visible && !reducedMotion && !lowPower }
}
