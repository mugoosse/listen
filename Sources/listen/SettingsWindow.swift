import AVFoundation
import AppKit
import ListenKit

/// Which section, by name.
///
/// Never a literal index. Speak's menu opened "About" as tab 4, so inserting a
/// tab above it would silently have opened Permissions instead. The raw `Int`
/// this used to carry was that index, read by `NSTabViewController`; the
/// sections live in the library window's sidebar now, so it is gone rather than
/// left lying around for someone to index by again.
enum SettingsTab: CaseIterable {
    case general, storage, permissions, privacy
    case meetings, audio
    case models, dictionary
    case dictation
    case agent
    case devices
    case developers, updates

    var title: String {
        switch self {
        case .general:     return "General"
        case .storage:     return "Storage"
        case .permissions: return "Permissions"
        // What the section decides is what leaves the machine, and Privacy is
        // the word somebody scans for when that is their question.
        case .privacy:     return "Privacy"
        case .meetings:    return "Meetings"
        case .audio:       return "Audio"
        case .models:      return "Models"
        case .dictionary:  return "Dictionary"
        case .dictation:   return "Dictation"
        // "Ask", not "Agent". The window calls this mode Ask, the CLI is
        // `listen ask`, and "agent" describes two of the four backends: Ollama
        // and OpenRouter are not agents, they are models Listen drives itself.
        // The settings sidebar was the last place using the word.
        case .agent:       return "Ask"
        // "Sync", not "Devices". The list of devices is one thing on this pane
        // and no longer the point of it: what somebody comes here to find out
        // is whether their library is in step, and only then which machines are
        // on it. The old name is what the pairing screen was called.
        case .devices:     return "Sync"
        case .developers:  return "Developers"
        // "Updates", not "About". The identity of the app, the credits and
        // every link out of it moved to `AboutWindow`, and what is left here is
        // the version check and the way back into setup. A section called About
        // holding neither would send somebody looking for the website into a
        // page that no longer has one.
        case .updates:     return "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general:     return "gearshape"
        case .storage:     return "internaldrive"
        case .permissions: return "lock.shield"
        case .privacy:     return "hand.raised"
        case .meetings:    return "video"
        case .audio:       return "mic"
        case .models:      return "cpu"
        case .dictionary:  return "character.book.closed"
        case .dictation:   return "mic.badge.plus"
        case .agent:       return "bubble.left.and.text.bubble.right"
        // An icon about being in step rather than about handing something to a
        // phone, which is what the arrow meant when this was pairing.
        case .devices:     return "arrow.triangle.2.circlepath"
        case .developers:  return "terminal"
        case .updates:     return "arrow.down.circle"
        }
    }

