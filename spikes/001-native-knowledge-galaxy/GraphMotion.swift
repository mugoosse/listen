import Foundation
import simd

/// A deliberately quiet, deterministic world rotation shared by Metal, labels, and picking.
/// It is a rigid rotation, so every layout shell keeps its exact radius.
enum GraphMotion {
    static func position(_ position: SIMD3<Float>, id: String, kind: String, time: Double) -> SIMD3<Float> {
        guard position != .zero, id != "view:current-device", kind != "device" else { return .zero }
        let transformed = matrix(time: time) * SIMD4<Float>(position, 1)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    static func matrix(time: Double) -> simd_float4x4 {
        let angle = Float(time) * 0.012
        guard angle != 0 else { return matrix_identity_float4x4 }
        let axis = simd_normalize(SIMD3<Float>(0.16, 1, 0.09))
        let c = cos(angle), s = sin(angle), t = 1 - c
        let x = axis.x, y = axis.y, z = axis.z
        return simd_float4x4(
            SIMD4<Float>(t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0),
            SIMD4<Float>(t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0),
            SIMD4<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0),
            SIMD4<Float>(0, 0, 0, 1))
    }
}
