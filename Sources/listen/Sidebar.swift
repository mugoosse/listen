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
    private var hover: TableHover!

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
        hover = TableHover(table, name: "sidebar")
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

    /// The Record row while a meeting is running: the same words, greyed.
    ///
    /// It used to become a red Stop row with a clock in it, which put the
    /// elapsed time on screen three times at once and a second stop control
    /// beside the one in the toolbar. A row that changes its verb, its icon and
    /// its colour is also a row you have to read before you can trust what
    /// pressing it does.
    ///
    /// Disabled says the one thing that is true and is not said anywhere else:
    /// there is no second recording to start. Stopping is the toolbar's, on the
    /// meeting you have open, and the menu bar's from anywhere.
    func setRecording(_ recording: Bool) {
        loadViewIfNeeded()
        newButton.isEnabled = !recording
        // A greyed control with no reason beside it is the shape people read as
        // broken, and the reason is not guessable from a row that says the same
        // thing it always says.
        newButton.toolTip = recording
            ? "Already recording. Stop it from the toolbar or the menu bar."
            : "Record this Mac's audio and your microphone"
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        // Day headings are not rows anybody can act on, so they do not light up.
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

    /// Monospaced digits, so a counting clock does not shuffle the words after
    /// it. Named because `configure` writes an attributed string, which carries
    /// its own font rather than taking the field's.
    private static let subtitleFont =
        NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = Self.subtitleFont
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
        let facts = [recording.clockTime, length].filter { !$0.isEmpty }
            .joined(separator: " · ")
        let state = recording.stateText

        // Red on the state word alone, and not on the line. The time and the
        // length are the same facts every other row prints, and colouring them
        // says the clock is the alarming part rather than what it is reporting.
        // The same rule as before, applied to less: a permanently coloured row
        // is decoration, one word that turns red is a state.
        //
        // The font travels with every run: an attributed string is the whole
        // description of what is drawn, so the monospaced digits set on the
        // field once are not inherited by anything set this way. Without it the
        // clock changes width as it counts.
        func run(_ text: String, _ colour: NSColor) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.foregroundColor: colour,
                                                          .font: Self.subtitleFont])
        }
        let line = NSMutableAttributedString(attributedString: run(facts, .secondaryLabelColor))
        if !state.isEmpty {
            if !facts.isEmpty { line.append(run(" · ", .secondaryLabelColor)) }
            line.append(run(state, live ? .systemRed : .secondaryLabelColor))
        }
        subtitle.attributedStringValue = line
    }
}

/// A table row that lights up under the pointer, and paints its own selection.
///
/// **Both are drawn here, and that is the point.** The hover used to be a
/// background on the cell, which sits inside the row view, so it was a
/// different width from the selection AppKit draws on the row itself: two
/// highlights for the same list, neither lining up with the other. Drawing both
/// in the row view gives them one geometry by construction.
///
/// The two point vertical inset is what keeps neighbours apart. Filling the row
/// makes a hovered row and the selected row above it into one continuous block,
/// which reads as a single tall selection rather than as two states.
@MainActor
final class HoverRowView: NSTableRowView {
    var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    /// Matches the inset `NSTableView` style, which is what the rest of this
    /// sidebar is laid out against.
    private static let sideInset: CGFloat = 10
    private static let gap: CGFloat = 2
    private static let radius: CGFloat = 8

    private var highlightRect: NSRect {
        bounds.insetBy(dx: Self.sideInset, dy: Self.gap)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        // Emphasized is the accent colour, which is the window being key; the
        // unemphasized grey is what AppKit uses when it is not, and copying
        // both is what keeps a background window's list from shouting.
        (isEmphasized ? NSColor.controlAccentColor
                      : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: highlightRect,
                     xRadius: Self.radius, yRadius: Self.radius).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard hovering, !isSelected else { return }
        hoverTint(0.14).setFill()
        NSBezierPath(roundedRect: highlightRect,
                     xRadius: Self.radius, yRadius: Self.radius).fill()
    }

    /// A reused row arrives carrying the last row's hover.
    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }
}

