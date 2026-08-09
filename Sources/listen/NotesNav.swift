import AppKit

/// The made-up URL scheme a note's source links carry.
///
/// Made up rather than real, and read back by the delegate that owns the text
/// view, so an id in a note's provenance can never reach `NSWorkspace`: a note
/// naming its sources must not be a way to launch something.
enum RecordingLink {
    static let scheme = "listen-recording:"

    static func id(_ link: Any) -> String? {
        guard let url = link as? String, url.hasPrefix(scheme) else { return nil }
        return String(url.dropFirst(scheme.count))
    }
}

/// And for a note, for the same reason as `ChatLink`.
enum NoteLink {
    static let scheme = "listen-note:"

    static func id(_ link: Any) -> String? {
        guard let url = link as? String, url.hasPrefix(scheme) else { return nil }
        return String(url.dropFirst(scheme.count))
    }
}

/// And for somebody in the roster, which only an answer's references link to.
///
/// The name as it is shown, not the on-disk label: it is written by an agent
/// that was handed display names, and `People.findByDisplayName` is the one
/// lookup that accepts both.
enum PersonLink {
    static let scheme = "listen-person:"

    static func id(_ link: Any) -> String? {
        guard let url = link as? String, url.hasPrefix(scheme) else { return nil }
        return String(url.dropFirst(scheme.count))
    }
}

/// The same trick for a conversation, and separate rather than a parameter on
/// the one above, because the two are read by different delegates and a link
/// that resolves to the wrong kind of thing is the failure worth designing out.
enum ChatLink {
    static let scheme = "listen-chat:"

    static func id(_ link: Any) -> String? {
        guard let url = link as? String, url.hasPrefix(scheme) else { return nil }
        return String(url.dropFirst(scheme.count))
    }
}

/// Which part of the library the window is showing.
///
/// Three peers, and settings is deliberately not a fourth. These are *what you
/// are looking at*; settings is configuring the app, and one control meaning
/// both is one control too many. Settings keeps the gear at the bottom left.
enum LibraryCollection: Int, CaseIterable {
    case recordings, people, notes

    var label: String {
        switch self {
        case .recordings: return "Recordings"
        case .people:     return "People"
        case .notes:      return "Notes"
        }
    }

    /// The placeholder changes with the segment, because search scopes to it.
    /// A search field that says "Search" in a list of people and then returns
    /// people is a surprise; one that says "Search people" is an expectation.
    var searchPlaceholder: String {
        switch self {
        case .recordings: return "Search recordings"
        case .people:     return "Search people"
        case .notes:      return "Search notes"
        }
    }
}

/// The three-way switch at the top of the sidebar.
///
/// **Above the search field, not below**, because the search scopes to whatever
/// is selected and the scope selector comes first.
///
/// It lives in the sidebar rather than the toolbar, and that is a claim about
/// what a toolbar is for: verbs on the selected recording. Export this,
/// transcribe this again, delete this. People was never a verb on a recording,
/// it is a peer collection of the whole library, and once a note can name four
/// recordings so are notes. A note referencing four meetings has no home in a
/// recording-centric sidebar at all, so without this the app can create
/// something it cannot show.
///
/// One of these is built by each of the three lists rather than shared by a
/// container above them, because the sidebar swaps its whole view controller
/// through `PaneHost`. Same builder, same constraints, same position, so the
/// control does not appear to move when the list underneath it changes.
@MainActor
final class CollectionPicker: NSSegmentedControl {
    var onSelect: ((LibraryCollection) -> Void)?

    convenience init(showing current: LibraryCollection) {
        self.init(labels: LibraryCollection.allCases.map(\.label),
                  trackingMode: .selectOne, target: nil, action: nil)
        segmentDistribution = .fillEqually
        selectedSegment = current.rawValue
        // The selected segment is the other place the system's blue shows.
        // Nil while the choice is `system`, so AppKit keeps drawing it itself.
        selectedSegmentBezelColor = Brand.tint
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }

    /// Pin one to the top of a sidebar list, with the search field under it.
    ///
    /// Returns the constraint list rather than activating it, so each caller
    /// keeps one `NSLayoutConstraint.activate` block the way the rest of this
    /// app does.
    func constraints(in container: NSView, above field: NSView) -> [NSLayoutConstraint] {
        [
            // Clear of the traffic lights, which sit over the content because
            // the window uses a transparent full-size title bar.
            topAnchor.constraint(equalTo: container.topAnchor, constant: 42),
            leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            heightAnchor.constraint(equalToConstant: 24),
            field.topAnchor.constraint(equalTo: bottomAnchor, constant: 10),
        ]
    }

    @objc private func fire() {
        guard let picked = LibraryCollection(rawValue: selectedSegment) else { return }
        onSelect?(picked)
    }
}

// The Settings row that used to be pinned to the bottom of all three sidebars,
// with its hairline above it, is gone: the gear in the title bar is the one
// visible way in, beside the collapse control and over the sidebar it belongs
// to. The row existed because that was the only place to put a gear when the
// toolbar's sidebar region held nothing but the masthead. Two of them is one
// too many, and the one that cost a list 56 points of height at the bottom of
// every collection is the one to lose.

