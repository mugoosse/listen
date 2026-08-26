import AppKit

/// What this recording or note is about, as a row of pills.
///
/// **One view for both, and it is not a convenience.** The type-to-filter
/// popover below holds `sendsActionOnEndEditing = false`, which is a trap this
/// codebase has already paid for twice, and the strip's leading pin is a
/// measured fix for Auto Layout breaking the wrong constraint. A second copy
/// for notes would be where both come back, and the precedent is written down:
/// the sidebar's speaker match and MCP's were two copies of one predicate and
/// they had already come apart. What varies between a meeting and a note is
/// `Taggable`, and that is the whole of it.
///
/// **The same band as the speakers, deliberately.** The header above the
/// transcript is already six deep: title, subtitle, chips, the document toggle,
/// the player, the transcript. A seventh band for a feature most recordings
/// will not use is the kind of thing that makes a window feel like a form, and
/// the chips row has empty trailing space on every recording that is not a
/// six-person call. Speakers read left, subjects read right, and neither costs
/// the other a point of height.
///
/// The pill is `SpeakerPill.showPlain`, which is the grey a chip standing for
/// nobody already uses. A tag is not somebody, so giving it a person's colour
/// would be the one pill in the row whose colour is a lie, and a second badge
/// class invented here would be exactly what `SpeakerPill` exists to prevent.
/// The `#` is what says which half of the row you are reading.
@MainActor
final class TagChips: NSView {
    private let stack = NSStackView()

    /// A tag was clicked, with its rectangle in this view's coordinates.
    ///
    /// The rect travels for the reason `SpeakerChips.onPerson` sends one: the
    /// caller has to convert it while the pill is still in the window, and the
    /// pills are all replaced by `configure` on any reload.
    var onTag: ((String, NSView, NSRect) -> Void)?

    /// The add button was pressed.
    var onAdd: ((NSView, NSRect) -> Void)?

    /// Something a pill's menu did changed the recording or the library.
    var onChanged: (() -> Void)?

    /// True when this recording carries no tags.
    ///
    /// The `＋` does not count. Whether the band is on screen is the pane's
    /// decision, not this view's, because it is shared with the speakers: an
    /// untranscribed recording with no tags has nothing in the band at all and
    /// it closes, and one with either has the band and therefore the `＋`.
    /// Answering "not empty, I have a button" would keep a 34 point row open
    /// under the date of every recording in the library.
    private(set) var isEmpty = true

    private var subject: Taggable?

    /// How many pills before the rest go into an overflow menu.
    ///
    /// Three rather than `SpeakerChips`'s five, and that is the transcript
    /// header's number: these share a row with the speakers there and lose to
    /// them when the pane is narrow, so the budget is what is left rather than
    /// what fits. A fourth tag is one click away and a truncated name is not a
    /// name.
    private var maxChips = 3

    /// The widest one pill is allowed to be, in points.
    ///
    /// Measured rather than chosen, **and measured for the transcript header**.
    /// The window will not go below 1056 points wide, which with the sidebar
    /// open leaves the pane 736; two speakers take about 230 of that, so the
    /// tags have roughly 480 to share. Take off the `＋` and the spacing and
    /// three pills have about 140 each.
    ///
    /// A tag may be 40 characters, which draws at over 300, so without this a
    /// single long one pushes its neighbours off the row. Truncated, the pill
    /// keeps its shape and the whole name is in the tooltip, which is the same
    /// trade the sidebar's title makes.
    private var maxChipWidth: CGFloat = 140

