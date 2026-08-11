import AppKit

/// Settings, Agent: which backends Listen can talk to, and proof that it can.
///
/// The pane is a reader of `AgentCLI`, in the way `DevicesPane` is a reader of
/// the two files `listen-sync` keeps: Listen installs nothing here and signs
/// nothing in. Everything on screen is a fact about the user's own machine, so
/// the job is to state it accurately and to say what to do when it is not what
/// they wanted.
///
/// It has one editable half now, which is new: a provider is a URL, a key and a
/// model, and those are typed here. The key goes to the Keychain and never to
/// preferences. See `AgentKey`.
///
/// **Detection runs off the main thread and the pane draws twice.** It spawns
/// up to four short processes, probes every configured provider over HTTP, and
/// the first time it can also spend five seconds in a login shell. Doing that
/// on the way in froze the window for long enough to look like a beachball, so
/// the pane opens saying "Looking" and fills in when the answer arrives. That
/// also makes "Check again" honest, since it is the same path.
final class AgentPane: Pane {
    private var listStack: NSStackView?
    private var choice: NSPopUpButton?
    private var tryButton: NSButton?
    private var result: NSTextField?
    private var latest: [AgentStatus] = []
    private var run: AgentSession?

    /// Which provider each editable control belongs to. A row is rebuilt on
    /// every refresh, so the controls cannot carry the id in a stored property
    /// of their own without leaking the old ones.
    private var boxOwner: [ObjectIdentifier: String] = [:]
    /// What each model box held when it was built.
    ///
    /// **The guard against a pane that edits settings by being looked at.**
    /// `controlTextDidEndEditing` fires when a row is torn down and
    /// `comboBoxSelectionDidChange` fires for a programmatic selection, so
    /// saving on either wrote a value nobody typed. Measured: opening
    /// Settings › Ask silently changed the OpenRouter model from
    /// `anthropic/claude-sonnet-5` to `deepseek/deepseek-v4-flash-0731` and put
    /// that at the top of the recently-used list.
    ///
    /// Comparing against the value the control was born with is what makes a
    /// save mean "somebody changed this": an incidental event carries the same
    /// string it started with, and is ignored.
    private var boxInitial: [ObjectIdentifier: String] = [:]

    override func build() {
        // **This paragraph used to promise something Listen can no longer
        // promise for every backend**, and it is worth saying why rather than
        // quietly editing it. It read "there is no Listen account, no key to
        // paste and no server in between", which was true when the only
        // backends were CLIs the user had already signed into. A provider can
        // be a model on this Mac, which keeps that claim intact and needs no
        // account at all, or a hosted service, which needs a key and receives
        // transcripts. Both are offered and the difference is stated wherever
        // it matters, rather than one sentence being made vague enough to
        // cover both.
        note("Listen can answer questions about your recordings using Claude Code "
             + "or Codex on the subscription you already have, or any provider "
             + "that speaks the OpenAI chat API, which includes a model running "
             + "on this Mac through Ollama. Whichever you pick is yours rather "
             + "than Listen's.\n\n"
             + "There is no Listen account and no server of ours in between.")

        separator()
        heading("What is set up")

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 14
        stack.addArrangedSubview(list)
        widthCapped(list)
        listStack = list

        let refresh = button("Check again") { [weak self] in
            // The login-shell answer is cached for the life of the process,
            // and somebody who just installed one of these in another terminal
            // is exactly who presses this.
            AgentCLI.forgetCachedPaths()
            self?.detect()
        }
        refresh.toolTip = "Look for the commands again, including a fresh read of "
            + "your login shell's PATH, and re-probe every provider."

        separator()
        heading("Which one to use")

        // **A pop-up rather than the segmented control this used to be.** The
        // segments were one per `AgentBackend`, which worked while there were
        // two of them and cannot survive a list the user adds to: five
        // providers plus two CLIs is seven segments in a 620 point pane.
        let picker = NSPopUpButton()
        picker.target = self
        picker.action = #selector(pickChoice(_:))
        stack.addArrangedSubview(picker)
        choice = picker

        note("Automatic takes whichever is ready, preferring Claude Code. That "
             + "preference is not a favour: Claude Code can be started with no "
             + "tools of its own at all, so the only thing it can reach is this "
             + "library. Codex keeps a shell, and while it cannot write anything "
             + "or reach the network, it can read files directly instead of "
             + "asking. A provider reaches the library through the same tools "
             + "and nothing else, because Listen runs that loop itself.")

        separator()
        buildProviders()

        separator()
        heading("What it can reach")
        note("Everything a backend knows about your recordings arrives through "
             + "the tools `listen mcp` serves, which is Listen answering "
             + "questions about its own library.\n\n"
             + "It can read: recordings, transcripts, people, tags and notes.\n"
             + "It can write: notes and tags, and only when you ask for something "
             + "that needs it.\n"
             + "It cannot: open a file, reach the network, change a transcript, "
             + "rename a speaker, retitle or delete a recording, or delete a note.\n\n"
             + "Your own agent settings do not apply either. Hooks, plugins, "
             + "custom instructions and any other MCP servers you have configured "
             + "are all switched off for these questions, so asking about a "
             + "meeting cannot start something else running.")

        separator()
        heading("Try it")

        let attempt = button("Ask a test question") { [weak self] in self?.tryIt() }
        tryButton = attempt

        let answer = NSTextField(wrappingLabelWithString: "")
        answer.font = .systemFont(ofSize: 11)
        answer.textColor = .secondaryLabelColor
        answer.isHidden = true
        stack.addArrangedSubview(answer)
        widthCapped(answer)
        result = answer

        note("Asks \"How many recordings are in the library?\" and shows what comes "
             + "back. On Claude Code or Codex it runs on the subscription you are "
             + "already signed into. On a provider of your own, whatever that "
             + "provider charges is between you and them.")

        detect()
    }

