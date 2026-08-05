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
    private var split: NSSplitViewController?
    private var sidebarItem: NSSplitViewItem?
    private let sidebar = SidebarViewController()
    private let detail = DetailViewController()

    private static let newRecordingItem = NSToolbarItem.Identifier("newRecording")
    private static let actionsItem = NSToolbarItem.Identifier("recordingActions")

    private var recordItem: NSToolbarItem?
    private var recordTick: Timer?

    /// The recording whose row was selected when capture started, so it is
    /// selected once rather than on every state change.
    private var selectedLive: String?

    /// The toolbar's record control, which is also the stop control.
    ///
    /// It used to be a fixed pencil icon that silently changed meaning: the
    /// same glyph started a recording and stopped one, so the window gave no
    /// sign at all that it was recording and no hint that clicking again was
    /// how to stop. An hour-long capture with no visible state is the failure
    /// this app can least afford.
    private lazy var recordButton: NSButton = {
        let b = NSButton(title: "", target: self, action: #selector(newRecording))
        b.bezelStyle = .rounded
        b.imagePosition = .imageLeading
        b.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        return b
    }()

    // MARK: - Showing

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let controller = NSSplitViewController()

        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 200
        side.maximumThickness = 460
        side.canCollapse = true
        // Higher than the detail pane's, so resizing the *window* moves the
        // divider's right-hand neighbour and leaves the sidebar the width it
        // was set to. The default is the other way round, which quietly
        // rewrites the saved width every time the window changes size and
        // looks exactly like the sidebar refusing to stay where it was put.
        side.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebar.identifier = NSUserInterfaceItemIdentifier("sidebar")
        controller.addSplitViewItem(side)
        sidebarItem = side

        let main = NSSplitViewItem(viewController: detail)
        main.minimumThickness = 420
        main.holdingPriority = NSLayoutConstraint.Priority(250)
        detail.identifier = NSUserInterfaceItemIdentifier("detail")
        controller.addSplitViewItem(main)

        let w = NSWindow(contentViewController: controller)
        w.title = "Listen"
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
            self?.detail.show(recording)
            self?.window?.toolbar?.validateVisibleItems()
        }
        sidebar.onRenamed = { [weak self] in self?.reload() }
        detail.onChanged = { [weak self] in self?.reload() }

        Queue.shared.onChange = { [weak self] _ in self?.reload() }
    }

    // MARK: - Data

    func reload() {
        sidebar.reload()
        // Re-read the selected recording from disk so a transcript that just
        // finished appears without anyone clicking away and back.
        if let id = sidebar.selectedRecording?.id, let fresh = Recording.find(id) {
            detail.show(fresh)
        } else if sidebar.selectedRecording == nil {
            detail.show(nil)
        }
    }

    var selected: Recording? { sidebar.selectedRecording }

    // MARK: - Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.newRecordingItem, .flexibleSpace, Self.actionsItem]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, Self.newRecordingItem, .flexibleSpace, Self.actionsItem]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.newRecordingItem:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Record"
            // A custom view rather than the item's own image, because while
            // recording this has to say the elapsed time, and a plain
            // `NSToolbarItem` in an icon-only toolbar has nowhere to put text.
            item.view = recordButton
            recordItem = item
            updateRecordButton()
            return item

        case Self.actionsItem:
            // A menu rather than a row of buttons. Everything in it acts on
            // the selected recording, and most of it is rare or destructive,
            // which is not what a toolbar button is for.
            let menu = NSMenu()
            menu.delegate = self
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Actions"
            item.toolTip = "Actions for this recording"
            item.image = NSImage(systemSymbolName: "ellipsis",
                                 accessibilityDescription: "Actions")
            item.menu = menu
            item.showsIndicator = false
            return item

        default:
            return nil
        }
    }

    // MARK: - Actions

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
        updateRecordButton()
        recordTick?.invalidate()
        recordTick = nil

        // The list has to be rebuilt on both edges. Starting adds the row for
        // the recording in progress, which lives in staging and is therefore
        // invisible to `Recording.all()`; stopping promotes it into the library
        // under the same id, so the row stays where it was rather than
        // disappearing and coming back.
        reload()

        guard let live = Capture.shared.current else {
            selectedLive = nil
            return
        }
        // Select it, once, when it starts. The recording somebody just began is
        // the one they are looking at, and leaving the selection on whatever
        // they were reading means hunting for a row that was not there a second
        // ago. Once, because re-selecting on every tick would fight anyone who
        // clicked away to read something while the meeting runs.
        if selectedLive != live.id {
            selectedLive = live.id
            sidebar.select(live.id)
        }

        // Once a second, because the button shows seconds. The floating panel
        // ticks twice a second for its own clock; this one does not need to.
        recordTick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateRecordButton()
                self?.sidebar.tickLive()
            }
        }
    }

    private func updateRecordButton() {
        let recording = Capture.shared.isRecording
        let symbol = recording ? "stop.fill" : "record.circle"
        recordButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: recording ? "Stop recording" : "Start recording")
        // Red only while recording. A permanently red control is decoration;
        // one that turns red is a state.
        recordButton.contentTintColor = recording ? .systemRed : nil
        recordButton.title = recording ? " Stop " + Self.clock(Capture.shared.elapsed) : ""
        recordButton.toolTip = recording ? "Stop recording" : "Start recording"
        recordItem?.label = recording ? "Stop" : "Record"
        recordButton.sizeToFit()
        // A toolbar item with a custom view keeps the width it was measured at,
        // so it has to be told again every time the title changes or the clock
        // is clipped as it passes ten minutes.
        recordItem?.minSize = recordButton.frame.size
        recordItem?.maxSize = recordButton.frame.size
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Focus the search field, for Cmd-F.
    func focusSearch() {
        window?.makeKeyAndOrderFront(nil)
        sidebar.focusSearch()
    }

    func windowWillClose(_ notification: Notification) {
        detail.stopPlayback()
    }
}

// MARK: - The actions menu

extension LibraryWindow: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let recording = selected else {
            menu.addItem(withTitle: "No recording selected", action: nil, keyEquivalent: "")
                .isEnabled = false
            return
        }

        add(menu, "Export…", #selector(exportSelected), "square.and.arrow.down")
        menu.addItem(.separator())
        add(menu, recording.hasTranscript ? "Transcribe Again" : "Transcribe",
            #selector(retranscribeSelected), "arrow.triangle.2.circlepath")
        add(menu, "Rename…", #selector(renameSelected), "pencil")
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

    @objc func revealSelected() {
        guard let recording = selected else { return }
        NSWorkspace.shared.selectFile(recording.metadataURL.path,
                                      inFileViewerRootedAtPath: recording.folder.path)
    }

    @objc func retranscribeSelected() {
        guard let recording = selected else { return }
        Queue.shared.enqueue(recording.id)
        reload()
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

// MARK: - Speaker naming

/// How a speaker is written in the interface.
///
/// The pipeline stores `A`, `B`, `C`, which are stable and short and exactly
/// right on disk. On screen a bare letter reads as a code the reader is
/// expected to decode, so it becomes "Speaker A". That also removes any need
/// for a "needs labelling" state in the list: an unnamed speaker is legible on
/// its own, and a filter tab for it was solving a problem the wording caused.
enum SpeakerName {
    static func display(_ label: String) -> String {
        VoiceBank.isPlaceholder(label) ? "Speaker \(label)" : label
    }
}
