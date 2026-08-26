import AppKit

/// A person, from the chip that names them.
///
/// **It reads before it edits.** The first version of this opened a name field,
/// and the complaint it earned was exactly right: clicking somebody's name to
/// find out who they are and landing in a form is the interface answering a
/// question nobody asked. So the card shows what is known, and editing is a
/// button on it.
///
/// A popover rather than a pane or a mode. Everything here is small, and a
/// popover keeps the transcript you were reading on screen behind it. The
/// larger view of the same person is People mode, which this links to.
@MainActor
enum PersonPopover {
    /// `NSPopover` does not retain itself, and a popover that is released while
    /// open takes its content view controller with it mid-click.
    private static var current: NSPopover?

    /// Open the card for one person.
    ///
    /// `view` has to outlive the popover, which is why the caller passes the
    /// row rather than the chip inside it. `NSPopover` closes itself as soon as
    /// its positioning view leaves the window, and anything that reloads the
    /// pane replaces every chip in the row.
    /// `closed` fires however this goes away, dismissed or committed. It is what
    /// puts playback back after a chip pointed it at one speaker: see
    /// `SpeakerPreview`, which carries the same hook for the unnamed side, so
    /// both kinds of chip follow one rule.
    static func show(_ label: String, from view: NSView, rect: NSRect,
                     closed: (() -> Void)? = nil,
                     done: @escaping () -> Void) {
        guard let person = People.find(label) else { return }
        current?.performClose(nil)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = ContactCard(
            person: person, editing: false, closed: closed) {
            current?.performClose(nil)
            done()
        }
        // Downward, and this is not cosmetic. `minY` is below the row in an
        // unflipped view, which is where there is room: the chips sit near the
        // top of the window, so a popover asked for above has the title bar and
        // then the screen edge within a hundred points, and one that does not
        // fit is not moved, it is closed.
        //
        // Off the click that opened it, too. A popover put up from inside a
        // control's own action arrives while the mouse event is still being
        // dispatched.
        DispatchQueue.main.async {
            // A positioning view that has left the window is an exception and
            // not a popover that fails to appear, so this is a crash guard
            // rather than tidiness. Anything the click set off gets a runloop
            // turn to reload the pane before this runs, and `DetailView` points
            // at itself precisely so that cannot take the anchor with it: if
            // this ever fires, the anchor outlived the click by less than the
            // popover needs and the caller is the thing to fix.
            guard view.window != nil else {
                trace("popover: anchor left the window before it opened")
                return
            }
            popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
        current = popover
    }

    static func close() {
        current?.performClose(nil)
        current = nil
    }

    /// The same actions as a menu.
    ///
    /// A popover is one window manager decision away from not appearing; a
    /// contextual menu is not. Every entry point this feature has is therefore
    /// also here, on the right button, which is where a Mac user looks for the
    /// verbs that apply to a thing.
    ///
    /// `open` replaces what the **first** item does, and exists because for one
    /// caller this menu is no longer only the right button. The pill in a
    /// transcript opens it on an ordinary click, so its first item has to be
    /// exactly what that click used to do: `DetailView.editSpeaker`, which
    /// routes an unnamed speaker to the picker rather than to `SpeakerSheet` and
    /// points playback at them for as long as the popover is up. Without it, the
    /// gesture people use most would reach the alert the picker replaced.
    ///
    /// The default is unchanged and is not an oversight. A chip's menu is a
    /// second route to a popover the chip itself already offers, so it
    /// deliberately does not depend on a popover appearing.
    static func menu(for label: String, in recording: Recording,
                     anchor: @escaping () -> (NSView, NSRect)?,
                     open: ((NSView, NSRect) -> Void)? = nil,
                     identify: ((NSView, NSRect) -> Void)? = nil,
                     done: @escaping () -> Void) -> NSMenu {
        let menu = NSMenu()
        let named = !VoiceBank.isPlaceholder(label)
        // The label is the contact's name: the book is keyed on it, which is
        // what makes a rename one operation rather than two that can disagree.
        let shown = SpeakerName.display(label)

        if named {
            menu.addItem(Action("Contact Card", "person.crop.circle") {
                guard let (view, rect) = anchor() else { return }
                guard let open else {
                    show(label, from: view, rect: rect, done: done)
                    return
                }
                open(view, rect)
            })
            menu.addItem(Action("Open in People", "person.2") {
                LibraryWindow.shared.showPerson(label)
            })
            menu.addItem(.separator())
            // The picker, not `SpeakerSheet`. This is the item somebody takes
            // when a name is wrong, so it has to lead somewhere that can say
            // "leave them unnamed" as well as "they are somebody else". The
            // sheet led to Merge and Discard, and Discard is how the last person
            // to walk this path deleted half a transcript.
            //
            // `identify` is here for the same reason `open` is: from a
            // transcript this item is also how one paragraph is handed to
            // somebody else, and the picker it opens carries the choice between
            // the two sizes. See `SpeakerPicker.TurnChoice`.
            //
            // The sheet is still the answer when there is no anchor to point a
            // popover at, because a menu must not depend on a popover appearing.
            menu.addItem(Action("Not \(shown)…", "person.crop.circle.badge.questionmark") {
                guard let (view, rect) = anchor() else {
                    SpeakerSheet.present(for: recording, speaker: label,
                                         in: NSApp.keyWindow, done: done)
                    return
                }
                guard let identify else {
                    SpeakerPicker.show(for: recording, speaker: label,
                                       from: view, rect: rect, done: done)
                    return
                }
                identify(view, rect)
            })
        } else {
            menu.addItem(Action("Who Is This?…", "person.crop.circle.badge.questionmark") {
                guard let open, let (view, rect) = anchor() else {
                    SpeakerSheet.present(for: recording, speaker: label,
                                         in: NSApp.keyWindow, done: done)
                    return
                }
                open(view, rect)
            })
        }
        return menu
    }
}

/// A menu item that runs a closure.
///
/// `NSMenuItem` wants a target and a selector, and every one of these items is
/// a different closure over a different person. The item owns its handler, so
/// nothing has to keep a table of them alive.
@MainActor
final class Action: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, _ symbol: String?, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}

