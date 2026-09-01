import AppKit

/// The conversation list, which is the sidebar while a conversation is a page.
///
/// **A list, not a menu.** History was a pull-down in the title bar for as long
/// as a conversation was a card resting over a meeting: the recordings were in
/// the sidebar, the conversation was in front of them, and a menu was the only
/// strip of chrome left to put them in. A page has no meeting behind it and no
/// recording list worth keeping on screen, so the conversations take the sidebar
/// the way the settings sections take it, and the menu that stood in for this
/// list is gone from that screen with it.
///
/// Rendered like the recordings list on purpose, down to `heading(for:)` being
/// the same function: both are things you made, filed under the day you made
/// them, and a second visual language for the second one would say they are
/// different kinds of object. They are not.
@MainActor
final class ChatNav: NSViewController {
    /// Headings and conversations in one list, which is what the table draws.
    /// `isGroupRow` picks the headings apart, exactly as the recordings list
    /// does.
    private enum Row {
        case header(String)
        case chat(Chat)
    }

    private var table: NSTableView!
    private var searchField: NSSearchField!
    private var rows: [Row] = []
    private var query = ""
    /// Meeting titles by id, resolved once per reload rather than per row.
    ///
    /// A row says what its conversation is about, and the answer lives in the
    /// recording's own metadata. Asked per row that is one `Recording.find` per
    /// conversation on every keystroke in the search field; asked here it is one
    /// listing for the whole list.
    private var titles: [String: String] = [:]

    var onSelect: ((Chat) -> Void)?

    /// The conversation the page is showing, so a reload puts the highlight
    /// back on it. An id rather than a `Chat`, because the file on disk moves
    /// under this list every time a question is answered.
    private(set) var selected: String?

    private var hover: TableHover!
    /// Set while `reload` is putting the selection back, so the table's
    /// notification is not mistaken for somebody picking a conversation. The
    /// same guard, for the same reason, as `SidebarViewController.reloading`.
    private var reloading = false

