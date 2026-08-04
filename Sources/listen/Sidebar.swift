import AppKit

/// The recording list.
///
/// Grouped by day with "Today" and "Yesterday" headings, newest first, the way
/// Anarlog does it. Grouping replaces the filter pills the first version had:
/// those existed mostly to find the recordings that still needed a name, and
/// once an unnamed speaker reads as "Speaker A" rather than a bare letter,
/// there is nothing to filter for.
@MainActor
final class SidebarViewController: NSViewController {
    private var table: NSTableView!
    private var searchField: NSSearchField!

    /// Headers and recordings in one list, because that is what the table
    /// draws. `isGroupRow` picks them apart.
    private enum Row {
        case header(String)
        case recording(Recording)
    }

    private var rows: [Row] = []
    private var query = ""

    var onSelect: ((Recording?) -> Void)?
    var onRenamed: (() -> Void)?

    private(set) var selectedRecording: Recording?

    override func loadView() {
        let container = NSView()

        searchField = NSSearchField()
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 52
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.backgroundColor = .clear
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.menu = rowMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            // Clear of the traffic lights, which sit over the content because
            // the window uses a transparent full-size title bar.
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                  constant: -10),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    // MARK: - Data

    func reload() {
        let keepID = selectedRecording?.id
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        let matching = Recording.all().filter { recording in
            guard !q.isEmpty else { return true }
            if recording.metadata.title.lowercased().contains(q) { return true }
            // Search the transcript too, which is the reason anyone searches a
            // meeting library: you remember what was said, not what the
            // recording was called.
            return recording.transcriptText.lowercased().contains(q)
        }

        rows = []
        var lastHeading: String?
        for recording in matching {
            let heading = Self.heading(for: recording)
            if heading != lastHeading {
                rows.append(.header(heading))
                lastHeading = heading
            }
            rows.append(.recording(recording))
        }

        table.reloadData()

        // Keep the selection on the same recording rather than the same row
        // index. Deleting or renaming reorders the list, and jumping to a
        // different meeting mid-read is the kind of thing nobody reports and
        // everybody notices.
        if let keepID, let row = rows.firstIndex(where: {
            if case .recording(let r) = $0 { return r.id == keepID }
            return false
        }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if let fresh = Recording.find(keepID) { selectedRecording = fresh }
        } else if selectedRecording != nil, Recording.find(keepID ?? "") == nil {
            selectedRecording = nil
            onSelect?(nil)
        }
    }

    private static func heading(for recording: Recording) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: recording.metadata.recorded_at) else {
            return "Earlier"
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let f = DateFormatter()
        // Inside the last week the weekday is more use than the date; beyond
        // that it is ambiguous, so switch.
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            f.dateFormat = "EEEE"
        } else {
            f.dateStyle = .long
            f.timeStyle = .none
        }
        return f.string(from: date)
    }

    private func recording(at row: Int) -> Recording? {
        guard row >= 0, row < rows.count, case .recording(let r) = rows[row] else { return nil }
        return r
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        query = searchField.stringValue
        reload()
    }

    @objc private func doubleClicked() {
        // Double-click is rename, matching Finder. The single click already
        // means "show me this one".
        LibraryWindow.shared.renameSelected()
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }
}

// MARK: - Table

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

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
                label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 4),
                label.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -4),
            ])
            return holder

        case .recording(let recording):
            let cell = RecordingCell()
            cell.configure(recording)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedRecording = recording(at: table.selectedRow)
        onSelect?(selectedRecording)
    }
}

// MARK: - Row menu

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Right-clicking a row selects it first, so the menu and the toolbar
        // menu always act on the same recording.
        let clicked = table.clickedRow
        if clicked >= 0, recording(at: clicked) != nil {
            table.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        LibraryWindow.shared.menuNeedsUpdate(menu)
    }
}

/// One row: title, when, how long, and what is happening to it.
@MainActor
final class RecordingCell: NSView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        for v in [title, subtitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ recording: Recording) {
        title.stringValue = recording.metadata.title
        subtitle.stringValue = [recording.clockTime, recording.lengthText,
                                recording.stateText]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

extension Recording {
    /// Just the time. The day is already the group heading above it.
    var clockTime: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: metadata.recorded_at) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
