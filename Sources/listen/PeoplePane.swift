import AppKit

// The way back to the library was a row at the top of whichever sidebar had
// replaced the recording list, aligned to the traffic lights by hand because
// nothing else was on that line. People and Notes lost theirs when the
// segmented control became the way between collections, and settings lost the
// last one when the title bar took the pair: the word Settings on the left, the
// way out on the right. The helper that built the row and the one that put it
// on the traffic lights' line went with it.

/// Any row that goes somewhere when you click it.
///
/// A line of text that opens a recording looks exactly like a line of text that
/// does not, so every list of them needs the same thing a table row gets for
/// free: it lights up under the pointer. `SidebarRow` does this for the icon
/// rows in the sidebar; this does it for arbitrary content, which is what the
/// card, the person page and the picker are full of.
@MainActor
final class HoverRow: NSView {
    private weak var target: AnyObject?
    private let action: Selector
    private var hovering = false { didSet { restyle() } }
    private var pressed = false { didSet { restyle() } }

    init(content: NSView, target: AnyObject?, action: Selector,
         inset: CGFloat = 6, height: CGFloat = 26) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let alpha: CGFloat = pressed ? 0.26 : (hovering ? 0.16 : 0)
        layer?.backgroundColor = alpha == 0
            ? NSColor.clear.cgColor
            : hoverTint(alpha).cgColor
    }

    /// A `CGColor` is a snapshot of whatever it was resolved from, so switching
    /// the Mac between light and dark leaves the last one behind.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

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
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}

/// Everybody the library knows, as the sidebar of People mode.
///
/// The roster is the thing the feature was missing. A chip tells you who is in
/// *this* meeting, and the card tells you about one person, but neither answers
/// "who does this library know", which is the question somebody has when they
/// open the app to find a conversation they half remember.
///
/// Placeholders are absent on purpose. `A` in one meeting has nothing to do
/// with `A` in another, so a roster listing them would be a list of strangers
/// who happened to be second in the room.
@MainActor
final class PeopleNav: NSViewController {
    private var table: NSTableView!
    private var searchField: NSSearchField!
    private var people: [Person] = []
    private var query = ""
    private var picker: CollectionPicker!

    var onSelect: ((Person) -> Void)?
    var onCollection: ((LibraryCollection) -> Void)?

    private(set) var selected: Person?
    private var hover: TableHover!

    override func loadView() {
        let container = NSView()

        picker = CollectionPicker(showing: .people)
        picker.onSelect = { [weak self] in self?.onCollection?($0) }

        searchField = NSSearchField()
        searchField.placeholderString = LibraryCollection.people.searchPlaceholder
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 46
        table.style = .inset
        table.backgroundColor = .clear
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.delegate = self
        table.dataSource = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // No back row any more. The segmented control above is the way to
        // every other collection *and* the way back, so a "Library" chevron
        // beside it would be a second control saying the same thing.
        container.addSubview(picker)
        container.addSubview(searchField)
        container.addSubview(scroll)
        NSLayoutConstraint.activate(picker.constraints(in: container, above: searchField) + [
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                  constant: -10),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hover = TableHover(table, name: "people")
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hover.start()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        hover.stop()
    }

    func reload() {
        loadViewIfNeeded()
        let keep = selected?.label
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        // `roster` and not `all`, so somebody with a card and nothing recorded
        // yet is still here. The same call the CLI makes.
        people = People.roster().filter { person in
            guard !q.isEmpty else { return true }
            if person.display.lowercased().contains(q) { return true }
            return ContactBook.contact(person.label)?.emails
                .contains { $0.contains(q) } ?? false
        }
        table.reloadData()
        if let keep, let row = people.firstIndex(where: { $0.label == keep }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            selected = people[row]
        } else if selected != nil {
            selected = nil
        }
    }

    /// Select somebody by their transcript label, for arriving from a chip.
    ///
    /// False when nobody in the roster has that label, which is not an edge
    /// case: it is what a rename, a merge and an unnaming all leave behind.
    /// Returning silently is what left the page showing a person who no longer
    /// existed, so the caller has to decide what to do instead.
    @discardableResult
    func select(_ label: String) -> Bool {
        loadViewIfNeeded()
        if people.isEmpty { reload() }
        guard let row = people.firstIndex(where: { $0.label == label }) else { return false }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        selected = people[row]
        onSelect?(people[row])
        return true
    }

    /// See `SidebarViewController.setCollection`.
    func setCollection(_ collection: LibraryCollection) {
        loadViewIfNeeded()
        picker.selectedSegment = collection.rawValue
    }

    func focusSearch() { view.window?.makeFirstResponder(searchField) }

    @objc private func searchChanged() {
        query = searchField.stringValue
        reload()
    }

}

extension PeopleNav: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { people.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HoverRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        let cell = PersonCell()
        cell.configure(people[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < people.count else { return }
        selected = people[table.selectedRow]
        onSelect?(people[table.selectedRow])
    }
}

/// One roster row: who, and how much of the library they are in.
@MainActor
final class PersonCell: NSView {
    private let disc = InitialsDisc()
    private let name = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "You")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        // Beside the name rather than in front of the counts. "You · 20
        // recordings · 2h 42m" is three points too long for the sidebar, so the
        // prefix was pushing the useful half off the end of the row.
        badge.font = .systemFont(ofSize: 9, weight: .semibold)
        badge.textColor = .secondaryLabelColor

