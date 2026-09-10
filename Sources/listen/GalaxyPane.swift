import AppKit
import MetalKit
import simd

/// The galaxy as a screen in the library window.
///
/// **It is a way into the library, not a second library.** Every star is a
/// recording, note, person or conversation that already has a page, and the
/// only thing this pane does with a click is hand that page's identifier back
/// to `LibraryWindow`. There is no editing here, no second copy of anything on
/// disk, and no state that outlives the snapshot: closing it loses nothing.
///
/// The chrome is deliberately small. The window already has a sidebar, a
/// toolbar and the Ask bar; a fourth column of controls inside the scene would
/// leave the picture as a strip. So: a legend in one corner, two buttons in
/// another, and a card that appears only when something is selected.
final class GalaxyPane: NSViewController, MTKViewDelegate {

    /// Open the thing a star stands for. The id is `Galaxy.Node.id`, and
    /// `Galaxy.subject(of:)` is what turns it back into a library identifier.
    var onOpen: ((String) -> Void)?

    private var snapshot = Galaxy.Snapshot()
    private var renderer: GalaxyRenderer?
    private var camera = GalaxyCamera()
    private var policy = GalaxyMotionPolicy()
    private var motionTime: Double = 0
    private var lastFrameTime: Double?
    private var lastLabelTime: Double = 0
    private var selectedID: String?
    private var hoveredID: String?
    private var dragging = false
    private var focusFlight: (start: GalaxyCamera, goal: GalaxyCamera, elapsed: Double)?
    private var hasFramedForRealSize = false
    private var loading = false
    private var reloadPending = false
    private var observing = false
    /// Shells the reader has struck out in the legend.
    ///
    /// A lens over the snapshot rather than a narrower read of the library:
    /// hiding notes is a question about the picture, not about what is on
    /// disk, and it has to come straight back. It lives as long as the window,
    /// which is how the library's own filters behave, and reaches no
    /// preference: a filter that outlives a session is one somebody finds
    /// applied a week later with no memory of setting it.
    private var hiddenKinds: Set<String> = []

    /// What is actually drawn: the snapshot minus the struck-out shells, and
    /// any link with an end in one of them. Computed rather than stored, so
    /// there is one snapshot on this pane and no second copy to go stale.
    private var visible: Galaxy.Snapshot {
        guard !hiddenKinds.isEmpty else { return snapshot }
        let nodes = snapshot.nodes.filter { !hiddenKinds.contains($0.kind) }
        let ids = Set(nodes.map(\.id))
        return Galaxy.Snapshot(nodes: nodes,
                               edges: snapshot.edges.filter { ids.contains($0.source) && ids.contains($0.target) },
                               label: snapshot.label)
    }
    /// Bumped whenever the snapshot is replaced, so the label pass can tell a
    /// new library from the same one without comparing every node.
    private var snapshotGeneration = 0
    /// And whenever what is *drawn* changes, which a struck-out shell does
    /// without the snapshot moving at all.
    private var renderGeneration = 0

    /// Everything the label layout depends on. See `updateLabels`.
    ///
    /// **`reserved` is part of it, and leaving it out was a bug.** The pass
    /// refuses any title that would land under the legend, the status line, the
    /// controls or the inspector card, and all four of those move: the card
    /// grows with the number of links on the star, and the controls and the
    /// card both slide up as the Ask bar grows. Keyed on the camera alone, the
    /// corrective pass those movements trigger was skipped and the titles
    /// stayed under them.
    ///
    /// It cannot re-open the loop the memo exists to break: the labels are
    /// positioned by frame and move none of those four views, so the rects
    /// settle after one pass and the next comparison is equal.
    private struct LabelState: Equatable {
        var camera: GalaxyCamera
        var time: Double
        var selected: String?
        var hovered: String?
        var size: CGSize
        var generation: Int
        var reserved: [CGRect]
    }
    private var labelState: LabelState?

    private var metalView: GalaxyMetalView?
    private var labels: [NSTextField] = []
    private let legend = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let failureLabel = NSTextField(wrappingLabelWithString: "")
    private let controls = NSStackView()
    private let motionButton = NSButton()
    private let inspector = GalaxyInspector()
    private var controlsBottom: NSLayoutConstraint!
    private var inspectorBottom: NSLayoutConstraint!
    private var bottomInset: CGFloat = 0
    private var legendHasChats = false
    private var legendCentreTitle = ""

    /// The sky the renderer clears to, and the one colour the pane, the
    /// shader and the window's sidebar all have to agree on. Stated once
    /// because two of them disagreeing is visible as a seam down the window.
    static let sky = NSColor(srgbRed: CGFloat(GalaxyRenderer.sky.x),
                            green: CGFloat(GalaxyRenderer.sky.y),
                            blue: CGFloat(GalaxyRenderer.sky.z), alpha: 1)

    /// Counters the verification script reads. Nothing else may.
    private(set) var renderedFrameCount = 0
    private(set) var redrawRequestCount = 0
    private(set) var labelUpdateCount = 0
    private(set) var isAnimating = false

