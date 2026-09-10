import Foundation
import Metal

@main struct RendererTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal required for renderer verification") }
        let renderer = try GraphRenderer(device: device)
        let snapshot = GraphSnapshot(nodes: [GraphNode(id: "center", kind: "person", title: "Synthetic center")], edges: [], label: "Synthetic picking test")
        renderer.update(snapshot: snapshot, selectionID: nil)
        let viewport = SIMD2<Float>(1280, 800), camera = GraphCamera()
        guard renderer.pick(screenPoint: [640, 400], viewportSize: viewport, camera: camera) == "center" else { fatalError("Center click must hit rendered node") }
        guard renderer.pick(screenPoint: [664, 400], viewportSize: viewport, camera: camera) == nil else { fatalError("Picking must not hit invisible area far outside the rendered node") }
        print("PASS: rendered-node picking bounds")
    }
}