        let title = NSStackView(views: [name, badge])
        title.orientation = .horizontal
        title.spacing = 5
        title.alignment = .firstBaseline
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [disc, text] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            disc.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            disc.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.leadingAnchor.constraint(equalTo: disc.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ person: Person) {
        disc.show(person)
        name.stringValue = person.display
        badge.isHidden = !person.isYou
        detail.stringValue = person.summary
    }
}

/// The disc of initials that stands in for a photo.
///
/// Coloured from the name rather than from a palette in order, so the same
/// person is the same colour in every meeting and a list is scannable without
/// being read.
@MainActor
final class InitialsDisc: NSView {
    private let label = NSTextField(labelWithString: "")
    private var diameter: NSLayoutConstraint!

    init(size: CGFloat = 30) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: size * 0.4, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        diameter = widthAnchor.constraint(equalToConstant: size)
        NSLayoutConstraint.activate([
            diameter,
            heightAnchor.constraint(equalTo: widthAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        layer?.cornerRadius = size / 2
    }

    override convenience init(frame: NSRect) { self.init(size: 30) }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ person: Person) {
        label.stringValue = Self.initials(person.display)
        layer?.backgroundColor = Self.colour(for: person.label).cgColor
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }

    static func colour(for label: String) -> NSColor { SpeakerColour.colour(for: label) }
}

// ---------------------------------------------------------------------------

/// One person in full: who they are, what you know about them, and every
/// recording they are in.
///
/// **It reads by default and edits on request.** The first version had every
/// field live, which meant a page that mostly showed empty boxes: an empty
/// email line and a large empty notes rectangle for everybody nobody had
/// written anything about yet. Details mode shows only what exists, and the
/// menu holds the verbs.
///
/// The name is a heading rather than two fields for the same reason. First and
/// Last across the top at heading size read as a form pretending to be a title,
/// with a grey "Last" sitting where a surname should be.
@MainActor
final class PersonPane: NSViewController, NSTextFieldDelegate, NSTextViewDelegate,
                        NSMenuDelegate {
    private var person: Person?
    private var editing = false

    private let disc = InitialsDisc(size: 46)
    private let nameLabel = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let first = NSTextField(string: "")
    private let last = NSTextField(string: "")
    private let emails = NSTextField(string: "")
    private let notes = NSTextView()
    private let empty = NSTextField(labelWithString: "Select somebody.")

    private var scroll: NSScrollView!
    private var content: NSStackView!
    /// Who this is, and everything about them that is not a recording.
    ///
    /// Outside the scroll view. It used to be the first thing in it, so
    /// scrolling a person with twenty meetings took their name, their disc and
    /// the note about them off the top of the page: by the time you were
    /// reading the list you could no longer see whose it was. The list is the
    /// only thing here that can be long, so it is the only thing that scrolls.
    private var head: NSStackView!
    /// Which stack `add` is filling. Set by `render` around the two halves,
    /// rather than threaded through every builder: the page is built top to
    /// bottom in one pass, and passing a target into fifteen call sites is
    /// fifteen chances to pass the wrong one.
    private var into: NSStackView!

    /// The card changed and the person is still who they were, so the roster
    /// row beside it is stale and its selection is not.
    var onChanged: (() -> Void)?
    /// The person being looked at no longer exists under the name the roster
    /// has selected: they were renamed to `label`, merged into it, or unnamed
    /// and are nobody, which is the empty string. Whichever, the roster has to
    /// land on them, because re-selecting the label it holds cannot work and
    /// fails by leaving the page exactly as it was.
    var onLandOn: ((String) -> Void)?

    private static let maxWidth: CGFloat = 620

    override func loadView() {
        let container = NSView()

        nameLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byWordWrapping
        summary.maximumNumberOfLines = 2
        // The header must never decide how wide the page is. Left at the
        // default, one long summary line held the content stack open past the
        // pane's own width, every field ran off the right edge, and the button
        // beside it was cut in half by the window.
        for label in [nameLabel, summary] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        for field in [first, last] {
            field.font = .systemFont(ofSize: 13)
            field.delegate = self
            field.cell?.usesSingleLineMode = true
        }
        first.placeholderString = "First"
        last.placeholderString = "Last"
        emails.placeholderString = "name@example.com, other@example.com"
        emails.font = .systemFont(ofSize: 13)
        notes.font = .systemFont(ofSize: 13)
        notes.isRichText = false
        notes.textContainerInset = NSSize(width: 6, height: 6)

        head = NSStackView()
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 6
        // 14 and not 38: the window's title is hidden, so the name and the
        // disc sit level with the toolbar buttons rather than a title's height
        // below where a title used to be.
        head.edgeInsets = NSEdgeInsets(top: 14, left: 24, bottom: 0, right: 24)
        head.translatesAutoresizingMaskIntoConstraints = false

        content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 28, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false

        scroll = NSScrollView()
        scroll.contentView = TopAlignedClipView()
        scroll.documentView = content
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(head)
        container.addSubview(scroll)
        container.addSubview(empty)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: container.topAnchor),
            head.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        show(nil)
    }

