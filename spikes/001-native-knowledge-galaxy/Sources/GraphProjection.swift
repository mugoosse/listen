import Foundation
import ListenKit

enum GraphProjection {
    static func build(cards: [ContextCard], sources: [GraphNode] = [], sourceEdges: [GraphEdge] = [], includeHistory: Bool = false) -> GraphSnapshot {
        var nodes: [String: GraphNode] = [:]
        var edges: [String: GraphEdge] = [:]
        let cardsByID = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let names = cardsByID.mapValues(\.name)
        let sourceByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var processedEntries: Set<String> = []

        func evidence(_ values: [ContextCard.Evidence]) -> [GraphEvidence] {
            var seen: Set<String> = []
            return values.compactMap { value in
                guard !value.source.isEmpty else { return nil }
                let result = GraphEvidence(source: value.source, title: value.title, quote: value.quote, start: value.start)
                return seen.insert(evidenceKey(result)).inserted ? result : nil
            }
        }
        func evidenceKey(_ value: GraphEvidence) -> String {
            [value.source, value.title, value.quote, value.start.map { String($0) } ?? "", value.relativePath ?? ""].joined(separator: "\u{1F}")
        }
        func combinedEvidence(_ first: [GraphEvidence], _ second: [GraphEvidence]) -> [GraphEvidence] {
            var seen: Set<String> = []
            return (first + second).filter { value in
                return seen.insert(evidenceKey(value)).inserted
            }
        }
        func addNode(_ node: GraphNode, replacingMetadata: Bool = false) {
            guard !node.id.isEmpty else { return }
            if let existing = nodes[node.id] {
                nodes[node.id] = GraphNode(id: existing.id, kind: replacingMetadata ? node.kind : existing.kind,
                                           title: replacingMetadata ? node.title : existing.title, position: existing.position,
                                           evidence: combinedEvidence(existing.evidence, node.evidence))
            } else {
                nodes[node.id] = node
            }
        }
        func kind(for id: String, fallback: String = "claim") -> String {
            if let card = cardsByID[id] { return card.kind }
            if id.hasPrefix("rec:") { return "recording" }
            if id.hasPrefix("note:") { return "note" }
            if id.hasPrefix("person:") { return "person" }
            return fallback
        }
        func sourceNode(for support: GraphEvidence) -> GraphNode {
            if let supplied = sourceByID[support.source] { return supplied }
            let title: String
            if support.source.hasPrefix("person:") {
                title = displayName(support.source)
            } else {
                title = support.title.isEmpty ? support.source : support.title
            }
            return GraphNode(id: support.source, kind: kind(for: support.source), title: title, evidence: [support])
        }
        func label(for entry: ContextCard.Entry) -> String {
            var qualifiers: [String] = []
            if entry.polarity == "negative" { qualifiers.append("Negative") }
            qualifiers += ContextPresentation.qualifiers(modality: entry.modality, attribution: entry.attribution)
            let category = ContextPresentation.category(entry.predicate, polarity: entry.polarity)
            return qualifiers.isEmpty ? category : "\(category) [\(qualifiers.joined(separator: "; "))]"
        }

        // These source nodes have already been independently verified by the library loader.
        for source in sources.sorted(by: { $0.id < $1.id }) { addNode(source) }
        for edge in sourceEdges.sorted(by: { $0.id < $1.id }) where sourceByID[edge.source] != nil && sourceByID[edge.target] != nil {
            edges[edge.id] = edge
        }

        for card in cards.sorted(by: { $0.id < $1.id }) {
            let eligible = card.entries.filter { includeHistory || !["historical", "retracted"].contains($0.status) }
            for entry in eligible.sorted(by: { $0.id < $1.id }) {
                guard processedEntries.insert(entry.id).inserted else { continue }
                let supports = evidence(entry.evidence + (entry.changeEvidence ?? []))
                // The caller normally provides verified cards, but do not turn malformed data into unsupported claims.
                guard !supports.isEmpty, !entry.subject.isEmpty else { continue }

                addNode(GraphNode(id: entry.subject, kind: kind(for: entry.subject, fallback: card.kind), title: entry.subjectName), replacingMetadata: true)
                let claimID = "claim:\(entry.id)"
                let evidenceOrigin: String
                if entry.corrected || entry.object?.isEmpty != false {
                    // Replacement wording is authoritative, but it does not prove that its old object ID still applies.
                    addNode(GraphNode(id: claimID, kind: "claim", title: entry.text, evidence: supports))
                    edges["relationship:\(entry.id)"] = GraphEdge(id: "relationship:\(entry.id)", source: entry.subject, target: claimID,
                                                                      kind: "relationship", label: label(for: entry), status: entry.status, evidence: supports)
                    evidenceOrigin = claimID
                } else if let object = entry.object, !object.isEmpty {
                    let objectKind = entry.objectKind?.isEmpty == false ? entry.objectKind! : kind(for: object, fallback: "topic")
                    let objectTitle = names[object] ?? entry.text
                    addNode(GraphNode(id: object, kind: objectKind, title: objectTitle))
                    edges["relationship:\(entry.id)"] = GraphEdge(id: "relationship:\(entry.id)", source: entry.subject, target: object,
                                                                      kind: "relationship", label: label(for: entry), status: entry.status, evidence: supports)
                    evidenceOrigin = entry.subject
                } else {
                    continue
                }

                for support in supports {
                    guard !support.source.isEmpty else { continue }
                    addNode(sourceNode(for: support))
                    let id = "evidence:\(entry.id):\(support.source)"
                    let preserved = combinedEvidence(edges[id]?.evidence ?? [], [support])
                    edges[id] = GraphEdge(id: id, source: evidenceOrigin, target: support.source,
                                          kind: "evidence", label: "Evidence", status: entry.status, evidence: preserved)
                }
            }
        }

        let validEdges = edges.values.filter { nodes[$0.source] != nil && nodes[$0.target] != nil }
        return GraphSnapshot(nodes: nodes.values.sorted(by: { $0.id < $1.id }),
                             edges: validEdges.sorted(by: { $0.id < $1.id }),
                             label: includeHistory ? "Verified context graph including history" : "Verified current context graph")
    }

    private static func displayName(_ id: String) -> String {
        let component = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? id
        return component.replacingOccurrences(of: "-", with: " ")
    }
}
