import Foundation
import simd

@main struct AnimationTests {
    static func main() {
        var state = GraphAnimationState()
        assert(!state.runs, "No hidden animation before the view becomes visible")
        state.visible = true
        assert(state.runs)
        state.reducedMotion = true
        assert(!state.runs)
        state.reducedMotion = false
        state.interacting = true
        assert(!state.runs)
        state.interacting = false
        state.enabled = false
        assert(!state.runs)
        state.enabled = true
        state.lowPower = true
        assert(!state.runs)
        state.lowPower = false
        state.visible = false
        assert(!state.runs)

        // Deliberate focus flights ignore interaction/selection but still obey motion policy.
        state.visible = true
        state.enabled = false
        assert(!state.focusAnimationEligible, "Paused motion must snap selection focus")
        state.enabled = true
        state.lowPower = true
        assert(!state.focusAnimationEligible, "Low Power Mode must snap selection focus")
        state.lowPower = false
        state.reducedMotion = true
        assert(!state.focusAnimationEligible, "Reduced Motion must snap selection focus")
        state.reducedMotion = false
        state.visible = false
        assert(!state.focusAnimationEligible, "Hidden views must not schedule a focus flight")
        state.visible = true
        state.interacting = true
        assert(state.focusAnimationEligible, "Selection focus remains eligible while ambient motion is paused for interaction")
        state.interacting = false

        var overview = GraphCamera()
        overview.frameGalaxy()
        assert(overview.target == .zero, "Device-centered overview must not recenter on uneven node bounds")
        assert(overview.distance > 17)
        let camera = GraphCamera()
        let focused = camera.focused(on: SIMD3<Float>(2, 3, 4), distance: 12)
        assert(simd_distance(focused.target, SIMD3<Float>(2, 3, 4)) < 0.0001)
        assert(focused.distance == 12)
        let start = camera.interpolated(to: focused, progress: 0)
        let end = camera.interpolated(to: focused, progress: 1)
        assert(start.target == camera.target && start.distance == camera.distance)
        assert(end.target == focused.target && end.distance == focused.distance)
        let middle = camera.interpolated(to: focused, progress: 0.5)
        assert(simd_distance(middle.target, camera.target) < simd_distance(end.target, camera.target))
        print("PASS: visibility/reduced-motion/pause/interaction/low-power policy and camera focus")
    }
}
