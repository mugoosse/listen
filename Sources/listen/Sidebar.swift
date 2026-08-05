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

    /// Show only the recordings one person is in, by their on-disk label.
    ///
    /// Set from a person's popover rather than from anything in this list. The
    /// day-grouped list is the library and this is a lens over it, so it is
    /// always visibly on and one click from off: a filter you cannot see is a
    /// library with recordings missing from it.
    private var speakerFilter: String?
    private var filterBar: NSView!
    private var filterButton: NSButton!
    private var filterHeight: NSLayoutConstraint!
    private var filterTop: NSLayoutConstraint!

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

        // One control, not a label with a close button beside it: the whole
        // pill turns the filter off, so there is no small target to hit.
        filterButton = NSButton(title: "", target: self, action: #selector(clearSpeakerFilter))
        filterButton.bezelStyle = .inline
        filterButton.font = .systemFont(ofSize: 11, weight: .medium)
        filterButton.image = NSImage(systemSymbolName: "xmark",
                                     accessibilityDescription: "Show everything")
        filterButton.imagePosition = .imageTrailing
        filterButton.toolTip = "Show every recording again"
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterBar = NSView()
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.addSubview(filterButton)
        filterBar.isHidden = true

        container.addSubview(searchField)
        container.addSubview(filterBar)
        container.addSubview(scroll)
        filterHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
        // Collapses to nothing, spacing included. A hidden view keeps its
        // frame, so an unfiltered list would otherwise sit six points lower
        // than it did before this row existed.
        filterTop = filterBar.topAnchor.constraint(equalTo: searchField.bottomAnchor,
                                                   constant: 0)
        NSLayoutConstraint.activate([
            // Clear of the traffic lights, which sit over the content because
            // the window uses a transparent full-size title bar.
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                  constant: -10),
            filterTop,
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                constant: -10),
            filterHeight,
            filterButton.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor),
            filterButton.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
    }

    // MARK: - Data

    func reload() {
        // The list is rebuilt whenever capture changes, and capture can change
        // before the window has ever been shown: the menu bar is built at
        // launch and a recording can be running by then. `table` is created in
        // `loadView`, so without this the first reload is a nil unwrap.
        loadViewIfNeeded()
        let keepID = selectedRecording?.id
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()

        // The recording being made now is in staging, not the library, so
        // `Recording.all()` cannot see it. It is listed anyway, from the first
        // second: pressing Record and having the list stay exactly as it was is
        // indistinguishable from pressing Record and nothing happening, and the
        // one thing this app cannot afford is doubt about whether it is
        // recording.
        // Read from disk rather than using the copy `Capture` took when it
        // started: the row has to show a title changed since, and the folder is
        // the truth about a recording here as everywhere else.
        let live = Capture.shared.current.map { Recording.load($0.folder) ?? $0 }
        let everything = (live.map { [$0] } ?? []) + Recording.all()

        let matching = everything.filter { recording in
            // Never filtered out. A search left in the field from ten minutes
            // ago is not a reason to hide the meeting being recorded now, and
            // neither is a speaker filter it cannot match: a recording still
            // being made has no transcript to have speakers in.
            if recording.id == live?.id { return true }
            if let speakerFilter, !recording.speakers.contains(speakerFilter) {
                return false
            }
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
        guard let date = recording.date else { return "Earlier" }
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

    private func row(for id: String) -> Int? {
        rows.firstIndex {
            if case .recording(let r) = $0 { return r.id == id }
            return false
        }
    }

    /// Select a recording by id. False when the list does not have it, which
    /// is how the caller finds out that a filter is in the way.
    @discardableResult
    func select(_ id: String) -> Bool {
        guard let row = row(for: id) else { return false }
        guard table.selectedRow != row else { return true }
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        // `selectRowIndexes` posts the selection notification, which is what
        // normally updates the pane. Doing it again here rather than trusting
        // that: a selection the user did not make must reach the detail pane,
        // and the cost of it arriving twice is a redraw.
        if selectedRecording?.id != id {
            selectedRecording = recording(at: row)
            onSelect?(selectedRecording)
        }
        return true
    }

    /// Show only the recordings one person is in. nil is the whole library.
    func filter(bySpeaker label: String?) {
        loadViewIfNeeded()
        speakerFilter = label
        if let label {
            filterButton.title = "Only " + SpeakerName.display(label) + " "
        }
        filterBar.isHidden = label == nil
        filterHeight.constant = label == nil ? 0 : 22
        filterTop.constant = label == nil ? 0 : 6
        reload()
    }

    /// Drop everything narrowing the list, for when something outside it needs
    /// a recording the filters are hiding.
    func clearFilters() {
        searchField.stringValue = ""
        query = ""
        filter(bySpeaker: nil)
    }

    @objc private func clearSpeakerFilter() {
        filter(bySpeaker: nil)
    }

    /// Redraw the row of the recording in progress, for its clock.
    ///
    /// One row, not the whole table: a reload every second would cancel a
    /// drag, fight the scroller and rebuild every cell in the library to
    /// advance one number.
    func tickLive() {
        guard let id = Capture.shared.current?.id, let row = row(for: id),
              let recording = recording(at: row),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                  as? RecordingCell
        else { return }
        cell.configure(recording)
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
        // An untitled recording says so in grey, so a list of them reads as a
        // list of things waiting for a name rather than as a list of things
        // that happen to share one.
        title.textColor = recording.isUntitled ? .secondaryLabelColor : .labelColor
        // The length of a live recording comes from the recorder, not the
        // file: `metadata.duration` is written when capture stops.
        let live = recording.isLive
        let length = live ? Recording.length(Capture.shared.elapsed) : recording.lengthText
        subtitle.stringValue = [recording.clockTime, length, recording.stateText]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        // Red only while recording, the same rule as the toolbar button: a
        // permanently coloured row is decoration, one that turns red is a
        // state.
        subtitle.textColor = live ? .systemRed : .secondaryLabelColor
    }
}

extension Recording {
    /// Just the time. The day is already the group heading above it.
    var clockTime: String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
