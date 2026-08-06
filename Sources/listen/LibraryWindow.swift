import AVFoundation
import AppKit

/// The main window: recordings on the left, the selected one on the right.
///
/// Apple Notes shape. The visual register to match is Anarlog and Granola:
/// light, calm, generous whitespace, content first.
///
/// Built on `NSSplitViewController`, not a bare `NSSplitView`. The first
/// version used the latter with `widthAnchor` constraints on each side, and
/// dragging the divider snapped straight back to the original width: the
/// constraints and the split view were both trying to own the same number, and
/// the constraints won on the next layout pass. `NSSplitViewItem` owns it
/// properly through `minimumThickness` and `maximumThickness`, and it is also
/// what makes the sidebar collapsible and gives the divider position a saved
/// position for free.
@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = LibraryWindow()

    private var window: NSWindow?
    private var split: LibrarySplitViewController?
    private var sidebarItem: NSSplitViewItem?
    private let sidebar = SidebarViewController()
    private let detail = DetailViewController()

    /// What the window is showing. Settings is a mode of this window rather
    /// than a window of its own: the sidebar swaps the recording list for the
    /// section list and the content side swaps the transcript for a pane.
    private enum Mode { case library, settings, people, notes }
    private var mode: Mode = .library

    /// The two split items' view controllers, which never change. Swapping a
    /// child inside them is the only way to change what a split view item shows:
    /// `NSSplitViewItem.viewController` is read-only after the fact, and
    /// removing and re-inserting items throws away the divider position that
    /// `splitView.autosaveName` exists to keep.
    private let sidebarHost = PaneHost()
    private let detailHost = PaneHost()

    private let settingsNav = SettingsNavViewController()
    /// People is a third mode for the same reason settings is a second one: it
    /// is a roster and a page, both of which want the whole window, and neither
    /// of which is a recording.
    private let peopleNav = PeopleNav()
    private let personPane = PersonPane()
    /// Notes are a fourth collection for the reason People is a third: a note
    /// can name four recordings, so a recording-centric list cannot show one.
    private let notesNav = NotesNav()
    private let notePane = NotePane()
    /// Built once each and kept, so returning to a section finds it where it
    /// was left rather than scrolled back to the top with its fields cleared.
    private var panes: [SettingsTab: Pane] = [:]
    /// Whether the sidebar was collapsed before settings forced it open.
    private var sidebarWasCollapsed = false

    private static let brandItem = NSToolbarItem.Identifier("listenBrand")
    private static let actionsItem = NSToolbarItem.Identifier("recordingActions")
    private static let settingsItem = NSToolbarItem.Identifier("openSettings")
    private static let peopleItem = NSToolbarItem.Identifier("openPeople")
    private static let personActionsItem = NSToolbarItem.Identifier("personActions")
    private static let backItem = NSToolbarItem.Identifier("backToLibrary")

    /// What the library looked like when this window last read it. See
    /// `appBecameActive`.
    private var libraryStamps: [String: TimeInterval] = [:]

    private var recordTick: Timer?
    /// Built once and kept: see `recordingActionsMenu`. A stored property
    /// rather than a `lazy var` because the menu is built in an extension.
    fileprivate var actionsMenu: NSMenu?
    /// The File menu's model list: see `modelMenu`. Kept for the same reason
    /// and stored here for the same one.
    fileprivate var fileModelMenu: NSMenu?

    /// The recording whose row was selected when capture started, so it is
    /// selected once rather than on every state change.
    private var selectedLive: String?

    /// The record control, floating over the bottom right of the content pane.
    /// See `RecordButton` for why it is not a row in the sidebar any more, and
    /// why it is the stop control too.
    ///
    /// **Idle it is in the recordings collection only.** In People and Notes it
    /// would be a recordings verb parked on a page that is not about
    /// recordings, and neither collection has a create action of its own: a
    /// person is derived from a transcript label and a note is written on a
    /// recording.
    ///
    /// **Running, it is on every screen, unconditionally.** That is not a
    /// relaxation of the rule above, it is the rule the toolbar's stop control
    /// already followed and the reason it had to: stopping a meeting must never
    /// mean leaving the screen you are on to find the button. Settings, People
    /// and Notes have no sidebar row with a clock in it, so a recording started
    /// an hour ago would otherwise have no visible end from any of them.
    ///
    /// It is also not conditioned on the live recording being the one selected,
    /// which the toolbar's control was. That condition existed because the
    /// toolbar item sat over the meeting's own title, where a stop button about
    /// a different recording is a second subject on one screen. Down here it is
    /// in the corner, it is the only red thing in the window, and it is the only
    /// clock that counts up: nothing else in this app looks like it.
    private lazy var recordFAB: RecordButton = {
        RecordButton(target: self, action: #selector(newRecording))
    }()

    /// The way out of settings.
    ///
    /// A custom view for the same reason the record control is one: the toolbar
    /// is `.iconOnly`, and a bare chevron with nowhere to say where it goes is
    /// a button you have to click to find out what it does.
    private lazy var backButton: NSButton = {
        let b = NSButton(title: " Library", target: self, action: #selector(exitSettings))
        b.bezelStyle = .rounded
        b.imagePosition = .imageLeading
        b.image = NSImage(systemSymbolName: "chevron.backward",
                          accessibilityDescription: "Back to the library")
        b.toolTip = "Back to the library (Esc)"
        b.sizeToFit()
        return b
    }()

    /// A calm masthead for the sidebar, not a new action. The toolbar's items
    /// before `sidebarTrackingSeparator` belong to the sidebar, which lets the
    /// name and coloured mascot use the otherwise empty title-bar space without
    /// competing with the meeting actions on the right.
    private lazy var brandMark: NSStackView = {
        let icon = BrandIcon.view(size: 28, accessibilityLabel: "Listen mascot")
        let name = NSTextField(labelWithString: "Listen")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byClipping

        let mark = NSStackView(views: [icon, name])
        mark.orientation = .horizontal
        mark.alignment = .centerY
        mark.spacing = 8
        mark.setAccessibilityLabel("Listen")
        mark.frame = NSRect(x: 0, y: 0, width: 92, height: 28)
        return mark
    }()

    // MARK: - Showing

    /// Open the app. Always the library: this is what the Dock icon, Cmd-0 and
    /// the menu bar's "Open Listen" mean, and landing in settings because that
    /// is where somebody was three days ago is not.
    func show() {
        if window == nil { build() }
        enter(.library)
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open settings, on `tab` or on whichever section was last open.
    ///
    /// nil rather than a `.general` default so that Cmd-, pressed while already
    /// in settings does not throw you back to the first section.
    func showSettings(_ tab: SettingsTab? = nil) {
        if window == nil { build() }
        enter(.settings)
        settingsNav.select(tab ?? settingsNav.selectedTab)
        showPane(settingsNav.selectedTab)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        settingsNav.focusList()
    }

    /// The way back, from wherever "back" is.
    ///
    /// It guarded on `.settings` when settings was the only other mode, so
    /// People inherited a Library button that did nothing: the same control,
    /// the same label, and no response. Anything that is not the library goes
    /// back to the library.
    @objc func exitSettings() {
        guard mode != .library else { return }
        enter(.library)
    }

    var isShowingSettings: Bool { mode == .settings }

    private func build() {
        let controller = LibrarySplitViewController()

        let side = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        side.minimumThickness = 200
        side.maximumThickness = 460
        side.canCollapse = true
        // Higher than the detail pane's, so resizing the *window* moves the
        // divider's right-hand neighbour and leaves the sidebar the width it
        // was set to. The default is the other way round, which quietly
        // rewrites the saved width every time the window changes size and
        // looks exactly like the sidebar refusing to stay where it was put.
        side.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarHost.identifier = NSUserInterfaceItemIdentifier("sidebar")
        controller.addSplitViewItem(side)
        sidebarItem = side

        let main = NSSplitViewItem(viewController: detailHost)
        main.minimumThickness = 420
        main.holdingPriority = NSLayoutConstraint.Priority(250)
        detailHost.identifier = NSUserInterfaceItemIdentifier("detail")
        controller.addSplitViewItem(main)

        // In the host and not in `DetailView`, so it floats over whichever pane
        // is on the content side rather than being torn down and rebuilt with
        // one of them. `PaneHost` inserts its children underneath for this: a
        // pane swapped in afterwards would otherwise be added above the button
        // and cover it.
        //
        // `RecordButton.margin` from both edges, which is the pane's own content
        // column and **not** the toolbar's margin above it. Those two are in
        // different layers: the ellipsis sits 3 points from the window edge
        // because AppKit puts it there, that number is the window's chrome
        // rather than this app's, and it moves between macOS releases. Measured,
        // it cannot even be matched: a spacer item is clamped to a full slot, so
        // the only two reachable values are 3 and 45.
        //
        // What a control floating over the content should line up with is the
        // content. Measured on the running window, every element in the detail
        // pane ends 24 points from the edge: the title, the speaker chips, the
        // player card, the mode bar and the note. So does this, and the shared
        // edge is visible, because the player card is drawn to it.
        detailHost.loadViewIfNeeded()
        detailHost.view.addSubview(recordFAB)
        NSLayoutConstraint.activate([
            recordFAB.trailingAnchor.constraint(equalTo: detailHost.view.trailingAnchor,
                                                constant: -RecordButton.margin),
            recordFAB.bottomAnchor.constraint(equalTo: detailHost.view.bottomAnchor,
                                              constant: -RecordButton.margin),
        ])

        let w = NSWindow(contentViewController: controller)
        w.title = "Listen"
        // The app's name is already in the menu bar, and in the window it was
        // the only thing occupying the top of the content area: every pane
        // started a title's height below the toolbar to clear a word nobody
        // needed twice. Hidden, the panes begin where they look like they
        // should, and the window keeps its title for Mission Control and the
        // Window menu, which read `title` rather than what is drawn.
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.setContentSize(NSSize(width: 1040, height: 680))
        w.center()
        // Frame first, then the divider. Restoring the frame resizes the
        // window, and a resize redistributes the split, so doing it the other
        // way round overwrites the divider position with whatever the resize
        // produced.
        w.setFrameAutosaveName("ListenLibrary")
        controller.splitView.autosaveName = "ListenSplit"
        w.delegate = self
        w.isReleasedWhenClosed = false

        let toolbar = NSToolbar(identifier: "ListenToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        w.toolbar = toolbar

        window = w
        split = controller

        sidebar.onSelect = { [weak self] recording in
            guard let self else { return }
            self.detail.show(recording)
            // No rebuild. Which items belong used to depend on whether the
            // recording in progress was the one selected, because the stop
            // control stood in for People and Actions on that one screen.
            // Stopping is `recordFAB`'s now, so a mode's items are fixed and a
            // click in the list is a validation pass rather than five items
            // removed and re-inserted.
            self.window?.toolbar?.validateVisibleItems()
        }
        sidebar.onRenamed = { [weak self] in self?.reload() }
        // The list, and not the pane that just wrote the change. `reload` calls
        // `detail.show`, which stops playback, puts the playhead back to zero
        // and rebuilds every turn, and the pane is already showing what it
        // wrote: a title it has in hand, or a sentence it re-rendered in place.
        // So a rename or a correction made while listening used to silence the
        // recording being corrected, which is exactly what `applyEdit`'s
        // targeted reload exists to avoid and was undone one line later. It also
        // pulled the clicked view out of the hierarchy mid-click, which is how a
        // rename followed by a click on a speaker aborted the app.
        detail.onChanged = { [weak self] in self?.sidebar.reload() }
        settingsNav.onSelect = { [weak self] tab in self?.showPane(tab) }
        sidebar.onSettings = { [weak self] in self?.showSettings() }
        peopleNav.onSelect = { [weak self] person in self?.personPane.show(person) }
        // One handler, three lists. Each carries its own copy of the same
        // control because the sidebar swaps its whole view controller, and they
        // all report the same thing.
        sidebar.onCollection = { [weak self] in self?.showCollection($0) }
        peopleNav.onCollection = { [weak self] in self?.showCollection($0) }
        notesNav.onCollection = { [weak self] in self?.showCollection($0) }
        notesNav.onSelect = { [weak self] note in self?.notePane.show(note) }
        // A note names the meetings it is about, and those names are the way
        // back to them. This is what makes a synthesis of four catch-ups
        // navigable rather than a dead end.
        notePane.onOpenRecording = { [weak self] id, slug in
            self?.open(recording: id, note: slug)
        }
        // A rename rewrites transcripts, so the roster beside it is stale the
        // moment it lands, and so is the recording list behind both.
        personPane.onChanged = { [weak self] in
            guard let self else { return }
            let keep = self.peopleNav.selected?.label
            self.peopleNav.reload()
            if let keep { self.peopleNav.select(keep) }
        }
        // A rename, a merge or an unnaming leaves the roster selecting a label
        // that has stopped existing, so it is told where the person went. The
        // pane has to be sent somewhere explicitly: `select` cannot find them,
        // and a roster that quietly keeps its old selection leaves the page it
        // was on frozen mid-edit.
        personPane.onLandOn = { [weak self] label in
            guard let self else { return }
            self.peopleNav.reload()
            if !self.peopleNav.select(label) { self.personPane.show(nil) }
        }

        Queue.shared.onChange = { [weak self] _ in self?.reload() }
        // Deliberately not `reload`. See `Queue.onProgress`: a job advancing is
        // one row's subtitle and one picture, and rebuilding the list and
        // re-showing the recording thirty times a track would stop playback on
        // every piece.
        Queue.shared.onProgress = { [weak self] id in
            guard let self else { return }
            self.sidebar.tickRow(id)
            self.detail.showProgress()
        }

        // Somebody else may have written to the library since you last looked.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        libraryStamps = Self.libraryStamps()

        sidebarHost.show(sidebar)
        detailHost.show(detail)
    }

    /// One modification date per recording folder, which is as much as is worth
    /// knowing about a library nobody in this process has touched.
    ///
    /// Cheap on purpose: one directory listing with the dates prefetched, no
    /// `metadata.json` opened. A folder's date moves when a file is created,
    /// removed or renamed inside it, and every writer here renames into place,
    /// both `Recording.save()` with `.atomic` and a sync tool landing a file. So
    /// an edit made on another Mac shows up in this without reading anything.
    private static func libraryStamps() -> [String: TimeInterval] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var stamps: [String: TimeInterval] = [:]
        for dir in [Library.recordings, Library.staging] {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys) else { continue }
            for url in entries {
                let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
                stamps[url.lastPathComponent] = date?.timeIntervalSince1970 ?? 0
            }
        }
        return stamps
    }

    /// Re-read the library when you come back to the app.
    ///
    /// Nothing watched the library until now, and nothing needed to: every
    /// writer was this process, so every reload could be triggered by the edit
    /// that caused it. Sharing a library between two Macs breaks that, and the
    /// symptom is specific rather than general. A recording made on the other
    /// Mac arrives as `metadata.json` a moment before its `transcript.json`, so
    /// a row built in that second says "not transcribed" and says it for ever,
    /// while the pane underneath renders the transcript that arrived after it.
    /// Reported from a real two-Mac session, and the files on disk were correct
    /// throughout: only the window was stale.
    ///
    /// `DetailView` already does exactly this for notes, for the same reason an
    /// agent writing one announces nothing. This is that rule applied to the
    /// list, and it fixes the same staleness for a tag written by an agent or
    /// the CLI while the window is open.
    ///
    /// **The detail pane is re-shown only when the selected recording's own
    /// folder moved.** `DetailView.show` stops playback and puts the playhead
    /// back to zero, so reloading it on every activation would silence a meeting
    /// you were listening to every time you switched to another app and back.
    /// That is the bug `reloading` and `renderTurns(scrollToTop:)` already exist
    /// to prevent, and it would have been reintroduced here for free.
    @objc private func appBecameActive() {
        guard mode == .library else { return }
        let now = Self.libraryStamps()
        guard now != libraryStamps else { return }

        let selected = sidebar.selectedRecording?.id
        let selectedMoved = selected.map { now[$0] != libraryStamps[$0] } ?? false
        libraryStamps = now

        sidebar.reload()
        if selectedMoved, let selected, let fresh = Recording.find(selected) {
            detail.show(fresh)
        }
        trace("library changed elsewhere, list reloaded"
              + (selectedMoved ? " and the open recording re-read" : ""))
    }

    // MARK: - Modes

    private func enter(_ next: Mode) {
        guard let sidebarItem, let split, mode != next else { return }
        // A mode change leaves nothing behind to inspect afterwards, and "the
        // window went back to the library on its own" is otherwise unanswerable.
        // It was answered once already: a window moved under a stationary
        // pointer had pressed the back button, which no log would have shown.
        trace("window mode \(mode) -> \(next)")
        let was = mode
        mode = next

        switch next {
        case .settings:
            // A transport nobody can see is a transport nobody can pause, which
            // is the same reason `windowWillClose` stops playback.
            detail.stopPlayback()
            sidebarWasCollapsed = sidebarItem.isCollapsed
            // Directly and not through `animator()`: the content is being
            // swapped underneath, and a sidebar sliding open around a list that
            // has already changed reads as a glitch rather than as an opening.
            if sidebarItem.isCollapsed { sidebarItem.isCollapsed = false }
            // Settings with no visible section list is a pane you cannot
            // navigate. This closes the divider drag and the double-click; the
            // toolbar item and the menu item are handled separately, because
            // there are three ways to collapse a sidebar and blocking one of
            // them is blocking none of them.
            sidebarItem.canCollapse = false
            split.canToggleSidebar = false
            sidebarHost.show(settingsNav)

        case .people:
            // The sidebar stays collapsible, unlike settings. It used to be
            // locked open because the roster was the only way out of this
            // screen, and now the segmented control at the top of it is the way
            // in and out of every collection: the lock was about navigation,
            // not about People.
            detail.saveYours()
            detail.stopPlayback()
            peopleNav.reload()
            sidebarItem.canCollapse = true
            split.canToggleSidebar = true
            sidebarHost.show(peopleNav)
            detailHost.show(personPane)

        case .notes:
            detail.saveYours()
            detail.stopPlayback()
            notesNav.reload()
            sidebarItem.canCollapse = true
            split.canToggleSidebar = true
            sidebarHost.show(notesNav)
            detailHost.show(notePane)

        case .library:
            sidebarItem.canCollapse = true
            split.canToggleSidebar = true
            // Only settings hid the sidebar, so only settings restores it.
            if was == .settings { sidebarItem.isCollapsed = sidebarWasCollapsed }
            sidebarHost.show(sidebar)
            detailHost.show(detail)
            reload()
            if let table = sidebar.view.window?.firstResponder as? NSView,
               table.isDescendant(of: settingsNav.view) {
                window?.makeFirstResponder(sidebar.view)
            }
        }
        // All three, not just the one on screen: the next mode change swaps in
        // a list whose control was last touched by a click that took the user
        // somewhere else.
        if let collection = Self.collection(for: next) {
            sidebar.setCollection(collection)
            peopleNav.setCollection(collection)
            notesNav.setCollection(collection)
        }
        updateRecordFAB()
        rebuildToolbar()
    }

    /// Settings has no segment, so it leaves the three controls alone.
    private static func collection(for mode: Mode) -> LibraryCollection? {
        switch mode {
        case .library:  return .recordings
        case .people:   return .people
        case .notes:    return .notes
        case .settings: return nil
        }
    }

    /// Open a recording from a link inside a note.
    ///
    /// The one entry point for both places a note names its sources, and they
    /// want different tabs.
    ///
    /// From the **Notes collection**, `note` is the note being read, and it
    /// lands on the Notes tab showing that note beside the recording: the whole
    /// page has changed, and a synthesis of four meetings has to be walkable
    /// through its sources without losing your place in it.
    ///
    /// From the **"Also about" line under a note shown beside a recording**,
    /// `note` is nil and it lands on the transcript. The note being read is
    /// about that meeting too, so staying on the Notes tab would put the same
    /// words under a different title, and a page that does not visibly change
    /// is a click that did not appear to work.
    ///
    /// The window is raised as well as filled. The note links that were this
    /// function's first callers are inside a window that is already key, so it
    /// did not use to be; the menu bar's Recent list is pressed with the window
    /// closed or behind a browser, and building it without showing it is a click
    /// that appears to do nothing at all.
    func open(recording id: String, note slug: String?) {
        if window == nil { build() }
        enter(.library)
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // A filter or a search in the sidebar can hide the recording a note
        // points at, and a click that appears to do nothing is worse than one
        // that gives way. The click already said which recording to look at, so
        // the filter is what loses, as it does in `reveal`.
        if !sidebar.select(id) {
            sidebar.clearFilters()
            guard sidebar.select(id) else { NSSound.beep(); return }
        }
        // After the selection, because selecting shows the recording and `show`
        // decides which tab is up.
        if let slug { detail.showNote(slug) } else { detail.showTranscript() }
    }

    /// Follow the sidebar's segmented control.
    ///
    /// Settings is deliberately not one of these: the segments are which part
    /// of the library you are looking at, and settings is configuring the app.
    func showCollection(_ collection: LibraryCollection) {
        switch collection {
        case .recordings: enter(.library)
        case .people:     enter(.people)
        case .notes:      enter(.notes)
        }
    }

    /// Open the roster, on `label` if somebody was asked for.
    ///
    /// The entry point from a chip's menu and from the toolbar. Selecting the
    /// person is done after the mode change, because the roster does not exist
    /// as a list of rows until it has been shown once.
    func showPerson(_ label: String? = nil) {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        enter(.people)
        if let label {
            peopleNav.select(label)
        } else if peopleNav.selected == nil {
            personPane.show(nil)
        }
    }

    private func showPane(_ tab: SettingsTab) {
        let pane = panes[tab] ?? {
            let made = tab.makePane()
            panes[tab] = made
            return made
        }()
        detailHost.show(pane)
        // Explicitly, as well as through `viewWillAppear`. Both are idempotent,
        // and a pane that shows stale permission or storage numbers because an
        // appearance callback did not arrive is the kind of wrong that looks
        // like the setting itself failing.
        pane.refresh()
        // No window subtitle for the section name. It draws immediately above
        // the pane's own 22pt heading, so the window read "Audio" twice, one
        // line apart, which looks like a bug rather than like a title.
    }

    /// Give transcript paragraphs a field editor that knows about sentences.
    ///
    /// This is the only place a right-click on a turn can be answered. A
    /// selectable `NSTextField` installs its field editor on `rightMouseDown`,
    /// *before* the contextual menu is built, so hit testing lands on that text
    /// view and an override on the field itself never runs. Measured, because
    /// the opposite is the natural assumption.
    ///
    /// Returning nil means "the standard one", which is what the title field and
    /// everything else in the window keeps. One editor is enough: AppKit uses a
    /// single field editor per window, since only one field can be edited at a
    /// time. Called constantly, so it stays a type check and nothing more.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is TranscriptBody ? transcriptEditor : nil
    }

    private let transcriptEditor = TranscriptFieldEditor.make()

    // MARK: - Data

    func reload() {
        // Take the stamps here too, so this window's own writes are never
        // mistaken for somebody else's the next time it is activated.
        libraryStamps = Self.libraryStamps()
        sidebar.reload()
        // Re-read the selected recording from disk so a transcript that just
        // finished appears without anyone clicking away and back.
        if let id = sidebar.selectedRecording?.id, let fresh = Recording.find(id) {
            detail.show(fresh)
        } else if sidebar.selectedRecording == nil {
            detail.show(nil)
        }
    }

    /// Nothing is selected while settings is open, so the Actions menu says so
    /// and the File menu greys out rather than acting on a row nobody can see.
    var selected: Recording? { mode == .library ? sidebar.selectedRecording : nil }

    /// Draw the window into a PNG without going near the screen.
    ///
    /// `LISTEN_SHOT=<prefix>`, in the same family as `LISTEN_PANEL` and
    /// `LISTEN_CHUNK`: scaffolding for looking at the thing, not a feature.
    ///
    /// It exists because `screencapture` and ScreenCaptureKit both photograph
    /// the *screen*, so neither can see this window when the Mac is locked, over
    /// SSH, or on the second machine that shares this library. `cacheDisplay`
    /// asks the view to draw itself into a bitmap, which needs no display, no
    /// session and no Screen Recording permission. For a window whose most
    /// interesting states last under a minute and only happen after a real
    /// meeting, that is the difference between a picture somebody can check and
    /// one they have to catch.
    @discardableResult
    func writeShot(to path: String) -> Bool {
        guard let view = window?.contentView else { return false }
        // Laid out first: a window that was never ordered front has never been
        // through a layout pass, and the bitmap would be of the frames the views
        // were created with rather than the ones they are drawn at.
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return false
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        // Composited onto the window's own background afterwards, because
        // `cacheDisplay` draws the views and not the window: an
        // `NSVisualEffectView`'s material is the window server's work, so the
        // sidebar and the page behind the text come out transparent. Left as it
        // is, a dark-mode window is white text on white, which is not a picture
        // anybody can review. This is not what the window looks like to the
        // pixel, and it is not meant to be: it is legible, and the colours and
        // the layout are the app's own.
        let size = view.bounds.size
        let flattened = NSImage(size: size)
        flattened.lockFocus()
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: size))
        flattened.unlockFocus()

        guard let flat = flattened.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: flat),
              let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            log("could not write \(path): \(error.localizedDescription)")
            return false
        }
    }

    /// Show the transcription picture on a real recording, at a made-up
    /// position. `LISTEN_PANEL=transcribing:0.6`, and nothing else calls it.
    ///
    /// A real recording rather than a made-up one, so the waveform is a real
    /// envelope: the drawing is a picture of an hour of somebody's meeting, and
    /// checking it against a flat line would miss exactly the bugs worth
    /// catching. The most recent one, because it is the one already selected.
    func previewTranscribing(_ fraction: Double) {
        show()
        if let first = Recording.all().first { sidebar.select(first.id) }
        // After the selection: `select` re-shows the recording, which rebuilds
        // the empty area and would put the picture straight back away again.
        detail.previewTranscribing(fraction)
    }

    /// Select a recording from somewhere that is not the list, which today
    /// means from a person's popover.
    func reveal(_ id: String) {
        show()
        guard !sidebar.select(id) else { return }
        // A search or a speaker filter can be hiding it, and selecting nothing
        // looks exactly like a click that missed. The click already said which
        // recording to look at, so the filter is what gives way.
        sidebar.clearFilters()
        sidebar.select(id)
    }

    /// Show only the recordings one person is in. nil is the whole library.
    func filter(bySpeaker label: String?) {
        show()
        sidebar.filter(bySpeaker: label)
    }

    /// Show only the recordings carrying one tag. nil is the whole library.
    func filter(byTag name: String?) {
        show()
        sidebar.filter(byTag: name)
    }

    // MARK: - Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.backItem,
         .flexibleSpace, Self.settingsItem,
         Self.actionsItem, Self.personActionsItem]
    }

    /// What the toolbar shows, which depends on the mode.
    ///
    /// The sidebar toggle is only in the library, and the back button takes the
    /// slot it leaves.
    ///
    /// There is **no record or stop item here at all any more**, in any mode.
    /// Both are `recordFAB`, in the bottom right corner of the content pane,
    /// which is what removed the last thing this list varied on: every mode's
    /// items are now the same whether or not a meeting is running, and the
    /// library's no longer depend on which row is selected either.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        switch mode {
        case .library:
            // `sidebarTrackingSeparator` is what puts the toggle over the
            // sidebar beside the traffic lights rather than at the left edge of
            // the content, and it is the only way to reach that region: items
            // before it belong to the sidebar, items after it to the content.
            // The masthead anchors the left edge of the sidebar. Its collapse
            // control belongs at the other edge, next to the divider: that
            // makes the title read as identity and the glyph read as utility,
            // rather than leaving two unrelated icons in a row.
            //
            // The actions menu stays whether or not anything is selected, and
            // says "No recording selected" when nothing is, which is what the
            // person page's menu does with no person. A control that appears
            // and disappears as you click around the list is harder to find
            // than one that is always in the same place and tells you why it is
            // empty.
            // People used to sit here. It moved into the sidebar, because a
            // toolbar holds verbs on the selected recording (export this,
            // transcribe this again, delete this) and People is not a verb on a
            // recording: it is a peer collection of the whole library, and so
            // are notes.
            return [Self.brandItem, .flexibleSpace, .toggleSidebar,
                    .sidebarTrackingSeparator, .flexibleSpace, Self.actionsItem]
        case .settings:
            // No back item: the way out is a row at the top of the section
            // list. In a window with a hidden title, a toolbar button sat over
            // the pane's own heading, so "General" read as half a word behind
            // "Library".
            // No toggle: settings locks the sidebar open, and a control that
            // is always disabled is a control that should not be drawn. The
            // way back takes its place, as a row in the sidebar level with the
            // traffic lights.
            return [.sidebarTrackingSeparator, .flexibleSpace]
        case .people:
            // The person's actions live beside the way out, where every other
            // menu in this window lives, rather than as a button inside the
            // page. It also lets the name and the disc sit at the top of the
            // page instead of below a row of controls.
            //
            // The sidebar toggle is here now, unlike before: these modes no
            // longer lock the sidebar open, because the segmented control in it
            // is the navigation and collapsing is a choice like any other.
            return [Self.brandItem, .flexibleSpace, .toggleSidebar,
                    .sidebarTrackingSeparator, .flexibleSpace, Self.personActionsItem]
        case .notes:
            // Nothing on the right. A note has no verbs yet: it is deleted
            // where it is written, and there is nothing to export that is not
            // already a markdown file on disk.
            // The masthead in every collection, not just the recording list.
            // Switching is one click now, so a window whose title bar empties
            // as you move between segments reads as three different screens
            // rather than three views of one library.
            return [Self.brandItem, .flexibleSpace, .toggleSidebar,
                    .sidebarTrackingSeparator, .flexibleSpace]
        }
    }

    /// Swap the items for the current mode.
    ///
    /// `NSToolbar` has no "reload your items" call, so this removes and
    /// re-inserts them. Assigning a second `NSToolbar` to the window is the
    /// other way and it re-runs the whole title bar layout to change two
    /// buttons.
    private func rebuildToolbar() {
        guard let toolbar = window?.toolbar else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (index, id) in toolbarDefaultItemIdentifiers(toolbar).enumerated() {
            toolbar.insertItem(withItemIdentifier: id, at: index)
        }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.brandItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Listen"
            item.view = brandMark
            item.minSize = NSSize(width: 92, height: 28)
            item.maxSize = NSSize(width: 92, height: 28)
            return item

        case Self.settingsItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Settings"
            item.toolTip = "Settings (⌘,)"
            item.image = NSImage(systemSymbolName: "gearshape",
                                 accessibilityDescription: "Settings")
            item.target = self
            item.action = #selector(openSettings)
            return item

        case Self.personActionsItem:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Actions"
            item.toolTip = "Edit, merge or delete this contact"
            item.image = NSImage(systemSymbolName: "ellipsis",
                                 accessibilityDescription: "Actions")
            // The pane owns the menu and rebuilds it as it opens: which items
            // belong depends on who is selected and whether they have a card.
            item.menu = personPane.actionsMenu
            item.showsIndicator = false
            return item

        case Self.peopleItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "People"
            item.toolTip = "Everybody this library knows"
            item.image = NSImage(systemSymbolName: "person.2",
                                 accessibilityDescription: "People")
            item.target = self
            item.action = #selector(openPeople)
            return item

        case Self.backItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Library"
            item.view = backButton
            item.minSize = backButton.frame.size
            item.maxSize = backButton.frame.size
            return item

        case Self.actionsItem:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Actions"
            item.toolTip = "Actions for this recording"
            item.image = NSImage(systemSymbolName: "ellipsis",
                                 accessibilityDescription: "Actions")
            item.menu = recordingActionsMenu
            item.showsIndicator = false
            return item

        default:
            return nil
        }
    }

    // MARK: - Actions

    @objc private func openSettings() { showSettings() }
    @objc private func openPeople() { showPerson() }

    @objc private func newRecording() {
        // Start, and stop, from the same control. The menu bar item does the
        // same thing; this exists because someone reading a transcript should
        // not have to go to the menu bar to record the next meeting.
        if Capture.shared.isRecording {
            NSApp.sendAction(#selector(App.stopRecordingFromUI), to: nil, from: self)
        } else {
            NSApp.sendAction(#selector(App.startRecordingFromUI), to: nil, from: self)
        }
    }

    /// Called by the delegate whenever capture starts or stops.
    func recordingChanged() {
        updateRecordFAB()
        recordTick?.invalidate()
        recordTick = nil

        // The list has to be rebuilt on both edges. Starting adds the row for
        // the recording in progress, which lives in staging and is therefore
        // invisible to `Recording.all()`; stopping promotes it into the library
        // under the same id, so the row stays where it was rather than
        // disappearing and coming back.
        reload()

        if let live = Capture.shared.current {
            // Select it, once, when it starts. The recording somebody just began
            // is the one they are looking at, and leaving the selection on
            // whatever they were reading means hunting for a row that was not
            // there a second ago. Once, because re-selecting on every tick would
            // fight anyone who clicked away to read something while the meeting
            // runs.
            if selectedLive != live.id {
                selectedLive = live.id
                sidebar.select(live.id)
            }

            // Once a second, because the button shows seconds. The floating
            // panel ticks twice a second for its own clock; this one does not
            // need to.
            recordTick = Timer.scheduledTimer(withTimeInterval: 1,
                                              repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updateRecordFAB()
                    self?.sidebar.tickLive()
                }
            }
        } else {
            selectedLive = nil
        }

        // Last, and after the selection: every mode swaps items on both edges of
        // capture, and in the library which items belong depends on whether the
        // recording that just started is the one on screen. Rebuilding before
        // selecting it would ask that question of the previous selection and
        // leave the stop control out for the length of the meeting.
        rebuildToolbar()
    }

    /// Put the floating record control into the state the app is actually in.
    ///
    /// Called from both edges of capture, from every mode change, and once a
    /// second while recording, which is when the clock in it changes.
    private func updateRecordFAB() {
        if Capture.shared.isRecording {
            recordFAB.isHidden = false
            recordFAB.state = .stop(clock: Self.clock(Capture.shared.elapsed))
        } else {
            recordFAB.isHidden = mode != .library
            recordFAB.state = .start
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Focus the search field, for Cmd-F.
    ///
    /// Leaves settings on the way. Cmd-F means find a recording, and the field
    /// it focuses is in the other sidebar.
    func focusSearch() {
        window?.makeKeyAndOrderFront(nil)
        exitSettings()
        sidebar.focusSearch()
    }

    func windowWillClose(_ notification: Notification) {
        detail.stopPlayback()
        // The user's own note is written as they type, but a keystroke inside
        // the last 0.8 seconds has not landed yet, and closing the window is
        // exactly when somebody stops typing.
        detail.saveYours()
        // Back to the library, so the collapse lock and the remembered sidebar
        // state are unwound rather than left in place for the next `show()`.
        exitSettings()
    }
}

// MARK: - Menu validation

/// The recording actions are only meaningful with a recording selected, and
/// `selected` is nil for the whole time settings is open. Nothing validated
/// them before, so they were permanently enabled and quietly did nothing when
/// pressed; settings makes that reachable often enough to be worth fixing here.
extension LibraryWindow: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(retranscribeSelected), #selector(retranscribeWithModel(_:)):
            // Transcribing needs the audio, and on a Mac sharing a library with
            // the machine that recorded it there is none. Enabled, this would be
            // a control that does nothing and reports nothing, which is the
            // hardest kind of failure to attribute. Both copies of this item go
            // through here: the File menu's targets nil, and the toolbar's is
            // validated the same way.
            return selected?.hasAudio == true
        case #selector(exportSelected), #selector(revealSelected),
             #selector(renameSelected), #selector(deleteSelected),
             #selector(tagSelected):
            return selected != nil
        default:
            return true
        }
    }
}

