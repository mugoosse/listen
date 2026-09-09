import AppKit

// ---------------------------------------------------------------------------
// Which models are worth putting in a menu
// ---------------------------------------------------------------------------

extension Settings {
    private static func recentModelsKey(_ backend: String) -> String {
        "agentRecentModels_" + backend
    }

    /// The models actually used on one backend, most recent first.
    ///
    /// **This is what the composer's menu shows, and it replaced a slice of the
    /// catalogue.** The menu used to list the first twelve models a provider
    /// offered, alphabetically, which for OpenRouter's 318 tool-capable models
    /// meant `ai21/jamba`, four `aion-labs` entries and five `amazon/nova`
    /// ones: twelve rows nobody had chosen and 306 that could not be reached
    /// from the composer at all. Both halves of that were wrong, and they are
    /// the same mistake, which is asking one control to be a catalogue and a
    /// shortcut at once.
    ///
    /// Recency needs no configuration and is right after the first question:
    /// the menu becomes exactly the models somebody uses, in the order they
    /// last reached for them, and everything else is one press away in the
    /// picker.
    static func recentModels(_ backend: String) -> [String] {
        defaults.stringArray(forKey: recentModelsKey(backend)) ?? []
    }

    /// Note that a model was used. Most recent first, de-duplicated, capped.
    ///
    /// Called when a model is *chosen* rather than when an answer succeeds. A
    /// model that turned out not to support tools is still one the user reached
    /// for, and hiding it from the menu would make the failure hard to retry
    /// or to correct.
    static func noteModelUsed(_ backend: String, _ id: String?) {
        guard let id, !id.isEmpty else { return }
        var list = recentModels(backend).filter { $0 != id }
        list.insert(id, at: 0)
        defaults.set(Array(list.prefix(recentModelLimit)), forKey: recentModelsKey(backend))
    }

    static func forgetRecentModels(_ backend: String) {
        defaults.removeObject(forKey: recentModelsKey(backend))
    }

    /// Six. Long enough to hold the two or three anybody alternates between
    /// plus the ones they tried this week, short enough that the menu stays a
    /// menu.
    static let recentModelLimit = 6

    /// Above this many, a provider's list is a catalogue rather than a menu,
    /// and the composer shows recents plus the picker instead of all of them.
    ///
    /// Fifteen. Ollama with what somebody has pulled, and Claude's three
    /// aliases, are below it and are shown in full, which is the behaviour
    /// those had before any of this and should not have changed.
    static let modelsShownInFull = 15
}

// ---------------------------------------------------------------------------
// Finding one among hundreds
// ---------------------------------------------------------------------------