    // -----------------------------------------------------------------------
    // View
    // -----------------------------------------------------------------------

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        // The scene is a dark sky whatever the app's appearance is, because the
        // renderer paints one and a light chrome over it would be unreadable.
        root.appearance = NSAppearance(named: .darkAqua)
        root.wantsLayer = true
        root.layer?.backgroundColor = Self.sky.cgColor
        view = root
        installMetalView()
        installChrome()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.acceptsMouseMovedEvents = true
        // Registered once. `PaneHost.show` takes the pane out of the window
        // and puts it back, and a second registration for the same selector is
        // a second call, not a no-op.
        guard !observing else { refreshMotionPolicy(); return }
        observing = true
        let centre = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            centre.addObserver(self, selector: #selector(refreshMotionPolicy), name: name, object: nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshMotionPolicy),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshMotionPolicy()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // Not merely paused: a pane the window has swapped away is a pane
        // nobody can see, and a Metal view still asking for frames behind
        // Settings is a battery cost for nothing.
        //
        // The observers stay. They are what would notice the window coming
        // back, and `refreshMotionPolicy` reads the view hierarchy rather than
        // this flag, so a missed callback cannot leave the GPU running.
        refreshMotionPolicy()
        lastFrameTime = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The first real size only. Re-framing on every layout would undo the
        // reader's own orbit and zoom the moment they resized the window.
        if !hasFramedForRealSize, view.bounds.width > 1, view.bounds.height > 1 {
            hasFramedForRealSize = true
            camera.frameGalaxy(aspect: Float(view.bounds.width / view.bounds.height))
        }
        invalidate()
    }

    /// Keep the floating controls clear of the Ask bar. See
    /// `LibraryWindow.onDrawerHeight`.
    func setBottomInset(_ points: CGFloat) {
        guard bottomInset != points else { return }
        bottomInset = points
        controlsBottom?.constant = -(16 + points)
        inspectorBottom?.constant = -(16 + points)
        // The controls and the card have moved, so the titles that were told
        // to keep clear of them have to be laid out again.
        invalidate()
    }

