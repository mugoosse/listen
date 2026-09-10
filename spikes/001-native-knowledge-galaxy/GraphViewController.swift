import AppKit
import MetalKit
import simd

private final class GraphMetalView: MTKView {
    var onClick: ((CGPoint) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); hoverArea = area
    }
    override func mouseMoved(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    private var dragOrigin: CGPoint?
    private var panning = false
    private var dragged = false

    override func mouseDown(with event: NSEvent) {
        onHover?(nil); onInteraction?(true)
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragged = false
        panning = event.modifierFlags.contains(.shift) || event.type == .rightMouseDown
    }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { drag(with: event) }
    override func rightMouseDragged(with event: NSEvent) { drag(with: event) }
    private func drag(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - origin.x, dy = point.y - origin.y
        if hypot(dx, dy) > 1 { dragged = true }
        dragOrigin = point
        if panning { onPan?(dx, dy) } else { onOrbit?(dx, dy) }
    }
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onInteraction?(false)
        if !dragged, let origin = dragOrigin, hypot(point.x - origin.x, point.y - origin.y) < 3 { onClick?(point) }
        dragOrigin = nil
    }
    override func rightMouseUp(with event: NSEvent) { dragOrigin = nil; onInteraction?(false) }
    override func scrollWheel(with event: NSEvent) { onZoom?(event.scrollingDeltaY) }
    override func magnify(with event: NSEvent) { onZoom?(-event.magnification * 120) }
}

private final class GraphLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class EvidenceButton: NSButton {
    var evidence: GraphEvidence?
    var invoke: ((GraphEvidence) -> Void)?
    @objc func activateEvidence() { if let evidence { invoke?(evidence) } }
}

final class GraphViewController: NSViewController, MTKViewDelegate {
    var onEvidence: ((GraphEvidence) -> Void)?
    var onSelection: ((String?) -> Void)?

    private var snapshot: GraphSnapshot
    private var animation = GraphAnimationState()
    private var motionTime: Double = 0
    private var lastFrameTime: Double?
    private var lastLabelTime: Double = 0
    private var hoveredID: String?
    private var dragging = false
    private var focusFlight: (start: GraphCamera, goal: GraphCamera, elapsed: Double)?
    private var motionButton: NSButton?
    private(set) var animationRunning = false
    private var redrawRequestCount = 0
    private var labelUpdateCount = 0
    var motionDiagnostics: [String: Bool] {
        ["enabled": animation.enabled, "visible": animation.visible, "reduced_motion": animation.reducedMotion,
         "low_power": animation.lowPower, "interacting": animation.interacting,
         "window_visible": view.window?.isVisible ?? false,
         "window_unoccluded": view.window?.occlusionState.contains(.visible) ?? false,
         "app_hidden": NSApp.isHidden]
    }
    func refreshMotionPolicy() { refreshAnimationState() }

