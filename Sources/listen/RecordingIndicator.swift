import AppKit

/// A floating panel, top right, that says what Listen is doing and carries the
/// confirm control.
///
/// Ported from Speak's, with the reasoning intact and one change: this one
/// takes clicks. Speak's is `ignoresMouseEvents` because it only reports; this
/// one is where Keep and Discard live.
///
/// A menu bar item is 16 points wide on a display you may not be looking at,
/// and on a Mac with a notch it can be hidden entirely. That argument is
/// stronger here than in Speak: a dictation lasts seconds, a meeting recording
/// runs for an hour, and believing you are recording when you are not is the
/// most expensive mistake this app can make.
///
/// ## Why the layout is computed rather than written down
///
/// The first version gave every control a literal frame, which worked for
/// "Recording" and broke the moment the label got longer: "Keep this
/// recording?" is wider than the 132 points it was given, so it ran underneath
/// the Discard button and the panel shipped with two overlapping controls. The
/// text is not a constant. It carries an app name that can be "Zoom" or
/// "Google Chrome", so any fixed width is wrong for some input. Everything here
/// is measured from the strings it is actually drawing.
/// A push button that paints its own accent fill.
///
/// Measured, because the obvious two ways both silently do nothing here:
/// `keyEquivalent = "\r"` and `bezelColor = Brand.accent` each left the
/// button rendering identically to its neighbours. AppKit draws the blue
/// default-button fill only for the *key* window's default cell, and this panel
/// is `.nonactivatingPanel` and deliberately never becomes key, because taking
/// key would pull focus out of the meeting. So the fill is drawn rather than
/// asked for.
///
/// Without it the panel offered "Never for Google Chrome", "No" and "Yes" as
/// three equally weighted choices, and the one people want to hit without
/// reading was the least visible of the three.
final class FilledButton: NSButton {
    /// A borderless button fits its title exactly, which reads as a label
    /// rather than as something to press once it has a background behind it.
    override func sizeToFit() {
        super.sizeToFit()
        setFrameSize(NSSize(width: frame.width + 18, height: max(frame.height, 20)))
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = 6
        layer?.backgroundColor = Brand.accent.cgColor
    }
}

/// The panel's background, and the thing you drag the panel by.
///
/// The whole panel is the grab area rather than a strip along the top. It is 52
/// points tall in its usual state and a title bar's worth of that would be most
/// of it, so the rule is the other way round: buttons keep their own clicks and
/// everything else, the labels, the dot and the two strips, drags.
///
/// `hitTest` rather than `isMovableByWindowBackground`, which is the one-liner
/// and does not work here: that flag only starts a drag when the click reaches
/// the window, and the labels are `NSTextField`s, which are controls and eat it.
/// Dragging by the padding while the word "Recording" was dead to the touch
/// reads as a broken panel rather than as a rule anybody could learn.
final class DragBackground: NSVisualEffectView {
    /// Called when a drag finishes. See `RecordingIndicator.settle`.
    var onDragEnd: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        // Anything inside a button is that button's, including the image view
        // inside an image-only one. Everything else is grab area.
        var view: NSView? = hit
        while let v = view, v !== self {
            if v is NSButton { return hit }
            view = v.superview
        }
        return self
    }

    /// The panel is `.nonactivatingPanel` and never becomes key, so a click on
    /// it arrives without the app being brought forward first. That is the
    /// whole point of the panel and it is also why this is stated: a view in a
    /// background window is not sent the click that activates its window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // The system's own drag loop, rather than tracking `mouseDragged` by
        // hand: it is the one that knows about display edges and about the
        // spaces this panel joins all of.
        window?.performDrag(with: event)
        onDragEnd?()
    }
}

@MainActor
final class RecordingIndicator {
    enum State: Equatable {
        case recording
        case transcribing
        /// Something started a call and capture is already running. The
        /// question is asked *while* recording, not before it: SPEC 5.3's whole
        /// point is that the minute spent answering is the minute where people
        /// say who they are.
        ///
        /// Carries the bundle identifier, not the display name, because the
        /// panel wants the app's icon too and that can only be found from the
        /// identifier. "Are you in a meeting?" with no subject is unanswerable
        /// anyway when the honest reply is "no, that is just Spotify".
        case detected(String)

        var title: String {
            switch self {
            case .recording:    return "Recording"
            case .transcribing: return "Transcribing"
            case .detected:     return "Are you in a meeting?"
            }
        }

        /// Two lines of controls, so the buttons get a row of their own.
        var asksAQuestion: Bool {
            if case .detected = self { return true }
            return false
        }
    }