    // MARK: - Showing

    func show(_ person: Person?) {
        loadViewIfNeeded()
        if person?.label != self.person?.label { editing = false }
        self.person = person
        render()
    }

    private func render() {
        for sub in head.arrangedSubviews { sub.removeFromSuperview() }
        for sub in content.arrangedSubviews { sub.removeFromSuperview() }
        guard let person else {
            head.isHidden = true
            scroll.isHidden = true
            empty.isHidden = false
            return
        }
        head.isHidden = false
        scroll.isHidden = false
        empty.isHidden = true

        let contact = ContactBook.contact(person.label)
        disc.show(person)
        nameLabel.stringValue = person.display
        summary.stringValue = facts(person)

        // A line of its own, and only when there is nothing to say instead.
        //
        // This page is where somebody comes to ask "does it know who I am", and
        // with no name set the heading says "Me" while nothing anywhere admits
        // that is a placeholder or that it can be changed. It was tried inside
        // the `·` list above and read badly: a sentence with a full stop in it,
        // wedged between a job description and a duration.
        var lines: [NSView] = [nameLabel, summary]
        if person.isYou, Settings.userName == nil {
            let hint = NSTextField(labelWithString:
                "Listen calls you Me. Settings, General is where you give it your name.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .tertiaryLabelColor
            lines.append(hint)
        }
        let titles = NSStackView(views: lines)
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [disc, titles])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        into = head
        add(header, spacingAfter: 18)
        add(rule(), spacingAfter: 14)

        editing ? renderEditor(person, contact) : renderDetails(person, contact)

        // No list while editing. It is a form, and a form with somebody's
        // twenty meetings under it is a form you have to scroll past to find
        // the Save button. It matters more now that the head does not scroll:
        // the fields would be squeezed into whatever the list left them.
        guard !editing else {
            scroll.isHidden = true
            return
        }

        add(rule(), spacingAfter: 14)
        add(section("Recordings"), spacingAfter: 10)

        // Everything above is fixed; only the list scrolls.
        into = content
        renderRecordings(person)
    }

    /// What is known, and nothing where nothing is known.
    private func renderDetails(_ person: Person, _ contact: Contact?) {
        var said = false
        if let contact, !contact.emails.isEmpty {
            add(section("Email"))
            for address in contact.emails {
                let label = NSTextField(labelWithString: address)
                label.font = .systemFont(ofSize: 13)
                label.textColor = .linkColor
                label.isSelectable = true
                add(label)
            }
            into.setCustomSpacing(14, after: into.arrangedSubviews.last!)
            said = true
        }
        if let note = contact?.note, !note.isEmpty {
            add(section("Notes"))
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = .systemFont(ofSize: 13)
            add(label, width: true, spacingAfter: 14)
            said = true
        }
        guard !said else { return }
        let nothing = NSTextField(labelWithString: person.isYou
            ? "Nothing written down about you yet."
            : "No email or notes yet.")
        nothing.font = .systemFont(ofSize: 13)
        nothing.textColor = .tertiaryLabelColor
        add(nothing, spacingAfter: 14)
    }

