import AppKit

/// A borderless button that says it is a button before anybody presses it.
///
/// AppKit gives a bezelled push button a resting shape, a pressed state and a
/// focus ring for nothing. It gives a borderless one none of those, so a
/// chevron that opens a menu and a chevron that is decoration are the same
/// pixels until you click one. Every control on the Ask surfaces is borderless,
/// because they float over a meeting and a row of grey bezels would be a
/// toolbar lying on the page, so all of them had that problem at once.
///
/// `HoverRow` is this for a row of a list and came first; the tint and the
/// alphas here are its, so a chip and a row light up by the same amount.
///
/// Two looks rather than two classes: the difference between them is which
/// property the pointer writes to, and the tracking, the press handling and the
/// appearance switch are the same code either way.
@MainActor
class HoverButton: NSButton {
    enum Look {
        /// The ink brightens. For a word or a glyph sitting in a line of text,
        /// where a filled rectangle would read as a second object rather than
        /// as the same one under a pointer.
        case ink
        /// The button fills a capsule of its own. `idle` is how much of it is
        /// drawn when nothing is near it: the starter chips are visible objects
        /// at rest, and the glass discs in the drawer's header are already a
        /// shape, so theirs is nothing at all.
        case fill(idle: CGFloat)
    }

    /// The `.ink` colour when the pointer is elsewhere.
    var rest: NSColor = .secondaryLabelColor { didSet { restyle() } }
    /// And under it. Brighter, never a different hue: a control that changes
    /// colour on hover reads as a state change rather than as a target.
    var bright: NSColor = .labelColor { didSet { restyle() } }

    private let look: Look
    private var hovering = false { didSet { restyle(); traceHover() } }

    /// The title as the caller set it.
    ///
    /// **An `attributedTitle` carries its own foreground colour, and it wins
    /// over `contentTintColor`.** The drawer's title button is a word and a
    /// chevron, and without this the chevron brightened under the pointer while
    /// the name beside it stayed grey: one control lighting up in halves. So
    /// the string is kept as it was given and recoloured on the way out, which
    /// is also what puts it back.
    private var baseTitle: NSAttributedString?

    init(_ look: Look = .ink) {
        self.look = look
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// The pressed state, which for a borderless button nothing else draws.
    override var isHighlighted: Bool {
        didSet { restyle() }
    }

    override var isEnabled: Bool {
        didSet { restyle() }
    }

    override var attributedTitle: NSAttributedString {
        get { super.attributedTitle }
        set {
            baseTitle = newValue
            super.attributedTitle = newValue
            restyle()
        }
    }

    override func layout() {
        super.layout()
        if case .fill = look { layer?.cornerRadius = min(bounds.height, bounds.width) / 2 }
    }

    /// **A hover that draws nothing and a hover that never fires are the same
    /// screenshot**, which is how the sidebar's highlight shipped broken three
    /// times: the fill was painted on every move, in a colour that changed no
    /// pixels. `hoverTint` is the fix for that and this is how to tell, in one
    /// run, which half of the system is at fault: whether the state landed,
    /// what alpha it asked for and what colour that actually resolved to in
    /// this view's appearance, which inside the drawer's glass is a vibrant one.
    private func traceHover() {
        guard DEBUG else { return }
        let what = (accessibilityLabel() ?? "") + title
        switch look {
        case .ink:
            trace("hover \(what.isEmpty ? "button" : what) "
                + "\(hovering ? "in" : "out") ink=\(contentTintColor?.description ?? "nil")")
        case .fill(let idle):
            trace("hover \(what.isEmpty ? "button" : what) \(hovering ? "in" : "out") "
                + "idle=\(idle) fill=\(layer?.backgroundColor.map { "\($0)" } ?? "nil")")
        }
    }

    private func restyle() {
        switch look {
        case .ink:
            let lit = isEnabled && (hovering || isHighlighted)
            contentTintColor = lit ? bright : rest
            // `super`, not `self`: the setter above is what records the title,
            // and going through it here would make the lit copy the one it
            // remembers, so the button would never go back to being quiet.
            if let baseTitle {
                guard lit else { super.attributedTitle = baseTitle; break }
                let copy = NSMutableAttributedString(attributedString: baseTitle)
                copy.addAttribute(.foregroundColor, value: bright,
                                  range: NSRange(location: 0, length: copy.length))
                super.attributedTitle = copy
            }
        case .fill(let idle):
            let alpha = !isEnabled ? idle
                : (isHighlighted ? idle + 0.15 : (hovering ? idle + 0.07 : idle))
            layer?.backgroundColor = alpha == 0
                ? NSColor.clear.cgColor
                : hoverTint(alpha).cgColor
        }
    }

    /// A `CGColor` is a snapshot of what it was resolved from, so without this
    /// the light fill stays behind after a switch to dark. `hoverTint` records
    /// the rest of it.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// **Ours is kept and removed by name, rather than clearing the lot.**
    /// `trackingAreas` is not only what this class put there: a tool tip is a
    /// tracking area installed by AppKit's own manager, and three of the four
    /// buttons this is used on have one, so removing everything on every layout
    /// pass would take "Close the conversation" off the cross while adding a
    /// highlight to it.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// A hidden view is not sent `mouseExited`, and the starter chips are
    /// hidden by the first question being asked: without this they come back
    /// for the next conversation still lit, under a pointer that is somewhere
    /// else entirely.
    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
    }
}

