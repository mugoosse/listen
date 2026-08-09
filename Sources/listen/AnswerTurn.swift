import AppKit
import QuartzCore

/// What came back, drawn the way an agent actually works.
///
/// The shape is Codex's and it is worth saying why, because the obvious layout
/// is the one this replaces. That one listed every tool call above the answer,
/// so the pane grew upwards while you were reading it: each call pushed the
/// text you were half way through down the screen. A list of everything an
/// agent did is a thing to look at *afterwards*, and while it is working the
/// only interesting fact is what it is doing **now**.
///
/// So, top to bottom:
///
/// - **"Working for 12s"**, counting, which becomes "Worked for 1m 3s" and a
///   disclosure when it stops. That one line is the whole progress report.
/// - **The blocks**, in the order they happened: what it said, then a summary
///   of what it did, then what it said next. This is the part that is worth
///   keeping and the part the disclosure hides.
/// - **One shimmering line** at the bottom saying what is happening this
///   second, replaced in place rather than appended to. Nothing below it moves,
///   because nothing is ever added below it.
///
/// The shimmer is not decoration either. A line of static grey text that
/// changes every few seconds is indistinguishable from a line of static grey
/// text that has hung; the sweep is what says the process is alive between
/// changes.
final class AnswerTurn: NSView {
    private let header = HeaderRow()
    private let elapsedLabel = NSTextField(labelWithString: "")
    private let disclosure = NSButton()
    private let blocks = NSStackView()
    private let activity = ShimmerLabel()
    private let footer = NSStackView()
    private let save = NSButton()

    /// Told the answer and the question it came from, and answers whether a note
    /// was written. See `saveTapped`.
    private let onSave: (String, String) -> Bool
    let question: String

    /// Every block, in order, so the turn can be written to `chat.json` and
    /// come back looking the same.
    private(set) var steps: [Chat.Step] = []
    /// The last text block, which is the answer. `Save as note` writes this and
    /// not the working-out.
    private(set) var body = ""
    /// Kept for the older `chat.json` shape, which stored tool lines flat.
    private(set) var toolLines: [String] = []

    /// The text view currently being streamed into, if the last block is text.
    private var openText: LinkLine?
    /// Tool phrases seen since the last text block, waiting to be summarised.
    private var pending: [String] = []
    /// Everything this answer cited, in the order the numbers were handed out.
    ///
    /// One list for the whole turn rather than one per block, so a recording
    /// named in the first paragraph and again in the last is reference 1 both
    /// times. It is rebuilt from the markdown every time a block is rendered,
    /// which is what makes a conversation read back from disk number itself the
    /// same way it did while it was being written.
    private var references: [Reference] = []

    private var started = Date()
    private var ticker: Timer?
    private var running = false
    private var collapsed = false

    init(question: String, onSave: @escaping (String, String) -> Bool) {
        self.question = question
        self.onSave = onSave
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    deinit { ticker?.invalidate() }

    // MARK: - Layout

    private func build() {
        elapsedLabel.font = .systemFont(ofSize: 12)
        elapsedLabel.textColor = .secondaryLabelColor

        disclosure.bezelStyle = .inline
        disclosure.isBordered = false
        disclosure.image = NSImage(systemSymbolName: "chevron.down",
                                   accessibilityDescription: "")
        disclosure.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        disclosure.contentTintColor = .tertiaryLabelColor
        disclosure.isHidden = true

        header.orientation = .horizontal
        header.spacing = 5
        header.alignment = .centerY
        header.addArrangedSubview(elapsedLabel)
        header.addArrangedSubview(disclosure)
        // The whole line, not the chevron. A nine point glyph is a small target
        // for something whose label is right beside it and says the same thing,
        // and every disclosure in this app that reads as a sentence should
        // behave like one.
        header.onClick = { [weak self] in self?.toggle() }

        blocks.orientation = .vertical
        blocks.alignment = .leading
        blocks.spacing = 10

        activity.isHidden = true

        save.title = "Save as note"
        save.bezelStyle = .rounded
        save.controlSize = .large
        save.font = .systemFont(ofSize: 12)
        save.target = self
        save.action = #selector(saveTapped)
        save.isHidden = true

        footer.orientation = .horizontal
        footer.spacing = 10
        footer.addArrangedSubview(save)

        // No rule under the header. Codex draws one and it is wrong here: a
        // separator implies two regions, and once the working-out is collapsed
        // there is only the answer under it, so the line was drawing a box
        // around nothing.
        let column = NSStackView(views: [header, blocks, activity, footer])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor,
                                             constant: -Self.gutter),
            // Only the blocks span the column. The header must not, or the
            // clickable disclosure becomes an invisible full-width target.
            blocks.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    /// Add a block, full width.
    ///
    /// An explicit constraint rather than `blocks.alignment = .width`, which was
    /// tried and does something else: with it the paragraphs came out
    /// *right*-aligned, visible only on the short ones because a paragraph that
    /// fills its width looks the same either way. A width constraint and
    /// leading alignment say the two separate things that were meant.
    private func addBlock(_ view: NSView) {
        blocks.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: blocks.widthAnchor).isActive = true
    }

