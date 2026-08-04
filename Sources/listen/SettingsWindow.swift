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
    static let paneHeight: CGFloat = 430
    static let paneWidth: CGFloat = 560

    let stack = NSStackView()

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

        let clip = NSView(frame: scroll.bounds)
        clip.addSubview(stack)
        scroll.documentView = clip

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            // Both a top constraint and a height of at least the clip view's.
            // An NSClipView is not flipped, so a document view shorter than it
            // is placed at the *bottom*: with only the top constraint a short
            // pane hangs off the floor of the window. Filling the height hands
            // the slack to the trailing spacer instead.
            stack.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            clip.widthAnchor.constraint(equalToConstant: Self.paneWidth),
            clip.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.paneHeight),
        ])
        view = scroll
        build()
        stack.addArrangedSubview(NSView())      // spacer keeps content top-aligned
    }

    /// Overridden by each pane.
    func build() {}

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
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
        checkbox("Offer to record when a meeting starts", Settings.autoDetectMeetings) {
            Settings.autoDetectMeetings = $0
        }
        note("Watches for Zoom, Meet, Teams and Slack huddles becoming audio-active. "
             + "Off by default: an app that starts recording the first time you join a "
             + "call, before you have asked it to, is a worse first impression than one "
             + "that waits. Recording from the menu bar always works either way.")

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
