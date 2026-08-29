import AppKit

/// Ask, set up as a choice between named options rather than as a settings
/// pane to decode.
///
/// The settings pane states facts: what is installed, what is signed in, what
/// a provider answered. That is the right shape for checking on a thing and
/// the wrong shape for choosing one, which the first outside install proved:
/// a Mac with the Claude app, no signed-in CLI and no provider showed accurate
/// facts everywhere and no path from "I want to ask about my meetings" to a
/// working composer. This sheet is that path. Each card names one way in,
/// states its trade-off in the card itself (the repo rule: the trade-off is in
/// the sentence, not a tooltip), and ends on a real answered question rather
/// than on "saved".
///
/// **On demand only.** It is reachable from the composer's setup card and from
/// Settings, Ask, and deliberately not from first-run onboarding: recording
/// and transcription owe nothing to this choice, and a first run already asks
/// for enough.
///
/// The writes all go through the existing machinery: `Settings.addProvider`,
/// `AgentKey.save` (Keychain, never preferences), `Settings.agentChoice`,
/// `Settings.setAgentModel`. The wizard owns no storage of its own, so
/// cancelling it writes nothing and the settings pane agrees with it by
/// construction.
@MainActor
final class AskSetupWizard: NSObject {
    static let shared = AskSetupWizard()

    /// The OpenRouter models the sheet offers, mirroring the iPhone's curated
    /// list: a short understandable menu instead of OpenRouter's hundreds of
    /// routes. The settings pane keeps the full searchable catalogue; this is
    /// a first choice, not a ceiling.
    private static let curated: [(id: String, name: String)] = [
        ("anthropic/claude-sonnet-5", "Claude Sonnet 5, recommended"),
        ("openai/gpt-5.4-mini", "GPT-5.4 mini, long recordings"),
        ("openai/gpt-5.6-luna", "GPT-5.6 Luna, fast questions"),
        ("deepseek/deepseek-v4-flash", "DeepSeek V4 Flash, cheapest"),
    ]

    private enum Choice: Int, CaseIterable {
        case openrouter, cli, desktop, local
    }

    private var window: NSWindow?
    private var host: NSWindow?
    private var cards: [Choice: CardView] = [:]
    private var actionArea: NSStackView!
    private var choice: Choice = .openrouter
    private var keyField: NSSecureTextField?
    private var modelPopup: NSPopUpButton?
    private var resultLabel: NSTextField?
    private var run: AgentSession?

    /// Present over the library window. One sheet at a time; a second call
    /// while it is up is a no-op rather than a stack of sheets.
    func present() {
        guard window == nil else { return }
        guard let host = LibraryWindow.shared.sheetHost else { return }
        self.host = host
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Set up Ask"
        window = sheet
        build(into: sheet)
        // Preselect what is closest to working: a usable backend means the
        // person is here to change something, so leave the default; a CLI that
        // is installed but signed out means one command finishes the job, so
        // open on that card.
        if let cached = AgentCLI.cached,
           cached.contains(where: { $0.backend.isCLI && $0.path != nil }) {
            choice = .cli
        } else if ClaudeDesktop.isInstalled {
            choice = .openrouter
        }
        select(choice)
        host.beginSheet(sheet)
    }

    private func dismiss() {
        run?.cancel()
        run = nil
        if let window, let host { host.endSheet(window) }
        window = nil
        host = nil
        cards = [:]
        keyField = nil
        modelPopup = nil
        resultLabel = nil
    }

    // MARK: - Building

    private func build(into sheet: NSWindow) {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        content.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "How should Listen answer questions?")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        content.addArrangedSubview(title)

        let intro = wrapped("Ask reads your recordings through Listen's own "
            + "tools and answers with an AI you bring. Pick one; recording and "
            + "transcription work without any of this.")
        content.addArrangedSubview(intro)

