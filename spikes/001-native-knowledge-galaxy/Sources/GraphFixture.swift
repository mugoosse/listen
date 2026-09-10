import Foundation

enum GraphFixture {
    static func makeGalaxy(nodeCount: Int = 80) -> GraphSnapshot {
        let count = max(3, min(1200, nodeCount) - 1)
        let kinds = ["person", "note", "chat", "recording"]
        let people = ["Ari Chen", "Morgan Bell", "Samira Patel", "Jonas Reed", "Casey Wright"]
        let themes = ["Launch planning", "Research synthesis", "Customer discovery", "Weekly review", "Design critique"]
        var nodes: [GraphNode] = []
        for index in 0..<count {
            let kind = kinds[index % kinds.count]
            let group = (index / kinds.count) % themes.count
            let title: String
            switch kind {
            case "person": title = people[group]
            case "note": title = "\(themes[group]) notes"
            case "chat": title = "Ask: \(themes[group])"
            default: title = "\(themes[group]) recording"
            }
            let evidence = (kind == "note" || kind == "recording")
                ? [GraphEvidence(source: "synthetic:\(kind):\(index)", title: title, quote: "Synthetic fixture evidence.", start: Double(index), relativePath: nil)]
                : []
            nodes.append(GraphNode(id: "synthetic:\(kind):\(index)", kind: kind, title: title, evidence: evidence))
        }
        var edges: [GraphEdge] = []
        for group in 0..<((count + 3) / 4) {
            let groupNodes = Array(nodes[(group * 4)..<min(count, group * 4 + 4)])
            let person = groupNodes.first(where: { $0.kind == "person" })
            let note = groupNodes.first(where: { $0.kind == "note" })
            let chat = groupNodes.first(where: { $0.kind == "chat" })
            let recording = groupNodes.first(where: { $0.kind == "recording" })
            let pairs = [(person, note), (note, chat), (person, recording)]
            for (offset, pair) in pairs.enumerated() {
                guard let source = pair.0, let target = pair.1 else { continue }
                edges.append(GraphEdge(id: "synthetic-theme:\(group):\(offset)", source: source.id, target: target.id,
                                       kind: offset == 2 ? "source-link" : "relationship", label: "Synthetic \(themes[group % themes.count]) link",
                                       status: "synthetic", evidence: source.evidence + target.evidence))
            }
        }
        let raw = GraphSnapshot(nodes: nodes, edges: edges, label: "Synthetic spherical galaxy fixture. No real source evidence files.")
        return GraphScene.make(snapshot: raw)
    }

    static func make(nodeCount: Int = 80) -> GraphSnapshot {
        let count = max(4, nodeCount)
        let kinds = ["person", "project", "organization", "topic", "recording", "note"]
        var nodes: [GraphNode] = []
        for index in 0..<count {
            let kind = kinds[index % kinds.count]
            let id = "synthetic:\(kind):\(index)"
            let evidence: [GraphEvidence]
            if kind == "recording" || kind == "note" {
                evidence = [GraphEvidence(source: "synthetic-source-\(index)", title: "Synthetic \(kind) \(index)",
                                          quote: "Synthetic evidence \(index).", start: Double(index), relativePath: nil)]
            } else {
                evidence = []
            }
            nodes.append(GraphNode(id: id, kind: kind, title: "Synthetic \(kind) \(index)", evidence: evidence))
        }
        var edges: [GraphEdge] = []
        for index in 1..<count {
            let source = nodes[index - 1]
            let target = nodes[index]
            let evidence = source.evidence + target.evidence
            edges.append(GraphEdge(id: "synthetic-edge-\(index)", source: source.id, target: target.id,
                                   kind: index % 3 == 0 ? "source-link" : "relationship",
                                   label: "Synthetic link \(index)", status: "synthetic", evidence: evidence))
        }
        return GraphLayout.apply(to: GraphSnapshot(nodes: nodes, edges: edges,
                                                    label: "Synthetic graph fixture. No real source evidence files."))
    }
}
