import AppKit
import ListenKit

/// The week's review, as a deck of cards in the sidebar's slot.
///
/// **A worklist, not a feed.** Every card but the opening one carries a verb,
/// and the deck does not advance itself. Auto-advance is what makes a sequence
/// of cards something you watch; a card you have to answer is something you
/// finish. That is the whole difference between memory getting better and
/// memory merely getting larger, because the answers are what correct it.
///
/// Step-through precedent is `Onboarding`, down to its rule: `updateControls`
/// must never call `render`, or a control that re-renders on being updated
/// recurses. Visual precedent is `GalaxyInspector`, because this sits beside
/// the same picture and has to look like it belongs to it.
@MainActor
final class ReviewDeck: NSViewController {
    /// **Flipped, or the card sits at the bottom of the column.** An
    /// `NSClipView`'s origin is at the bottom, so a document shorter than its
    /// scroll view is laid out from there up: the first version of this put
    /// "Your week" level with the Next button with 900 points of empty sky
    /// above it, which reads as a broken screen rather than as a short card.
    /// `PersonBriefComposer.SourceList` is the same one-line fix for the same
    /// reason, and `.agents/notes/galaxy.md` records the trap.
    private final class Deck: NSStackView { override var isFlipped: Bool { true } }
    /// The scroll view's document. Flipped for the same reason `Deck` is: an
    /// `NSClipView`'s origin is at the bottom, so an unflipped document lays
    /// out from there up.
    private final class FlippedStage: NSView { override var isFlipped: Bool { true } }

    /// A big glass pill, because this page is a picture with a card over it.
    ///
    /// The rule this codebase keeps is that every floating surface is made of
    /// the system's own material: `NSGlassEffectView` on macOS 26 and
    /// `.hudWindow` vibrancy below it, never a hand-drawn panel. Small bezelled
    /// buttons read as a form; a review is closer to a card somebody is being
    /// handed, and the control that moves it should be the size of that
    /// gesture. `GlassIconButton` is the same idea at icon size.
    final class GlassPill: NSView {
        private let backdrop: NSView
        private let button: NSButton
        private let height: CGFloat