    private var panel: NSPanel?
    /// What the panel is currently showing. Kept because the clock re-lays the
    /// panel out as it grows, and the layout depends on the state.
    private var showing: State?
    private var background: DragBackground?

    /// The origin `position` last set, and whether it is setting one now.
    ///
    /// Both exist to answer one question in `panelMoved`: did the user move
    /// this panel, or did we? `NSWindow.didMoveNotification` fires for both,
    /// and for the `setContentSize` in `layout` as well, since that keeps the
    /// top left corner and therefore moves the origin. Two guards because they
    /// cover each other: `placing` catches a notification delivered inside the
    /// relayout, and the origin comparison catches one delivered after it,
    /// which is when the flag has already gone back down.
    private var placedOrigin: NSPoint?
    private var placing = false

    private var dot: NSView!
    private var iconView: NSImageView!
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var timeLabel: NSTextField!
    private var yesButton: NSButton!
    private var noButton: NSButton!
    private var neverButton: NSButton!
    private var stopButton: NSButton!
    private var hideButton: NSButton!
    private var tick: Timer?
    private var pulse: Timer?
    private var bright = true

    /// The two tracks, upper the far side and lower you, as on the recording
    /// screen and in `TranscribingView`.
    ///
    /// This is the surface that matters when the library window is not in front,
    /// which was the case in the hour that was lost: the panel was on screen, it
    /// said "Recording", and the only thing moving on it was the clock. A clock
    /// counting up looks the same whether or not anybody's voice is arriving.
    private var themMeter: TrackMeter!
    private var youMeter: TrackMeter!

    /// One line under the strips, empty almost always. See `refreshAudio`.
    private var warnLabel: NSTextField!

    /// Whether the strips are subscribed and animating, so `show` is idempotent.
    /// It is called again on every capture change and every menu rebuild, and
    /// restarting the strips each time would wipe their history repeatedly.
    private var metering = false

    /// The panel has been put away by hand for the rest of this recording.
    ///
    /// Sticky, and it has to be: `show` is called again on every capture
    /// change, and `AppDelegate.rebuildMenu` fires one for reasons that have
    /// nothing to do with this panel. A dismissal the next menu rebuild undid
    /// would not be a dismissal.
    private(set) var isDismissed = false

    /// Stop the recording that is running.
    var onStop: (() -> Void)?

    /// The panel was dismissed. Recording carries on; the caller's job is to
    /// offer the way back, because this panel is no longer on screen to do it.
    var onDismiss: (() -> Void)?

    /// A fixed clock for `LISTEN_PANEL=recording:<seconds>`, nil in every real
    /// run. The tick reads this instead of `Capture`, which in a preview launch
    /// is recording nothing and would put "0:00" back half a second later.
    var previewElapsed: TimeInterval?

    /// A fixed answer to "is the microphone hearing anything" for
    /// `LISTEN_PANEL=recording:silent`, nil in every real run. The state this
    /// panel most needs checking in is the one no Mac reproduces on demand.
    var previewSilent: Bool?

    /// Drives both strips from a synthetic speech envelope in a preview launch,
    /// since nothing is being captured there. `RecordingView.fakeLevel` is the
    /// same envelope, for the same reason.
    private var fake: Timer?
    private var fakeClock: TimeInterval = 0

    /// The three answers to "are you in a meeting?".
    ///
    /// `onNo` stops and deletes this one. `onNeverFor` does that *and* adds the
    /// app to the skip list, which is the difference between "wrong this time"
    /// and "wrong every time". Anarlog asks the second question in a follow-up
    /// notification you have to dismiss separately, and being asked twice in
    /// order to say no once is worse than one more button.
    var onYes: (() -> Void)?
    var onNo: (() -> Void)?
    var onNeverFor: (() -> Void)?

    // MARK: - Metrics

    private enum M {
        static let pad: CGFloat = 16
        static let gap: CGFloat = 10
        static let icon: CGFloat = 30
        static let dot: CGFloat = 9
        /// Square, and larger than the 13-point glyph inside it: an image-only
        /// borderless button is exactly as clickable as its image, and a
        /// 13-point target beside a real button is a misclick on the real
        /// button.
        static let hide: CGFloat = 20
        static let minWidth: CGFloat = 236
        static let maxWidth: CGFloat = 460

        /// One track's row, and the gap between the two.
        static let meter: CGFloat = 15
        static let meterGap: CGFloat = 3
        /// The shortest strip worth drawing. Below about this the history stops
        /// being readable and the thing degenerates into a level bar, which is
        /// the style this replaced.
        static let meterMin: CGFloat = 150
    }

