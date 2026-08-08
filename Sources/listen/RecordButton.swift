import AppKit

/// The library's primary action, floating in the bottom right of the content
/// pane.
///
/// It was the first row of the sidebar, under the search field, and the
/// argument for it there was that Record belongs at the top of the list it
/// adds to. What that arrangement could not survive is the sidebar being
/// collapsed. Idle, the toolbar carries no record item at all
/// (`toolbarDefaultItemIdentifiers`, the `.library` case), so a collapsed
/// sidebar left the window with no way whatsoever to start a recording, and
/// only Cmd-N and the menu bar behind it. Anchored to the content pane the
/// control is there whatever the sidebar is doing, and on an empty first-run
/// library it is the only thing on the screen.
///
/// The cost is real and worth stating rather than hiding: the row this makes
/// appears at the top left of a list, diagonally opposite the button that made
/// it.
///
/// **It is also the stop control**, in the same corner, and that is the point
/// rather than a convenience. Start and stop are one toggle, and putting them
/// in opposite corners of the window means undoing a press requires crossing
/// the whole window to a control your pointer has no reason to be near. The
/// first version hid this button while a meeting ran, on the argument that the
/// live recording's red row replaces it in the same instant. The row does
/// appear, but it appears in the sidebar: nothing at all replaced the button
/// *where the button was*, which is where somebody who has just pressed it is
/// looking.
///
/// **Red only while recording**, which is the rule the toolbar's control
/// stated: a permanently red control is decoration and one that turns red is a
/// state. The glyph and the words turn, and the glass does not, because a
/// filled red capsule floating over a transcript is an alarm rather than a
/// button.
@MainActor
final class RecordButton: NSView {
    /// What pressing it does right now.
    ///
    /// `stop` carries nothing. It used to carry the elapsed clock and read
    /// "Stop 0:58", which put a second copy of that number a few hundred points
    /// from the row already printing it. See `window.md`: the row is the one
    /// clock that always counts, because it is about the recording, and this
    /// button is about the verb.
    enum State: Equatable {
        case start
        case stop
    }

    var state: State = .start {
        didSet {
            guard state != oldValue else { return }
            apply()
        }
    }

    private let label = NSTextField(labelWithString: "New Recording")
    private let icon = NSImageView()
    /// Everything that is drawn on top of the glass, in one view, because on
    /// macOS 26 that view is handed to `NSGlassEffectView` rather than added
    /// as a subview here.
    private let content = NSView()
    /// The hover and press wash, above the glass and below the words.
    private let wash = NSView()
    /// The glass on macOS 26, a vibrancy view below it. Held as `NSView` so
    /// the two paths lay out through one property.
    private let backdrop: NSView
    /// True when `backdrop` draws its own shadow and edge, which Liquid Glass
    /// does and `NSVisualEffectView` does not.
    private let isGlass: Bool

    private weak var target: AnyObject?
    private let action: Selector

    private enum M {
        static let height: CGFloat = 36
        /// Half the height, so the capsule is a capsule at any label length.
        static var radius: CGFloat { height / 2 }
        static let pad: CGFloat = 14
        static let gap: CGFloat = 7
        static let icon: CGFloat = 15
    }

    /// How far the button is held off the corner of the pane it floats over.
    ///
    /// The detail pane's content column, measured on the running window: the
    /// title, the speaker chips, the player card, the mode bar and the note all
    /// end 24 points from the edge. Deliberately **not** the toolbar's margin,
    /// which is 3 and is AppKit's rather than this app's. A control floating
    /// over the content lines up with the content; the window's chrome is a
    /// different layer and lines up with itself.
    static let margin: CGFloat = 24

    /// How much room anything scrolling underneath has to leave at its bottom.
    ///
    /// The button, the margin it is inset by, and 12 more so the last line of a
    /// transcript stops clear of it rather than touching it. Without this the
    /// end of every recording, and the end of every note somebody types, sits
    /// permanently under a capsule: scrollable to, and never readable.
    static let clearance: CGFloat = M.height + margin + 12

    private var hovering = false { didSet { restyle() } }
    private var pressed = false { didSet { restyle() } }

    init(target: AnyObject?, action: Selector) {
        self.target = target
        self.action = action
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = M.radius
            backdrop = glass
            isGlass = true
        } else {
            // The material the floating panel already uses, so the two things
            // this app puts over other content read as the same material.
            // `.withinWindow` and not `.behindWindow`: behind-window blur is
            // what a window's own background does, and inside one it samples
            // the desktop rather than the transcript underneath.
            let vibrant = NSVisualEffectView()
            vibrant.material = .hudWindow
            vibrant.blendingMode = .withinWindow
            vibrant.state = .active
            vibrant.wantsLayer = true
            vibrant.layer?.cornerRadius = M.radius
            vibrant.layer?.masksToBounds = true
            backdrop = vibrant
            isGlass = false
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        icon.imageScaling = .scaleProportionallyUpOrDown

        // Plain system digits are enough now that neither label has a digit in
        // it. This was `monospacedDigitSystemFont` for the whole life of the
        // stop clock, which is the defence `RecordingIndicator` still needs and
        // this button no longer does.
        label.font = .systemFont(ofSize: 13, weight: .medium)

        wash.wantsLayer = true
        wash.layer?.cornerRadius = M.radius

        content.addSubview(wash)
        content.addSubview(icon)
        content.addSubview(label)

        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            // The supported way in. The header is explicit that only
            // `contentView` is guaranteed a place inside the effect, and that
            // arbitrary subviews of the glass view are not, so the words go
            // through this rather than through `addSubview`.
            glass.contentView = content
            addSubview(glass)
        } else {
            addSubview(backdrop)
            addSubview(content)
            // Liquid Glass carries its own edge and shadow. Below it the
            // capsule is a flat blur with nothing separating it from the
            // transcript it is sitting on, so it is given both.
            wantsLayer = true
            shadow = NSShadow()
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.18
            layer?.shadowRadius = 8
            layer?.shadowOffset = NSSize(width: 0, height: -2)
            backdrop.layer?.borderWidth = 1
        }

