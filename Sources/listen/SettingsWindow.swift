import AVFoundation
import AppKit

/// Which section, by name.
///
/// Never a literal index. Speak's menu opened "About" as tab 4, so inserting a
/// tab above it would silently have opened Permissions instead. The raw `Int`
/// this used to carry was that index, read by `NSTabViewController`; the
/// sections live in the library window's sidebar now, so it is gone rather than
/// left lying around for someone to index by again.
enum SettingsTab: CaseIterable {
    case general, storage, permissions
    case meetings, audio
    case models, dictionary
    case developers, about

    var title: String {
        switch self {
        case .general:     return "General"
        case .storage:     return "Storage"
        case .permissions: return "Permissions"
        case .meetings:    return "Meetings"
        case .audio:       return "Audio"
        case .models:      return "Models"
        case .dictionary:  return "Dictionary"
        case .developers:  return "Developers"
        case .about:       return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general:     return "gearshape"
        case .storage:     return "internaldrive"
        case .permissions: return "lock.shield"
        case .meetings:    return "video"
        case .audio:       return "mic"
        case .models:      return "cpu"
        case .dictionary:  return "character.book.closed"
        case .developers:  return "terminal"
        case .about:       return "info.circle"
        }
    }

    @MainActor
    func makePane() -> Pane {
        let pane: Pane
        switch self {
        case .general:     pane = GeneralPane()
        case .storage:     pane = StoragePane()
        case .permissions: pane = PermissionsPane()
        case .meetings:    pane = MeetingsPane()
        case .audio:       pane = AudioPane()
        case .models:      pane = ModelsPane()
        case .dictionary:  pane = DictionaryPane()
        case .developers:  pane = DevelopersPane()
        case .about:       pane = AboutPane()
        }
        // Here rather than at the call site, so a pane and the heading it draws
        // cannot disagree about which section it is.
        pane.tab = self
        return pane
    }
}

/// How the sections are grouped in the sidebar.
///
/// Nine rows in one flat list is a list you read rather than scan. The groups
/// are the same shape Anarlog uses, and they are named after what is in them:
/// "Recording" is what happens while a meeting runs and "Transcription" is what
/// happens to it afterwards, which is also the order they happen in.
enum SettingsGroup: CaseIterable {
    case app, recording, transcription, advanced

    var title: String {
        switch self {
        case .app:           return "App"
        case .recording:     return "Recording"
        case .transcription: return "Transcription"
        case .advanced:      return "Advanced"
        }
    }

    var tabs: [SettingsTab] {
        switch self {
        case .app:           return [.general, .storage, .permissions]
        case .recording:     return [.meetings, .audio]
        case .transcription: return [.models, .dictionary]
        case .advanced:      return [.developers, .about]
        }
    }
}

/// A settings pane.
///
/// It lives in the library window's content side, so it is as wide as the
/// window and scrolls when it is taller. It used to be a fixed 560 x 500 box
/// because `NSTabViewController` sized a non-resizable window to the tallest
/// pane; nothing sizes to it any more, so the only fixed number left is the cap
/// on how wide a line of text is allowed to get.
@MainActor
class Pane: NSViewController {
    /// The width the pane is built at, before the window has ever laid it out.
    /// A floor, not a promise: `sizeDocument` takes over from the first layout.
    static let paneWidth: CGFloat = 560
    static let paneHeight: CGFloat = 500

    /// How wide a run of text or a full-width row is allowed to get.
    ///
    /// Without a cap, a note stretches to whatever the window is and a sentence
    /// runs 1400 points across a screen nobody can track a line on. The controls
    /// are leading-aligned already, so capping the text keeps one left edge and
    /// one comfortable measure.
    static let maxContentWidth: CGFloat = 620

    /// Which section this is, set by `SettingsTab.makePane`.
    var tab: SettingsTab = .general