    // MARK: - Showing

    func show(_ state: State) {
        // A question outranks a dismissal. The answer to "are you in a
        // meeting?" decides whether this recording is kept, and this panel is
        // the only place it can be given.
        if state.asksAQuestion { isDismissed = false }
        guard !isDismissed else { return }

        let p = panel ?? makePanel()
        panel = p

        titleLabel.stringValue = state.title

        var app: String?
        if case .detected(let bundleID) = state {
            app = AppNames.display(bundleID)
            iconView.image = AppNames.icon(bundleID)
            // Named on its own line rather than inside the question. "Are you
            // in a meeting on Zoom?" is a worse question than "are you in a
            // meeting?" with Zoom shown underneath, because the thing being
            // asked about is the call, not the app.
            subtitleLabel.stringValue = "Recording · \(app ?? bundleID)"
        }

        let detected = app != nil
        iconView.isHidden = !detected
        subtitleLabel.isHidden = !detected
        timeLabel.isHidden = detected
        yesButton.isHidden = !detected
        noButton.isHidden = !detected
        neverButton.isHidden = !detected
        // Not while the question is up: the answer to "are you in a meeting?"
        // decides whether this recording is kept, and a Stop beside it would be
        // a third answer whose meaning nobody could guess.
        stopButton.isHidden = (state != .recording)
        // Same argument as Stop's, one step further: the question has to be
        // answered, so it cannot be put away either.
        hideButton.isHidden = state.asksAQuestion
        if let app { neverButton.title = "Never for \(app)" }

        switch state {
        case .recording:
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            startTimers()
        case .transcribing:
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            stopTimers()
        case .detected:
            // Still red, and still pulsing, on the subtitle line. A grey dot
            // beside "are you in a meeting?" would read as a question about
            // whether to *start*, and somebody who walked away believing
            // nothing had been captured is the one person this panel must not
            // create.
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            startTimers()
        }

        switch state {
        case .recording, .detected:
            startMetering()
        case .transcribing:
            // The microphone is closed and the transcriber is busy. The strips
            // have to keep moving, because a frozen panel reads as a hung app,
            // but nothing they do may be readable as "I can still hear you", so
            // they stop scrolling and a highlight sweeps what they already
            // captured. See `MeterView.working`.
            Capture.shared.removeLevelSink(self)
            metering = false
            themMeter.meter.working()
            youMeter.meter.working()
        }
        refreshAudio()

        showing = state
        replace(state, p)
        // orderFrontRegardless, not makeKeyAndOrderFront: taking key would pull
        // focus out of the meeting window the user is in.
        p.orderFrontRegardless()
    }

    // MARK: - Metering

    private func startMetering() {
        guard !metering else { return }
        metering = true
        themMeter.meter.begin()
        youMeter.meter.begin()
        Capture.shared.addLevelSink(self) { [weak self] track, level in
            guard let self else { return }
            switch track {
            case .you:  self.youMeter.meter.push(CGFloat(level))
            case .them: self.themMeter.meter.push(CGFloat(level))
            }
        }
    }

    /// Unsubscribe and stop the frame clocks.
    ///
    /// Called from every way the panel leaves the screen, and that matters more
    /// here than on the recording screen: a dismissed panel stays dismissed for
    /// the rest of an hour-long meeting, and a 60 Hz redraw of a view nobody can
    /// see is an hour of wakeups for nothing.
    private func endMetering() {
        metering = false
        Capture.shared.removeLevelSink(self)
        themMeter?.meter.end()
        youMeter?.meter.end()
    }

    /// The strips' silence state and the line under them.
    ///
    /// Deliberately shorter sentences than the recording screen's. This panel is
    /// 236 to 460 points wide and floats over somebody's meeting, so it gets the
    /// fact and the window gets the explanation.
    private func refreshAudio() {
        guard let youMeter, let warnLabel else { return }
        let capture = Capture.shared
        let silent = previewSilent ?? capture.micIsSilent
        youMeter.isSilent = silent

        let text = previewSilent == true
            ? "Your microphone is not picking anything up"
            : capture.micNotice(short: true)

        let wasHidden = warnLabel.isHidden
        warnLabel.stringValue = text ?? ""
        warnLabel.isHidden = text == nil
        warnLabel.textColor = silent ? .systemOrange : .secondaryLabelColor
        // The line changes the panel's height, so its appearing has to re-lay
        // out and re-place the panel. Without this it draws off the bottom edge
        // of a panel sized before the microphone went quiet, which is precisely
        // the moment it has to be readable.
        guard wasHidden != warnLabel.isHidden, let showing, let p = panel else { return }
        replace(showing, p)
    }