        init(title: String, symbol: String? = nil, tinted: Bool = false,
             height: CGFloat = 44, target: AnyObject?, action: Selector) {
            self.height = height
            if #available(macOS 26.0, *) {
                let glass = NSGlassEffectView()
                glass.cornerRadius = height / 2
                // Tinted glass rather than a filled rectangle: the accent has
                // to sit in the same material as everything else on this
                // screen, or it reads as a control pasted onto the picture.
                if tinted { glass.tintColor = Brand.accent }
                backdrop = glass
            } else {
                let vibrant = NSVisualEffectView()
                vibrant.material = .hudWindow
                vibrant.blendingMode = .withinWindow
                vibrant.state = .active
                vibrant.wantsLayer = true
                vibrant.layer?.cornerRadius = height / 2
                if tinted { vibrant.layer?.backgroundColor = Brand.accent.withAlphaComponent(0.55).cgColor }
                backdrop = vibrant
            }
            button = NSButton(title: title, target: target, action: action)
            button.isBordered = false
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 15, weight: .semibold)
            button.contentTintColor = .labelColor
            if let symbol {
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                button.imagePosition = title.isEmpty ? .imageOnly : .imageTrailing
                button.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
                // **The image beside the title, not at the button's edge.**
                // A borderless `NSButton` wider than its content lays the image
                // out against its own trailing edge and leaves the gap between
                // the two to grow with the button, so "Next" and its arrow
                // drifted apart as the pill got wider while the arrow crowded
                // the glass. `imageHugsTitle` is what pairs them; the codebase
                // records the same trap for a leading image on a toolbar item.
                button.imageHugsTitle = true
            }
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            addSubview(backdrop)
            button.translatesAutoresizingMaskIntoConstraints = false
            if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
                // The supported way in: only `contentView` is laid out inside
                // the glass, and a subview added beside it is drawn over it.
                glass.contentView = button
            } else {
                backdrop.addSubview(button)
                NSLayoutConstraint.activate([
                    button.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
                    button.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
                ])
            }
            // Enough that the content is not against the glass, and no more:
            // the width was 44 points of padding on a button whose image had
            // already been pushed to the edge, which is how it read as one
            // wide button with an arrow stuck to the side of it.
            let width = max(height, button.intrinsicContentSize.width + (title.isEmpty ? 0 : 34))
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
                heightAnchor.constraint(equalToConstant: height),
                widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            ])
        }
        required init?(coder: NSCoder) { fatalError("no nib") }
        var title: String {
            get { button.title }
            set { button.title = newValue }
        }
        override func setAccessibilityLabel(_ label: String?) { button.setAccessibilityLabel(label) }
    }
    /// Stars this card is about, so the galaxy can follow the reader.
    var onFocus: (([String]) -> Void)?
    /// Open a recording, note or person the reader pressed.
    var onOpen: ((String) -> Void)?
    /// The reader is finished.
    var onClose: (() -> Void)?
    /// Ask the week's question.
    var onAsk: ((String) -> Void)?
    /// The reader asked for a different span.
    var onRange: ((Int) -> Void)?

    private var review: Review?
    private var index = 0
    private var body: NSStackView!
    private var rail: NSStackView!
    private var back: GlassPill!
    private var next: GlassPill!
    private var counter: NSTextField!
    private var column: NSStackView!
    private let range = NSPopUpButton()
    private var days = 7
    /// People the reader has said not to remember, and loose ends they have
    /// dealt with, so a card does not offer the same thing twice in one walk.
    private var handled: Set<String> = []

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        // The sidebar's slot is painted with the galaxy's sky by
        // `LibraryWindow.paintSidebarSky`, so this draws nothing of its own.
        container.appearance = NSAppearance(named: .darkAqua)

        rail = NSStackView()
        rail.orientation = .horizontal
        rail.spacing = 6
        rail.alignment = .centerY

        body = Deck()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 10

        counter = NSTextField(labelWithString: "")
        counter.font = .systemFont(ofSize: 11)
        counter.textColor = .tertiaryLabelColor

        // **The way out is Back, in the title bar.** It used to be a cross in
        // this row, which put two different exits on one screen and neither of
        // them where the rest of the app keeps its way out: settings and chats
        // both put Back at the top of the sidebar, and a review is the same
        // kind of thing, a mode you came into from somewhere and go back out
        // of. See `LibraryWindow.reviewTitleItem`.
        back = GlassPill(title: "Back", height: 44, target: self, action: #selector(goBack))
        next = GlassPill(title: "Next", symbol: "arrow.right", tinted: true, height: 44,
                         target: self, action: #selector(goNext))

        // The span, beside the rail rather than in the toolbar: it changes
        // what this page is about, and the toolbar in this mode holds only the
        // window's own verbs.
        range.pullsDown = false
        range.bezelStyle = .inline
        range.controlSize = .small
        range.target = self
        range.action = #selector(changeRange)
        range.setAccessibilityLabel("How far back this review goes")
        for value in WeeklyReview.ranges {
            range.addItem(withTitle: value >= 365 ? "Last year" : "Last \(value) days")
            range.lastItem?.tag = value
        }

        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .horizontal)
        let controls = NSStackView(views: [back, space, next])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY

        // **Centred when it is short, scrolling when it is long.** A card
        // holding a title and four figures is a quarter of this column, and
        // top-aligned it left five hundred points of empty sky underneath,
        // which reads as a page that failed to load rather than as a short
        // card. The stack cannot do this on its own: a scroll view sizes its
        // document to the content, so the document has to be told to fill the
        // clip view and the content told to sit in the middle of it.
        let stage = FlippedStage()
        stage.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(body)

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = stage

        let centre = body.centerYAnchor.constraint(equalTo: stage.centerYAnchor)
        // Beaten by the two inequalities above and below it, so a card taller
        // than the column stops centring and starts scrolling.
        centre.priority = .init(250)
        let fill = stage.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor)
        NSLayoutConstraint.activate([
            stage.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            body.topAnchor.constraint(greaterThanOrEqualTo: stage.topAnchor),
            body.bottomAnchor.constraint(lessThanOrEqualTo: stage.bottomAnchor),
            centre, fill,
        ])

        let railSpace = NSView()
        railSpace.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [rail, railSpace, range])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8

        let column = NSStackView(views: [top, scroll, counter, controls])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        column.translatesAutoresizingMaskIntoConstraints = false
        self.column = column
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            controls.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
            top.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -40),
        ])
        view = container
    }

    /// Keep the first row clear of the title bar.
    ///
    /// This pane fills the sidebar's slot, which reaches the top of the window,
    /// so its first 38 points are behind the traffic lights and the toolbar.
    /// The rail was laid out there and was simply invisible: not clipped, not
    /// mis-sized, just underneath. `GalaxyPane.updateTitlebarInset` measures
    /// the same gap the same way and for the same reason.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window, let content = window.contentView else { return }
        let bar = max(0, content.bounds.height - window.contentLayoutRect.height)
        let wanted = 18 + bar
        guard abs(column.edgeInsets.top - wanted) > 0.5 else { return }
        column.edgeInsets.top = wanted
    }

    func show(_ review: Review, days: Int) {
        self.review = review
        self.days = days
        range.selectItem(withTag: WeeklyReview.ranges.contains(days) ? days : WeeklyReview.ranges[0])
        index = 0
        handled = []
        render()
    }

    @objc private func changeRange() {
        let wanted = range.selectedItem?.tag ?? 7
        guard wanted != days else { return }
        onRange?(wanted)
    }

    private var card: ReviewCard? {
        guard let review, index >= 0, index < review.cards.count else { return nil }
        return review.cards[index]
    }

    private func render() {
        for child in body.arrangedSubviews { child.removeFromSuperview() }
        for child in rail.arrangedSubviews { child.removeFromSuperview() }
        guard let review, let card else {
            body.addArrangedSubview(label("Nothing to review yet.", size: 15, weight: .semibold))
            body.addArrangedSubview(label("Record a conversation and come back.", size: 12, color: .secondaryLabelColor))
            updateControls()
            return
        }

        // Filled behind, a ring on the one you are reading, hollow ahead. The
        // same grammar as setup's rail, rebuilt rather than mutated so it
        // cannot keep a tint from a card somebody has left.
        for position in review.cards.indices {
            let dot = NSImageView()
            let name = position < index ? "checkmark.circle.fill"
                : position == index ? "circle.inset.filled" : "circle"
            dot.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            // Secondary rather than tertiary: this rail is drawn on the
            // galaxy's sky, and tertiary on near-black is a dot nobody can
            // see. Setup's rail sits on `Brand.canvas` and can afford it.
            dot.contentTintColor = position <= index ? Brand.accent : .secondaryLabelColor
            // Sized explicitly, like setup's rail: an `NSImageView` holding a
            // symbol resolves to nothing inside a stack that is not told how
            // big it should be, and a rail of zero-width dots is a rail that
            // is simply not there.
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 11).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 11).isActive = true
            rail.addArrangedSubview(dot)
        }
        rail.setAccessibilityLabel("Card \(index + 1) of \(review.cards.count)")

        // **The title is the size of the thing it names.** A recap read at
        // arm's length is mostly one sentence and some numbers, and at 19pt
        // beside a galaxy it read as a caption on the picture rather than as
        // the point of the screen.
        body.addArrangedSubview(label(card.title, size: 30, weight: .bold))
        if !card.stats.isEmpty {
            // Figures rather than the sentence, and each one in the colour of
            // the shell it counts, so the eight people on the card and the
            // eight gold stars beside it are visibly the same eight.
            body.setCustomSpacing(18, after: body.arrangedSubviews.last!)
            body.addArrangedSubview(statGrid(card.stats))
            body.setCustomSpacing(18, after: body.arrangedSubviews.last!)
        } else if !card.detail.isEmpty {
            body.addArrangedSubview(label(card.detail, size: 15, color: .secondaryLabelColor))
        }
        if !card.stats.isEmpty, !card.detail.isEmpty, card.items.isEmpty,
           card.detail.contains("Nothing recorded") {
            body.addArrangedSubview(label(card.detail, size: 15, color: .secondaryLabelColor))
        }
        for item in card.items where !handled.contains(item.id) {
            body.addArrangedSubview(itemView(item, card: card))
        }
        if card.kind == .ask {
            let ask = NSButton(title: "Ask this", target: self, action: #selector(askIt))
            ask.bezelStyle = .rounded
            body.addArrangedSubview(ask)
        }
        updateControls()
        onFocus?(card.stars.compactMap(\.galaxyID))
    }

    /// The card's figures, two to a row, each in its shell's colour.
    private func statGrid(_ stats: [ReviewStat]) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        var row: NSStackView?
        for (index, stat) in stats.enumerated() {
            if index % 2 == 0 {
                let made = NSStackView()
                made.orientation = .horizontal
                made.alignment = .top
                made.spacing = 26
                made.distribution = .fillEqually
                column.addArrangedSubview(made)
                made.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                row = made
            }
            let value = NSTextField(labelWithString: stat.value)
            value.font = .systemFont(ofSize: 34, weight: .bold)
            value.textColor = Self.shellColor(stat.kind)
            // Digits that line up between cards rather than shuffling as the
            // counts change.
            value.font = .monospacedDigitSystemFont(ofSize: 34, weight: .bold)
            let caption = NSTextField(labelWithString: stat.label)
            caption.font = .systemFont(ofSize: 12, weight: .medium)
            caption.textColor = .secondaryLabelColor
            caption.lineBreakMode = .byTruncatingTail
            let cell = NSStackView(views: [value, caption])
            cell.orientation = .vertical
            cell.alignment = .leading
            cell.spacing = 0
            row?.addArrangedSubview(cell)
        }
        return column
    }

    /// The galaxy's own colours, so a number and the stars it counts match.
    /// `GalaxyRenderer.starColor` is the source; these are the same four.
    private static func shellColor(_ kind: String) -> NSColor {
        switch kind {
        case Galaxy.Node.person:    return NSColor(srgbRed: 1.00, green: 0.80, blue: 0.28, alpha: 1)
        case Galaxy.Node.note:      return NSColor(srgbRed: 0.46, green: 0.60, blue: 1.00, alpha: 1)
        case Galaxy.Node.chat:      return NSColor(srgbRed: 0.85, green: 0.42, blue: 1.00, alpha: 1)
        case Galaxy.Node.recording: return NSColor(srgbRed: 0.20, green: 0.88, blue: 0.74, alpha: 1)
        default:                    return .labelColor
        }
    }

    /// One line of the card, its quote, and the verbs that answer it.
    private func itemView(_ item: ReviewItem, card: ReviewCard) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.addArrangedSubview(label(item.text, size: 15, weight: .medium))
        if !item.quote.isEmpty {
            let quote = label("“" + item.quote + "”", size: 12.5, color: .secondaryLabelColor)
            quote.font = NSFontManager.shared.convert(.systemFont(ofSize: 12.5),
                                                      toHaveTrait: .italicFontMask)
            column.addArrangedSubview(quote)
        }
        if !item.date.isEmpty {
            column.addArrangedSubview(label(String(item.date.prefix(10)), size: 11, color: .tertiaryLabelColor))
        }
        var buttons: [NSView] = []
        for verb in card.verbs {
            let button = NSButton(title: verb, target: self, action: #selector(runVerb(_:)))
            button.bezelStyle = .inline
            button.controlSize = .small
            // The verb and what it acts on, because one card can hold three
            // items and a target is not recoverable from a title alone.
            button.identifier = NSUserInterfaceItemIdentifier(verb + "\u{1}" + item.id + "\u{1}" + (item.ref?.target ?? ""))
            button.setAccessibilityLabel(verb + " " + item.text)
            buttons.append(button)
        }
        if !buttons.isEmpty {
            let row = NSStackView(views: buttons)
            row.orientation = .horizontal
            row.spacing = 6
            column.addArrangedSubview(row)
        }
        return column
    }

    /// Never calls `render`. See the class note.
    private func updateControls() {
        guard let review else {
            back.isHidden = true; next.isHidden = true
            counter.stringValue = ""; return
        }
        back.isHidden = index == 0
        next.isHidden = false
        next.title = index >= review.cards.count - 1 ? "Done" : "Next"
        next.setAccessibilityLabel(next.title)
        counter.stringValue = review.cards.isEmpty ? ""
            : "\(index + 1) of \(review.cards.count)"
    }


    @objc private func goBack() {
        guard index > 0 else { return }
        index -= 1
        render()
    }

    @objc private func goNext() {
        guard let review else { onClose?(); return }
        guard index < review.cards.count - 1 else {
            // Only the library's own week moves the mark. Catching up on one
            // person is not the same as having read the week, and letting it
            // count would silently shorten the next Sunday's window.
            if review.scope == .library { WeeklyReview.lastReviewed = review.to }
            onClose?()
            return
        }
        index += 1
        render()
    }

    @objc private func askIt() {
        onAsk?(card?.detail ?? "")
    }

    @objc private func runVerb(_ sender: NSButton) {
        let parts = (sender.identifier?.rawValue ?? "").components(separatedBy: "\u{1}")
        guard parts.count == 3 else { return }
        let (verb, id, source) = (parts[0], parts[1], parts[2])
        switch verb {
        case "Open", "Name the speakers":
            onOpen?(source)
        case "Don't remember":
            // The same contract the roster and the person page use, so a no
            // here means the same thing a no anywhere else means.
            try? MemoryPreferences.automatic(false, person: MemoryPreferences.personID(source, root: Library.root),
                                             root: Library.root)
            handled.insert(id)
            render()
        case "Hide":
            try? PeopleMemory.dismiss(id)
            handled.insert(id)
            render()
        case "Accept", "Confirm":
            // Nothing to write: the claim already says this. Acknowledging it
            // is what takes it off the card, and the card is the worklist.
            handled.insert(id)
            render()
        case "Correct", "That's wrong":
            onOpen?(source)
        case "Snooze":
            handled.insert(id)
            render()
        default:
            break
        }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.isSelectable = false
        // A wrapping label reports one line as its fitting size, so anything
        // holding it has to be told how wide it is allowed to be.
        field.preferredMaxLayoutWidth = 260
        return field
    }
}
