import AVFoundation
import AppKit

/// The main window: recordings on the left, the selected one on the right.
///
/// Apple Notes shape, deliberately. The visual register to match is Anarlog and
/// Granola: light, calm, generous whitespace, content first. This should not
/// read as a developer tool, which mostly means resisting the urge to put a
/// number on everything.
///
/// There is no People tab. Recordings only, asked for explicitly.
@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()

    private var window: NSWindow?
    private var table: NSTableView!
    private var searchField: NSSearchField!
    private var filterBar: NSSegmentedControl!
    private var detail: DetailView!

    private var all: [Recording] = []
    private var shown: [Recording] = []
    private var filter: Filter = .all
    private var query = ""

    enum Filter: Int, CaseIterable {
        case all, needsLabelling, done
        var title: String {
            switch self {
            case .all:           return "All"
            case .needsLabelling: return "Needs labelling"
            case .done:          return "Done"
            }
        }
        func matches(_ r: Recording) -> Bool {
            switch self {
            case .all:            return true
            case .needsLabelling: return r.metadata.stateValue == .needsLabelling
            case .done:           return r.metadata.stateValue == .done
            }
        }
    }

    // MARK: - Showing

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Listen"
        w.titlebarAppearsTransparent = true
        w.center()
        w.setFrameAutosaveName("ListenLibrary")
        w.delegate = self

        let split = NSSplitView(frame: .zero)
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        split.addArrangedSubview(buildSidebar())
        detail = DetailView()
        split.addArrangedSubview(detail)

        let content = NSView()
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        w.contentView = content
        window = w

        // Redraw the row a job is working on rather than the whole list, so a
        // rename being typed elsewhere is not thrown away by a progress tick.
        Queue.shared.onChange = { [weak self] _ in self?.reload() }
    }

    private func buildSidebar() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        searchField = NSSearchField()
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        filterBar = NSSegmentedControl(
            labels: Filter.allCases.map(\.title), trackingMode: .selectOne,
            target: self, action: #selector(filterChanged))
        filterBar.selectedSegment = 0
        filterBar.segmentDistribution = .fillEqually
        filterBar.translatesAutoresizingMaskIntoConstraints = false

        table = NSTableView()
        table.headerView = nil
        table.rowHeight = 62
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.menu = rowMenu()

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(filterBar)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 38),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            filterBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rename", action: #selector(renameSelected), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealSelected),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Transcribe Again", action: #selector(retranscribeSelected),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "")
            .target = self
        return menu
    }

    // MARK: - Data

    func reload() {
        let selectedID = selected?.id
        all = Recording.all()
        applyFilter()
        table?.reloadData()
        // Keep the selection on the same recording rather than the same row
        // index. A transcription finishing reorders nothing today, but a rename
        // or a delete does, and jumping to a different meeting mid-read is the
        // kind of thing nobody reports and everybody notices.
        if let selectedID, let row = shown.firstIndex(where: { $0.id == selectedID }) {
            table?.selectRowIndexes([row], byExtendingSelection: false)
        }
        updateFilterCounts()
        refreshDetail()
    }

    private func applyFilter() {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        shown = all.filter { recording in
            guard filter.matches(recording) else { return false }
            guard !q.isEmpty else { return true }
            if recording.metadata.title.lowercased().contains(q) { return true }
            // Search the transcript too, which is the reason anyone searches a
            // meeting library at all: you remember what was said, not what the
            // recording was called.
            return recording.transcriptText.lowercased().contains(q)
        }
    }

    private func updateFilterCounts() {
        for (i, f) in Filter.allCases.enumerated() {
            let n = all.filter(f.matches).count
            filterBar.setLabel(n > 0 ? "\(f.title) \(n)" : f.title, forSegment: i)
        }
    }

    var selected: Recording? {
        guard let row = table?.selectedRow, row >= 0, row < shown.count else { return nil }
        return shown[row]
    }

    private func refreshDetail() {
        detail?.show(selected)
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        query = searchField.stringValue
        applyFilter()
        table.reloadData()
    }

    @objc private func filterChanged() {
        filter = Filter(rawValue: filterBar.selectedSegment) ?? .all
        applyFilter()
        table.reloadData()
    }

    @objc private func renameSelected() {
        guard var recording = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Rename recording"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = recording.metadata.title
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        recording.metadata.title = name
        try? recording.save()
        reload()
    }

    @objc private func revealSelected() {
        guard let recording = selected else { return }
        NSWorkspace.shared.selectFile(recording.metadataURL.path,
                                      inFileViewerRootedAtPath: recording.folder.path)
    }

    @objc private func retranscribeSelected() {
        guard let recording = selected else { return }
        Queue.shared.enqueue(recording.id)
    }

    @objc private func deleteSelected() {
        guard let recording = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(recording.metadata.title)?"
        // Say what is actually lost. The audio is the irreplaceable part.
        alert.informativeText = "The audio and the transcript are deleted from disk. "
            + "This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? recording.delete()
        reload()
    }
}

// MARK: - Table

extension LibraryWindow: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?,
                   row: Int) -> NSView? {
        let recording = shown[row]
        let cell = RecordingCell()
        cell.configure(recording)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshDetail()
    }
}

/// One row: title, when, how long, and what is happening to it.
@MainActor
final class RecordingCell: NSView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        state.font = .systemFont(ofSize: 11)
        state.textColor = .tertiaryLabelColor
        state.alignment = .right

        for v in [title, subtitle, state] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            state.topAnchor.constraint(equalTo: subtitle.topAnchor),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            state.leadingAnchor.constraint(greaterThanOrEqualTo: subtitle.trailingAnchor,
                                           constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ recording: Recording) {
        title.stringValue = recording.metadata.title
        subtitle.stringValue = [recording.when, recording.lengthText]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        state.stringValue = recording.stateText
    }
}

extension Recording {
    var when: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: metadata.recorded_at) else { return "" }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    var lengthText: String {
        let t = Int(metadata.duration)
        guard t > 0 else { return "" }
        return t >= 3600 ? String(format: "%dh %02dm", t / 3600, (t % 3600) / 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// What the row says on the right.
    ///
    /// Empty when there is nothing to say. A row that reads "Done" on every
    /// finished recording is a column of noise; the states worth a word are the
    /// ones that mean something is happening or something is owed.
    @MainActor
    var stateText: String {
        if Queue.shared.running == id { return Queue.shared.stage ?? "transcribing" }
        if Queue.shared.isQueued(id) { return "waiting" }
        switch metadata.stateValue {
        case .pending:        return hasTranscript ? "" : "not transcribed"
        case .transcribing:   return "transcribing"
        case .needsLabelling: return "needs labelling"
        case .failed:         return "failed"
        case .done, .unconfirmed: return ""
        }
    }

    /// The transcript as one string, for searching.
    var transcriptText: String {
        guard let data = try? Data(contentsOf: turnsURL),
              let turns = try? JSONDecoder().decode([Turn].self, from: data)
        else { return "" }
        return turns.map(\.text).joined(separator: " ")
    }

    var storedTranscript: StoredTranscript? {
        guard let data = try? Data(contentsOf: transcriptURL) else { return nil }
        return try? JSONDecoder().decode(StoredTranscript.self, from: data)
    }
}