    /// Drive the strips from a synthetic envelope, for a preview launch where
    /// nothing is being captured. `LISTEN_PANEL=recording[:silent]`.
    ///
    /// The panel's states are otherwise only reachable by holding a real
    /// meeting, which is the argument this file already makes for
    /// `previewElapsed`, and it is sharper for a strip than for a clock: a state
    /// that cannot be put on screen on demand is a state nobody checks, and the
    /// one worth checking most is your own track flat while the far side moves.
    func previewLevels(silent: Bool) {
        previewSilent = silent
        fakeClock = 2000
        fake?.invalidate()
        fake = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fakeClock += 1.0 / 30.0
                self.themMeter.meter.push(CGFloat(FakeSpeech.level(self.fakeClock)))
                self.youMeter.meter.push(silent ? 0
                    : CGFloat(FakeSpeech.level(self.fakeClock + 2.6)))
            }
        }
        refreshAudio()
    }

    /// Draw the panel into a PNG. See `NSView.writeShot`.
    @discardableResult
    func writeShot(to path: String) -> Bool {
        guard let view = panel?.contentView else { return false }
        return view.writeShot(to: path)
    }

    func hide() {
        stopTimers()
        endMetering()
        panel?.orderOut(nil)
        // A dismissal belongs to one recording. The next one starts visible,
        // because "I did not want to see it during that call" is not "I never
        // want to see it", and a recorder that runs with nothing on screen is
        // only acceptable when somebody asked for it this time.
        isDismissed = false
    }

    /// Undo a dismissal.
    ///
    /// Clears the flag and nothing else: which state the panel should come
    /// back in is the caller's to know, and the caller is about to say so.
    func reveal() { isDismissed = false }

    // MARK: - Building

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: M.minWidth, height: 52),
            // .nonactivatingPanel is load-bearing: without it, showing this
            // steals focus from the meeting.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let bg = DragBackground(frame: p.contentLayoutRect)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        bg.onDragEnd = { [weak self] in self?.settle() }
        background = bg

        // Where the panel ends up after a drag is worth keeping, and the
        // notification is what keeps it: it fires throughout the system's drag
        // loop, so the placement is stored even if `performDrag` returns before
        // the mouse comes up. `onDragEnd` above only puts a panel dropped over
        // a screen edge back on screen.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        }

        let d = NSView()
        d.wantsLayer = true
        d.layer?.cornerRadius = M.dot / 2
        d.layer?.backgroundColor = NSColor.systemRed.cgColor
        bg.addSubview(d)
        dot = d

        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.isHidden = true
        bg.addSubview(icon)
        iconView = icon

        titleLabel = NSTextField(labelWithString: "Recording")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        bg.addSubview(titleLabel)

        subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.isHidden = true
        bg.addSubview(subtitleLabel)

        timeLabel = NSTextField(labelWithString: "0:00")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        bg.addSubview(timeLabel)

        neverButton = button("Never for this app", #selector(neverFor), in: bg)
        noButton = button("No", #selector(no), in: bg)
        yesButton = filledButton("Yes", #selector(yes), in: bg)
        // Return says yes. The panel is `.nonactivatingPanel` and never takes
        // key, so this is a shortcut for somebody who has already clicked the
        // panel, not a way to answer by accident while typing in the meeting.
        yesButton.keyEquivalent = "\r"

        // The one control the panel was missing. `onStop` existed from the
        // start and nothing ever called it, so the only way to stop a recording
        // was the menu bar item: 16 points wide, on a display you may not be
        // looking at, and hidden entirely behind the notch on the Macs that
        // have one. The panel spent an hour saying "Recording" and offering no
        // way to make it stop.
        stopButton = button("Stop", #selector(stop), in: bg)

        // Put the panel away without stopping anything. A meeting recording
        // runs for an hour and this floats over the top right corner of
        // whatever the meeting is about, so the choice was between covering a
        // screen share and stopping the recording, and neither is the one
        // people want. Borderless, and quieter than Stop, because between the
        // two controls on this panel the consequential one should be the one
        // that looks like a button.
        //
        // The tooltip is not decoration. A minus beside "Recording" reads as
        // "remove this recording" to anybody who has not clicked it before,
        // and that is the guess this app can least afford them to test.
        hideButton = symbolButton("minus.circle", in: bg)
        hideButton.toolTip = "Hide this panel. The recording keeps running."

        themMeter = TrackMeter(name: "Them", tint: .systemTeal)
        youMeter = TrackMeter(name: "You", tint: .systemRed)
        for m in [themMeter, youMeter] { bg.addSubview(m!) }

        warnLabel = NSTextField(labelWithString: "")
        warnLabel.font = .systemFont(ofSize: 10, weight: .medium)
        warnLabel.textColor = .systemOrange
        warnLabel.lineBreakMode = .byTruncatingTail
        warnLabel.isHidden = true
        bg.addSubview(warnLabel)

        p.contentView = bg
        return p
    }


    private func button(_ title: String, _ action: Selector, in parent: NSView) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 12)
        b.isHidden = true
        parent.addSubview(b)
        return b
    }

    /// An image-only button, sized by `M.hide` rather than by its glyph.
    private func symbolButton(_ name: String, in parent: NSView) -> NSButton {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Hide")?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        let b = NSButton(image: image ?? NSImage(), target: self, action: #selector(dismiss))
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.contentTintColor = .secondaryLabelColor
        b.isHidden = true
        parent.addSubview(b)
        return b
    }

    private func filledButton(_ title: String, _ action: Selector,
                              in parent: NSView) -> NSButton {
        let b = FilledButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ])
        b.isHidden = true
        parent.addSubview(b)
        return b
    }

    // MARK: - Layout

    /// Size the panel to its content, then place the content in it.
    ///
    /// Bottom-up coordinates, because the content view is not flipped: `y` is
    /// the distance from the floor of the panel, so the top row is computed
    /// from the height rather than from zero.
    private func layout(_ state: State) {
        guard let p = panel, let bg = background else { return }

        let buttons = visibleButtons()
        for b in buttons { b.sizeToFit() }
        let buttonHeight = buttons.map(\.frame.height).max() ?? 0
        let buttonsWidth = buttons.reduce(0) { $0 + $1.frame.width }
            + CGFloat(max(0, buttons.count - 1)) * 8

        titleLabel.sizeToFit()
        subtitleLabel.sizeToFit()
        timeLabel.sizeToFit()
        stopButton.sizeToFit()
        // Trailing furniture on the single-line states, in reading order after
        // the clock: Stop, then the dismiss.
        var trailing: CGFloat = 0
        if !stopButton.isHidden { trailing += stopButton.frame.width + 10 }
        if !hideButton.isHidden { trailing += M.hide + 8 }

        // The dot leads the title in the single-line states. In the detected
        // one the icon takes the left margin and the dot drops to the subtitle
        // line, where it is the only thing saying "this is happening now"
        // besides the word "Recording".
        let detected = !iconView.isHidden
        let leftInset = detected ? M.pad + M.icon + M.gap : M.pad + M.dot + M.gap
        let subtitleInset = leftInset + M.dot + 6
        let textWidth = max(titleLabel.frame.width,
                            detected ? subtitleLabel.frame.width + M.dot + 6 : 0)

        // The panel is as wide as whichever row needs more room. Clamped at the
        // top so a pathological app name cannot produce a panel wider than the
        // screen edge it is pinned to.
        var width = max(M.minWidth,
                        leftInset + textWidth + M.pad,
                        M.pad + buttonsWidth + M.pad,
                        // Enough for a strip that still reads as history rather
                        // than as a level bar. See `M.meterMin`.
                        M.pad + TrackMeter.labelWidth + 8 + M.meterMin + M.pad)
        if !state.asksAQuestion {
            width = max(width, leftInset + textWidth + M.gap
                               + timeLabel.frame.width + trailing + M.pad)
        }
        width = min(width, M.maxWidth)

        let titleH = titleLabel.frame.height
        let subtitleH = detected ? subtitleLabel.frame.height + 2 : 0
        let textBlock = titleH + subtitleH

        // The two strips and the line under them, which is present in every
        // state: capture is running in all three, and in `.transcribing` they
        // are showing what was captured being read.
        warnLabel.sizeToFit()
        let warnBlock = warnLabel.isHidden ? 0 : warnLabel.frame.height + 3
        let meterBlock = 8 + M.meter * 2 + M.meterGap + warnBlock

        let height = state.asksAQuestion
            ? M.pad + textBlock + meterBlock + 12 + buttonHeight + 13
            : max(52, M.pad + textBlock + meterBlock + M.pad)

        let size = NSSize(width: width, height: height)
        if p.frame.size != size {
            p.setContentSize(size)
            bg.frame = NSRect(origin: .zero, size: size)
        }

        // Text block, hung from the top.
        let titleY = height - M.pad - titleH
        titleLabel.frame = NSRect(x: leftInset, y: titleY,
                                  width: min(textWidth, width - leftInset - M.pad),
                                  height: titleH)
        if detected {
            let subH = subtitleLabel.frame.height
            let subY = titleY - 2 - subH
            subtitleLabel.frame = NSRect(x: subtitleInset, y: subY,
                                         width: min(subtitleLabel.frame.width,
                                                    width - subtitleInset - M.pad),
                                         height: subH)
            iconView.frame = NSRect(x: M.pad,
                                    y: subY + (textBlock - M.icon) / 2,
                                    width: M.icon, height: M.icon)
            dot.frame = NSRect(x: leftInset, y: subY + (subH - M.dot) / 2,
                               width: M.dot, height: M.dot)
        } else {
            dot.frame = NSRect(x: M.pad, y: titleY + (titleH - M.dot) / 2,
                               width: M.dot, height: M.dot)
        }
        // Right to left, so each piece of furniture only has to know its own
        // width and the gap before it. The cursor ends where the clock ends,
        // which is `trailing` measured rather than repeated.
        var right = width - M.pad
        if !hideButton.isHidden {
            right -= M.hide
            hideButton.frame = NSRect(x: right, y: titleY + (titleH - M.hide) / 2,
                                      width: M.hide, height: M.hide)
            right -= 8
        }
        if !stopButton.isHidden {
            right -= stopButton.frame.width
            stopButton.frame = NSRect(x: right,
                                      y: titleY + (titleH - stopButton.frame.height) / 2,
                                      width: stopButton.frame.width,
                                      height: stopButton.frame.height)
            right -= 10
        }
        timeLabel.frame = NSRect(x: right - timeLabel.frame.width,
                                 y: titleY + (titleH - timeLabel.frame.height) / 2,
                                 width: timeLabel.frame.width,
                                 height: timeLabel.frame.height)

        // The strips, under the text block and above whatever else the state
        // carries. Full width rather than tucked into a trailing column: they
        // have a row each, so Speak's problem of a spanning meter fighting the
        // status text for one column does not arise here.
        //
        // `textBlock` is measured from the top, so its underside is the one
        // number both the one-line and the question layouts agree on.
        let meterX = M.pad
        let meterW = width - meterX - M.pad
        var my = height - M.pad - textBlock - 8 - M.meter
        themMeter.frame = NSRect(x: meterX, y: my, width: meterW, height: M.meter)
        my -= M.meterGap + M.meter
        youMeter.frame = NSRect(x: meterX, y: my, width: meterW, height: M.meter)
        if !warnLabel.isHidden {
            my -= 3 + warnLabel.frame.height
            warnLabel.frame = NSRect(x: meterX, y: my, width: meterW,
                                     height: warnLabel.frame.height)
        }
        // The panel lays itself out by hand, so the two track views have to be
        // told their own contents moved.
        themMeter.needsLayout = true
        youMeter.needsLayout = true

        // Buttons right to left, so the affirmative answer lands in the same
        // place whichever question is being asked.
        var x = width - M.pad
        for b in buttons.reversed() {
            x -= b.frame.width
            b.frame = NSRect(x: x, y: 13, width: b.frame.width, height: buttonHeight)
            x -= 8
        }
    }

    /// In reading order, left to right.
    private func visibleButtons() -> [NSButton] {
        [neverButton, noButton, yesButton].filter { !$0.isHidden }
    }

    @objc private func yes() { onYes?() }
    @objc private func no() { onNo?() }
    @objc private func neverFor() { onNeverFor?() }
    @objc private func stop() { onStop?() }

    @objc private func dismiss() {
        isDismissed = true
        stopTimers()
        endMetering()
        panel?.orderOut(nil)
        onDismiss?()
    }

    /// Re-measure the panel and put it back where it belongs, as one step.
    ///
    /// The two halves are never useful apart. Every string that changes the
    /// size also moves the panel, because it is placed by a corner rather than
    /// by its origin, and a resize that skipped the placing would grow the
    /// panel through whichever screen edge it is parked against.
    private func replace(_ state: State, _ p: NSPanel) {
        placing = true
        layout(state)
        position(p)
        placing = false
    }

    /// Top right, like Blackbox, unless somebody has dragged it somewhere else.
    /// On whichever screen has the mouse, either way.
    ///
    /// Inset from `visibleFrame` rather than `frame` so it sits under the menu
    /// bar rather than behind it, and clear of the notch on the Macs that have
    /// one.
    ///
    /// The size is read here rather than assumed: the states are different
    /// sizes, and a constant would push the wide one off the edge it is
    /// measured from.
    private func position(_ p: NSPanel) {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = (Settings.recordingPanelPlacement ?? .default)
            .origin(for: p.frame.size, in: frame)
        placedOrigin = origin
        p.setFrameOrigin(origin)
    }

    /// A drag finished. Put the panel wholly back on screen if it was dropped
    /// over an edge.
    ///
    /// Only the clamp: moving it fires `didMove`, and `panelMoved` is the one
    /// place the placement is written, so what gets stored is where the panel
    /// can be seen rather than where the mouse was let go.
    ///
    /// Deliberately after the drag rather than during it. Clamping on every
    /// `didMove` would mean setting the origin inside the system's own drag
    /// loop, which is a fight over the same number sixty times a second.
    private func settle() {
        guard let p = panel, let frame = screen(mostlyUnder: p.frame)?.visibleFrame
        else { return }
        let origin = PanelPlacement(p.frame, in: frame)
            .origin(for: p.frame.size, in: frame)
        guard origin != p.frame.origin else { return }
        p.setFrameOrigin(origin)
    }

    /// The panel moved, and we did not move it, so somebody dragged it.
    ///
    /// Read against the screen the panel is mostly on rather than the one with
    /// the mouse. They are the same screen at the end of a drag and different
    /// in the middle of one that is crossing displays, and the panel is the
    /// thing being placed.
    private func panelMoved() {
        guard !placing, let p = panel, p.frame.origin != placedOrigin,
              let frame = screen(mostlyUnder: p.frame)?.visibleFrame else { return }
        placedOrigin = p.frame.origin
        Settings.recordingPanelPlacement = PanelPlacement(p.frame, in: frame)
    }

    /// The screen a rect covers most of, which for a panel dragged across a
    /// display boundary is the one it now belongs to.
    private func screen(mostlyUnder rect: NSRect) -> NSScreen? {
        func overlap(_ s: NSScreen) -> CGFloat {
            let r = s.frame.intersection(rect)
            return r.width * r.height
        }
        return NSScreen.screens.max { overlap($0) < overlap($1) } ?? NSScreen.main
    }

    // MARK: - Timers

    func setElapsed(_ seconds: TimeInterval) {
        let t = Int(seconds)
        // An hour-long meeting needs the hour. Speak's never did.
        let text = t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
        let was = timeLabel.stringValue
        guard text != was else { return }
        timeLabel.stringValue = text

        // Every frame in this panel is measured from the strings it is drawing,
        // and this is the only one that changes after `show` has laid it out.
        // It was sized for "0:00" when capture started, so from ten minutes in
        // the label was a character too narrow and the clock lost a digit for
        // the rest of the meeting: a panel reading "33:1" is worse than one
        // reading nothing, because it looks like a time.
        //
        // Monospaced digits, so the character count *is* the width, and this
        // re-lays out once per digit rather than twice a second.
        guard text.count != was.count, let showing, let p = panel else { return }
        // The panel is pinned by a corner, so a width that grows past the
        // minimum moves its origin too.
        replace(showing, p)
    }

    private func startTimers() {
        stopTimers()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.setElapsed(self.previewElapsed ?? Capture.shared.elapsed)
                self.refreshAudio()
            }
        }
        // A slow pulse rather than a blink: noticeable in peripheral vision
        // without being the most distracting thing on screen during a meeting.
        pulse = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let dot = self.dot else { return }
                self.bright.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.55
                    dot.animator().alphaValue = self.bright ? 1.0 : 0.35
                }
            }
        }
    }

    private func stopTimers() {
        tick?.invalidate(); tick = nil
        pulse?.invalidate(); pulse = nil
        fake?.invalidate(); fake = nil
        dot?.alphaValue = 1
    }
}