    private func installMetalView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            showFailure(GalaxyRendererError.metalUnavailable.localizedDescription); return
        }
        do {
            let renderer = try GalaxyRenderer(device: device)
            self.renderer = renderer
            renderer.onError = { [weak self] message in
                DispatchQueue.main.async { self?.setMotionEnabled(false); self?.showFailure(message) }
            }
            camera.frameGalaxy()
            renderer.update(snapshot: visible, selectionID: nil)
            let metal = GalaxyMetalView(frame: .zero, device: device)
            metal.translatesAutoresizingMaskIntoConstraints = false
            metal.colorPixelFormat = .bgra8Unorm
            metal.depthStencilPixelFormat = .depth32Float
            metal.preferredFramesPerSecond = 30
            metal.enableSetNeedsDisplay = true
            metal.isPaused = true
            metal.delegate = self
            metal.onClick = { [weak self] point, clicks in self?.click(point, clicks: clicks) }
            metal.onHover = { [weak self] point in self?.hover(point) }
            metal.onInteraction = { [weak self] active in
                self?.dragging = active
                if active { self?.focusFlight = nil }
                self?.refreshMotionPolicy()
            }
            metal.onOrbit = { [weak self] x, y in
                guard let height = self?.metalView?.bounds.height else { return }
                self?.moveCamera { $0.orbit(deltaX: Float(x), deltaY: Float(y), viewportHeight: Float(height)) }
            }
            metal.onPan = { [weak self] x, y in
                guard let size = self?.metalView?.bounds else { return }
                self?.moveCamera { $0.pan(deltaX: Float(x), deltaY: Float(y),
                                          viewportSize: SIMD2(Float(size.width), Float(size.height))) }
            }
            metal.onZoom = { [weak self] delta in self?.moveCamera { $0.zoom(delta: Float(delta)) } }
            view.addSubview(metal)
            NSLayoutConstraint.activate([
                metal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                metal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                metal.topAnchor.constraint(equalTo: view.topAnchor),
                metal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            metalView = metal
            // **What VoiceOver is told this is.** A Metal view is one opaque
            // element, and the stars inside it are pixels rather than views, so
            // there is nothing here to read or to move between. Saying so, and
            // saying where the same things *can* be reached, is the honest
            // answer: the sidebar beside this pane is the same library as a
            // list, and it is fully navigable. `updateStatus` keeps the counts
            // in this sentence current.
            metal.setAccessibilityRole(.image)
            metal.setAccessibilityRoleDescription("galaxy")
            updateSceneAccessibility()
        } catch {
            showFailure(error.localizedDescription)
        }
    }

    private func installChrome() {
        legend.orientation = .vertical
        legend.alignment = .leading
        legend.spacing = 5
        legend.translatesAutoresizingMaskIntoConstraints = false
        legend.setAccessibilityLabel("What the shells are, from the centre outwards")
        buildLegend()
        view.addSubview(legend)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.5)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.maximumNumberOfLines = 3
        view.addSubview(statusLabel)

        failureLabel.font = .systemFont(ofSize: 13, weight: .medium)
        failureLabel.textColor = .systemRed
        failureLabel.alignment = .center
        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        failureLabel.isHidden = true
        view.addSubview(failureLabel)

        controls.orientation = .horizontal
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        let reset = NSButton(title: "Reset view", target: self, action: #selector(resetView))
        reset.bezelStyle = .rounded
        reset.setAccessibilityLabel("Reset view")
        motionButton.target = self
        motionButton.action = #selector(toggleMotion)
        motionButton.bezelStyle = .rounded
        motionButton.title = "Pause motion"
        controls.addArrangedSubview(reset)
        controls.addArrangedSubview(motionButton)
        view.addSubview(controls)

        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspector.isHidden = true
        inspector.onOpen = { [weak self] in
            guard let id = self?.selectedID else { return }
            self?.onOpen?(id)
        }
        inspector.onClear = { [weak self] in self?.select(nil) }
        view.addSubview(inspector)

        controlsBottom = controls.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        inspectorBottom = inspector.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            legend.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            legend.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: legend.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: legend.bottomAnchor, constant: 14),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            failureLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            failureLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            failureLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            controls.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            controlsBottom,
            inspector.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            inspectorBottom,
            inspector.widthAnchor.constraint(equalToConstant: 300),
            // Never taller than the pane, or a conversation with a long title
            // pushes its own Open button off the bottom of the window.
            inspector.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: 18),
        ])
    }

    private func buildLegend() {
        let wantsChats = Settings.askEnabled
        // The centre's row is named after you, and the name arrives with the
        // first snapshot: built once, the row kept the "This Mac" placeholder
        // it was created with before anything had been read off disk.
        // The star carries the name; the row says what the centre is. Somebody
        // scanning the legend is asking which colour means what, and "Maxime"
        // on its own does not answer that.
        let centre = (snapshot.nodes.first { $0.kind == Galaxy.Node.device }?.title).map { "\($0) (this Mac)" }
            ?? "This Mac"
        guard legend.arrangedSubviews.isEmpty || wantsChats != legendHasChats
                || centre != legendCentreTitle else { return }
        legendHasChats = wantsChats
        legendCentreTitle = centre
        legend.arrangedSubviews.forEach { legend.removeArrangedSubview($0); $0.removeFromSuperview() }
        let heading = NSTextField(labelWithString: "FROM THE CENTRE OUTWARDS")
        heading.font = .systemFont(ofSize: 9, weight: .semibold)
        heading.textColor = NSColor.white.withAlphaComponent(0.45)
        legend.addArrangedSubview(heading)
        var rows: [(String, String)] = [
            (Galaxy.Node.device, centre),
            (Galaxy.Node.person, "People"), (Galaxy.Node.note, "Notes"),
        ]
        // **No Chats row with Ask off.** `Galaxy.build` reads no conversations
        // then, so the row would name a shell that is always empty, which
        // reads as a shell that is broken.
        if wantsChats { rows.append((Galaxy.Node.chat, "Chats")) }
        rows.append((Galaxy.Node.recording, "Recordings"))
        for (kind, name) in rows {
            let row = GalaxyLegendRow(kind: kind, name: name,
                                      action: #selector(toggleShell(_:)), target: self)
            row.apply(hidden: hiddenKinds.contains(kind))
            legend.addArrangedSubview(row)
        }
    }

    /// Hide or show one shell. The legend is the control, because the legend is
    /// already the list of what is on screen and a second list beside it would
    /// be the same names twice.
    @objc private func toggleShell(_ sender: GalaxyLegendRow) {
        if hiddenKinds.contains(sender.kind) { hiddenKinds.remove(sender.kind) }
        else { hiddenKinds.insert(sender.kind) }
        sender.apply(hidden: hiddenKinds.contains(sender.kind))
        // A star that has just been hidden cannot stay selected: its card would
        // offer to open something the reader can no longer see or click.
        if let id = selectedID, let node = snapshot.node(id), hiddenKinds.contains(node.kind) {
            select(nil)
        }
        renderGeneration += 1
        pushToRenderer()
        updateStatus()
        invalidate()
    }

    private func showFailure(_ message: String) {
        failureLabel.stringValue = message
        failureLabel.isHidden = false
    }

    /// What the pane is showing, for the verification script. Nil when healthy.
    var visibleFailureText: String? { failureLabel.isHidden ? nil : failureLabel.stringValue }

    // -----------------------------------------------------------------------
    // The snapshot
    // -----------------------------------------------------------------------

    /// Rebuild from the library, off the main thread.
    ///
    /// **Coalesced rather than queued.** The window reloads on activation, on a
    /// recording arriving and on the queue advancing, and three passes over the
    /// library for one visible change is three passes nobody asked for. A
    /// request that arrives while one is running sets a flag and the running
    /// one repeats itself once.
    func reload() {
        guard !loading else { reloadPending = true; return }
        loading = true
        updateStatus()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let built = Galaxy.build()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                self.apply(built)
                if self.reloadPending { self.reloadPending = false; self.reload() }
            }
        }
    }

    private func pushToRenderer() {
        renderer?.update(snapshot: visible, selectionID: selectedID, hoverID: hoveredID)
    }

    private func apply(_ built: Galaxy.Snapshot) {
        snapshot = built
        snapshotGeneration += 1
        renderGeneration += 1
        // `Galaxy.build` re-reads `Settings.askEnabled` every time, and the
        // switch is in the same window: the legend has to be rebuilt with the
        // scene or it keeps a key for a shell that is gone, or loses the key
        // for one that has come back.
        buildLegend()
        trace("galaxy snapshot \(built.nodes.count) stars \(built.edges.count) links")
        // A star that has gone from the library cannot stay selected: the card
        // would offer to open a recording that is not there any more.
        if let id = selectedID, built.node(id) == nil { select(nil) }
        pushToRenderer()
        updateStatus()
        updateInspector()
        invalidate()
    }

    private func updateStatus() {
        if loading && snapshot.nodes.isEmpty {
            statusLabel.stringValue = "Reading your library…"
        } else if snapshot.nodes.count <= 1 {
            statusLabel.stringValue = "Nothing to draw yet. Record something, or write a note,"
                + " and it appears here."
        } else {
            let drawn = visible
            var text = snapshot.label
                + "\n\(drawn.edges.count) \(drawn.edges.count == 1 ? "link" : "links"),"
                + " each one already written down."
            // Struck out, not lost. A shell hidden from the legend takes its
            // stars and its links with it, and a count that quietly shrank
            // would read as the library having lost something.
            if !hiddenKinds.isEmpty {
                let missing = max(0, snapshot.nodes.count - drawn.nodes.count)
                text += "\n\(missing) hidden by the legend."
            }
            statusLabel.stringValue = text
        }
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
        updateSceneAccessibility()
    }

    private func updateSceneAccessibility() {
        let drawn = visible
        let stars = max(0, drawn.nodes.count - 1)
        metalView?.setAccessibilityLabel(
            stars == 0
                ? "Your library as a picture. Nothing to draw yet."
                : "Your library as a picture: \(stars) "
                  + "\(stars == 1 ? "star" : "stars") on four shells around this Mac, "
                  + "\(drawn.edges.count) \(drawn.edges.count == 1 ? "link" : "links"). "
                  + "The stars are drawn rather than laid out, so they cannot be "
                  + "reached from here. The list beside this pane is the same "
                  + "library, and every row in it opens the same page.")
    }

    // -----------------------------------------------------------------------
    // Motion policy
    // -----------------------------------------------------------------------

    @objc func refreshMotionPolicy() {
        // **`view.window` first, and it is the load-bearing half.** A pane the
        // window has swapped out has no window, which is the one signal that
        // cannot be missed: relying on `viewDidDisappear` to set a flag would
        // leave the GPU drawing behind Settings on any path where AppKit does
        // not call it.
        policy.visible = !view.isHiddenOrHasHiddenAncestor && (view.window.map {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) && !NSApp.isHidden
        } ?? false)
        policy.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        policy.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        applyMotionPolicy()
    }

    func setMotionEnabled(_ enabled: Bool) {
        policy.enabled = enabled
        motionButton.title = enabled ? "Pause motion" : "Resume motion"
        motionButton.setAccessibilityLabel(enabled ? "Pause motion" : "Resume motion")
        applyMotionPolicy()
    }

    private func applyMotionPolicy() {
        policy.interacting = dragging || hoveredID != nil || selectedID != nil || focusFlight != nil
        // A flight that policy has just forbidden lands where it was going,
        // rather than stopping half way: the camera, the labels and picking all
        // read the same position, so a frozen intermediate frame would be a
        // picture nobody could click accurately.
        var snapped = false
        if let flight = focusFlight, !policy.flights {
            camera = flight.goal
            focusFlight = nil
            snapped = true
        }
        let wasAnimating = isAnimating
        isAnimating = policy.ambient
        let continuous = isAnimating || (focusFlight != nil && policy.flights)
        // Whether the GPU is running, and why not when it is not. Invisible to
        // the accessibility tree and to a screenshot alike, which is why
        // `verify_galaxy.sh` reads it out of the trace the way the find bar's
        // scroll position is read. See `.agents/notes/window.md`.
        if wasAnimating != isAnimating {
            trace("galaxy motion \(isAnimating ? "on" : "off")"
                  + " enabled=\(policy.enabled) visible=\(policy.visible)"
                  + " reduced=\(policy.reducedMotion) lowPower=\(policy.lowPower)"
                  + " interacting=\(policy.interacting)")
        }
        // The clock restarts whenever the view stops or starts drawing, or the
        // first frame after a pause advances the world by the length of the pause.
        if metalView?.isPaused == continuous { lastFrameTime = nil }
        metalView?.isPaused = !continuous
        motionButton.title = policy.enabled ? "Pause motion" : "Resume motion"
        if snapped { invalidate() }
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    func draw(in view: MTKView) {
        guard let renderer, let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = min(0.1, max(0, now - (lastFrameTime ?? now)))
        lastFrameTime = now
        if isAnimating { motionTime += delta }
        if var flight = focusFlight, policy.flights {
            flight.elapsed += delta
            camera = flight.start.interpolated(to: flight.goal, progress: Float(flight.elapsed / 0.65))
            focusFlight = flight.elapsed >= 0.65 ? nil : flight
            if focusFlight == nil { refreshMotionPolicy() }
        }
        // Ten times a second, not thirty: rebuilding two dozen NSTextFields on
        // every frame is the one part of this that is not on the GPU.
        if now - lastLabelTime > 0.1 { updateLabels(); lastLabelTime = now }
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(GalaxyRenderer.sky.x), green: Double(GalaxyRenderer.sky.y),
            blue: Double(GalaxyRenderer.sky.z), alpha: 1)
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.clearDepth = 1
        renderer.draw(renderPassDescriptor: descriptor, drawable: drawable,
                      viewportSize: view.drawableSize, camera: camera, time: motionTime)
        renderedFrameCount += 1
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { invalidate() }

    private func invalidate() {
        redrawRequestCount += 1
        metalView?.setNeedsDisplay(metalView?.bounds ?? .zero)
        updateLabels()
    }

    private func moveCamera(_ body: (inout GalaxyCamera) -> Void) {
        focusFlight = nil
        body(&camera)
        refreshMotionPolicy()
        invalidate()
    }

    // -----------------------------------------------------------------------
    // Selection
    // -----------------------------------------------------------------------

    private func click(_ point: CGPoint, clicks: Int) {
        guard let id = star(at: point) else { select(nil); return }
        // A double click is the shortcut past the card: it is what a row in the
        // sidebar does, and a star should not need two gestures where a row
        // needs one.
        if clicks > 1, Galaxy.subject(of: id) != nil { onOpen?(id); return }
        select(id)
    }

    private func hover(_ point: CGPoint?) {
        let id = point.flatMap { star(at: $0) }
        guard id != hoveredID else { return }
        hoveredID = id
        pushToRenderer()
        refreshMotionPolicy()
        invalidate()
    }

    private func star(at point: CGPoint) -> String? {
        guard let metalView, let renderer else { return nil }
        let scale = metalView.window?.backingScaleFactor ?? 1
        // The Metal view is unflipped and the drawable is not, so the y has to
        // be turned over before it means the same thing to both.
        let screen = SIMD2<Float>(Float(point.x * scale), Float((metalView.bounds.height - point.y) * scale))
        return renderer.pick(screenPoint: screen,
                             viewportSize: SIMD2(Float(metalView.drawableSize.width),
                                                 Float(metalView.drawableSize.height)),
                             camera: camera, time: motionTime)
    }

    /// Select a star by id, or nothing. Public so a verification script can
    /// drive what a click drives.
    func select(_ id: String?) {
        let wanted = id.flatMap { visible.node($0) }?.id
        selectedID = wanted
        hoveredID = nil
        renderer?.update(snapshot: visible, selectionID: wanted)
        if let node = wanted.flatMap({ visible.node($0) }) {
            let position = GalaxyMotion.position(node.position, kind: node.kind, time: motionTime)
            let aspect = Float(view.bounds.width / max(view.bounds.height, 1))
            let goal: GalaxyCamera
            if node.kind == Galaxy.Node.device {
                // The centre links to nothing, so there is no neighbourhood to
                // frame: this is "show me the whole thing" and it is framed as
                // the opening view is.
                var whole = camera
                whole.frameGalaxy(aspect: aspect)
                goal = whole
            } else {
                // Everything this star links to, so the answer to "what is this
                // connected to" is on screen rather than off the edges.
                let linked = Set(visible.edges.compactMap { edge -> String? in
                    edge.source == node.id ? edge.target : edge.target == node.id ? edge.source : nil
                })
                let positions = visible.nodes.filter { linked.contains($0.id) }
                    .map { GalaxyMotion.position($0.position, kind: $0.kind, time: motionTime) }
                goal = camera.focused(on: position, including: positions, aspect: aspect)
            }
            if policy.flights { focusFlight = (camera, goal, 0) } else { camera = goal; focusFlight = nil }
        } else {
            focusFlight = nil
        }
        refreshMotionPolicy()
        updateInspector()
        invalidate()
    }

    var selection: String? { selectedID }

    private func updateInspector() {
        guard let id = selectedID, let node = visible.node(id) else {
            inspector.isHidden = true
            return
        }
        let links = visible.edges.filter { $0.source == id || $0.target == id }
        let titles = Dictionary(visible.nodes.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        inspector.show(node: node, links: links, titles: titles,
                       openable: Galaxy.subject(of: id) != nil)
        inspector.isHidden = false
    }

    @objc private func toggleMotion() { setMotionEnabled(!policy.enabled) }

    @objc private func resetView() {
        select(nil)
        hoveredID = nil
        motionTime = 0
        camera.reset()
        camera.frameGalaxy(aspect: Float(view.bounds.width / max(view.bounds.height, 1)))
        invalidate()
    }

    // -----------------------------------------------------------------------
    // Labels
    // -----------------------------------------------------------------------

    /// Up to two dozen titles, laid out so none overlaps another.
    ///
    /// AppKit text fields rather than glyphs in the shader, because these are
    /// the app's own font at the app's own size and a bitmap atlas would be a
    /// second typographic system to keep agreeing with the first. The cap is
    /// what keeps that affordable: the stars and lines stay GPU-instanced.
    private struct Candidate { let node: Galaxy.Node; let point: CGPoint; let depth: Float; let priority: Int }

    private func updateLabels() {
        guard let metalView, metalView.bounds.width > 0, metalView.bounds.height > 0 else { return }
        // **Nothing to do is a return.** Rebuilding two dozen text fields is
        // the one part of this pane that is not on the GPU, and `invalidate`
        // reaches here from the camera, the selection, a layout and a reload
        // alike, most of which change nothing a label depends on.
        //
        // It also closes a loop that review argued for and measurement has not
        // shown: these labels have autoresizing frames in an Auto-Layout
        // superview, so removing and re-adding them could mark the pane as
        // needing layout, which calls `viewDidLayout`, which calls
        // `invalidate`, which lands back here. Against that, the prototype's
        // smoke test measured exactly 0 frames over half a second with the
        // motion paused, five runs, which a live loop would not allow. So the
        // saving is the reason and the loop is insurance.
        // The corners the chrome occupies, so a title never lands under the
        // legend or behind the inspector card. Part of the key as well as the
        // layout: see `LabelState`.
        let reserved = [legend.frame, statusLabel.frame, controls.frame,
                        inspector.isHidden ? .zero : inspector.frame].map { $0.insetBy(dx: -6, dy: -6) }
        let state = LabelState(camera: camera, time: motionTime, selected: selectedID,
                               hovered: hoveredID, size: metalView.bounds.size,
                               generation: renderGeneration, reserved: reserved)
        guard state != labelState else { return }
        labelState = state
        labelUpdateCount += 1
        labels.forEach { $0.removeFromSuperview() }
        labels.removeAll(keepingCapacity: true)
        let size = metalView.drawableSize
        let projection = GalaxyCamera.perspectiveMatrix(aspect: Float(size.width / max(size.height, 1)))
        let viewProjection = projection * camera.viewMatrix()
        let drawn = visible
        let neighbours = Set(drawn.edges.flatMap { edge -> [String] in
            edge.source == selectedID || edge.target == selectedID ? [edge.source, edge.target] : []
        })
        // Ranked on the position the star is drawn at, not the one the layout
        // gave it: those differ by the ambient rotation, and ranking on the
        // wrong one labels a different set of stars from the ones in front.
        let candidates: [Candidate] = drawn.nodes.compactMap { node in
            let position = GalaxyMotion.position(node.position, kind: node.kind, time: motionTime)
            let clip = viewProjection * SIMD4<Float>(position, 1)
            guard clip.w > 0, clip.z >= 0, clip.z <= clip.w else { return nil }
            let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
            guard abs(ndc.x) <= 1, abs(ndc.y) <= 1 else { return nil }
            let priority = node.id == selectedID ? 4 : node.id == hoveredID ? 3
                : node.kind == Galaxy.Node.device ? 2 : (neighbours.contains(node.id) ? 1 : 0)
            return Candidate(node: node,
                             point: CGPoint(x: CGFloat((ndc.x + 1) * 0.5) * metalView.bounds.width,
                                            y: CGFloat((ndc.y + 1) * 0.5) * metalView.bounds.height),
                             depth: simd_length_squared(position - camera.eye), priority: priority)
        }
        // **A turn each, by shell.** Sorted by depth alone, the whole budget of
        // 24 went to the outer shell: the near face of the recordings sphere is
        // always the nearest thing to the camera, so on a real library not one
        // person was ever named, on a screen whose legend says People. So the
        // stars the reader asked for go first, and then the four shells take
        // turns. A person is the most nameable thing here and a recording the
        // least: it already has a title and a date in the list beside this.
        let asked = candidates.filter { $0.priority > 0 }
            .sorted { $0.priority == $1.priority ? $0.depth < $1.depth : $0.priority > $1.priority }
        // **With a star selected, name it and what it links to, and nothing
        // else.** The rest are dimmed to context, so labelling them puts
        // twenty unrelated titles over a picture whose whole point at that
        // moment is one thing and its neighbours. The turn-taking below is for
        // the unselected view, where there is no answer to be crowded out.
        guard selectedID == nil else {
            layOut(asked, in: metalView)
            return
        }
        var queues: [[Candidate]] = [Galaxy.Node.person, Galaxy.Node.note,
                                     Galaxy.Node.chat, Galaxy.Node.recording].map { kind in
            candidates.filter { $0.priority == 0 && $0.node.kind == kind }.sorted { $0.depth < $1.depth }
        }
        var ranked = asked
        while queues.contains(where: { !$0.isEmpty }) {
            for index in queues.indices where !queues[index].isEmpty {
                ranked.append(queues[index].removeFirst())
            }
        }
        layOut(ranked, in: metalView)
    }

    /// Place as many of these titles as fit without overlapping each other or
    /// the chrome, in the order given.
    private func layOut(_ ranked: [Candidate], in metalView: MTKView) {
        let reserved = labelState?.reserved ?? []
        var occupied: [CGRect] = []
        for candidate in ranked {
            if labels.count >= 24 { break }
            let node = candidate.node
            let font = NSFont.systemFont(ofSize: 10, weight: node.id == selectedID ? .semibold : .regular)
            // Measured, not counted. A character count as a width drew
            // "Casey Wright" as "Casey Wri…" in the prototype this came from.
            let measured = (node.title as NSString).size(withAttributes: [.font: font]).width
            let rect = CGRect(x: candidate.point.x + 8, y: candidate.point.y + 5,
                              width: min(180, ceil(measured) + 6), height: 14)
            guard view.bounds.contains(rect),
                  !reserved.contains(where: { $0.intersects(rect) }),
                  !occupied.contains(where: { $0.intersects(rect.insetBy(dx: -3, dy: -2)) }) else { continue }
            occupied.append(rect)
            let label = GalaxyLabel(labelWithString: node.title)
            label.font = font
            label.textColor = .white
            label.backgroundColor = NSColor.black.withAlphaComponent(0.38)
            label.drawsBackground = true
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.frame = rect
            view.addSubview(label, positioned: .below, relativeTo: legend)
            labels.append(label)
        }
    }

    // -----------------------------------------------------------------------
    // Seams the verification script uses, and nothing else
    // -----------------------------------------------------------------------

    var testMetalView: MTKView? { metalView }
    var testRenderer: GalaxyRenderer? { renderer }
    var testSnapshot: Galaxy.Snapshot { snapshot }
    var testFocusFlightGoal: GalaxyCamera? { focusFlight?.goal }
    var testCamera: GalaxyCamera { camera }
    func testApply(_ built: Galaxy.Snapshot) { apply(built) }
    func testStartFocusFlight(from start: GalaxyCamera, goal: GalaxyCamera) {
        camera = start
        focusFlight = (start, goal, 0)
    }
    func testApplyMotionPolicy(visible: Bool, reducedMotion: Bool, lowPower: Bool) {
        policy.visible = visible
        policy.reducedMotion = reducedMotion
        policy.lowPower = lowPower
        applyMotionPolicy()
    }
    var testMotionDiagnostics: [String: Bool] {
        ["enabled": policy.enabled, "visible": policy.visible, "reduced_motion": policy.reducedMotion,
         "low_power": policy.lowPower, "interacting": policy.interacting,
         "window_visible": view.window?.isVisible ?? false,
         "window_unoccluded": view.window?.occlusionState.contains(.visible) ?? false,
         "app_hidden": NSApp.isHidden]
    }
}

/// A label that is drawn over the scene and never in the way of a click.
private final class GalaxyLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// One shell in the legend, and the switch that hides it.
///
/// **A real `NSButton`, not a view with a click handler.** Every popover row in
/// this app is a plain `NSView` with a target and an action, which makes it
/// invisible to accessibility and unreachable from a script; see the note in
/// CLAUDE.md about `HoverRow`. A button gets a name, a pressed state and a
/// place in the key view loop for free, and `verify_galaxy.sh` can press it.
///
/// The dot is a bullet in the shell's own colour inside the attributed title
/// rather than a separate view, so the strike-through that says "hidden" runs
/// through the whole row the way a struck-out line should.
private final class GalaxyLegendRow: NSButton {
    let kind: String
    private let name: String

    init(kind: String, name: String, action: Selector, target: AnyObject) {
        self.kind = kind
        self.name = name
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        alignment = .left
        font = .systemFont(ofSize: 11)
        setAccessibilityRole(.checkBox)
        apply(hidden: false)
    }
    required init?(coder: NSCoder) { nil }

    func apply(hidden: Bool) {
        let colour = GalaxyRenderer.starColor(kind: kind)
        let dot = NSColor(red: CGFloat(colour.x), green: CGFloat(colour.y),
                          blue: CGFloat(colour.z), alpha: hidden ? 0.28 : 1)
        let text = NSMutableAttributedString(
            string: "\u{25CF}  ", attributes: [.foregroundColor: dot, .font: NSFont.systemFont(ofSize: 8)])
        var style: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(hidden ? 0.32 : 0.72),
            .font: NSFont.systemFont(ofSize: 11),
        ]
        if hidden { style[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        text.append(NSAttributedString(string: name, attributes: style))
        attributedTitle = text
        // **Both, and the title is the one a probe can see.** An attributed
        // title leaves `AXTitle` empty, so the row was in the tree with three
        // blank columns and `verify_galaxy.sh` could not find it. The label is
        // what a screen reader reads; the title is what everything else does.
        setAccessibilityTitle(name)
        setAccessibilityLabel(name)
        setAccessibilityValue(hidden ? "hidden" : "shown")
        toolTip = hidden ? "Show \(name.lowercased())" : "Hide \(name.lowercased())"
    }
}

/// The card that appears when a star is selected.
///
/// It says what the thing is, what it is connected to and how to open it. It
/// does not try to be the page: a recording's transcript, a note's text and a
/// conversation's turns all live somewhere that already shows them properly,
/// and Open is the whole point of the card.
final class GalaxyInspector: NSVisualEffectView {
    var onOpen: (() -> Void)?
    var onClear: (() -> Void)?

    private let stack = NSStackView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let kind = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let links = NSStackView()
    private let openButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // **The sidebar's own material**, so the card reads as part of this
        // window rather than as a tooltip drawn on top of it. It was a flat
        // near-black with a hairline border, which is what a panel over a
        // scene looks like in a game and not what anything else here looks
        // like. `.withinWindow` because what is behind it is the scene.
        material = .sidebar
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .white
        title.maximumNumberOfLines = 3
        kind.font = .systemFont(ofSize: 10, weight: .semibold)
        kind.textColor = NSColor.white.withAlphaComponent(0.5)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = NSColor.white.withAlphaComponent(0.66)
        detail.maximumNumberOfLines = 2
        links.orientation = .vertical
        links.alignment = .leading
        links.spacing = 3
        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(open)
        let row = NSStackView(views: [openButton])
        row.orientation = .horizontal
        row.spacing = 8

        for item in [kind, title, detail] { stack.addArrangedSubview(item) }
        stack.addArrangedSubview(links)
        stack.addArrangedSubview(row)
        // A wrapping label reports its whole string as one line's worth of
        // width and is then clipped by the card. Only this makes it wrap.
        for item in [title, detail] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        // **A cross in the corner, where every other page in this window puts
        // the way out.** It was a "Clear" button beside Open, which read as a
        // second verb on the thing being described rather than as dismissing
        // the card, and put the two at the same weight.
        addSubview(close)
        close.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            close.widthAnchor.constraint(equalToConstant: 22),
            close.heightAnchor.constraint(equalToConstant: 22),
            // The card's own text stops short of it, or a long kind word runs
            // underneath the button.
            kind.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
        ])
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }

    /// The way out, as the round glass cross this window uses everywhere else.
    private lazy var close: NSView = {
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .withinWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 11
        glass.layer?.masksToBounds = true
        // The material alone is nearly invisible against this ground, which is
        // most of the point of the ground. A little white over it gives the
        // circle the same presence the window's own cross has.
        glass.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        let button = NSButton(image: NSImage(systemSymbolName: "xmark",
                                             accessibilityDescription: "Clear selection") ?? NSImage(),
                              target: self, action: #selector(clear))
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.setAccessibilityLabel("Clear selection")
        button.toolTip = "Clear selection"
        button.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            button.topAnchor.constraint(equalTo: glass.topAnchor),
            button.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        return glass
    }()

    func show(node: Galaxy.Node, links edges: [Galaxy.Edge], titles: [String: String], openable: Bool) {
        title.stringValue = node.title
        kind.stringValue = Self.word(for: node).uppercased()
        detail.stringValue = node.detail
        detail.isHidden = node.detail.isEmpty
        links.arrangedSubviews.forEach { links.removeArrangedSubview($0); $0.removeFromSuperview() }
        let heading = NSTextField(labelWithString: edges.isEmpty
            ? "Nothing links to this yet"
            : "\(edges.count) \(edges.count == 1 ? "link" : "links")")
        heading.font = .systemFont(ofSize: 11, weight: .medium)
        heading.textColor = NSColor.white.withAlphaComponent(0.72)
        links.addArrangedSubview(heading)
        // Four, then a count. The card is a card; the page it opens is where
        // the whole list belongs.
        for edge in edges.prefix(4) {
            let other = edge.source == node.id ? edge.target : edge.source
            let line = NSTextField(labelWithString: "\(edge.phrase(from: node.id)) \(titles[other] ?? other)")
            line.font = .systemFont(ofSize: 11)
            line.textColor = NSColor.white.withAlphaComponent(0.55)
            line.lineBreakMode = .byTruncatingTail
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // Added first. A constraint between two views with no common
            // ancestor yet throws `NSGenericException`, and this one is
            // reached the first time anybody clicks a star.
            links.addArrangedSubview(line)
            line.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -28).isActive = true
        }
        if edges.count > 4 {
            let more = NSTextField(labelWithString: "and \(edges.count - 4) more")
            more.font = .systemFont(ofSize: 11)
            more.textColor = NSColor.white.withAlphaComponent(0.4)
            links.addArrangedSubview(more)
        }
        openButton.title = "Open " + Self.word(for: node).lowercased()
        openButton.isHidden = !openable
        openButton.setAccessibilityLabel(openButton.title)
        setAccessibilityLabel("\(Self.word(for: node)): \(node.title)")
    }

    static func word(for node: Galaxy.Node) -> String {
        switch node.kind {
        case Galaxy.Node.person: return "Person"
        case Galaxy.Node.note: return "Note"
        case Galaxy.Node.chat: return "Chat"
        case Galaxy.Node.recording: return "Recording"
        // The centre is you when the library has heard you speak, and a bare
        // anchor when it has not. Saying "This Mac" over your own name would
        // be the card disagreeing with the star it is describing.
        default: return Galaxy.subject(of: node.id) == nil ? "This Mac" : "You"
        }
    }

    @objc private func open() { onOpen?() }
    @objc private func clear() { onClear?() }
}