    /// **There is deliberately no `layout()` override any more.** There used to
    /// be one, telling every paragraph its `preferredMaxLayoutWidth`, because an
    /// `NSTextField` computes its height from that and not from the width it has
    /// been given: a label left at the default reserved room for the three lines
    /// it would need at some narrower width and then drew one, leaving the
    /// difference as blank space underneath. It read as a spacing bug and was a
    /// measuring one.
    ///
    /// The blocks are `LinkLine`s now, whose container tracks the view's width,
    /// and that width is stated by the constraint `addBlock` puts on every one
    /// of them. So the measurement follows the constraint rather than a property
    /// somebody has to remember to set, and re-adding a `layout()` pass here
    /// would be setting it twice.

    /// How far short of the right edge an answer stops, so an answer and a
    /// question are visibly different shapes before you read either.
    private static let gutter: CGFloat = 40

    // MARK: - While it runs

    func begin(with backend: String) {
        running = true
        started = Date()
        tick()
        // Once a second, which is the resolution the label has. `.common` so it
        // keeps counting while a menu is open or the pane is being scrolled.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        show(activity: "Thinking")
    }

    private func tick() {
        elapsedLabel.stringValue =
            (running ? "Working for " : "Worked for ") + Self.spell(Date().timeIntervalSince(started))
    }

    /// "9s", "1m 3s", "4m 41s". Minutes only past a minute, because "0m 9s" is
    /// a stopwatch and this is a sentence.
    private static func spell(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }

    /// The line at the bottom, replaced rather than added to.
    private func show(activity text: String) {
        activity.isHidden = false
        activity.text = text
        activity.start()
    }

    private func hideActivity() {
        activity.stop()
        activity.isHidden = true
    }

    func thinking() {
        guard running, pending.isEmpty else { return }
        show(activity: "Thinking")
    }

    /// A tool call, which is the current activity and nothing more.
    ///
    /// The phrase replaces whatever the line said before. It is remembered in
    /// `pending` so that when text starts arriving again the whole phase can be
    /// collapsed into one summary, which is what keeps a twenty-call answer
    /// from being a twenty-line list.
    func tool(_ name: String, _ detail: String) {
        toolLines.append(Self.phrase(name, detail))
        pending.append(Self.category(name))
        show(activity: Self.doing(name, detail))
        // Text and tools alternate, so a tool call ends whatever paragraph was
        // being written.
        openText = nil
    }

    func appendBlock(_ text: String) {
        closePhase()
        openText = nil
        append(text)
    }

    func append(_ chunk: String) {
        closePhase()
        // Text is arriving, so nothing is "happening" that is worth a line of
        // its own: the words are the progress.
        hideActivity()

        if let open = openText {
            body += chunk
            write(body, into: open)
            if var last = steps.last, last.kind == Chat.Step.text {
                last.text = body
                steps[steps.count - 1] = last
            }
        } else {
            body = chunk
            let label = paragraph(chunk)
            addBlock(label)
            openText = label
            steps.append(Chat.Step(kind: Chat.Step.text, text: chunk))
        }
    }

    /// Fold the tool calls since the last text block into one line.
    ///
    /// "Read notes, read the transcript" rather than four rows. Codex words the
    /// same idea as "Loaded tools, read files, ran commands", and the value is
    /// the same: after the fact, *what kind* of work happened is the useful
    /// summary and the individual calls are noise.
    private func closePhase() {
        guard !pending.isEmpty else { return }
        var seen = Set<String>()
        let unique = pending.filter { seen.insert($0).inserted }
        pending = []
        let text = unique.joined(separator: ", ").capitalisedFirst
        addBlock(ActivityLine(text))
        steps.append(Chat.Step(kind: Chat.Step.activity, text: text))
    }