// ---------------------------------------------------------------------------
// Placement
// ---------------------------------------------------------------------------

/// Where the recording panel sits: a corner of the screen, and an inset from
/// it in each direction.
///
/// Not an origin, which is the obvious shape and the wrong one twice over.
///
/// The panel is measured from the strings it is drawing and resizes as they
/// change, so it needs to know which of its own corners is nailed down: a panel
/// parked against the right edge has to grow leftwards and one parked against
/// the left edge has to grow rightwards, or the growth goes off the screen. An
/// origin cannot say that, and the old code did not have to, because the corner
/// was always the top right.
///
/// A stored origin is also read on a screen that may not be the screen it was
/// written on. The panel appears wherever the mouse is, so an origin taken off
/// a 27-inch display lands below the bottom edge of a laptop's, while an inset
/// from a corner means the same thing on both.
struct PanelPlacement: Equatable {
    /// Which edges the insets are measured from, and therefore which corner of
    /// the panel stays put when it resizes.
    var fromLeft: Bool
    var fromTop: Bool
    /// Inset from those two edges of the screen's `visibleFrame`, in points.
    var dx: CGFloat
    var dy: CGFloat

    init(fromLeft: Bool, fromTop: Bool, dx: CGFloat, dy: CGFloat) {
        self.fromLeft = fromLeft
        self.fromTop = fromTop
        self.dx = dx
        self.dy = dy
    }

