import AppKit

/// The conversations about one recording, on a tab of the page they are about.
///
/// **A tab, not a line of links.** This replaced the conversation half of the
/// "Also about this" row, which named every conversation in a run of small
/// accent-coloured text under the tab bar and read as a sentence rather than as
/// a list: two questions asked about a meeting wrapped it onto a second line,
/// five made it a paragraph, and none of them said when they were asked or how
/// long they were. The notes half of that row stays where it is, because an
/// agent's note about this meeting is a document the Notes tab already holds.
///
/// Rendered with `ChatCell`, which is the conversation list's own row, for the
/// reason `ChatNav` gives about the recordings list: these are the same objects
/// in a narrower scope, and a second visual language for them would say they
/// were a different kind of thing.
///
/// It is a `NSView` and not a view controller because it lives inside
/// `DetailView`'s pane alongside the transcript and the note, which are views
/// too, and the pane switches between them by hiding rather than by swapping a
/// child controller.
@MainActor
final class ChatList: NSView {
    /// Pressed a conversation. The pane opens it over the page, which is what
    /// `DetailView.openChat` already does for the note's back links.
    var onOpen: ((Chat) -> Void)?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    /// What the tab says when nobody has asked anything yet.
    ///
    /// **A sentence pointing at the composer, not an apology.** The card is at
    /// the foot of this very window, so the empty state of this tab is one
    /// gesture from being filled and the only useful thing it can say is which
    /// gesture. Compare `appendSourceHistory`, which puts a disabled row with
    /// the same shape of sentence in the menu: a control that opens onto
    /// nothing reads as broken.
    private let empty = NSTextField(labelWithString:
        "Nothing asked about this meeting yet. Ask a question below and it will be listed here.")

    private var chats: [Chat] = []
    /// Rows do not light up under the pointer by themselves: `HoverRowView`
    /// draws the highlight and something has to tell it where the pointer is.
    /// See `TableHover`, and the note under `hoverTint` for why three fixes to
    /// the tracking went in before anybody looked at the colour.
    private var hover: TableHover!

    override init(frame: NSRect) {
        super.init(frame: frame)

        table.headerView = nil
        table.rowHeight = 52
        table.style = .inset
        table.backgroundColor = .clear
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.delegate = self
        table.dataSource = self

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        // No track down the edge of a list of three. The conversation list next
        // door states the same rule, and this one overflows even less often.
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.lineBreakMode = .byWordWrapping
        empty.maximumNumberOfLines = 0
        empty.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scroll)
        addSubview(empty)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Where the first row's text would have been, so the tab does not
            // move sideways when the first question is asked. 22 is the table's
            // own 14 plus `RecordingCell.textInset`, which is the number the
            // sidebar states rather than one measured again here.
            empty.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            empty.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: 14 + RecordingCell.textInset),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -22),
        ])

        hover = TableHover(table, name: "chatlist")
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// **The monitor runs exactly while the list is on screen.** It is a local
    /// event monitor that asks the table which row a point is over, and the
    /// table keeps its frame while this view is hidden, so left armed it would
    /// have been answering that question for every pointer move across the
    /// transcript standing in the same rectangle. `applyShowing` sets `isHidden`
    /// and knows nothing about tracking, which is why this is here rather than
    /// there.
    override var isHidden: Bool {
        get { super.isHidden }
        set {
            super.isHidden = newValue
            updateHover()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // `start` reads `table.window`, so arming before there is one arms
        // nothing and traces `window=false`.
        updateHover()
    }

    private func updateHover() {
        if isHidden || window == nil { hover.stop() } else { hover.start() }
    }

    /// The conversations about this recording, newest first, which is the order
    /// `Chat.about` already gives.
    ///
    /// Re-read on every visit rather than cached: an answer streaming into the
    /// card at the bottom of this window rewrites `chat.json` under this list,
    /// and the first exchange is what gives a conversation its title at all.
    func show(_ recording: Recording?) {
        chats = recording.map { Chat.about($0.id) } ?? []
        empty.isHidden = !chats.isEmpty || recording == nil
        scroll.isHidden = chats.isEmpty
        table.reloadData()
        table.deselectAll(nil)
    }

    /// How many there are, for the count on the tab. Asked of the list rather
    /// than recounted, so the tab and the rows cannot disagree.
    var count: Int { chats.count }

    /// When it was last being had, and how much of it there is.
    ///
    /// Not what it is about: every row here is about the meeting whose page
    /// this is, so `ChatNav`'s third fact would be the same word on every row.
    /// The date is absolute rather than a time of day for the opposite reason:
    /// that list is grouped under day headings and this one is not, so a row
    /// saying only "12:39" would not say which day.
    private func subtitle(for chat: Chat) -> String {
        var facts: [String] = []
        if let stamp = chat.updated ?? chat.created, let date = Timestamps.parse(stamp) {
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .short
            facts.append(f.string(from: date))
        }
        // Questions, never turns: a conversation of four questions and four
        // answers is four things you asked, and counting both halves counts the
        // one you did not write.
        let asked = chat.turns.filter { $0.who == Chat.you }.count
        if asked > 0 { facts.append("\(asked) question" + (asked == 1 ? "" : "s")) }
        return facts.joined(separator: " · ")
    }
}

extension ChatList: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { chats.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HoverRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        guard chats.indices.contains(row) else { return nil }
        let cell = ChatCell()
        cell.configure(chats[row], about: subtitle(for: chats[row]))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard chats.indices.contains(row) else { return }
        let chat = chats[row]
        // **A press, not a selection.** The conversation opens as a card over
        // this page and the page stays where it is, so a row left highlighted
        // behind the card would claim this tab is showing that conversation
        // when it is showing a list. `ChatNav` keeps its highlight because
        // there the list *is* the sidebar of the page being read.
        table.deselectAll(nil)
        onOpen?(chat)
    }
}