    /// Room for a row that is not sharing with the speakers.
    ///
    /// The note page's strip has the full width of the pane and nothing
    /// competing for it, so the two numbers above are simply the wrong ones
    /// there. They are still the defaults, because the header they were
    /// measured against is the busier case; this says out loud that a caller
    /// with a different row measured its own rather than inheriting somebody
    /// else's number by accident.
    func widen(maxChips: Int, maxChipWidth: CGFloat) {
        self.maxChips = maxChips
        self.maxChipWidth = maxChipWidth
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        // Trailing rather than leading, which is the whole arrangement: the
        // speakers grow rightward from the title and these grow leftward from
        // the window's edge, so the gap between them is whatever is spare
        // instead of a constant that is wrong at one width or another.
        //
        // **The leading edge is a preference, not a rule, and that distinction
        // was a bug.** Required, it is unsatisfiable the moment the pills are
        // wider than the space left for them, and Auto Layout resolves the
        // conflict by breaking something of its choosing: measured with three
        // 40 character tags at the narrowest the window goes, it broke the
        // *trailing* pin instead, and the row ran 335 points past the edge of
        // the pane with the `＋` off the side of the window. At a lower
        // priority it simply gives, the trailing pin holds, and `clipsToBounds`
        // takes the overflow off the left, which is the end the `+N` is at.
        let leading = stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
        leading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading,
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ subject: Taggable) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        self.subject = subject

        let tags = subject.tags
        isEmpty = tags.isEmpty

        let overflow = tags.dropFirst(maxChips)
        if !overflow.isEmpty {
            // Before the visible ones, not after. The row is read right to left
            // from the window's edge, so a count on the far right would be the
            // first thing seen and would put the tags it stands for in the
            // middle of the row rather than at the end of it.
            let more = SpeakerPill()
            more.target = self
            more.action = #selector(showOverflow)
            more.showPlain("+\(overflow.count)")
            more.toolTip = overflow.joined(separator: ", ")
            let menu = NSMenu()
            for name in overflow {
                let item = NSMenuItem(title: "#" + name,
                                      action: #selector(overflowPicked(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = name
                menu.addItem(item)
            }
            more.menu = menu
            stack.addArrangedSubview(more)
        }

        for name in tags.prefix(maxChips) {
            stack.addArrangedSubview(pill(name))
        }

        // Always last, so it stays put as tags come and go: a button that moves
        // between clicks is one you have to look for every time.
        stack.addArrangedSubview(addButton())
    }

