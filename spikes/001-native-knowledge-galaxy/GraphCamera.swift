import Foundation
import simd

struct GraphRay: Sendable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
}

struct GraphPickNode: Sendable {
    var id: String
    var position: SIMD3<Float>
    var radius: Float
}

enum GraphPicking {
    /// Returns the front-most sphere hit along the same ray used by rendering's camera matrices.
    static func nearestHit(ray: GraphRay, nodes: [GraphPickNode]) -> GraphPickNode? {
        var nearest: (node: GraphPickNode, distance: Float)?
        for node in nodes where node.radius > 0 {
            let offset = ray.origin - node.position
            let b = simd_dot(offset, ray.direction)
            let c = simd_dot(offset, offset) - node.radius * node.radius
            let discriminant = b * b - c
            guard discriminant >= 0 else { continue }
            let root = sqrt(discriminant)
            let nearDistance = -b - root
            let farDistance = -b + root
            let distance = nearDistance >= 0 ? nearDistance : farDistance
            guard distance >= 0 else { continue }
            if nearest == nil || distance < nearest!.distance {
                nearest = (node, distance)
            }
        }
        return nearest?.node
    }
}

struct GraphCamera: Sendable {
    static let defaultDistance: Float = 18
    static let minimumDistance: Float = 2.5
    static let maximumDistance: Float = 90

    private(set) var yaw: Float = 0
    private(set) var pitch: Float = 0.28
    private(set) var distance: Float = GraphCamera.defaultDistance
    private(set) var target = SIMD3<Float>(repeating: 0)

    var eye: SIMD3<Float> {
        let horizontal = cos(pitch) * distance
        return target + SIMD3<Float>(sin(yaw) * horizontal, sin(pitch) * distance, cos(yaw) * horizontal)
    }

    mutating func orbit(deltaX: Float, deltaY: Float) {
        yaw += deltaX * 0.008
        pitch = min(max(pitch + deltaY * 0.008, -1.45), 1.45)
    }

    mutating func zoom(delta: Float) {
        distance = min(max(distance * exp(delta * 0.0015), Self.minimumDistance), Self.maximumDistance)
    }

    mutating func pan(deltaX: Float, deltaY: Float, viewportSize: SIMD2<Float>) {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, forward))
        let scale = 2 * distance * tan(Float.pi / 8) / viewportSize.y
        target += (-right * deltaX + up * deltaY) * scale
    }

    mutating func frameGalaxy(aspect: Float = 1) {
        frame(positions: [SIMD3<Float>(17, 0, 0), SIMD3<Float>(-17, 0, 0),
                          SIMD3<Float>(0, 17, 0), SIMD3<Float>(0, -17, 0),
                          SIMD3<Float>(0, 0, 17), SIMD3<Float>(0, 0, -17)], aspect: aspect)
    }

    mutating func frame(positions: [SIMD3<Float>], aspect: Float = 1) {
        guard let first = positions.first else { reset(); return }
        var low = first, high = first
        for position in positions { low = simd_min(low, position); high = simd_max(high, position) }
        target = (low + high) * 0.5
        let radius = positions.map { simd_length($0 - target) }.max() ?? 1
        let halfAngle = atan(tan(Float.pi / 8) * min(max(aspect, 0.1), 1))
        distance = min(Self.maximumDistance, max(Self.minimumDistance, (radius + 0.5) / sin(halfAngle) * 1.12))
    }

    mutating func reset() {
        yaw = 0
        pitch = 0.28
        distance = Self.defaultDistance
        target = .zero
    }

    func focused(on position: SIMD3<Float>, distance desired: Float) -> GraphCamera {
        var next = self
        next.target = position
        next.distance = min(Self.maximumDistance, max(Self.minimumDistance, desired))
        return next
    }

    func interpolated(to goal: GraphCamera, progress: Float) -> GraphCamera {
        let t = min(1, max(0, progress))
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        var result = self
        result.target += (goal.target - target) * eased
        result.distance += (goal.distance - distance) * eased
        result.yaw += (goal.yaw - yaw) * eased
        result.pitch += (goal.pitch - pitch) * eased
        return result
    }

    func viewMatrix() -> simd_float4x4 {
        Self.lookAt(eye: eye, target: target, up: SIMD3<Float>(0, 1, 0))
    }

    static func perspectiveMatrix(fovyRadians: Float, aspect: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
        let y = 1 / tan(fovyRadians * 0.5)
        let x = y / max(aspect, 0.0001)
        let z = farZ / (nearZ - farZ)
        return simd_float4x4(
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, z * nearZ, 0)
        )
    }

    static func ray(screenPoint: SIMD2<Float>, viewportSize: SIMD2<Float>, view: simd_float4x4, projection: simd_float4x4) -> GraphRay? {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return nil }
        let ndc = SIMD2<Float>(2 * screenPoint.x / viewportSize.x - 1, 1 - 2 * screenPoint.y / viewportSize.y)
        let inverse = simd_inverse(projection * view)
        let near = inverse * SIMD4<Float>(ndc.x, ndc.y, 0, 1)
        let far = inverse * SIMD4<Float>(ndc.x, ndc.y, 1, 1)
        guard abs(near.w) > 0.00001, abs(far.w) > 0.00001 else { return nil }
        let origin = SIMD3<Float>(near.x, near.y, near.z) / near.w
        let end = SIMD3<Float>(far.x, far.y, far.z) / far.w
        let direction = end - origin
        guard simd_length_squared(direction) > 0.000001 else { return nil }
        return GraphRay(origin: origin, direction: simd_normalize(direction))
    }

    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let cameraUp = simd_cross(right, forward)
        return simd_float4x4(
            SIMD4<Float>(right.x, cameraUp.x, -forward.x, 0),
            SIMD4<Float>(right.y, cameraUp.y, -forward.y, 0),
            SIMD4<Float>(right.z, cameraUp.z, -forward.z, 0),
            SIMD4<Float>(-simd_dot(right, eye), -simd_dot(cameraUp, eye), simd_dot(forward, eye), 1)
        )
    }
}
