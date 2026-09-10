import Foundation
import ListenKit

@main
struct GraphShellTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func testShellRadiiAreExactAndOrdered() {
        let radii = ["person", "note", "chat", "recording"].compactMap(GraphLayout.shellRadius)
        require(radii == [5, 9, 13, 17], "shell radii must be 5, 9, 13, 17")
        require(GraphLayout.shellRadius(kind: "project") == nil, "unsupported kinds must not receive a shell")
    }

    static func testSceneAddsDeviceAndOmitsUnsupportedTypes() {
        let input = GraphSnapshot(
            nodes: [
                GraphNode(id: "recording:r", kind: "recording", title: "Planning review"),
                GraphNode(id: "project:p", kind: "project", title: "Atlas"),
                GraphNode(id: "person:a", kind: "person", title: "Ari"),
                GraphNode(id: "note:n", kind: "note", title: "Launch notes"),
                GraphNode(id: "chat:c", kind: "chat", title: "Ask: release plan")
            ],
            edges: [
                GraphEdge(id: "actual", source: "person:a", target: "note:n", kind: "evidence", label: "Evidence", status: "current"),
                GraphEdge(id: "hidden", source: "project:p", target: "note:n", kind: "relationship", label: "Hidden", status: "current")
            ], label: "Verified graph")
        let scene = GraphScene.make(snapshot: input, deviceTitle: "Listen · Test Mac")
        let ids = scene.nodes.map(\.id)
        require(ids == ["chat:c", "note:n", "person:a", "recording:r", "view:current-device"], "scene must sort known nodes and add exactly one device")
        let device = scene.nodes.first(where: { $0.id == "view:current-device" })
        require(device?.kind == "device" && device?.title == "Listen · Test Mac" && device?.position == .zero && device?.evidence.isEmpty == true, "device is a presentation-only origin")
        require(scene.edges.map(\.id) == ["actual"], "only actual edges with visible endpoints may remain")
        require(!scene.edges.contains { $0.source == "view:current-device" || $0.target == "view:current-device" }, "device must not gain factual edges")
        for node in scene.nodes where node.kind != "device" {
            require(abs(distance(node.position, .zero) - GraphLayout.shellRadius(kind: node.kind)!) < 0.001,
                    "Scene projection must place real zero-position input nodes onto shells, not only synthetic fixtures")
        }
        require(scene.label.contains("1 unsupported"), "label must truthfully disclose omitted source types")
    }

    static func testGalaxyFixtureHasOnlyShellContentAndNoDeviceEdges() {
        let galaxy = GraphFixture.makeGalaxy(nodeCount: 24)
        require(galaxy.label.localizedCaseInsensitiveContains("synthetic"), "galaxy must disclose synthetic data")
        let device = galaxy.nodes.first(where: { $0.id == "view:current-device" })
        require(device?.position == .zero && device?.evidence.isEmpty == true, "galaxy device must be presentation-only")
        let shellNodes = galaxy.nodes.filter { $0.kind != "device" }
        require(Set(shellNodes.map(\.kind)) == ["person", "note", "chat", "recording"], "galaxy must contain only the four approved shells")
        for node in shellNodes {
            let radius = sqrt(node.position.x * node.position.x + node.position.y * node.position.y + node.position.z * node.position.z)
            require(abs(radius - (GraphLayout.shellRadius(kind: node.kind) ?? -1)) < 0.001, "fixture node must lie on its exact shell")
            require(node.evidence.allSatisfy { $0.relativePath == nil }, "synthetic fixture has no real path")
        }
        require(galaxy.edges.allSatisfy { $0.source != "view:current-device" && $0.target != "view:current-device" }, "fixture must not fabricate center edges")
    }

    static func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let delta = a - b
        return sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
    }

    static func testSceneIsDeterministicAndBounded() {
        let nodes = (0..<1_300).map { index in
            GraphNode(id: "node:\(index)", kind: ["person", "note", "chat", "recording", "claim"][index % 5], title: "Node \(index)")
        }
        let edges = (1..<1_300).map { index in
            GraphEdge(id: "edge:\(index)", source: "node:\(index - 1)", target: "node:\(index)", kind: "evidence", label: "Actual", status: "current")
        }
        let source = GraphSnapshot(nodes: nodes, edges: edges, label: "Source")
        let first = GraphScene.make(snapshot: source, maximumNodes: 1_000)
        let reversed = GraphScene.make(snapshot: GraphSnapshot(nodes: nodes.reversed(), edges: edges.reversed(), label: "Source"), maximumNodes: 1_000)
        require(first.nodes.count == 1_000 && first.nodes.map(\.id) == reversed.nodes.map(\.id), "projection must be stable and include the device within its bound")
        let ids = Set(first.nodes.map(\.id))
        require(first.edges.allSatisfy { ids.contains($0.source) && ids.contains($0.target) }, "bounded scene edges must retain valid endpoints")
        require(first.label.contains("260 unsupported") && first.label.contains("41 nodes omitted"), "label must disclose every presentation omission")
        let laidOut = GraphLayout.relax(to: first)
        require(laidOut.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite }, "bounded relaxation must remain finite at presentation scale")
    }

    static func testRelaxationIsFiniteDeterministicAndUsesRealEdges() {
        let a = GraphNode(id: "person:alpha", kind: "person", title: "Alpha")
        let b = GraphNode(id: "person:bravo", kind: "person", title: "Bravo")
        let c = GraphNode(id: "person:charlie", kind: "person", title: "Charlie")
        let edge = GraphEdge(id: "actual-edge", source: a.id, target: b.id, kind: "relationship", label: "Actual", status: "current")
        let source = GraphSnapshot(nodes: [c, a, b], edges: [edge], label: "Force")
        let seed = GraphLayout.relax(to: source, iterations: 0)
        let relaxed = GraphLayout.relax(to: source)
        let reordered = GraphLayout.relax(to: GraphSnapshot(nodes: [b, c, a], edges: [edge], label: "Force"))
        let seeded = Dictionary(uniqueKeysWithValues: seed.nodes.map { ($0.id, $0.position) })
        let result = Dictionary(uniqueKeysWithValues: relaxed.nodes.map { ($0.id, $0.position) })
        let repeatResult = Dictionary(uniqueKeysWithValues: reordered.nodes.map { ($0.id, $0.position) })
        require(distance(result[a.id]!, result[b.id]!) < distance(seeded[a.id]!, seeded[b.id]!), "a real edge must attract its endpoints")
        require(result == repeatResult, "relaxation must be deterministic across input order")
        for node in relaxed.nodes {
            let radius = sqrt(node.position.x * node.position.x + node.position.y * node.position.y + node.position.z * node.position.z)
            require(node.position.x.isFinite && node.position.y.isFinite && node.position.z.isFinite && abs(radius - 5) < 0.001, "relaxed shell positions must remain finite and normalized")
        }
        let edgeFree = GraphLayout.relax(to: GraphSnapshot(nodes: [a, b, c], edges: [], label: "No edges"))
        let edgeFreePositions = Dictionary(uniqueKeysWithValues: edgeFree.nodes.map { ($0.id, $0.position) })
        require(distance(edgeFreePositions[a.id]!, edgeFreePositions[b.id]!) > distance(result[a.id]!, result[b.id]!), "unconnected nodes must not receive fabricated attraction")
    }

    static func testRelaxationHandlesEmptySingleAndDuplicateNodes() {
        for snapshot in [
            GraphSnapshot(nodes: [], edges: [], label: "Empty"),
            GraphSnapshot(nodes: [GraphNode(id: "person:one", kind: "person", title: "One")], edges: [], label: "Single"),
            GraphSnapshot(nodes: [GraphNode(id: "person:duplicate", kind: "person", title: "First"), GraphNode(id: "person:duplicate", kind: "person", title: "Second")], edges: [], label: "Duplicate")
        ] {
            let laidOut = GraphLayout.relax(to: snapshot)
            require(laidOut.nodes.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite }, "all degenerate layouts must be finite")
        }
    }

    static func main() {
        testShellRadiiAreExactAndOrdered()
        testSceneAddsDeviceAndOmitsUnsupportedTypes()
        testGalaxyFixtureHasOnlyShellContentAndNoDeviceEdges()
        testSceneIsDeterministicAndBounded()
        testRelaxationIsFiniteDeterministicAndUsesRealEdges()
        let adjacentIDs = (0..<256).map { GraphNode(id: "person:\($0)", kind: "person", title: "P \($0)") }
        let seededCloud = GraphLayout.relax(to: GraphSnapshot(nodes: adjacentIDs, edges: [], label: "Seed"), iterations: 0)
        let mean = seededCloud.nodes.reduce(SIMD3<Float>.zero) { $0 + $1.position / 5 } / Float(seededCloud.nodes.count)
        require(distance(mean, .zero) < 0.2, "Adjacent IDs must seed across the sphere, not collapse into one FNV hash sector")
        let cloud = GraphLayout.relax(to: GraphSnapshot(nodes: adjacentIDs, edges: [], label: "Cloud"))
        let reversedCloud = GraphLayout.relax(to: GraphSnapshot(nodes: adjacentIDs.reversed(), edges: [], label: "Cloud"))
        require(cloud.nodes.map(\.position) == reversedCloud.nodes.map(\.position), "Crowded relaxation must remain exactly deterministic")
        testRelaxationHandlesEmptySingleAndDuplicateNodes()
        print("Graph shell tests passed")
    }
}