    func setMotionEnabled(_ enabled: Bool) {
        animation.enabled = enabled
        refreshAnimationState()
        updateDetail()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.acceptsMouseMovedEvents = true
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange] {
            center.addObserver(self, selector: #selector(refreshAnimationState), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAnimationState), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshAnimationState()
    }
    override func viewDidDisappear() {
        super.viewDidDisappear()
        animation.visible = false; animationRunning = false; metalView?.isPaused = true
        lastFrameTime = nil
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
    @objc private func refreshAnimationState() {
        animation.visible = view.window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !NSApp.isHidden } ?? false
        animation.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        animation.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        applyAnimationState()
    }

    private func applyAnimationState() {
        animation.interacting = dragging || hoveredID != nil || selectedID != nil || focusFlight != nil
        let snappedFocusFlight: Bool
        if let flight = focusFlight, !animation.focusAnimationEligible {
            camera = flight.goal
            focusFlight = nil
            snappedFocusFlight = true
        } else {
            snappedFocusFlight = false
        }
        animationRunning = animation.runs
        let flying = focusFlight != nil && animation.focusAnimationEligible
        let continuous = animationRunning || flying
        if metalView?.isPaused == continuous { lastFrameTime = nil }
        metalView?.isPaused = !continuous
        motionButton?.title = animation.enabled ? "Pause motion" : "Resume motion"
        if snappedFocusFlight { invalidate() }
    }

    private var renderer: GraphRenderer?
    private var camera = GraphCamera()
    private(set) var selectedID: String?
    private(set) var renderedFrameCount = 0
    var onReload: (() -> Void)?
    private var labels: [NSTextField] = []
    private let root = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760))
    private let sceneHost = NSView()
    private let detailStack = NSStackView()
    private let detailScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "Preparing Metal graph…")
    private var metalView: GraphMetalView?

    init(snapshot: GraphSnapshot) { self.snapshot = snapshot; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.035, green: 0.05, blue: 0.09, alpha: 1).cgColor
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        sceneHost.translatesAutoresizingMaskIntoConstraints = false
        let panel = makeDetailPanel()
        split.addArrangedSubview(sceneHost)
        split.addArrangedSubview(panel)
        split.setPosition(700, ofDividerAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(split)
        NSLayoutConstraint.activate([split.leadingAnchor.constraint(equalTo: root.leadingAnchor), split.trailingAnchor.constraint(equalTo: root.trailingAnchor), split.topAnchor.constraint(equalTo: root.topAnchor), split.bottomAnchor.constraint(equalTo: root.bottomAnchor), panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)])
        view = root
        installMetalView()
    }

    func update(snapshot: GraphSnapshot) {
        self.snapshot = snapshot
        if selectedID != nil && !snapshot.nodes.contains(where: { $0.id == selectedID }) { select(nil) }
        renderer?.update(snapshot: snapshot, selectionID: selectedID)
        updateDetail()
        invalidate()
    }

    override func viewDidLayout() { super.viewDidLayout(); updateLabels(); invalidate() }

    func draw(in view: MTKView) {
        guard let renderer, let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(0.1, max(0, now - (lastFrameTime ?? now)))
        lastFrameTime = now
        if animationRunning { motionTime += delta }
        if var flight = focusFlight, animation.focusAnimationEligible {
            flight.elapsed += delta
            camera = flight.start.interpolated(to: flight.goal, progress: Float(flight.elapsed / 0.65))
            focusFlight = flight.elapsed >= 0.65 ? nil : flight
            if focusFlight == nil { refreshAnimationState() }
        }
        if now - lastLabelTime > 0.1 { updateLabels(); lastLabelTime = now }
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.035, green: 0.05, blue: 0.09, alpha: 1)
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 1
        renderer.draw(renderPassDescriptor: descriptor, drawable: drawable, viewportSize: view.drawableSize, camera: camera, time: motionTime)
        renderedFrameCount += 1
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidate() }

    private func installMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else { showError("Metal is unavailable on this Mac."); return }
        do {
            let renderer = try GraphRenderer(device: device)
            self.renderer = renderer
            renderer.onError = { [weak self] message in
                DispatchQueue.main.async { self?.setMotionEnabled(false); self?.showError(message) }
            }
            camera.frameGalaxy()
            renderer.update(snapshot: snapshot, selectionID: selectedID)
            let metal = GraphMetalView(frame: .zero, device: device)
            metal.translatesAutoresizingMaskIntoConstraints = false
            metal.colorPixelFormat = .bgra8Unorm
            metal.depthStencilPixelFormat = .depth32Float
            metal.preferredFramesPerSecond = 30
            metal.enableSetNeedsDisplay = true
            metal.isPaused = true
            metal.delegate = self
            metal.onClick = { [weak self] point in self?.pick(point) }
            metal.onHover = { [weak self] point in self?.hover(point) }
            metal.onInteraction = { [weak self] active in
                self?.dragging = active
                if active { self?.focusFlight = nil }
                self?.refreshAnimationState()
            }
            metal.onOrbit = { [weak self] x, y in self?.moveCamera { $0.orbit(deltaX: Float(x), deltaY: Float(-y)) } }
            metal.onPan = { [weak self] x, y in self?.moveCamera { $0.pan(deltaX: Float(x), deltaY: Float(y), viewportSize: SIMD2<Float>(Float(self?.metalView?.bounds.width ?? 0), Float(self?.metalView?.bounds.height ?? 0))) } }
            metal.onZoom = { [weak self] delta in self?.moveCamera { $0.zoom(delta: Float(delta)) } }
            sceneHost.addSubview(metal)
            NSLayoutConstraint.activate([metal.leadingAnchor.constraint(equalTo: sceneHost.leadingAnchor), metal.trailingAnchor.constraint(equalTo: sceneHost.trailingAnchor), metal.topAnchor.constraint(equalTo: sceneHost.topAnchor), metal.bottomAnchor.constraint(equalTo: sceneHost.bottomAnchor)])
            metalView = metal
            statusLabel.removeFromSuperview()
            invalidate()
        } catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        sceneHost.addSubview(statusLabel)
        NSLayoutConstraint.activate([statusLabel.centerXAnchor.constraint(equalTo: sceneHost.centerXAnchor), statusLabel.centerYAnchor.constraint(equalTo: sceneHost.centerYAnchor), statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: sceneHost.leadingAnchor, constant: 24), statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: sceneHost.trailingAnchor, constant: -24)])
    }

    private func moveCamera(_ body: (inout GraphCamera) -> Void) { focusFlight = nil; body(&camera); refreshAnimationState(); invalidate() }
    private func invalidate() { redrawRequestCount += 1; metalView?.setNeedsDisplay(metalView?.bounds ?? .zero); updateLabels() }

    private func pick(_ point: CGPoint) {
        guard let metalView, let renderer else { return }
        let scale = metalView.window?.backingScaleFactor ?? 1
        let screen = SIMD2<Float>(Float(point.x * scale), Float((metalView.bounds.height - point.y) * scale))
        select(renderer.pick(screenPoint: screen, viewportSize: SIMD2<Float>(Float(metalView.drawableSize.width), Float(metalView.drawableSize.height)), camera: camera, time: motionTime))
    }
    private func hover(_ point: CGPoint?) {
        guard let metalView, let renderer else { return }
        let scale = metalView.window?.backingScaleFactor ?? 1
        let id = point.flatMap { point in
            renderer.pick(screenPoint: SIMD2<Float>(Float(point.x * scale), Float((metalView.bounds.height - point.y) * scale)), viewportSize: SIMD2<Float>(Float(metalView.drawableSize.width), Float(metalView.drawableSize.height)), camera: camera, time: motionTime)
        }
        guard id != hoveredID else { return }
        hoveredID = id
        renderer.update(snapshot: snapshot, selectionID: selectedID, hoverID: hoveredID)
        refreshAnimationState(); invalidate()
    }

    func select(nodeID: String?) {
        select(snapshot.nodes.contains(where: { $0.id == nodeID }) ? nodeID : nil)
    }

    private func select(_ id: String?) {
        refreshAnimationState()
        selectedID = id
        renderer?.update(snapshot: snapshot, selectionID: id)
        hoveredID = nil
        if let node = snapshot.nodes.first(where: { $0.id == id }) {
            let position = GraphMotion.position(node.position, id: node.id, kind: node.kind, time: motionTime)
            let goal = camera.focused(on: position, distance: node.kind == "device" ? 48 : 14)
            if !animation.focusAnimationEligible { camera = goal; focusFlight = nil }
            else { focusFlight = (camera, goal, 0) }
        } else { focusFlight = nil }
        refreshAnimationState()
        onSelection?(id)
        updateDetail()
        invalidate()
    }

    private func makeDetailPanel() -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 9
        detailStack.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 18, right: 16)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.documentView = detailStack
        detailScroll.drawsBackground = false
        detailScroll.hasVerticalScroller = true
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(detailScroll)
        NSLayoutConstraint.activate([detailScroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor), detailScroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor), detailScroll.topAnchor.constraint(equalTo: panel.topAnchor), detailScroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor), detailStack.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor)])
        updateDetail()
        return panel
    }

    private func updateDetail() {
        detailStack.arrangedSubviews.forEach { detailStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let heading = NSTextField(labelWithString: selectedID.flatMap { id in snapshot.nodes.first(where: { $0.id == id })?.title } ?? "Your Listen galaxy")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        detailStack.addArrangedSubview(heading)
        let summary = NSTextField(wrappingLabelWithString: "\(snapshot.nodes.count) nodes · \(snapshot.edges.count) links\n" + snapshot.label)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(summary)
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.addArrangedSubview(NSButton(title: "Reset", target: self, action: #selector(resetView)))
        controls.addArrangedSubview(NSButton(title: "Clear selection", target: self, action: #selector(clearSelection)))
        controls.addArrangedSubview(NSButton(title: "Reload", target: self, action: #selector(reloadGraph)))
        detailStack.addArrangedSubview(controls)
        let motion = NSButton(title: animation.enabled ? "Pause motion" : "Resume motion", target: self, action: #selector(toggleMotion))
        motionButton = motion; detailStack.addArrangedSubview(motion)
        let legend = NSTextField(wrappingLabelWithString: "CENTER · Listen on this Mac\n01  People   →   02  Notes\n03  Ask chats   →   04  Recordings\n\nAmbient motion is decorative, not live activity. Motion rests during selection or hover.")
        legend.font = .systemFont(ofSize: 11); legend.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(legend)
        guard let selectedID, let node = snapshot.nodes.first(where: { $0.id == selectedID }) else {
            let help = NSTextField(wrappingLabelWithString: "Drag to orbit. Shift-drag to pan. Scroll to zoom. Click a node to inspect its verified evidence.")
            help.textColor = .secondaryLabelColor
            detailStack.addArrangedSubview(help)
            let reset = NSButton(title: "Reset view", target: self, action: #selector(resetView))
            detailStack.addArrangedSubview(reset)
            return
        }
        let kind = NSTextField(labelWithString: node.kind.capitalized)
        kind.textColor = .secondaryLabelColor
        detailStack.addArrangedSubview(kind)
        let incident = snapshot.edges.filter { $0.source == selectedID || $0.target == selectedID }
        detailStack.addArrangedSubview(NSTextField(labelWithString: "\(incident.count) connected relationship\(incident.count == 1 ? "" : "s")"))
        let byID = Dictionary(snapshot.nodes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        for edge in incident.prefix(8) {
            let text = "\(byID[edge.source] ?? edge.source) → \(edge.label) → \(byID[edge.target] ?? edge.target)\n\(edge.kind) · \(edge.status)"
            let relationship = NSTextField(wrappingLabelWithString: text)
            relationship.font = .systemFont(ofSize: 11)
            detailStack.addArrangedSubview(relationship)
        }
        var seen = Set<String>()
        let evidence = (node.evidence + incident.flatMap(\.evidence)).filter { seen.insert($0.source + "\n" + $0.quote).inserted }
        if evidence.isEmpty { detailStack.addArrangedSubview(NSTextField(wrappingLabelWithString: "No evidence is attached to this item.")) }
        for item in evidence.prefix(12) {
            let button = EvidenceButton(title: item.title.isEmpty ? item.source : item.title, target: nil, action: nil)
            button.target = button
            button.action = #selector(EvidenceButton.activateEvidence)
            button.evidence = item
            button.invoke = { [weak self] in self?.onEvidence?($0) }
            button.alignment = .left
            button.bezelStyle = .rounded
            button.lineBreakMode = .byTruncatingTail
            detailStack.addArrangedSubview(button)
            if !item.quote.isEmpty { let quote = NSTextField(wrappingLabelWithString: item.quote); quote.textColor = .secondaryLabelColor; quote.font = .systemFont(ofSize: 11); detailStack.addArrangedSubview(quote) }
        }
    }

    @objc private func toggleMotion() { setMotionEnabled(!animation.enabled) }

    @objc private func clearSelection() { select(nil) }
    @objc private func reloadGraph() { onReload?() }

    @objc private func resetView() { select(nil); hoveredID = nil; motionTime = 0; camera.reset(); camera.frameGalaxy(aspect: Float(sceneHost.bounds.width / max(sceneHost.bounds.height, 1))); invalidate() }

    private func updateLabels() {
        labelUpdateCount += 1
        guard let metalView, metalView.bounds.width > 0, metalView.bounds.height > 0 else { return }
        labels.forEach { $0.removeFromSuperview() }; labels.removeAll(keepingCapacity: true)
        let size = metalView.drawableSize
        let projection = GraphCamera.perspectiveMatrix(fovyRadians: .pi / 4, aspect: Float(size.width / max(size.height, 1)), nearZ: 0.1, farZ: 200)
        let viewProjection = projection * camera.viewMatrix()
        let candidates: [(GraphNode, CGPoint)] = snapshot.nodes.compactMap { node in
            let position = GraphMotion.position(node.position, id: node.id, kind: node.kind, time: motionTime)
            let clip = viewProjection * SIMD4<Float>(position, 1)
            guard clip.w > 0, clip.z >= 0, clip.z <= clip.w else { return nil }
            let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
            guard abs(ndc.x) <= 1, abs(ndc.y) <= 1 else { return nil }
            return (node, CGPoint(x: CGFloat((ndc.x + 1) * 0.5) * metalView.bounds.width, y: CGFloat((ndc.y + 1) * 0.5) * metalView.bounds.height))
        }.sorted { simd_length_squared($0.0.position - camera.eye) < simd_length_squared($1.0.position - camera.eye) }
        let neighbors = Set(snapshot.edges.flatMap { edge in
            edge.source == selectedID || edge.target == selectedID ? [edge.source, edge.target] : []
        })
        let ranked = candidates.sorted { a, b in
            let pa = a.0.id == selectedID ? 4 : a.0.id == hoveredID ? 3 : a.0.kind == "device" ? 2 : (neighbors.contains(a.0.id) ? 1 : 0)
            let pb = b.0.id == selectedID ? 4 : b.0.id == hoveredID ? 3 : b.0.kind == "device" ? 2 : (neighbors.contains(b.0.id) ? 1 : 0)
            return pa == pb ? simd_length_squared(a.0.position - camera.eye) < simd_length_squared(b.0.position - camera.eye) : pa > pb
        }
        var occupied: [CGRect] = []
        for (node, point) in ranked {
            if labels.count >= 24 { break }
            let rect = CGRect(x: point.x + 8, y: point.y + 5, width: min(155, max(65, CGFloat(node.title.count) * 5.5)), height: 14)
            guard sceneHost.bounds.contains(rect), !occupied.contains(where: { $0.intersects(rect.insetBy(dx: -3, dy: -2)) }) else { continue }
            occupied.append(rect)
            let label = GraphLabel(labelWithString: node.title)
            label.font = .systemFont(ofSize: 10, weight: node.id == selectedID ? .semibold : .regular)
            label.textColor = .white
            label.backgroundColor = NSColor.black.withAlphaComponent(0.35)
            label.drawsBackground = true
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.frame = rect
            // Labels are capped and AppKit-only. Nodes and edges remain GPU-instanced/batched.
            sceneHost.addSubview(label); labels.append(label)
        }
    }

    // Focused controller-level test seams; production policy values remain sourced above.
    var testMetalView: MTKView? { metalView }
    var testCamera: GraphCamera { camera }
    var testFocusFlightGoal: GraphCamera? { focusFlight?.goal }
    var testRedrawRequestCount: Int { redrawRequestCount }
    var testLabelUpdateCount: Int { labelUpdateCount }
    func testStartFocusFlight(from start: GraphCamera, goal: GraphCamera) { camera = start; focusFlight = (start, goal, 0) }
    func testApplyAnimationPolicy(visible: Bool, reducedMotion: Bool, lowPower: Bool) {
        animation.visible = visible
        animation.reducedMotion = reducedMotion
        animation.lowPower = lowPower
        applyAnimationState()
    }
}
