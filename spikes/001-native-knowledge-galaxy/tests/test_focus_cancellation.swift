import AppKit
import MetalKit
import simd

@main struct FocusCancellationTests {
    static func main() {
        _ = NSApplication.shared
        let controller = GraphViewController(snapshot: GraphFixture.makeGalaxy(nodeCount: 8))
        controller.loadViewIfNeeded()
        guard let metal = controller.testMetalView else { fatalError("Expected the controller to install a real MTKView") }

        verifyCancellation(named: "manual pause", controller: controller, metal: metal) {
            controller.setMotionEnabled(false)
        }
        controller.setMotionEnabled(true)

        verifyCancellation(named: "low power", controller: controller, metal: metal) {
            controller.testApplyAnimationPolicy(visible: true, reducedMotion: false, lowPower: true)
        }
        verifyCancellation(named: "reduced motion", controller: controller, metal: metal) {
            controller.testApplyAnimationPolicy(visible: true, reducedMotion: true, lowPower: false)
        }
        verifyCancellation(named: "hidden", controller: controller, metal: metal) {
            controller.testApplyAnimationPolicy(visible: false, reducedMotion: false, lowPower: false)
        }
        print("PASS: focus-flight cancellation schedules one settled redraw and label refresh without a continuous timer")
    }

    private static func verifyCancellation(named name: String, controller: GraphViewController, metal: MTKView, cancel: () -> Void) {
        controller.testApplyAnimationPolicy(visible: true, reducedMotion: false, lowPower: false)
        let start = GraphCamera()
        let goal = start.focused(on: SIMD3<Float>(7, -3, 2), distance: 9)
        controller.testStartFocusFlight(from: start, goal: goal)
        controller.testApplyAnimationPolicy(visible: true, reducedMotion: false, lowPower: false)
        assert(!metal.isPaused, "\(name): eligible focus flight should drive the real MTKView")

        let redraws = controller.testRedrawRequestCount
        let labelUpdates = controller.testLabelUpdateCount
        cancel()

        assert(controller.testFocusFlightGoal == nil, "\(name): cancellation must clear the flight")
        assert(simd_distance(controller.testCamera.target, goal.target) < 0.0001, "\(name): camera must snap to the settled goal")
        assert(abs(controller.testCamera.distance - goal.distance) < 0.0001, "\(name): camera distance must snap to the settled goal")
        assert(controller.testRedrawRequestCount == redraws + 1, "\(name): cancellation must request exactly one settled-camera redraw")
        assert(controller.testLabelUpdateCount == labelUpdates + 1, "\(name): cancellation must refresh labels once")
        // The redraw counter records the real MTKView setNeedsDisplay request. This offscreen
        // process cannot assert a presented GPU drawable because WindowServer is occluded.
        assert(metal.isPaused && !controller.animationRunning, "\(name): cancellation must not leave a continuous timer running")
    }
}