    /// Top right, 16 points in from the side and 12 down from under the menu
    /// bar. Where this panel has always been, and where it still starts.
    static let `default` = PanelPlacement(fromLeft: false, fromTop: true, dx: 16, dy: 12)

    /// Read a placement off a panel somebody has just dragged.
    ///
    /// The nearest corner wins, and that one decision is what makes a dragged
    /// panel behave like the one that was only ever top right: it fixes the
    /// corner the panel keeps still, so it goes on growing away from the edge
    /// it was parked against rather than through it.
    init(_ rect: NSRect, in frame: NSRect) {
        let left = rect.midX < frame.midX
        let top = rect.midY > frame.midY
        self.init(fromLeft: left, fromTop: top,
                  dx: left ? rect.minX - frame.minX : frame.maxX - rect.maxX,
                  dy: top ? frame.maxY - rect.maxY : rect.minY - frame.minY)
    }

    /// Where a panel of `size` goes on a screen whose `visibleFrame` is
    /// `frame`, clamped so all of it is on that screen.
    ///
    /// The clamp is not defensive tidying. A placement is applied on whichever
    /// screen has the mouse, which is not necessarily the screen it was read
    /// on, and it is also applied to a panel that has grown since: both are
    /// ways for an inset that was on screen to stop being one.
    func origin(for size: NSSize, in frame: NSRect) -> NSPoint {
        let x = fromLeft ? frame.minX + dx : frame.maxX - size.width - dx
        let y = fromTop ? frame.maxY - size.height - dy : frame.minY + dy
        // The outer `max` is for a panel taller or wider than the screen,
        // where the two bounds cross and the top left corner is the only one
        // worth keeping.
        return NSPoint(
            x: min(max(x, frame.minX), max(frame.minX, frame.maxX - size.width)),
            y: min(max(y, frame.minY), max(frame.minY, frame.maxY - size.height)))
    }

