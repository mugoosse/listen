import AVFoundation
import AppKit

/// Which tab, by name.
///
/// Never a literal index. Speak's menu opened "About" as tab 4, so inserting a
/// tab above it would silently have opened Permissions instead.
enum SettingsTab: Int, CaseIterable {
    case general, models, storage, permissions, developers, about

    var title: String {
        switch self {
        case .general:     return "General"
        case .models:      return "Models"
        case .storage:     return "Storage"
        case .permissions: return "Permissions"
        case .developers:  return "Developers"
        case .about:       return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general:     return "gearshape"
        case .models:      return "cpu"
        case .storage:     return "internaldrive"
        case .permissions: return "lock.shield"
        case .developers:  return "terminal"
        case .about:       return "info.circle"
        }
    }
}

/// A settings pane.
///
/// Each one is a fixed-height `NSScrollView`, because `NSTabViewController`
/// sizes the window to the tallest pane and the window is not resizable.
/// Adding a tall pane otherwise pushes the window past the bottom of a laptop
/// screen, taking its buttons with it and leaving no way to reach them.
@MainActor
class Pane: NSViewController {
    static let paneHeight: CGFloat = 500
    static let paneWidth: CGFloat = 560

    let stack = NSStackView()
    private var document: NSView?

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.paneWidth,
                                                height: Self.paneHeight))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Flipped, and resized by hand in `resizeDocument`.
        //
        // The document view used to be a plain `NSView(frame:)` pinned to the
        // stack top and bottom with a `greaterThanOrEqualTo` height. Because
        // `translatesAutoresizingMaskIntoConstraints` stayed true, the frame
        // won and the height constraint could never grow it, so a pane whose
        // content did not fit was *compressed* rather than scrolled: headings
        // drew at zero height and notes lost their last line. That read as a
        // text-wrapping bug rather than a scrolling one, which is why it lasted
        // until the General pane grew past 500 points. Every pane before that
        // happened to fit.
        //
        // Turning the flag off is not the fix either. A document view with no
        // constraints tying it to the clip view leaves the scroll view's layout
        // ambiguous, and the whole settings window then failed to appear at
        // all. Measured, twice. So the frame stays authoritative and
        // `resizeDocument` sets it from the content.
        //
        // Flipped for the reason the old bottom constraint existed: an
        // unflipped document view has its origin at the bottom, so a short pane
        // hung off the floor of the window and a tall one opened scrolled to
        // the end.
        let clip = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.paneWidth,
                                             height: Self.paneHeight))
        clip.addSubview(stack)
        scroll.documentView = clip
        document = clip

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        ])
        view = scroll
        // The frame above is not enough. `NSTabViewController` ignores a view
        // controller's frame and sizes itself from `preferredContentSize`, so
        // without this every pane got NSTabView's default 500 x 500 while all
        // the layout arithmetic here went on using 560. Measured before the
        // fix: window 500 wide, clip view 500 wide, document view 560 wide, so
        // the right 60 points of every pane, and of every separator and note in
        // it, was quietly cut off. It read as clipped text rather than as a
        // sizing bug, which is why it survived this long.
        preferredContentSize = NSSize(width: Self.paneWidth, height: Self.paneHeight)
        build()
        resizeDocument()
    }

    /// Overridden by each pane.
    func build() {}

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        // After `refresh`, not only after `build`. Panes add rows here rather
        // than in `build` when the content can change while the app runs, and a
        // document sized before those rows exist scrolls to the wrong place or
        // not at all.
        resizeDocument()
    }

    /// Grow the document view to whatever the content needs, so the scroll view
    /// has something to scroll.
    private func resizeDocument() {
        guard let document else { return }
        stack.layoutSubtreeIfNeeded()
        let height = max(Self.paneHeight, stack.fittingSize.height)
        if document.frame.height != height {
            document.setFrameSize(NSSize(width: Self.paneWidth, height: height))
        }
    }

    /// Re-read anything that can change while the window is open.
    func refresh() {}

    // MARK: - Building blocks

    func heading(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(label)
    }

    /// Explanatory copy. States the trade-off rather than hiding it in a
    /// tooltip: a tooltip is a place to put something you have decided nobody
    /// needs to read.
    @discardableResult
    func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Pane.paneWidth - 60
        stack.addArrangedSubview(label)
        return label
    }

    @discardableResult
    func checkbox(_ title: String, _ on: Bool, _ action: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        button.state = on ? .on : .off
        let handler = ActionHandler { sender in
            action((sender as? NSButton)?.state == .on)
        }
        button.target = handler
        button.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(button)
        return button
    }

    @discardableResult
    func button(_ title: String, _ action: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        let handler = ActionHandler { _ in action() }
        button.target = handler
        button.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(button)
        return button
    }

    func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        stack.addArrangedSubview(row)
        return row
    }

    func separator() {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(line)
        line.widthAnchor.constraint(equalToConstant: Pane.paneWidth - 44).isActive = true
    }
}

