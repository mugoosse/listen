import AppKit
import Foundation
import Metal
import MetalKit
import simd

/// The orbit camera, and the ray a click turns into.
///
/// Separate from the renderer because picking has to use the exact matrices the
/// GPU used. Two copies of a projection agree until one of them is edited, and
/// the failure is a click that selects the star next to the one under the
/// pointer, which reads as the picture being wrong rather than the maths.
struct GalaxyCamera: Equatable {
    static let defaultDistance: Float = 18

    /// How close a scroll may bring the camera, derived from the shells rather
    /// than picked.
    ///
    /// **It was 2.5, which is inside the people shell.** At that distance the
    /// camera sits within the innermost sphere looking outwards: the centre
    /// fills most of the frame, the shells stop reading as concentric, and
    /// there is nothing on screen to say which way is out. The floor is the
    /// innermost radius, plus the centre's own drawn radius, plus a margin so
    /// its glow is not the picture — 5 + 1.2 + 1.8. Derived so it follows the
    /// shells if those ever move.
    static var minimumDistance: Float {
        (Galaxy.shellRadius(kind: Galaxy.Node.person) ?? 5) + 1.2 + 1.8
    }
    static let maximumDistance: Float = 90
    /// Half of the 45 degree vertical field of view, which every projection
    /// here is built from. Stated once so the camera and the renderer cannot
    /// frame differently.
    static let halfFieldOfView = Float.pi / 8

    private(set) var yaw: Float = 0
    private(set) var pitch: Float = 0.28
    private(set) var distance = GalaxyCamera.defaultDistance
    private(set) var target = SIMD3<Float>(repeating: 0)

    var eye: SIMD3<Float> {
        let horizontal = cos(pitch) * distance
        return target + SIMD3<Float>(sin(yaw) * horizontal, sin(pitch) * distance, cos(yaw) * horizontal)
    }

    /// How far a drag of one viewport height turns the scene, as a fraction of
    /// a full turn. Three.js `OrbitControls` at `rotateSpeed` 0.45, which is
    /// what the reference this was ported from uses.
    static let rotateSpeed: Float = 0.45

    /// Orbit from a drag, in this view's own coordinates: x to the right, y up.
    ///
    /// **The scene follows the pointer on both axes**, which is what every 3D
    /// viewer does and what the reference does: drag right and the galaxy comes
    /// with you. That means the *camera* goes the other way, so both terms are
    /// subtracted, and getting the sign wrong on one axis alone is the failure
    /// this comment exists for. It shipped that way: yaw was added, so dragging
    /// right sent the scene left while dragging up brought it up, and one axis
    /// disagreeing with the other reads as the picture being broken.
    ///
    /// Derivation against Three.js, whose `clientY` runs downwards where
    /// AppKit's runs up. `rotateLeft(+dx)` does `theta -= dx`, and its
    /// `setFromSphericalCoords` is this `eye`: x = r·sinφ·sinθ, z = r·sinφ·cosθ.
    /// So a rightward drag lowers theta, the camera moves to −x, and the scene
    /// appears to move right. `rotateUp(+dy_down)` does `phi -= dy_down`, which
    /// raises the camera, so a downward drag moves the scene down. Negating
    /// AppKit's upward y turns the second into the same subtraction.
    ///
    /// Per point of viewport height rather than a fixed constant, so a drag
    /// across the pane is the same turn whatever size the window is.
    mutating func orbit(deltaX: Float, deltaY: Float, viewportHeight: Float) {
        let radiansPerPoint = 2 * .pi * Self.rotateSpeed / max(viewportHeight, 1)
        yaw -= deltaX * radiansPerPoint
        // Stopped short of straight up. At the pole the up vector and the view
        // direction are parallel and `lookAt` produces a matrix full of NaN.
        pitch = min(max(pitch - deltaY * radiansPerPoint, -1.45), 1.45)
    }
    /// How far one point of a trackpad scroll moves the camera, in log units.
    ///
    /// Log units because zooming is multiplicative: a step should feel the same
    /// close up and far out, and adding a constant to a distance does not. The
    /// range, 8 to 90, is `ln(11.25)` = 2.42 of these, so a 250-point swipe is
    /// about seventy per cent of it: one gesture crosses most of the way
    /// without a flick landing on either stop.
    ///
    /// It was 0.0015, which made a good swipe a forty per cent change, and
    /// then 0.009 while the floor was still 2.5 and the range half again as
    /// long.
    static let zoomPerScrollPoint: Float = 0.007
    /// And one line of a mouse wheel, which reports in lines rather than
    /// points: three or so per notch where a trackpad sends hundreds. One rate
    /// for both would make a wheel useless or a trackpad unusable.
    static let zoomPerScrollLine: Float = 0.3
    /// And a pinch, whose `magnification` is a fraction of the current size, so
    /// a full one is about a doubling.
    static let zoomPerMagnification: Float = 0.7