// ---------------------------------------------------------------------------

/// Every note in the library, newest first.
///
/// The view that makes cross-recording notes reachable at all. A note about
/// four meetings appears under each of them in the detail pane, which is right
/// for reading one meeting and useless for finding it: this is the list where a
/// synthesis is a first-class thing rather than an attachment, and where the
/// user's own notes read as a body of thinking rather than as 36 scattered
/// files.
@MainActor
final class NotesNav: NSViewController {
    private var table: NSTableView!
    private var searchField: NSSearchField!
    private var picker: CollectionPicker!
    private var notes: [Note] = []
    private var query = ""

    var onSelect: ((Note?) -> Void)?
    var onCollection: ((LibraryCollection) -> Void)?

    private(set) var selected: Note?
    private var hover: TableHover!

    override func loadView() {
        let container = NSView()

        picker = CollectionPicker(showing: .notes)
        picker.onSelect = { [weak self] in self?.onCollection?($0) }

        searchField = NSSearchField()
        searchField.placeholderString = LibraryCollection.notes.searchPlaceholder
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 52
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
        hover = TableHover(table, name: "notes")
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
        let keep = selected?.slug
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        notes = Notes.all().filter { note in
            guard !q.isEmpty else { return true }
            if note.title.lowercased().contains(q) { return true }
            if note.body.lowercased().contains(q) { return true }
            // The meetings it names, by their titles. "Everything about Edgar"
            // is a question about the recordings a note points at, not about
            // its own text, and searching only the body would not answer it.
            return Notes.sources(of: note)
                .contains { ($0.title ?? $0.id).lowercased().contains(q) }
        }
        table.reloadData()

        if let keep, let row = notes.firstIndex(where: { $0.slug == keep }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            selected = notes[row]
        } else if selected != nil {
            selected = nil
            onSelect?(nil)
        }
    }

    /// Select a note by slug, for arriving from somewhere else.
    @discardableResult
    func select(_ slug: String) -> Bool {
        loadViewIfNeeded()
        if notes.isEmpty { reload() }
        guard let row = notes.firstIndex(where: { $0.slug == slug }) else { return false }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        selected = notes[row]
        onSelect?(notes[row])
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

extension NotesNav: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HoverRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        let cell = NoteCell()
        cell.configure(notes[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard table.selectedRow >= 0, table.selectedRow < notes.count else { return }
        selected = notes[table.selectedRow]
        onSelect?(notes[table.selectedRow])
    }
}

/// One row: what the note is, who wrote it, and what it is about.
@MainActor
final class NoteCell: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ note: Note) {
        let sources = Notes.sources(of: note)
        // Every one of the user's own notes is titled "Your notes", so a list of
        // them is a column of identical rows distinguished only by a truncated
        // second line. The meeting is what tells them apart, so for those the
        // row leads with it and "Your notes" moves down to where the kind is
        // stated. An agent's note is the other way round: its title is the one
        // thing that is its own.
        title.stringValue = Notes.isYours(note)
            ? (sources.first?.title ?? note.title)
            : note.title
        var facts: [String] = [Notes.isYours(note) ? "Your notes" : "Agent"]
        // The meeting's own name when there is one, a count when there are
        // several. "4 recordings" is what makes a synthesis findable in this
        // list; a single note's own meeting is what makes the rest legible.
        if !Notes.isYours(note), sources.count == 1 {
            facts.append(sources[0].title ?? "recording deleted")
        } else if sources.count > 1 {
            facts.append("\(sources.count) recordings")
        }
        if let date = Timestamps.parse(note.updated) {
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .none
            facts.append(f.string(from: date))
        }
        detail.stringValue = facts.joined(separator: " · ")
    }
}

// ---------------------------------------------------------------------------