/// Top-left origin, so a settings pane reads downwards like everything else.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Closure-to-selector bridge, so panes read as a list of controls rather than
/// a list of `@objc` methods.
final class ActionHandler: NSObject {
    private let action: (Any?) -> Void
    init(_ action: @escaping (Any?) -> Void) { self.action = action }
    @objc func fire(_ sender: Any?) { action(sender) }
}

// ---------------------------------------------------------------------------

@MainActor
final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var controller: NSTabViewController?

    func show(_ tab: SettingsTab = .general) {
        if window == nil { build() }
        controller?.selectedTabViewItemIndex = tab.rawValue
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let pane: Pane
            switch tab {
            case .general:     pane = GeneralPane()
            case .models:      pane = ModelsPane()
            case .storage:     pane = StoragePane()
            case .permissions: pane = PermissionsPane()
            case .developers:  pane = DevelopersPane()
            case .about:       pane = AboutPane()
            }
            let item = NSTabViewItem(viewController: pane)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: nil)
            tabs.addTabViewItem(item)
        }

        let w = NSWindow(contentViewController: tabs)
        w.title = "Listen Settings"
        w.styleMask = [.titled, .closable]
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        controller = tabs
    }
}

// ---------------------------------------------------------------------------

final class GeneralPane: Pane {
    private var loginBox: NSButton?
    private var deviceMenu: NSPopUpButton?
    private var skipList: NSStackView?
    private var addButton: NSPopUpButton?