    /// `"right top 16 12"`, in the order it reads out loud.
    ///
    /// Whole points, because this is a plist a person may end up looking at and
    /// a stored `16.000001` tells them nothing they need.
    var stored: String {
        "\(fromLeft ? "left" : "right") \(fromTop ? "top" : "bottom")"
            + " \(Int(dx.rounded())) \(Int(dy.rounded()))"
    }

    init?(stored raw: String) {
        let parts = raw.split(separator: " ")
        guard parts.count == 4,
              parts[0] == "left" || parts[0] == "right",
              parts[1] == "top" || parts[1] == "bottom",
              let dx = Double(parts[2]), let dy = Double(parts[3]) else { return nil }
        self.init(fromLeft: parts[0] == "left", fromTop: parts[1] == "top",
                  dx: CGFloat(dx), dy: CGFloat(dy))
    }
}

extension Settings {
    private static let panelPlacementKey = "recordingPanelPlacement"

    /// Where the recording panel was last dragged to, and nil until somebody
    /// drags it.
    ///
    /// nil rather than storing the default, so "never moved" stays
    /// distinguishable from "moved back to the corner it starts in". That is
    /// what lets the starting corner change later without stranding everyone
    /// who never had an opinion about it, and it makes `defaults delete
    /// com.mgo.listen recordingPanelPlacement` a way back for anybody who does.
    ///
    /// One string rather than four keys: a placement is only ever read and
    /// written whole, and four keys can be half-written.
    static var recordingPanelPlacement: PanelPlacement? {
        get {
            guard let raw = defaults.string(forKey: panelPlacementKey) else { return nil }
            return PanelPlacement(stored: raw)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: panelPlacementKey)
                return
            }
            defaults.set(newValue.stored, forKey: panelPlacementKey)
        }
    }
}
