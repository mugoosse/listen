import AppKit
import ListenKit

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

    /// Headers, recordings and notes in one list, because that is what the
    /// table draws. `isGroupRow` picks the headings apart.
    ///
    /// **A note is a row here only when it has no single page to live on.** A
    /// note about exactly one recording belongs to that recording and is shown
    /// with it; listing it here too would put every meeting in the library
    /// twice, once as itself and once as the note somebody wrote on it. What is
    /// left is a synthesis of several meetings, which has no one home, and a
    /// note about none, which is a page in its own right. See `pageless`.
    /// **A person is a row only while something is typed.** People have no date,
    /// so they cannot be sorted into the days the rest of the list is grouped
    /// by, and listing the whole roster above an unfiltered library would be the
    /// People tab again under another name. A search is the one moment somebody
    /// has a name in mind, which is exactly when the card is worth showing.
    private enum Row {
        /// A heading, and the lens it sets when there is one.
        ///
        /// A day heading sets nothing: "Today" is not a kind, and a lens that
        /// narrowed the library to one date is a filter nobody asked for from a
        /// control that looks like a label. Only the three kind headings are
        /// buttons, and only while no kind lens is already on, because a
        /// heading offering to show what is already shown is a control that
        /// does nothing.
        case header(String, Lens?)
        case recording(Recording)
        case note(Note)
        case person(Person)
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
        case tag(String)
        /// Recordings with a voice nobody has named. Unlike the other two this
        /// one is set from inside the list, by the row above it, because it is
        /// the only lens that is a question about the library as a whole rather
        /// than about a thing you arrived at holding.
        case unnamed
        /// Which kind of row the list may show, which is what the three
        /// segments above this used to be. See `LibraryKind`.
        case kind(LibraryKind)

        /// What this reads as on its pill.
        var title: String {
            switch self {
            case .tag(let name): return "#" + name
            case .unnamed:       return "Needs a speaker"
            case .kind(let k):   return k.label
            }
        }

        /// The pill's tooltip, which is what clicking it does rather than what
        /// it says: see `renderLenses` for why the title is not overwritten.
        var explanation: String {
            switch self {
            case .tag(let name):
                return "Only the recordings tagged #\(name). Click to drop this filter."
            case .unnamed:
                return "Only the recordings with a voice nobody has named. "
                    + "Click to drop this filter."
            case .kind(let k):
                return "Only \(k.label.lowercased()). Click to drop this filter."
            }
        }

        /// The operator that would set this, for putting a pill back into the
        /// field. Backspace at the head of an empty field is the one gesture
        /// that runs the lift backwards, and a token that cannot be re-typed is
        /// a token you can only delete.
        var typed: String {
            switch self {
            case .tag(let name):
                return name.contains(" ") ? "tag:\"\(name)\"" : "tag:" + name
            case .unnamed:     return "is:unnamed"
            case .kind(let k): return "kind:" + k.rawValue
            }
        }

        /// A stable name for `dropLens`, which only gets the button back.
        var id: String {
            switch self {
            case .tag(let name): return "tag:" + name
            case .unnamed:       return "unnamed"
            case .kind(let k):   return "kind:" + k.rawValue
            }
        }
    }

    private var lenses: [Lens] = []

    /// The kind lens, if one is on.
    private var kindLens: LibraryKind? {
        for lens in lenses { if case .kind(let k) = lens { return k } }
        return nil
    }

    /// True while the list is sectioned by kind rather than by day.
    ///
    /// **Sections are by kind while you are searching and by day while you are
    /// browsing.** Chronology is what you want from a library and kind is what
    /// you want from a result set: a search is the one moment the answer to
    /// "what sort of thing is this" outranks "when was it". It is also what
    /// gives all three kinds a heading to click, which is the whole of the
    /// discoverable route to the kind lens. With notes sorted into the days
    /// beside recordings there was exactly one heading in the list that named a
    /// kind, so the affordance could only ever have worked for People.
    ///
    /// The day each row belongs to moves into its subtitle when this is on, so
    /// nothing is lost with the heading that carried it.
    private var sectionsByKind = false

    /// The tags the magnifier's menu was last built from.
    ///
    /// `searchMenuTemplate` is copied when the menu opens rather than consulted
    /// live, so a template built once at `loadView` lists the tags that existed
    /// at launch for ever. Rebuilt from `reload` when the vocabulary has
    /// actually changed, which is rare: adding a tag to a recording.
    private var menuTags: [String] = []

    /// True while `complete(_:)` is running, so the text change it makes does
    /// not ask for a completion of the completion.
    private var completing = false

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
    /// How many recordings were waiting on a name when the magnifier's menu
    /// was last built. See `menuTags`: the menu is a template, so a count in it
    /// is frozen at the moment it was made unless something notices.
    private var menuWaiting = -1

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
    /// A note picked out of the same list. Separate from `onSelect` rather than
    /// a single callback over a sum type, because the window answers them in
    /// different panes and every other caller of `onSelect` means a recording.
    var onSelectNote: ((Note) -> Void)?
    /// A person picked out of the search results, which is the only route to
    /// the card now that the roster is not a collection you can navigate to.
    var onSelectPerson: ((Person) -> Void)?

    private(set) var selectedRecording: Recording?
    private(set) var selectedNote: Note?
    private(set) var selectedPerson: Person?
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

    /// Set while a click is moving the selection, so `rowClicked` can tell a
    /// click that opened something from a click on what was already open.
    private var selectionMoved = false

    override func loadView() {
        let container = NSView()

        searchField = NSSearchField()
        // Unscoped, and it says so. There is one list now, so the field reaches
        // everything in it: the segmented control that used to sit above this
        // and name a collection is gone, and with it the reason the placeholder
        // had to promise less than "Search".
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        // For the lift, the completion and the backspace that puts a pill back.
        // `controlTextDidChange` is the only place the field's text can be read
        // as it is typed: the `action` above fires on Return and on the search
        // field's own delay, which is far too late to take an operator out from
        // under the caret.
        searchField.delegate = self
        // The magnifier's menu, which is this app's "show search options". See
        // `buildSearchMenu`: it costs no width in a 280 point sidebar, which a
        // standing row of filter chips does.
        // Built with no count, because `loadView` runs before anything has
        // read the library. `reload` rebuilds it with one on the first pass.
        searchField.searchMenuTemplate = buildSearchMenu(tags: knownTags, waiting: 0)
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
        table.action = #selector(rowClicked)
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
            // Where the collection picker used to start: clear of the traffic
            // lights, which sit over the content because the window uses a
            // transparent full-size title bar.
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 42),
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

            scroll.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // To the bottom of the sidebar. The list used to stop at a hairline
            // above the Settings row; both are gone, so the recordings run to
            // the edge of the window the way the list in a mail app does.
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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

        // Read once and passed down, rather than derived again inside
        // `Tags.all` and again in the note rows below. The vocabulary spans
        // both kinds now, so this list is needed to parse the search field as
        // well as to build the rows.
        let everyNote = Notes.all()

        // `tag:` in the search field is a lens typed rather than clicked, so it
        // is parsed against the tags that exist: see `RecordingFilter.parse`.
        // A tag only a note carries is one of those, which is what makes
        // `tag:` over a note-only subject complete in the field at all.
        var filter = RecordingFilter.parse(
            q, knownTags: Tags.all(in: library, notes: everyNote).map(\.name))
        for lens in lenses {
            switch lens {
            case .tag(let name): filter.tags.append(name)
            case .unnamed: filter.needsSpeakers = true
            case .kind(let k): filter.kind = k
            }
        }

        let kind = filter.kind
        // A query still being typed sections the list even before it matches
        // anything, so the headings do not appear and disappear under the
        // pointer as somebody types.
        sectionsByKind = !filter.query.trimmingCharacters(in: .whitespaces).isEmpty
            || kind != nil

        let matching = kind == nil || kind == .recordings ? filter.apply(to: library) : []

        // Notes stand alongside recordings, sorted into the same days, because
        // a note is a page that happens to have no audio. Ordinarily only the
        // ones with no single page to live on: see `Row`.
        //
        // **A tag lens no longer hides notes, it filters them.** It used to,
        // and the reason it used to was that a note had no tags, so one
        // surviving a filter for "the calls tagged #kinsight" would have been a
        // row the filter did not consider rather than one it kept. A note
        // carries tags now, so hiding a note that is filed under #kinsight from
        // the answer to "what is filed under #kinsight" would be the wrong
        // answer rather than the tidier one.
        //
        // **`pageless` only earns its keep while recordings are in the list
        // too.** It exists so a meeting and the note about that one meeting are
        // not two rows saying the same thing, which is a rule about a list of
        // everything and about nothing else.
        //
        // Two lists are not that, and both were hiding notes with nothing on
        // screen to say so:
        //
        // - **The Notes collection.** `kind:notes` puts no recordings in the
        //   list at all, so there is nothing for a note to double up with, and
        //   yet every note about exactly one meeting was dropped from it. On a
        //   real library that is most of them: a list called Notes showed five
        //   of fourteen and looked like a library with almost no notes in it.
        // - **A tag lens.** The list is then not everything, it is what
        //   matches, and dropping a match because it also has a home elsewhere
        //   is a wrong answer rather than a tidier one. That reverses the rule
        //   this comment used to carry, which was right only while a note had
        //   no tags to match on.
        //
        // Either way the row's second line already names the meeting it belongs
        // to, so a reader can see why it is there.
        //
        // `is:unnamed` still hides notes entirely, and that half of the old rule
        // stands: a note has no speakers for that question to be about.
        //
        // `lenses` is not consulted any more. `filter` already carries both the
        // typed operators and the clicked lenses, which is what the loop above
        // is for, and reading the two separately was how a typed `tag:` and a
        // clicked one could behave differently.
        let listingRecordings = kind == nil || kind == .recordings
        let mayDoubleUp = listingRecordings && filter.tags.isEmpty
        let noteRows = !filter.needsSpeakers && (kind == nil || kind == .notes)
            ? everyNote.filter {
                (Self.pageless($0) || !mayDoubleUp)
                    && Self.matches($0, query: filter.query, tags: filter.tags)
              }
            : []

        var items: [(date: Date?, row: Row)] =
            matching.map { ($0.date, Row.recording($0)) }
            + noteRows.map { ($0.date, Row.note($0)) }
        // A missing or unparseable date sinks to the bottom, which is where
        // `heading(for:)` already files it under "Earlier".
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        // The recording being made now is never filtered out, and never sorted
        // either. A search left in the field from ten minutes ago is not a
        // reason to hide the meeting being recorded now, and neither is a lens
        // it cannot match: a recording still being made has no transcript to
        // have speakers in, and its tags are the ones somebody is about to add.
        // Pinned to the top rather than trusted to sort there, because a note
        // written in the last minute would otherwise sit above it.
        if let live { items.insert((live.date, .recording(live)), at: 0) }

        // The magnifier lists the tags that exist and how much labelling is
        // outstanding, so it is rebuilt when either changes. See `menuTags`.
        let tags = Tags.all(in: library, notes: everyNote).map(\.name)
        let waiting = waitingCount(in: library)
        if tags != menuTags || waiting != menuWaiting {
            searchField.searchMenuTemplate = buildSearchMenu(tags: tags, waiting: waiting)
        }

        rows = []

        // People first, under their own heading, and never mixed into the days.
        //
        // A person has no date, so there is no honest place for them in a
        // chronological list; sorting them in by relevance instead would put a
        // card between two meetings and make the whole list's order a guess.
        // One section above the library says what they are and leaves the rest
        // of the list meaning exactly what it meant before anybody typed.
        let people = matchingPeople(filter.query, needsSpeakers: filter.needsSpeakers,
                                    kind: kind, in: library)
        if !people.isEmpty {
            // Singular when there is one, and it is still the kind's heading:
            // the lens it sets is People either way.
            rows.append(.header(people.count == 1 ? "Person" : "People",
                                offer(.kind(.people), unless: kind)))
            rows.append(contentsOf: people.map { Row.person($0) })
        }

        guard !sectionsByKind else {
            // Searching: one heading per kind, in the order somebody reads them
            // in. People are already above; notes before recordings because
            // there are far fewer of them and a section that scrolls off the
            // bottom is a section nobody knows is there.
            let notes = items.compactMap { item -> Row? in
                if case .note = item.row { return item.row }
                return nil
            }
            if !notes.isEmpty {
                rows.append(.header("Notes", offer(.kind(.notes), unless: kind)))
                rows.append(contentsOf: notes)
            }
            let recordings = items.compactMap { item -> Row? in
                if case .recording = item.row { return item.row }
                return nil
            }
            if !recordings.isEmpty {
                rows.append(.header("Recordings", offer(.kind(.recordings), unless: kind)))
                rows.append(contentsOf: recordings)
            }
            finishReload(keepID: keepID)
            return
        }

        var lastHeading: String?
        for item in items {
            let heading = Self.heading(for: item.date)
            if heading != lastHeading {
                rows.append(.header(heading, nil))
                lastHeading = heading
            }
            rows.append(item.row)
        }

        finishReload(keepID: keepID)
    }

    /// A heading's lens, or nil when that lens is already on.
    ///
    /// A heading offering to show what is already shown is a control that does
    /// nothing, and the pill above the list is what turns it back off.
    private func offer(_ lens: Lens, unless current: LibraryKind?) -> Lens? {
        current == nil ? lens : nil
    }

    /// Draw the rows and put the selection back on whatever the pane is showing.
    ///
    /// Split out of `reload` when the list gained a second way to be assembled.
    /// Two copies of the three-way "keep what is open" rule is two places for
    /// the next kind of row to be forgotten, and this is the half that decides
    /// whether a rename silences the recording being renamed.
    private func finishReload(keepID: String?) {
        reloading = true
        table.reloadData()

        // A selected person is kept the same way, and first for the same
        // reason: whichever of the three is set is the one the pane is showing.
        //
        // Their row is the one that can stop existing without them being
        // deleted, because it is only in this list while a query names them.
        // Whether it survived decides nothing about the card: `selectedPerson`
        // is what the pane and the menu read, and it stays set either way. See
        // `deselect`, which is the half of this that used to be missing.
        if let keepLabel = selectedPerson?.label, let row = rows.firstIndex(where: {
            if case .person(let p) = $0 { return p.label == keepLabel }
            return false
        }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if case .person(let fresh) = rows[row] { selectedPerson = fresh }
            reloading = false
            return
        }

        // A selected note is kept the same way and for the same reason, and
        // first because the two are mutually exclusive: whichever one is set is
        // the one the pane is showing.
        if let keepSlug = selectedNote?.slug, let row = rows.firstIndex(where: {
            if case .note(let n) = $0 { return n.slug == keepSlug }
            return false
        }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            if case .note(let fresh) = rows[row] { selectedNote = fresh }
            reloading = false
            return
        }

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

    /// Who the query names, as cards for the top of the results.
    ///
    /// Two sources, because the roster and the contact book answer different
    /// halves of "who is this". `People.roster` knows everybody with a voice in
    /// the library; `ContactBook` knows the ones the user has named but who have
    /// not been recorded yet, and a card that only appeared once somebody had
    /// been in a meeting would be missing exactly when it is most useful. This
    /// is the pairing `listen people <name>` already makes.
    ///
    /// **`contains`, not `SpeakerName.matches`.** That rule is case-insensitive
    /// equality, which is right for a filter naming somebody exactly and wrong
    /// for a field somebody is still typing into: "marc" would find nobody and
    /// read as "no such person" rather than as "keep going".
    ///
    /// Empty while nothing is typed, and empty while a tag or the unnamed lens
    /// is on: both are claims about which recordings are interesting, and a
    /// person card is not one of them.
    ///
    /// **`kind:people` is the exception, and it lists the whole roster.** This
    /// reverses the rule written above `Row`, which was that listing everybody
    /// over an unfiltered library would be the People tab under another name.
    /// That objection was to the roster appearing *unasked*: with a People pill
    /// visibly on the row above and one click from off, it is a filtered view
    /// somebody requested rather than the default state of the window. Without
    /// the reversal, deleting the People collection would take with it the only
    /// way to browse the people you cannot already name, which is exactly the
    /// case a roster is for.
    private func matchingPeople(_ query: String, needsSpeakers: Bool,
                                kind: LibraryKind?, in library: [Recording]) -> [Person] {
        guard !needsSpeakers, kind == nil || kind == .people else { return [] }
        // A tag lens is still disqualifying: no tag says anything about a
        // person, so a card surviving one would be a row the filter did not
        // consider.
        guard !lenses.contains(where: { if case .kind = $0 { return false }
                                        return true }) else { return [] }

        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty || kind == .people else { return [] }

        var found = People.roster(in: library).filter {
            wanted.isEmpty || $0.display.localizedCaseInsensitiveContains(wanted)
        }
        // Nothing typed means the whole roster, which `People.roster` has
        // already folded the contact book into and sorted. Asking
        // `ContactBook.matching("")` here as well would append the entire
        // address book a second time, because an empty query matches every
        // contact rather than none.
        guard !wanted.isEmpty else { return found }

        // A contact with no recordings, appended rather than merged: anybody the
        // roster already knows is there with their real counts, and `Person.summary`
        // says "no recordings yet" for the rest.
        let known = Set(found.map { $0.display.lowercased() })
        for contact in ContactBook.matching(wanted)
        where !known.contains(contact.name.lowercased()) {
            found.append(Person(label: contact.name, recordings: [], seconds: 0))
        }
        return found
    }

    /// Does this note have no single recording to be shown on?
    ///
    /// Exactly one source means it belongs to that page. Zero means it is a
    /// page itself, and two or more means it is a synthesis with no one home,
    /// which is the case the library-level note store exists for.
    private static func pageless(_ note: Note) -> Bool { note.recordings.count != 1 }

    /// Free text and tags against a note, ANDed.
    ///
    /// `RecordingFilter` is still not reused, and the reason has changed. It
    /// used to be that a note had nothing for its predicates to test; now it is
    /// the shape. `apply(to:)` is a function over a *list* rather than a
    /// per-item predicate because `person` and `query` read every `turns.json`
    /// and the cheap fields have to run first, and only something seeing the
    /// whole list can arrange that. A note has nothing expensive to defer, so
    /// that machinery would buy nothing here.
    ///
    /// What the two do share is the parser and `Tags.matches`, which is where
    /// they could actually come apart, and neither is duplicated.
    ///
    /// Free text stays title and body. Typing `job hunt` should not surface a
    /// note because it is *filed* under it; `tag:job hunt` is how that question
    /// is asked, and the field turns it into a lens.
    private static func matches(_ note: Note, query: String, tags: [String]) -> Bool {
        guard note.carries(tags) else { return false }
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return true }
        return note.title.localizedCaseInsensitiveContains(wanted)
            || note.body.localizedCaseInsensitiveContains(wanted)
    }

    /// Internal rather than private: `ChatNav` files conversations under the
    /// same days, and two copies of "Today, Yesterday, then the weekday for a
    /// week and the date after that" would be two lists that agree until one of
    /// those three numbers is changed.
    static func heading(for date: Date?) -> String {
        guard let date else { return "Earlier" }
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

    /// How many recordings are waiting on a name.
    ///
    /// Counted from the **unfiltered** library, so the number is about the
    /// library rather than about whatever is on screen: one that moved with the
    /// search would read as zero the moment somebody typed.
    ///
    /// Cheap enough to ask on every reload. `Labelling.waits` is answered from
    /// a cache keyed on each `turns.json` stamp, which is why the lens is
    /// ordered first among the three predicates that read transcripts.
    private func waitingCount(in library: [Recording]) -> Int {
        Labelling.waiting(in: library).count
    }

    @objc private func showUnnamed() {
        filter(byUnnamedSpeakers: true)
    }

    /// A section heading was clicked, so narrow the list to that kind.
    ///
    /// The identifier carries the lens rather than a closure per row, because
    /// the header views are made and thrown away by the table on every reload
    /// and a captured lens would outlive the row it was made for.
    @objc private func headerClicked(_ sender: NSView) {
        guard let id = sender.identifier?.rawValue,
              let kind = LibraryKind.allCases.first(where: { "kind:" + $0.rawValue == id })
        else { return }
        add(.kind(kind))
    }

    /// Show only one kind of row, from outside the list.
    ///
    /// The route the People menu item takes now that the roster is not a
    /// collection to navigate to.
    func filter(byKind kind: LibraryKind) {
        add(.kind(kind))
    }

    /// Open somebody's card, with the list saying why it looks like that.
    ///
    /// **The one arrival that replaces the People collection.** A chip's menu
    /// used to swap the whole sidebar for a roster behind a tab strip, which is
    /// a screen with nothing on it explaining how you got there and a Notes tab
    /// one click away that had nothing to do with the question. This types the
    /// name into the field instead, so the reason the list has changed is the
    /// first thing on it, and the way back is the ✕ the field already has.
    ///
    /// The name and not a `kind:people` lens, because the question a chip asks
    /// is "who is this", not "show me everybody". The recordings they are in
    /// come up under it, which is the other half of that question.
    func reveal(person: Person) {
        loadViewIfNeeded()
        lenses = []
        let name = person.display
        searchField.stringValue = name
        query = name
        // Set before the reload, so `finishReload` puts the selection back on
        // them the way it does for a person whose row survived a reload.
        selectedPerson = person
        selectedRecording = nil
        selectedNote = nil
        renderLenses()
        if let row = rows.firstIndex(where: {
            if case .person(let p) = $0 { return p.label == person.label }
            return false
        }) {
            table.scrollRowToVisible(row)
        }
        // Explicitly, because the selection above was made with `reloading`
        // set: that is what stops a rebuild being reported as somebody choosing
        // a row, and this arrival really is a choice.
        onSelectPerson?(person)
    }

    /// Also show only the recordings with somebody unnamed in them.
    func filter(byUnnamedSpeakers on: Bool) {
        add(on ? .unnamed : nil)
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
        guard insert(next) else { return }
        renderLenses()
    }

    /// Put a lens in the list without redrawing anything.
    ///
    /// Split out for the lift, which can take three operators out of the field
    /// in one keystroke: `add` renders and reloads on each call, so a paste of
    /// `kind:notes tag:kinsight` rebuilt the whole library list twice to show
    /// one row of pills.
    @discardableResult
    private func insert(_ next: Lens) -> Bool {
        guard !lenses.contains(next) else { return false }
        // **Two kind lenses cannot stack.** Every other lens here is ANDed, and
        // ANDing "only people" with "only notes" is a list that is empty by
        // construction rather than because nothing matched. So a second kind
        // replaces the first, which is also what somebody clicking a second
        // heading means.
        if case .kind = next {
            lenses.removeAll { if case .kind = $0 { return true }; return false }
        }
        lenses.append(next)
        return true
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

            // The neutral wash, for every one of them. A tag is not somebody, a
            // state of the library is not somebody, and neither is a kind of
            // row, so borrowing a person's colour would be the one token on
            // screen whose colour means nothing. `Lens` owns the words: three
            // switches over the same enum in three functions is three places
            // for the fourth case to be forgotten.
            pill.showPlain(lens.title)
            pill.identifier = NSUserInterfaceItemIdentifier(lens.id)
            pill.toolTip = lens.explanation
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
        lenses.removeAll { $0.id == id }
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
        cell.configure(recording, dated: sectionsByKind)
    }

    /// Is anything open, whatever kind it is?
    var hasSelection: Bool {
        selectedRecording != nil || selectedNote != nil || selectedPerson != nil
    }

    /// Put the open page away and give the pane back to the composer.
    ///
    /// `deselectAll` posts the selection notification, which is what carries
    /// the nil onwards, so that path does not report it a second time.
    ///
    /// **What is open and what is selected are two different questions, and
    /// only the second one is the table's.** A person is the one page that can
    /// be open with no row behind it: their row exists only while a query names
    /// them, so opening a card from the search results and then clearing the
    /// field rebuilds the list without it. `deselectAll` on an empty selection
    /// changes nothing, so it posts nothing, so Close did nothing at all on the
    /// screen it is the only way off. Measured on the shipped build: the card
    /// stayed up and the menu went on offering Close.
    func deselect() {
        loadViewIfNeeded()
        guard hasSelection else { return }
        guard table.selectedRow >= 0 else {
            selectedRecording = nil
            selectedNote = nil
            selectedPerson = nil
            onSelect?(nil)
            return
        }
        table.deselectAll(nil)
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Actions

    @objc private func searchChanged() {
        // Return, and the search field's own delay. `controlTextDidChange` has
        // usually run first and left `query` correct already; this is what
        // catches a value the lift is holding, which is the whole point of
        // Return being the other way to finish one. See `liftOperators`.
        liftOperators(finishing: true)
        query = searchField.stringValue
        reload()
    }

    // MARK: - Operators in the field

    /// Take any finished operator out of the field and make it a pill.
    ///
    /// **The field holds free text and the row below it holds operators, and
    /// nothing is ever in both.** The pill row already exists as *the* place
    /// that says this list is not the whole library, so leaving `tag:kinsight`
    /// sitting in the field would state the same fact twice, in two places that
    /// can disagree. That is Drive's choice rather than Gmail's, and here it is
    /// forced by a control that was already on screen.
    ///
    /// Finished means followed by a space, except when the value could still
    /// grow: see `RecordingFilter.isUnfinished` for the `tag:job ` trap and why
    /// this waits. `finishing` is Return, which says to take the value as typed
    /// however incomplete it looks.
    ///
    /// Returns true when something moved, so the caller knows the field's text
    /// has been rewritten under the caret.
    @discardableResult
    private func liftOperators(finishing: Bool = false) -> Bool {
        let text = searchField.stringValue
        guard finishing || text.last?.isWhitespace == true else { return false }
        let known = knownTags
        guard finishing || !RecordingFilter.isUnfinished(text, knownTags: known)
        else { return false }

        let parsed = RecordingFilter.parse(text, knownTags: known)
        var moved = false
        if let kind = parsed.kind { moved = insert(.kind(kind)) || moved }
        if parsed.needsSpeakers { moved = insert(.unnamed) || moved }
        for tag in parsed.tags { moved = insert(.tag(tag)) || moved }
        // Nothing to lift, or every operator typed was one already on: either
        // way the words have to come out of the field, or `tag:kinsight` stays
        // in it as a search term matching no title in the library.
        guard parsed.kind != nil || parsed.needsSpeakers || !parsed.tags.isEmpty
        else { return false }

        searchField.stringValue = parsed.query
        query = parsed.query
        // The caret goes to the end of what is left, which is where it was.
        searchField.currentEditor()?
            .selectedRange = NSRange(location: (parsed.query as NSString).length, length: 0)
        if moved { renderLenses() } else { reload() }
        return true
    }

    /// The tag vocabulary, which both the parser and the completion read.
    ///
    /// Both lists, because a tag only a note carries is one somebody can type.
    /// This is read per keystroke while a `tag:` is being finished, so it walks
    /// the notes directory as well as the recordings now. It is the same order
    /// of work as the transcript search already on that path, and the
    /// alternative is a cache with nothing to invalidate it.
    private var knownTags: [String] { Tags.all().map(\.name) }

    /// What the magnifier offers, which is this window's "show search options".
    ///
    /// **A menu rather than a row of chips under the field.** Gmail has a full
    /// advanced-search sheet and Drive keeps a standing row of chips; at 280
    /// points, with a to-do row and the meeting being recorded already
    /// competing for the top of the list, a form is the wrong shape and a
    /// permanent chip row is the wrong width. This costs no pixels at all and
    /// is the control macOS users already expect the magnifier to have.
    ///
    /// **Every item names the operator it writes.** That is the one thing
    /// Gmail's advanced form gets right and its chips do not: using the form
    /// composes the query string in the box, so the discoverable route teaches
    /// the typed one instead of being a parallel way to do the same thing.
    private func buildSearchMenu(tags: [String], waiting: Int) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(Self.caption("Show only"))
        for kind in LibraryKind.allCases {
            menu.addItem(Self.option(kind.label, "kind:" + kind.rawValue,
                                     target: self, action: #selector(pickKind(_:)),
                                     represented: kind.rawValue))
        }
        menu.addItem(.separator())
        menu.addItem(Self.caption("Narrow by"))
        // **The count is here and nowhere else.** A row above the list used to
        // carry it, and it was removed on request: some voices are never going
        // to be named, so a permanent "5 recordings need a speaker" is a
        // standing claim of outstanding work that will never reach zero, which
        // is the definition of a nag rather than a to-do list. The number is
        // still worth having, so it moved to the one place you only see by
        // going to look. Absent entirely at zero, so an empty count is never
        // printed.
        menu.addItem(Self.option(waiting > 0 ? "Needs a speaker  (\(waiting))"
                                             : "Needs a speaker",
                                 "is:unnamed",
                                 target: self, action: #selector(showUnnamed)))
        if !tags.isEmpty {
            for name in tags.prefix(Self.menuTagLimit) {
                let typed = name.contains(" ") ? "tag:\"\(name)\"" : "tag:" + name
                menu.addItem(Self.option("#" + name, typed,
                                         target: self, action: #selector(pickTag(_:)),
                                         represented: name))
            }
        }
        menuTags = tags
        menuWaiting = waiting
        return menu
    }

    /// How many tags the magnifier lists before it stops.
    ///
    /// The menu is a way in, not the tag list: `tag:` in the field completes
    /// against every one of them, and a menu long enough to scroll is a menu
    /// nobody reads to the bottom of. Eight is what fits under the field
    /// without the menu reaching the middle of the window at the height this
    /// sidebar runs at.
    private static let menuTagLimit = 8

    private static func caption(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// One row of the magnifier's menu: what it does on the left, what it types
    /// on the right, in the monospaced face an operator is read in.
    private static func option(_ title: String, _ typed: String,
                               target: AnyObject, action: Selector,
                               represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.representedObject = represented
        let line = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        line.append(NSAttributedString(
            string: "   " + typed,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = line
        return item
    }

    @objc private func pickKind(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = LibraryKind(rawValue: raw) else { return }
        add(.kind(kind))
    }

    @objc private func pickTag(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        add(.tag(name))
    }

    /// A click on the row that is already open closes it.
    ///
    /// The table's `action` fires on every click, including one that changed
    /// nothing, which is the only way to hear about a click on an already
    /// selected row: `tableViewSelectionDidChange` by definition does not fire
    /// when the selection did not change.
    ///
    /// `selectionMoved` is what tells the two apart. Clicking a *different* row
    /// changes the selection first and then arrives here, and closing the page
    /// somebody has just opened is the opposite of what they asked for.
    @objc private func rowClicked() {
        defer { selectionMoved = false }
        guard !selectionMoved, table.clickedRow >= 0,
              table.clickedRow == table.selectedRow else { return }
        deselect()
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
        case .header(let title, let lens):
            guard let lens else {
                let label = NSTextField(labelWithString: title)
                label.font = SectionHeader.font
                label.textColor = .secondaryLabelColor
                let holder = NSView()
                label.translatesAutoresizingMaskIntoConstraints = false
                holder.addSubview(label)
                NSLayoutConstraint.activate([
                    // Level with the icon column below it, not four points
                    // inside it. A day heading, an app icon and New Recording's
                    // dot now share one edge, and every title in the list
                    // shares the next.
                    label.leadingAnchor.constraint(equalTo: holder.leadingAnchor,
                                                   constant: RecordingCell.textInset),
                    label.bottomAnchor.constraint(equalTo: holder.bottomAnchor,
                                                  constant: -4),
                ])
                return holder
            }
            let header = SectionHeader(title: title, target: self,
                                       action: #selector(headerClicked(_:)))
            header.identifier = NSUserInterfaceItemIdentifier(lens.id)
            return header

        case .recording(let recording):
            let cell = RecordingCell()
            cell.configure(recording, dated: sectionsByKind)
            return cell

        case .note(let note):
            // `NoteCell`, the same class the Notes collection drew, rather than
            // a second cell shaped to match it. Same argument as the lens pill
            // being a `SpeakerPill`: a note in this list is the same object it
            // always was, so it should be drawn by the same code and not by a
            // copy of its numbers that can go out of step.
            // No `dated:` here, unlike the recording above it: `NoteCell`
            // already prints the note's date on every row, because the Notes
            // collection it was written for had no day headings to carry one.
            let cell = NoteCell()
            cell.configure(note)
            return cell

        case .person(let person):
            // `PersonCell`, the roster's own, for `NoteCell`'s reason: the card
            // in the results is the same card, not a copy of it, so the disc of
            // initials keeps the colour that person has everywhere else.
            let cell = PersonCell()
            cell.configure(person)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Not while `reload` is putting the selection back where it was: that
        // is the list being rebuilt, not somebody choosing a recording. See
        // `reloading`.
        guard !reloading else { return }
        selectionMoved = true
        guard rows.indices.contains(table.selectedRow) else {
            selectedRecording = nil
            selectedNote = nil
            selectedPerson = nil
            onSelect?(nil)
            return
        }
        switch rows[table.selectedRow] {
        case .recording(let recording):
            selectedNote = nil
            selectedPerson = nil
            selectedRecording = recording
            onSelect?(recording)
        case .person(let person):
            selectedRecording = nil
            selectedNote = nil
            selectedPerson = person
            onSelectPerson?(person)
        case .note(let note):
            // The recording goes first. Everything that validates a menu item
            // or a toolbar button asks `selectedRecording`, and a note selected
            // while that still held the last meeting would leave Export and
            // Transcribe Again enabled over something they cannot act on.
            selectedRecording = nil
            selectedPerson = nil
            selectedNote = note
            onSelectNote?(note)
        case .header:
            selectedRecording = nil
            selectedNote = nil
            selectedPerson = nil
            onSelect?(nil)
        }
    }
}

// MARK: - Row menu

// MARK: - The search field

/// Typing an operator, and the two gestures that run it backwards.
///
/// The field is the only place any of this can be done, because
/// `NSSearchField`'s `action` fires on Return and on its own delay: far too
/// late to take an operator out from under a caret that has moved on.
extension SidebarViewController: NSSearchFieldDelegate {
    func controlTextDidChange(_ note: Notification) {
        // The completion inserts text, which arrives back here. Without this
        // the insertion asks to complete the thing it has just completed.
        guard !completing else { return }
        // Lift first: it rewrites the field, and `query` has to be what is left
        // rather than what was typed.
        guard !liftOperators() else { return }
        query = searchField.stringValue
        reload()
        offerCompletion()
    }

    /// Backspace at the head of the field puts the last pill back as text.
    ///
    /// **The half that stops the lift feeling like a fight.** Without it a
    /// token can only be dismissed, so a mistyped tag means clicking the pill
    /// and typing the whole operator again, and the field appears to eat what
    /// you wrote. This is the same gesture every token field on this platform
    /// has, and `Lens.typed` is what makes it possible: a pill that cannot be
    /// written back is a pill you can only delete.
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.deleteBackward(_:)),
              textView.selectedRange() == NSRange(location: 0, length: 0),
              let last = lenses.last
        else { return false }

        lenses.removeLast()
        let restored = last.typed
        let text = query.isEmpty ? restored : restored + " " + query
        searchField.stringValue = text
        query = text
        // The caret lands at the end of what came back, not at the end of the
        // line: what you are about to edit is the operator, and the words after
        // it were already where you wanted them.
        textView.selectedRange = NSRange(location: (restored as NSString).length, length: 0)
        renderLenses()
        return true
    }

    /// What `tag:` and `kind:` complete to.
    ///
    /// The candidates are the vocabulary the parser reads back, deliberately:
    /// a completion offering a word `RecordingFilter.parse` does not know is a
    /// filter that appears to work and quietly searches for its own name.
    ///
    /// Nothing is preselected. `complete(_:)` inserts the selected candidate as
    /// it opens the list, so a default selection types over the value somebody
    /// is halfway through, which is exactly the behaviour the lift already had
    /// to be taught not to do.
    func control(_ control: NSControl, textView: NSTextView, completions words: [String],
                 forPartialWordRange charRange: NSRange,
                 indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
        index.pointee = -1
        guard let context = completionContext(in: textView.string, at: charRange)
        else { return [] }
        let typed = (textView.string as NSString).substring(with: charRange).lowercased()
        let wanted = (context.stem + typed).lowercased()
        return context.candidates
            .filter { $0.lowercased().hasPrefix(wanted) }
            // Only the part that is not already on screen: the range being
            // replaced is the partial word, not the whole operand, so returning
            // the full value writes the stem twice.
            .map { String($0.dropFirst(context.stem.count)) }
    }

    /// Which operator the caret is inside, and what has already been typed of
    /// its value before the range about to be replaced.
    private struct Completion {
        let candidates: [String]
        /// The part of the value before `charRange`, which a multi-word tag can
        /// have and a kind cannot.
        let stem: String
    }

    private func completionContext(in text: String, at range: NSRange) -> Completion? {
        let ns = text as NSString
        guard range.location <= ns.length else { return nil }
        let before = ns.substring(to: range.location)

        // `kind:` and `is:` take one word, so the operator has to be right
        // here. `unnamed` is on the list because `is:unnamed` is the typed form
        // of the lens the to-do row sets, and somebody who has seen the pill is
        // owed a way to type it.
        let low = before.lowercased()
        if low.hasSuffix("kind:") || low.hasSuffix("is:") {
            return Completion(candidates: LibraryKind.allCases.map(\.rawValue) + ["unnamed"],
                              stem: "")
        }

        // A tag value can contain spaces, so its operator may be several words
        // back. `trailingTagValue` is the parser's own idea of where it starts,
        // which is what keeps the completion and the parse agreeing.
        guard let stem = RecordingFilter.trailingTagValue(before) else { return nil }
        return Completion(candidates: knownTags, stem: stem)
    }

    /// Offer a completion, but only inside an operator.
    ///
    /// Calling `complete(_:)` on every keystroke would put a list under every
    /// word somebody searches for, which is a spell-checker rather than a
    /// filter.
    private func offerCompletion() {
        guard let editor = searchField.currentEditor() as? NSTextView else { return }
        let range = editor.rangeForUserCompletion
        guard range.location != NSNotFound,
              completionContext(in: editor.string, at: range) != nil else { return }
        completing = true
        editor.complete(nil)
        completing = false
    }
}

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Right-clicking a row selects it first, so the menu and the toolbar
        // menu always act on the same thing.
        //
        // **Any row, not just a recording.** It used to select only those, from
        // when they were the only kind here, and a right-click on a note row
        // left the selection on whatever meeting was open: the menu that came up
        // was that meeting's, with its red Delete in it, over a note. The one
        // list made that reachable, so the rule is now the same one the table
        // itself uses for a left-click, which is every row that is not a day
        // heading.
        let clicked = table.clickedRow
        if rows.indices.contains(clicked), tableView(table, shouldSelectRow: clicked) {
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
    private let activityBar = BrandProgressBar()
    private var activityTop: NSLayoutConstraint!
    private var activityHeight: NSLayoutConstraint!

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
    /// **The 22 points these add up to were measured against three rows that
    /// no longer exist**, and the number outlived all of them: New Recording,
    /// Settings and the to-do row each put an icon 22 points in, and this cell
    /// lines its app icon up with where they were. Measured off the screen
    /// while they were still there, in points from the same edge: icon ink at
    /// 33 (New Recording), 32 (Settings, a narrower glyph in the same box) and
    /// 34 (an app icon, which fills its box); text ink at 56 and 58. What is
    /// left is the glyphs' own side bearings.
    ///
    /// A cell that reserves the same 16 and then uses a gap of its own
    /// invention lands two points off every other label in the list, which is
    /// the width that reads as a mistake rather than as a margin. So: same
    /// icon, same gap, one column.
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
        activityBar.isHidden = true

        for v in [title, subtitle, appIcon, activityBar] as [NSView] {
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

        activityTop = activityBar.topAnchor.constraint(equalTo: subtitle.bottomAnchor)
        activityHeight = activityBar.heightAnchor.constraint(equalToConstant: 0)

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

            activityTop,
            activityHeight,
            activityBar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            activityBar.trailingAnchor.constraint(equalTo: title.trailingAnchor),

            block.topAnchor.constraint(equalTo: title.topAnchor),
            block.bottomAnchor.constraint(equalTo: activityBar.bottomAnchor),
            block.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `dated` prints the day on the row, for when the heading above it names
    /// a kind rather than a day. See `SidebarViewController.sectionsByKind`.
    func configure(_ recording: Recording, dated: Bool = false) {
        title.stringValue = recording.displayTitle
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
        appIcon.image = NSImage(contentsOf: recording.sourceIconURL)
            ?? recording.appBundleID.flatMap(AppNames.icon) ?? AppNames.own
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
        // The clock and the length give way while this row is the job being
        // transcribed. The stage sentence is the information of the moment,
        // the two facts are stable and come back with the reload that ends the
        // job, and together they pushed the percentage off the line at the
        // widths this sidebar actually runs at.
        let transcribingHere = Queue.shared.running == recording.id
        // The day comes back onto the row when the list is sectioned by kind,
        // because then there is no day heading above it carrying it. Leading,
        // where the heading was, so a row reads the same way round either way.
        let day = dated ? SidebarViewController.heading(for: recording.date) : ""
        let facts = transcribingHere ? ""
            : [day, recording.clockTime, length].filter { !$0.isEmpty }
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
        //
        // The paragraph style travels too, and losing it is worse than losing
        // the font: the field's own `.byTruncatingTail` is replaced by the
        // string's default, which wraps. The row is 52 points whatever its
        // content wants, so a subtitle long enough to wrap put its second line
        // and the activity bar under it over the card's bottom edge.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        func run(_ text: String, _ colour: NSColor) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.foregroundColor: colour,
                                                          .font: Self.subtitleFont,
                                                          .paragraphStyle: style])
        }
        let line = NSMutableAttributedString(attributedString: run(facts, .secondaryLabelColor))
        if !state.isEmpty {
            if !facts.isEmpty { line.append(run(" · ", .secondaryLabelColor)) }
            line.append(run(state, live ? .systemRed : .secondaryLabelColor))
        }
        // On the row, not only in the pane, and by the same argument the state
        // word is coloured: a recording missing half of what was said is not a
        // fact you should have to select it to find out. This is the surface
        // somebody scrolls past a week later looking for the call they half
        // remember, and a row that looks like every other row is how an hour
        // stays lost.
        if recording.micWasSilent {
            if line.length > 0 { line.append(run(" · ", .secondaryLabelColor)) }
            line.append(run("your mic caught nothing", .systemOrange))
        }
        subtitle.attributedStringValue = line

        let active: CloudActivity?
        if Queue.shared.running == recording.id {
            active = CloudActivity(
                recordingID: recording.id, stage: .transcribing,
                fraction: Queue.shared.progress?.overall,
                detail: Queue.shared.progress?.message)
        } else {
            active = CloudSyncHost.shared.activity(for: recording.id)
        }
        if let active, active.stage != .ready,
           active.fraction != nil || active.isMoving {
            activityBar.isHidden = false
            activityTop.constant = 3
            activityHeight.constant = 2
            activityBar.setAccessibilityLabel(active.title)
            activityBar.setAccessibilityValue(active.percentage ?? "In progress")
            if let fraction = active.fraction {
                activityBar.fraction = fraction
            } else {
                activityBar.fraction = nil
            }
        } else {
            activityBar.fraction = nil
            activityBar.isHidden = true
            activityTop.constant = 0
            activityHeight.constant = 0
        }
        // The reason rides the row as a tool tip. Two points of activity bar
        // cannot say "your iCloud storage is full", and thanks to
        // `SyncTrouble` the detail is a sentence rather than CloudKit's
        // phrasing. Cleared otherwise, so a recycled row does not carry the
        // previous recording's trouble.
        toolTip = (active?.stage == .retrying || active?.isFailure == true)
            ? active?.detail : nil
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

/// A section heading that is also the control that narrows the list to it.
///
/// **The heading is the chip.** Gmail and Drive grow a row of filter chips
/// under the search box because a mail list has no sections to hang them on;
/// this list has three, so the affordance is already on screen and needs no new
/// chrome in a 280 point column. Click "People" and the list becomes people,
/// with a pill above it saying so.
///
/// The hint only appears under the pointer. A heading that permanently
/// advertises what clicking it does is a row of instructions down the side of
/// the window, and the heading's first job is still to say what the rows under
/// it are.
///
/// **Unlike `HoverRow` this one answers to accessibility.**
/// Those two are plain views with a target and an action, so no automation and
/// no screen reader can press them, which is a real gap and not just a testing
/// one. There is no reason to add a third: the role, the title and the press
/// are four lines.
@MainActor
final class SectionHeader: NSView {
    static let font = NSFont.systemFont(ofSize: 12, weight: .semibold)

    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Only these")
    private weak var target: AnyObject?
    private let action: Selector

    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            hint.isHidden = !hovering
            restyle()
        }
    }

    init(title: String, target: AnyObject?, action: Selector) {
        self.target = target
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = Self.font
        label.textColor = .secondaryLabelColor

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Brand.accent
        hint.isHidden = true
        // Or a long heading pushes it off the edge instead of truncating
        // itself, which is the way round the sidebar's titles already work.
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [label, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // The same edge as a day heading, so the two do not appear to be
            // indented differently when a search swaps one set for the other.
            label.leadingAnchor.constraint(equalTo: leadingAnchor,
                                           constant: RecordingCell.textInset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            hint.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor,
                                           constant: -RecordingCell.textInset),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor,
                                          constant: 8),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp("Show only \(title.lowercased()).")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityPerformPress() -> Bool {
        NSApp.sendAction(action, to: target, from: self)
        return true
    }

    /// The heading is one control, not a control containing two labels.
    ///
    /// Measured through the accessibility tree: a section read "Person,
    /// Person, Person", once for the table's own cell wrapper, once for this
    /// view and once for the field inside it. `setAccessibilityElement(false)`
    /// on the fields does not do it, because `NSTextField` answers that
    /// question itself; emptying the children is what removes them.
    override func accessibilityChildren() -> [Any]? { [] }

    private func restyle() {
        layer?.backgroundColor = hovering ? hoverTint(0.10).cgColor : NSColor.clear.cgColor
    }

    /// A `CGColor` is a snapshot of what it was resolved from, so switching the
    /// Mac between light and dark leaves the last one painted.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    /// Swallow the press so the table underneath does not treat it as a click
    /// on the list. `shouldSelectRow` already refuses the selection; this stops
    /// `rowClicked` seeing a click that closed the open page.
    override func mouseDown(with event: NSEvent) {}
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