    let stack = NSStackView()
    private var document: NSView?
    private let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Pane.paneWidth,
                                                    height: Pane.paneHeight))
    /// Every wrapping label, so their `preferredMaxLayoutWidth` can be moved
    /// when the window is resized. See `sizeDocument`.
    private var notes: [NSTextField] = []

    override func loadView() {
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        // 24 on each side, so the content lines up with the page title above it
        // and with the recording title the pane replaces.
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 24, right: 24)
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

        // The section name, in the place and the size the recording title
        // occupies in the other mode, so switching between them does not move
        // the heading. Static rather than scrolling with the content: the window
        // has a transparent full-size title bar, and content scrolling under it
        // draws over the traffic lights.
        let title = NSTextField(labelWithString: tab.title)
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(title)
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 38),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                            constant: -24),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        view = container
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

    /// Tear the pane down and build it again.
    ///
    /// For a pane whose *shape* changes rather than its values, which `refresh`
    /// cannot express: the dictionary's two halves have different columns and a
    /// different explanation underneath, so switching between them is a rebuild
    /// and not a reload.
    func rebuild() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        build()
        refresh()
        resizeDocument()
    }

    /// Size the document to the content, and put the pane back at the top.
    ///
    /// The two halves are separate because only one of them is wanted on a
    /// resize: `sizeDocument` has to run on every layout pass to follow the
    /// window, and scrolling to the top on every layout pass would drag the pane
    /// back to its first control while somebody was reading the last one.
    func resizeDocument() {
        sizeDocument()
        // Growing the document under a clip view leaves the clip where it was,
        // which on a pane that just became scrollable means opening part-way
        // down with the first heading out of sight. A settings pane always
        // starts at its first control.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        sizeDocument()
    }

    private func sizeDocument() {
        guard let document else { return }
        let width = scroll.contentSize.width
        guard width > 0 else { return }

        // Before measuring the height, not after. An `NSTextField` computes its
        // height from `preferredMaxLayoutWidth` and not from whatever width it
        // has been given, so a note left at the old width reports the old height
        // and loses its last line as the window narrows. Only when it changed:
        // setting it dirties layout, and setting it unconditionally from
        // `viewDidLayout` is a layout pass that schedules another one forever.
        let content = contentWidth
        for note in notes where abs(note.preferredMaxLayoutWidth - content) > 0.5 {
            note.preferredMaxLayoutWidth = content
        }

        stack.layoutSubtreeIfNeeded()
        let size = NSSize(width: width,
                          height: max(scroll.contentSize.height, stack.fittingSize.height))
        if document.frame.size != size { document.setFrameSize(size) }
    }

    /// How wide a full-width row in this pane currently is.
    private var contentWidth: CGFloat {
        let inset = stack.edgeInsets.left + stack.edgeInsets.right
        return min(max(scroll.contentSize.width - inset, 0), Pane.maxContentWidth)
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
        label.preferredMaxLayoutWidth = contentWidth
        stack.addArrangedSubview(label)
        widthCapped(label)
        notes.append(label)
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

    @discardableResult
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
        stack.addArrangedSubview(line)
        widthCapped(line)
    }

    /// Make a view as wide as the pane allows, up to `maxContentWidth`.
    ///
    /// The stack is leading-aligned, so it does not stretch what it arranges:
    /// anything that should span the pane has to say so. A low-priority equality
    /// with a required maximum resolves to the smaller of the two, which is the
    /// full width in a narrow window and the cap in a wide one. 500 rather than
    /// `.defaultLow`, which is the same 250 an `NSTextField` hugs at, and a tie
    /// there leaves the width ambiguous.
    func widthCapped(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        let fill = view.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(stack.edgeInsets.left + stack.edgeInsets.right))
        fill.priority = NSLayoutConstraint.Priority(500)
        NSLayoutConstraint.activate([
            fill,
            view.widthAnchor.constraint(lessThanOrEqualToConstant: Pane.maxContentWidth),
        ])
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

final class GeneralPane: Pane {
    private var loginBox: NSButton?

    override func build() {
        heading("Startup")
        loginBox = checkbox("Open Listen at login", LoginItem.state.isSelected) { on in
            if let message = LoginItem.setEnabled(on) {
                let alert = NSAlert()
                alert.messageText = message
                alert.runModal()
            }
        }
        note("Listen sits in the menu bar and records nothing until it is asked to, or "
             + "until it sees a meeting start.")
    }

    override func refresh() {
        loginBox?.state = LoginItem.state.isSelected ? .on : .off
    }
}

// ---------------------------------------------------------------------------

final class AudioPane: Pane {
    private var deviceMenu: NSPopUpButton?

