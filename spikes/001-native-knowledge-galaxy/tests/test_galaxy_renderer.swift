import Foundation

@main struct GalaxyRendererTests {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("listen-galaxy-renderer-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = GraphSnapshot(
            nodes: [
                GraphNode(id: "view:current-device", kind: "device", title: "This Mac", position: .zero),
                GraphNode(id: "person:ada", kind: "person", title: "Ada", position: SIMD3<Float>(5, 0, 0)),
                GraphNode(id: "note:one", kind: "note", title: "One", position: SIMD3<Float>(0, 2, 9)),
            ],
            edges: [GraphEdge(id: "link", source: "person:ada", target: "note:one", kind: "relationship", label: "related", status: "synthetic")],
            label: "GPU renderer test")
        let first = root.appendingPathComponent("zero.png")
        let later = root.appendingPathComponent("later.png")
        _ = try GraphGPUProbe.run(snapshot: snapshot, output: first, frames: 1, time: 0)
        _ = try GraphGPUProbe.run(snapshot: snapshot, output: later, frames: 1, time: 10)
        let a = try Data(contentsOf: first), b = try Data(contentsOf: later)
        guard a.count > 1000, b.count > 1000 else { fatalError("GPU export must write PNGs") }
        guard a != b else { fatalError("fixed renderer time must change actual GPU pixels") }
        try GraphGPUProbe.exportFrames(snapshot: snapshot, directory: root.appendingPathComponent("frames"), count: 2, fps: 30)
        for index in 0..<2 {
            let url = root.appendingPathComponent("frames/frame-\(String(format: "%04d", index)).png")
            guard FileManager.default.fileExists(atPath: url.path) else { fatalError("missing sequential exported frame \(index)") }
        }
        print("PASS: GPU time changes pixels and sequential PNG frames export")
    }
}