// MARK: - The two halves of the window

/// Holds one view controller at a time, so a split view item can change what it
/// shows.
///
/// The view draws nothing. `NSSplitViewItem(sidebarWithViewController:)` puts
/// its material behind whatever it is given, and a host that painted a
/// background would cover it and leave the sidebar looking like a plain panel.
@MainActor
final class PaneHost: NSViewController {
    private(set) var current: NSViewController?

    override func loadView() { view = NSView() }

    func show(_ child: NSViewController) {
        loadViewIfNeeded()
        guard current !== child else { return }
        if let old = current {
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        // Underneath whatever the host already holds, which on the content side
        // is the floating Record button. Added on top, a pane swapped in later
        // would cover it, and the button would work in the mode it was built in
        // and silently stop after the first visit to People or Settings.
        view.addSubview(child.view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        current = child
    }
}

/// The window's split view controller, which knows when the sidebar is locked.
///
/// Two of the three ways to collapse a sidebar go through here. The third is
/// the toolbar item, which is simply not in the toolbar in settings mode.
@MainActor
final class LibrarySplitViewController: NSSplitViewController, NSMenuItemValidation {
    var canToggleSidebar = true

    override func toggleSidebar(_ sender: Any?) {
        guard canToggleSidebar else { return }
        super.toggleSidebar(sender)
    }

    /// Grey out View > Hide Sidebar rather than letting it look available and
    /// do nothing. The item targets nil and travels the responder chain, so
    /// this is where it lands.
    ///
    /// Conformance rather than an override: `NSSplitViewController` does not
    /// implement this, which the compiler says plainly if you try. So there is
    /// no super to call, and everything this does not recognise is enabled,
    /// which is what the default behaviour was.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSidebar(_:)) { return canToggleSidebar }
        return true
    }

    /// Escape leaves settings.
    ///
    /// Here rather than on either child because this is last in the responder
    /// chain, so anything that wants Escape for itself, a text field ending an
    /// edit, gets it first.
    override func cancelOperation(_ sender: Any?) {
        LibraryWindow.shared.exitSettings()
    }
}

// MARK: - The actions menu

extension LibraryWindow: NSMenuDelegate {
    /// The recording's actions, as a menu the toolbar owns.
    ///
    /// A menu rather than a row of buttons. Everything in it acts on the
    /// selected recording, and most of it is rare or destructive, which is not
    /// what a toolbar button is for.
    ///
    /// Kept rather than built per toolbar item so `menuNeedsUpdate` can tell it
    /// apart from the sidebar's contextual menu, which shares this delegate.
    var recordingActionsMenu: NSMenu {
        if let built = actionsMenu { return built }
        let menu = NSMenu()
        menu.delegate = self
        actionsMenu = menu
        return menu
    }

