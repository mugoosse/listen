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

    /// The two rows that used to be toolbar buttons.
    ///
    /// Codex's shape, and it earns its place here for a reason the toolbar
    /// could not: Record is the app's primary action and belongs where the eye
    /// already is, at the top of the list it will add to, and Settings is the
    /// one thing you reach for least, so it belongs at the bottom out of the
    /// way. A toolbar gives both the same weight and puts them equally far from
    /// what they act on.
    /// Where a row's content starts, matching the recording titles below.
    ///
    /// An inset table indents its rows and `RecordingCell` insets its title
    /// inside that. Measured against the result rather than added up from the
    /// two constants: at 18 the row's icon sat four points left of every title
    /// in the list, which is exactly close enough to look like a mistake rather
    /// than a margin.
    private static let rowInset: CGFloat = 22

    /// Where a row's *background* starts: level with the search field, so the
    /// highlight is the width of the control above it rather than a shorter bar
    /// floating inside the same column.
    private static let rowEdge: CGFloat = 10

    private var newButton: SidebarRow!
    private var settingsButton: SidebarRow!

    var onNewRecording: (() -> Void)?
    var onSettings: (() -> Void)?
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
        // A capsule in the accent colour rather than a line of text with a
        // cross after it. It is a token saying the list is not the whole
        // library, so it should look like the chips that put it there, and the
        // whole capsule is the target rather than the small glyph on its end.
        filterButton.isBordered = false
        filterButton.wantsLayer = true
        filterButton.layer?.cornerRadius = 11
        filterButton.layer?.backgroundColor = NSColor.controlAccentColor
            .withAlphaComponent(0.18).cgColor
        filterButton.contentTintColor = .controlAccentColor
        filterButton.font = .systemFont(ofSize: 11, weight: .semibold)
        filterButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                     accessibilityDescription: "Show everything")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        filterButton.imagePosition = .imageTrailing
        filterButton.toolTip = "Show every recording again"
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        filterBar = NSView()
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.addSubview(filterButton)
        filterBar.isHidden = true

        // "New Recording" and not "Record": it names the thing that appears in
        // the list below it, the way every other row here is a noun, and it
        // does not collide with the state it turns into. Somebody who has just
        // installed this cannot tell what "Record" would record, so the tooltip
        // says the part that cannot be guessed.
        newButton = row("New Recording", "record.circle", #selector(newRecording))
        newButton.toolTip = "Record this Mac's audio and your microphone"
        settingsButton = row("Settings", "gearshape", #selector(openSettings))
        settingsButton.toolTip = "Settings (⌘,)"
        settingsButton.contentTintColor = .secondaryLabelColor

        container.addSubview(searchField)
        container.addSubview(newButton)
        container.addSubview(filterBar)
        container.addSubview(scroll)
        // A hairline, so the list ends rather than appearing to run underneath
        // the row pinned over it.
        let footerRule = NSBox()
        footerRule.boxType = .separator
        footerRule.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(footerRule)
        container.addSubview(settingsButton)
        filterHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
        // Collapses to nothing, spacing included. A hidden view keeps its
        // frame, so an unfiltered list would otherwise sit six points lower
        // than it did before this row existed.
        filterTop = filterBar.topAnchor.constraint(equalTo: newButton.bottomAnchor,
                                                   constant: 0)
        NSLayoutConstraint.activate([
            // Clear of the traffic lights, which sit over the content because
            // the window uses a transparent full-size title bar.
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                  constant: -10),
            // Spaced like a row in the list below it rather than crammed
            // against the search field: the icon lines up with the recording
            // titles, and there is air on both sides of the pair.
            newButton.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            newButton.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                               constant: Self.rowEdge),
            newButton.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                constant: -Self.rowEdge),
            newButton.heightAnchor.constraint(equalToConstant: 32),
            filterTop,
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor,
                                                constant: -10),
            filterHeight,
            filterButton.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor),
            filterButton.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerRule.topAnchor),
            footerRule.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerRule.bottomAnchor.constraint(equalTo: settingsButton.topAnchor,
                                               constant: -10),
            settingsButton.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                    constant: Self.rowEdge),
            settingsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                     constant: -Self.rowEdge),
            settingsButton.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                                   constant: -14),
            settingsButton.heightAnchor.constraint(equalToConstant: 32),
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
            // Padded with spaces, which is what a borderless button gives you
            // instead of an inset: the capsule would otherwise be drawn tight
            // against both ends of the text.
            filterButton.title = "  Only " + SpeakerName.display(label) + "  "
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

    /// A full-width row: icon, then text, then nothing. The shape of a
    /// navigation item rather than of a button, because that is what these are.
    private func row(_ title: String, _ symbol: String, _ action: Selector) -> SidebarRow {
        let button = SidebarRow(title: title, target: self, action: action,
                                contentInset: Self.rowInset - Self.rowEdge)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return button
    }

    /// What the Record row says, which is also the only clock on screen while
    /// the sidebar is what you are looking at.
    ///
    /// Red only while recording. A permanently coloured row is decoration; one
    /// that turns red is a state.
    func setRecording(_ recording: Bool, elapsed: TimeInterval) {
        loadViewIfNeeded()
        newButton.title = recording ? "Stop  " + Recording.length(elapsed)
                                    : "New Recording"
        newButton.image = NSImage(
            systemSymbolName: recording ? "stop.fill" : "record.circle",
            accessibilityDescription: recording ? "Stop recording" : "Start recording")
        // Red only while recording. A permanently coloured row is decoration;
        // one that turns red is a state, which is the same rule the toolbar
        // control follows.
        newButton.contentTintColor = recording ? .systemRed : .labelColor
    }

    @objc private func newRecording() { onNewRecording?() }
    @objc private func openSettings() { onSettings?() }

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
        // A cell is not told that the selection moved, and the pointer can be
        // resting on the row that just became selected, so the hover would stay
        // drawn on top of it.
        table.restyleHoverCells()
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
final class RecordingCell: HoverCell {
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
        restyle()
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

/// A table cell that lights up under the pointer.
///
/// `NSTableView` has no hover state of its own, so the recording list looked
/// inert next to the rows above and below it, which do respond. The highlight
/// is the same weight as `SidebarRow`'s, and it defers to the selection: a
/// selected row is already painted, and drawing over it would only muddy the
/// colour the table chose.
@MainActor
class HoverCell: NSView {
    private var hovering = false { didSet { restyle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Reconsider the highlight. Called by the table when the selection moves,
    /// because a cell is never told, and by `configure` because a reused cell
    /// arrives carrying the state of the row it used to be.
    func restyle() {
        let selected = (superview as? NSTableRowView)?.isSelected ?? false
        layer?.backgroundColor = hovering && !selected
            ? NSColor.quaternaryLabelColor.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

extension NSTableView {
    /// Let every visible cell reconsider its hover.
    @MainActor
    func restyleHoverCells() {
        let visible = rows(in: visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<(visible.lowerBound + visible.length) {
            (view(atColumn: 0, row: row, makeIfNecessary: false) as? HoverCell)?.restyle()
        }
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


/// A sidebar row that lights up under the pointer.
///
/// A view rather than a button, for one reason: the highlight has to span the
/// sidebar the way the search field above it does, while the icon and the text
/// line up with the recording titles below. A button's frame is both its
/// background and its content, so it can satisfy one or the other. Here the
/// frame is the width of the search field and `contentInset` puts the content
/// where the list is.
@MainActor
final class SidebarRow: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private weak var target: AnyObject?
    private let action: Selector

    /// Where the icon starts, measured from the row's own leading edge.
    private let contentInset: CGFloat

    var title: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var image: NSImage? {
        get { icon.image }
        set { icon.image = newValue }
    }

    /// Tints both halves, so a row is one colour rather than an icon and a
    /// label that happen to agree.
    var contentTintColor: NSColor? {
        didSet {
            icon.contentTintColor = contentTintColor
            label.textColor = contentTintColor ?? .labelColor
        }
    }

    private var hovering = false { didSet { restyle() } }
    private var pressed = false { didSet { restyle() } }

    init(title: String, target: AnyObject?, action: Selector,
         contentInset: CGFloat = 12) {
        self.target = target
        self.action = action
        self.contentInset = contentInset
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                            constant: -contentInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        let alpha: CGFloat = pressed ? 0.26 : (hovering ? 0.16 : 0)
        layer?.backgroundColor = alpha == 0
            ? NSColor.clear.cgColor
            : NSColor.quaternaryLabelColor.withAlphaComponent(alpha).cgColor
    }

    /// Rebuilt on every layout, because a tracking area holds the rectangle it
    /// was made with: one added once keeps lighting up the place the row used
    /// to be after the sidebar is resized.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        // Only when the pointer is still on the row, which is what letting go
        // somewhere else means everywhere on this platform.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}