    func reset() {
        body = ""
        toolLines = []
        pending = []
        steps = []
        references = []
        openText = nil
        for view in blocks.arrangedSubviews { view.removeFromSuperview() }
        show(activity: "Thinking")
    }

    func fail(_ message: String) {
        stopClock()
        closePhase()
        hideActivity()
        let label = paragraph(message, colour: .systemRed)
        addBlock(label)
        openText = nil
    }

    func finish(_ outcome: AgentRun.Outcome) {
        stopClock()
        closePhase()
        hideActivity()
        if let failure = outcome.failure, body.isEmpty {
            fail(failure)
            return
        }
        // Markdown only now. Re-parsing on every delta means re-laying out the
        // whole answer forty times a second, and half-written markdown renders
        // as its own syntax while it is half-written.
        if let open = openText { open.set(rendered(body)) }
        openText = nil
        save.isHidden = body.isEmpty
        // Only worth collapsing when there is working-out to hide.
        disclosure.isHidden = steps.count < 2
        // And collapsed the moment it is finished. The chain is what you want
        // while it runs and clutter the second it stops: nobody rereads "I'll
        // start by checking what's already known" after the answer arrives, and
        // leaving it up pushes the answer down the pane behind its own preamble.
        setCollapsed(!disclosure.isHidden)
    }

    private func stopClock() {
        ticker?.invalidate()
        ticker = nil
        running = false
        tick()
    }

    /// A turn read back from disk, which is finished by definition.
    func restore(_ turn: Chat.Turn) {
        running = false
        started = Date().addingTimeInterval(-Double(turn.durationMS ?? 0) / 1000)
        elapsedLabel.stringValue = turn.durationMS
            .map { "Worked for " + Self.spell(Double($0) / 1000) } ?? "Answered"

        if let saved = turn.steps, !saved.isEmpty {
            steps = saved
            for step in saved {
                if step.kind == Chat.Step.activity {
                    addBlock(ActivityLine(step.text))
                } else {
                    let label = paragraph(step.text)
                    label.set(rendered(step.text))
                    addBlock(label)
                }
            }
            body = saved.last(where: { $0.kind == Chat.Step.text })?.text ?? turn.text
        } else {
            // The first `chat.json` shape: a flat list of tool lines and one
            // body. Rendered as one activity line and one answer, which is as
            // much order as that file records.
            if let tools = turn.tools, !tools.isEmpty {
                addBlock(ActivityLine(tools.joined(separator: ", ").capitalisedFirst))
            }
            body = turn.text
            if !turn.text.isEmpty {
                let label = paragraph(turn.text)
                label.set(rendered(turn.text))
                addBlock(label)
            }
            toolLines = turn.tools ?? []
        }

        if let failure = turn.failure, body.isEmpty {
            addBlock(paragraph(failure, colour: .systemRed))
        }
        save.isHidden = body.isEmpty
        disclosure.isHidden = blocks.arrangedSubviews.count < 2
        // A reopened conversation shows its answers, not how they were reached.
        setCollapsed(!disclosure.isHidden)
    }

    // MARK: - Hiding the working-out

    /// Collapse everything except the answer.
    ///
    /// The chain is what you want while it runs and clutter once it has. The
    /// last text block stays, because that is the answer; everything above it
    /// is how the answer was arrived at.
    private func toggle() { setCollapsed(!collapsed, animated: true) }

    /// Animated only when somebody pressed it.
    ///
    /// `finish` and `restore` also collapse, and animating those would be an
    /// answer that arrives and then visibly folds itself up, or a conversation
    /// that plays back its own history on the way in.
    private func setCollapsed(_ hide: Bool, animated: Bool = false) {
        collapsed = hide
        header.isEnabled = !disclosure.isHidden
        header.setAccessibilityLabel(
            elapsedLabel.stringValue + (hide ? ", show what it did" : ", hide what it did"))

        let last = blocks.arrangedSubviews.last
        let moving = blocks.arrangedSubviews.filter { $0 !== last }

        // Two glyphs, not one glyph rotated. `frameCenterRotation` was tried and
        // is wrong under Auto Layout: the constraint engine sets the frame on
        // the next pass and the rotation is applied about a centre that has
        // moved, so the collapsed chevron sat visibly below its own baseline
        // while the expanded one was fine. A rotation that only looks right in
        // one of its two states is not a rotation.
        disclosure.image = NSImage(
            systemSymbolName: hide ? "chevron.right" : "chevron.down",
            accessibilityDescription: "")

        let fold = {
            for view in moving {
                view.isHidden = hide
                view.alphaValue = hide ? 0 : 1
            }
        }

        guard animated else {
            fold()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            // Short. This is a disclosure, not a transition, and anything past
            // about a quarter of a second reads as the app thinking.
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // `animator()` on an arranged subview is what makes `NSStackView`
            // animate the space closing rather than snapping it shut.
            for view in moving {
                view.animator().alphaValue = hide ? 0 : 1
                view.animator().isHidden = hide
            }
            context.allowsImplicitAnimation = true
            self.superview?.layoutSubtreeIfNeeded()
        }
    }