        for choice in Choice.allCases {
            let card = CardView(title: cardTitle(choice), body: cardBody(choice))
            card.onPress = { [weak self] in self?.select(choice) }
            cards[choice] = card
            content.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: content.widthAnchor,
                                        constant: -40).isActive = true
        }

        actionArea = NSStackView()
        actionArea.orientation = .vertical
        actionArea.alignment = .leading
        actionArea.spacing = 10
        content.addArrangedSubview(actionArea)
        actionArea.widthAnchor.constraint(equalTo: content.widthAnchor,
                                          constant: -40).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        content.addArrangedSubview(spacer)

        let close = NSButton(title: "Close", target: self, action: #selector(closePressed))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let footer = NSStackView(views: [close])
        footer.orientation = .horizontal
        content.addArrangedSubview(footer)

        sheet.contentView = content
    }

    private func cardTitle(_ choice: Choice) -> String {
        switch choice {
        case .openrouter: return "OpenRouter"
        case .cli:        return "Claude Code or Codex"
        case .desktop:    return "The Claude app"
        case .local:      return "A model on this Mac"
        }
    }

    /// The trade-off is the body, per the copy rule: what it costs sits next
    /// to what it gives, not behind a tooltip.
    private func cardBody(_ choice: Choice) -> String {
        switch choice {
        case .openrouter:
            return "Paste one key and pick a model; working in a minute, and "
                + "what the iPhone app uses. The meetings you ask about are "
                + "sent to OpenRouter under zero data retention, and you pay "
                + "per use."
        case .cli:
            return "Uses the Claude or ChatGPT subscription you already have, "
                + "and the agent reaches nothing but Listen's own tools. Needs "
                + "one terminal command to sign in."
        case .desktop:
            return "Ask about your library inside the Claude app instead of "
                + "here. One click connects it; Listen's composer stays as it "
                + "is."
        case .local:
            return "Ollama runs a model on this Mac: no account, and nothing "
                + "leaves the machine. A few gigabytes of download, and it "
                + "wants a recent Mac to feel quick."
        }
    }

    private func select(_ selected: Choice) {
        choice = selected
        for (which, card) in cards { card.selected = which == selected }
        for view in actionArea.arrangedSubviews { view.removeFromSuperview() }
        keyField = nil
        modelPopup = nil
        resultLabel = nil
        switch selected {
        case .openrouter: buildOpenRouter()
        case .cli:        buildCLI()
        case .desktop:    buildDesktop()
        case .local:      buildLocal()
        }
        window?.layoutIfNeeded()
    }

    // MARK: - OpenRouter

    private func buildOpenRouter() {
        link("Get a key at openrouter.ai/keys",
             url: URL(string: "https://openrouter.ai/keys")!)

        let field = NSSecureTextField()
        field.placeholderString = "sk-or-…"
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        keyField = field

        let models = NSPopUpButton()
        for model in Self.curated {
            models.addItem(withTitle: model.name)
            models.lastItem?.representedObject = model.id
        }
        modelPopup = models

        let row = NSStackView(views: [field, models])
        row.orientation = .horizontal
        row.spacing = 8
        actionArea.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: actionArea.widthAnchor).isActive = true
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        // The button is the consent, like the model download in setup: the
        // sentence about transcripts leaving the Mac is on the card directly
        // above it, so a second alert would be asking what was just read.
        primary("Save and try it", #selector(saveOpenRouter))
        result()
    }

    @objc private func saveOpenRouter() {
        guard let provider = Provider.known("openrouter") else { return }
        let typed = keyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !typed.isEmpty else {
            resultLabel?.stringValue = "Paste the key first. The link above opens "
                + "the page that makes one."
            resultLabel?.isHidden = false
            return
        }
        guard Settings.addProvider(provider) else {
            resultLabel?.stringValue = "Your organisation's device profile manages "
                + "Ask providers, so this one cannot be added here."
            resultLabel?.isHidden = false
            return
        }
        guard AgentKey.save(typed, for: provider.host) else {
            resultLabel?.stringValue = "The Keychain refused to store the key, so "
                + "nothing was saved."
            resultLabel?.isHidden = false
            return
        }
        let model = modelPopup?.selectedItem?.representedObject as? String
            ?? Self.curated[0].id
        Settings.setAgentModel(provider.id, model)
        Settings.noteModelUsed(provider.id, model)
        // Explicit, not automatic: automatic prefers a CLI, and a Mac with the
        // Claude app has a signed-out `claude` on disk that would outrank the
        // provider this sheet just finished setting up.
        Settings.agentChoice = provider.id
        proveIt(expectingKey: provider.id)
    }

    // MARK: - The CLIs

    private func buildCLI() {
        let statuses = (AgentCLI.cached ?? []).filter { $0.backend.isCLI }
        if statuses.isEmpty {
            actionArea.addArrangedSubview(wrapped("Looking…"))
        }
        for status in statuses {
            let line: String
            if status.path == nil {
                line = "\(status.name) is not installed."
            } else if status.signedIn == false {
                line = "\(status.name) is installed and needs a sign-in."
            } else if status.signedIn == true {
                line = "\(status.name) is signed in and ready."
            } else {
                line = "\(status.name) is installed; whether it is signed in "
                    + "shows up on the first question."
            }
            actionArea.addArrangedSubview(wrapped(line))
            if let command = status.path == nil
                ? status.backend.installCommand : (status.signedIn == false
                ? status.backend.signInCommand : nil) {
                copyButton(command)
            }
        }
        let ready = statuses.contains { $0.signedIn == true }
        if ready {
            primary("Try it", #selector(tryChosen))
        } else {
            primary("Check again", #selector(checkCLIs))
        }
        result()
    }

    @objc private func checkCLIs() {
        AgentCLI.forgetCachedPaths()
        resultLabel?.isHidden = false
        resultLabel?.stringValue = "Looking…"
        AgentCLI.statuses { [weak self] _ in
            guard let self, self.window != nil else { return }
            if self.choice == .cli { self.select(.cli) }
        }
    }

    @objc private func tryChosen() {
        // Automatic again: the person chose a CLI, and automatic already
        // prefers those. An explicit provider choice made earlier in this
        // sheet would otherwise pin Ask away from the thing just signed into.
        Settings.agentChoice = nil
        proveIt(expectingKey: nil)
    }

    // MARK: - The Claude app

    private func buildDesktop() {
        let state = ClaudeDesktop.state()
        switch state {
        case .notInstalled:
            actionArea.addArrangedSubview(wrapped("The Claude app is not "
                + "installed on this Mac. claude.ai/download has it; come back "
                + "here after."))
            link("Open claude.ai/download", url: URL(string: "https://claude.ai/download")!)
        case .connected:
            actionArea.addArrangedSubview(wrapped("Connected. Open the Claude "
                + "app and ask it about your library; if Listen is not listed "
                + "under its connectors yet, restart it."))
            if ClaudeDesktop.running != nil {
                primary("Restart Claude Desktop", #selector(restartDesktop))
            }
        case .notConnected, .connectedElsewhere:
            actionArea.addArrangedSubview(wrapped("One press writes Listen into "
                + "the Claude app's connector configuration, with a backup of "
                + "the file beside it. Claude then reads your library through "
                + "the same tools with the same limits."))
            primary("Add to Claude Desktop", #selector(connectDesktop))
        case .brokenConfig(let why):
            actionArea.addArrangedSubview(wrapped("The Claude app's "
                + "configuration file could not be read (\(why)), and Listen "
                + "will not overwrite a file it cannot parse. Settings, "
                + "Developers has the block to paste by hand."))
        }
        result()
    }

    @objc private func connectDesktop() {
        do {
            let outcome = try ClaudeDesktop.connect()
            resultLabel?.stringValue = outcome.message
            resultLabel?.isHidden = false
            if choice == .desktop { select(.desktop) }
            resultLabel?.stringValue = outcome.message
            resultLabel?.isHidden = false
        } catch {
            resultLabel?.stringValue = error.localizedDescription
            resultLabel?.isHidden = false
        }
    }

    @objc private func restartDesktop() {
        ClaudeDesktop.restart { [weak self] opened in
            guard let self, self.window != nil else { return }
            self.resultLabel?.isHidden = false
            self.resultLabel?.stringValue = opened
                ? "The Claude app is starting with Listen connected."
                : "The Claude app did not restart; quit and reopen it yourself."
        }
    }

    // MARK: - Ollama

    private func buildLocal() {
        actionArea.addArrangedSubview(wrapped("Install Ollama, then in a "
            + "terminal run `ollama pull qwen3` (or any model that handles "
            + "tools). Once it is running, the check below finds it."))
        link("Open ollama.com", url: URL(string: "https://ollama.com")!)
        primary("Ollama is running, check", #selector(checkOllama))
        result()
    }

    @objc private func checkOllama() {
        guard let provider = Provider.known("ollama") else { return }
        guard Settings.addProvider(provider) else {
            resultLabel?.stringValue = "Your organisation's device profile manages "
                + "Ask providers, so this one cannot be added here."
            resultLabel?.isHidden = false
            return
        }
        resultLabel?.isHidden = false
        resultLabel?.stringValue = "Asking Ollama what it serves…"
        DispatchQueue.global(qos: .userInitiated).async {
            let status = provider.probe()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                guard status.signedIn == true, let first = status.models.first else {
                    self.resultLabel?.stringValue = "Nothing answered at "
                        + "\(provider.base.absoluteString). Start Ollama, pull a "
                        + "model, then check again."
                    return
                }
                let model = Settings.agentModel(provider.id) ?? first.id
                Settings.setAgentModel(provider.id, model)
                Settings.agentChoice = provider.id
                self.proveIt(expectingKey: provider.id)
            }
        }
    }

    // MARK: - The proof

    /// End on a real answer. Saving credentials proves the Keychain works;
    /// only a question proves Ask does, and this is the same question the
    /// settings pane's test uses.
    private func proveIt(expectingKey key: String?) {
        resultLabel?.isHidden = false
        resultLabel?.stringValue = "Asking…"
        AgentCLI.statuses { [weak self] all in
            guard let self, self.window != nil else { return }
            let status: AgentStatus?
            if let key { status = all.first { $0.key == key } }
            else { status = AgentCLI.choose(from: all) }
            guard let status, let path = status.path else {
                self.resultLabel?.stringValue = "Nothing answered yet. The "
                    + "settings pane behind this sheet shows what was found."
                return
            }
            var answer = ""
            let question = AgentRun.Question(
                text: "How many recordings are in the library? Answer in one short sentence.",
                backend: status.backend, path: path, provider: status.provider,
                model: Settings.agentModel(status.key))
            let run = question.session { [weak self] event in
                guard let self else { return }
                switch event {
                case .text(let text): answer += text
                case .textDelta(let text): answer += text
                case .finished(let outcome):
                    self.run = nil
                    if let failure = outcome.failure {
                        self.resultLabel?.stringValue = "That did not work: \(failure)"
                    } else {
                        let said = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                        self.resultLabel?.stringValue = said.isEmpty
                            ? "It answered. Ask is ready."
                            : "It answered: \(said)"
                    }
                default:
                    break
                }
            }
            self.run = run
            do { try run.start() } catch {
                self.run = nil
                self.resultLabel?.stringValue = "That did not work: "
                    + error.localizedDescription
            }
        }
    }

    // MARK: - Small pieces

    @objc private func closePressed() { dismiss() }

    private func wrapped(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 500
        return label
    }

    private func link(_ title: String, url: URL) {
        let button = NSButton(title: title, target: nil, action: nil)
        button.isBordered = false
        button.contentTintColor = .linkColor
        button.font = .systemFont(ofSize: 12)
        let handler = ActionHandler { _ in NSWorkspace.shared.open(url) }
        button.target = handler
        button.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        actionArea.addArrangedSubview(button)
    }

    private func primary(_ title: String, _ action: Selector) {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"
        actionArea.addArrangedSubview(button)
    }

    private func copyButton(_ command: String) {
        let button = NSButton(title: "Copy `\(command)`", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        let handler = ActionHandler { _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
        button.target = handler
        button.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        actionArea.addArrangedSubview(button)
    }

    private func result() {
        let label = wrapped("")
        label.isHidden = true
        label.textColor = .labelColor
        actionArea.addArrangedSubview(label)
        resultLabel = label
    }

    /// One option: a bordered card that reads as a radio button with room for
    /// a paragraph. A plain `NSView` with a click recognizer rather than a
    /// button, because a button's title cannot hold two fonts and wrap.
    private final class CardView: NSView {
        var onPress: (() -> Void)?
        var selected = false {
            didSet { restyle() }
        }

        init(title: String, body: String) {
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = 8
            layer?.borderWidth = 1

            let name = NSTextField(labelWithString: title)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            let text = NSTextField(wrappingLabelWithString: body)
            text.font = .systemFont(ofSize: 11.5)
            text.textColor = .secondaryLabelColor

            let column = NSStackView(views: [name, text])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
            NSLayoutConstraint.activate([
                column.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                text.widthAnchor.constraint(equalTo: column.widthAnchor),
            ])

            let click = NSClickGestureRecognizer(target: self, action: #selector(pressed))
            addGestureRecognizer(click)

            setAccessibilityElement(true)
            setAccessibilityRole(.radioButton)
            setAccessibilityLabel("\(title). \(body)")
            restyle()
        }

        required init?(coder: NSCoder) { fatalError("no nib") }

        @objc private func pressed() { onPress?() }

        private func restyle() {
            layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
            layer?.borderWidth = selected ? 2 : 1
            setAccessibilityValue(selected ? "selected" : "not selected")
        }

        /// A `CGColor` is a snapshot, so a theme switch leaves the old edge
        /// behind without this.
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            restyle()
        }
    }
}