// ---------------------------------------------------------------------------

/// The card itself, in one of its two states.
@MainActor
private final class ContactCard: NSViewController, NSTextFieldDelegate {
    private let person: Person
    private let done: () -> Void
    private var editing: Bool

    private static let width: CGFloat = 330
    /// Enough rows to see the shape of somebody's history without building two
    /// hundred views for a person who is in every meeting. The remainder is
    /// counted rather than dropped silently.
    private static let maxRows = 20

    private let first = NSTextField(string: "")
    private let last = NSTextField(string: "")
    private let emails = NSTextField(string: "")
    private let notes = NSTextView()
    private var committing = false

    private let closed: (() -> Void)?

    init(person: Person, editing: Bool, closed: (() -> Void)? = nil,
         done: @escaping () -> Void) {
        self.person = person
        self.editing = editing
        self.closed = closed
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The one hook both ways out of this card go through, dismissed or
    /// committed, so a transcript narrowed to this person is never left that way
    /// with nothing on screen asking about them.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        closed?()
    }

    private var contact: Contact? { ContactBook.contact(person.label) }

    override func loadView() {
        view = NSView()
        view.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        rebuild()
    }

    private func rebuild() {
        for sub in view.subviews { sub.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        editing ? buildEditor(into: stack) : buildCard(into: stack)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    // MARK: - Reading

    private func buildCard(into stack: NSStackView) {
        // The actions sit in the corner as a circle, the way the person page
        // puts them in the toolbar, so the foot of the card carries one plain
        // verb rather than a button and a second button pretending to be one.
        let more = NSButton(title: "", target: self, action: #selector(showMenu(_:)))
        more.bezelStyle = .circular
        // Sized to match the circles in the toolbar rather than left at the
        // default, which draws a `.circular` button noticeably smaller than
        // every other round button in the window and reads as a different kind
        // of control.
        more.controlSize = .large
        more.image = NSImage(systemSymbolName: "ellipsis",
                             accessibilityDescription: "More")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        more.toolTip = "Edit this person"
        more.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            more.widthAnchor.constraint(equalToConstant: 28),
            more.heightAnchor.constraint(equalToConstant: 28),
        ])
        let header = NSStackView(views: [disc(), titles(), NSView(), more])
        header.orientation = .horizontal
        header.alignment = .top
        header.spacing = 10
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true

        if let contact, !contact.emails.isEmpty {
            let block = NSStackView()
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 1
            for address in contact.emails {
                let label = NSTextField(labelWithString: address)
                label.font = .systemFont(ofSize: 12)
                label.textColor = .linkColor
                label.isSelectable = true
                block.addArrangedSubview(label)
            }
            stack.addArrangedSubview(block)
        }

        if let note = contact?.note, !note.isEmpty {
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            width(label)
        }

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(recordingList())
        stack.addArrangedSubview(separator())

        // The foot of the card is the way through to the person, and it used to
        // be the way to narrow the library instead. Filtering the sidebar is a
        // thing done *to* the list you were reading, and it left the card's one
        // plain verb pointing away from the person whose card it is; the page
        // that holds everything about them was two levels down, behind an
        // ellipsis. So the verb leads there, and narrowing the library by
        // somebody is gone altogether: see "Nobody wanted the library narrowed
        // by a speaker" in `speakers.md`.
        let open = button("Open in People", #selector(openInPeople))
        open.toolTip = "See everything about \(person.display) in People"
        stack.addArrangedSubview(open)
    }

    /// The initials disc, which stands in for a photo.
    ///
    /// Coloured from the name rather than from a palette in order, so the same
    /// person is the same colour in every meeting and a row of chips is
    /// scannable without reading it.
    private func disc() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 17
        box.layer?.backgroundColor = Self.colour(for: person.label).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let initials = NSTextField(labelWithString: contact?.initials
                                   ?? Self.initials(of: person.display))
        initials.font = .systemFont(ofSize: 13, weight: .semibold)
        initials.textColor = .white
        initials.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(initials)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 34),
            box.heightAnchor.constraint(equalToConstant: 34),
            initials.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            initials.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    private func titles() -> NSView {
        let name = NSTextField(labelWithString: person.display)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail

        let summary = NSTextField(labelWithString: person.summary)
        summary.font = .systemFont(ofSize: 11)
        summary.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [name, summary])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1

        if person.isYou {
            let badge = NSTextField(labelWithString: "You, on the microphone track")
            badge.font = .systemFont(ofSize: 11)
            badge.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(badge)
        } else if let last = person.lastSeen {
            let heard = NSTextField(labelWithString: "Last heard " + Self.when(last))
            heard.font = .systemFont(ofSize: 11)
            heard.textColor = .tertiaryLabelColor
            stack.addArrangedSubview(heard)
        }
        return stack
    }

