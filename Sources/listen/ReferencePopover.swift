import AppKit

/// What is behind a numbered reference in an answer.
///
/// **A card before a page.** The number could have opened the recording
/// directly, and that is the wrong trade: a citation is read while reading the
/// sentence it sits on, and a click that replaces the page you are reading with
/// another one is a click most people will not risk twice. So the number shows
/// what it points at, over the answer, and the card is the thing that navigates.
///
/// Every rule in `.agents/notes/appkit.md` about popovers applies here and two
/// of them decide the code: the anchor is the text view, which lives as long as
/// the turn does, and it opens on the next runloop turn because this is put up
/// from inside a click that AppKit is still dispatching.
@MainActor
enum ReferencePopover {
    /// `NSPopover` does not retain itself, and one released while open takes
    /// its content view controller down mid-click.
    private static var current: NSPopover?

    static func show(_ reference: Reference, from view: NSView, rect: NSRect) {
        // Resolved before anything is built. A reference that no longer names
        // anything is a recording deleted since the answer was written, and the
        // honest response is nothing happening rather than an empty card.
        guard let target = ReferenceLookup().resolve(reference) else {
            NSSound.beep()
            return
        }
        current?.performClose(nil)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = ReferenceCard(target: target) {
            current?.performClose(nil)
            ReferenceCard.open(target)
        }
        DispatchQueue.main.async {
            // A positioning view that has left the window raises rather than
            // failing to appear. See `PersonPopover.show`, which carries the
            // measurement behind this guard.
            guard view.window != nil else {
                trace("reference popover: anchor left the window before it opened")
                return
            }
            // `.maxY` is *below* the number here. An `NSTextView` is flipped, so
            // the edge that is downward on screen is the opposite one from the
            // chips row, where the same argument produced `.minY`. Downward is
            // what matters either way: an answer's citations sit in the middle
            // of a tall pane, and a popover that does not fit is closed rather
            // than moved.
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        }
        current = popover
    }

    static func close() {
        current?.performClose(nil)
        current = nil
    }
}

/// The card itself: what the thing is, then the way to it.
private final class ReferenceCard: NSViewController {
    private let target: ReferenceTarget
    private let open: () -> Void

    private static let width: CGFloat = 320

