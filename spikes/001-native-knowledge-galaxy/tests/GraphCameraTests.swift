import Foundation
import simd

@inline(__always)
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func approximatelyEqual(_ lhs: Float, _ rhs: Float, tolerance: Float = 0.0001) -> Bool {
    abs(lhs - rhs) <= tolerance
}

@main
struct GraphCameraTests {
    static func main() {
        var camera = GraphCamera()
        let initial = camera.eye
        camera.orbit(deltaX: 120, deltaY: -45)
        expect(simd_length(camera.eye - initial) > 0.01, "orbit changes eye")
        expect(approximatelyEqual(simd_length(camera.eye - camera.target), camera.distance, tolerance: 0.01), "orbit preserves distance")

        let beforeZoom = camera.distance
        camera.zoom(delta: -1_000)
        expect(camera.distance < beforeZoom, "negative zoom moves closer")
        expect(camera.distance >= GraphCamera.minimumDistance, "zoom is clamped")

        camera.pan(deltaX: 40, deltaY: -20, viewportSize: SIMD2<Float>(800, 600))
        expect(simd_length(camera.target) > 0.01, "pan changes target")
        camera.reset()
        expect(approximatelyEqual(camera.distance, GraphCamera.defaultDistance), "reset restores distance")
        expect(simd_length(camera.target) < 0.0001, "reset restores target")

        let view = matrix_identity_float4x4
        let projection = GraphCamera.perspectiveMatrix(fovyRadians: .pi / 2, aspect: 1, nearZ: 0.1, farZ: 100)
        let centerRay = GraphCamera.ray(screenPoint: SIMD2<Float>(50, 50), viewportSize: SIMD2<Float>(100, 100), view: view, projection: projection)
        expect(centerRay != nil, "center ray is defined")
        expect(centerRay!.direction.z < -0.99, "center ray points through negative z")

        let hit = GraphPicking.nearestHit(
            ray: GraphRay(origin: SIMD3<Float>(0, 0, 4), direction: SIMD3<Float>(0, 0, -1)),
            nodes: [
                GraphPickNode(id: "far", position: SIMD3<Float>(0, 0, -2), radius: 1),
                GraphPickNode(id: "near", position: SIMD3<Float>(0, 0, 0), radius: 1)
            ]
        )
        expect(hit?.id == "near", "picking chooses nearest depth-consistent sphere")
        expect(GraphPicking.nearestHit(ray: GraphRay(origin: .zero, direction: SIMD3<Float>(1, 0, 0)), nodes: []) == nil, "empty picks return nil")

        let points: [SIMD3<Float>] = [[-12, -2, -5], [12, 2, 5]]
        camera.frame(positions: points, aspect: 1)
        let framed = GraphCamera.perspectiveMatrix(fovyRadians: .pi / 4, aspect: 1, nearZ: 0.1, farZ: 200) * camera.viewMatrix()
        for point in points {
            let clip = framed * SIMD4<Float>(point, 1)
            expect(clip.w > 0 && abs(clip.x / clip.w) < 0.95 && abs(clip.y / clip.w) < 0.95, "framing fits complete graph")
        }
        print("GraphCameraTests: PASS")
    }
}
