import AppKit
import ListenKit

/// What is about to happen: the row at the top of the library, the page it
/// opens, and the sentence the agent is handed to prepare for it.
///
/// **This is the one part of the app that is about a meeting that has not
/// happened.** Everything else here reads a folder on disk; there is no folder
/// yet, so nothing on this page can be saved, corrected or deleted, and the
/// only durable thing a person can do from it is ask a question. That is also
/// why the conversation carries `Chat.event`: when the meeting is finally
/// recorded, `MeetingCalendar.attach` hands the conversation to the recording
/// and the preparation stops being a thing you have to remember asking.

// ---------------------------------------------------------------------------

/// The people on a meeting, as the discs they are everywhere else.
///
/// **The same disc, not a second one drawn to match.** `InitialsDisc` colours
/// itself from the name through `SpeakerColour`, which is a function of the
/// string, so somebody who has never been recorded gets the colour they will
/// have the moment they are: the face on an invitation and the chip on the
/// transcript of that meeting are the same mark. It also costs nothing to
/// build, which is what makes it affordable on a table cell: no roster, no
/// library read, one hash per name.
@MainActor
final class FaceRow: NSStackView {
    /// 20 rather than the 16 the icon column uses. Initials are drawn at 0.4 of
    /// the diameter, so 16 puts two letters in 6 points and the disc becomes a
    /// coloured dot; 20 is the smallest that can still be read.
    static let size: CGFloat = 20
    /// How far each disc sits under the one before it. Enough to say "these
    /// belong together" and not so much that a letter is hidden.
    private static let overlap: CGFloat = -6

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .horizontal
        alignment = .centerY
        spacing = Self.overlap
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Up to `limit` faces, and a count for the rest.
    func show(_ names: [String], limit: Int = 3) {
        for view in arrangedSubviews { view.removeFromSuperview() }
        for name in names.prefix(limit) {
            let disc = InitialsDisc(size: Self.size)
            disc.show(Person(label: name, recordings: [], seconds: 0))
            addArrangedSubview(disc)
        }
        guard names.count > limit else { return }
        // Grey, and a number rather than a letter, for `SpeakerPill`'s reason:
        // the overflow stands for nobody, and giving it somebody's colour
        // would be the one disc in the row whose colour is a lie.
        let more = CountDisc(size: Self.size)
        more.show(names.count - limit)
        addArrangedSubview(more)
    }
}

/// "+2", in the same circle the faces are.
@MainActor
final class CountDisc: NSView {
    private let label = NSTextField(labelWithString: "")

    init(size: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: size * 0.36, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        layer?.cornerRadius = size / 2
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalTo: widthAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ count: Int) { label.stringValue = "+\(count)" }

    /// A `CGColor` is resolved when it is set, so it does not follow the Mac
    /// between light and dark on its own.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }
}