    /// Saved without the markers.
    ///
    /// A note is a markdown file somebody may open in another editor, and
    /// `[rec:2026-08-08-150112-42A1]` in the middle of a sentence is this app's
    /// private punctuation showing through. The note keeps the recording it is
    /// about in its own `recordings` field, which is where provenance belongs.
    ///
    /// **The button reports its own outcome.** The confirmation used to be only
    /// the small grey line under the composer, which is six inches away from the
    /// thing that was pressed and is wiped by the next status change; a press
    /// that wrote a file and a press that did nothing looked identical. The
    /// control that was clicked is the one place the answer cannot be missed.
    /// Disabled with it, so an answer cannot quietly become two notes.
    @objc private func saveTapped() {
        guard onSave(AnswerReferences.strip(body), question) else { return }
        save.title = "Saved"
        save.image = NSImage(systemSymbolName: "checkmark",
                             accessibilityDescription: nil)
        save.imagePosition = .imageLeading
        save.isEnabled = false
    }

    // MARK: - Words

    /// One block of the answer.
    ///
    /// **A text view, not a label.** Every block used to be an `NSTextField`,
    /// which cannot route a click on a link to anything but `NSWorkspace`, and
    /// a citation that asks Launch Services to open `listen-recording:` is a
    /// citation that does nothing. `LinkLine` is the same view the note pane
    /// puts its sources in, for the same reason, and it brings its own height.
    /// It also retires the trap the old label carried: a selectable
    /// `NSTextField` hands itself to the field editor on the first click and
    /// re-renders its content in the control's font, so the answer lost every
    /// bold and every list indent the moment somebody clicked it to copy a line.
    private func paragraph(_ text: String, colour: NSColor = .labelColor) -> LinkLine {
        let view = LinkLine()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.delegate = self
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        // Stated rather than left at the default, which underlines every link
        // and paints it system blue whatever the attributed string asked for.
        // See `DetailView.buildNotesPane`, where leaving it out drew a blue
        // band across the pane.
        view.linkTextAttributes = [
            .foregroundColor: Brand.accent,
            .cursor: NSCursor.pointingHand,
        ]
        write(text, into: view, colour: colour)
        return view
    }