/// A button drawn as a filled capsule.
///
/// The starter chips and the two controls under an answer are the same object
/// with different words in them, and all of them were `.rounded` push buttons
/// before this. A bordered `NSButton` draws its bezel over anything the layer
/// holds, so there is no way to add a hover to that shape from outside it: the
/// capsule has to be ours to draw. 26 points tall with 13 either side is what
/// `controlSize = .large` measured, so nothing moved when they changed.
@MainActor
class ChipButton: HoverButton {
    static let height: CGFloat = 26
    private static let padding: CGFloat = 13
    /// The gap AppKit is not asked for, because the width below is.
    private static let glyphGap: CGFloat = 5

    private var label = ""

    init(_ title: String) {
        super.init(.fill(idle: 0.08))
        // **The glyph belongs beside the words, not at the capsule's edge.**
        // An untouched leading image is laid out against the leading edge while
        // the title, whose paragraph style centres it, stays in the middle of
        // what is left: the Saved chip came out as a checkmark hard against the
        // rounded edge with a gap the width of the padding after it. The width
        // below already reserves the glyph and one gap, so hugging is what
        // spends it in the right place. Same fix, same reason, as the drawer's
        // title button.
        imageHugsTitle = true
        setLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// Change the words.
    ///
    /// Not `title`, which lands in whatever colour the cell picks, and this is
    /// not a one-off: `AnswerTurn` relabels its Save button to "Saved" the
    /// moment it is pressed, which is the whole of how that press is confirmed.
    func setLabel(_ text: String) {
        label = text
        applyLabel()
    }

    /// Dimmed when it is spent. **AppKit greys a disabled button's plain title
    /// and leaves an attributed one alone**, because the string's own colour
    /// wins, so without this a Saved chip that can no longer be pressed reads
    /// exactly like a live one.
    override var isEnabled: Bool {
        didSet { applyLabel() }
    }

    private func applyLabel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        attributedTitle = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            .paragraphStyle: paragraph,
        ])
    }

    /// Wide enough for the words, and for a glyph if one was set: the capsule is
    /// sized here rather than by the cell, so a checkmark added later would be
    /// drawn into padding that was never asked for.
    override var intrinsicContentSize: NSSize {
        let glyph = image.map { ceil($0.size.width) + Self.glyphGap } ?? 0
        return NSSize(width: ceil(attributedTitle.size().width) + glyph + Self.padding * 2,
                      height: Self.height)
    }
}