        // `setAccessibilityElement(true)` and not just the role: an `NSView` is
        // not an element by default, so a role and a label set on one reach
        // nothing. Measured, because the two lines read as if the second were
        // enough: without it the app's primary action was absent from the
        // accessibility tree entirely, which is both a VoiceOver hole and, with
        // no test target here, the loss of the only way to verify it.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply()
        restyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Put the current state on screen: the words, the glyph, the colour, and
    /// the size the words now need.
    private func apply() {
        let symbol: String
        switch state {
        case .start:
            label.stringValue = "New Recording"
            symbol = "record.circle"
            toolTip = "Record this Mac's audio and your microphone (⌘N)"
        case .stop:
            label.stringValue = "Stop"
            symbol = "stop.fill"
            toolTip = "Stop recording"
        }
        let red = state != .start
        label.textColor = red ? .systemRed : .labelColor
        icon.contentTintColor = red ? .systemRed : .labelColor
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: M.icon, weight: .regular))
        setAccessibilityLabel(label.stringValue)
        // The width is the label's, and the two labels are different lengths.
        // Without this the capsule keeps the width it had before the state
        // changed, which is how "New Recording" came to be drawn in the space
        // "Stop" had left.
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Its own size, from the words in it. The pieces inside are laid out by
    /// frame rather than by constraints because on macOS 26 the middle one
    /// belongs to `NSGlassEffectView`, which positions its content view itself:
    /// constraints pinned across that boundary are a fight over the same
    /// number, which is the trap the sidebar width already paid for once.
    override var intrinsicContentSize: NSSize {
        NSSize(width: M.pad + M.icon + M.gap + labelWidth + M.pad, height: M.height)
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        // Set on both paths, and harmless on the one where the glass owns it:
        // the glass is the button's own size, so the two agree on the answer.
        content.frame = bounds
        let b = content.bounds
        wash.frame = b
        icon.frame = NSRect(x: M.pad, y: (b.height - M.icon) / 2,
                            width: M.icon, height: M.icon)
        let height = ceil(label.intrinsicContentSize.height)
        label.frame = NSRect(x: M.pad + M.icon + M.gap,
                             y: round((b.height - height) / 2),
                             width: labelWidth, height: height)
    }

    /// How wide the words actually need to be drawn.
    ///
    /// `cellSize` and **not** `intrinsicContentSize`, which is the narrower of
    /// the two and was clipping the last glyph. Measured here, on this font, at
    /// 13 point medium: "Stop" asks 29.00 as an intrinsic size and 32.97 as a
    /// cell, "New Recording" 94.50 against 98.02, "Stop 1:02:05" 79.50 against
    /// 83.48. Four points every time, which is the cell's own padding, and it
    /// is the padding the text is drawn inside.
    ///
    /// It cost the `p` of "Stop": a digit ending a string loses two points of
    /// nothing, and a round bowl loses part of itself. `sizeToFit` uses
    /// `cellSize` for exactly this reason, and this button cannot call it
    /// because the label's frame is set by hand.
    private var labelWidth: CGFloat {
        ceil(label.cell?.cellSize.width ?? label.intrinsicContentSize.width)
    }

    private func restyle() {
        let alpha: CGFloat = pressed ? 0.20 : (hovering ? 0.11 : 0)
        wash.layer?.backgroundColor = alpha == 0
            ? NSColor.clear.cgColor
            : hoverTint(alpha).cgColor
        if !isGlass {
            backdrop.layer?.borderColor = hoverTint(0.10).cgColor
        }
    }

    /// A `CGColor` is a snapshot of what it was resolved from, so switching the
    /// Mac between light and dark leaves the last one behind.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// Rebuilt on every layout, because a tracking area holds the rectangle it
    /// was made with: one added once keeps lighting up the place the button
    /// used to be after the window is resized.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        // Only when the pointer is still on the button, which is what letting
        // go somewhere else means everywhere on this platform.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    /// There is no test target, so verification is driving the real window
    /// through accessibility. A view that reports itself a button and then
    /// cannot be pressed through one is a control nothing can check.
    override func accessibilityPerformPress() -> Bool {
        NSApp.sendAction(action, to: target, from: self)
        return true
    }
}