    /// The text as it arrives, before markdown is parsed.
    ///
    /// Markers are taken out here as well as at the end. They are written
    /// mid-sentence, so leaving them in while the answer streams shows the
    /// reader `[rec:2026-08-08-150112-42A1]` for as long as it takes the next
    /// paragraph to arrive, which is the one moment they are least able to
    /// ignore it.
    private func write(_ text: String, into view: LinkLine,
                       colour: NSColor = .labelColor) {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        view.set(NSAttributedString(string: AnswerReferences.strip(text), attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: colour,
            .paragraphStyle: style,
        ]))
    }

    /// Markdown, trimmed for a label that is one block among several.
    ///
    /// `MarkdownText` ends every paragraph with a newline and gives it
    /// `paragraphSpacing`, which is right in a note where the whole document is
    /// one text view and wrong here: each block is its own label inside a stack
    /// that already spaces them, so the last paragraph contributed an empty
    /// line plus its trailing spacing, and the blocks drifted apart. Measured
    /// against the plain-text version of the same answer, which was correct and
    /// is what made the cause obvious.
    ///
    /// The references are numbered on the way in and drawn on the way out,
    /// either side of the markdown, because neither parser can be trusted with
    /// a marker: the numbering has to see `[rec:…]` before Foundation decides
    /// what a bracket means, and the number has to be inserted after
    /// `MarkdownText` has finished moving text around.
    private func rendered(_ markdown: String) -> NSAttributedString {
        let numbered = AnswerReferences.number(markdown, into: &references)
        let out = NSMutableAttributedString(
            attributedString: MarkdownText.attributed(numbered))
        AnswerReferences.decorate(out, with: references)
        while let last = out.string.last, last.isNewline {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        guard out.length > 0 else { return out }
        let end = NSRange(location: out.length - 1, length: 1)
        let paragraph = (out.string as NSString).paragraphRange(for: end)
        if let style = out.attribute(.paragraphStyle, at: out.length - 1,
                                     effectiveRange: nil) as? NSParagraphStyle,
           let trimmed = style.mutableCopy() as? NSMutableParagraphStyle {
            trimmed.paragraphSpacing = 0
            out.addAttribute(.paragraphStyle, value: trimmed, range: paragraph)
        }
        return out
    }

    /// What a tool call is doing, in the present tense, for the live line.
    static func doing(_ name: String, _ detail: String) -> String {
        let quoted = detail.isEmpty ? "" : " \u{201C}\(detail)\u{201D}"
        switch name {
        case "list_recordings":    return "Looking through the library"
        case "get_recording":      return "Checking this recording"
        case "get_transcript":     return "Reading the transcript"
        case "search_transcripts": return "Searching every transcript for" + quoted
        case "list_people":        return "Checking who is in the library"
        case "list_tags":          return "Checking the tags"
        case "list_notes":         return "Looking for notes"
        case "read_note":          return "Reading the note" + quoted
        case "write_note":         return "Writing a note"
        case "edit_note":          return "Editing the note" + quoted
        case "add_tags":           return "Adding tags" + quoted
        case "remove_tags":        return "Removing tags" + quoted
        case "shell":              return "Running a command"
        default:                   return "Using " + name
        }
    }

    /// What kind of work it was, in the past tense, for the summary line.
    /// Several calls of the same kind collapse to one phrase.
    static func category(_ name: String) -> String {
        switch name {
        case "list_recordings", "get_recording", "list_people", "list_tags":
            return "looked through the library"
        case "get_transcript":     return "read the transcript"
        case "search_transcripts": return "searched the transcripts"
        case "list_notes", "read_note": return "read notes"
        case "write_note", "edit_note": return "wrote a note"
        case "add_tags", "remove_tags": return "changed tags"
        case "shell":              return "ran a command"
        default:                   return "used " + name
        }
    }

    /// The long form, kept for `chat.json`'s flat tool list and for anything
    /// that wants to know exactly what was called.
    static func phrase(_ name: String, _ detail: String) -> String {
        let doing = Self.doing(name, detail)
        return doing.prefix(1).lowercased() + doing.dropFirst()
    }
}

extension AnswerTurn: NSTextViewDelegate {
    /// A numbered reference was clicked.
    ///
    /// The card is anchored to the number itself rather than to the block, so a
    /// reference half way down a long answer does not put its popover at the
    /// top of the paragraph. The anchor view is the text view, which lives as
    /// long as this turn does: anchoring to something shorter-lived than the
    /// popover is the crash `.agents/notes/appkit.md` records.
    func textView(_ textView: NSTextView, clickedOnLink link: Any,
                  at charIndex: Int) -> Bool {
        guard let reference = Reference(link: link) else { return false }
        ReferencePopover.show(reference, from: textView,
                              rect: Self.rect(of: charIndex, in: textView))
        return true
    }

    /// Where one character is, in the text view's own coordinates.
    private static func rect(of index: Int, in view: NSTextView) -> NSRect {
        guard let manager = view.layoutManager, let container = view.textContainer else {
            return view.bounds
        }
        let glyphs = manager.glyphRange(
            forCharacterRange: NSRange(location: index, length: 1),
            actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        // The container is inset inside the view, and a rect that ignores that
        // is a popover pointing a few points off the number it belongs to.
        rect.origin.x += view.textContainerInset.width
        rect.origin.y += view.textContainerInset.height
        return rect
    }
}

// ---------------------------------------------------------------------------

/// The "Worked for 24s ›" line, clickable across its whole width.
///
/// `hitTest` is overridden rather than relying on the label passing clicks
/// through, because whether an `NSTextField` swallows a click depends on
/// whether it is selectable, and a row whose clickable area changes when
/// somebody makes a label selectable later is a row that will break quietly.
/// Nothing inside needs its own click, so the row takes them all.
private final class HeaderRow: NSStackView {
    var onClick: (() -> Void)?
    /// False while there is nothing to disclose, so a one-block answer does not
    /// offer a pointing hand over a line that does nothing.
    var isEnabled = false { didSet { window?.invalidateCursorRects(for: self) } }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .disclosureTriangle }
    override func isAccessibilityElement() -> Bool { isEnabled }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }
}

