import AppKit

/// Cmd-Q asks once before it quits.
///
/// Ported from Anarlog, for a reason that is stronger here: Cmd-Q sits next to
/// Cmd-W and Cmd-Tab, and the cost of hitting it by accident in this app is an
/// hour-long meeting that stops recording mid-sentence. One extra press is a
/// cheap toll on the deliberate case and the whole difference on the accidental
/// one.
///
/// ## How it intercepts a keystroke the menu owns
///
/// A local event monitor runs **before** `NSApplication` dispatches the event,
/// which includes before the main menu matches its key equivalents. That
/// ordering is the entire mechanism: returning nil means the Quit item never
/// sees the keystroke. Nothing in `MainMenu` has to change, and there is no
/// second Quit action that could disagree with the first.
///
/// Two consequences worth knowing before editing this:
///
/// 1. **The status bar item's Quit is not intercepted.** A menu tracking
///    session runs its own event loop and does not go through `sendEvent`, so
///    Cmd-Q with that menu open quits straight away. Clicking either Quit item
///    quits straight away too. That is deliberate rather than a gap: reaching
///    for a menu item is already a decision, and Cmd-Q is the one that gets
///    pressed without one. It also means there is always a way out that does
///    not confirm, so no hidden override keystroke is needed.
/// 2. **The first Cmd-Q keydown is swallowed**, so macOS may never send the
///    matching keyup. `pressed()` therefore treats a second press while the
///    prompt is still up as confirmation whichever state it is in.
@MainActor
final class QuitConfirm {
    static let shared = QuitConfirm()

    private enum State {
        case idle
        /// The prompt is up and Cmd-Q has not come back up yet.
        case held
        /// The keys are released, the prompt is still on screen and counting
        /// down. A second press in this window quits.
        case armed
    }

    private var state: State = .idle
    private var monitor: Any?
    private var panel: NSPanel?
    private var titleLabel: NSTextField!
    private var subtitleLabel: NSTextField!
    private var expiry: Timer?

    /// How long the prompt stays up once the keys are released.
    ///
    /// A judgement rather than a measurement: long enough to read five words
    /// and press again, short enough that a prompt nobody answered is gone
    /// before it becomes something to wonder about. Anarlog uses 1.5s.
    private static let grace: TimeInterval = 2

    private enum M {
        static let pad: CGFloat = 18
        static let minWidth: CGFloat = 300
    }

    // MARK: - Install

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { event in
            QuitConfirm.shared.handle(event)
        }
    }

    /// Returning nil swallows the event, and only Cmd-Q is ever swallowed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            guard isQuit(event) else { return event }
            // Holding the keys down repeats. A repeat is the same press, not a
            // second one, so only the first of a hold is an answer.
            if !event.isARepeat { pressed() }
            return nil

        case .keyUp:
            if event.charactersIgnoringModifiers?.lowercased() == "q" { released() }
            return event

        case .flagsChanged:
            if !event.modifierFlags.contains(.command) { released() }
            return event

        default:
            return event
        }
    }

    /// Command and Q, and nothing else held.
    ///
    /// Anything with a further modifier passes through untouched. Cmd-Shift-Q
    /// is a different keystroke, and quietly treating it as Quit would be a
    /// shortcut nobody asked for and nothing documents.
    private func isQuit(_ event: NSEvent) -> Bool {
        let held = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .shift, .control, .option])
        return held == .command && event.charactersIgnoringModifiers?.lowercased() == "q"
    }

    // MARK: - State

    private func pressed() {
        switch state {
        case .idle:
            trace("quit confirm: asking")
            state = .held
            show()
        case .held, .armed:
            trace("quit confirm: confirmed from \(state)")
            quit()
        }
    }

    private func released() {
        // Traced after the guard, not before. Every Command release in the app
        // arrives here, so a line per call would bury the capture tracing this
        // shares stderr with.
        guard state == .held else { return }
        trace("quit confirm: armed")
        state = .armed
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: Self.grace, repeats: false) { _ in
            Task { @MainActor in QuitConfirm.shared.expire() }
        }
    }

    private func expire() {
        guard state == .armed else { return }
        trace("quit confirm: expired")
        state = .idle
        hide()
    }

    private func quit() {
        state = .idle
        expiry?.invalidate()
        expiry = nil
        hide()
        // Capture is stopped in `applicationWillTerminate`, so this path
        // finalises the WAV headers and tears the tap down like every other.
        NSApp.terminate(nil)
    }

    // MARK: - Panel

    private func show() {
        let p = panel ?? makePanel()
        panel = p

        // Read at the moment of asking, not at build time: whether a recording
        // is running is the thing that decides what quitting costs.
        subtitleLabel.stringValue = Capture.shared.isRecording
            ? "This stops the recording in progress." : ""
        subtitleLabel.isHidden = !Capture.shared.isRecording

        layout()
        position(p)
        p.alphaValue = 0
        // orderFrontRegardless, not makeKeyAndOrderFront, and matching the
        // recording indicator: taking key would move focus during the meeting
        // this prompt exists to protect.
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 1
        }
    }

    private func hide() {
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: M.minWidth, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Nothing here is clickable. The answer is the keystroke, and a button
        // would be a second way to answer that has to keep agreeing with it.
        p.ignoresMouseEvents = true

        let bg = NSVisualEffectView(frame: p.contentLayoutRect)
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        titleLabel = NSTextField(labelWithString: "Press ⌘Q again to quit")
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        bg.addSubview(titleLabel)

        subtitleLabel = NSTextField(labelWithString: "")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.isHidden = true
        bg.addSubview(subtitleLabel)

        p.contentView = bg
        return p
    }

    /// Size the panel to its text, then centre the text in it.
    ///
    /// Measured from the strings rather than written down, for the reason the
    /// recording indicator carries the long version of: the second line is
    /// there only while recording, so any fixed height is wrong half the time.
    /// Bottom-up coordinates, because the content view is not flipped.
    private func layout() {
        guard let p = panel else { return }
        titleLabel.sizeToFit()
        subtitleLabel.sizeToFit()

        let second = !subtitleLabel.isHidden
        let width = max(M.minWidth,
                        max(titleLabel.frame.width, subtitleLabel.frame.width) + M.pad * 2)
        let height = M.pad * 2 + titleLabel.frame.height
            + (second ? subtitleLabel.frame.height + 4 : 0)
        p.setContentSize(NSSize(width: width, height: height))

        if second {
            subtitleLabel.setFrameOrigin(NSPoint(
                x: (width - subtitleLabel.frame.width) / 2, y: M.pad))
            titleLabel.setFrameOrigin(NSPoint(
                x: (width - titleLabel.frame.width) / 2,
                y: M.pad + subtitleLabel.frame.height + 4))
        } else {
            titleLabel.setFrameOrigin(NSPoint(
                x: (width - titleLabel.frame.width) / 2, y: M.pad))
        }
    }

    /// Centred and a little above the middle, on the screen with the mouse.
    ///
    /// Not the top right, where the recording indicator already is: a prompt
    /// landing on top of the panel that says "Recording" would hide the one
    /// thing worth seeing before answering it.
    private func position(_ p: NSPanel) {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(
            x: frame.midX - p.frame.width / 2,
            y: frame.midY - p.frame.height / 2 + frame.height * 0.15))
    }
}
