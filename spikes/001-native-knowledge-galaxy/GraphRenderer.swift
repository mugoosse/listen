import Foundation
import Metal
import MetalKit
import simd

enum GraphRendererError: LocalizedError {
    case noCommandQueue, shaderCompilation(Error), pipeline(Error), bufferAllocation
    var errorDescription: String? {
        switch self {
        case .noCommandQueue: return "Metal command queue could not be created."
        case .shaderCompilation(let error): return "Metal shader compilation failed: \(error.localizedDescription)"
        case .pipeline(let error): return "Metal render pipeline creation failed: \(error.localizedDescription)"
        case .bufferAllocation: return "Metal buffer allocation failed."
        }
    }
}

private struct GraphGPUNode { var position: SIMD3<Float>; var radius: Float; var color: SIMD4<Float> }
private struct GraphGPUEdgeVertex { var position: SIMD3<Float>; var color: SIMD4<Float> }
private struct GraphGPUUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var viewport: SIMD2<Float>
    var pointScale: Float
    var time: Float
    var padding: SIMD3<Float> = .zero
}

final class GraphRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    /// Receives asynchronous Metal execution failures without changing caller error handling.
    var onError: ((String) -> Void)?
    private let backgroundPipeline: MTLRenderPipelineState
    private let nodePipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState
    private let guidePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let overlayDepthState: MTLDepthStencilState
    private let quadBuffer: MTLBuffer
    private var nodeBuffer: MTLBuffer?
    private var edgeBuffer: MTLBuffer?
    private var guideBuffer: MTLBuffer?
    private(set) var nodes: [GraphNode] = []
    private var nodeGPU: [GraphGPUNode] = []
    private var edgeGPU: [GraphGPUEdgeVertex] = []
    private var selectionID: String?
    private var hoverID: String?

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw GraphRendererError.noCommandQueue }
        commandQueue = queue
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaderSource, options: nil) }
        catch { throw GraphRendererError.shaderCompilation(error) }
        func pipeline(_ vertex: String, _ fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            if blending {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            do { return try device.makeRenderPipelineState(descriptor: descriptor) }
            catch { throw GraphRendererError.pipeline(error) }
        }
        backgroundPipeline = try pipeline("backgroundVertex", "backgroundFragment", blending: false)
        nodePipeline = try pipeline("nodeVertex", "nodeFragment", blending: true)
        edgePipeline = try pipeline("edgeVertex", "edgeFragment", blending: true)
        guidePipeline = try pipeline("guideVertex", "guideFragment", blending: true)
        let depth = MTLDepthStencilDescriptor(); depth.depthCompareFunction = .lessEqual; depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else { throw GraphRendererError.bufferAllocation }
        depthState = state
        let overlay = MTLDepthStencilDescriptor(); overlay.depthCompareFunction = .lessEqual; overlay.isDepthWriteEnabled = false
        guard let overlayState = device.makeDepthStencilState(descriptor: overlay) else { throw GraphRendererError.bufferAllocation }
        overlayDepthState = overlayState
        let quad: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1)]
        guard let buffer = device.makeBuffer(bytes: quad, length: MemoryLayout<SIMD2<Float>>.stride * quad.count, options: .storageModeShared) else { throw GraphRendererError.bufferAllocation }
        quadBuffer = buffer
        guideBuffer = Self.buffer(device: device, values: Self.sphericalGuides())
    }

    func update(snapshot: GraphSnapshot, selectionID: String?, hoverID: String? = nil) {
        nodes = snapshot.nodes; self.selectionID = selectionID; self.hoverID = hoverID
        let neighbors = Set(snapshot.edges.compactMap { edge -> String? in
            guard let selectionID else { return nil }
            if edge.source == selectionID { return edge.target }; if edge.target == selectionID { return edge.source }; return nil
        })
        nodeGPU = snapshot.nodes.map { node in
            let focused = selectionID == nil || node.id == selectionID || neighbors.contains(node.id)
            let base = Self.nodeColor(kind: node.kind)
            let dimmed = SIMD4<Float>(base.x * 0.28, base.y * 0.28, base.z * 0.28, 0.32)
            return GraphGPUNode(position: node.position, radius: Self.coreRadius(id: node.id, kind: node.kind, selectionID: selectionID, hoverID: hoverID), color: focused ? base : dimmed)
        }
        let byID = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        edgeGPU.removeAll(keepingCapacity: true)
        for edge in snapshot.edges {
            guard let source = byID[edge.source], let target = byID[edge.target] else { continue }
            let connected = selectionID != nil && (edge.source == selectionID || edge.target == selectionID)
            var color = Self.edgeColor(kind: edge.kind)
            if connected { color.w = 0.72 }
            else if selectionID != nil { color = SIMD4<Float>(color.x * 0.24, color.y * 0.24, color.z * 0.24, 0.10) }
            else { color.w = 0.13 }
            edgeGPU.append(GraphGPUEdgeVertex(position: source.position, color: color))
            edgeGPU.append(GraphGPUEdgeVertex(position: target.position, color: color))
        }
        nodeBuffer = Self.buffer(device: device, values: nodeGPU)
        edgeBuffer = Self.buffer(device: device, values: edgeGPU)
    }

    func draw(renderPassDescriptor: MTLRenderPassDescriptor, drawable: CAMetalDrawable?, viewportSize: CGSize, camera: GraphCamera, time: Double = 0) {
        guard viewportSize.width > 0, viewportSize.height > 0, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            if buffer.status == .error { self?.onError?((buffer.error ?? GraphRendererError.bufferAllocation).localizedDescription) }
        }
        encode(commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor, viewportSize: viewportSize, camera: camera, time: time)
        if let drawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }

    func encode(commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor, viewportSize: CGSize, camera: GraphCamera, time: Double = 0) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        let aspect = Float(viewportSize.width / max(viewportSize.height, 1))
        var uniforms = GraphGPUUniforms(viewProjection: GraphCamera.perspectiveMatrix(fovyRadians: .pi / 4, aspect: aspect, nearZ: 0.1, farZ: 200) * camera.viewMatrix(), model: Self.motionMatrix(time: time), viewport: SIMD2(Float(viewportSize.width), Float(viewportSize.height)), pointScale: Float(viewportSize.height) * 0.5 / tan(Float.pi / 8), time: Float(time))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GraphGPUUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GraphGPUUniforms>.stride, index: 2)
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.setDepthStencilState(overlayDepthState)
        if let guideBuffer {
            encoder.setRenderPipelineState(guidePipeline); encoder.setVertexBuffer(guideBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: guideBuffer.length / MemoryLayout<SIMD3<Float>>.stride)
        }
        if let edgeBuffer, !edgeGPU.isEmpty {
            encoder.setRenderPipelineState(edgePipeline); encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeGPU.count)
        }
        if let nodeBuffer, !nodeGPU.isEmpty {
            encoder.setDepthStencilState(depthState); encoder.setRenderPipelineState(nodePipeline)
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0); encoder.setVertexBuffer(nodeBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: nodeGPU.count)
        }
        encoder.endEncoding()
    }

    func pick(screenPoint: SIMD2<Float>, viewportSize: SIMD2<Float>, camera: GraphCamera, time: Double = 0) -> String? {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return nil }
        let projection = GraphCamera.perspectiveMatrix(fovyRadians: .pi / 4, aspect: viewportSize.x / viewportSize.y, nearZ: 0.1, farZ: 200)
        let matrix = projection * camera.viewMatrix(); var best: (String, Float)?
        for node in nodes {
            let position = Self.motionPosition(node.position, id: node.id, kind: node.kind, time: time)
            let clip = matrix * SIMD4<Float>(position, 1)
            guard clip.w > 0, clip.z >= 0, clip.z <= clip.w else { continue }
            let center = SIMD2<Float>((clip.x / clip.w + 1) * viewportSize.x / 2, (1 - clip.y / clip.w) * viewportSize.y / 2)
            let radius = Self.coreRadius(id: node.id, kind: node.kind, selectionID: selectionID, hoverID: hoverID)
            let pixels = radius * viewportSize.y * 0.5 * projection[1][1] / clip.w
            guard simd_length_squared(screenPoint - center) <= pixels * pixels else { continue }
            let depth = clip.z / clip.w; if best == nil || depth < best!.1 { best = (node.id, depth) }
        }
        return best?.0
    }

    // Kept byte-for-byte equivalent to GraphMotion so this renderer also compiles in the legacy standalone probe command.
    private static func motionPosition(_ position: SIMD3<Float>, id: String, kind: String, time: Double) -> SIMD3<Float> {
        guard position != .zero, id != "view:current-device", kind != "device" else { return .zero }
        let transformed = motionMatrix(time: time) * SIMD4<Float>(position, 1)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
    private static func motionMatrix(time: Double) -> simd_float4x4 {
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
    private static func coreRadius(id: String, kind: String, selectionID: String?, hoverID: String?) -> Float {
        if kind == "device" || id == "view:current-device" { return 1.2 }
        if id == selectionID { return 0.30 }
        if id == hoverID { return 0.25 }
        return 0.20
    }
    private static func buffer<T>(device: MTLDevice, values: [T]) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        return values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }
    private static func nodeColor(kind: String) -> SIMD4<Float> {
        switch kind {
        case "person": return SIMD4(0.27, 0.70, 1.0, 1)
        case "note": return SIMD4(1.0, 0.72, 0.30, 1)
        case "chat": return SIMD4(0.69, 0.43, 1.0, 1)
        case "recording": return SIMD4(0.20, 0.88, 0.74, 1)
        case "device": return SIMD4(0.40, 0.86, 1.0, 1)
        default: return SIMD4(0.66, 0.76, 0.94, 1)
        }
    }
    private static func edgeColor(kind: String) -> SIMD4<Float> {
        switch kind {
        case "evidence": return SIMD4(1.0, 0.68, 0.30, 0.18)
        case "source-link": return SIMD4(0.25, 0.83, 0.72, 0.18)
        case "derived-speaker": return SIMD4(0.65, 0.46, 1.0, 0.18)
        default: return SIMD4(0.43, 0.63, 0.91, 0.15)
        }
    }
    private static func sphericalGuides() -> [SIMD3<Float>] {
        var lines: [SIMD3<Float>] = []
        let radii: [Float] = [5, 9, 13, 17]
        let segments = 72
        for radius in radii {
            for latitude in [0 as Float] {
                for i in 0..<segments {
                    func point(_ n: Int) -> SIMD3<Float> { let a = Float(n % segments) / Float(segments) * 2 * .pi; return SIMD3(radius * cos(latitude) * cos(a), radius * sin(latitude), radius * cos(latitude) * sin(a)) }
                    lines += [point(i), point(i + 1)]
                }
            }
            for longitude in [0 as Float, .pi / 2] {
                for i in 0..<segments {
                    func point(_ n: Int) -> SIMD3<Float> { let a = Float(n % segments) / Float(segments) * 2 * .pi; return SIMD3(radius * cos(a) * cos(longitude), radius * sin(a), radius * cos(a) * sin(longitude)) }
                    lines += [point(i), point(i + 1)]
                }
            }
        }
        return lines
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Node { float3 position; float radius; float4 color; };
    struct EdgeVertex { float3 position; float4 color; };
    struct Uniforms { float4x4 viewProjection; float4x4 model; float2 viewport; float pointScale; float time; float3 padding; };
    struct Out { float4 position [[position]]; float4 color; float2 local; float3 world; };
    float hash21(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
    vertex Out backgroundVertex(const device float2 *quad [[buffer(0)]], uint vid [[vertex_id]]) { Out o; o.position=float4(quad[vid],0,1); o.local=quad[vid]; o.color=0; o.world=0; return o; }
    fragment float4 backgroundFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(2)]]) {
        float2 uv = (in.local + 1.0) * .5; float vignette = 1.0 - 0.42 * dot(in.local, in.local);
        float3 space = float3(0.006, 0.012, 0.035) * max(vignette, .3);
        float2 grid = uv * float2(138., 86.); float2 cell = floor(grid);
        float2 local = fract(grid) - float2(.2 + .6 * hash21(cell + 13.), .2 + .6 * hash21(cell + 31.));
        float star = step(.987, hash21(cell)) * exp(-dot(local, local) * 180.);
        float twinkle = .55 + .45 * sin(u.time * (0.8 + hash21(cell)) + hash21(cell + 9.) * 6.283);
        return float4(space + star * twinkle * float3(.32,.48,.72), 1);
    }
    vertex Out nodeVertex(const device float2 *quad [[buffer(0)]], const device Node *nodes [[buffer(1)]], constant Uniforms &u [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) {
        Node n=nodes[iid]; float4 world=u.model*float4(n.position,1); float4 clip=u.viewProjection*world; float scale=n.radius*u.pointScale/max(clip.w,.01); Out o; o.position=clip+float4(quad[vid]*scale*float2(2./u.viewport.x,2./u.viewport.y)*clip.w,0,0); o.color=n.color; o.local=quad[vid]; o.world=world.xyz; return o;
    }
    fragment float4 nodeFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(2)]]) {
        float d=dot(in.local,in.local); if(d>1.) discard_fragment(); float edge=smoothstep(1.,.78,d); float core=smoothstep(.48,.04,d); float shimmer=.91+.09*sin(u.time*2.1+in.world.x*1.7+in.world.z*.8);
        float3 color=in.color.rgb; if(in.color.b>.85 && in.color.g>.8) { float light=max(0.,1.-length(in.local-float2(-.28,.32))); color*=.55+.72*light; }
        return float4(color*(.25+core*1.45)*shimmer, edge*(.28+.72*core));
    }
    vertex Out edgeVertex(const device EdgeVertex *v [[buffer(0)]], constant Uniforms &u [[buffer(2)]], uint vid [[vertex_id]]) { Out o; o.position=u.viewProjection*u.model*float4(v[vid].position,1); o.color=v[vid].color; o.local=0; o.world=0; return o; }
    fragment float4 edgeFragment(Out in [[stage_in]]) { return in.color; }
    vertex Out guideVertex(const device float3 *v [[buffer(0)]], constant Uniforms &u [[buffer(2)]], uint vid [[vertex_id]]) { Out o; o.position=u.viewProjection*u.model*float4(v[vid],1); float r=length(v[vid]); float3 c = r<7. ? float3(.27,.70,1.) : r<11. ? float3(1.,.72,.30) : r<15. ? float3(.69,.43,1.) : float3(.20,.88,.74); o.color=float4(c,.095); o.local=0; o.world=0; return o; }
    fragment float4 guideFragment(Out in [[stage_in]]) { return in.color; }
    """
}