/// One folded-up phase: a wrench and a sentence.
private final class ActivityLine: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "wrench.and.screwdriver",
            accessibilityDescription: "") ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        icon.contentTintColor = .tertiaryLabelColor

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.spacing = 7
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no nib") }
}

/// A line of text with a highlight sweeping through it.
///
/// The ChatGPT effect, which in CSS is a gradient clipped to the glyphs with
/// its background position animated. AppKit has no `background-clip: text`, so
/// the same thing is built out of layers: the words are drawn once in the base
/// colour, a brighter gradient band is laid over them, and that band is masked
/// by *the same words again*, so it can only ever brighten glyphs and never the
/// space between them.
///
/// Animating `locations` rather than the layer's position, because a gradient
/// that slides has to be wider than the view and then has to be positioned
/// relative to a text width that changes every time the line does. The stops
/// are in the layer's own coordinate space, so they are correct at any width
/// with nothing to recompute.
final class ShimmerLabel: NSView {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            apply()
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private let base = CATextLayer()
    private let sheen = CAGradientLayer()
    private let sheenMask = CATextLayer()
    private var animating = false

    private var font: NSFont { .systemFont(ofSize: 12) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(base)
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.locations = [0, 0.5, 1]
        sheen.mask = sheenMask
        layer?.addSublayer(sheen)
        apply()
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    override var intrinsicContentSize: NSSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width) + 2, height: ceil(size.height))
    }

    override func layout() {
        super.layout()
        withoutAnimation {
            base.frame = bounds
            sheen.frame = bounds
            sheenMask.frame = bounds
            // Without this the text is drawn at 1x and looks soft next to every
            // other label on the pane.
            let scale = window?.backingScaleFactor ?? 2
            for layer in [base, sheenMask] { layer.contentsScale = scale }
            sheen.contentsScale = scale
        }
    }

    /// Layer properties changed outside a draw animate themselves.
    ///
    /// This line's whole job is to be replaced in place, and the default
    /// quarter-second cross-fade meant the old sentence hung behind the new one
    /// every time: "Reading the transcript" drawn over the tail of "Reading the
    /// note …", which reads as a rendering bug and is the exact opposite of the
    /// no-layout-shift point of the design.
    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func apply() {
        withoutAnimation { applyNow() }
    }

    private func applyNow() {
        for layer in [base, sheenMask] {
            layer.string = text
            layer.font = font
            layer.fontSize = font.pointSize
            layer.truncationMode = .end
            layer.alignmentMode = .left
        }
        base.foregroundColor = NSColor.secondaryLabelColor.cgColor
        // The mask only cares about alpha, so the colour is arbitrary as long
        // as it is opaque.
        sheenMask.foregroundColor = NSColor.white.cgColor
        sheen.colors = [
            NSColor.labelColor.withAlphaComponent(0).cgColor,
            NSColor.labelColor.withAlphaComponent(0.95).cgColor,
            NSColor.labelColor.withAlphaComponent(0).cgColor,
        ]
    }

    func start() {
        guard !animating else { return }
        animating = true
        let sweep = CABasicAnimation(keyPath: "locations")
        // Starts and ends fully off the line, so the band enters from the left
        // and leaves at the right rather than fading in over the middle.
        sweep.fromValue = [-0.6, -0.3, 0.0]
        sweep.toValue = [1.0, 1.3, 1.6]
        sweep.duration = 1.6
        sweep.repeatCount = .infinity
        // Linear: an eased sweep reads as something speeding up and slowing
        // down, which suggests progress that is not being measured.
        sweep.timingFunction = CAMediaTimingFunction(name: .linear)
        sheen.add(sweep, forKey: "shimmer")
    }

    func stop() {
        animating = false
        sheen.removeAnimation(forKey: "shimmer")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // A `CGColor` is a snapshot of the colour it was resolved from, so a
        // light and dark switch leaves the old one behind.
        apply()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // An animation on a layer in a window that goes away is a timer nobody
        // can see, and this view outlives its run inside a saved conversation.
        if window == nil { stop() }
    }
}

extension String {
    /// "read notes, ran a command" becomes "Read notes, ran a command".
    /// `capitalized` would title-case every word.
    var capitalisedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
