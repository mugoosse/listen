import Foundation

enum GraphScene {
    private static let deviceID = "view:current-device"
    private static let visibleKinds: Set<String> = ["person", "note", "chat", "recording"]

    /// Builds the device-centered presentation without changing the underlying graph.
    static func make(snapshot: GraphSnapshot, deviceTitle: String = "Listen · This Mac", maximumNodes: Int = 1200) -> GraphSnapshot {
        let sortedInput = snapshot.nodes.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.title < rhs.title
        }
        var seen: Set<String> = []
        let known = sortedInput.filter { node in
            node.id != deviceID && visibleKinds.contains(node.kind) && seen.insert(node.id).inserted
        }
        let unsupported = Set(sortedInput.filter { $0.id != deviceID && !visibleKinds.contains($0.kind) }.map(\.id)).count
        let capacity = max(0, maximumNodes - 1)
        let visible = Array(known.prefix(capacity))
        let visibleIDs = Set(visible.map(\.id))
        var edgeIDs: Set<String> = []
        let edges = snapshot.edges.sorted { lhs, rhs in
            if lhs.id != rhs.id { return lhs.id < rhs.id }
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            return lhs.target < rhs.target
        }.filter { edge in
            edge.source != deviceID && edge.target != deviceID &&
            visibleIDs.contains(edge.source) && visibleIDs.contains(edge.target) &&
            edgeIDs.insert(edge.id).inserted
        }
        let device = GraphNode(id: deviceID, kind: "device", title: deviceTitle, position: .zero, evidence: [])
        let omittedForLimit = max(0, known.count - visible.count)
        var omissions: [String] = []
        if unsupported > 0 { omissions.append("\(unsupported) unsupported source type\(unsupported == 1 ? "" : "s") omitted") }
        if omittedForLimit > 0 { omissions.append("\(omittedForLimit) node\(omittedForLimit == 1 ? "" : "s") omitted by presentation limit") }
        let suffix = omissions.isEmpty ? "" : " \(omissions.joined(separator: "; "))."
        return GraphLayout.relax(to: GraphSnapshot(nodes: (visible + [device]).sorted { $0.id < $1.id }, edges: edges,
                             label: snapshot.label + suffix))
    }
}
