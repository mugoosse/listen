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

    /// What the sidebar's search field holds. The galaxy narrows with it.
    private var search = ""

    /// Stars whose title matches the search, which are the ones drawn lit.
    private var matches: Set<String> {
        guard !search.isEmpty else { return [] }
        return Set(snapshot.nodes
            .filter { $0.title.localizedCaseInsensitiveContains(search) }
            .map(\.id))
    }

    /// What is actually drawn: the snapshot minus the struck-out shells, and
    /// narrowed to a search when there is one. Computed rather than stored, so
    /// there is one snapshot on this pane and no second copy to go stale.
    ///
    /// **A search keeps what the matches link to.** Narrowing to the matches
    /// alone leaves two stars floating in an empty sphere with no lines, which
    /// answers "is Herman in here" and nothing else; the neighbours are the
    /// answer to "and what about him". They are drawn dim, so the matches are
    /// still the thing the eye lands on.
    private var visible: Galaxy.Snapshot {
        var nodes = snapshot.nodes
        if !hiddenKinds.isEmpty { nodes = nodes.filter { !hiddenKinds.contains($0.kind) } }
        if !search.isEmpty {
            let hits = matches
            let neighbours = Set(snapshot.edges.flatMap { edge -> [String] in
                if hits.contains(edge.source) { return [edge.source, edge.target] }
                if hits.contains(edge.target) { return [edge.source, edge.target] }
                return []
            })
            // The centre stays whatever the search says, because it is where
            // the picture is drawn from and its absence reads as a bug.
            nodes = nodes.filter {
                hits.contains($0.id) || neighbours.contains($0.id) || $0.kind == Galaxy.Node.device
            }
        }
        guard nodes.count != snapshot.nodes.count else { return snapshot }
        let ids = Set(nodes.map(\.id))
        return Galaxy.Snapshot(nodes: nodes,
                               edges: snapshot.edges.filter { ids.contains($0.source) && ids.contains($0.target) },
                               label: snapshot.label, omitted: snapshot.omitted)
    }

    /// Narrow the picture to what the sidebar is searching for.
    func setSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed != search else { return }
        search = trimmed
        // Timed for the same reason the sidebar's reload is: this runs on every
        // keystroke, on the main thread, and the question of whether it needs a
        // debounce is a measurement rather than an opinion.
        let began = DEBUG ? DispatchTime.now().uptimeNanoseconds : 0
        // A star that has fallen out of the search cannot stay selected.
        if let id = selectedID, visible.node(id) == nil { select(nil) }
        renderGeneration += 1
        pushToRenderer()
        updateStatus()
        invalidate()
        trace("galaxy search \(visible.nodes.count) of \(snapshot.nodes.count) stars in "
              + "\((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000) ms")
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
    /// Where each title landed and what it names, so a click on the word is a
    /// click on the star. Rebuilt with the labels.
    private var labelTargets: [(rect: CGRect, id: String)] = []
    private let legend = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let failureLabel = NSTextField(wrappingLabelWithString: "")
    private let controls = NSStackView()
    private let motionButton = NSButton()
    private let inspector = GalaxyInspector()
    private var controlsBottom: NSLayoutConstraint!
    private var inspectorBottom: NSLayoutConstraint!
    private var legendTop: NSLayoutConstraint!
    /// How much of the top of this pane the window's title bar is drawn over.
    /// Zero until there is a window to ask. See `updateTitlebarInset`.
    private var titlebarInset: CGFloat = 0
    private var bottomInset: CGFloat = 0
    private var legendHasChats = false
    private var legendCentreTitle = ""
    private var pendingSelection: String?

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
        updateTitlebarInset()
        invalidate()
    }

    /// **Collapsing the sidebar puts the window's own controls over this
    /// pane.** The window is `fullSizeContentView`, so the picture has always
    /// run up under the title bar; what kept the legend clear of it was the
    /// sidebar, because everything before `.sidebarTrackingSeparator` (the
    /// traffic lights, the masthead, the gear, the collapse control) is drawn
    /// over the sidebar's own width. Take the sidebar away and all of it lands
    /// on the galaxy's top-left corner, on top of the legend.
    ///
    /// So the question is not "is the sidebar collapsed", which this pane has
    /// no business knowing, but "does this pane reach the window's left edge",
    /// which is where those controls are. Measured rather than assumed: the
    /// title bar's height is whatever the window says is outside its content
    /// layout rect, which counts the toolbar and follows a style change.
    private func updateTitlebarInset() {
        guard let window = view.window, let content = window.contentView else { return }
        let reachesTheCorner = view.convert(view.bounds, to: nil).minX < 12
        let bar = content.bounds.height - window.contentLayoutRect.height
        let inset = reachesTheCorner ? bar : 0
        guard inset != titlebarInset else { return }
        titlebarInset = inset
        legendTop.constant = 18 + inset
        // The legend has moved, so the titles told to keep clear of it have to
        // be laid out again. See `setBottomInset`, which is the same rule at
        // the other end of the pane.
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
            // **A role is not an element.** `NSView.isAccessibilityElement` is
            // false by default, so a view that sets a role and a label and
            // nothing else is still not in the tree: every sentence below was
            // written for VoiceOver and none of it was ever reachable, and the
            // count of what is drawn is the only handle `verify_galaxy.sh` has
            // on the search filter.
            metal.setAccessibilityElement(true)
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
        legend.setAccessibilityLabel("What each colour in the picture means")
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
        inspector.onFollow = { [weak self] id in self?.select(id) }
        view.addSubview(inspector)

        controlsBottom = controls.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        inspectorBottom = inspector.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        legendTop = legend.topAnchor.constraint(equalTo: view.topAnchor, constant: 18)
        NSLayoutConstraint.activate([
            legend.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            legendTop,
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
        // **Whose library this is, rather than how to read the diagram.** It
        // said "FROM THE CENTRE OUTWARDS", which explains the ordering once
        // and then sits there for ever; the rows are in that order and a
        // reader works it out from the first glance. `Settings.userName` is
        // the same name the transcript and the roster use, and "Your" is what
        // it says before anybody has given one, because "Me's" is not English.
        let owner = Settings.userName.map { "\($0)'s" } ?? "Your"
        let heading = NSTextField(labelWithString: "\(owner) Listen brain".uppercased())
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
        renderer?.update(snapshot: visible, selectionID: selectedID,
                         hoverID: hoveredID, highlight: matches)
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
        if let wanted = pendingSelection, built.node(wanted) != nil {
            pendingSelection = nil
            select(wanted)
        }
        pushToRenderer()
        updateStatus()
        updateInspector()
        invalidate()
    }

    /// **What is wrong or missing, and nothing else.**
    ///
    /// It used to read "159 of your library, on four shells. 186 links, each
    /// one already written down." on every galaxy, for ever. That sentence is
    /// true, and it is the picture restating itself: the shells are visible,
    /// the links are visible, and the legend already names them. What a reader
    /// cannot see is what is *not* drawn, so that is all this says now.
    private func updateStatus() {
        if loading && snapshot.nodes.isEmpty {
            statusLabel.stringValue = "Reading your library…"
        } else if snapshot.nodes.count <= 1 {
            statusLabel.stringValue = "Nothing to draw yet. Record something, or write a note,"
                + " and it appears here."
        } else if !search.isEmpty && matches.isEmpty {
            // **A search nobody's library answers empties the picture.** With
            // the neighbours gone too there is nothing left but the centre, and
            // a galaxy that goes blank says "broken" rather than "no matches".
            // Same rule as the cap: what the reader cannot check by looking is
            // the thing worth a sentence.
            statusLabel.stringValue = "Nothing here matches \u{201C}\(search)\u{201D}."
        } else if snapshot.omitted > 0 {
            // The one thing a reader cannot check by looking.
            statusLabel.stringValue = "\(snapshot.omitted) not drawn: the picture stops at"
                + " \(snapshot.nodes.count - 1)."
        } else {
            statusLabel.stringValue = ""
        }
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
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
        // **A title is the star.** The labels sit beside the dot they name and
        // used to swallow nothing and hit nothing: `GalaxyLabel` refuses hit
        // testing so a drag that starts on one still orbits, which means a
        // click on one used to fall through to the scene and pick whatever was
        // behind it, usually nothing. Testing their rects here keeps the drag
        // behaviour and makes the word as clickable as the dot, which is the
        // larger target and the one a reader is actually aiming at.
        //
        // Before the ray, because a label is drawn over the scene.
        for (rect, id) in labelTargets where rect.contains(point) { return id }
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

    /// Select this star as soon as the library has been read.
    ///
    /// The snapshot is built on a background queue, so arriving from a page
    /// with a star to open means asking for one that does not exist yet.
    /// Remembered rather than polled, and cleared once it lands so a later
    /// reload does not drag the selection back.
    func select(whenLoaded id: String) {
        if snapshot.node(id) != nil { select(id); return }
        pendingSelection = id
    }

    /// Select a star by id, or nothing. Public so a verification script can
    /// drive what a click drives.
    func select(_ id: String?) {
        let wanted = id.flatMap { visible.node($0) }?.id
        selectedID = wanted
        hoveredID = nil
        renderer?.update(snapshot: visible, selectionID: wanted, highlight: matches)
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
            // **Clearing puts the pivot back at the centre.** Selecting a star
            // moves the camera's target to it, which is what makes orbiting
            // around the thing you are inspecting work; nothing moved it back,
            // so after one click and a clear the whole galaxy rotated about a
            // recording somewhere out on the fourth shell and the star with
            // your name on it swung around the frame. Reset view was the only
            // way home, and nothing on screen said so.
            //
            // The distance is kept: how far in somebody has zoomed is theirs,
            // and only what the picture turns about is being corrected.
            let home = camera.focused(on: .zero, distance: camera.distance)
            if policy.flights { focusFlight = (camera, home, 0) } else { camera = home }
            if !policy.flights { focusFlight = nil }
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
        // The strip under the title bar is chrome too, and unlike the four
        // views it is not one of this pane's own. It is only reserved when the
        // window's controls are actually over the picture, so an open sidebar
        // costs the labels nothing. See `updateTitlebarInset`.
        let strip = titlebarInset > 0
            ? CGRect(x: 0, y: view.bounds.height - titlebarInset,
                     width: view.bounds.width, height: titlebarInset)
            : .zero
        let reserved = [legend.frame, statusLabel.frame, controls.frame,
                        inspector.isHidden ? .zero : inspector.frame, strip]
            .filter { !$0.isEmpty }.map { $0.insetBy(dx: -6, dy: -6) }
        let state = LabelState(camera: camera, time: motionTime, selected: selectedID,
                               hovered: hoveredID, size: metalView.bounds.size,
                               generation: renderGeneration, reserved: reserved)
        guard state != labelState else { return }
        labelState = state
        labelUpdateCount += 1
        labels.forEach { $0.removeFromSuperview() }
        labels.removeAll(keepingCapacity: true)
        labelTargets.removeAll(keepingCapacity: true)
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
            labelTargets.append((rect, node.id))
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
final class GalaxyInspector: NSView {
    /// Stated once, because the title's width is computed from it.
    static let closeSize: CGFloat = 28

    var onOpen: (() -> Void)?
    var onClear: (() -> Void)?
    /// Follow one of the links to the star at its other end.
    var onFollow: ((String) -> Void)?

    private let stack = NSStackView()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let links = NSStackView()
    private let openButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // **The window's own ground, painted rather than blended.** A
        // `.sidebar` material looked like the obvious way to match the
        // sidebar and is not: vibrancy blends with what is behind it, and
        // behind this is the Metal view rather than the desktop, so the card
        // came out RGB(38,38,45) beside a sidebar rendering at RGB(11,15,28).
        // `Brand.canvas` is what the sidebar resolves to, so this is that.
        //
        // Which leaves it the same colour as the scene, so a border and a
        // shadow are what make it a card rather than a hole.
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = Brand.canvas.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.45
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -4)

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

        // **The title is the first thing and the largest.** It was third,
        // under a "PERSON" header in small caps, which spent the top line of
        // the card on the one word the reader can already tell from the
        // star's colour. The kind moved into the line below it.
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white
        title.maximumNumberOfLines = 3
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

        for item in [title, detail] { stack.addArrangedSubview(item) }
        stack.addArrangedSubview(links)
        stack.addArrangedSubview(row)
        // A wrapping label reports its whole string as one line's worth of
        // width and is then clipped by the card. Only a width makes it wrap.
        //
        // **The title's is narrower, and a trailing constraint is not the way
        // to say so.** Constrained to the stack's full width *and* told to
        // stop short of the close button, the two fought: the width is
        // required and the stack is leading-aligned, so autolayout satisfied
        // both by sliding the label out of the left edge of the card. One
        // width, computed to clear the button, and nothing to argue with.
        title.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                     constant: -(28 + Self.closeSize + 10)).isActive = true
        detail.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        // **A cross in the corner, where every other page in this window puts
        // the way out.** It was a "Clear" button beside Open, which read as a
        // second verb on the thing being described rather than as dismissing
        // the card, and put the two at the same weight.
        addSubview(close)
        close.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            close.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            close.widthAnchor.constraint(equalToConstant: Self.closeSize),
            close.heightAnchor.constraint(equalToConstant: Self.closeSize),
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
        glass.layer?.cornerRadius = Self.closeSize / 2
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
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
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
        // "Person · 4 recordings · 1h 15m", so the kind is still said and the
        // top line is the name.
        detail.stringValue = [Galaxy.word(for: node), node.detail]
            .filter { !$0.isEmpty }.joined(separator: " · ")
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
            // **A link that names a star should go to it.** These were static
            // text: the card told you a recording was written up in a note and
            // then made you find that note in the sphere yourself.
            let line = GalaxyLinkButton(
                phrase: edge.phrase(from: node.id), name: titles[other] ?? other,
                id: other) { [weak self] id in self?.onFollow?(id) }
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
        openButton.title = "Open " + Galaxy.word(for: node).lowercased()
        openButton.isHidden = !openable
        openButton.setAccessibilityLabel(openButton.title)
        setAccessibilityLabel("\(Galaxy.word(for: node)): \(node.title)")
    }


    @objc private func open() { onOpen?() }
    @objc private func clear() { onClear?() }
}

/// One line of the card's link list, which goes where it says.
///
/// A button rather than a text field with a gesture on it: it gets a name, a
/// place in the key view loop and a pressed state for free, which is the same
/// argument the legend rows make. The phrase stays quiet and the name is the
/// part that lights up, because the name is the thing being offered.
private final class GalaxyLinkButton: NSButton {
    private let id: String
    private let phrase: String
    private let name: String
    private let follow: (String) -> Void
    private var hoverArea: NSTrackingArea?

    init(phrase: String, name: String, id: String, follow: @escaping (String) -> Void) {
        self.id = id
        self.phrase = phrase
        self.name = name
        self.follow = follow
        super.init(frame: .zero)
        isBordered = false
        alignment = .left
        setButtonType(.momentaryChange)
        target = self
        action = #selector(go)
        lineBreakMode = .byTruncatingTail
        setAccessibilityTitle("\(phrase) \(name)")
        setAccessibilityLabel("\(phrase) \(name)")
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        apply(hovered: false)
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }
    override func mouseEntered(with event: NSEvent) { apply(hovered: true); NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { apply(hovered: false); NSCursor.arrow.set() }

    private func apply(hovered: Bool) {
        let text = NSMutableAttributedString(
            string: phrase + " ",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.white.withAlphaComponent(0.45)])
        var nameStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white.withAlphaComponent(hovered ? 0.95 : 0.7),
        ]
        if hovered { nameStyle[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        text.append(NSAttributedString(string: name, attributes: nameStyle))
        attributedTitle = text
    }

    @objc private func go() { follow(id) }
}

/// The Metal view, and the gestures over it.
private final class GalaxyMetalView: MTKView {
    var onClick: ((CGPoint, Int) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    var onInteraction: ((Bool) -> Void)?
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onZoom: ((CGFloat) -> Void)?

    private var hoverArea: NSTrackingArea?
    private var dragOrigin: CGPoint?
    private var pressOrigin: CGPoint?
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
        // **Every drag orbits.** Shift-drag used to pan, which moves the
        // camera's target off the centre, and a target off the centre is a
        // galaxy that rotates about nothing in particular with no cue about
        // which way to drag back. The reference disables panning for the same
        // reason. See the note in `.agents/notes/galaxy.md`, which had claimed
        // this was already true for a while before it was.
        onOrbit?(dx, dy)
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
