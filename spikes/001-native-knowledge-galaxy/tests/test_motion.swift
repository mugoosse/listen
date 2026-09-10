import Foundation
import simd

@main struct MotionTests {
    static func close(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>, _ tolerance: Float = 0.0001) -> Bool {
        simd_length_squared(lhs - rhs) <= tolerance * tolerance
    }

    static func main() {
        let source = SIMD3<Float>(3, -4, 12)
        guard close(GraphMotion.position(source, id: "note:one", kind: "note", time: 0), source) else {
            fatalError("t=0 must preserve the layout position")
        }
        let center = GraphMotion.position(.zero, id: "view:current-device", kind: "device", time: 42)
        guard close(center, .zero) else { fatalError("device center must remain fixed") }
        let animated = GraphMotion.position(source, id: "note:one", kind: "note", time: 13.25)
        guard abs(simd_length(animated) - simd_length(source)) < 0.0001 else {
            fatalError("ambient motion must preserve shell radius")
        }
        let again = GraphMotion.position(source, id: "note:one", kind: "note", time: 13.25)
        guard close(animated, again) else { fatalError("motion must be deterministic") }
        guard !close(animated, source) else { fatalError("non-center nodes must move at nonzero time") }
        print("PASS: GraphMotion origin, center, radial preservation, determinism")
    }
}