    /// The same fields, open for typing.
    private func renderEditor(_ person: Person, _ contact: Contact?) {
        let split = Contact.split(person.display)
        first.stringValue = contact?.firstName ?? split.first
        last.stringValue = contact?.lastName ?? split.last
        emails.stringValue = (contact?.emails ?? []).joined(separator: ", ")
        notes.string = contact?.note ?? ""

        add(section("Name"))
        for field in [first, last] {
            field.widthAnchor.constraint(equalToConstant: 150).isActive = true
        }
        let names = NSStackView(views: [first, last])
        names.orientation = .horizontal
        names.spacing = 8
        add(names, spacingAfter: 14)

        add(section("Email"))
        add(emails, width: true, spacingAfter: 14)

        add(section("Notes"))
        let notesScroll = NSScrollView()
        notesScroll.documentView = notes
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .bezelBorder
        notesScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true
        add(notesScroll, width: true)

        // Tab walks the form. **A key view loop is built from a nib, and there
        // is no nib here**, so with these links unset `nextValidKeyView` is nil
        // and Tab in the first name field does nothing whatsoever: every field
        // has to be clicked, in a form whose first two are a first name and a
        // last name sitting side by side. The loop closes back to `first`
        // rather than dead-ending, which is also what makes Shift-Tab work.
        //
        // `notes` is a text view and keeps Tab for itself, inserting a tab the
        // way a multi-line field is supposed to. It is last in the order for
        // that reason as much as for its place on screen.
        first.nextKeyView = last
        last.nextKeyView = emails
        emails.nextKeyView = notes
        notes.nextKeyView = first

        // Says what it will cost before it is pressed. The name is the one
        // field here that rewrites transcripts, and the count is the part
        // nobody can guess.
        let note = NSTextField(wrappingLabelWithString: person.isYou
            ? "Your name is shown in place of \"Me\" everywhere, past and future. "
              + "The transcripts keep saying Me, so this costs nothing to change."
            : "Renaming rewrites the transcript in "
              + (person.recordings.count == 1
                 ? "1 recording" : "\(person.recordings.count) recordings")
              + " and moves their voiceprint with the name.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        add(note, width: true)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEditing))
        let save = NSButton(title: "Save", target: self, action: #selector(saveEdits))
        for b in [cancel, save] { b.bezelStyle = .rounded }
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        add(buttons, spacingAfter: 14)
    }

    private func renderRecordings(_ person: Person) {
        guard !person.recordings.isEmpty else {
            let none = NSTextField(labelWithString: "In no recordings yet.")
            none.font = .systemFont(ofSize: 13)
            none.textColor = .tertiaryLabelColor
            add(none)
            return
        }
        for recording in person.recordings {
            let title = NSTextField(labelWithString: recording.metadata.title)
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            title.textColor = recording.isUntitled ? .secondaryLabelColor : .labelColor
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let spoken = People.speakers(in: recording)
                .first { $0.label == person.label }?.seconds
            let detail = NSTextField(labelWithString:
                [recording.when, spoken.map(Recording.length) ?? ""]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .tertiaryLabelColor
            detail.setContentHuggingPriority(.required, for: .horizontal)

            let content = NSStackView(views: [title, detail])
            content.orientation = .horizontal
            content.distribution = .fill
            content.spacing = 8

            let row = HoverRow(content: content, target: self,
                               action: #selector(openRecording(_:)))
            row.identifier = NSUserInterfaceItemIdentifier(recording.id)
            row.toolTip = "Open this recording"
            add(row, width: true)
        }
    }

    private func facts(_ person: Person) -> String {
        var parts = [person.summary]
        if person.isYou { parts.insert("You, on the microphone track", at: 0) }
        if let seen = person.lastSeen, !person.isYou {
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .none
            parts.append("last heard " + f.string(from: seen).lowercased())
        }
        let voiced = person.recordings.filter {
            $0.voiceprints[person.label]?.isEvidence == true
        }
        if !voiced.isEmpty {
            parts.append("recognised by voice in \(voiced.count)")
        } else if !person.recordings.isEmpty, !person.isYou {
            parts.append("no voiceprint yet")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - The menu

    /// The actions for whoever is on screen, as a menu the toolbar owns.
    ///
    /// Rebuilt every time it opens rather than kept in step by hand: which
    /// items belong depends on who is selected, whether they have a card yet
    /// and whether the page is being edited, and a menu that answers those
    /// from a stale copy offers Delete for somebody who has nothing to delete.
    lazy var actionsMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        // A pull-down menu takes its **first** item as the button's own title
        // and shows the rest, so whatever is first never appears. Edit Contact
        // was being eaten by the ellipsis and the menu opened on Merge, which
        // reads as Edit not having been built.
        menu.addItem(NSMenuItem())
        guard let person else {
            menu.addItem(withTitle: "No person selected", action: nil, keyEquivalent: "")
                .isEnabled = false
            return
        }
        if editing {
            menu.addItem(Action("Stop Editing", "xmark") { [weak self] in
                self?.cancelEditing()
            })
        } else {
            menu.addItem(Action("Edit", "pencil") { [weak self] in
                self?.startEditing()
            })
        }
        if !person.isYou {
            menu.addItem(Action("Merge…", "arrow.triangle.merge") { [weak self] in
                self?.mergeInto()
            })
        }
        if !person.isYou {
            menu.addItem(.separator())
            let remove = Action("Delete", "trash") {
                [weak self] in self?.removeContact()
            }
            // The only item here that changes transcripts without being asked a
            // second question first, so it is the only one that is red.
            remove.attributedTitle = NSAttributedString(
                string: "Delete",
                attributes: [.foregroundColor: NSColor.systemRed])
            menu.addItem(remove)
        }
    }

    private func startEditing() {
        editing = true
        render()
        DispatchQueue.main.async { self.view.window?.makeFirstResponder(self.first) }
    }

    @objc private func cancelEditing() {
        editing = false
        render()
    }

    // MARK: - Writing

    @objc private func saveEdits() {
        guard let person else { return }
        let typed = Contact.join(first: first.stringValue, last: last.stringValue)
        let addresses = emails.stringValue
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let text = notes.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let renaming = !typed.isEmpty && typed != person.display

        // The name first, because the book is keyed on it: writing the
        // addresses under the old name and then renaming would file them twice.
        var label = person.label
        if renaming {
            if person.isYou {
                // A preference and not a transcript edit: the label stays `Me`.
                Settings.userName = typed
            } else {
                if let problem = People.check(typed) {
                    warn(problem.localizedDescription)
                    return
                }
                guard confirm(renaming: person, to: typed) else { return }
                let changed = People.rename(person.label, to: typed)
                log("renamed \(person.label) to \(typed) in \(changed.count) recording(s)")
                // Nothing rewritten where there was something to rewrite means
                // the rename did not happen: a transcript that would not
                // decode, or one that could not be written. Carrying on files
                // the card under a name nobody has and sends the roster to
                // somebody who does not exist, which empties the page. From
                // the outside that reads as the app having deselected the
                // person rather than as a rename that failed.
                if changed.isEmpty, !person.recordings.isEmpty {
                    warn("\(person.display) could not be renamed, so nothing was "
                         + "changed. Their transcripts are as they were.")
                    return
                }
                label = typed
            }
        }
        ContactBook.set(Contact(name: person.isYou ? SpeakerName.display(SpeakerName.you)
                                                   : label,
                                emails: addresses, notes: text.isEmpty ? nil : text))

        // Leave edit mode here rather than trusting the reload to do it.
        // Setting `editing` is not what closes the editor: `render` is, and the
        // only thing that used to call it was the roster re-selecting this
        // person. A rename is exactly the case where that cannot happen,
        // because the label the roster is holding has stopped existing, so
        // nothing re-selected and nothing re-rendered. Rename looked like it
        // had done nothing, with the transcripts already rewritten behind it.
        editing = false
        render()

        // A rename means the person on screen no longer exists under the name
        // the roster has selected, so it has to be told where they went. An
        // edit to the addresses or the notes leaves the label alone, and there
        // the roster keeps its selection and only the row's summary is stale.
        if renaming { onLandOn?(label) } else { onChanged?() }
    }

    /// Fold this person into somebody else.
    ///
    /// The case it exists for is the imported library: the same human is `Me`
    /// on the recordings made here and a name on the ones that came from
    /// elsewhere. Renaming cannot fix that, because `Me` is refused as a new
    /// name and should be; merging is the one place the app accepts "that
    /// speaker was me".
    private func mergeInto() {
        guard let person, !person.isYou else { return }
        let others = People.roster().filter { $0.label != person.label }
        guard !others.isEmpty else {
            warn("There is nobody else to merge into.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Merge \(person.display) into which person?"
        alert.informativeText = "Every recording that says \(person.display) will say "
            + "the other name instead, and their addresses, notes and voiceprints "
            + "move with them. This cannot be undone from here."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: others.map { $0.display + " · " + $0.summary })
        alert.accessoryView = popup
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              popup.indexOfSelectedItem >= 0,
              popup.indexOfSelectedItem < others.count else { return }

        let target = others[popup.indexOfSelectedItem]
        let changed = People.merge(person.label, into: target.label)
        log("merged \(person.label) into \(target.label) in \(changed.count) recording(s)")
        onLandOn?(target.label)
    }

    /// Take the name off, so the speaker can be named again.
    ///
    /// **The name goes, the speech stays.** Every recording that called them
    /// Ryan calls them Speaker A again, which is a speaker waiting for a name
    /// rather than one who was deleted, and their card goes with the name it
    /// was filed under. Nothing is removed from any transcript.
    ///
    /// This is what "remove" should mean here. A version that only deleted the
    /// email and the note left the wrong name on the recordings, which is the
    /// half of the problem somebody is usually trying to fix.
    private func removeContact() {
        guard let person, !person.isYou else { return }
        let count = person.recordings.count
        let alert = NSAlert()
        let where_ = count == 1 ? "1 recording?" : "\(count) recordings?"
        // "Delete", to match the recording menu, because it is the same kind of
        // act from the user's side: this person goes. What it actually does is
        // spelled out underneath, since deleting a contact and deleting a
        // recording destroy very different amounts.
        alert.messageText = "Delete \(person.display) from " + where_
        alert.informativeText = count == 0
            ? "Their email addresses and notes are removed."
            : "They become an unnamed speaker again in "
              + (count == 1 ? "that recording" : "those recordings")
              + ", ready to be named, and their email addresses and notes are "
              + "removed. Nothing is taken out of any transcript, and their "
              + "voiceprint stays with the speaker, so the bank can still "
              + "suggest who they are."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let changed = People.unname(person.label)
        log("unnamed \(person.label) in \(changed.count) recording(s)")
        editing = false
        // The person on screen no longer exists under that name, and this time
        // they are nobody: the empty string lands the roster on no page at all.
        onLandOn?("")
    }

    private func warn(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Ask only about the half of a rename that is not already on screen.
    ///
    /// **The plain confirmation is gone.** It restated, after the click, what
    /// the line directly above Save states before it: how many transcripts get
    /// rewritten and that the voiceprint travels with the name. A second
    /// statement of a fact somebody has just read and acted on is not a safety
    /// step, it is a click, and it is the same argument that removed the
    /// keep-this-recording panel: a question asked away from the moment it
    /// belongs to gets answered without being read.
    ///
    /// A collision is different, and it is the reason this function still
    /// exists. Renaming Sarah to Anna where a recording already has an Anna
    /// merges two people there, `Merge.turns` condenses their now-adjacent
    /// turns, and the result looks exactly as though it had always been that
    /// way. Nothing on the pane says it and nothing afterwards shows it.
    private func confirm(renaming person: Person, to name: String) -> Bool {
        let collisions = People.collisions(renaming: person.label, to: name)
        guard !collisions.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = (collisions.count == 1
            ? "One recording already has" : "\(collisions.count) recordings already have")
            + " somebody called \(name)."
        alert.informativeText = "There, \(person.display) and \(name) become one person, "
            + "and their turns are condensed as though they always had been. "
            + "This cannot be undone from here."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func openRecording(_ sender: NSView) {
        guard let id = sender.identifier?.rawValue else { return }
        LibraryWindow.shared.reveal(id)
    }

    // MARK: - Furniture

    /// Add a view to the page, optionally as wide as it.
    ///
    /// Width is applied after the view is in the stack, because a constraint
    /// between two views with no common ancestor throws rather than laying out
    /// badly.
    private func add(_ view: NSView, width: Bool = false, spacingAfter: CGFloat? = nil,
                     to stack: NSStackView? = nil) {
        let stack = stack ?? into ?? content!
        stack.addArrangedSubview(view)
        if width {
            let fill = view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                                   constant: -48)
            fill.priority = .defaultLow
            NSLayoutConstraint.activate([
                fill,
                view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor,
                                            constant: -48),
                view.widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            ])
        }
        if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: view) }
    }

    private func section(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    /// A hairline the width of the page, separating who somebody is from what
    /// you know about them, and both from where they have been heard.
    private func rule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