    override func build() {
        heading("Startup")
        loginBox = checkbox("Open Listen at login", LoginItem.state.isSelected) { on in
            if let message = LoginItem.setEnabled(on) {
                let alert = NSAlert()
                alert.messageText = message
                alert.runModal()
            }
        }

        separator()
        heading("Meetings")
        checkbox("Record when a meeting starts, and ask", Settings.autoDetectMeetings) {
            Settings.autoDetectMeetings = $0
            MeetingDetector.shared.refresh()
        }
        note("Watches for an app that is listening and speaking at once, which is what a "
             + "call looks like from outside. Capture starts immediately and a panel asks "
             + "whether you are in a meeting: saying no deletes it. It records first "
             + "because the minute spent answering is the minute where people say who "
             + "they are. Off by default, and recording from the menu bar always works "
             + "either way.")

        separator()
        heading("Never ask about these apps")
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        stack.addArrangedSubview(list)
        skipList = list

        let add = NSPopUpButton()
        add.pullsDown = true
        let addHandler = ActionHandler { [weak self] _ in self?.addSkipped() }
        add.target = addHandler
        add.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(add, "handler", addHandler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(add)
        addButton = add

        note("Listening and speaking at once is a broader rule than a list of known "
             + "meeting apps, which is deliberate: a guessed list misses the fifth thing "
             + "you join a call in. The cost is that other recorders match it too, so "
             + "Blackbox and anything like it belongs here. The panel's \"Never for…\" "
             + "button adds an app without coming back to this pane.")

        separator()
        heading("Microphone")
        let menu = NSPopUpButton()
        let handler = ActionHandler { [weak self] _ in self?.deviceChanged() }
        menu.target = handler
        menu.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(menu, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(menu)
        deviceMenu = menu
        note("Your own track. The other side of the call is captured separately and does "
             + "not come through this device.")
    }

    override func refresh() {
        loginBox?.state = LoginItem.state.isSelected ? .on : .off
        refreshSkipped()
        guard let menu = deviceMenu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "System default")
        for device in AudioDevices.inputs() {
            menu.addItem(withTitle: device.name)
            menu.lastItem?.representedObject = device.uid
        }
        // Show a missing device rather than silently falling back to the
        // default, which is how someone records a meeting from the wrong
        // microphone and finds out afterwards.
        if let uid = Settings.microphoneUID {
            if let index = menu.itemArray.firstIndex(where: {
                $0.representedObject as? String == uid
            }) {
                menu.selectItem(at: index)
            } else {
                menu.addItem(withTitle: "Not connected")
                menu.lastItem?.representedObject = uid
                menu.selectItem(at: menu.numberOfItems - 1)
            }
        } else {
            menu.selectItem(at: 0)
        }
    }

    private func deviceChanged() {
        Settings.microphoneUID = deviceMenu?.selectedItem?.representedObject as? String
    }

    // MARK: - Skipped apps

    private func refreshSkipped() {
        guard let list = skipList else { return }
        for view in list.arrangedSubviews { view.removeFromSuperview() }

        let skipped = Settings.skippedBundleIDs.sorted {
            AppNames.display($0).localizedCaseInsensitiveCompare(AppNames.display($1))
                == .orderedAscending
        }
        if skipped.isEmpty {
            let empty = NSTextField(labelWithString: "Nothing skipped.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty)
        }
        for id in skipped {
            list.addArrangedSubview(skipRow(id))
        }
        refreshAddMenu()
    }

    private func skipRow(_ bundleID: String) -> NSView {
        let image = NSImageView()
        image.image = AppNames.icon(bundleID)
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 16).isActive = true
        image.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let name = NSTextField(labelWithString: AppNames.display(bundleID))
        name.font = .systemFont(ofSize: 12)
        // The identifier as the tooltip, because two apps can share a display
        // name and the list has to be unambiguous enough to remove the right
        // one.
        name.toolTip = bundleID

        let remove = NSButton(title: "Remove", target: nil, action: nil)
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        let handler = ActionHandler { [weak self] _ in
            Settings.unskip(bundleID)
            self?.refreshSkipped()
        }
        remove.target = handler
        remove.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(remove, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        // A fixed row width and a spacer that absorbs the slack, so every
        // Remove lands in the same column. An `NSStackView` packs its arranged
        // subviews against the leading edge and leaves the rest as trailing
        // space, so without the spacer each row is only as wide as its own app
        // name and the buttons come out in a ragged diagonal that reads as five
        // unrelated controls rather than one list. Lowering the label's hugging
        // priority is not enough on its own; the slack has to have somewhere to
        // go.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        name.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [image, name, spacer, remove])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Pane.paneWidth - 44).isActive = true
        return row
    }

    /// The add menu, populated from what is running now.
    ///
    /// Accessory apps are included, not just the ones with a Dock icon. The
    /// apps most worth skipping are menu bar recorders, and a "regular apps
    /// only" filter would leave exactly those unselectable.
    private func refreshAddMenu() {
        guard let add = addButton else { return }
        add.removeAllItems()
        add.addItem(withTitle: "Add App…")       // the pull-down's own title

        let skipped = Settings.skippedBundleIDs
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, !skipped.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

        var seen = Set<String>()
        for (id, name) in running where seen.insert(id).inserted {
            add.addItem(withTitle: name)
            add.lastItem?.representedObject = id
            add.lastItem?.image = AppNames.icon(id)
            add.lastItem?.image?.size = NSSize(width: 16, height: 16)
        }
        add.isEnabled = add.numberOfItems > 1
    }

    private func addSkipped() {
        guard let id = addButton?.selectedItem?.representedObject as? String else { return }
        Settings.skip(id)
        refreshSkipped()
    }
}

// ---------------------------------------------------------------------------

final class ModelsPane: Pane {
    private var labels: [String: NSTextField] = [:]
    private var diarizerNote: NSTextField?

    override func build() {
        heading("Speech model")
        note("Parakeet runs on this Mac. Nothing is uploaded.")

        for choice in ModelChoice.all {
            let radio = NSButton(radioButtonWithTitle: choice.title, target: nil, action: nil)
            radio.state = Settings.model.id == choice.id ? .on : .off
            let handler = ActionHandler { [weak self] _ in
                Settings.model = choice
                self?.refresh()
            }
            radio.target = handler
            radio.action = #selector(ActionHandler.fire(_:))
            objc_setAssociatedObject(radio, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
            stack.addArrangedSubview(radio)

            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
            stack.addArrangedSubview(status)
            labels[choice.id] = status
        }

        note("v2 is the default because it is English-only and therefore cannot decode "
             + "your speech as another language. v3 covers 25 European languages but will "
             + "sometimes misidentify a short clip, and there is no language picker "
             + "because the underlying library ignores one.")

        separator()
        heading("Speaker recognition")
        diarizerNote = note("")
    }

    override func refresh() {
        for choice in ModelChoice.all {
            // Say plainly when the weights are already here because Speak
            // fetched them. "Already on disk" and "already on disk, shared with
            // Speak" answer different questions: the second one tells you that
            // deleting it takes dictation away too.
            let text: String
            if choice.isSharedWithSpeak {
                text = "\(ModelChoice.humanBytes(choice.bytesUsed)) on disk, shared with Speak"
            } else if choice.isDownloaded {
                text = "\(ModelChoice.humanBytes(choice.bytesUsed)) on disk"
            } else {
                text = "not downloaded · \(ModelChoice.humanBytes(choice.approxBytes))"
            }
            labels[choice.id]?.stringValue = text
        }
        diarizerNote?.stringValue = Diarizer.isDownloaded
            ? "Diarization models are on disk. They are separate from Parakeet and are "
              + "not shared with Speak."
            : "Diarization models download the first time you transcribe a meeting. "
              + "They are much smaller than the speech model."
    }
}

// ---------------------------------------------------------------------------

final class StoragePane: Pane {
    private var usage: NSTextField?
    private var staged: NSTextField?

    override func build() {
        heading("Library")
        note(Library.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        usage = note("")
        button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil,
                inFileViewerRootedAtPath: Library.recordings.path)
        }

        separator()
        heading("Unconfirmed recordings")
        staged = note("")
        note("Listen starts writing to disk the moment capture begins, before you press "
             + "Keep, so the first minute of a meeting is never lost. Anything you never "
             + "answered for is deleted after 24 hours.")
        button("Delete unconfirmed recordings now") { [weak self] in
            for recording in Recording.staged() { try? recording.delete() }
            self?.refresh()
        }
    }

    override func refresh() {
        let recordings = Recording.all()
        usage?.stringValue = "\(recordings.count) recording"
            + (recordings.count == 1 ? "" : "s")
            + " · " + ModelChoice.humanBytes(Self.size(of: Library.recordings))

        let waiting = Recording.staged()
        staged?.stringValue = waiting.isEmpty
            ? "Nothing waiting."
            : "\(waiting.count) waiting · "
              + ModelChoice.humanBytes(Self.size(of: Library.staging))
    }

    static func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

// ---------------------------------------------------------------------------

final class PermissionsPane: Pane {
    private var micLabel: NSTextField?
    private var tapLabel: NSTextField?

    override func build() {
        heading("Microphone")
        micLabel = note("")
        button("Open System Settings") { Permissions.openMicrophoneSettings() }

        separator()
        heading("System audio")
        tapLabel = note("")
        note("Listen records the other side of a call with a Core Audio process tap, "
             + "which asks for audio recording and not screen recording. That is the "
             + "whole reason it works this way: hearing a meeting should not cost access "
             + "to everything on your screen.")
    }

    override func refresh() {
        micLabel?.stringValue = Permissions.microphone
            ? "Granted. Your own voice is recorded."
            : (Permissions.microphoneDenied
               ? "Denied. Listen can still record the other side of a call, but not you."
               : "Not granted yet. Listen asks the first time you record.")

        if !Permissions.systemAudioSupported {
            tapLabel?.stringValue = "Needs macOS 14.2 or later. On this Mac only your "
                + "microphone can be recorded."
        } else {
            tapLabel?.stringValue = Permissions.systemAudio
                ? "Working. The other side of a call is recorded."
                : "Not available. Grant the microphone permission above, which is the "
                  + "same permission a process tap needs."
        }
    }
}

// ---------------------------------------------------------------------------

final class AboutPane: Pane {
    override func build() {
        let name = NSTextField(labelWithString: "Listen")
        name.font = .systemFont(ofSize: 22, weight: .semibold)
        stack.addArrangedSubview(name)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        note("Version \(version) (build \(build))")

        note("A local meeting recorder, transcriber and speaker labeller. Audio never "
             + "leaves this Mac. The only network connections Listen makes are "
             + "downloading models the first time and checking for updates.")

        separator()
        heading("Built on")
        note("Parakeet by NVIDIA, through mlx-audio-swift and MLX by Apple. "
             + "Diarization and speaker embeddings by FluidAudio. "
             + "Updates by Sparkle.")

        separator()
        button("Check for Updates") { Updater.shared.checkForUpdates(nil) }
    }
}

// ---------------------------------------------------------------------------

final class DevelopersPane: Pane {
    private var cliLabel: NSTextField?
    private var installButton: NSButton?

    override func build() {
        heading("Command line")
        note("`listen` is the same binary as the app, so it never goes stale: it is "
             + "symlinked into place rather than copied.")
        cliLabel = note("")
        installButton = button("Install") { [weak self] in self?.install() }
        button("Remove") { [weak self] in
            CLIInstall.uninstall()
            self?.refresh()
        }

        separator()
        heading("MCP")
        note("`listen mcp` serves the library to an agent over stdio. Read-only, no "
             + "port, and the app does not need to be running. Paste this into your "
             + "MCP client configuration.")

        let field = NSTextView()
        field.string = MCPConfig.json
        field.isEditable = false
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        let box = NSScrollView()
        box.documentView = field
        box.hasVerticalScroller = true
        box.borderType = .bezelBorder
        box.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(box)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: Pane.paneWidth - 44),
            box.heightAnchor.constraint(equalToConstant: 120),
        ])

        button("Copy configuration") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(MCPConfig.json, forType: .string)
        }
    }

    override func refresh() {
        let state = CLIInstall.state
        var text = state.summary
        // An installed command that is not on the PATH cannot be run, and
        // nothing else would say why.
        if case .installed(let path) = state, !CLIInstall.isOnPath(path) {
            text += ". That directory is not on your PATH, so add it to your shell "
                + "profile or the command will not be found."
        }
        cliLabel?.stringValue = text
        installButton?.title = state == .notInstalled ? "Install" : "Reinstall"
    }

    private func install() {
        do {
            let path = try CLIInstall.install()
            log("installed the command at \(path)")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not install the command"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refresh()
    }
}
