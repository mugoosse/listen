import AppKit

/// One person, from the chip that names them: where else they appear, and the
/// two ways their name can change.
///
/// A popover rather than a pane or a mode. Everything here is about a name and
/// a list of recordings, both of which are small, and a popover keeps the
/// transcript you were reading on screen behind it. It is also the only place
/// in the app that edits more than one recording at once, which is why the
/// confirmation says how many before it does anything.
@MainActor
enum PersonPopover {
    /// `NSPopover` does not retain itself, and a popover that is released while
    /// open takes its content view controller with it mid-click.
    private static var current: NSPopover?

    /// Open the popover for one person.
    ///
    /// `view` has to outlive the popover, which is why the caller passes the
    /// row rather than the chip inside it. `NSPopover` closes itself as soon as
    /// its positioning view leaves the window, and anything that reloads the
    /// pane replaces every chip in the row.
    static func show(_ label: String, from view: NSView, rect: NSRect,
                     done: @escaping () -> Void) {
        guard let person = People.find(label) else { return }
        current?.performClose(nil)

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = PersonPopoverController(person: person) {
            current?.performClose(nil)
            done()
        }
        // Downward, and this is not cosmetic. `minY` is below the row in an
        // unflipped view, which is where there is room: the chips sit near the
        // top of the window, so a popover asked for above has the title bar and
        // then the screen edge within a hundred points, and one that does not
        // fit is not moved, it is closed. It came and went inside the same
        // `show(relativeTo:)` call, reporting `isShown == false` immediately
        // afterwards with a close reason of "standard".
        DispatchQueue.main.async {
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
private final class PersonPopoverController: NSViewController, NSTextFieldDelegate {
    private let person: Person
    private let done: () -> Void

    private let nameField = NSTextField(string: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var committing = false

    /// Enough rows to see the shape of somebody's history without building two
    /// hundred views for a person who is in every meeting. The remainder is
    /// counted rather than dropped silently.
    private static let maxRows = 25
    private static let width: CGFloat = 320

    init(person: Person, done: @escaping () -> Void) {
        self.person = person
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        nameField.stringValue = person.display
        nameField.font = .systemFont(ofSize: 15, weight: .semibold)
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(commit)
        // Only for the user: the Mac account name is a suggestion of what to
        // type, never something applied on its own.
        if person.isYou, Settings.userName == nil {
            nameField.placeholderString = Settings.suggestedUserName
        }

        subtitle.stringValue = person.isYou
            ? "You, on the microphone track · " + person.summary
            : person.summary
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        // The trade-off, on the control rather than in a tooltip. The two
        // renames are different operations and only one of them rewrites files,
        // so they must not read as the same button.
        note.stringValue = person.isYou
            ? "Shown in place of \"Me\" in every recording, past and future. "
              + "The transcripts keep saying Me, so this costs nothing to change."
            : "Renaming rewrites the transcript in "
              + (person.recordings.count == 1
                 ? "1 recording" : "\(person.recordings.count) recordings")
              + " and moves their voiceprint with the name."
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor

        saveButton.target = self
        saveButton.action = #selector(commit)
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .small
        saveButton.keyEquivalent = "\r"
        updateSaveButton()

        for view in [nameField, subtitle, note, saveButton] {
            stack.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        nameField.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        note.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        stack.setCustomSpacing(4, after: nameField)
        stack.setCustomSpacing(10, after: subtitle)

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true

        stack.addArrangedSubview(recordingList())

        // Useless for the user, who is in everything: a filter that selects the
        // whole library is a control that appears to do nothing.
        if !person.isYou {
            let filter = NSButton(title: "Show only \(person.display) in the library",
                                  target: self, action: #selector(filterLibrary))
            filter.bezelStyle = .inline
            filter.controlSize = .small
            stack.addArrangedSubview(filter)
        }

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
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }

    // MARK: - The recordings

    private func recordingList() -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2

        for recording in person.recordings.prefix(Self.maxRows) {
            rows.addArrangedSubview(row(for: recording))
        }
        let hidden = person.recordings.count - Self.maxRows
        if hidden > 0 {
            let more = NSTextField(labelWithString: "and \(hidden) more")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .tertiaryLabelColor
            rows.addArrangedSubview(more)
        }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.contentView = TopAlignedClipView()
        scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false

        let lines = min(person.recordings.count, Self.maxRows) + (hidden > 0 ? 1 : 0)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: Self.width - 28),
            scroll.heightAnchor.constraint(equalToConstant: min(CGFloat(lines) * 22 + 4, 200)),
            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
        return scroll
    }

    private func row(for recording: Recording) -> NSView {
        let button = NSButton(title: recording.metadata.title, target: self,
                              action: #selector(openRecording(_:)))
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.alignment = .left
        button.cell?.lineBreakMode = .byTruncatingTail
        button.identifier = NSUserInterfaceItemIdentifier(recording.id)
        button.contentTintColor = recording.isUntitled ? .secondaryLabelColor : .labelColor
        button.toolTip = "Open this recording"

        let date = NSTextField(labelWithString: Self.shortDate(recording))
        date.font = .systemFont(ofSize: 11)
        date.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [button, date])
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 6
        row.widthAnchor.constraint(equalToConstant: Self.width - 44).isActive = true
        // The title takes the slack and gives up space first: a date squeezed
        // to "5 Au" is unreadable, a truncated title is still recognisable.
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        date.setContentHuggingPriority(.required, for: .horizontal)
        return row
    }

    private static func shortDate(_ recording: Recording) -> String {
        guard let date = recording.date else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "d MMM" : "d MMM yyyy"
        return f.string(from: date)
    }

    // MARK: - Actions

    @objc private func openRecording(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        PersonPopover.close()
        LibraryWindow.shared.reveal(id)
    }

    @objc private func filterLibrary() {
        PersonPopover.close()
        LibraryWindow.shared.filter(bySpeaker: person.label)
    }

    func controlTextDidChange(_ obj: Notification) { updateSaveButton() }

    private var typed: String {
        nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateSaveButton() {
        let changed = typed != person.display
        saveButton.isEnabled = changed
        saveButton.title = person.isYou
            ? "Save"
            : "Rename in \(person.recordings.count)"
    }

    @objc private func commit() {
        // Return in the field and the default button can both fire, and the
        // second would arrive while the first is still putting a confirmation
        // on screen: two alerts asking the same question, one behind the other.
        // Only the path that leads to one latches, and it never unlatches
        // because the popover is closing.
        guard !committing else { return }
        guard typed != person.display else { done(); return }

        if person.isYou {
            // A preference, so no confirmation: nothing on disk changes and
            // clearing the field puts "Me" back.
            let chosen = typed.isEmpty || typed == SpeakerName.you ? nil : typed
            Settings.userName = chosen
            if let chosen, let other = People.find(chosen), !other.isYou {
                sayThereAreTwo(chosen, other)
            }
            done()
            return
        }

        let name = typed
        if let problem = People.check(name) {
            complain(problem.localizedDescription)
            return
        }

        // The popover has to go before a modal alert runs: a transient popover
        // closes itself when the alert takes the window, which would deallocate
        // this controller in the middle of its own action.
        committing = true
        let person = self.person
        let after = done
        PersonPopover.close()
        DispatchQueue.main.async {
            guard Self.confirm(renaming: person, to: name) else { return }
            let changed = People.rename(person.label, to: name)
            log("renamed \(person.label) to \(name) in \(changed.count) recording(s)")
            after()
        }
    }

    /// Told, not prevented.
    ///
    /// A library really can hold both: an imported recording was labelled with
    /// your name by hand, and the microphone track is `Me`, so choosing that
    /// name puts two identically labelled people in the list. They are still
    /// two people here, and the alternative to saying so is two identical chips
    /// in one transcript with nothing to explain them. Merging them is the
    /// per-recording Merge in that transcript, which is a transcript edit and
    /// not a preference.
    private func sayThereAreTwo(_ name: String, _ other: Person) {
        let alert = NSAlert()
        alert.messageText = "There is already somebody called \(name)."
        alert.informativeText = "\(other.summary), named by hand rather than "
            + "recorded on your microphone. This only changes what the microphone "
            + "track is called, so the two stay separate."
        alert.runModal()
    }

    private func complain(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
        nameField.stringValue = person.display
        updateSaveButton()
    }

    /// Say how much this touches before touching it.
    ///
    /// The collision count is the part nobody would otherwise find out: two
    /// people becoming one leaves a transcript that looks as though it was
    /// always that way.
    private static func confirm(renaming person: Person, to name: String) -> Bool {
        let collisions = People.collisions(renaming: person.label, to: name)
        let count = person.recordings.count

        let alert = NSAlert()
        alert.messageText = "Rename \(person.display) to \(name) in "
            + (count == 1 ? "1 recording?" : "\(count) recordings?")
        var body = "Every transcript with \(person.display) in it is rewritten, and "
            + "their voiceprint moves with the name so the next recording still "
            + "recognises them. This cannot be undone from here."
        if !collisions.isEmpty {
            body += "\n\n"
                + (collisions.count == 1 ? "One of them" : "\(collisions.count) of them")
                + " already has somebody called \(name), and the two become one "
                + "person there."
        }
        alert.informativeText = body
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
