import AppKit

/// Naming an unnamed speaker, as a popover rather than a dialog.
///
/// **What this replaces was a stack of buttons in an alert**: a text field, a
/// "sounds like" line of prose, invitation names as loose buttons, and Save,
/// Merge and Discard underneath. Everything it could tell you was written as a
/// sentence, everything it could do was a button of equal weight, and naming
/// somebody you have named nine times before still meant typing their name
/// again.
///
/// This offers the answers instead. Every candidate the app has is a row you
/// can click: the voice bank's guess first, then whoever was on the invitation,
/// then everybody the library already knows. Typing filters them, and typing
/// something new offers to make it a person. Merge and Discard are still here,
/// because a phantom speaker over silence is not a person, but they are at the
/// bottom in the size they deserve.
@MainActor
enum SpeakerPicker {
    private static var current: NSPopover?

    static func show(for recording: Recording, speaker: String,
                     from view: NSView, rect: NSRect, done: @escaping () -> Void) {
        current?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = PickerController(
            recording: recording, speaker: speaker) {
                current?.performClose(nil)
                done()
            }
        // Downward, like every other popover in this window: these sit near the
        // top of the pane, and one that does not fit above is not moved, it is
        // closed.
        DispatchQueue.main.async {
            // Refused rather than raised, for the reason `PersonPopover.show`
            // gives: an anchor with no window aborts the app here.
            guard view.window != nil else {
                trace("picker: anchor left the window before it opened")
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
}

/// One candidate, from wherever it came.
private struct Candidate {
    /// What gets written into the transcript.
    ///
    /// Apart from the user this is the same string as `name`. The microphone
    /// track is `Me` on disk however you have chosen to be shown, so the two
    /// have to be carried separately or the row that reads "Maxime" writes a
    /// second person called Maxime beside the `Me` who is already you. This
    /// library holds that exact case from the import and it is not one to add
    /// to.
    var label: String
    /// What the row reads.
    var name: String
    /// The address that asserts *which* attendee this is, when the candidate
    /// came from an invitation. Picking the row claims it for that name.
    var email: String?
    var detail: String
    /// Sorts and groups the list. The order is confidence: what a human already
    /// said, then what the invitation says, then what the voice suggests.
    var section: String
}

@MainActor
private final class PickerController: NSViewController, NSTextFieldDelegate {
    private let recording: Recording
    private let speaker: String
    private let done: () -> Void

    private let field = NSTextField(string: "")
    private var rows: NSStackView!
    private var candidates: [Candidate] = []

    private static let width: CGFloat = 320

    init(recording: Recording, speaker: String, done: @escaping () -> Void) {
        self.recording = recording
        self.speaker = speaker
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

        let title = NSTextField(labelWithString: "Who is \(SpeakerName.display(speaker))?")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        // Only when there is a length to print. `Recording.length` gives an
        // empty string for anything under a second, and "Spoke for  of this
        // recording" is what that reads as in a sentence built around it.
        let spoken = People.speakers(in: recording).first { $0.label == speaker }?.seconds
        let howLong = spoken.map(Recording.length) ?? ""
        if !howLong.isEmpty {
            let detail = NSTextField(labelWithString:
                "Spoke for " + howLong + " of this recording")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            stack.addArrangedSubview(detail)
        }

        field.placeholderString = "Name, or search people"
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.target = self
        field.action = #selector(commitTyped)
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
            scroll.heightAnchor.constraint(equalToConstant: 220),
            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true

        // The two repairs, at the bottom and small. Diarization invents a
        // speaker over silence and splits one person into two, so both are
        // needed often enough to stay; neither is what this popover is for.
        //
        // No trailing ellipsis on either. The convention says one when a
        // control opens something that asks for more, and both of these do, but
        // in a popover that is *already* the thing asking, two dotted verbs at
        // the foot of a list read as unfinished rather than as considerate. The
        // tooltips say what each one means, which the dots never did.
        let merge = small("Merge", #selector(mergeSpeaker))
        merge.toolTip = "This speaker is really one of the others in this recording"
        let discard = small("Discard", #selector(discardSpeaker))
        discard.toolTip = "There is no person here, only noise the diarizer split off"
        let footer = NSStackView(views: [merge, discard])
        footer.orientation = .horizontal
        footer.spacing = 8
        stack.addArrangedSubview(footer)

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

        candidates = gather()
        render()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    // MARK: - Candidates

    /// Everybody this app could mean, in descending order of confidence.
    private func gather() -> [Candidate] {
        var out: [Candidate] = []
        // Never offered: anybody already in this recording. They are accounted
        // for, and naming two speakers the same thing is a merge, which is the
        // button at the bottom that says so.
        let taken = Set(recording.speakers)

        for match in VoiceBank.suggestions(for: speaker, in: recording)
        where !taken.contains(match.name) {
            out.append(Candidate(label: match.name,
                                 name: SpeakerName.display(match.name), email: nil,
                                 detail: "\(Int(match.score * 100))% match"
                                     + (match.recordings > 1
                                        ? " · \(match.recordings) recordings" : ""),
                                 section: "Sounds like"))
        }

        let named = Set(out.map(\.label))
        for person in (recording.metadata.calendar_people ?? [])
        where !person.is_me {
            guard let name = person.bestName, !taken.contains(name),
                  !named.contains(name) else { continue }
            out.append(Candidate(label: name, name: name, email: person.email,
                                 detail: [person.email,
                                          person.is_organizer ? "organizer" : nil]
                                     .compactMap { $0 }.joined(separator: " · "),
                                 section: "In the invitation"))
        }

        // You are in this list, unless you are already in this recording, and
        // `taken` is what says so: the microphone track is on disk as `Me`, so
        // the ordinary "anybody already accounted for" rule covers it. What
        // this replaced was an explicit `!person.isYou`, which left an imported
        // mix-only recording, the one kind with no microphone side, unable to
        // say that a speaker was you at all.
        let offered = Set(out.map(\.label))
        for person in People.roster()
        where !taken.contains(person.label) && !offered.contains(person.label) {
            out.append(Candidate(label: person.label, name: person.display, email: nil,
                                 detail: person.summary, section: "People"))
        }
        return out
    }

    private func render() {
        for row in rows.arrangedSubviews { row.removeFromSuperview() }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = candidates.filter {
            query.isEmpty || $0.name.lowercased().contains(query)
                || $0.detail.lowercased().contains(query)
        }

        var section = ""
        for candidate in shown {
            if candidate.section != section {
                section = candidate.section
                let label = NSTextField(labelWithString: section.uppercased())
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = .tertiaryLabelColor
                rows.addArrangedSubview(label)
            }
            addRow(for: candidate)
        }

        // Typing something nobody is called offers to make it somebody. The row
        // rather than a second button, so creating and choosing are one gesture
        // in one list.
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, !shown.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(typed) == .orderedSame }) {
            let new = NSButton(title: "New person “\(typed)”", target: self,
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
                "Nobody to suggest yet. Type a name.")
            none.font = .systemFont(ofSize: 12)
            none.textColor = .tertiaryLabelColor
            rows.addArrangedSubview(none)
        }
    }

    private func addRow(for candidate: Candidate) {
        let disc = InitialsDisc(size: 22)
        // The label, not the name: the disc takes its colour from the string on
        // disk, so passing the display name gives you a different colour here
        // from the one your chip has two inches above.
        disc.show(Person(label: candidate.label, recordings: [], seconds: 0))
        let name = NSTextField(labelWithString: candidate.name)
        name.font = .systemFont(ofSize: 13)
        let detail = NSTextField(labelWithString: candidate.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for label in [name, detail] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let content = NSStackView(views: [disc, text])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8

        // A row that lights up, so a list of people reads as a list of things
        // you can pick rather than as a paragraph about them.
        let row = HoverRow(content: content, target: self, action: #selector(pick(_:)),
                           inset: 4, height: 34)
        row.identifier = NSUserInterfaceItemIdentifier(candidate.label)
        // Added and constrained in that order: a constraint between two views
        // with no common ancestor throws rather than laying out badly.
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    // MARK: - Choosing

    @objc private func pick(_ sender: NSView) {
        guard let label = sender.identifier?.rawValue else { return }
        let email = candidates.first { $0.label == label }?.email
        apply(label: label, email: email)
    }

    @objc private func commitTyped() {
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        // An exact match in the list is that person, not a new one of the same
        // name.
        let match = candidates.first {
            $0.name.localizedCaseInsensitiveCompare(typed) == .orderedSame
        }
        apply(label: match?.label ?? Self.label(for: typed), email: match?.email)
    }

    /// The string to write for a name somebody typed.
    ///
    /// Your own name resolves back to `Me`. `SpeakerName.display` turns that
    /// label into the name you chose everywhere it is read, so typing that name
    /// in means the microphone track; taking it literally would file a second
    /// person under a name that already appears in the roster, and the two
    /// would never merge because nothing on disk says they are the same. Same
    /// accept-what-they-meant rule as `People.findByDisplayName`.
    private static func label(for typed: String) -> String {
        typed.localizedCaseInsensitiveCompare(SpeakerName.display(SpeakerName.you))
            == .orderedSame ? SpeakerName.you : typed
    }

    private func apply(label: String, email: String?) {
        // `People.checkSpeaker` and not `People.check`: this writes one label
        // onto one speaker in one transcript, where `Me` is a legitimate answer
        // and the library-wide rename's refusal of it is not. See the comment
        // on `checkSpeaker`.
        guard let problem = People.checkSpeaker(label, in: recording) else {
            TranscriptEditor.apply(.rename(speaker, to: label), to: recording)
            // The address, only when a row carrying one was picked. Typing a
            // name freehand asserts nothing about who was on the invitation,
            // which is the standard the book already holds.
            if let email { ContactBook.link(email, to: label) }
            done()
            return
        }
        let alert = NSAlert()
        alert.messageText = problem.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    func controlTextDidChange(_ note: Notification) { render() }

    // MARK: - The two repairs

    @objc private func mergeSpeaker() {
        let others = recording.speakers.filter { $0 != speaker }
        guard !others.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "There is nobody else in this recording to merge into."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Merge \(SpeakerName.display(speaker)) into which speaker?"
        alert.informativeText = "Every segment attributed to them is reassigned. "
            + "This is for a person diarization split in two."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: others.map(SpeakerName.display))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              popup.indexOfSelectedItem >= 0 else { return }
        TranscriptEditor.apply(.merge(speaker, into: others[popup.indexOfSelectedItem]),
                               to: recording)
        done()
    }

    @objc private func discardSpeaker() {
        let alert = NSAlert()
        alert.messageText = "Discard everything attributed to "
            + "\(SpeakerName.display(speaker))?"
        alert.informativeText = "Their segments are removed from the transcript. "
            + "The audio is untouched, so transcribing again brings them back."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        TranscriptEditor.apply(.discard(speaker), to: recording)
        done()
    }

    /// A capsule at the foot of the popover.
    ///
    /// **The width is stated, because an `.inline` bezel has no content inset
    /// to set.** AppKit draws one of these tight around its title, which reads
    /// as cramped beside the popover's own 14 point margins and the 34 point
    /// rows above it. Padding the title with spaces is the usual way out and it
    /// is not precise: a space is about three and a half points at this size,
    /// so the padding comes in steps of that and changes with the font.
    /// Measuring the string and adding a margin either side is what
    /// `SpeakerPill` already does, and it says what it means.
    ///
    /// `.regular` rather than `.small`: these are the only two controls at the
    /// bottom of the card, and a smaller-than-standard control is for a place
    /// that is short of room.
    private static let footerPadding: CGFloat = 18
    private static let footerHeight: CGFloat = 28

    private func small(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.controlSize = .regular
        b.translatesAutoresizingMaskIntoConstraints = false
        let font = b.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let text = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: text + Self.footerPadding * 2),
            b.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
        return b
    }
}