    override func refresh() { detect() }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // A test question outliving the pane would call back into views that
        // are no longer on screen, and there is nothing to see by then anyway.
        run?.cancel()
        run = nil
    }

    // MARK: - Providers

    /// The list somebody adds to, plus the one control that adds to it.
    ///
    /// One section for every provider rather than a bespoke section each, which
    /// is what this replaced. Ollama had a URL field and OpenRouter had a key
    /// field and they shared nothing, so adding a third meant writing a third.
    /// Now a provider is a row and the catalogue is a menu.
    private func buildProviders() {
        // "Add a provider", not "Providers": the providers themselves are rows
        // in the list above, and a heading that names them again would promise
        // a second list that is not here.
        heading("Add a provider")
        note("Anything that speaks the OpenAI chat API. A model on this Mac "
             + "through Ollama, LM Studio or llama.cpp needs no key and no "
             + "account, and nothing about your recordings leaves the machine. A "
             + "hosted provider needs a key, which is kept in your Keychain and "
             + "never in Listen's preferences file.")

        let add = NSPopUpButton()
        add.target = self
        add.action = #selector(addProvider(_:))
        stack.addArrangedSubview(add)
        adder = add
        fillAdder()
    }

    private var adder: NSPopUpButton?

    /// The catalogue, minus what is already added, plus a way in for a URL
    /// nobody catalogued.
    private func fillAdder() {
        guard let adder else { return }
        adder.removeAllItems()
        adder.addItem(withTitle: "Add a provider…")
        let already = Set(Settings.providers.map(\.id))
        for provider in Provider.catalogue where !already.contains(provider.id) {
            adder.addItem(withTitle: "\(provider.name)  ·  \(provider.note)")
            adder.lastItem?.representedObject = provider.id
        }
        adder.menu?.addItem(.separator())
        adder.addItem(withTitle: "Another URL…")
        adder.lastItem?.representedObject = "custom"
        adder.selectItem(at: 0)
    }

    @objc private func addProvider(_ sender: NSPopUpButton) {
        defer { sender.selectItem(at: 0) }
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        if id == "custom" { askForURL(); return }
        guard let provider = Provider.known(id) else { return }
        // A hosted provider is a decision about where recordings go, so it is
        // confirmed before it is saved rather than after. A loopback one is
        // added with no ceremony, because it changes nothing.
        guard confirm(provider) else { return }
        Settings.addProvider(provider)
        fillAdder()
        detect()
    }

    /// Ask for a base URL, for a server that is not in the catalogue.
    private func askForURL() {
        let alert = NSAlert()
        alert.messageText = "Add a provider"
        alert.informativeText = "The base URL of anything that speaks the OpenAI "
            + "chat API. It usually ends in /v1."
        let field = NSTextField(string: "")
        field.placeholderString = "http://localhost:11434/v1"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: typed), url.host != nil,
              url.scheme == "http" || url.scheme == "https" else {
            let bad = NSAlert()
            bad.messageText = "That is not a base URL"
            bad.informativeText = "It looks like http://localhost:11434/v1"
            bad.runModal()
            return
        }
        // `custom` returns the catalogue entry when the URL is one Listen
        // already has a name for, so pasting Ollama's URL adds the row called
        // Ollama rather than a second one called localhost.
        let provider = Provider.custom(url: url)
        guard confirm(provider) else { return }
        Settings.addProvider(provider)
        fillAdder()
        detect()
    }

    /// Say where the recordings will go, once, before saving.
    private func confirm(_ provider: Provider) -> Bool {
        guard !provider.isLoopback else { return true }
        let alert = NSAlert()
        alert.messageText = "Send transcripts to \(provider.host)?"
        alert.informativeText = provider.exposure.sentence
            + "\n\nOnly the meetings you actually ask about are sent, and only "
            + "when you ask. Nothing is uploaded in the background."
        alert.addButton(withTitle: "Add it")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// One provider: what it is, where it is, its key and its model.
    private func rowForProvider(_ provider: Provider, status: AgentStatus?) -> NSView {
        let ready = status?.signedIn == true
        let icon = NSImageView(image: NSImage(
            systemSymbolName: ready ? "checkmark.circle.fill" : "circle.dashed",
            accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = ready ? .systemGreen : .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16)])

        let name = NSTextField(labelWithString: provider.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)

        // `choose(from: latest)`, never `chosen()`. See the note on the
        // latter: this runs once per row, and detection here is what froze
        // the whole screen for fifteen seconds when the pane opened.
        let inUse = AgentCLI.choose(from: latest)?.key == provider.id
        let state = NSTextField(labelWithString: {
            guard let status else { return "Not checked" }
            if status.signedIn == false {
                return status.refused ? "Refused the key" : "Not answering"
            }
            if status.signedIn == nil { return "Not checked" }
            return inUse ? "Ready, and in use" : "Ready"
        }())
        state.font = .systemFont(ofSize: 11, weight: inUse ? .medium : .regular)
        state.textColor = ready ? (inUse ? .controlAccentColor : .secondaryLabelColor)
                                : .tertiaryLabelColor

        let remove = NSButton(title: "Remove", target: nil, action: nil)
        remove.bezelStyle = .rounded
        remove.controlSize = .small
        let removeHandler = ActionHandler { [weak self] _ in
            Settings.removeProvider(provider.id)
            // The key goes too. Leaving a credential behind for a provider the
            // user has just removed is the opposite of what pressing Remove
            // means.
            AgentKey.save(nil, for: provider.host)
            self?.fillAdder()
            self?.detect()
        }
        remove.target = removeHandler
        remove.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(remove, "handler", removeHandler, .OBJC_ASSOCIATION_RETAIN)

        let heading = NSStackView(views: [icon, name, state, remove])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8

        let detail = NSTextField(wrappingLabelWithString: describeProvider(provider, status))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = Pane.maxContentWidth - 24

        let column = NSStackView(views: [heading, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4

        if provider.needsKey { column.addArrangedSubview(keyRow(provider)) }
        column.addArrangedSubview(modelRow(provider, status))
        return column
    }

    private func describeProvider(_ provider: Provider, _ status: AgentStatus?) -> String {
        var lines = [provider.base.absoluteString]
        lines.append(provider.exposure.sentence)
        if let status {
            if status.signedIn == false {
                lines.append(status.refused
                             ? "It answered and refused the key."
                             : "Nothing answered. Start the server, or check the URL.")
            } else if let account = status.account {
                lines.append([status.version, account].compactMap { $0 }.joined(separator: "   "))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func keyRow(_ provider: Provider) -> NSView {
        let field = NSSecureTextField(string: "")
        field.placeholderString = AgentKey.has(provider.host)
            ? "A key is stored. Paste a new one to replace it."
            : "API key"
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([field.widthAnchor.constraint(equalToConstant: 320)])
        boxOwner[ObjectIdentifier(field)] = provider.id

        let store = NSButton(title: "Store", target: nil, action: nil)
        store.bezelStyle = .rounded
        store.controlSize = .small
        let handler = ActionHandler { [weak self] _ in
            let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { return }
            AgentKey.save(typed, for: provider.host)
            // Cleared, so the key is not left sitting in a field on a screen
            // somebody may screenshot for a bug report.
            field.stringValue = ""
            self?.detect()
        }
        store.target = handler
        store.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(store, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        var views: [NSView] = [field, store]
        if let docs = provider.docs, let url = URL(string: docs) {
            let get = NSButton(title: "Get a key", target: nil, action: nil)
            get.bezelStyle = .rounded
            get.controlSize = .small
            let open = ActionHandler { _ in NSWorkspace.shared.open(url) }
            get.target = open
            get.action = #selector(ActionHandler.fire(_:))
            objc_setAssociatedObject(get, "handler", open, .OBJC_ASSOCIATION_RETAIN)
            views.append(get)
        }
        return row(views)
    }

    /// **A combo box, not a pop-up.** OpenRouter lists 319 models that accept
    /// tools, and a menu that long is one nobody can find anything in. This
    /// completes as you type, and it still accepts a pasted id that is newer
    /// than the last time the list was fetched.
    private func modelRow(_ provider: Provider, _ status: AgentStatus?) -> NSView {
        let box = NSComboBox()
        box.completes = true
        box.usesDataSource = false
        box.numberOfVisibleItems = 12
        box.delegate = self
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([box.widthAnchor.constraint(equalToConstant: 320)])
        let models = status?.models ?? []
        box.addItems(withObjectValues: models.map(\.id))
        box.stringValue = Settings.agentModel(provider.id) ?? ""
        box.placeholderString = models.first?.id ?? "model id"
        boxOwner[ObjectIdentifier(box)] = provider.id
        boxInitial[ObjectIdentifier(box)] = box.stringValue

        let browse = NSButton(title: "Browse…", target: nil, action: nil)
        browse.bezelStyle = .rounded
        browse.controlSize = .small
        let browseHandler = ActionHandler { [weak self] _ in
            ModelPicker.present(models: models, current: Settings.agentModel(provider.id),
                                over: self?.view.window) { id in
                Settings.setAgentModel(provider.id, id)
                Settings.noteModelUsed(provider.id, id)
                self?.fillList()
            }
        }
        browse.target = browseHandler
        browse.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(browse, "handler", browseHandler, .OBJC_ASSOCIATION_RETAIN)
        browse.isEnabled = !models.isEmpty

        let hint = NSTextField(labelWithString: {
            if models.isEmpty {
                return provider.needsKey && !AgentKey.has(provider.host)
                    ? "Store a key to load the list."
                    : "No list yet. You can still type an id."
            }
            return "\(models.count) available" + (provider.isOpenRouter ? " that accept tools" : "")
        }())
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        return row([NSTextField(labelWithString: "Model"), box, browse, hint])
    }

    // MARK: - Detection

    private func detect() {
        guard let listStack else { return }
        for view in listStack.arrangedSubviews { view.removeFromSuperview() }
        let looking = NSTextField(labelWithString: "Looking…")
        looking.font = .systemFont(ofSize: 11)
        looking.textColor = .secondaryLabelColor
        listStack.addArrangedSubview(looking)
        tryButton?.isEnabled = false

        AgentCLI.statuses { [weak self] found in
            guard let self else { return }
            self.latest = found
            self.fillList()
        }
    }

    private func fillList() {
        guard let listStack else { return }
        boxOwner.removeAll()
        boxInitial.removeAll()

        for view in listStack.arrangedSubviews { view.removeFromSuperview() }
        for status in latest where status.backend.isCLI {
            listStack.addArrangedSubview(rowFor(status))
        }
        // The providers appear in the same list, because "what is set up" is
        // one question and answering it in two places is how somebody ends up
        // reading only the half that is on screen.
        for provider in Settings.providers {
            let status = latest.first { $0.key == provider.id }
            listStack.addArrangedSubview(rowForProvider(provider, status: status))
        }
        if Settings.providers.isEmpty {
            let none = NSTextField(labelWithString: "No providers added.")
            none.font = .systemFont(ofSize: 11)
            none.textColor = .tertiaryLabelColor
            listStack.addArrangedSubview(none)
        }

        fillChoice()
        tryButton?.isEnabled = AgentCLI.choose(from: latest) != nil
        resizeDocument()
    }

    /// The "which one to use" menu, from what detection actually found.
    private func fillChoice() {
        guard let picker = choice else { return }
        picker.removeAllItems()
        picker.addItem(withTitle: "Automatic")
        picker.lastItem?.representedObject = ""
        for status in latest {
            picker.addItem(withTitle: status.name + (status.usable ? "" : "  (not ready)"))
            picker.lastItem?.representedObject = status.key
        }
        let want = Settings.agentChoice ?? ""
        let index = picker.itemArray.firstIndex {
            ($0.representedObject as? String) == want
        }
        picker.selectItem(at: index ?? 0)
    }

    @objc private func pickChoice(_ sender: NSPopUpButton) {
        let key = sender.selectedItem?.representedObject as? String ?? ""
        Settings.agentChoice = key.isEmpty ? nil : key
        fillList()
    }

    /// One CLI, said plainly.
    ///
    /// The path is on screen even when everything is fine, because "installed"
    /// is not the useful fact on a Mac with two copies of a command. Measured
    /// here: inside a terminal wrapper that shims both CLIs, the shim is what
    /// gets found and reports itself signed out, and only the path says so.
    private func rowFor(_ status: AgentStatus) -> NSView {
        let ready = status.usable && status.signedIn == true
        let icon = NSImageView(image: NSImage(
            systemSymbolName: ready ? "checkmark.circle.fill" : "circle.dashed",
            accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = ready ? .systemGreen : .tertiaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16)])

        let name = NSTextField(labelWithString: status.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)

        let chosen = AgentCLI.choose(from: latest)?.key == status.key
        let state = NSTextField(labelWithString: {
            if status.path == nil { return "Not installed" }
            if status.signedIn == false { return "Not signed in" }
            if status.signedIn == nil { return "Sign-in unknown" }
            return chosen ? "Ready, and in use" : "Ready"
        }())
        state.font = .systemFont(ofSize: 11, weight: chosen ? .medium : .regular)
        state.textColor = ready ? (chosen ? .controlAccentColor : .secondaryLabelColor)
                                : .tertiaryLabelColor

        let heading = NSStackView(views: [icon, name, state])
        heading.orientation = .horizontal
        // The icon has no baseline worth aligning to, so it is centred on the
        // name by hand rather than dropping the whole row to centreY, which
        // would leave the two labels visibly off each other.
        heading.alignment = .centerY
        heading.spacing = 8

        let detail = NSTextField(wrappingLabelWithString: describe(status))
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.preferredMaxLayoutWidth = Pane.maxContentWidth - 24

        let column = NSStackView(views: [heading, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3

        // The one action a row can offer: put the command on the clipboard, so
        // the fix is a paste into a terminal rather than something to retype.
        if let command = fixFor(status) {
            let copy = NSButton(title: "Copy command", target: nil, action: nil)
            copy.bezelStyle = .rounded
            copy.controlSize = .small
            let handler = ActionHandler { _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            copy.target = handler
            copy.action = #selector(ActionHandler.fire(_:))
            objc_setAssociatedObject(copy, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
            column.addArrangedSubview(copy)
        }
        return column
    }

    private func describe(_ status: AgentStatus) -> String {
        guard let path = status.path else { return status.backend.installHint }
        let where_ = path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        var lines = [[status.version, where_].compactMap { $0 }.joined(separator: "   ")]
        switch status.signedIn {
        case true?:  if let account = status.account { lines.append("Signed in as \(account)") }
        case false?: lines.append(status.backend.installHint)
        case nil:    lines.append("Listen could not tell whether this is signed in. "
                                  + "It will find out the first time you ask something.")
        }
        return lines.joined(separator: "\n")
    }

    /// The command that would fix this row, or nil when nothing needs fixing.
    ///
    /// Nil for a provider in every state, and that is not an omission: what
    /// fixes one is a field in this very pane, so a button offering to copy a
    /// command would be offering the wrong gesture.
    private func fixFor(_ status: AgentStatus) -> String? {
        if status.path == nil { return status.backend.installCommand }
        if status.signedIn == false { return status.backend.signInCommand }
        return nil
    }

    /// Store what a row's combo box says, against the provider that row is for.
    private func saveModel(_ box: NSComboBox) {
        guard let id = boxOwner[ObjectIdentifier(box)] else { return }
        let typed = box.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unchanged means nobody changed it, whatever event brought us here.
        guard typed != (boxInitial[ObjectIdentifier(box)] ?? "") else { return }
        boxInitial[ObjectIdentifier(box)] = typed
        Settings.setAgentModel(id, typed.isEmpty ? nil : typed)
        Settings.noteModelUsed(id, typed.isEmpty ? nil : typed)
    }

    // MARK: - The test question

    private func tryIt() {
        // From `latest` too. Pressing a button is not a reason to re-probe
        // every backend, and detection has already run by the time this
        // button is enabled.
        guard let chosen = AgentCLI.choose(from: latest), let path = chosen.path else { return }
        tryButton?.isEnabled = false
        result?.isHidden = false
        result?.stringValue = "Asking \(chosen.name)…"
        resizeDocument()

        var answer = ""
        let question = AgentRun.Question(
            text: "How many recordings are in the library? Answer in one short sentence.",
            backend: chosen.backend, path: path, provider: chosen.provider,
            // A provider has no model of its own to fall back on, so the test
            // question has to carry the chosen one or it fails on the guard
            // rather than on anything worth learning from.
            model: Settings.agentModel(chosen.key))
        let run = question.session { [weak self] event in
            guard let self else { return }
            switch event {
            case .text(let text):
                answer += (answer.isEmpty ? "" : "\n") + text
            case .toolCall(let name, _):
                self.result?.stringValue = "\(chosen.name) is calling \(name)…"
            case .offline(let trouble):
                // The test question is the one place somebody comes to when the
                // agent is not working, so a network fault has to be readable
                // here rather than looking like the CLI being broken. And it has
                // to be taken back down when the connection returns: the next
                // event might be a whole answer away, and an amber line left
                // under a working reply is worse than no line at all.
                self.result?.stringValue = trouble ?? "Asking \(chosen.name)…"
                self.result?.textColor = trouble == nil ? .secondaryLabelColor : .systemOrange
                self.resizeDocument()
            case .finished(let outcome):
                var line = outcome.failure ?? answer
                // How long, and nothing about money. See
                // `AgentRun.Outcome.costUSD`: this runs on a subscription the
                // user already pays a flat rate for.
                if outcome.failure == nil, let ms = outcome.durationMS {
                    line += String(format: "\n\nAnswered in %.1fs.", Double(ms) / 1000)
                }
                self.result?.stringValue = line
                self.result?.textColor = outcome.failure == nil
                    ? .secondaryLabelColor : .systemRed
                self.tryButton?.isEnabled = true
                self.run = nil
                self.resizeDocument()
            default:
                break
            }
        }
        self.run = run
        do {
            try run.start()
        } catch {
            result?.stringValue = error.localizedDescription
            result?.textColor = .systemRed
            tryButton?.isEnabled = true
            self.run = nil
        }
    }
}

/// A model typed or picked in any provider row is saved against that provider.
///
/// The box is looked up in `boxOwner` rather than carrying its own id, because
/// every row is rebuilt on each refresh: a stored property on the control would
/// keep the previous row's provider alive and save against the wrong one.
extension AgentPane: NSComboBoxDelegate {
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let box = notification.object as? NSComboBox else { return }
        saveModel(box)
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let box = notification.object as? NSComboBox else { return }
        // The selection is not in `stringValue` yet when this fires, so the
        // save is deferred by one turn of the run loop.
        DispatchQueue.main.async { [weak self] in self?.saveModel(box) }
    }
}