    init(target: ReferenceTarget, open: @escaping () -> Void) {
        self.target = target
        self.open = open
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// Where a reference goes when it is clicked through.
    ///
    /// All three land on the page the library already has for that thing, by
    /// the same entry points a click in the sidebar uses. Nothing here is a
    /// second route to a view built for this popover.
    static func open(_ target: ReferenceTarget) {
        switch target {
        case .recording(let recording):
            LibraryWindow.shared.open(recording: recording.id, note: nil)
        case .note(let note):
            LibraryWindow.shared.open(note: note.slug)
        case .person(let person):
            LibraryWindow.shared.showPerson(person.label)
        }
    }

    override func loadView() {
        let card = ClickableCard { [weak self] in self?.open() }
        card.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        card.onHover = { [weak self] on in self?.lightOpen(on) }
        lightOpen(false)

        let stack = NSStackView(views: [kindRow(), title(), meta()])
        if let detail = detail() { stack.addArrangedSubview(detail) }
        stack.addArrangedSubview(openRow())
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setCustomSpacing(3, after: stack.arrangedSubviews[0])
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        card.setAccessibilityLabel("Open " + words.kind + ", " + words.title)
        view = card
    }

    // MARK: - What it says

    /// One description of the target, so the four labels cannot disagree about
    /// which kind of thing this is. Built once: every row reads it, and a
    /// date formatter per label is three formatters for one card.
    private lazy var words: (kind: String, symbol: String, title: String,
                             meta: String, detail: String?) = {
        switch target {
        case .recording(let recording):
            let people = recording.speakers.map(SpeakerName.display)
                .joined(separator: ", ")
            return ("Recording", "waveform",
                    recording.displayTitle,
                    [recording.when, recording.lengthText]
                        .filter { !$0.isEmpty }.joined(separator: " · "),
                    people.isEmpty ? nil : people)
        case .note(let note):
            var facts = [Notes.isYours(note) ? "Yours" : "Written by an agent"]
            if let when = Timestamps.parse(note.updated) {
                let f = DateFormatter()
                f.doesRelativeDateFormatting = true
                f.dateStyle = .medium
                f.timeStyle = .short
                facts.append(f.string(from: when))
            }
            return ("Note", "note.text", note.title,
                    facts.joined(separator: " · "), Self.snippet(note.body))
        case .person(let person):
            let seen = person.lastSeen.map { date -> String in
                let f = DateFormatter()
                f.doesRelativeDateFormatting = true
                f.dateStyle = .medium
                return "Last heard " + f.string(from: date)
            }
            return ("Person", "person.crop.circle", person.display,
                    person.summary, seen)
        }
    }()

    /// The first sentences of a note, as one line of prose.
    ///
    /// The markdown is not rendered here on purpose: a card is three lines and
    /// a heading rendered at 20 points inside one is a card made of one word.
    private static func snippet(_ body: String) -> String? {
        let flat = body.replacingOccurrences(of: "#", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !flat.isEmpty else { return nil }
        return flat.count > 220 ? String(flat.prefix(220)) + "…" : flat
    }

    // MARK: - The rows

    private func kindRow() -> NSView {
        let icon = NSImageView(image: NSImage(
            systemSymbolName: words.symbol, accessibilityDescription: "") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor

        let label = NSTextField(labelWithString: words.kind.uppercased())
        label.font = .systemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        return row
    }

    private func title() -> NSView {
        let label = NSTextField(wrappingLabelWithString: words.title)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = Self.width - 28
        return label
    }

    private func meta() -> NSView {
        let label = NSTextField(wrappingLabelWithString: words.meta)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = Self.width - 28
        return label
    }

    private func detail() -> NSView? {
        guard let text = words.detail else { return nil }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = Self.width - 28
        return label
    }

    /// The verb, said out loud at the foot of the card.
    ///
    /// The whole card is the button, and a card that is a button without saying
    /// so is a card people read and dismiss. This line is what makes the click
    /// discoverable, so it is text rather than a chevron on its own.
    private func openRow() -> NSView {
        let chevron = NSImageView(image: NSImage(
            systemSymbolName: "chevron.right", accessibilityDescription: "") ?? NSImage())
        chevron.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        chevron.contentTintColor = Brand.accent

        let row = NSStackView(views: [openLabel, chevron])
        row.orientation = .horizontal
        row.spacing = 3
        row.alignment = .centerY
        return row
    }

    /// The verb, kept so the pointer can underline it.
    private lazy var openLabel = NSTextField(labelWithString: "")

    /// Underline the verb while the pointer is anywhere on the card.
    ///
    /// The whole card is the button, and the line at the foot of it is what says
    /// so, but it was the accent colour and nothing else: the same blue as a
    /// reference number, on a card that until now answered a pointer with only
    /// a cursor. Underlining is what every other link in this app does under the
    /// pointer, and it is drawn on the one line that names the destination
    /// rather than as a wash over the card, which would highlight three lines of
    /// description that go nowhere on their own.
    private func lightOpen(_ on: Bool) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Brand.accent,
        ]
        if on { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        openLabel.attributedStringValue = NSAttributedString(
            string: "Open " + words.kind.lowercased(), attributes: attributes)
    }
}

/// A view that is one button, whatever is drawn inside it.
///
/// `hitTest` takes every click for the reason `AnswerTurn.HeaderRow` does:
/// whether a label swallows a click depends on whether somebody made it
/// selectable later, and a target that changes shape when an unrelated property
/// does is one that breaks quietly.
private final class ClickableCard: NSView {
    private let onClick: () -> Void
    /// True while the pointer is on the card. What that looks like belongs to
    /// the card's contents: see `ReferenceCard.lightOpen`.
    var onHover: ((Bool) -> Void)?

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// Ours by name rather than clearing `trackingAreas`, for the reason
    /// `HoverButton` records.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // `.activeAlways` rather than in-key-window: a popover's window is not
        // the key one, and this card lives in nothing else.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }
}