    override func loadView() {
        let container = NSView()

        searchField = NSSearchField()
        searchField.placeholderString = "Search conversations"
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
        // **And it goes when there is nothing to scroll.** A Mac set to show
        // scroll bars always draws the track whether or not the list overflows,
        // and a history of nine conversations does not: a full-height bar down
        // the edge of a list that fits is chrome about a state the list is not
        // in. The recordings list is left alone deliberately, because it does
        // overflow, and its bar has a thumb in it that means something.
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            // **42, which is where the recordings list's search field is.**
            //
            // No collection picker above it, unlike People and Notes: the
            // conversations are not a fourth collection of the library. They are
            // the working-out, they are reached from the screen you were asking
            // on, and the way back is the toolbar's Back rather than a segment.
            // The recordings list has no picker either, for its own reason, and
            // 42 is the number it states: enough to clear a transparent
            // full-size title bar and nothing more.
            //
            // It was 76 first, which is what `CollectionPicker` spends (42, its
            // own 24, and 10 under it) and therefore where the *other two*
            // lists' fields sit. Matching those put this one a control's height
            // lower than the list it swaps with, which is visible as a jump the
            // moment you press Back. Before that it was 8, which drew the field
            // behind the traffic lights, the word "Chats" and the Back button.
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 42),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                  constant: -10),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hover = TableHover(table, name: "chats")
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

    /// Re-read the conversations and redraw, keeping the highlight where it was.
    ///
    /// Called on the way into the mode and again whenever a conversation is
    /// written to: a question answered changes the row's title on the first
    /// exchange and its day heading on the next one, and a list that only
    /// refreshed on entry would name the conversation on screen by a question
    /// asked ten minutes ago.
    func reload() {
        loadViewIfNeeded()
        let wanted = query.trimmingCharacters(in: .whitespaces)
        let chats = Chat.all().filter { Self.matches($0, query: wanted) }

        titles = [:]
        // Only when something is going to ask, which is the ordinary case of an
        // empty history not paying for a listing of the library.
        if !chats.isEmpty {
            for recording in Recording.all() { titles[recording.id] = recording.displayTitle }
        }

        rows = []
        var lastGroup: String?
        for chat in chats {
            let group = SidebarViewController.heading(for: Self.date(of: chat))
            if group != lastGroup {
                rows.append(.header(group))
                lastGroup = group
            }
            rows.append(.chat(chat))
        }

        reloading = true
        table.reloadData()
        if let selected, let row = self.row(for: selected) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            // Deliberately silent. A conversation that has been deleted, or
            // filtered out by a search, leaves nothing selected here and the
            // page keeps whatever it is showing: the list is how you change
            // pages, and a reload is not somebody changing one.
            table.deselectAll(nil)
        }
        reloading = false
    }

    /// Highlight one without calling back, for arriving from somewhere else.
    ///
    /// The caller is the one that opened it, so telling it what it just did
    /// would open the conversation twice.
    @discardableResult
    func select(_ id: String) -> Bool {
        loadViewIfNeeded()
        selected = id
        if rows.isEmpty { reload() }
        guard let row = row(for: id) else { return false }
        reloading = true
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        reloading = false
        return true
    }

    /// Nothing is open: the page is a fresh composer, so no row is its.
    func clearSelection() {
        loadViewIfNeeded()
        selected = nil
        reloading = true
        table.deselectAll(nil)
        reloading = false
    }

    func focusSearch() { view.window?.makeFirstResponder(searchField) }

    /// Narrow the list to a query typed somewhere else.
    ///
    /// The library's own field hands its word over here when somebody clicks
    /// the row saying how many conversations mention it. Sets the field as well
    /// as the state, because a list narrowed by a term the reader cannot see is
    /// a history with conversations missing from it.
    func search(_ text: String) {
        loadViewIfNeeded()
        searchField.stringValue = text
        query = text
        reload()
    }

    /// How many conversations a word appears in.
    ///
    /// The library's list asks, so it can offer the way over. Here rather than
    /// in the sidebar, because this is where the predicate lives and two
    /// readings of "mentions" that could disagree is the thing `RecordingFilter`
    /// exists to prevent.
    static func mentions(_ query: String) -> Int {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return 0 }
        return Chat.all().filter { matches($0, query: wanted) }.count
    }

    @objc private func searchChanged() {
        query = searchField.stringValue
        reload()
    }

    /// Title, then anything anybody said. A question you remember asking is the
    /// usual way back in, and it is the title only if it was the first one.
    private static func matches(_ chat: Chat, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if chat.displayTitle.localizedCaseInsensitiveContains(query) { return true }
        return chat.turns.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }

    /// When the conversation was last touched, which is what it is filed under.
    ///
    /// `updated` rather than `created`, for the reason `Chat.all` sorts by it: a
    /// conversation is picked up where it was left, so the day that matters is
    /// the day it was last being had.
    private static func date(of chat: Chat) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let stamp = chat.updated ?? chat.created else { return nil }
        return parser.date(from: stamp)
    }

    private func row(for id: String) -> Int? {
        rows.firstIndex {
            if case .chat(let chat) = $0 { return chat.id == id }
            return false
        }
    }

    private func chat(at row: Int) -> Chat? {
        guard rows.indices.contains(row), case .chat(let chat) = rows[row] else { return nil }
        return chat
    }

    /// What a row says under its title: when, how much of it there is, and what
    /// it was about.
    private func subtitle(for chat: Chat) -> String {
        var facts: [String] = []
        if let date = Self.date(of: chat) {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            facts.append(f.string(from: date))
        }
        // Questions rather than turns. A conversation of four questions and four
        // answers is four things you asked, and "8 messages" counts the half you
        // did not write.
        let asked = chat.turns.filter { $0.who == Chat.you }.count
        if asked > 0 { facts.append("\(asked) question" + (asked == 1 ? "" : "s")) }
        // What it is about, which is the field that tells two conversations with
        // similar opening questions apart. A person first, because a question
        // asked from somebody's card is about them rather than about whichever
        // of their meetings the answer happened to read.
        if let person = chat.person, !person.isEmpty {
            facts.append(person)
        } else if chat.sources.count > 1 {
            facts.append("\(chat.sources.count) recordings")
        } else if let id = chat.sources.first {
            facts.append(titles[id] ?? "1 recording")
        }
        return facts.joined(separator: " · ")
    }
}

extension ChatNav: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if case .header = rows[row] { return nil }
        return HoverRowView()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 30 }
        return 52
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            let holder = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(label)
            NSLayoutConstraint.activate([
                // The same inset the recordings list uses, so the two lists have
                // one column edge between them and switching modes does not
                // shift the text sideways.
                label.leadingAnchor.constraint(equalTo: holder.leadingAnchor,
                                               constant: RecordingCell.textInset),
                label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -4),
            ])
            return holder

        case .chat(let chat):
            let cell = ChatCell()
            cell.configure(chat, about: subtitle(for: chat))
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading else { return }
        guard let chat = chat(at: table.selectedRow) else { return }
        selected = chat.id
        onSelect?(chat)
    }
}

/// One row: what was asked, and enough about it to tell it from the next one.
@MainActor
final class ChatCell: NSView {
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

    func configure(_ chat: Chat, about: String) {
        title.stringValue = chat.displayTitle
        detail.stringValue = about
        detail.isHidden = about.isEmpty
    }
}