    /// Move the camera in or out. **Positive is closer**, which is the sign of
    /// every gesture that means "bigger": scrolling up, and pinching out.
    ///
    /// It was the other way round, so scrolling up pushed the galaxy away, and
    /// far too slow to reach either end: 0.0015 per point made a good swipe a
    /// 40% change on a range that spans 36 times.
    mutating func zoom(delta: Float) {
        distance = min(max(distance * exp(-delta), Self.minimumDistance), Self.maximumDistance)
    }
    mutating func pan(deltaX: Float, deltaY: Float, viewportSize: SIMD2<Float>) {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return }
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_normalize(simd_cross(right, forward))
        // Points on screen to world units at the target's depth, so a drag
        // moves the thing under the pointer by the distance the pointer moved.
        let scale = 2 * distance * tan(Self.halfFieldOfView) / viewportSize.y
        target += (-right * deltaX + up * deltaY) * scale
    }

    /// Frame the whole outermost shell, whatever the library holds.
    ///
    /// The six poles of the recordings shell rather than the actual stars: an
    /// empty library, or one with three recordings on one side, would otherwise
    /// open zoomed into a corner of a sphere whose other side is the picture.
    mutating func frameGalaxy(aspect: Float = 1) {
        let radius = Galaxy.shellRadius(kind: Galaxy.Node.recording) ?? 17
        frame(positions: [SIMD3(radius, 0, 0), SIMD3(-radius, 0, 0),
                          SIMD3(0, radius, 0), SIMD3(0, -radius, 0),
                          SIMD3(0, 0, radius), SIMD3(0, 0, -radius)], aspect: aspect)
    }

    mutating func frame(positions: [SIMD3<Float>], aspect: Float = 1) {
        guard let first = positions.first else { reset(); return }
        var low = first, high = first
        for position in positions { low = simd_min(low, position); high = simd_max(high, position) }
        target = (low + high) * 0.5
        let radius = positions.map { simd_length($0 - target) }.max() ?? 1
        // The narrower of the two half-angles, so a tall column frames on its
        // width rather than clipping the sides off.
        let halfAngle = atan(tan(Self.halfFieldOfView) * min(max(aspect, 0.1), 1))
        distance = min(Self.maximumDistance, max(Self.minimumDistance, (radius + 0.5) / sin(halfAngle) * 1.12))
    }

    mutating func reset() {
        yaw = 0; pitch = 0.28; distance = Self.defaultDistance; target = .zero
    }

    func focused(on position: SIMD3<Float>, distance desired: Float) -> GalaxyCamera {
        var next = self
        next.target = position
        next.distance = min(Self.maximumDistance, max(Self.minimumDistance, desired))
        return next
    }

    /// Look at one star with everything it links to still in frame.
    ///
    /// **A fixed distance was the obvious version and it was wrong.** Flying to
    /// 14 units from a star on the outer shell put the camera inside a sphere
    /// of radius 17 looking outwards: the star filled the middle of the screen
    /// and the things it connects to, which is the entire reason anybody
    /// clicked it, were off the edges. The neighbours decide the distance now,
    /// and `nearest` is the floor so a star with one close neighbour, or none
    /// at all, does not end up pressed against the lens.
    func focused(on position: SIMD3<Float>, including neighbours: [SIMD3<Float>],
                 aspect: Float, nearest: Float = 11) -> GalaxyCamera {
        var next = self
        next.target = position
        let reach = neighbours.map { simd_distance($0, position) }.max() ?? 0
        let halfAngle = atan(tan(Self.halfFieldOfView) * min(max(aspect, 0.1), 1))
        let wanted = (reach + 1.2) / sin(halfAngle) * 1.06
        next.distance = min(Self.maximumDistance, max(nearest, wanted))
        return next
    }

    func interpolated(to goal: GalaxyCamera, progress: Float) -> GalaxyCamera {
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
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        return simd_float4x4(
            SIMD4<Float>(right.x, up.x, -forward.x, 0),
            SIMD4<Float>(right.y, up.y, -forward.y, 0),
            SIMD4<Float>(right.z, up.z, -forward.z, 0),
            SIMD4<Float>(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1))
    }

    static func perspectiveMatrix(aspect: Float, nearZ: Float = 0.1, farZ: Float = 200) -> simd_float4x4 {
        let y = 1 / tan(halfFieldOfView)
        let x = y / max(aspect, 0.0001)
        let z = farZ / (nearZ - farZ)
        return simd_float4x4(SIMD4<Float>(x, 0, 0, 0), SIMD4<Float>(0, y, 0, 0),
                             SIMD4<Float>(0, 0, z, -1), SIMD4<Float>(0, 0, z * nearZ, 0))
    }
}

