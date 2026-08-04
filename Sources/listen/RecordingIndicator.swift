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
@MainActor
final class RecordingIndicator {
    enum State {
        case recording
        case transcribing
        /// Capture has stopped and nobody has said whether to keep it.
        case confirm

        var text: String {
            switch self {
            case .recording:    return "Recording"
            case .transcribing: return "Transcribing"
            case .confirm:      return "Keep this recording?"
            }
        }
    }

    private var panel: NSPanel?
    private var dot: NSView?
    private var label: NSTextField!
    private var timeLabel: NSTextField!
    private var keepButton: NSButton!
    private var discardButton: NSButton!
    private var tick: Timer?
    private var pulse: Timer?
    private var bright = true

    /// What the buttons do. Set by whoever shows the confirm state.
    var onKeep: (() -> Void)?
    var onDiscard: (() -> Void)?
    /// Clicking the body while recording stops it.
    var onStop: (() -> Void)?

    private static let size = NSSize(width: 232, height: 52)

    func show(_ state: State) {
        let p = panel ?? makePanel()
        panel = p

        label.stringValue = state.text
        let confirming = (state == .confirm)
        keepButton.isHidden = !confirming
        discardButton.isHidden = !confirming
        timeLabel.isHidden = confirming

        switch state {
        case .recording:
            dot?.layer?.backgroundColor = NSColor.systemRed.cgColor
            startTimers()
        case .transcribing:
            dot?.layer?.backgroundColor = NSColor.systemOrange.cgColor
            stopTimers()
        case .confirm:
            dot?.layer?.backgroundColor = NSColor.systemGray.cgColor
            stopTimers()
        }

        position(p)
        // orderFrontRegardless, not makeKeyAndOrderFront: taking key would pull
        // focus out of the meeting window the user is in.
        p.orderFrontRegardless()
    }

    func hide() {
        stopTimers()
        panel?.orderOut(nil)
    }

    // MARK: - Building

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
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

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        bg.autoresizingMask = [.width, .height]
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true

        let d = NSView(frame: NSRect(x: 16, y: 21, width: 10, height: 10))
        d.wantsLayer = true
        d.layer?.cornerRadius = 5
        d.layer?.backgroundColor = NSColor.systemRed.cgColor
        bg.addSubview(d)
        dot = d

        label = NSTextField(labelWithString: "Recording")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.frame = NSRect(x: 36, y: 17, width: 132, height: 18)
        bg.addSubview(label)

        timeLabel = NSTextField(labelWithString: "0:00")
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.alignment = .right
        timeLabel.frame = NSRect(x: 160, y: 18, width: 58, height: 16)
        bg.addSubview(timeLabel)

        discardButton = NSButton(title: "Discard", target: self, action: #selector(discard))
        discardButton.bezelStyle = .rounded
        discardButton.controlSize = .small
        discardButton.frame = NSRect(x: 96, y: 12, width: 62, height: 24)
        discardButton.isHidden = true
        bg.addSubview(discardButton)

        keepButton = NSButton(title: "Keep", target: self, action: #selector(keep))
        keepButton.bezelStyle = .rounded
        keepButton.controlSize = .small
        keepButton.keyEquivalent = "\r"
        keepButton.frame = NSRect(x: 162, y: 12, width: 56, height: 24)
        keepButton.isHidden = true
        bg.addSubview(keepButton)

        p.contentView = bg
        return p
    }

    @objc private func keep() { onKeep?() }
    @objc private func discard() { onDiscard?() }

    /// Top right, like Blackbox, on whichever screen has the mouse.
    ///
    /// Inset from `visibleFrame` rather than `frame` so it sits under the menu
    /// bar rather than behind it, and clear of the notch on the Macs that have
    /// one.
    private func position(_ p: NSPanel) {
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(
            x: frame.maxX - Self.size.width - 16,
            y: frame.maxY - Self.size.height - 12))
    }

    // MARK: - Timers

    func setElapsed(_ seconds: TimeInterval) {
        let t = Int(seconds)
        // An hour-long meeting needs the hour. Speak's never did.
        timeLabel.stringValue = t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }

    private func startTimers() {
        stopTimers()
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.setElapsed(Capture.shared.elapsed)
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
        dot?.alphaValue = 1
    }
}