    /// The File menu's copy of the model list.
    ///
    /// Kept, unlike the other two, because the item it hangs off is built once
    /// at launch. Filled here as well as on open so it is never empty: AppKit
    /// will not open an empty submenu, and a parent that cannot be opened is a
    /// menu item that does nothing.
    var modelMenu: NSMenu {
        if let built = fileModelMenu { return built }
        let menu = NSMenu()
        menu.delegate = self
        fill(menu, for: nil)
        fileModelMenu = menu
        return menu
    }

    /// The models, as a submenu of Transcribe Again.
    func modelSubmenu(for recording: Recording?) -> NSMenu {
        let menu = NSMenu()
        fill(menu, for: recording)
        return menu
    }

    private func fill(_ menu: NSMenu, for recording: Recording?) {
        menu.removeAllItems()
        // The tick goes on what **made** the transcript, not on what the next
        // run would use. That is the question somebody reading a wrong
        // transcript actually has, and this is the only place the app answers it
        // in the same gesture that changes it. Before there is a transcript
        // there is nothing to have made it, so the recording's own choice stands
        // in.
        let current = recording?.storedTranscript
            .flatMap { ModelChoice.forRepo($0.model) } ?? recording?.asrModel

        for choice in ModelChoice.all {
            // The coverage rather than the whole blurb. "May misdetect short
            // clips" is true and belongs in Settings, and it is misleading
            // here: what is being re-transcribed is a meeting, which is not
            // short. What matters at this click is which languages it can read.
            var title = "\(choice.title) · \(choice.coverage)"
            // The cost of the click, before the click. Otherwise a 2.5 GB
            // download starts inside the job and the first thing that says so
            // is the progress line in the sidebar.
            if !choice.isDownloaded {
                title += " · downloads \(ModelChoice.humanBytes(choice.approxBytes))"
            }
            let item = NSMenuItem(title: title,
                                  action: #selector(retranscribeWithModel(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = choice.id
            item.state = choice.id == current?.id ? .on : .off
            menu.addItem(item)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The File menu's model list, which is the one menu here that is kept
        // rather than rebuilt. Before the recording actions below, which would
        // otherwise fill it with Export and Delete.
        if menu === fileModelMenu { fill(menu, for: selected); return }

        menu.removeAllItems()
        // A pull-down menu takes its **first** item as the button's own title
        // and never shows it, so the toolbar's copy needs something expendable
        // there. Measured on the shipped build: with a recording selected the
        // menu opened on Transcribe Again and Export was simply gone, and with
        // nothing selected the one "No recording selected" item was eaten
        // whole, leaving an empty menu, which AppKit does not put up at all.
        // Pressing the ellipsis then does nothing and reports nothing.
        //
        // Only the toolbar's. The sidebar's right-click menu shares this
        // delegate and shows every item it is handed, blank one included.
        if menu === actionsMenu { menu.addItem(NSMenuItem()) }
        guard let recording = selected else {
            menu.addItem(withTitle: "No recording selected", action: nil, keyEquivalent: "")
                .isEnabled = false
            return
        }

        add(menu, "Export…", #selector(exportSelected), "square.and.arrow.down")
        menu.addItem(.separator())
        // The model hangs off this item rather than living three screens away
        // in Settings, because a transcript in the wrong language is read here
        // and the model is the only lever over it. A fresh submenu each time:
        // an `NSMenu` can be the submenu of one item only, and these two menus
        // are rebuilt on every open anyway.
        add(menu, recording.hasTranscript ? "Transcribe Again" : "Transcribe",
            #selector(retranscribeSelected), "arrow.triangle.2.circlepath")
            .submenu = modelSubmenu(for: recording)
        add(menu, "Rename…", #selector(renameSelected), "pencil")
        // The one way in for a recording whose band is collapsed, which is a
        // live or untranscribed one: with no speakers and no tags there is no
        // strip on screen to hold a `＋`. One line here gives the toolbar's
        // ellipsis and the sidebar's right-click menu both, because they share
        // this delegate.
        add(menu, "Tags…", #selector(tagSelected), "number")
        menu.addItem(.separator())
        add(menu, "Show in Finder", #selector(revealSelected), "folder")
        menu.addItem(.separator())

        let delete = add(menu, "Delete", #selector(deleteSelected), "trash")
        // Red, like Anarlog's. The only irreversible item in the menu should
        // not look like the others.
        delete.attributedTitle = NSAttributedString(
            string: "Delete", attributes: [.foregroundColor: NSColor.systemRed])
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector,
                     _ symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
        return item
    }

    @objc func renameSelected() {
        // Renaming happens in the detail pane's title field, which is where
        // the name is. Focusing it is less surprising than a dialog asking for
        // a string with no context around it.
        detail.beginEditingTitle()
    }

    /// Tagging happens in the detail pane, beside the tags.
    ///
    /// Same argument as Rename, and the same funnel: `DetailView` is what knows
    /// the three-step order a popover here has to be opened in.
    @objc func tagSelected() {
        detail.beginEditingTags()
    }

    @objc func revealSelected() {
        guard let recording = selected else { return }
        NSWorkspace.shared.selectFile(recording.metadataURL.path,
                                      inFileViewerRootedAtPath: recording.folder.path)
    }

    /// Transcribe again on whatever model this recording already carries.
    ///
    /// Rarely reached now that the item owns a submenu, because AppKit sends no
    /// action for an item that has one: the submenu's ticked row is the "same
    /// again" click. It stays because it is still the right answer if anything
    /// ever does fire it, and because keeping the action on the parent is what
    /// keeps both copies of the item going through `validateMenuItem`.
    @objc func retranscribeSelected() {
        guard let recording = selected else { return }
        retranscribe(recording, using: recording.asrModel)
    }

    /// Transcribe again on the model this menu item names.
    @objc func retranscribeWithModel(_ sender: NSMenuItem) {
        guard let recording = selected,
              let id = sender.representedObject as? String,
              let choice = ModelChoice.named(id) else { return }
        retranscribe(recording, using: choice)
    }

    private func retranscribe(_ recording: Recording, using choice: ModelChoice) {
        guard confirmOverwrite(recording, with: choice) else { return }
        Queue.shared.enqueue(recording.id, using: choice)
        reload()
    }

    /// Whether the re-run may go ahead.
    ///
    /// Transcribing again overwrites `transcript.json`, `turns.json` and the
    /// voiceprints beside them, so it discards every speaker somebody named and
    /// every sentence they corrected. Nothing asked before this, which was
    /// survivable while the item was a plain repeat and is not now that it is a
    /// choice: picking a model is what somebody does to a transcript they have
    /// already been through by hand.
    ///
    /// Only when there is something to lose, though. An unnamed recording stays
    /// one click, which is most of them and is exactly the case this feature was
    /// written for, and a confirmation that fires every time is one people learn
    /// to dismiss without reading it.
    private func confirmOverwrite(_ recording: Recording, with choice: ModelChoice) -> Bool {
        guard recording.hasHumanEdits else { return true }
        let alert = NSAlert()
        alert.messageText = "Transcribe \(recording.metadata.title) again"
            + " with \(choice.title)?"
        // Name what goes and what does not. The audio is untouched and so are
        // the notes, and somebody deciding this in a hurry should not have to
        // work that out.
        alert.informativeText = "The names you gave the speakers, and any sentences"
            + " you corrected, are part of the transcript this replaces."
            + " The audio and your notes are untouched."
        alert.addButton(withTitle: "Transcribe Again")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func exportSelected() {
        guard let recording = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = recording.exportName + ".md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var out = "# \(recording.metadata.title)\n\n\(recording.when)\n\n"
        for turn in recording.storedTurns {
            out += "**\(SpeakerName.display(turn.speaker))** · "
                + "\(TranscriptFormat.stamp(turn.start))\n\n\(turn.text)\n\n"
        }
        try? out.write(to: url, atomically: true, encoding: .utf8)
    }

    @objc func deleteSelected() {
        guard let recording = selected else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(recording.metadata.title)?"
        // Say what is actually lost. The audio is the irreplaceable part, and
        // what the user typed during the meeting is more irreplaceable still:
        // a call can in principle be had again, and a thought somebody had
        // while it was happening cannot. Notes an agent wrote are derived from
        // the transcript, so they are not worth a sentence here.
        var lost = "The audio and the transcript are deleted from disk. "
            + "This cannot be undone."
        if let yours = Notes.yours(for: recording), !yours.body.isEmpty {
            // Kept rather than deleted, and said so rather than left to be
            // discovered. Notes live in the library and not in the recording
            // folder, so nothing here removes them, which is what stops a
            // synthesis of four meetings vanishing because one was tidied up.
            // The consequence for this one is worth a sentence: it survives
            // naming a recording that no longer exists.
            lost += "\n\nYour own notes are kept, under Notes in the sidebar. "
                + "They will name a recording that is no longer here."
        }
        alert.informativeText = lost
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? recording.delete()
        reload()
    }
}

// MARK: - Speaker naming

/// How a speaker is written in the interface.
///
/// The pipeline stores `A`, `B`, `C`, which are stable and short and exactly
/// right on disk. On screen a bare letter reads as a code the reader is
/// expected to decode, so it becomes "Speaker A". That also removes any need
/// for a "needs labelling" state in the list: an unnamed speaker is legible on
/// its own, and a filter tab for it was solving a problem the wording caused.
enum SpeakerName {
    /// The label the pipeline writes for the microphone track.
    ///
    /// It stays `Me` on disk however the user chooses to be shown, which is the
    /// same rule as `A` and `B`: the label is the stable fact and this is where
    /// it is made legible. Writing the chosen name into the transcripts instead
    /// would fail in three ways that only appear later. Recordings made before
    /// the name was set would keep saying `Me` while later ones said "Emily".
    /// Changing your mind would not reach the history. And `Me` would stop
    /// being a stable key, which `VoiceBank.isPlaceholder` and `Enroll` both
    /// rely on to know which voice is the user's without being told.
    static let you = "Me"

    static func display(_ label: String) -> String {
        if label == you { return Settings.userName ?? you }
        return VoiceBank.isPlaceholder(label) ? "Speaker \(label)" : label
    }
}