    /// Nothing selected. The band closes, so there is no lone `+` over an empty
    /// pane offering to tag a recording that is not there.
    func clear() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        subject = nil
        isEmpty = true
        isHidden = true
    }

    private func pill(_ name: String) -> NSButton {
        let button = SpeakerPill()
        button.target = self
        button.action = #selector(tagClicked(_:))
        button.showPlain("#" + name)
        button.identifier = NSUserInterfaceItemIdentifier(name)
        button.toolTip = "Show only what is tagged #\(name)"
        button.menu = menu(for: name)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: maxChipWidth)
            .isActive = true
        return button
    }

    /// The same three things on the right button.
    ///
    /// A popover is one window-manager decision away from not appearing and a
    /// menu is not, so filtering stays reachable either way, and the two edits
    /// that are not a click go here rather than into a second popover.
    private func menu(for name: String) -> NSMenu {
        let menu = NSMenu()
        // The third item names what it is taking the tag off, because "Remove"
        // alone beside "Rename Everywhere" reads as the same scale of edit and
        // is not. The kind comes from the subject: the strip is on a note page
        // as well as a meeting now.
        let kind = subject?.kindWord ?? "Recording"
        for (title, action) in [("Show Only These", #selector(filterTo(_:))),
                                ("Rename Everywhere…", #selector(renameTag(_:))),
                                ("Remove From This \(kind)", #selector(removeTag(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        return menu
    }

    private func addButton() -> NSButton {
        let button = SpeakerPill()
        button.target = self
        button.action = #selector(addClicked(_:))
        button.showPlain("＋")
        button.toolTip = subject.map(\.tags).map {
            $0.isEmpty
                ? "Say what this \(subject?.kindWord.lowercased() ?? "recording") is about"
                : "Add another tag"
        }
        return button
    }

    // MARK: - Clicks

    @objc private func tagClicked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        onTag?(name, self, convert(sender.frame, from: stack))
    }

    @objc private func addClicked(_ sender: NSButton) {
        onAdd?(self, convert(sender.frame, from: stack))
    }

    @objc private func showOverflow(_ sender: NSButton) {
        guard let menu = sender.menu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func overflowPicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // Anchored to the overflow pill, which is the first in the row: the menu
        // item it was picked from has no view of its own by the time this runs.
        let first = stack.arrangedSubviews.first.map { convert($0.frame, from: stack) }
        onTag?(name, self, first ?? bounds)
    }

    @objc private func filterTo(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        LibraryWindow.shared.filter(byTag: name)
    }

    @objc private func removeTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let subject else { return }
        do {
            try subject.removing([name])
            onChanged?()
        } catch {
            // Said out loud rather than swallowed. A `try?` here would leave a
            // menu item that does nothing and reports nothing, which is the
            // hardest kind of failure to attribute.
            report(error)
        }
    }

    @objc private func renameTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let tag = Tags.find(name)

        let alert = NSAlert()
        alert.messageText = "Rename #\(name)?"
        // The count before the fact, for the reason `People.collisions` is
        // counted before a rename: nothing afterwards would show that this
        // reached recordings the user was not looking at.
        //
        // `summary` rather than a count of recordings, because the rename
        // reaches notes too and a sentence that said "3 recordings" before
        // rewriting four notes as well would be wrong in the one place
        // somebody is reading to decide.
        alert.informativeText = tag?.total == 1
            ? "It is on this \(subject?.kindWord.lowercased() ?? "recording") only."
            : "It is on \(tag?.summary ?? "nothing"), and all of them change."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            _ = try Tags.rename(name, to: field.stringValue)
            onChanged?()
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// Adding a tag, as a popover over the row it will land in.
///
/// The same shape as `SpeakerPicker`, which is this app's one type-to-filter
/// control, and for its reason: the useful answer is almost always a tag the
/// library already has, so the list is the feature and the text field is how
/// you narrow it. `NSTokenField` would be the first in the codebase, would not
/// match the pill language, and has its own ideas about commas.
@MainActor
enum TagPopover {
    private static var current: NSPopover?

    /// `changed` fires on every tick and **does not close the popover**.
    ///
    /// Unlike `SpeakerPicker`, where picking a name is the end of the question,
    /// filing a meeting is rarely one tag: "job hunt" and "acme" arrive
    /// together, and dismissing after the first would mean four clicks to get
    /// back to where you already were. It is `.transient`, so clicking anywhere
    /// else is still how it goes away.
    static func show(for subject: Taggable, from view: NSView, rect: NSRect,
                     changed: @escaping () -> Void) {
        current?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = TagPickerController(subject: subject,
                                                            changed: changed)
        DispatchQueue.main.async {
            // Refused rather than raised, for the reason `PersonPopover.show`
            // gives: an anchor with no window aborts the app here.
            guard view.window != nil else {
                trace("tags: anchor left the window before it opened")
                return
            }
            // Downward. These sit near the top of the pane, and a popover that
            // does not fit above is not moved, it is closed.
            popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
        current = popover
    }

    static func close() {
        current?.performClose(nil)
        current = nil
    }
}

@MainActor
private final class TagPickerController: NSViewController, NSTextFieldDelegate {
    private let subject: Taggable
    private let changed: () -> Void

    private let field = NSTextField(string: "")
    private var rows: NSStackView!
    private var carried: [String] = []
    /// How much carries each tag, by lowercased name. Rebuilt by `render`.
    private var counts: [String: Int] = [:]

    private static let width: CGFloat = 280

    init(subject: Taggable, changed: @escaping () -> Void) {
        self.subject = subject
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let title = NSTextField(labelWithString: "What is this about?")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        field.placeholderString = "Tag, or search tags"
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.target = self
        field.action = #selector(commitTyped)
        // Not on losing focus. Same trap as `SpeakerPicker`, and the same one
        // line: `NSTextField(string:)` turns `sendsActionOnEndEditing` on, so
        // clicking away from a half-typed tag filed it. See the longer note
        // there.
        field.cell?.sendsActionOnEndEditing = false
        stack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true

        rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1
        rows.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.contentView = TopAlignedClipView()
        scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: Self.width - 28),
            scroll.heightAnchor.constraint(equalToConstant: 200),
            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        view = container

        carried = subject.tags
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    private func render() {
        for view in rows.arrangedSubviews { view.removeFromSuperview() }

        let typed = Tags.canonical(field.stringValue)
        // Derived once for the whole list, not once per row.
        //
        // Each row shows how much carries its tag, and it used to ask
        // `Tags.find` for that, which walks the library. Cheap enough when the
        // library was the only thing a tag could be on, and no longer: the
        // vocabulary spans the notes directory too, so a twenty row list was
        // about to read every recording folder and every note file twenty
        // times, on every keystroke.
        let vocabulary = Tags.all()
        counts = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.name.lowercased(),
                                                                   $0.total) })
        // Carried tags first however the list is filtered, because untagging is
        // the other half of what this popover is for and a tag that scrolled
        // out of sight cannot be unticked.
        let known = Tags.suggestions(for: field.stringValue, among: vocabulary).map(\.name)
        let shown = carried.filter { typed.isEmpty || Tags.matches($0, typed)
            || $0.lowercased().contains(typed.lowercased()) }
            + known.filter { name in !carried.contains { Tags.matches($0, name) } }

        for name in shown { addRow(name) }

        // Typing something nothing carries offers to make it a tag. A row rather
        // than a second button, so coining and choosing are one gesture in one
        // list, which is `SpeakerPicker`'s arrangement.
        if !typed.isEmpty, !shown.contains(where: { Tags.matches($0, typed) }) {
            let new = NSButton(title: "New tag “\(typed)”", target: self,
                               action: #selector(commitTyped))
            new.isBordered = false
            new.font = .systemFont(ofSize: 13, weight: .medium)
            new.alignment = .left
            new.contentTintColor = Brand.accent
            rows.addArrangedSubview(new)
            new.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            new.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        if shown.isEmpty, typed.isEmpty {
            let none = NSTextField(labelWithString:
                "No tags yet. Type what this meeting is about.")
            none.font = .systemFont(ofSize: 12)
            none.textColor = .tertiaryLabelColor
            none.lineBreakMode = .byWordWrapping
            none.preferredMaxLayoutWidth = Self.width - 40
            rows.addArrangedSubview(none)
        }
    }

    private func addRow(_ name: String) {
        let on = carried.contains { Tags.matches($0, name) }
        let tick = NSImageView()
        tick.image = NSImage(systemSymbolName: on ? "checkmark.circle.fill" : "circle",
                             accessibilityDescription: nil)
        tick.contentTintColor = on ? Brand.accent : .tertiaryLabelColor
        tick.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Everything carrying it, recordings and notes together. One number,
        // because the row is answering "is this tag in use" rather than
        // breaking down what uses it, and two numbers in an 11 point label at
        // the end of a row would need a legend.
        let count = counts[name.lowercased()] ?? 0
        let detail = NSTextField(labelWithString: count > 0 ? "\(count)" : "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor

        let content = NSStackView(views: [tick, label, NSView(), detail])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8

        let row = HoverRow(content: content, target: self, action: #selector(toggle(_:)),
                           inset: 4, height: 28)
        row.identifier = NSUserInterfaceItemIdentifier(name)
        // Added and constrained in that order: a constraint between two views
        // with no common ancestor throws rather than laying out badly.
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    @objc private func toggle(_ sender: NSView) {
        guard let name = sender.identifier?.rawValue else { return }
        apply {
            carried.contains { Tags.matches($0, name) }
                ? try subject.removing([name])
                : try subject.adding([name])
        }
    }

    @objc private func commitTyped() {
        let typed = Tags.canonical(field.stringValue)
        guard !typed.isEmpty else { return }
        field.stringValue = ""
        apply { try subject.adding([typed]) }
    }

    /// Write, keep what the recording now carries, and tell the pane.
    ///
    /// `changed` redraws the strip behind this popover rather than dismissing
    /// it, so the row and the ticks cannot disagree about what is on the
    /// recording while it is still open.
    private func apply(_ write: () throws -> [String]) {
        do {
            carried = try write()
            render()
            changed()
        } catch {
            let alert = NSAlert()
            alert.messageText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    func controlTextDidChange(_ note: Notification) { render() }
}