enum GalaxyRendererError: LocalizedError {
    case metalUnavailable, noCommandQueue, shaderCompilation(Error), pipeline(Error)
    case bufferAllocation, commandBuffer, renderEncoder
    var errorDescription: String? {
        switch self {
        case .metalUnavailable: return "This Mac has no Metal device, so the galaxy cannot be drawn."
        case .noCommandQueue: return "Metal command queue could not be created."
        case .shaderCompilation(let error): return "Metal shader compilation failed: \(error.localizedDescription)"
        case .pipeline(let error): return "Metal render pipeline creation failed: \(error.localizedDescription)"
        case .bufferAllocation: return "Metal buffer allocation failed."
        case .commandBuffer: return "Metal command buffer could not be created. The galaxy has stopped drawing."
        case .renderEncoder: return "Metal render encoder could not be created. The galaxy has stopped drawing."
        }
    }
}

private struct GalaxyGPUStar { var position: SIMD3<Float>; var radius: Float; var color: SIMD4<Float> }
private struct GalaxyGPULine { var position: SIMD3<Float>; var color: SIMD4<Float> }
private struct GalaxyGPUUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var viewport: SIMD2<Float>
    var pointScale: Float
    var time: Float
    /// **The sky, sent rather than written twice.** The shader used to carry
    /// its own constant and the pane carried another, and they disagreed: the
    /// pane's was RGB(10,15,29) and what the GPU actually painted was
    /// RGB(1,2,6). Nobody could see that inside the scene, and it showed up as
    /// a seam the moment the window put anything else beside it.
    var sky: SIMD3<Float>
    var padding: Float = 0
}

/// GPU-instanced stars, batched lines, and one shader compiled from source at
/// launch.
///
/// **From source rather than a `.metal` file in the target.** The app already
/// fights one metallib problem (`CLAUDE.md`, "swift build does not produce a
/// working binary"), and adding a second Metal source to the build would mean
/// the galaxy could only be tested through the full Xcode path. Compiling a
/// string costs about 40 ms once, on a background-eligible init, and it means
/// this file is the whole shader story.
final class GalaxyRenderer {
    /// The one sky. Everything that paints a background beside this scene has
    /// to use it: the pane under the Metal view before the first frame, the
    /// clear colour, the shader, and the window's sidebar while the galaxy is
    /// up. `GalaxyPane.sky` is this as an `NSColor`.
    /// `Brand.canvas` in its dark appearance, as the shader's own units. The
    /// scene is not a picture in a frame: it fills a pane of a window whose
    /// other panes are this colour, and a sky a shade off the ground beside it
    /// reads as a seam down the middle rather than as depth.
    ///
    /// A literal rather than a read of `Brand.canvas`, because this is what the
    /// GPU is handed and `NSColor`'s dynamic value depends on an appearance
    /// that a render pass does not have. `verify_galaxy.sh` measures the two
    /// against each other, so they cannot come apart quietly.
    static let sky = SIMD3<Float>(10.0 / 255, 15.0 / 255, 29.0 / 255)

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    /// Runtime failures after a successful init. A silent return here leaves a
    /// frozen picture and no explanation, which is how this got a name.
    var onError: ((String) -> Void)?

