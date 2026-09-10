import Foundation
import ListenKit

struct GraphLoadResult {
    var snapshot: GraphSnapshot
    var synthetic: Bool
    var verifiedCards: Int
    var skippedSources: Int
    var projectionPresent: Bool
}

enum GraphBridge {
    static func load(root: URL?, nodeCount: Int, includeHistory: Bool) throws -> GraphLoadResult {
        guard let root else {
            return GraphLoadResult(snapshot: GraphFixture.makeGalaxy(nodeCount: nodeCount), synthetic: true, verifiedCards: 0, skippedSources: 0, projectionPresent: false)
        }
        let input = try GraphLibrary.read(root: root)
        let sources = input.sources.map { source in
            GraphNode(id: source.id, kind: source.kind, title: source.title, evidence: [
                GraphEvidence(source: source.id, title: source.title, quote: "", start: nil, relativePath: source.relativePath)
            ])
        }
        let edges = input.sources.flatMap { source in
            source.recordings.map { recording in
                GraphEdge(id: "source-link:\(source.id):\(recording)", source: source.id, target: "rec:" + recording,
                    kind: "source-link", label: "References recording", status: "explicit", evidence: [
                        GraphEvidence(source: source.id, title: source.title, quote: "", start: nil, relativePath: source.relativePath)
                    ])
            }
        }
        var graph = GraphProjection.build(cards: input.cards, sources: sources, sourceEdges: edges, includeHistory: includeHistory)
        let paths = Dictionary(input.sources.map { ($0.id, $0.relativePath) }, uniquingKeysWith: { a, _ in a })
        func attach(_ items: [GraphEvidence]) -> [GraphEvidence] {
            items.map { item in var value = item; value.relativePath = value.relativePath ?? paths[value.source]; return value }
        }
        for i in graph.nodes.indices { graph.nodes[i].evidence = attach(graph.nodes[i].evidence) }
        for i in graph.edges.indices { graph.edges[i].evidence = attach(graph.edges[i].evidence) }
        graph.label = "Read-only local library. \(input.cards.count) verified memory cards. " +
            (input.snapshotPresent ? "Owner projection present." : "No owner memory projection yet.") + " Reload to refresh."
        return GraphLoadResult(snapshot: GraphScene.make(snapshot: graph), synthetic: false, verifiedCards: input.cards.count,
            skippedSources: input.skipped, projectionPresent: input.snapshotPresent)
    }
}
