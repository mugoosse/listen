import Foundation

enum GraphLayout {
    static func shellRadius(kind: String) -> Float? {
        switch kind {
        case "person": return 5
        case "note": return 9
        case "chat": return 13
        case "recording": return 17
        default: return nil
        }
    }

    /// The original hash-cluster layout is retained for callers that rely on its seed stability.
    static func apply(to snapshot: GraphSnapshot) -> GraphSnapshot {
        let nodes = snapshot.nodes.map { node in
            var positioned = node
            positioned.position = position(id: node.id, kind: node.kind)
            return positioned
        }.sorted(by: { $0.id < $1.id })
        return GraphSnapshot(nodes: nodes, edges: snapshot.edges.sorted(by: { $0.id < $1.id }), label: snapshot.label)
    }

    /// A bounded, one-shot relaxation for the approved spherical presentation shells.
    static func relax(to snapshot: GraphSnapshot, iterations: Int = 18) -> GraphSnapshot {
        var nodes = snapshot.nodes.sorted { $0.id < $1.id }
        var indices: [String: Int] = [:]
        var anchors = Array(repeating: SIMD3<Float>.zero, count: nodes.count)
        for index in nodes.indices {
            if nodes[index].kind == "device" { nodes[index].position = .zero; continue }
            guard let radius = shellRadius(kind: nodes[index].kind) else { continue }
            let direction = seedDirection(id: nodes[index].id)
            anchors[index] = direction
            nodes[index].position = direction * radius
            indices[nodes[index].id] = index
        }
        let edges = snapshot.edges.sorted { $0.id < $1.id }
        let count = max(0, min(iterations, 24))
        guard count > 0 else { return GraphSnapshot(nodes: nodes, edges: edges, label: snapshot.label) }

        for _ in 0..<count {
            var delta = Array(repeating: SIMD3<Float>.zero, count: nodes.count)
            // Existing graph edges are the only attractive relationships.
            for edge in edges {
                guard let a = indices[edge.source], let b = indices[edge.target], a != b else { continue }
                let da = unit(nodes[a].position)
                let db = unit(nodes[b].position)
                delta[a] += tangent(db - da * dot(db, da), at: da) * 0.12
                delta[b] += tangent(da - db * dot(da, db), at: db) * 0.12
            }
            // Fixed-resolution unit-sphere buckets bound repulsion work instead of comparing every pair.
            var buckets: [Cell: [Int]] = [:]
            for index in nodes.indices where indices[nodes[index].id] != nil {
                buckets[cell(for: unit(nodes[index].position)), default: []].append(index)
            }
            // Sorted node iteration plus fixed cell order avoids randomized Dictionary summation.
            // Inspect at most 96 neighbor candidates per node, even for a dense coincident cluster.
            for a in nodes.indices where indices[nodes[a].id] != nil {
                let da = unit(nodes[a].position)
                var inspected = 0
                neighbors: for neighbor in cell(for: da).neighbors {
                    guard let others = buckets[neighbor] else { continue }
                    for b in others where a < b {
                        inspected += 1
                        let db = unit(nodes[b].position)
                        let separation = da - db
                        let distanceSquared = max(0.015, dot(separation, separation))
                        if distanceSquared < 0.24 {
                            delta[a] += tangent(separation / distanceSquared, at: da) * 0.018
                            delta[b] += tangent(-separation / distanceSquared, at: db) * 0.018
                        }
                        if inspected >= 96 { break neighbors }
                    }
                }
            }
            for index in nodes.indices where indices[nodes[index].id] != nil {
                let direction = unit(nodes[index].position)
                delta[index] += tangent(anchors[index] - direction * dot(anchors[index], direction), at: direction) * 0.035
                let next = unit(direction + delta[index])
                nodes[index].position = next * (shellRadius(kind: nodes[index].kind) ?? 0)
            }
        }
        return GraphSnapshot(nodes: nodes, edges: edges, label: snapshot.label)
    }

    private struct Cell: Hashable {
        let x: Int; let y: Int; let z: Int
        var neighbors: [Cell] {
            (-1...1).flatMap { dx in (-1...1).flatMap { dy in (-1...1).map { dz in Cell(x: x + dx, y: y + dy, z: z + dz) } } }
        }
    }

    private static func cell(for direction: SIMD3<Float>) -> Cell {
        Cell(x: Int(floor(direction.x * 8)), y: Int(floor(direction.y * 8)), z: Int(floor(direction.z * 8)))
    }

    private static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func unit(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let magnitude = sqrt(max(0, dot(value, value)))
        return magnitude > 0.000_001 ? value / magnitude : SIMD3<Float>(0, 1, 0)
    }
    private static func tangent(_ value: SIMD3<Float>, at direction: SIMD3<Float>) -> SIMD3<Float> {
        value - direction * dot(value, direction)
    }
    private static func avalanche(_ value: UInt64) -> UInt64 {
        var x = value
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        return x ^ (x >> 31)
    }
    private static func seedDirection(id: String) -> SIMD3<Float> {
        let first = avalanche(hash(id))
        let second = avalanche(hash("sphere:\(id)"))
        let z = Float(Double(first) / Double(UInt64.max) * 2 - 1)
        let angle = Float(Double(second) / Double(UInt64.max) * Double.pi * 2)
        let radius = sqrt(max(0, 1 - z * z))
        return SIMD3<Float>(cos(angle) * radius, z, sin(angle) * radius)
    }

    private static func position(id: String, kind: String) -> SIMD3<Float> {
        let cluster = hash(kind)
        let point = hash(id)
        let clusterAngle = Float(cluster % 360) * .pi / 180
        let pointAngle = Float(point % 360) * .pi / 180
        let clusterRadius = Float(5 + ((cluster >> 12) % 7))
        let localRadius = Float(1 + ((point >> 12) % 1_000)) / 1_000 * 2
        return SIMD3<Float>(cos(clusterAngle) * clusterRadius + cos(pointAngle) * localRadius,
                            Float(Int((point >> 24) % 2_001) - 1_000) / 1_000 * 2,
                            sin(clusterAngle) * clusterRadius + sin(pointAngle) * localRadius)
    }

    /// FNV-1a is fixed across launches, unlike Swift's deliberately randomized Hasher.
    private static func hash(_ value: String) -> UInt64 {
        var result: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { result ^= UInt64(byte); result &*= 1_099_511_628_211 }
        return result
    }
}