    override func build() {
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

final class MeetingsPane: Pane {
    private var skipList: NSStackView?
    private var addButton: NSPopUpButton?
    private var calendarNote: NSTextField?

    override func build() {
        heading("Detection")
        checkbox("Record when a meeting starts, and ask", Settings.autoDetectMeetings) {
            Settings.autoDetectMeetings = $0
            MeetingDetector.shared.refresh()
        }
        note("Watches for an app that is listening and speaking at once, which is what a "
             + "call looks like from outside. Capture starts immediately and a panel asks "
             + "whether you are in a meeting: saying no deletes it. It records first "
             + "because the minute spent answering is the minute where people say who "
             + "they are. On by default, because a recorder you have to remember to turn "
             + "on is off for the meeting you needed it for. Recording from the menu bar "
             + "works either way.")

        separator()
        heading("Calendar")
        checkbox("Name a recording after the meeting it lines up with",
                 Settings.nameFromCalendar) { Settings.nameFromCalendar = $0 }
        calendarNote = note("")
        note("A meeting counts as the same one when it starts within ten minutes of the "
             + "recording. Measured over this library: at ten minutes, fourteen of "
             + "forty-seven recordings matched and every match was right; at thirty, two "
             + "more matched and both were wrong. A name you typed yourself is never "
             + "replaced. Who was invited is remembered either way, and offered when you "
             + "name a speaker.")
        note("The calendar is only read, never written to. Google and Microsoft accounts "
             + "come through whatever you have added in System Settings, Internet "
             + "Accounts, so there is no account to make here and nothing leaves this Mac.")

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
    }

    override func refresh() {
        refreshSkipped()
        // The setting can be on while the permission is missing, and from the
        // checkbox alone that is indistinguishable from the feature not
        // working. Said here rather than left to be discovered.
        calendarNote?.stringValue = MeetingCalendar.isAuthorized
            ? "Reading \(MeetingCalendar.calendars().count) calendar(s) on this Mac."
            : "Listen has no calendar access yet, so this does nothing. "
              + "Settings → Permissions → Calendar."
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
            let row = skipRow(id)
            // Added first, then widened. `widthCapped` constrains the row
            // against the pane's stack, and two views with no common ancestor
            // yet is an exception rather than a layout that sorts itself out.
            list.addArrangedSubview(row)
            widthCapped(row)
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

        // A full row width and a spacer that absorbs the slack, so every Remove
        // lands in the same column. An `NSStackView` packs its arranged
        // subviews against the leading edge and leaves the rest as trailing
        // space, so without the spacer each row is only as wide as its own app
        // name and the buttons come out in a ragged diagonal that reads as five
        // unrelated controls rather than one list. Lowering the label's hugging
        // priority is not enough on its own; the slack has to have somewhere to
        // go. The width itself comes from `widthCapped`, once the row is in the
        // hierarchy.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        name.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [image, name, spacer, remove])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        row.distribution = .fill
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
    private var getButton: NSButton?
    private var progress: NSProgressIndicator?
    private var progressNote: NSTextField?

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

        // The button this pane did not have. Without it, a Mac whose weights
        // went away showed "not downloaded" and offered nothing: the only way
        // to ask for the fetch was setup's model step, which is behind About,
        // Run setup again, and nothing here said so.
        getButton = button("Download") { [weak self] in
            guard let self else { return }
            if ModelDownload.shared.isDownloading {
                ModelDownload.shared.cancel()
            } else {
                ModelDownload.shared.start(Settings.model)
            }
            self.refresh()
        }

        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.isHidden = true
        stack.addArrangedSubview(bar)
        widthCapped(bar)
        progress = bar

        progressNote = note("")

        note("v2 is the default because it is English-only and therefore cannot decode "
             + "your speech as another language. v3 covers 25 European languages but will "
             + "sometimes misidentify a short clip, and there is no language picker "
             + "because the underlying library ignores one.")

        separator()
        heading("Speaker recognition")
        diarizerNote = note("")

        // Follow a download this pane did not start, including the implicit
        // one a recording triggers.
        ModelDownload.shared.onChange = { [weak self] in self?.refresh() }
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

        let status = ModelDownload.shared.status
        let chosen = Settings.model
        getButton?.isHidden = chosen.isDownloaded && !status.isBusy
        getButton?.title = status.isBusy
            ? "Cancel"
            : "Download \(chosen.title) (\(ModelChoice.humanBytes(chosen.approxBytes)))"

        if let fraction = status.fraction {
            progress?.isHidden = false
            progress?.doubleValue = fraction
        } else {
            progress?.isHidden = !status.isBusy
            progress?.doubleValue = 0
        }

        // Only speak when there is something to say. A permanent "ready" under
        // a model that is plainly on disk is noise.
        if case .ready = status {
            progressNote?.stringValue = ""
        } else {
            progressNote?.stringValue = status.summary
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
    private var calendarLabel: NSTextField?
    private var calendarButton: NSButton?

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

        separator()
        heading("Calendar")
        calendarLabel = note("")
        // One button for both jobs, dispatching at click time. macOS only lists
        // an app under Privacy, Calendars once it has asked, so before the
        // first request there is no switch in System Settings to send anyone
        // to, and a button that opens an empty pane is worse than no button.
        calendarButton = button("Allow calendar access") { [weak self] in
            if Permissions.calendarAction == .canAsk {
                Permissions.requestCalendar { _ in self?.refresh() }
            } else {
                Permissions.openCalendarSettings()
            }
        }
        note("Unlike the two above, this one is optional. Without it Listen still "
             + "records, transcribes and labels; what it loses is the meeting's name "
             + "and the list of who was invited. It reads the calendars already on "
             + "this Mac, including Google and Microsoft accounts added in System "
             + "Settings, Internet Accounts. Nothing is sent anywhere and nothing is "
             + "ever written back to a calendar.")
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

        switch Permissions.calendarAction {
        case .granted:
            calendarButton?.title = "Open System Settings"
            // The count, not just "granted". A grant that reaches an empty
            // calendar store looks identical to a working one from here, and
            // that is the failure this row exists to make visible.
            let count = MeetingCalendar.calendars().count
            calendarLabel?.stringValue = count == 0
                ? "Granted, but there are no calendars on this Mac to read."
                : "Granted. Reading \(count) calendar\(count == 1 ? "" : "s")."
        case .canAsk:
            calendarButton?.title = "Allow calendar access"
            calendarLabel?.stringValue = "Not granted yet."
        case .settingsOnly:
            calendarButton?.title = "Open System Settings"
            // Split from "denied", because the two look identical from here and
            // are fixed the same way, but only one of them is a decision
            // anybody made: a dismissed prompt records nothing, so the status
            // still says nobody has been asked.
            calendarLabel?.stringValue = Permissions.calendarDenied
                ? "Denied. Recordings keep the name you give them, and speakers are "
                  + "named by hand."
                : "Asked, and not granted. The button below opens System Settings, "
                  + "where Listen can be switched on under Calendars."
        }
    }
}

// ---------------------------------------------------------------------------

final class AboutPane: Pane {
    private static let websiteURL = "https://maxgoespublic.com/"

    override func build() {
        // No "Listen" heading here any more: the pane draws its own section
        // name at the top, and two 22pt words above the version number read as
        // a mistake rather than as a title.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        note("Version \(version) (build \(build))")

        note("A local meeting recorder, transcriber and speaker labeller. Audio never "
             + "leaves this Mac. The only network connections Listen makes are "
             + "downloading models the first time and checking for updates.")

        separator()
        heading("Setup")
        button("Run setup again…") { Onboarding.shared.restart() }
        note("Walks through the permissions and the speech model. It changes nothing "
             + "you have already chosen, and it is the quickest way to find out which "
             + "part has stopped working.")

        separator()
        heading("Made by")
        // A plain label rather than `note`, which is 11pt and secondary: a
        // person's name is not a footnote to the credits below it. Same shape
        // as Speak's About pane.
        let author = NSTextField(labelWithString: "Maxime Goossens")
        author.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(author)
        let site = button(Self.websiteURL) {
            if let url = URL(string: Self.websiteURL) { NSWorkspace.shared.open(url) }
        }
        site.bezelStyle = .inline
        site.controlSize = .small

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
        heading("CLI")
        note("`listen` is the same binary as the app, so it never goes stale: it is "
             + "symlinked into place rather than copied.")
        cliLabel = note("")
        // One button, not an Install and a Remove side by side. Only one of
        // them was ever the right thing to press, and showing both made the
        // pane ask a question it could answer itself.
        installButton = button("Install") { [weak self] in self?.toggle() }

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
        stack.addArrangedSubview(box)
        widthCapped(box)
        box.heightAnchor.constraint(equalToConstant: 120).isActive = true

        button("Copy configuration") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(MCPConfig.json, forType: .string)
        }
    }

    override func refresh() {
        let state = CLIInstall.state
        var text = state.summary
        // The version the command would actually report. Read from the bundle
        // the symlink resolves to, so a link left pointing at an older copy
        // says so instead of borrowing this app's version number.
        if let version = CLIInstall.installedVersion {
            text += " · \(version)"
        }
        // An installed command that is not on the PATH cannot be run, and
        // nothing else would say why.
        if case .installed(let path) = state, !CLIInstall.isOnPath(path) {
            text += ". That directory is not on your PATH, so add it to your shell "
                + "profile or the command will not be found."
        }
        cliLabel?.stringValue = text

        switch state {
        case .notInstalled: installButton?.title = "Install"
        case .installed:    installButton?.title = "Remove"
        // Reinstall rather than Remove, because the useful move for a link
        // pointing at another copy is to repoint it here. Removing stays one
        // press away: it becomes `.installed` and the button says Remove.
        case .stale:        installButton?.title = "Reinstall"
        }
    }

    /// Install or remove, whichever the current state calls for.
    private func toggle() {
        if case .installed = CLIInstall.state {
            CLIInstall.uninstall()
            refresh()
            return
        }
        install()
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