    private func recordingList() -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        rows.translatesAutoresizingMaskIntoConstraints = false

        for recording in person.recordings.prefix(Self.maxRows) {
            rows.addArrangedSubview(row(for: recording))
        }
        let hidden = person.recordings.count - Self.maxRows
        if hidden > 0 {
            let more = NSTextField(labelWithString: "and \(hidden) more in People")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .tertiaryLabelColor
            rows.addArrangedSubview(more)
        }
        if person.recordings.isEmpty {
            let none = NSTextField(labelWithString: "In no recordings yet")
            none.font = .systemFont(ofSize: 12)
            none.textColor = .tertiaryLabelColor
            rows.addArrangedSubview(none)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.contentView = TopAlignedClipView()
        scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let lines = min(person.recordings.count, Self.maxRows) + (hidden > 0 ? 1 : 0)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: Self.width - 28),
            scroll.heightAnchor.constraint(
                equalToConstant: min(max(CGFloat(lines), 1) * 22 + 4, 160)),
            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return scroll
    }

    private func row(for recording: Recording) -> NSView {
        let title = NSTextField(labelWithString: recording.displayTitle)
        title.font = .systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = recording.isUntitled ? .secondaryLabelColor : .labelColor
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let date = NSTextField(labelWithString: Self.shortDate(recording))
        date.font = .systemFont(ofSize: 11)
        date.textColor = .tertiaryLabelColor
        date.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView(views: [title, date])
        content.orientation = .horizontal
        content.distribution = .fill
        content.spacing = 6

        let row = HoverRow(content: content, target: self,
                           action: #selector(openRecording(_:)), height: 24)
        row.identifier = NSUserInterfaceItemIdentifier(recording.id)
        row.toolTip = "Open this recording"
        row.widthAnchor.constraint(equalToConstant: Self.width - 34).isActive = true
        return row
    }

    // MARK: - Writing

    private func buildEditor(into stack: NSStackView) {
        let split = Contact.split(person.display)
        first.stringValue = contact?.firstName ?? split.first
        last.stringValue = contact?.lastName ?? split.last
        emails.stringValue = (contact?.emails ?? []).joined(separator: ", ")
        notes.string = contact?.note ?? ""

        for (field, placeholder) in [(first, "First"), (last, "Last")] {
            field.placeholderString = placeholder
            field.font = .systemFont(ofSize: 13)
            field.delegate = self
        }
        emails.placeholderString = "name@example.com, other@example.com"
        emails.font = .systemFont(ofSize: 12)

        let names = NSStackView(views: [first, last])
        names.orientation = .horizontal
        names.distribution = .fillEqually
        names.spacing = 6
        stack.addArrangedSubview(names)
        width(names)
        stack.addArrangedSubview(emails)
        width(emails)

        // A text view, because notes are the one field somebody writes a
        // paragraph into.
        notes.font = .systemFont(ofSize: 12)
        notes.isRichText = false
        notes.textContainerInset = NSSize(width: 4, height: 4)
        notes.drawsBackground = false
        let notesScroll = NSScrollView()
        notesScroll.documentView = notes
        notesScroll.hasVerticalScroller = true
        notesScroll.borderType = .bezelBorder
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(notesScroll)
        NSLayoutConstraint.activate([
            notesScroll.widthAnchor.constraint(equalToConstant: Self.width - 28),
            notesScroll.heightAnchor.constraint(equalToConstant: 76),
        ])

        // Tab walks the form, for the reason `PeoplePane.renderEditor` records:
        // a key view loop comes from a nib and there is no nib, so unset these
        // links mean Tab does nothing at all.
        first.nextKeyView = last
        last.nextKeyView = emails
        emails.nextKeyView = notes
        notes.nextKeyView = first

        // Says what it will cost before it is pressed. Renaming somebody is the
        // one edit here that rewrites transcripts, and the count is the part
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
        stack.addArrangedSubview(note)
        width(note)

        let cancel = button("Cancel", #selector(cancelEditing))
        let save = button("Save", #selector(commit))
        save.keyEquivalent = "\r"
        let row = NSStackView(views: [cancel, save])
        row.orientation = .horizontal
        row.spacing = 6
        stack.addArrangedSubview(row)
    }

    @objc private func startEditing() {
        editing = true
        rebuild()
        DispatchQueue.main.async { self.view.window?.makeFirstResponder(self.first) }
    }

    @objc private func cancelEditing() {
        editing = false
        rebuild()
    }

    @objc private func commit() {
        guard !committing else { return }
        let typed = Contact.join(first: first.stringValue, last: last.stringValue)
        let addresses = emails.stringValue
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let text = notes.string.trimmingCharacters(in: .whitespacesAndNewlines)

        // The name first, because everything else is filed under it. Renaming
        // moves the book entry too, through `People.rename`.
        let renaming = !typed.isEmpty && typed != person.display
        if renaming, !person.isYou {
            if let problem = People.check(typed) {
                complain(problem.localizedDescription)
                return
            }
            committing = true
            let person = self.person
            let after = done
            PersonPopover.close()
            DispatchQueue.main.async {
                guard Self.confirm(renaming: person, to: typed) else { return }
                let changed = People.rename(person.label, to: typed)
                ContactBook.set(Contact(name: typed, emails: addresses,
                                        notes: text.isEmpty ? nil : text))
                log("renamed \(person.label) to \(typed) in \(changed.count) recording(s)")
                after()
            }
            return
        }

        if person.isYou, renaming {
            // A preference and not a transcript edit: the label stays `Me`.
            Settings.userName = typed
        }
        ContactBook.set(Contact(name: person.isYou ? person.display : person.label,
                                emails: addresses, notes: text.isEmpty ? nil : text))
        done()
    }

    private func complain(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Ask only about the half of a rename that is not already on screen.
    ///
    /// `PeoplePane.confirm` carries the argument, and this card has the same
    /// line above the same Save button, so it makes the same trade: the count
    /// and the voiceprint are stated before the click and not repeated after
    /// it, and a rename that silently merges two people still asks.
    private static func confirm(renaming person: Person, to name: String) -> Bool {
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

    // MARK: - Actions

    @objc private func openRecording(_ sender: NSView) {
        guard let id = sender.identifier?.rawValue else { return }
        PersonPopover.close()
        LibraryWindow.shared.reveal(id)
    }

    /// Everything the card can do that is not its one plain verb.
    @objc private func showMenu(_ sender: NSButton) {
        // No placeholder first item here, unlike the toolbar's menu. A pull-down
        // button takes its first item as its own title and hides it; a menu
        // popped up directly shows everything it is given, so the placeholder
        // arrived on screen as a row reading "NSMenuItem".
        let menu = NSMenu()
        menu.addItem(Action("Edit", "pencil") { [weak self] in
            self?.startEditing()
        })
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func openInPeople() {
        PersonPopover.close()
        LibraryWindow.shared.showPerson(person.label)
    }

    // MARK: - Furniture

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        return box
    }

    private func width(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
    }

    private static func initials(of name: String) -> String {
        let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
        return parts.isEmpty ? "?" : String(parts).uppercased()
    }

    /// Deterministic from the name, so somebody is the same colour everywhere.
    private static func colour(for label: String) -> NSColor {
        SpeakerColour.colour(for: label)
    }

    private static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date).lowercased()
    }

    private static func shortDate(_ recording: Recording) -> String {
        guard let date = recording.date else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "d MMM" : "d MMM yyyy"
        return f.string(from: date)
    }
}