/// A search field over every model a backend offers.
///
/// **A sheet, not a popover.** A popover would sit closer to the composer and
/// is what this wanted to be, and it would have to take first responder for a
/// search field to work. `appkit.md` records what that costs, and `AskView`
/// already carries a local event monitor because a click in this app so often
/// goes nowhere. A sheet is unambiguous about focus, dismisses on Escape for
/// free, and is honest about its weight: picking one of 318 things is not a
/// glance.
///
/// It filters on id *and* name, because people know models by both:
/// `anthropic/claude` and `Opus` should each find the same row.
final class ModelPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let models: [AgentModel]
    private var shown: [AgentModel]
    private let current: String?
    private let onPick: (String?) -> Void

    private let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
        styleMask: [.titled, .closable, .resizable, .utilityWindow],
        backing: .buffered, defer: false)
    private let search = NSSearchField()
    private let table = NSTableView()

    /// Show it over `window`, calling back with the id, or with nil for
    /// "whatever the backend picks".
    @discardableResult
    static func present(models: [AgentModel], current: String?, over window: NSWindow?,
                        onPick: @escaping (String?) -> Void) -> ModelPicker? {
        guard let window else { return nil }
        let picker = ModelPicker(models: models, current: current, onPick: onPick)
        window.beginSheet(picker.panel)
        // After the sheet is up, or the field is not yet in a window to be
        // first responder of.
        picker.panel.makeFirstResponder(picker.search)
        // Held by the sheet's own lifetime. Without this the picker is released
        // the moment `present` returns and the table's data source is nil.
        picker.retained = picker
        return picker
    }

    private var retained: ModelPicker?

    private init(models: [AgentModel], current: String?, onPick: @escaping (String?) -> Void) {
        self.models = models
        self.shown = models
        self.current = current
        self.onPick = onPick
        super.init()
        build()
    }

    private func build() {
        panel.title = "Choose a model"

        search.placeholderString = "Search \(models.count) models"
        search.target = self
        search.action = #selector(filter)
        // Fires on every keystroke rather than only on return, which is what
        // makes this a filter rather than a query.
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true

        table.headerView = nil
        table.rowHeight = 42
        table.addTableColumn(NSTableColumn(identifier: .init("model")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pick)
        table.style = .inset

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let useDefault = NSButton(title: "Use the default", target: self,
                                  action: #selector(pickDefault))
        useDefault.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let choose = NSButton(title: "Choose", target: self, action: #selector(pick))
        choose.bezelStyle = .rounded
        choose.keyEquivalent = "\r"

        let buttons = NSStackView(views: [useDefault, NSView(), cancel, choose])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let column = NSStackView(views: [search, scroll, buttons])
        column.orientation = .vertical
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(column)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: content.topAnchor),
                column.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                column.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ])
        }

        // Start on what is in use, so Return with no typing is a no-op rather
        // than a silent change to whatever sorted first.
        if let current, let index = models.firstIndex(where: { $0.id == current }) {
            table.selectRowIndexes([index], byExtendingSelection: false)
            table.scrollRowToVisible(index)
        }
    }

    @objc private func filter() {
        let text = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        shown = text.isEmpty ? models : models.filter {
            // Both, because people know a model by its vendor path and by its
            // marketing name and should not have to guess which this wants.
            $0.id.lowercased().contains(text) || $0.name.lowercased().contains(text)
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    @objc private func pick() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return }
        finish(shown[row].id)
    }

    @objc private func pickDefault() { finish(nil) }

    @objc private func close() { finish(nil, changed: false) }

    private func finish(_ id: String?, changed: Bool = true) {
        panel.sheetParent?.endSheet(panel)
        if changed { onPick(id) }
        retained = nil
    }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let model = shown[row]
        let name = NSTextField(labelWithString: model.name)
        name.font = .systemFont(ofSize: 13, weight: model.id == current ? .semibold : .regular)
        let detail = NSTextField(labelWithString: model.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        let column = NSStackView(views: [name, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        return column
    }
}

/// The same provider and model choice in Ask and People & Memory.
@MainActor
final class AgentModelMenu: NSObject {
    private weak var window: NSWindow?
    private let onChange: () -> Void
    private let background: Bool

    private init(window: NSWindow?, background: Bool, onChange: @escaping () -> Void) {
        self.window = window
        self.background = background
        self.onChange = onChange
    }

    static func present(from anchor: NSView, background: Bool = false, onChange: @escaping () -> Void) {
        let chooser = AgentModelMenu(window: anchor.window, background: background, onChange: onChange)
        withExtendedLifetime(chooser) { chooser.show(from: anchor) }
    }

    private func show(from anchor: NSView) {
        // Refresh for the next opening without blocking this menu.
        AgentCLI.refreshStaleProviders(onChange)
        let menu = NSMenu()
        if background {
            let follow = NSMenuItem(title: "Use the Ask model", action: #selector(followAsk), keyEquivalent: "")
            follow.target = self; follow.state = Settings.contextModelChoice == nil ? .on : .off
            menu.addItem(follow); menu.addItem(.separator())
        }
        for status in AgentCLI.cached ?? [] {
            guard status.usable else { continue }
            let header = NSMenuItem(title: status.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let chosen = (background ? ContextModel.chosen(cachedOnly: true)?.key : AgentCLI.cachedChosen()?.key) == status.key
            let current = background && Settings.contextModelChoice?.provider == status.key ? Settings.contextModelChoice?.model : Settings.agentModel(status.key)
            add(to: menu, status.key, model: nil,
                title: "Default", on: chosen && current == nil)

            // **A short list is shown whole; a long one becomes recents.**
            // Ollama with what you have pulled, and Claude's three aliases, are
            // menus already. A provider offering hundreds is a catalogue, and a
            // menu that shows the first twelve of one is twelve rows nobody
            // chose plus no way to reach the rest.
            let offered: [AgentModel]
            if status.models.count <= Settings.modelsShownInFull {
                offered = status.models
            } else {
                var recent = Settings.recentModels(status.key)
                // Whatever is in use belongs in the menu whether or not it has
                // been used since this list existed, or switching away from it
                // would be a one-way door.
                if let current, !recent.contains(current) { recent.insert(current, at: 0) }
                offered = recent.compactMap { id in
                    status.models.first { $0.id == id }
                        // A model that is no longer offered, or was typed by
                        // hand, still shows: it is what the user picked, and
                        // dropping it silently would look like the setting had
                        // been lost.
                        ?? (id == current ? AgentModel(id: id, name: id) : nil)
                }
            }
            for model in offered {
                add(to: menu, status.key, model: model.id,
                    title: model.name, on: chosen && current == model.id)
            }

            if status.models.count > Settings.modelsShownInFull {
                let browse = NSMenuItem(title: "Choose a model…",
                                        action: #selector(browseModels(_:)), keyEquivalent: "")
                browse.target = self
                browse.indentationLevel = 1
                browse.representedObject = status.key
                menu.addItem(browse)
            }
            if status.key != (AgentCLI.cached ?? []).last(where: { $0.usable })?.key {
                menu.addItem(.separator())
            }
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No agent is set up", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    private func add(to menu: NSMenu, _ key: String, model: String?,
                     title: String, on: Bool) {
        let item = NSMenuItem(title: title, action: #selector(pickModel(_:)), keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        // Indented under the backend heading, which is what makes the heading
        // read as a heading rather than as a disabled row.
        item.indentationLevel = 1
        item.representedObject = [key, model as Any] as [Any]
        menu.addItem(item)
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any],
              let key = pair.first as? String else { return }
        use(key, model: pair.count > 1 ? pair[1] as? String : nil)
    }

    /// The whole catalogue, searchable, for the providers that have one.
    @objc private func browseModels(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let status = (AgentCLI.cached ?? []).first(where: { $0.key == key }) else { return }
        ModelPicker.present(models: status.models, current: background ? ContextModel.model(status) : Settings.agentModel(key),
                            over: window) { [self] id in
            use(key, model: id)
        }
    }

    /// Switch to a backend and a model, and remember that the model was used.
    private func use(_ key: String, model: String?) {
        if background { Settings.contextModelChoice = ContextModelChoice(provider: key, model: model) }
        else { Settings.agentChoice = key; Settings.setAgentModel(key, model) }
        // Recorded on the choice rather than on a successful answer: a model
        // that turned out not to support tools is still one that was reached
        // for, and hiding it would make the failure awkward to retry.
        Settings.noteModelUsed(key, model)
        onChange()
    }
    @objc private func followAsk() { Settings.contextModelChoice = nil; onChange() }

}