/// The Metal view, and the gestures over it.
private final class GalaxyMetalView: MTKView {
    var onClick: ((CGPoint, Int) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?

    private var hoverArea: NSTrackingArea?
    private var dragOrigin: CGPoint?
    private var pressOrigin: CGPoint?
    private var panning = false
    private var dragged = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.inVisibleRect` keeps this correct through a scroll or a resize
        // without anybody recomputing the rect, which is why it is `.zero`.
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }

    override func mouseDown(with event: NSEvent) {
        onHover?(nil)
        onInteraction?(true)
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        pressOrigin = point
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
        // A press wanders a point or two before a real drag. Without the
        // threshold every click orbits the camera a little before selecting.
        if hypot(dx, dy) > 1 { dragged = true }
        dragOrigin = point
        if panning { onPan?(dx, dy) } else { onOrbit?(dx, dy) }
    }

    override func mouseUp(with event: NSEvent) {
        onInteraction?(false)
        let point = convert(event.locationInWindow, from: nil)
        // Against where the press started, not where the last drag event
        // landed: `dragOrigin` has been moved to the current point by then, so
        // comparing with it would call every drag a click.
        if !dragged, let origin = pressOrigin, hypot(point.x - origin.x, point.y - origin.y) < 3 {
            onClick?(point, event.clickCount)
        }
        dragOrigin = nil
        pressOrigin = nil
    }
    override func rightMouseUp(with event: NSEvent) { dragOrigin = nil; pressOrigin = nil; onInteraction?(false) }
    // NSEvent's units, turned into the camera's. A trackpad and a Magic Mouse
    // report points and send many events; a wheel reports lines and sends few.
    // AppKit has already applied the system's natural-scroll setting, so this
    // follows whichever way round the rest of the Mac scrolls.
    override func scrollWheel(with event: NSEvent) {
        let rate = event.hasPreciseScrollingDeltas
            ? GalaxyCamera.zoomPerScrollPoint : GalaxyCamera.zoomPerScrollLine
        onZoom?(CGFloat(Float(event.scrollingDeltaY) * rate))
    }
    override func magnify(with event: NSEvent) {
        onZoom?(CGFloat(Float(event.magnification) * GalaxyCamera.zoomPerMagnification))
    }
}
