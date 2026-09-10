import Foundation

struct GraphEvidence: Codable, Sendable {
    var source: String
    var title: String
    var quote: String
    var start: Double?
    var relativePath: String?

    init(source: String, title: String, quote: String, start: Double?, relativePath: String? = nil) {
        self.source = source
        self.title = title
        self.quote = quote
        self.start = start
        self.relativePath = relativePath
    }
}

struct GraphNode: Codable, Sendable {
    var id: String
    var kind: String
    var title: String
    var position: SIMD3<Float>
    var evidence: [GraphEvidence]

    init(id: String, kind: String, title: String, position: SIMD3<Float> = .zero, evidence: [GraphEvidence] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.position = position
        self.evidence = evidence
    }
}

struct GraphEdge: Codable, Sendable {
    var id: String
    var source: String
    var target: String
    var kind: String
    var label: String
    var status: String
    var evidence: [GraphEvidence]

    init(id: String, source: String, target: String, kind: String, label: String, status: String, evidence: [GraphEvidence] = []) {
        self.id = id
        self.source = source
        self.target = target
        self.kind = kind
        self.label = label
        self.status = status
        self.evidence = evidence
    }
}

struct GraphSnapshot: Codable, Sendable {
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var label: String

    init(nodes: [GraphNode], edges: [GraphEdge], label: String) {
        self.nodes = nodes
        self.edges = edges
        self.label = label
    }
}
