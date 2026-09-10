import AppKit
import Foundation
import simd

/// The galaxy's geometry, as assertions, with no library and no window.
///
/// `verify_galaxy.sh` compiles this against `Galaxy.swift`, `GalaxyRenderer.swift`
/// and `GalaxyPane.swift`'s motion policy alone, which is possible because
/// `GalaxyLibrary.swift` holds everything that reads the disk. What it buys is
/// the one class of bug in this feature that a screenshot cannot show and a
/// count cannot catch: a sign.
///
/// The orbit direction shipped inverted on one axis. Dragging right sent the
/// scene left while dragging up brought it up, which reads as the picture being
/// broken rather than as a minus sign, and nothing in the suite could see it.
@main struct GalaxyGeometry {
    static var passed = 0
    static func check(_ condition: Bool, _ name: String) {
        if condition { passed += 1; print("  ok: \(name)") }
        else { print("  FAIL: \(name)"); failures += 1 }
    }
    static var failures = 0

    /// Where a world point lands on screen, in the same matrices the renderer
    /// and picking use. x grows right, y grows up.
    static func project(_ point: SIMD3<Float>, _ camera: GalaxyCamera, aspect: Float = 1.6) -> SIMD2<Float>? {
        let clip = GalaxyCamera.perspectiveMatrix(aspect: aspect) * camera.viewMatrix() * SIMD4<Float>(point, 1)
        guard clip.w > 0.0001 else { return nil }
        return SIMD2(clip.x / clip.w, clip.y / clip.w)
    }

    static func main() {
        print("the camera")
        // **A star on the near face, and the choice matters.** A drag orbits
        // the camera about the target, so everything *beyond* the target moves
        // the opposite way on screen from everything in front of it. The near
        // face is what a reader thinks they have hold of, so it is what "the
        // scene follows the pointer" is a claim about. Measured at rest: this
        // marker sits at x +0.740, y -0.327 in clip space, comfortably in
        // frame, and the far-side check below pins the other half.
        let near = SIMD3<Float>(6, 0, 6)
        let far = SIMD3<Float>(0, 0, -12)
        var camera = GalaxyCamera()
        camera.reset()
        guard let before = project(near, camera), let farBefore = project(far, camera) else {
            fatalError("both markers must start in front of the camera")
        }

        // **The scene follows the pointer.** This is the assertion the feature
        // shipped without: drag right, and the thing you are looking at comes
        // with you, the way it does in every 3D viewer and in the reference
        // this was ported from. It shipped inverted on the horizontal alone,
        // which reads as the picture being broken rather than as a sign.
        var dragged = camera
        dragged.orbit(deltaX: 60, deltaY: 0, viewportHeight: 800)
        check(project(near, dragged).map { $0.x > before.x + 0.01 } ?? false,
              "dragging right moves the near face right")
        check(dragged.eye.x < camera.eye.x,
              "which means the camera itself goes the other way, to the left")
        check(project(far, dragged).map { $0.x < farBefore.x - 0.01 } ?? false,
              "and the far side moves the other way, because this is a rotation about the target")

        var draggedLeft = camera
        draggedLeft.orbit(deltaX: -60, deltaY: 0, viewportHeight: 800)
        check(project(near, draggedLeft).map { $0.x < before.x - 0.01 } ?? false,
              "dragging left moves the near face left")

        var draggedUp = camera
        draggedUp.orbit(deltaX: 0, deltaY: 60, viewportHeight: 800)
        check(project(near, draggedUp).map { $0.y > before.y + 0.01 } ?? false,
              "dragging up moves the near face up")
        check(draggedUp.eye.y < camera.eye.y, "by lowering the camera")

        var draggedDown = camera
        draggedDown.orbit(deltaX: 0, deltaY: -60, viewportHeight: 800)
        check(project(near, draggedDown).map { $0.y < before.y - 0.01 } ?? false,
              "dragging down moves the near face down")

        // The same drag is the same turn whatever the window is, which is why
        // the rate is per point of viewport height rather than a constant.
        var small = camera, large = camera
        small.orbit(deltaX: 40, deltaY: 0, viewportHeight: 400)
        large.orbit(deltaX: 80, deltaY: 0, viewportHeight: 800)
        check(abs(small.yaw - large.yaw) < 0.0001, "a drag across the pane is the same turn at any window size")

        // Straight up is where `lookAt` produces NaN, so the pitch stops short.
        var extreme = camera
        for _ in 0..<200 { extreme.orbit(deltaX: 0, deltaY: -400, viewportHeight: 800) }
        check(extreme.pitch.isFinite && abs(extreme.pitch) < 1.5, "pitch stops short of the pole")
        check(extreme.eye.x.isFinite && extreme.eye.y.isFinite && extreme.eye.z.isFinite, "and the eye stays finite there")

        // Zoom is bounded at both ends, or a scroll runs the camera through the
        // middle of the galaxy or off to infinity.
        var zoomed = camera
        for _ in 0..<200 { zoomed.zoom(delta: -400) }
        check(zoomed.distance >= GalaxyCamera.minimumDistance, "zooming in stops before the centre")
        for _ in 0..<400 { zoomed.zoom(delta: 400) }
        check(zoomed.distance <= GalaxyCamera.maximumDistance, "and zooming out stops")

        print("\nframing a selection")
        // The whole reason a click flies anywhere: what the star links to has
        // to be on screen when it lands.
        let star = SIMD3<Float>(0, 0, 17)
        let linked = SIMD3<Float>(0, 14, -6)
        let framed = camera.focused(on: star, including: [linked], aspect: 1.6)
        if let there = project(linked, framed) {
            check(abs(there.x) <= 1 && abs(there.y) <= 1, "the farthest thing a star links to is in frame")
        } else { check(false, "the farthest link stayed in front of the camera") }
        let alone = camera.focused(on: star, including: [], aspect: 1.6)
        check(alone.distance >= 11, "a star that links to nothing is not pressed against the lens")

        print("\npicking agrees with what is drawn")
        // The radius the shader scales a quad by is the radius picking tests,
        // or a click selects the star beside the one under the pointer.
        check(GalaxyRenderer.starRadius(id: "a", kind: Galaxy.Node.recording, selectionID: "a", hoverID: nil)
              > GalaxyRenderer.starRadius(id: "a", kind: Galaxy.Node.recording, selectionID: nil, hoverID: nil),
              "a selected star is drawn larger, so it is easier to click")
        check(GalaxyRenderer.starRadius(id: "d", kind: Galaxy.Node.device, selectionID: nil, hoverID: nil)
              > GalaxyRenderer.starRadius(id: "a", kind: Galaxy.Node.recording, selectionID: "a", hoverID: nil),
              "and the centre is larger than any of them")

        print("\nthe motion policy")
        var policy = GalaxyMotionPolicy()
        policy.visible = true
        check(policy.ambient, "a visible galaxy animates")
        for gate in [\GalaxyMotionPolicy.reducedMotion, \GalaxyMotionPolicy.lowPower,
                     \GalaxyMotionPolicy.interacting] {
            var gated = policy
            gated[keyPath: gate] = true
            check(!gated.ambient, "and stops for every gate, one at a time")
        }
        var hidden = policy
        hidden.visible = false
        check(!hidden.ambient && !hidden.flights, "a galaxy nobody can see does neither")
        var interacting = policy
        interacting.interacting = true
        check(interacting.flights, "but a flight to a star somebody clicked is not an interruption")

        print("\n\(passed) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