    @MainActor
    func makePane() -> Pane {
        let pane: Pane
        switch self {
        case .general:     pane = GeneralPane()
        case .storage:     pane = StoragePane()
        case .permissions: pane = PermissionsPane()
        case .privacy:     pane = PrivacyPane()
        case .meetings:    pane = MeetingsPane()
        case .audio:       pane = AudioPane()
        case .models:      pane = ModelsPane()
        case .dictionary:  pane = DictionaryPane()
        case .dictation:   pane = DictationPane()
        case .agent:       pane = AgentPane()
        case .devices:     pane = DevicesPane()
        case .developers:  pane = DevelopersPane()
        case .updates:     pane = UpdatesPane()
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
    case app, recording, transcription, dictation, ask, advanced

    var title: String {
        switch self {
        case .app:           return "App"
        case .recording:     return "Recording"
        case .transcription: return "Transcription"
        case .dictation:     return "Dictation"
        case .ask:           return "Ask"
        case .advanced:      return "Advanced"
        }
    }

    var tabs: [SettingsTab] {
        switch self {
        // Sync sits with the app's own settings, on Ask's argument above.
        // It was in Advanced when it was a pairing screen: a QR code, a typed
        // code, a list of things that had scanned it, all of it setup you did
        // once. There is no pairing any more. What the pane says now is whether
        // this library is reaching your other machines, which is the product's
        // whole claim and the first thing to look at when it seems not to be.
        // Updates sits here rather than in Advanced, where it was while this
        // section was About. Whether the app is current is not an advanced
        // question, and Advanced is where things go that most people never
        // open.
        case .app:           return [.general, .storage, .permissions, .privacy,
                                     .devices, .updates]
        case .recording:     return [.meetings, .audio]
        case .transcription: return [.models, .dictionary]
        // A group of one, and worth the header. Dictation is a second thing the
        // app does rather than a detail of the first: "Recording" is what
        // happens during a meeting and "Transcription" is what happens to it
        // afterwards, and this is neither. Folding it under Transcription would
        // file the feature under the machinery it happens to share.
        case .dictation:     return [.dictation]
        // **A group of one, on Dictation's own argument.** This used to sit in
        // Advanced beside Devices, because both were integrations with
        // something installed and signed into elsewhere. That was true when the
        // feature was "drive a CLI somebody happens to have", and it stopped
        // being true: with providers, a model on this Mac and a key, asking the
        // library is a third thing the app does rather than a detail of the
        // other two. Advanced is where things go that most people never open,
        // and this is not one of them any more.
        //
        // It sits after Transcription and Dictation because that is the order
        // things happen in: record it, transcribe it, then ask about it.
        case .ask:           return [.agent]
        case .advanced:      return [.developers]
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
    private var nameField: NSTextField?

    override func build() {
        heading("Your name")
        let field = NSTextField(string: Settings.userName ?? "")
        // The placeholder is what the app calls you with nothing set, so the
        // field shows the current answer whether or not it has been given one.
        field.placeholderString = SpeakerName.you
        field.delegate = self
        stack.addArrangedSubview(field)
        widthCapped(field)
        nameField = field
        note("What your own track is called on screen, in the transcript, in the "
             + "roster and to an agent.\n\n"
             + "Transcripts keep saying `Me` whatever you put here, which is what "
             + "makes this safe to change your mind about: every recording you "
             + "have already made reads the same as the ones you make next, and "
             + "nothing is rewritten. Clearing it puts `Me` back.")

        separator()
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
        // Re-read rather than left alone: the same preference is set from the
        // person page's editor and from `listen me`, and a settings field
        // showing a stale name is a settings field nobody can trust.
        if let nameField, nameField.currentEditor() == nil {
            nameField.stringValue = Settings.userName ?? ""
        }
    }
}

extension GeneralPane: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField, field === nameField else { return }
        // `Settings.userName` trims and treats empty as nil, so clearing the
        // field is how you go back to `Me` and needs no separate control.
        Settings.userName = field.stringValue
        LibraryWindow.shared.reload()
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
            let text: String
            if choice.isDownloaded {
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
            ? "Diarization models are on disk. They are separate from Parakeet, and "
              + "deleting the speech model leaves them alone."
            : "Diarization models download the first time you transcribe a meeting. "
              + "They are much smaller than the speech model."
    }
}

// ---------------------------------------------------------------------------

final class StoragePane: Pane {
    private var usage: NSTextField?
    private var staged: NSTextField?
    private var kept: NSTextField?

    override func build() {
        heading("Library")
        note(Library.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        usage = note("")
        button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(nil,
                inFileViewerRootedAtPath: Library.recordings.path)
        }
        // Almost all of that number is audio, and the switch that decides how
        // much of it this Mac keeps is in Devices, beside the list of what the
        // other devices are keeping. Pointed at rather than duplicated: two
        // checkboxes for one setting is one of them being wrong.
        note("Most of that is audio. Whether this Mac keeps a copy of every "
             + "recording's audio is in Devices, next to what your other "
             + "devices are keeping.")

        separator()
        // In Storage rather than in a section of its own, and not only because
        // this pane is about the disk. Deleting a recording stops freeing its
        // space straight away once copies exist, so a number here that did not
        // account for them would be quietly wrong.
        heading("Copies")
        kept = note("")
        note("Listen keeps a copy of your library every day, and anything deleted "
             + "for two weeks, so a mistake is not final. The copies share their "
             + "contents with the library, so they take almost no extra space.")
        note("These live on this Mac. They protect you from mistakes, not from "
             + "the disk itself failing, which is what Time Machine is for.")
        button("Reveal copies in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Backups.root.path)
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

        // Said as a date rather than a count, because "7 copies" invites the
        // question this section exists to answer and a date answers it.
        kept?.stringValue = Backups.summary

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
    private var micLabel: PermissionStatusRow?
    private var tapLabel: PermissionStatusRow?
    private var calendarLabel: PermissionStatusRow?
    private var calendarButton: NSButton?
    private var accessibilityLabel: PermissionStatusRow?

    /// Watches for a grant landing while this pane is on screen.
    ///
    /// Every one of these is granted in System Settings, in another app, and
    /// macOS sends no notification when one changes. Without this the pane goes
    /// on reporting the state it was built with, so somebody who followed a
    /// button out, switched Listen on and came back is looking at a stale answer
    /// to the question they left to resolve. A few microseconds, once a second,
    /// and only while the pane is visible.
    private var poll: Timer?
    private var lastKey = ""

    override func build() {
        heading("Microphone")
        micLabel = statusRow()
        button("Open System Settings") { Permissions.openMicrophoneSettings() }

        separator()
        heading("System audio")
        tapLabel = statusRow()
        note("Listen records the other side of a call with a Core Audio process tap, "
             + "which asks for audio recording and not screen recording. That is the "
             + "whole reason it works this way: hearing a meeting should not cost access "
             + "to everything on your screen.")

        separator()
        heading("Accessibility")
        accessibilityLabel = statusRow()
        button("Open System Settings") { [weak self] in
            Permissions.openAccessibilitySettings()
            // Granted in another app, minutes from now. Arming the tap the
            // moment it lands is what stops the shortcut looking broken until
            // the next launch.
            Dictation.shared.activate()
            self?.refresh()
        }
        note("Only for dictation, and only if you use it: this is what lets Listen watch "
             + "for the shortcut and type what you said into the app in front. Recording, "
             + "transcribing and labelling meetings never touch it.")

        separator()
        heading("Calendar")
        calendarLabel = statusRow()
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
        // Microphone. Blocked and not optional: without it Listen records only
        // the other side of a call, which is half a meeting.
        if Permissions.microphone {
            micLabel?.set(.granted, "Granted. Your own voice is recorded.")
        } else if Permissions.microphoneDenied {
            micLabel?.set(.blocked, "Denied. Listen can still record the other side of "
                          + "a call, but not you.")
        } else {
            micLabel?.set(.blocked, "Not granted yet. Listen asks the first time you "
                          + "record.")
        }

        if !Permissions.systemAudioSupported {
            // Not a fault and not fixable: there is no switch in System Settings
            // that adds process taps to macOS 14.1, so colouring it as a problem
            // would be pointing at something nobody can act on.
            tapLabel?.set(.optional, "Needs macOS 14.2 or later. On this Mac only your "
                          + "microphone can be recorded.")
        } else if Permissions.systemAudio {
            tapLabel?.set(.granted, "Working. The other side of a call is recorded.")
        } else {
            tapLabel?.set(.blocked, "Not available. Grant the microphone permission "
                          + "above, which is the same permission a process tap needs.")
        }

        if Permissions.accessibility {
            // Read from the setting, not from `hotkeyInstalled`. The tap can be
            // absent for reasons that are nothing to do with the switch: a
            // preview launch never arms it, and neither does a first run before
            // setup finishes. Both reported "dictation is switched off" about a
            // dictation that was switched on.
            accessibilityLabel?.set(
                .granted,
                Settings.dictationEnabled
                    ? "Granted. \(DictationShortcut.description) starts a dictation."
                    : "Granted, but dictation is switched off in the Dictation tab.")
        } else if Settings.dictationEnabled {
            // Blocked, because dictation is on and this is the reason it does
            // nothing. That state was invisible for a release: the switch read
            // as on, the shortcut was listed, and pressing it produced silence,
            // because a tap without this grant is refused and there is no
            // keystroke left to report the refusal with.
            accessibilityLabel?.set(.blocked, "Not granted, so the dictation shortcut "
                                    + "does nothing. Everything else in Listen works "
                                    + "without it.")
        } else {
            accessibilityLabel?.set(.optional, "Not granted, and not needed: dictation "
                                    + "is switched off in the Dictation tab.")
        }

        switch Permissions.calendarAction {
        case .granted:
            calendarButton?.title = "Open System Settings"
            // The count, not just "granted". A grant that reaches an empty
            // calendar store looks identical to a working one from here, and
            // that is the failure this row exists to make visible.
            let count = MeetingCalendar.calendars().count
            if count == 0 {
                calendarLabel?.set(.blocked, "Granted, but there are no calendars on "
                                   + "this Mac to read.")
            } else {
                calendarLabel?.set(.granted,
                                   "Granted. Reading \(count) calendar\(count == 1 ? "" : "s").")
            }
        case .canAsk:
            calendarButton?.title = "Allow calendar access"
            // Optional throughout. Listen records, transcribes and labels
            // without it, so a warning colour here would be nagging somebody
            // about a choice rather than reporting a fault.
            calendarLabel?.set(.optional, "Not granted yet.")
        case .settingsOnly:
            calendarButton?.title = "Open System Settings"
            // Split from "denied", because the two look identical from here and
            // are fixed the same way, but only one of them is a decision
            // anybody made: a dismissed prompt records nothing, so the status
            // still says nobody has been asked.
            calendarLabel?.set(.optional, Permissions.calendarDenied
                ? "Denied. Recordings keep the name you give them, and speakers are "
                  + "named by hand."
                : "Asked, and not granted. The button below opens System Settings, "
                  + "where Listen can be switched on under Calendars.")
        }

        // The sidebar carries the same answer, so a missing grant is visible
        // without opening this pane at all.
        LibraryWindow.shared.refreshSettingsBadges()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        poll?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only on a change. `refresh` reads the calendar store and
                // rebuilds four rows, and doing that every second under
                // somebody reading the pane is work nobody asked for.
                let key = "\(Permissions.microphone)|\(Permissions.systemAudio)"
                    + "|\(Permissions.accessibility)|\(Permissions.calendar)"
                guard key != self.lastKey else { return }
                self.lastKey = key
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        poll?.invalidate()
        poll = nil
    }
}

// ---------------------------------------------------------------------------

/// Is this copy current, and the way back into setup.
///
/// This was `AboutPane` and carried the app's identity, its credits and every
/// link out of it as well. All of that is `AboutWindow` now, for the reason
/// recorded there: a person looking for the website was never going to open
/// Settings, Advanced, About and scroll. What is left is two questions that
/// really are preferences.
final class UpdatesPane: Pane {
    private var checkButton: NSButton?
    private var autoCheck: NSButton?
    private var autoDownload: NSButton?
    private var result: NSTextField?
    private var installButton: NSButton?
    private var installNote: NSTextField?
    private var lastChecked: NSTextField?

    /// A check can also be started from the menu bar, and a scheduled one starts
    /// on its own, so follow the updater rather than only reacting to this
    /// pane's own button.
    override func viewWillAppear() {
        super.viewWillAppear()
        NotificationCenter.default.addObserver(
            self, selector: #selector(outcomeChanged),
            name: Updater.outcomeChanged, object: nil)
        refreshUpdates()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        NotificationCenter.default.removeObserver(
            self, name: Updater.outcomeChanged, object: nil)
    }

    @objc private func outcomeChanged() { refreshUpdates() }

    override func build() {
        // Straight into the controls. There is no "Updates" heading because the
        // pane already draws that word in 22 point immediately above, and the
        // heading only existed while this section was called About and the
        // block needed naming.
        //
        // A button and a checkbox on one row, the way Speak has them: the
        // checkbox is about the button beside it, and a second line for it read
        // as a preference belonging to whatever came next.
        let check = NSButton(title: "Check Now", target: nil, action: nil)
        let checkHandler = ActionHandler { [weak self] _ in
            Updater.shared.checkForUpdates(nil)
            // Immediately, not from the callback. `checkForUpdates` sets the
            // outcome to `.checking` before it asks, and waiting for a delegate
            // that a check with no network never reaches leaves the button
            // looking untouched.
            self?.refreshUpdates()
        }
        check.target = checkHandler
        check.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(check, "handler", checkHandler, .OBJC_ASSOCIATION_RETAIN)

        let auto = NSButton(checkboxWithTitle: "Check automatically",
                            target: nil, action: nil)
        auto.state = Updater.shared.automaticallyChecks ? .on : .off
        let autoHandler = ActionHandler { [weak self] sender in
            Updater.shared.automaticallyChecks = (sender as? NSButton)?.state == .on
            // Turning checking off also takes installing automatically with it,
            // and that has to show on the checkbox below in the same click
            // rather than the next time the pane is opened.
            self?.refreshUpdates()
        }
        auto.target = autoHandler
        auto.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(auto, "handler", autoHandler, .OBJC_ASSOCIATION_RETAIN)

        row([check, auto])
        checkButton = check
        autoCheck = auto

        let outcome = NSTextField(wrappingLabelWithString: "")
        outcome.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(outcome)
        widthCapped(outcome)
        result = outcome

        // Directly under the result line, because it is the verb for the
        // sentence above it: "Version 0.20.0 is ready to install" and then the
        // way to install it. Hidden the rest of the time rather than disabled,
        // since there is nothing staged for it to act on and a permanently grey
        // button is a promise about a state nobody can see.
        // Deliberately not the window's default button. It is the loudest verb
        // in Settings, it quits the app, and a stray Return in a pane somebody
        // opened to read is not consent to be relaunched.
        let install = NSButton(title: "Install and Relaunch", target: nil, action: nil)
        let installHandler = ActionHandler { [weak self] _ in
            // The blocker is re-read on the press rather than only on the last
            // refresh: a recording can start while this pane sits open, and the
            // pane does not poll.
            Updater.shared.installNow()
            self?.refreshUpdates()
        }
        install.target = installHandler
        install.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(install, "handler", installHandler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(install)
        installButton = install

        installNote = note("")

        lastChecked = note("")

        // Below the result rather than beside the button: the row above is the
        // check and the checkbox that governs it, and this is about what
        // happens after a check rather than about checking.
        let down = NSButton(checkboxWithTitle: "Install updates automatically",
                            target: nil, action: nil)
        down.state = Updater.shared.automaticallyDownloads ? .on : .off
        let downHandler = ActionHandler { sender in
            Updater.shared.automaticallyDownloads = (sender as? NSButton)?.state == .on
        }
        down.target = downHandler
        down.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(down, "handler", downHandler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(down)
        autoDownload = down

        note("With this on, a new version is downloaded in the background and put "
             + "in place the next time you quit, so you never see a prompt. Listen "
             + "puts a dot on the gear while one is waiting, and Install and "
             + "Relaunch above is how you take it without waiting for a quit that "
             + "an app you leave open may not get. With it off, Listen asks first "
             + "and waits.")

        note("Updates come from this project's GitHub releases. Each one is checked "
             + "against Listen's signing key before it is installed, and the check "
             + "itself sends nothing about you.")

        separator()
        heading("Setup")
        button("Run setup again…") { Onboarding.shared.restart() }
        note("Walks through the permissions and the speech model. It changes nothing "
             + "you have already chosen, and it is the quickest way to find out which "
             + "part has stopped working.")

        separator()
        heading("About")
        // The version is here as well as in the window, because it is the thing
        // people come to a settings screen to read out to somebody. The button
        // is the bridge: this pane is where About used to live, so anybody who
        // learned that route still lands one press away from it.
        note(Self.versionString)
        // Under the version, because it is what the version means. This pane
        // says whether a copy is current; the notes say what being current got
        // you, and nothing else in the app could answer that.
        button("Release Notes…") { ChangelogWindow.show() }
        note("What changed in this version and in every one before it. Sparkle "
             + "shows the newest section before an update, and with updates "
             + "installing on quit that is a pane most people never see.")
        button("About Listen…") { AboutWindow.show() }
        note("What Listen is, who made it, and the links to the website, the "
             + "documentation and the source.")
    }

    /// Read from the bundle rather than hardcoded, so bumping `VERSION` is
    /// enough and this cannot go stale.
    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != short { return "Version \(short) (build \(build))" }
        return "Version \(short)"
    }

    /// Mirror the updater into the five controls, in place. Rebuilding the pane
    /// instead would replace the button under the cursor of somebody who has
    /// just clicked it.
    private func refreshUpdates() {
        guard let checkButton, let result, let lastChecked else { return }

        checkButton.isEnabled = Updater.shared.canCheck
        autoCheck?.state = Updater.shared.automaticallyChecks ? .on : .off
        // Sparkle will not install automatically while it is not allowed to
        // check, and refuses the write silently rather than reporting it, so
        // the checkbox is disabled instead of being left to look settable.
        autoDownload?.isEnabled = Updater.shared.automaticallyChecks
        autoDownload?.state = Updater.shared.automaticallyDownloads ? .on : .off

        switch Updater.shared.outcome {
        case .unknown:
            result.stringValue = ""
            result.isHidden = true
        case .checking:
            result.stringValue = "Checking…"
            result.textColor = .secondaryLabelColor
            result.isHidden = false
        case .upToDate(let why):
            result.stringValue = "● \(why)"
            result.textColor = .systemGreen
            result.isHidden = false
        case .available(let version):
            result.stringValue = "● Version \(version) is available."
            result.textColor = .systemBlue
            result.isHidden = false
        case .ready(let version):
            result.stringValue = "● Version \(version) is downloaded and ready to install."
            result.textColor = .systemBlue
            result.isHidden = false
        case .failed(let why):
            result.stringValue = "○ \(why)"
            result.textColor = .systemOrange
            result.isHidden = false
        }

        // The button and its line, which only exist while something is staged.
        if let installButton, let installNote {
            installButton.isHidden = !Updater.shared.isReady
            installNote.isHidden = !Updater.shared.isReady
            let blocker = Updater.shared.installNowBlocker
            installButton.isEnabled = blocker == nil
            installNote.stringValue = blocker
                ?? "Listen quits and comes straight back on the new version. "
                 + "Leaving it will install the same version the next time you quit."
        }

        if let date = Updater.shared.lastCheck {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            lastChecked.stringValue = "Last checked \(f.string(from: date))."
        } else {
            lastChecked.stringValue = "Not checked yet."
        }
        // Deliberately no `resizeDocument()`. The result line appearing changes
        // the pane's height, but `sizeDocument` already runs on every layout
        // pass and a text field whose string changed schedules one. Calling the
        // public one would also scroll the pane back to its first control, and a
        // scheduled check finishing while somebody is reading the credits is not
        // a reason to move the page under them.
    }
}

// ---------------------------------------------------------------------------

/// The telemetry switch, on by default, and everything needed to judge it:
/// what is sent, where it goes, and the complete public dictionary one click
/// away.
///
/// The checkbox mirrors `Telemetry.consent`, which every install is migrated
/// to true exactly once by `migrateToDefaultOnIfNeeded()`, unconditionally,
/// overriding even a prior no: there is no separate question anywhere else
/// any more, only this switch. Unticking is an explicit no, and `Telemetry`
/// deletes the queue and the install identity on that transition; re-ticking
/// later creates a fresh one.
final class PrivacyPane: Pane {
    private var shareBox: NSButton?
    private var channelPopup: NSPopUpButton?

    override func build() {
        heading("Anonymous usage statistics")

        let forced = Settings.forcedBool("telemetryDisabled") == true
        let box = checkbox("Share anonymous usage statistics and crash reports",
                           Telemetry.consent == true) { on in
            Telemetry.consent = on
        }
        box.isEnabled = !forced
        shareBox = box
        if forced {
            note("Telemetry is off, set by your organisation's device profile.")
        }

        note("On by default. Listen sends anonymous counts: how many recordings, "
             + "how long in rough buckets, which app a call was in, and crash "
             + "reports. They go to PostHog in the EU under a random install ID "
             + "that exists only while this is on, created the moment it turns on "
             + "and deleted the moment it turns off. Your recordings, transcripts, "
             + "titles, names and searches never leave this Mac either way.")

        // The paragraph above has always claimed an install ID exists and is
        // deleted when the switch goes off. Printing it is what makes both
        // halves checkable rather than merely stated, and it is the only way
        // somebody with more than one Mac can tell which rows are which: the
        // events carry no device name, on purpose. Selectable so it can be
        // copied; absent rather than blank when nothing is being sent, because
        // "no ID" is the honest answer then and an empty box is not.
        if let id = Telemetry.installID {
            let field = NSTextField(labelWithString: "Install ID: \(id)")
            field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            field.textColor = .secondaryLabelColor
            field.isSelectable = true
            stack.addArrangedSubview(field)
        }

        let dictionary = NSButton(title: "See exactly what is shared",
                                  target: nil, action: nil)
        dictionary.isBordered = false
        dictionary.contentTintColor = .linkColor
        dictionary.font = .systemFont(ofSize: 12)
        let handler = ActionHandler { _ in Links.open(Links.telemetry) }
        dictionary.target = handler
        dictionary.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(dictionary, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(dictionary)

        separator()
        heading("How did you hear about Listen?")
        note("Optional, and the only marketing question in the app. The answer "
             + "travels with the statistics above, so it is only ever sent if "
             + "sharing is on.")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: "Prefer not to say")
        for channel in TelemetrySchema.AcquisitionChannel.allCases {
            popup.addItem(withTitle: channel.label)
        }
        let pick = ActionHandler { sender in
            guard let popup = sender as? NSPopUpButton else { return }
            let channels = TelemetrySchema.AcquisitionChannel.allCases
            let index = popup.indexOfSelectedItem - 1
            Telemetry.setChannel(
                channels.indices.contains(index) ? channels[index] : nil)
        }
        popup.target = pick
        popup.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(popup, "handler", pick, .OBJC_ASSOCIATION_RETAIN)
        channelPopup = popup
        row([popup])
    }

    override func refresh() {
        shareBox?.state = Telemetry.consent == true ? .on : .off
        if let stored = Settings.telemetryChannel,
           let index = TelemetrySchema.AcquisitionChannel.allCases
               .firstIndex(where: { $0.rawValue == stored }) {
            channelPopup?.selectItem(at: index + 1)
        } else {
            channelPopup?.selectItem(at: 0)
        }
    }
}

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
        note("`listen mcp` serves the library to an agent over stdio. No port, and "
             + "the app does not need to be running. Paste this into your MCP "
             + "client configuration.\n\n"
             + "Notes and tags are the only things an agent can write. It can "
             + "add, rewrite and delete the notes it wrote, and tag and untag a "
             + "meeting; it can read the notes you type yourself and not change "
             + "them; and it cannot rename a speaker, correct a transcript, "
             + "retitle a meeting or delete one. It also reads your transcripts, "
             + "so if the agent runs in the cloud, that text leaves this Mac.")

        // The full text-view-in-a-scroll-view plumbing, same shape as
        // `ChangelogWindow`. A bare `NSTextView()` handed to a scroll view
        // rendered as an empty white box on an older macOS (measured on the
        // first outside install): with no frame, no autoresizing and no
        // container tracking, the document view never takes the clip view's
        // width there, and the text is drawn into zero space. The explicit
        // `textColor` is for the same trip: a text view built this way is not
        // guaranteed the semantic default on every macOS this app runs on.
        let field = NSTextView()
        field.frame = NSRect(x: 0, y: 0, width: 400, height: 120)
        field.string = MCPConfig.json
        field.isEditable = false
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        field.textColor = .textColor
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.minSize = NSSize(width: 0, height: 0)
        field.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                               height: CGFloat.greatestFiniteMagnitude)
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.autoresizingMask = [.width]
        field.textContainer?.widthTracksTextView = true
        field.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
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

        // The Claude app, connected by a button rather than by hand. The JSON
        // above stays as the floor for every other MCP client; this is the one
        // client common enough to deserve its own verb, and the person most
        // likely to own it is the person least likely to paste JSON. See
        // `ClaudeDesktop` for the failure modes the button owns.
        separator()
        heading("Claude app")
        desktopLabel = note("")
        let add = button("Add to Claude Desktop") { [weak self] in
            self?.connectDesktop()
        }
        desktopButton = add
        let restart = button("Restart Claude Desktop") { [weak self] in
            self?.restartDesktop()
        }
        restart.isHidden = true
        desktopRestart = restart
    }

    private var desktopLabel: NSTextField?
    private var desktopButton: NSButton?
    private var desktopRestart: NSButton?

    private func connectDesktop() {
        do {
            let outcome = try ClaudeDesktop.connect()
            // The entry is only worth having if the binary it names serves.
            // Checked after the write, off the main thread, because it spawns
            // a process; the label updates when it answers.
            desktopLabel?.stringValue = outcome.message
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let answers = ClaudeDesktop.serves()
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !answers {
                        self.desktopLabel?.stringValue = outcome.message
                            + " One check failed though: `listen mcp` did not "
                            + "answer from \(MCPConfig.command). Reinstall the "
                            + "CLI above, then press the button again."
                    }
                    self.refresh()
                }
            }
        } catch {
            desktopLabel?.stringValue = error.localizedDescription
        }
        refresh()
    }

    private func restartDesktop() {
        desktopRestart?.isEnabled = false
        ClaudeDesktop.restart { [weak self] opened in
            self?.desktopRestart?.isEnabled = true
            self?.desktopLabel?.stringValue = opened
                ? "The Claude app is starting with Listen connected."
                : "The Claude app did not restart; quit and reopen it yourself "
                    + "when convenient. The connection is already written."
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

        // The Claude app block. Restart is only offered while the app is
        // running and the connection is written, because that is the one
        // moment a restart does anything.
        let desktop = ClaudeDesktop.state()
        let connected = desktop == .connected
        desktopButton?.isHidden = desktop == .notInstalled
        desktopButton?.isEnabled = !connected
        desktopRestart?.isHidden = !(connected && ClaudeDesktop.running != nil)
        switch desktop {
        case .notInstalled:
            desktopLabel?.stringValue = "The Claude app is not installed, so "
                + "there is nothing to connect. The block above works for any "
                + "other MCP client."
        case .notConnected:
            desktopLabel?.stringValue = "The Claude app is installed. One press "
                + "writes the block above into its configuration, with a backup "
                + "of the file beside it, and then Claude can read your library "
                + "through `listen mcp`: same tools, same limits."
        case .connected:
            desktopLabel?.stringValue = "Connected. The Claude app reads this "
                + "at launch, so restart it if Listen is not listed there yet."
        case .connectedElsewhere(let command):
            desktopLabel?.stringValue = "Connected, but to \(command), which is "
                + "not where Listen is now. One press repoints it."
            desktopButton?.isEnabled = true
        case .brokenConfig(let why):
            desktopLabel?.stringValue = "The Claude app's configuration file "
                + "could not be read (\(why)), and Listen will not overwrite a "
                + "file it cannot parse. Fix or delete it, then press the button."
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