extension NSView {
    /// The grey a row is tinted with under the pointer, resolved against the
    /// window's light or dark appearance rather than the view's own.
    ///
    /// **A sidebar's descendants draw in a *vibrant* appearance, where the label
    /// colours mean something else.** Measured on this machine, in dark mode:
    ///
    ///     darkAqua      quaternaryLabelColor  white 1.0  alpha 0.098
    ///     vibrantDark   quaternaryLabelColor  grey 0.137 alpha 1.0
    ///
    /// Vibrancy blends its version rather than compositing it, so used as a
    /// plain alpha fill inside the sidebar it is dark grey at 14% over a dark
    /// background, which is no change to any pixel. That was this bug: the
    /// highlight really was drawn, on the right rectangle, on every pointer
    /// move, and nothing appeared. Three fixes to the *tracking* went in before
    /// anybody looked at the colour, because a hover that never draws and a
    /// hover that draws nothing are the same screenshot.
    ///
    /// It also explains the cell-based version this replaced, which worked: it
    /// set `layer.backgroundColor`, and `NSColor.cgColor` resolves against
    /// whatever appearance is current at that moment. Called from
    /// `mouseEntered` that is the window's `darkAqua`, never the `vibrantDark`
    /// a `draw(_:)` would have installed. So the same expression was correct
    /// there and invisible here, which is why moving the highlight from the
    /// cell to the row view appeared to break the tracking.
    ///
    /// `bestMatch` is what maps back: `vibrantDark` to `darkAqua`, verified
    /// rather than assumed. White and black are stated outright because that is
    /// exactly what `quaternaryLabelColor.withAlphaComponent` resolves to in
    /// the two non-vibrant appearances, and the alpha is being replaced anyway.
    @MainActor
    func hoverTint(_ alpha: CGFloat) -> NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha)
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

    /// Whether the row answers. A disabled row keeps its words and dims, which
    /// is the one shape on this platform that reads as "not now" rather than as
    /// something having gone wrong.
    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.4
            // Or the highlight from the last hover stays painted under a row
            // that no longer responds to the pointer.
            hovering = false
            pressed = false
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
            : hoverTint(alpha).cgColor
    }

    /// A `CGColor` is a snapshot of whatever it was resolved from, so switching
    /// the Mac between light and dark leaves the last one behind.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// Rebuilt on every layout, because a tracking area holds the rectangle it
    /// was made with: one added once keeps lighting up the place the row used
    /// to be after the sidebar is resized.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = isEnabled }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = isEnabled }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        guard isEnabled else { return }
        // Only when the pointer is still on the row, which is what letting go
        // somewhere else means everywhere on this platform.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSApp.sendAction(action, to: target, from: self)
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

/// Which row the pointer is over, followed from the window's mouse events.
///
/// A monitor rather than a tracking area, because the row that lights up and
/// the cell the pointer is actually over are two different views and this way
/// nothing has to forward between them. It needs `acceptsMouseMovedEvents` on
/// the window, which is off by default.
///
/// **Measured, and worth keeping in mind before it is rewritten again**: the
/// monitor is armed, the events arrive, the point converts, and the right row
/// view is found on every move. Two earlier tracking-area versions were
/// abandoned on the theory that they were not firing, when the state they set
/// was reaching the row view and the highlight was being painted in a colour
/// that changed no pixels. See `hoverTint` above. The tracking was never the
/// bug, so a fourth mechanism would not have been either.
@MainActor
final class TableHover {
    private weak var table: NSTableView?
    private var monitor: Any?
    private let name: String

    init(_ table: NSTableView, name: String) {
        self.table = table
        self.name = name
    }

    func start() {
        guard monitor == nil else { return }
        table?.window?.acceptsMouseMovedEvents = true
        // A pointer monitor leaves nothing behind to inspect, and this hover was
        // rebuilt three times against the wrong suspect. The trace says whether
        // it was ever armed, which is the first thing to rule out next time.
        trace("\(name): hover armed, window=\(table?.window != nil)")
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .mouseExited, .scrollWheel]) { [weak self] event in
                self?.update(event)
                return event
            }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        clear()
    }

    private func update(_ event: NSEvent) {
        guard let table, table.window === event.window else { clear(); return }
        let point = table.convert(event.locationInWindow, from: nil)
        let hovered = table.bounds.contains(point) ? table.row(at: point) : -1
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<(visible.lowerBound + visible.length) {
            (table.rowView(atRow: row, makeIfNecessary: false) as? HoverRowView)?
                .hovering = row == hovered
        }
    }

    private func clear() {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<(visible.lowerBound + visible.length) {
            (table.rowView(atRow: row, makeIfNecessary: false) as? HoverRowView)?
                .hovering = false
        }
    }
}
