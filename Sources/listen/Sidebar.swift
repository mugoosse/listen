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

    /// What the list is narrowed to, besides the search field.
    ///
    /// A person comes from their popover and a tag from a pill in the
    /// transcript's header, so neither is set from anything in this list and
    /// both are things you arrive at holding. The day-grouped list is the
    /// library and these are lenses over it, so they are always visibly on and
    /// one click from off: a filter you cannot see is a library with recordings
    /// missing from it.
    ///
    /// **They stack, and they are ANDed.** "The calls Ryan and Emily were both
    /// in" is a question one lens cannot ask, and it is the ordinary reason to
    /// reach for this at all. Setting one therefore adds rather than replaces,
    /// which is how a row of tokens behaves everywhere else; replacing is
    /// dismissing the old one first.
    private enum Lens: Equatable {
        case speaker(String)
        case tag(String)
        /// Recordings with a voice nobody has named. Unlike the other two this
        /// one is set from inside the list, by the row above it, because it is
        /// the only lens that is a question about the library as a whole rather
        /// than about a thing you arrived at holding.
        case unnamed
    }

    private var lenses: [Lens] = []

    /// The row that offers the to-do list, above the list and only while there
    /// is one.
    ///
    /// **Not a status on every row, which is what this replaces.** There used to
    /// be a "needs labelling" state in the sidebar with a filter tab beside it,
    /// and the reason both went is in `Recording.stateText`: an unnamed speaker
    /// reads as "Speaker A" in the transcript, which is legible on its own, so
    /// the list was nagging about something that did not look broken. What was
    /// actually missing was never a badge on 13 rows, it was one sentence saying
    /// the 13 exist. This row is that sentence, it counts rather than warns, and
    /// it is gone entirely the moment the count is zero, so a library with
    /// nothing outstanding looks exactly as it did before this existed.
    private var todoRow: SidebarRow!
    private var todoHeight: NSLayoutConstraint!
    private var todoTop: NSLayoutConstraint!

    /// Settings is the one row left here, at the bottom, because it is the
    /// thing you reach for least. Record was the row above the list until it
    /// became `RecordButton`: see there for why it left, which is that a
    /// collapsed sidebar took the app's primary action off the screen with it.
    ///
    /// Where a row's content starts, matching the app icons below.
    ///
    /// An inset table indents its rows and `RecordingCell` insets its own
    /// content inside that. Measured against the result rather than added up
    /// from the two constants: at 18 this row's icon sat four points left of
    /// everything under it, which is exactly close enough to look like a
    /// mistake rather than a margin.
    ///
    /// It used to line up with the recording *titles*, because there was
    /// nothing else in the list to line up with. Now that a recording carries
    /// its app's icon, the sidebar has two columns and not three: this row's
    /// icon over the app icons, this row's label over the titles. Measured off
    /// the screen when both rows were still here, in points from the same edge:
    /// icon ink at 33 (New Recording), 32 (Settings, a narrower glyph in the
    /// same box) and 34 (an app icon, which fills its box); text ink at 56 and
    /// 58. What is left is the glyphs' own side bearings.
    private static let rowInset: CGFloat = 22

    /// Where a row's *background* starts: level with the search field, so the
    /// highlight is the width of the control above it rather than a shorter bar
    /// floating inside the same column.
    private static let rowEdge: CGFloat = 10

    private var settingsButton: SidebarRow!

    var onSettings: (() -> Void)?
    private var filterBar: NSView!
    private var filterStack: NSStackView!

    private static let lensSpacing: CGFloat = 6

    /// What the lens row has to share before it has been laid out once.
    ///
    /// The sidebar opens at 280 points and this row is inset 12 and 10, so the
    /// first render of a lens set has this to divide up. Every render after it
    /// measures the bar instead.
    private static let lensRowWidth: CGFloat = 258
    private var filterHeight: NSLayoutConstraint!
    private var filterTop: NSLayoutConstraint!

    var onSelect: ((Recording?) -> Void)?
    var onRenamed: (() -> Void)?
    var onCollection: ((LibraryCollection) -> Void)?
    private var picker: CollectionPicker!

    private(set) var selectedRecording: Recording?
    private var hover: TableHover!

    /// True while `reload` is rebuilding the list, so its own re-selection is
    /// not reported as the user picking a recording.
    ///
    /// `reloadData` drops the table's selection and the re-select puts it back,
    /// and both post `NSTableViewSelectionDidChangeNotification`. Reported as
    /// a selection change, that reaches `DetailView.show`, which stops
    /// playback, puts the playhead back to zero and rebuilds every turn: so
    /// renaming a recording or correcting a sentence while listening to it
    /// silenced the recording being corrected, and any reload at all blanked
    /// the pane and rebuilt it. Measured: paused at 00:03, rename, 00:00.
    ///
    /// Landing somewhere new is still reported, at the end of `reload`, because
    /// then it is true.
    private var reloading = false

    override func loadView() {
        let container = NSView()

        picker = CollectionPicker(showing: .recordings)
        picker.onSelect = { [weak self] in self?.onCollection?($0) }

        searchField = NSSearchField()
        // Scoped, and it says so. The search reads this list and nothing else,
        // so a field that just said "Search" beside a segment control would be
        // claiming a reach it does not have.
        searchField.placeholderString = LibraryCollection.recordings.searchPlaceholder
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
        //
        // **It is a `SpeakerPill`, the same class as the chips that set it.**
        // This is a token saying the list is not the whole library, so it
        // should look like the thing you clicked to narrow it, and the way to
        // guarantee that is to be the same object rather than a second one
        // drawn to match. A person's lens takes their colour and a tag's takes
        // the neutral wash a tag pill has, so which kind of lens is on is
        // legible before the words are read.
        //
        // What this replaces was a hand-built capsule: accent wash, 11 point
        // semibold, an 11 point corner radius, and a stated width to buy the
        // padding a borderless button has none of. Every one of those numbers
        // was a copy of one in `SpeakerPill` that had already gone out of step
        // with it by two points.
        filterStack = NSStackView()
        filterStack.orientation = .horizontal
        filterStack.alignment = .centerY
        filterStack.spacing = Self.lensSpacing
        filterStack.translatesAutoresizingMaskIntoConstraints = false
        filterBar = NSView()
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        // Long names in a narrow sidebar are clipped rather than drawn over the
        // list below.
        filterBar.clipsToBounds = true
        filterBar.addSubview(filterStack)
        filterBar.isHidden = true

        settingsButton = row("Settings", "gearshape", #selector(openSettings))
        settingsButton.toolTip = "Settings (⌘,)"
        settingsButton.contentTintColor = .secondaryLabelColor

        todoRow = row("", "person.crop.circle.badge.questionmark",
                      #selector(showUnnamed))
        todoRow.isHidden = true

        container.addSubview(picker)
        container.addSubview(searchField)
        container.addSubview(filterBar)
        container.addSubview(todoRow)
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
        filterTop = filterBar.topAnchor.constraint(equalTo: searchField.bottomAnchor,
                                                   constant: 0)
        todoTop = todoRow.topAnchor.constraint(equalTo: filterBar.bottomAnchor,
                                               constant: 0)
        todoHeight = todoRow.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate(picker.constraints(in: container, above: searchField) + [
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                  constant: -10),
            filterTop,
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            // Pinned rather than `lessThanOrEqualTo`, because the pills inside
            // are sized against this width: with the bar free to shrink to its
            // content there would be nothing for them to be a share of.
            filterBar.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                constant: -10),
            filterHeight,
            filterStack.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor),
            filterStack.centerYAnchor.constraint(equalTo: filterBar.centerYAnchor),
            filterStack.trailingAnchor.constraint(lessThanOrEqualTo: filterBar.trailingAnchor),

            // Collapses to nothing, spacing included, for the reason the lens
            // row above it does: a hidden view keeps its frame, and a library
            // with nothing outstanding must look exactly as it did before this
            // row existed.
            todoTop,
            todoHeight,
            todoRow.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                             constant: Self.rowEdge),
            todoRow.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                              constant: -Self.rowEdge),

            scroll.topAnchor.constraint(equalTo: todoRow.bottomAnchor, constant: 10),
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
        let q = query.trimmingCharacters(in: .whitespaces)

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
        let library = Recording.all()

        // `tag:` in the search field is a lens typed rather than clicked, so it
        // is parsed against the tags that exist: see `RecordingFilter.parse`.
        var filter = RecordingFilter.parse(q, knownTags: Tags.all(in: library).map(\.name))
        for lens in lenses {
            switch lens {
            case .speaker(let label): filter.people.append(label)
            case .tag(let name): filter.tags.append(name)
            case .unnamed: filter.needsSpeakers = true
            }
        }

        // The recording being made now is never filtered out. A search left in
        // the field from ten minutes ago is not a reason to hide the meeting
        // being recorded now, and neither is a lens it cannot match: a
        // recording still being made has no transcript to have speakers in, and
        // its tags are the ones somebody is about to add.
        let matching = (live.map { [$0] } ?? []) + filter.apply(to: library)

        refreshTodo(in: library)

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

        reloading = true
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
            reloading = false
        } else if selectedRecording != nil, Recording.find(keepID ?? "") == nil {
            selectedRecording = nil
            reloading = false
            onSelect?(nil)
        } else {
            reloading = false
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

    /// How many recordings are waiting on a name, said once above the list.
    ///
    /// Counted from the **unfiltered** library, so the row goes on saying how
    /// much work there is while a search is narrowing the list to something
    /// else. A count that moved with the search would be answering a question
    /// nobody asked and would read as zero the moment somebody typed.
    ///
    /// Hidden while the lens is on, because then the list *is* the answer and a
    /// row offering to show what is already shown is a control that does
    /// nothing. The lens pill above it is what turns it back off.
    private func refreshTodo(in library: [Recording]) {
        let waiting = lenses.contains(.unnamed) ? 0 : Labelling.waiting(in: library).count
        let show = waiting > 0
        todoRow.isHidden = !show
        todoHeight.constant = show ? 32 : 0
        todoTop.constant = show ? 10 : 0
        guard show else { return }
        todoRow.title = waiting == 1
            ? "1 recording needs a speaker"
            : "\(waiting) recordings need a speaker"
        todoRow.toolTip = "Show only the recordings with a voice nobody has named."
    }

    @objc private func showUnnamed() {
        filter(byUnnamedSpeakers: true)
    }

    /// Also show only the recordings with somebody unnamed in them.
    func filter(byUnnamedSpeakers on: Bool) {
        add(on ? .unnamed : nil)
    }

    /// Also show only the recordings one person is in. nil clears every lens.
    func filter(bySpeaker label: String?) {
        add(label.map { Lens.speaker($0) })
    }

    /// Also show only the recordings carrying one tag. nil clears every lens.
    func filter(byTag name: String?) {
        add(name.map { Lens.tag($0) })
    }

    /// Add a lens, or clear them all.
    ///
    /// Adding the one already on is a no-op rather than a duplicate: clicking a
    /// chip twice is something people do, and two identical tokens narrowing to
    /// the same thing is a row you have to dismiss twice.
    private func add(_ next: Lens?) {
        loadViewIfNeeded()
        guard let next else {
            lenses = []
            renderLenses()
            return
        }
        guard !lenses.contains(next) else { return }
        lenses.append(next)
        renderLenses()
    }

    private func renderLenses() {
        for view in filterStack.arrangedSubviews { view.removeFromSuperview() }

        // Each pill is capped at an equal share of the row, so a second lens
        // truncates the first rather than pushing it off the side. The whole
        // name stays in the tooltip, which is the trade the sidebar's titles
        // already make.
        let room = filterBar.bounds.width > 0 ? filterBar.bounds.width : Self.lensRowWidth
        let share = (room - Self.lensSpacing * CGFloat(max(0, lenses.count - 1)))
            / CGFloat(max(1, lenses.count))

        for lens in lenses {
            let pill = SpeakerPill()
            pill.target = self
            pill.action = #selector(dropLens(_:))
            // A bare cross rather than `xmark.circle.fill`. The filled disc is a
            // second capsule inside a capsule and draws heavier at this size
            // than the name beside it, so the eye lands on the dismiss glyph
            // rather than on what is being filtered. See `SpeakerPill.trailing`
            // for why it is a character and not the button's image.
            // No `setAccessibilityTitle` here: it replaces the title rather than
            // adding to it, so the pill announced "Stop filtering" and stopped
            // saying which filter. What it is stays the title and what clicking
            // does is the tooltip, which is `AXHelp`.
            pill.trailing = "✕"

            switch lens {
            case .speaker(let label):
                // Their name and their colour, so the token is the chip that
                // set it. No "Only" in front: the row is a list of filters and
                // a second one reading "Only Emily" beside "Only Ryan" claims
                // each is the whole of it, which is the opposite of what two
                // ANDed lenses mean.
                pill.show(label, title: SpeakerName.display(label))
                pill.identifier = NSUserInterfaceItemIdentifier("speaker:" + label)
                pill.toolTip = "Only the recordings \(SpeakerName.display(label)) is in. "
                    + "Click to drop this filter."
            case .tag(let name):
                // The neutral wash a tag pill has. A tag is not somebody, so
                // borrowing a person's colour would be the one token on screen
                // whose colour means nothing.
                pill.showPlain("#" + name)
                pill.identifier = NSUserInterfaceItemIdentifier("tag:" + name)
                pill.toolTip = "Only the recordings tagged #\(name). "
                    + "Click to drop this filter."
            case .unnamed:
                // The same neutral wash, for the same reason: this lens is about
                // a state of the library rather than about a person, so a
                // person's colour would be a lie about what set it.
                pill.showPlain("Needs a speaker")
                pill.identifier = NSUserInterfaceItemIdentifier("unnamed")
                pill.toolTip = "Only the recordings with a voice nobody has named. "
                    + "Click to drop this filter."
            }
            filterStack.addArrangedSubview(pill)
            pill.widthAnchor.constraint(lessThanOrEqualToConstant: max(44, share))
                .isActive = true
        }

        let empty = lenses.isEmpty
        filterBar.isHidden = empty
        filterHeight.constant = empty ? 0 : 22
        // 10 rather than 6. The search field is a bezelled control with its own
        // focus ring, so six points read as the pills hanging off the bottom of
        // it rather than as a row of their own.
        filterTop.constant = empty ? 0 : 10
        reload()
    }

    /// Drop everything narrowing the list, for when something outside it needs
    /// a recording the filters are hiding.
    ///
    /// Every lens, and that matters: `LibraryWindow.open(recording:note:)` and
    /// `reveal` give way to the filters to reach a recording, so one left behind
    /// turns a note's source link into a beep.
    func clearFilters() {
        searchField.stringValue = ""
        query = ""
        add(nil)
    }

    @objc private func dropLens(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        lenses.removeAll { lens in
            switch lens {
            case .speaker(let label): return id == "speaker:" + label
            case .tag(let name): return id == "tag:" + name
            case .unnamed: return id == "unnamed"
            }
        }
        renderLenses()
    }

    /// Redraw the row of the recording in progress, for its clock.
    ///
    /// One row, not the whole table: a reload every second would cancel a
    /// drag, fight the scroller and rebuild every cell in the library to
    /// advance one number.
    func tickLive() {
        guard let id = Capture.shared.current?.id else { return }
        tickRow(id)
    }

    /// Redraw one row in place, wherever the reason came from.
    ///
    /// The second caller is transcription progress, which is the same argument
    /// as the clock's and arrives more often: once per chunk rather than once
    /// per second, and the row's subtitle carries the stage.
    ///
    /// A row that is scrolled out of view has no cell, and `makeIfNecessary` is
    /// false on purpose: there is nothing to redraw, and building one to write a
    /// number nobody can see is the work this exists to avoid.
    func tickRow(_ id: String) {
        guard let row = row(for: id),
              let recording = recording(at: row),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                  as? RecordingCell
        else { return }
        cell.configure(recording)
    }

    /// Put the segmented control back where the window says it should be.
    ///
    /// Each list carries its own copy of the same control, so clicking Notes on
    /// this one leaves it reading "Notes" while this one is the list on screen.
    /// Measured that way round: the sidebar came back to Recordings with the
    /// segment still highlighting Notes, which reads as the control having
    /// stopped working.
    func setCollection(_ collection: LibraryCollection) {
        loadViewIfNeeded()
        picker.selectedSegment = collection.rawValue
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
                // Level with the icon column below it, not four points inside
                // it. A day heading, an app icon and New Recording's dot now
                // share one edge, and every title in the list shares the next.
                label.leadingAnchor.constraint(equalTo: holder.leadingAnchor,
                                               constant: RecordingCell.textInset),
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
        // Not while `reload` is putting the selection back where it was: that
        // is the list being rebuilt, not somebody choosing a recording. See
        // `reloading`.
        guard !reloading else { return }
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

    /// The app the call was in, as its icon.
    ///
    /// An icon rather than a fourth fact in the subtitle, which already reads
    /// `18:04 · 33:12 · recording` inside a 280 point sidebar and truncates
    /// before it gets to a fifth word. The icon costs no text width, and it is
    /// the one thing on the row somebody recognises without reading.
    private let appIcon = NSImageView()

    /// The icon column, and the text column after it, are the sidebar's and not
    /// this cell's.
    ///
    /// `SidebarViewController.rowInset` puts New Recording's icon 22 points in,
    /// measured against what is under it, and `SidebarRow` puts its label
    /// 16 + 8 after that. A row that reserves the
    /// same 16 and then uses a gap of its own invention lands two points off
    /// every other label in the list, which is the width that reads as a
    /// mistake rather than as a margin. So: same icon, same gap, one column.
    private static let icon: CGFloat = 16
    private static let gap: CGFloat = 8
    /// The cell's own inset, inside the inset table's. 8 + 14 is the 22 above.
    /// The day headings are laid out against this too, so the two cannot part.
    static let textInset: CGFloat = 8

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

        for v in [title, subtitle, appIcon] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // The two lines are centred as one block rather than pinned to the top
        // of the row. Pinned, a 52 point row put 8 above the title and 13 under
        // the subtitle, so every row in the list sat slightly high inside its
        // own selection. A guide rather than a stack view because a vertical
        // `NSStackView` sizes an arranged subview to what it asks for, and a
        // label that truncates asks for its whole string.
        let block = NSLayoutGuide()
        addLayoutGuide(block)

        NSLayoutConstraint.activate([
            appIcon.leadingAnchor.constraint(equalTo: leadingAnchor,
                                             constant: Self.textInset),
            appIcon.widthAnchor.constraint(equalToConstant: Self.icon),
            appIcon.heightAnchor.constraint(equalToConstant: Self.icon),
            // Centred on both lines, not on the title. On the title's line it
            // reads as punctuation attached to the name; on the block it reads
            // as the row's own mark, which is what it is.
            appIcon.centerYAnchor.constraint(equalTo: block.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: appIcon.trailingAnchor,
                                           constant: Self.gap),
            title.trailingAnchor.constraint(equalTo: trailingAnchor,
                                            constant: -Self.textInset),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            block.topAnchor.constraint(equalTo: title.topAnchor),
            block.bottomAnchor.constraint(equalTo: subtitle.bottomAnchor),
            block.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ recording: Recording) {
        title.stringValue = recording.metadata.title
        // The column is reserved whether or not there is an icon to put in it,
        // so every title in the list starts at the same place. Indenting only
        // the rows that have one gives the list a ragged left edge that moves
        // as you scroll, which is worse than an empty square: a recording made
        // in a quiet room, and one made on a call, are the same kind of thing.
        // Cells are reused, so this is written every time.
        // Listen's own icon when nothing else was on the call, because that is
        // the true answer rather than a blank: a recording started from the
        // sidebar in a quiet room was recorded by this app and by nothing else.
        // It also keeps the column full, so the list has one left edge instead
        // of a ragged one that changes as you scroll.
        appIcon.image = recording.appBundleID.flatMap(AppNames.icon) ?? AppNames.own
        // The name is not on the row, so the icon has to answer for itself.
        appIcon.toolTip = recording.appLabel ?? "Recorded in Listen"
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
        (isEmphasized ? Brand.accent
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