/// One upcoming meeting, as a row in the library list.
///
/// Laid out like `RecordingCell` on purpose, down to the icon column: this row
/// is in the same table, and a second set of numbers for the same shape is the
/// trap that file records against its own 22 points.
@MainActor
final class EventCell: NSView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    /// Who is coming, as faces at the trailing edge.
    ///
    /// **Not in the leading column, which is where a face wants to go.** That
    /// column is 16 points at an inset of 8 and every title in this list starts
    /// after it: `RecordingCell.icon` records that a cell inventing its own
    /// width there lands two points off every other label, which reads as a
    /// mistake rather than a margin. Faces are wider than a glyph however they
    /// are drawn, so they went to the other end, which is where a calendar puts
    /// them anyway.
    private let faces = FaceRow()

    private static let iconSize: CGFloat = 16
    private static let gap: CGFloat = 8

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        // The same monospaced digits every other row's second line uses, so the
        // minute counting down does not shuffle the names after it.
        subtitle.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        icon.contentTintColor = .secondaryLabelColor

        for v in [title, subtitle, icon, faces] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        let block = NSLayoutGuide()
        addLayoutGuide(block)
        let centred = block.centerYAnchor.constraint(equalTo: centerYAnchor)
        centred.priority = .defaultHigh

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor,
                                          constant: RecordingCell.textInset),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            icon.centerYAnchor.constraint(equalTo: block.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor,
                                           constant: Self.gap),
            // The faces take the trailing end and the words give way to them,
            // which is the arrangement `RecordingCell` already uses for its
            // match count.
            title.trailingAnchor.constraint(equalTo: faces.leadingAnchor,
                                            constant: -Self.gap),
            faces.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -RecordingCell.textInset),
            faces.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            block.topAnchor.constraint(equalTo: title.topAnchor),
            block.bottomAnchor.constraint(equalTo: subtitle.bottomAnchor),
            centred,
            block.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            block.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ event: CalendarEvent) {
        title.stringValue = event.title
        // A camera when there is something to join and a calendar page when
        // there is not, which is the one fact about the row worth knowing
        // without reading it: whether this meeting is a link or a room.
        let joinable = event.link != nil
        icon.image = NSImage(systemSymbolName: joinable ? "video.fill" : "calendar",
                             accessibilityDescription: joinable ? "Video call" : "Meeting")
        icon.toolTip = joinable ? "There is a link to join this one" : nil
        // **Faces rather than a comma list of names.** "in 12 min · Ryan
        // Mitchell, Emily Chen" truncates at the second name in a 280 point
        // sidebar, so the row spent its whole second line saying half of
        // something. A disc is recognised without being read, and it is the
        // same disc and the same colour these people have on every other
        // screen, so a row is scannable at the speed a calendar is.
        //
        // Nothing is lost: the names are in the tool tip and on the page.
        faces.show(event.guestNames)
        subtitle.stringValue = EventTime.relative(event.start)
        toolTip = ([event.title, EventTime.span(event), event.calendar]
            + (event.guestNames.isEmpty ? [] : [event.guestNames.joined(separator: ", ")]))
            .joined(separator: "\n")
        // The row is a `HoverRow`-less table cell, so the only thing that can
        // speak for the faces is the cell itself: `texts` reads this, and a
        // reader who cannot see a coloured circle gets the names.
        setAccessibilityLabel([event.title, subtitle.stringValue,
                               event.guestNames.joined(separator: ", ")]
            .filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

// ---------------------------------------------------------------------------

/// The page an upcoming meeting opens: the invitation, who is coming, and what
/// this library already holds about them.
///
/// **It is not a recording page and does not pretend to be one.** There is no
/// transcript, no player and no title to edit, because none of those things
/// exists yet. What it has instead is the two things that are only useful
/// beforehand: the link, and the history with the people who are about to be on
/// the call.
@MainActor
final class UpcomingPane: NSViewController {
    private var event: CalendarEvent?
    var currentEvent: CalendarEvent? { event }

    private let titleLabel = NSTextField(labelWithString: "")
    private let whenLabel = NSTextField(labelWithString: "")
    private let joinButton = NSButton(title: "Join", target: nil, action: nil)
    private let prepareButton = NSButton(title: "Prepare", target: nil, action: nil)
    private let empty = NSTextField(labelWithString: "Nothing coming up.")

    private var scroll: NSScrollView!
    private var content: NSStackView!
    private var head: NSStackView!

    /// Ask the window's composer something about this meeting.
    var onAsk: ((String) -> Void)?
    /// Open a recording from the history list.
    var onOpenRecording: ((String) -> Void)?
    /// Open somebody's card from the guest list.
    var onOpenPerson: ((Person) -> Void)?

    private static let maxWidth: CGFloat = 620

    override func loadView() {
        let container = NSView()

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        whenLabel.font = .systemFont(ofSize: 12)
        whenLabel.textColor = .secondaryLabelColor
        whenLabel.lineBreakMode = .byTruncatingTail
        // The header must never decide how wide the page is: a long invitation
        // title held the content stack open past the pane and cut the button
        // beside it in half, which `PersonPane` records against its own summary.
        for label in [titleLabel, whenLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        joinButton.bezelStyle = .rounded
        joinButton.controlSize = .large
        joinButton.target = self
        joinButton.action = #selector(join)
        joinButton.toolTip = "Open the meeting link"

        prepareButton.bezelStyle = .rounded
        prepareButton.controlSize = .large
        prepareButton.target = self
        // `askPrepare`, because `NSViewController` already has a `prepare`
        // (`prepare(for:sender:)`) and a selector naming this one is ambiguous.
        prepareButton.action = #selector(askPrepare)
        prepareButton.toolTip = "Ask what you should know before this meeting"

        head = NSStackView()
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 6
        head.edgeInsets = NSEdgeInsets(top: 14, left: 24, bottom: 0, right: 24)
        head.translatesAutoresizingMaskIntoConstraints = false

        content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.edgeInsets = NSEdgeInsets(top: 18, left: 24, bottom: 28, right: 24)
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

    /// The header sits level with the toolbar buttons, and moves below them at
    /// the width where AppKit collapses the sidebar. `PersonPane` does the same
    /// thing for the same reason.
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let window = view.window, let windowContent = window.contentView else { return }
        let atWindowEdge = view.convert(.zero, to: windowContent).x < 1
        let toolbarHeight = max(0, windowContent.bounds.height - window.contentLayoutRect.maxY)
        let top: CGFloat = atWindowEdge ? toolbarHeight + 14 : 14
        if head.edgeInsets.top != top { head.edgeInsets.top = top }
    }

    func show(_ event: CalendarEvent?) {
        loadViewIfNeeded()
        self.event = event
        render()
    }

    // MARK: - Drawing

    private func render() {
        // Room for the composer, which belongs to the window and floats over
        // the foot of whatever this pane is showing.
        content.edgeInsets.bottom = Settings.askEnabled ? 116 : 28
        for sub in head.arrangedSubviews { sub.removeFromSuperview() }
        for sub in content.arrangedSubviews { sub.removeFromSuperview() }
        guard let event else {
            head.isHidden = true
            scroll.isHidden = true
            empty.isHidden = false
            return
        }
        head.isHidden = false
        scroll.isHidden = false
        empty.isHidden = true

        titleLabel.stringValue = event.title
        whenLabel.stringValue = [EventTime.span(event), event.calendar]
            .filter { !$0.isEmpty }.joined(separator: " · ")

        let titles = NSStackView(views: [titleLabel, whenLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        titles.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var buttons: [NSView] = []
        if event.link != nil { buttons.append(joinButton) }
        // **Prepare is a button and not only a chip.** The composer's starter
        // chips are drawn once somebody clicks into the field, which is right
        // on a page you are reading and wrong on a page whose entire reason to
        // exist is the question: see `AskView.drawStarters`. It sends the same
        // prompt the first chip would.
        //
        // **And it is not conditional on an agent, unlike those chips.** They
        // are hidden without one because four buttons that silently do nothing
        // teach that the pane is broken; this one is not silent, because
        // `AskView.ask(question:)` fails at the same guard that raises the
        // setup card. Detection also finishes after this page can first be
        // opened, and nothing here would redraw when it did, so a button that
        // asked would come and go for reasons the reader cannot see.
        // Not on a block, for `MeetingBrief`'s reason: every question it
        // sends is about the people invited, and there are none. A button that
        // asks "what should I know about nobody" is worse than no button.
        if Settings.askEnabled, event.hasGuests { buttons.append(prepareButton) }
        let header = NSStackView(views: [titles] + buttons)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        add(header, to: head, width: true, spacingAfter: 18)
        add(rule(), to: head, width: true, spacingAfter: 0)

        // Read once, for both halves. The guest list asks whether the library
        // knows each person and the history asks what it holds about them,
        // which is the same roster over the same library: two calls here is two
        // full reads of the library on every click down the section.
        let library = Recording.all()
        let roster = People.roster(in: library)
        // **A block has no guest list, so it gets no heading over an empty
        // one.** Nobody else is invited, which is the whole of what "blocked"
        // means, and an "Invited" section with nothing under it reads as a
        // guest list that failed to load. The same goes for the history: what
        // this library holds about the people coming is not a question when
        // nobody is coming.
        if event.hasGuests {
            renderGuests(event, roster: roster)
        } else {
            add(section("What this is"), spacingAfter: 8)
            let line = NSTextField(labelWithString:
                "An hour you blocked out. Nobody else is invited, so there is "
                + "nothing to join and nobody to prepare about.")
            line.font = .systemFont(ofSize: 13)
            line.textColor = .secondaryLabelColor
            line.maximumNumberOfLines = 3
            add(line, width: true, spacingAfter: 20)
        }
        if let agenda = MeetingBrief.trimmedAgenda(event) { renderAgenda(agenda) }
        if event.hasGuests { renderHistory(event, roster: roster) }
    }

    private func renderGuests(_ event: CalendarEvent, roster: [Person]) {
        add(section("Invited"), spacingAfter: 8)
        for guest in event.guests {
            let name = guest.bestName ?? guest.email ?? "Somebody unnamed"
            let known = roster.first { $0.label.caseInsensitiveCompare(name) == .orderedSame }
            let person = known ?? Person(label: name, recordings: [], seconds: 0)

            let disc = InitialsDisc(size: 26)
            disc.show(person)
            let label = NSTextField(labelWithString: person.display)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // What the library knows, which is the fact worth having here:
            // somebody with no recordings is somebody to read about beforehand.
            //
            // `Person.summary` either way, so a stranger is marked in the same
            // words the roster uses ("no recordings yet") rather than in a
            // second phrase invented here. Their address goes beside it,
            // because for somebody the library has never heard it is the only
            // identifying thing on the row.
            let detail = NSTextField(labelWithString:
                [person.summary, known == nil ? guest.email : nil]
                    .compactMap { $0 }.joined(separator: " · "))
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .tertiaryLabelColor
            detail.setContentHuggingPriority(.required, for: .horizontal)

            let line = NSStackView(views: [disc, label, detail])
            line.orientation = .horizontal
            line.alignment = .centerY
            line.spacing = 8
            guard let known else {
                // Nothing to open, so nothing that lights up under the pointer.
                add(line, width: true)
                continue
            }
            let row = HoverRow(content: line, target: self,
                               action: #selector(openPerson(_:)), height: 34)
            row.identifier = NSUserInterfaceItemIdentifier(known.label)
            row.toolTip = "Open \(known.display)"
            add(row, width: true)
        }
        content.setCustomSpacing(20, after: content.arrangedSubviews.last!)
    }

    private func renderAgenda(_ agenda: String) {
        add(section("From the invitation"), spacingAfter: 8)
        let label = NSTextField(wrappingLabelWithString: agenda)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        add(label, width: true, spacingAfter: 20)
    }

    /// What this library already holds about the people who are about to be on
    /// the call.
    ///
    /// The whole argument for the page. A guest list is on the invitation
    /// already, in whatever calendar it came from; the meetings behind those
    /// names are the thing only this app has.
    private func renderHistory(_ event: CalendarEvent, roster: [Person]) {
        let names = Set(event.guestNames.map { $0.lowercased() })
        var seen = Set<String>()
        var found: [Recording] = []
        for person in roster where names.contains(person.label.lowercased()) {
            for recording in person.recordings where seen.insert(recording.id).inserted {
                found.append(recording)
            }
        }
        found.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        add(section("Before this"), spacingAfter: 8)
        guard !found.isEmpty else {
            let none = NSTextField(labelWithString:
                "No recordings with them yet. This is the first one.")
            none.font = .systemFont(ofSize: 13)
            none.textColor = .tertiaryLabelColor
            add(none)
            return
        }
        for recording in found.prefix(6) {
            let title = NSTextField(labelWithString: recording.displayTitle)
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            title.textColor = recording.isUntitled ? .secondaryLabelColor : .labelColor
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let detail = NSTextField(labelWithString: recording.when)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .tertiaryLabelColor
            detail.setContentHuggingPriority(.required, for: .horizontal)

            let line = NSStackView(views: [title, detail])
            line.orientation = .horizontal
            line.spacing = 8
            let row = HoverRow(content: line, target: self,
                               action: #selector(openRecording(_:)))
            row.identifier = NSUserInterfaceItemIdentifier(recording.id)
            row.toolTip = "Open this recording"
            add(row, width: true)
        }
    }

    // MARK: - Actions

    @objc private func join() {
        guard let link = event?.link else { return }
        NSWorkspace.shared.open(link)
    }

    @objc private func askPrepare() {
        guard let event, let prompt = MeetingBrief.starters(for: event).first?.1 else { return }
        onAsk?(prompt)
    }

    @objc private func openRecording(_ sender: NSView) {
        guard let id = sender.identifier?.rawValue else { return }
        onOpenRecording?(id)
    }

    @objc private func openPerson(_ sender: NSView) {
        guard let label = sender.identifier?.rawValue,
              let person = People.roster(in: Recording.all())
                  .first(where: { $0.label == label }) else { return }
        onOpenPerson?(person)
    }

    // MARK: - Building blocks

    private func add(_ view: NSView, to stack: NSStackView? = nil, width: Bool = false,
                     spacingAfter: CGFloat? = nil) {
        let stack = stack ?? content!
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

    private func rule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