    private let backgroundPipeline: MTLRenderPipelineState
    private let starPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let guidePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let overlayDepthState: MTLDepthStencilState
    private let quadBuffer: MTLBuffer
    private let guideBuffer: MTLBuffer?
    private var starBuffer: MTLBuffer?
    private var lineBuffer: MTLBuffer?
    private(set) var nodes: [Galaxy.Node] = []
    private var stars: [GalaxyGPUStar] = []
    private var lines: [GalaxyGPULine] = []
    private var selectionID: String?
    private var hoverID: String?

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw GalaxyRendererError.noCommandQueue }
        commandQueue = queue
        let library: MTLLibrary
        do { library = try device.makeLibrary(source: Self.shaderSource, options: nil) }
        catch { throw GalaxyRendererError.shaderCompilation(error) }
        func pipeline(_ vertex: String, _ fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.depthAttachmentPixelFormat = .depth32Float
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            if blending, let attachment = descriptor.colorAttachments[0] {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                // Additive rather than one-minus-source-alpha: stars and lines
                // over a near-black sky should accumulate light where they
                // overlap, which is what makes a crowded shell read as bright.
                attachment.destinationRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            do { return try device.makeRenderPipelineState(descriptor: descriptor) }
            catch { throw GalaxyRendererError.pipeline(error) }
        }
        backgroundPipeline = try pipeline("galaxyBackgroundVertex", "galaxyBackgroundFragment", blending: false)
        starPipeline = try pipeline("galaxyStarVertex", "galaxyStarFragment", blending: true)
        linePipeline = try pipeline("galaxyLineVertex", "galaxyLineFragment", blending: true)
        guidePipeline = try pipeline("galaxyGuideVertex", "galaxyGuideFragment", blending: true)
        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        guard let state = device.makeDepthStencilState(descriptor: depth) else { throw GalaxyRendererError.bufferAllocation }
        depthState = state
        // Lines and shell guides test depth but do not write it, so a line
        // passing in front of a star does not punch a hole in the star behind.
        let overlay = MTLDepthStencilDescriptor()
        overlay.depthCompareFunction = .lessEqual
        overlay.isDepthWriteEnabled = false
        guard let overlayState = device.makeDepthStencilState(descriptor: overlay) else { throw GalaxyRendererError.bufferAllocation }
        overlayDepthState = overlayState
        let quad: [SIMD2<Float>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1), SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1)]
        guard let buffer = device.makeBuffer(bytes: quad, length: MemoryLayout<SIMD2<Float>>.stride * quad.count,
                                             options: .storageModeShared) else { throw GalaxyRendererError.bufferAllocation }
        quadBuffer = buffer
        guideBuffer = Self.buffer(device: device, values: Self.shellGuides())
    }

    /// `highlight` is the search's matches. **A selection outranks it**:
    /// clicking a star while a search is up is a narrower question than the
    /// search, and two sets of lit stars would answer neither.
    func update(snapshot: Galaxy.Snapshot, selectionID: String?, hoverID: String? = nil,
                highlight: Set<String> = []) {
        nodes = snapshot.nodes
        self.selectionID = selectionID
        self.hoverID = hoverID
        let neighbours: Set<String> = selectionID.map { id in
            Set(snapshot.edges.compactMap { $0.source == id ? $0.target : $0.target == id ? $0.source : nil })
        } ?? []
        stars = snapshot.nodes.map { node in
            let lit = selectionID == nil
                ? (highlight.isEmpty || highlight.contains(node.id))
                : (node.id == selectionID || neighbours.contains(node.id))
            let base = Self.starColor(kind: node.kind)
            // Dimmed, not extinguished. At 0.28 the rest of the library went
            // black at the distance a selection flies to, and a star with two
            // links looked like a star alone in space.
            let dimmed = SIMD4<Float>(base.x * 0.42, base.y * 0.42, base.z * 0.42, 0.5)
            return GalaxyGPUStar(position: node.position,
                                 radius: Self.starRadius(id: node.id, kind: node.kind,
                                                         selectionID: selectionID, hoverID: hoverID),
                                 color: lit ? base : dimmed)
        }
        let byID = Dictionary(snapshot.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        lines.removeAll(keepingCapacity: true)
        for edge in snapshot.edges {
            guard let source = byID[edge.source], let target = byID[edge.target] else { continue }
            let connected = selectionID != nil && (edge.source == selectionID || edge.target == selectionID)
            // **Neutral, so a link never competes with a shell for hue.** It
            // was a blue within a few percent of the notes shell, which read
            // as "this line is a note" and made a pixel check unable to tell
            // them apart either. A link is a relationship between two
            // colours; it should be neither of them.
            let searched = selectionID == nil && !highlight.isEmpty
                && (highlight.contains(edge.source) || highlight.contains(edge.target))
            var color = SIMD4<Float>(0.62, 0.68, 0.80, 0.15)
            if connected || searched { color.w = 0.75 }
            else if selectionID != nil || !highlight.isEmpty {
                color = SIMD4(color.x * 0.24, color.y * 0.24, color.z * 0.24, 0.08)
            }
            lines.append(GalaxyGPULine(position: source.position, color: color))
            lines.append(GalaxyGPULine(position: target.position, color: color))
        }
        starBuffer = Self.buffer(device: device, values: stars)
        lineBuffer = Self.buffer(device: device, values: lines)
    }

    func draw(renderPassDescriptor: MTLRenderPassDescriptor, drawable: CAMetalDrawable?,
              viewportSize: CGSize, camera: GalaxyCamera, time: Double = 0) {
        // A zero viewport is a view awaiting layout, which is not a failure.
        // Everything below it is, and a silent return there is a window that
        // keeps its last frame with nothing said.
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            onError?(GalaxyRendererError.commandBuffer.localizedDescription); return
        }
        commandBuffer.addCompletedHandler { [weak self] buffer in
            if buffer.status == .error {
                self?.onError?((buffer.error ?? GalaxyRendererError.bufferAllocation).localizedDescription)
            }
        }
        encode(commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor,
               viewportSize: viewportSize, camera: camera, time: time)
        if let drawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }

    func encode(commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor,
                viewportSize: CGSize, camera: GalaxyCamera, time: Double = 0) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            onError?(GalaxyRendererError.renderEncoder.localizedDescription); return
        }
        let aspect = Float(viewportSize.width / max(viewportSize.height, 1))
        var uniforms = GalaxyGPUUniforms(
            viewProjection: GalaxyCamera.perspectiveMatrix(aspect: aspect) * camera.viewMatrix(),
            model: GalaxyMotion.matrix(time: time),
            viewport: SIMD2(Float(viewportSize.width), Float(viewportSize.height)),
            pointScale: Float(viewportSize.height) * 0.5 / tan(GalaxyCamera.halfFieldOfView),
            time: Float(time), sky: Self.sky)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GalaxyGPUUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<GalaxyGPUUniforms>.stride, index: 2)

        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        encoder.setDepthStencilState(overlayDepthState)
        if let guideBuffer {
            encoder.setRenderPipelineState(guidePipeline)
            encoder.setVertexBuffer(guideBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0,
                                   vertexCount: guideBuffer.length / MemoryLayout<SIMD3<Float>>.stride)
        }
        if let lineBuffer, !lines.isEmpty {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setVertexBuffer(lineBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lines.count)
        }
        if let starBuffer, !stars.isEmpty {
            encoder.setDepthStencilState(depthState)
            encoder.setRenderPipelineState(starPipeline)
            encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(starBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: stars.count)
        }
        encoder.endEncoding()
    }

    /// The front-most star under a point, in the same matrices the GPU drew.
    func pick(screenPoint: SIMD2<Float>, viewportSize: SIMD2<Float>, camera: GalaxyCamera, time: Double = 0) -> String? {
        guard viewportSize.x > 0, viewportSize.y > 0 else { return nil }
        let projection = GalaxyCamera.perspectiveMatrix(aspect: viewportSize.x / viewportSize.y)
        let matrix = projection * camera.viewMatrix()
        var best: (String, Float)?
        for node in nodes {
            let position = GalaxyMotion.position(node.position, kind: node.kind, time: time)
            let clip = matrix * SIMD4<Float>(position, 1)
            guard clip.w > 0, clip.z >= 0, clip.z <= clip.w else { continue }
            let centre = SIMD2<Float>((clip.x / clip.w + 1) * viewportSize.x / 2,
                                      (1 - clip.y / clip.w) * viewportSize.y / 2)
            let radius = Self.starRadius(id: node.id, kind: node.kind, selectionID: selectionID, hoverID: hoverID)
            let pixels = radius * viewportSize.y * 0.5 * projection[1][1] / clip.w
            guard simd_length_squared(screenPoint - centre) <= pixels * pixels else { continue }
            let depth = clip.z / clip.w
            if best == nil || depth < best!.1 { best = (node.id, depth) }
        }
        return best?.0
    }

    /// The same numbers the shader scales a quad by, so what is drawn and what
    /// is clickable are one statement.
    /// **Bigger further in, and it is not arbitrary.** One radius for every
    /// star made the people shell nearly invisible: it holds the fewest things,
    /// they sit closest to the middle where the centre's glow is, and they are
    /// the most nameable thing in the library. A recording has a title and a
    /// date in the list beside this; a person is a name and a colour.
    ///
    /// Selection and hover still win, so the star under the pointer is always
    /// the largest thing near it, and picking reads this same function.
    static func starRadius(id: String, kind: String, selectionID: String?, hoverID: String?) -> Float {
        if kind == Galaxy.Node.device { return 1.2 }
        let base: Float
        switch kind {
        case Galaxy.Node.person: return id == selectionID ? 0.36 : id == hoverID ? 0.32 : 0.28
        case Galaxy.Node.note: base = 0.23
        case Galaxy.Node.chat: base = 0.21
        default: base = 0.19
        }
        if id == selectionID { return base + 0.10 }
        if id == hoverID { return base + 0.05 }
        return base
    }

    static func starColor(kind: String) -> SIMD4<Float> {
        switch kind {
        // People are the warm one, and notes took their blue. This is the way
        // round somebody who reads their own library every day asked for: the
        // shell you scan for a name is the one that should catch the eye. The
        // guide circles in the shader carry the same four by radius, and a
        // wrong one there is instantly visible.
        case Galaxy.Node.person: return SIMD4(1.0, 0.80, 0.28, 1)
        // A true blue rather than the cyan it started at. Beside the teal
        // recordings shell that cyan read as the same colour at small sizes,
        // and the two most numerous shells being one colour is the picture
        // saying less than it knows.
        case Galaxy.Node.note: return SIMD4(0.36, 0.52, 1.0, 1)
        case Galaxy.Node.chat: return SIMD4(0.85, 0.42, 1.0, 1)
        case Galaxy.Node.recording: return SIMD4(0.20, 0.88, 0.74, 1)
        // **Warm, because the centre is a person and people are warm now.** It
        // was a blue-white, which was fine beside blue people and wrong beside
        // yellow ones: the one star that *is* you read as belonging to a shell
        // it had just left. It is also the only blue-white left, so a pixel
        // check could not tell it from a note.
        case Galaxy.Node.device: return SIMD4(1.0, 0.93, 0.74, 1)
        default: return SIMD4(0.66, 0.76, 0.94, 1)
        }
    }

    private static func buffer<T>(device: MTLDevice, values: [T]) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        return values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    /// Three great circles per shell, faint. They are what makes four bands
    /// read as four spheres rather than as a cloud that happens to be thicker
    /// in places, and they are drawn in the shell's own colour so the legend
    /// and the picture agree without a key on screen.
    private static func shellGuides() -> [SIMD3<Float>] {
        var lines: [SIMD3<Float>] = []
        let segments = 72
        for kind in [Galaxy.Node.person, Galaxy.Node.note, Galaxy.Node.chat, Galaxy.Node.recording] {
            guard let radius = Galaxy.shellRadius(kind: kind) else { continue }
            func circle(_ point: @escaping (Float) -> SIMD3<Float>) {
                for i in 0..<segments {
                    let a = Float(i) / Float(segments) * 2 * .pi
                    let b = Float(i + 1) / Float(segments) * 2 * .pi
                    lines += [point(a), point(b)]
                }
            }
            circle { SIMD3(radius * cos($0), 0, radius * sin($0)) }
            circle { SIMD3(radius * cos($0), radius * sin($0), 0) }
            circle { SIMD3(0, radius * sin($0), radius * cos($0)) }
        }
        return lines
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Star { float3 position; float radius; float4 color; };
    struct Line { float3 position; float4 color; };
    struct Uniforms { float4x4 viewProjection; float4x4 model; float2 viewport; float pointScale; float time; float3 sky; float padding; };
    struct Out { float4 position [[position]]; float4 color; float2 local; float3 world; };
    float galaxyHash(float2 p) { p = fract(p * float2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }

    vertex Out galaxyBackgroundVertex(const device float2 *quad [[buffer(0)]], uint vid [[vertex_id]]) {
        Out o; o.position = float4(quad[vid], 0, 1); o.local = quad[vid]; o.color = 0; o.world = 0; return o;
    }
    // Decorative background stars. Unpickable, and not library content: they
    // are a depth cue, and a viewer must never be able to click one.
    fragment float4 galaxyBackgroundFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(2)]]) {
        float2 uv = (in.local + 1.0) * .5;
        // **Flat, and the vignette is gone rather than reduced.** It was 0.42,
        // then 0.10, then 0.05, and every one of them was a gradient against a
        // sidebar that is one flat colour: the seam simply moved to wherever
        // the fade had got to by the divider. A sky that *is* the window's
        // ground has nothing to be darker than.
        float3 space = u.sky;
        float2 grid = uv * float2(138., 86.);
        float2 cell = floor(grid);
        float2 local = fract(grid) - float2(.2 + .6 * galaxyHash(cell + 13.), .2 + .6 * galaxyHash(cell + 31.));
        float star = step(.987, galaxyHash(cell)) * exp(-dot(local, local) * 180.);
        float twinkle = .55 + .45 * sin(u.time * (0.8 + galaxyHash(cell)) + galaxyHash(cell + 9.) * 6.283);
        // **Neutral, like the links.** The rule this scene keeps is that every
        // hue belongs to a shell and everything decorative is grey: these were
        // a blue within a few percent of the notes shell, so a sky full of
        // ornament read as a sky full of notes.
        return float4(space + star * twinkle * float3(.58, .62, .70), 1);
    }

    vertex Out galaxyStarVertex(const device float2 *quad [[buffer(0)]], const device Star *stars [[buffer(1)]],
                                constant Uniforms &u [[buffer(2)]], uint vid [[vertex_id]], uint iid [[instance_id]]) {
        Star s = stars[iid];
        float4 world = u.model * float4(s.position, 1);
        float4 clip = u.viewProjection * world;
        float scale = s.radius * u.pointScale / max(clip.w, .01);
        Out o;
        o.position = clip + float4(quad[vid] * scale * float2(2. / u.viewport.x, 2. / u.viewport.y) * clip.w, 0, 0);
        o.color = s.color; o.local = quad[vid]; o.world = world.xyz;
        return o;
    }
    fragment float4 galaxyStarFragment(Out in [[stage_in]], constant Uniforms &u [[buffer(2)]]) {
        float d = dot(in.local, in.local);
        if (d > 1.) discard_fragment();
        float edge = smoothstep(1., .78, d);
        float core = smoothstep(.48, .04, d);
        float shimmer = .91 + .09 * sin(u.time * 2.1 + in.world.x * 1.7 + in.world.z * .8);
        float3 color = in.color.rgb;
        // The centre is a lit sphere rather than a dot, which is the one thing
        // that makes it read as "here" instead of as a very large star.
        // The centre alone: warm and very bright, where a person is warm and a
        // note is blue. Keyed on the colour rather than on a flag because the
        // instance buffer carries nothing else, and no other star is this pale.
        if (in.color.r > .95 && in.color.g > .85) {
            float light = max(0., 1. - length(in.local - float2(-.28, .32)));
            color *= .55 + .72 * light;
        }
        return float4(color * (.25 + core * 1.45) * shimmer, edge * (.28 + .72 * core));
    }

    vertex Out galaxyLineVertex(const device Line *v [[buffer(0)]], constant Uniforms &u [[buffer(2)]], uint vid [[vertex_id]]) {
        Out o; o.position = u.viewProjection * u.model * float4(v[vid].position, 1);
        o.color = v[vid].color; o.local = 0; o.world = 0; return o;
    }
    fragment float4 galaxyLineFragment(Out in [[stage_in]]) { return in.color; }

    vertex Out galaxyGuideVertex(const device float3 *v [[buffer(0)]], constant Uniforms &u [[buffer(2)]], uint vid [[vertex_id]]) {
        Out o; o.position = u.viewProjection * u.model * float4(v[vid], 1);
        float r = length(v[vid]);
        // Same four as `starColor`, by radius. Two places, and the only thing
        // keeping them honest is that a wrong one is instantly visible.
        float3 c = r < 7. ? float3(1., .80, .28) : r < 11. ? float3(.36, .52, 1.)
                 : r < 15. ? float3(.85, .42, 1.) : float3(.20, .88, .74);
        o.color = float4(c, .095); o.local = 0; o.world = 0; return o;
    }
    fragment float4 galaxyGuideFragment(Out in [[stage_in]]) { return in.color; }
    """
}

/// The galaxy rendered to a file, with no window.
///
/// **It exists because a locked screen photographs as black.** Metal needs no
/// display, so this answers "what does the picture look like" on a machine
/// whose window server will not hand over a single pixel, which is where
/// `verify_galaxy.sh --ui` cannot run at all.
///
/// It draws stars, links and the shell guides, and **no titles**: the labels
/// are AppKit text fields over the scene, so an image of a real library is a
/// pattern of coloured dots and carries no recording, note or person's name.
/// That is what makes it safe to write one out of somebody's own library.
enum GalaxyImage {
    /// `zoom` is a distance for the camera, for looking at a stop rather than
    /// at the opening view: the near one is the whole point of having one, and
    /// no screenshot of a live window can be relied on to be exactly there.
    static func write(_ snapshot: Galaxy.Snapshot, to output: URL,
                      width: Int = 1600, height: Int = 1000, zoom: Float? = nil) throws {
        guard width > 0, height > 0 else { throw GalaxyRendererError.bufferAllocation }
        guard let device = MTLCreateSystemDefaultDevice() else { throw GalaxyRendererError.metalUnavailable }
        let renderer = try GalaxyRenderer(device: device)
        // **Without this the failure is invisible.** `encode` returns quietly
        // when it cannot make a render encoder, and a command buffer with
        // nothing in it completes successfully, so the PNG would be written
        // from a texture whose clear had never run and the CLI would print
        // "wrote out.png" over a blank file.
        var failure: String?
        renderer.onError = { failure = failure ?? $0 }
        renderer.update(snapshot: snapshot, selectionID: nil)

        let colour = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        colour.usage = [.renderTarget]
        colour.storageMode = .shared
        let depth = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
        depth.usage = [.renderTarget]
        depth.storageMode = .private
        guard let colourTexture = device.makeTexture(descriptor: colour),
              let depthTexture = device.makeTexture(descriptor: depth) else {
            throw GalaxyRendererError.bufferAllocation
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colourTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(GalaxyRenderer.sky.x), green: Double(GalaxyRenderer.sky.y),
            blue: Double(GalaxyRenderer.sky.z), alpha: 1)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        var camera = GalaxyCamera()
        camera.frameGalaxy(aspect: Float(width) / Float(height))
        if let zoom {
            // Driven through `zoom` rather than set, so the clamp under test is
            // the one a scroll wheel goes through. Bounded, because asking for
            // a distance the clamp forbids is exactly what this is for and the
            // loop would never reach it.
            for _ in 0..<2000 where camera.distance > zoom + 0.01 { camera.zoom(delta: 0.05) }
            camera = camera.focused(on: .zero, distance: camera.distance)
        }
        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            throw GalaxyRendererError.commandBuffer
        }
        renderer.encode(commandBuffer: commandBuffer, renderPassDescriptor: pass,
                        viewportSize: CGSize(width: width, height: height), camera: camera)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw GalaxyRendererError.commandBuffer
        }
        if failure != nil { throw GalaxyRendererError.renderEncoder }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        colourTexture.getBytes(&pixels, bytesPerRow: width * 4,
                               from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // The texture is BGRA and a PNG is RGBA. Without the swap the sky comes
        // out brown and every shell is the wrong colour, which looks like a
        // palette bug rather than a byte order.
        for index in stride(from: 0, to: pixels.count, by: 4) { pixels.swapAt(index, index + 2) }
        guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bitmapFormat: [.alphaNonpremultiplied],
                bytesPerRow: width * 4, bitsPerPixel: 32),
              let destination = bitmap.bitmapData else { throw GalaxyRendererError.bufferAllocation }
        pixels.withUnsafeBytes {
            destination.update(from: $0.baseAddress!.assumingMemoryBound(to: UInt8.self), count: pixels.count)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw GalaxyRendererError.bufferAllocation
        }
        try png.write(to: output, options: .atomic)
    }
}