/// One note, read on its own rather than beside a recording.
///
/// Read-only, including the user's own, and that is deliberate rather than
/// unfinished. Their note is edited on the recording it belongs to, where the
/// audio and the transcript are, and having two editors for one file would be
/// two writers of the thing this app is most careful about. The sources are
/// buttons, so the way to edit it is one click and the click also takes you to
/// the meeting it is about.
@MainActor
final class NotePane: NSViewController {
    private let heading = NSTextField(labelWithString: "")
    private let info = NSTextField(labelWithString: "")
    /// The meetings a note is about, as a line of links.
    ///
    /// A text view and not a row of buttons. Buttons with a trailing chevron
    /// each read as one step of a path, so four of them are a breadcrumb trail
    /// claiming a hierarchy that does not exist: these are four peers. A
    /// sentence with commas in it is a list, which is what they are, and it
    /// wraps, underlines on hover and turns the pointer into a hand for free.
    private let sources = LinkLine()
    private let text = NSTextView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "Select a note.")

    private var note: Note?

    /// Where a source button goes: the recording, and the note being read, so
    /// the pane it lands on opens on the same note rather than on a transcript
    /// nobody asked for.
    var onOpenRecording: ((String, String) -> Void)?

    override func loadView() {
        let container = NSView()

        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        info.maximumNumberOfLines = 0
        info.cell?.wraps = true
        sources.isEditable = false
        sources.isSelectable = true
        sources.drawsBackground = false
        sources.delegate = self
        sources.textContainerInset = .zero
        sources.textContainer?.lineFragmentPadding = 0
        sources.textContainer?.widthTracksTextView = true
        sources.isVerticallyResizable = true
        sources.isHorizontallyResizable = false
        sources.setContentHuggingPriority(.required, for: .vertical)
        sources.setContentCompressionResistancePriority(.required, for: .vertical)
        sources.linkTextAttributes = [
            .foregroundColor: Brand.accent,
            .cursor: NSCursor.pointingHand,
        ]

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 0, height: 12)
        // See `DetailView.buildNotesPane`: the default padding puts the body
        // five points right of everything above it.
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0,
                                                   height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor

        for v in [heading, info, sources, scroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 38),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                              constant: -24),
            info.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            info.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            sources.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 6),
            sources.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            sources.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sources.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                             constant: -24),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        show(nil)
    }

    func show(_ note: Note?) {
        loadViewIfNeeded()
        self.note = note
        let hidden = note == nil
        for v in [heading, info, sources, scroll] as [NSView] {
            v.isHidden = hidden
        }
        empty.isHidden = !hidden
        guard let note else { return }

        heading.stringValue = note.title
        let when = Timestamps.parse(note.updated).map { date -> String in
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: date)
        }
        // One line. It carried three before: who wrote it, when, and a sentence
        // explaining that your own note is edited on the recording, on every
        // note, for ever. That sentence is a thing you need once, so it is the
        // text view's tooltip, and what is left fits where the sidebar row's
        // second line already puts the same two facts.
        var facts = [Notes.isYours(note) ? "Yours" : "Written by an agent"]
        if let when { facts.append(Notes.isYours(note) ? "edited \(when)" : when) }
        var line = facts.joined(separator: " · ")
        if let prompt = note.prompt, !prompt.isEmpty { line += "\nAsked for: \(prompt)" }
        info.stringValue = line
        text.toolTip = Notes.isYours(note)
            ? "Your notes are written on the recording itself. An agent can read "
                + "this and cannot change it."
            : nil

        let list = NSMutableAttributedString()
        for source in Notes.sources(of: note) {
            if list.length > 0 {
                list.append(NSAttributedString(string: ", ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
            ]
            if let title = source.title {
                // A made-up scheme rather than a real URL. The delegate below
                // reads the id back out and never lets it reach `NSWorkspace`,
                // which is what stops a note's own provenance being a way to
                // launch something.
                attributes[.link] = RecordingLink.scheme + source.id
                list.append(NSAttributedString(string: title, attributes: attributes))
            } else {
                // An id with no recording behind it is shown and not a link, and
                // says why. Silently dropping it would make the note claim it
                // was never about that meeting.
                attributes[.foregroundColor] = NSColor.tertiaryLabelColor
                list.append(NSAttributedString(
                    string: source.id + " (no longer in the library)",
                    attributes: attributes))
            }
        }
        sources.textStorage?.setAttributedString(list)
        sources.invalidateIntrinsicContentSize()

        // The body without the heading the title already is. An agent writes
        // `# Decisions` at the top of a note called "Decisions", which is right
        // in the file and reads as a mistake on a page whose own title is two
        // lines above it.
        text.textStorage?.setAttributedString(
            MarkdownText.attributed(note.body, without: note.title))
        text.scroll(NSPoint(x: 0, y: 0))
    }
}

extension NotePane: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any,
                  at charIndex: Int) -> Bool {
        guard let id = RecordingLink.id(link), let note else { return false }
        onOpenRecording?(id, note.slug)
        return true
    }
}


/// A text view that is as tall as its text.
///
/// An `NSTextView` reports no intrinsic size, which is fine inside a scroll
/// view where its frame is managed for it and wrong everywhere else: pinned
/// into a stack of constraints with nothing saying how tall it is, it took the
/// whole pane and pushed the note's body off the bottom of the window. The
/// symptom is a note that renders its header and nothing else, which reads as
/// an empty note.
@MainActor
final class LinkLine: NSTextView {
    /// Replace the text, and say so.
    ///
    /// `textStorage` is written to directly rather than through `string`,
    /// because the attributes are the point here, and a programmatic write does
    /// not call `didChangeText`: without the invalidation the view keeps the
    /// height it was last measured at, which for an answer being streamed into
    /// is the height of its first sentence.
    func set(_ text: NSAttributedString) {
        textStorage?.setAttributedString(text)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else {
            return super.intrinsicContentSize
        }
        // The container tracks the view's width, which the constraints set, so
        // laying out first is what makes this the height *after* wrapping
        // rather than the height of one very long line.
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: used.height + textContainerInset.height * 2)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A width change re-wraps, and re-wrapping changes the height. Without
        // this the line is measured once at the width it happened to be built
        // at and never again, so narrowing the window clips it.
        invalidateIntrinsicContentSize()
    }
}
