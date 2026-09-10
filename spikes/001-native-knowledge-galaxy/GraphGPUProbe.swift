import AppKit
import Foundation
import Metal
import simd

/** Offscreen timing probe. Values are measured render-submit/wait time and Metal GPU duration, not display FPS. */
enum GraphGPUProbe {
    static func run(snapshot: GraphSnapshot, output: URL, frames: Int, time: Double = 0) throws -> [String: Double] {
        guard frames > 0 else { throw GraphGPUProbeError.invalidFrameCount }
        let context = try makeContext(snapshot: snapshot)
        var cpuTotal: Double = 0, gpuTotal: Double = 0
        for _ in 0..<frames {
            let commandBuffer = try render(context: context, time: time)
            cpuTotal += commandBuffer.1; gpuTotal += commandBuffer.0
        }
        try writePNG(texture: context.color, output: output)
        return ["cpu_ms_per_frame": cpuTotal * 1000 / Double(frames), "gpu_ms_per_frame": gpuTotal * 1000 / Double(frames), "frames": Double(frames), "width": Double(context.width), "height": Double(context.height)]
    }

    /// Renders deterministic, sequential 1280×800 PNG frames suitable for an external video encoder.
    static func exportFrames(snapshot: GraphSnapshot, directory: URL, count: Int = 90, fps: Double = 30) throws {
        guard count > 0 else { throw GraphGPUProbeError.invalidFrameCount }
        guard fps.isFinite, fps > 0 else { throw GraphGPUProbeError.invalidFrameRate }
        let context = try makeContext(snapshot: snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<count {
            _ = try render(context: context, time: Double(index) / fps)
            try writePNG(texture: context.color, output: directory.appendingPathComponent(String(format: "frame-%04d.png", index)))
        }
    }

    private struct Context { let renderer: GraphRenderer; let color: MTLTexture; let depth: MTLTexture; let camera: GraphCamera; let width: Int; let height: Int }
    private static func makeContext(snapshot: GraphSnapshot) throws -> Context {
        guard let device = MTLCreateSystemDefaultDevice() else { throw GraphGPUProbeError.metalUnavailable }
        let renderer = try GraphRenderer(device: device); renderer.update(snapshot: snapshot, selectionID: nil)
        let width = 1280, height = 800
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget]; colorDescriptor.storageMode = .shared
        guard let color = device.makeTexture(descriptor: colorDescriptor) else { throw GraphGPUProbeError.textureAllocation }
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depthDescriptor.usage = [.renderTarget]; depthDescriptor.storageMode = .private
        guard let depth = device.makeTexture(descriptor: depthDescriptor) else { throw GraphGPUProbeError.textureAllocation }
        var camera = GraphCamera(); camera.frameGalaxy(aspect: Float(width) / Float(height))
        return Context(renderer: renderer, color: color, depth: depth, camera: camera, width: width, height: height)
    }
    /// Returns (GPU duration, CPU submit/wait duration) after a completed real command buffer.
    private static func render(context: Context, time: Double) throws -> (Double, Double) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = context.color; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.006, green: 0.012, blue: 0.035, alpha: 1)
        pass.depthAttachment.texture = context.depth; pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .dontCare; pass.depthAttachment.clearDepth = 1
        guard let commandBuffer = context.renderer.commandQueue.makeCommandBuffer() else { throw GraphGPUProbeError.commandBuffer }
        let started = ProcessInfo.processInfo.systemUptime
        context.renderer.encode(commandBuffer: commandBuffer, renderPassDescriptor: pass, viewportSize: CGSize(width: context.width, height: context.height), camera: context.camera, time: time)
        commandBuffer.commit(); commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw GraphGPUProbeError.commandFailed(commandBuffer.error) }
        return (max(0, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime), ProcessInfo.processInfo.systemUptime - started)
    }
    private static func writePNG(texture: MTLTexture, output: URL) throws {
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        for index in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(index, index + 2) } // BGRA texture -> RGBA PNG
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bitmapFormat: [.alphaNonpremultiplied], bytesPerRow: width * 4, bitsPerPixel: 32), let destination = bitmap.bitmapData else { throw GraphGPUProbeError.pngEncoding }
        pixels.withUnsafeBytes { destination.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: pixels.count) }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw GraphGPUProbeError.pngEncoding }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output, options: .atomic)
    }
}

enum GraphGPUProbeError: LocalizedError {
    case invalidFrameCount, invalidFrameRate, metalUnavailable, textureAllocation, commandBuffer, commandFailed(Error?), pngEncoding
    var errorDescription: String? {
        switch self {
        case .invalidFrameCount: return "GPU probe needs at least one frame."
        case .invalidFrameRate: return "GPU frame export needs a positive finite frame rate."
        case .metalUnavailable: return "Metal is unavailable on this Mac."
        case .textureAllocation: return "GPU probe could not allocate its offscreen textures."
        case .commandBuffer: return "GPU probe could not create a Metal command buffer."
        case .commandFailed(let error): return "GPU probe command failed: \(error?.localizedDescription ?? "unknown Metal error")"
        case .pngEncoding: return "GPU probe could not encode its PNG."
        }
    }
}
