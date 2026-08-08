import AppKit

/// Settings, Agent: which agent CLI Listen can talk to, and proof that it can.
///
/// The pane is a reader of `AgentCLI`, in the way `DevicesPane` is a reader of
/// the two files `listen-sync` keeps: Listen installs nothing here, signs
/// nothing in, and stores no key. Everything on screen is a fact about the
/// user's own machine, so the job is to state it accurately and to say what to
/// type when it is not what they wanted.
///
/// **Detection runs off the main thread and the pane draws twice.** It spawns
/// up to four short processes, and the first time it can also spend five
/// seconds in a login shell. Doing that on the way in froze the window for long
/// enough to look like a beachball, so the pane opens saying "Looking" and
/// fills in when the answer arrives. That also makes "Check again" honest,
/// since it is the same path.
final class AgentPane: Pane {
    private var listStack: NSStackView?
    private var choice: NSSegmentedControl?
    private var tryButton: NSButton?
    private var result: NSTextField?
    private var latest: [AgentStatus] = []
    private var run: AgentRun?

    override func build() {
        note("Listen can answer questions about your recordings using Claude Code "
             + "or Codex, if you already have one of them. The model is yours and "
             + "so is the subscription: there is no Listen account, no key to paste "
             + "and no server in between.\n\n"
             + "Nothing is installed from here. These are the commands as they are "
             + "on this Mac.")

        separator()
        heading("On this Mac")

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
            + "your login shell's PATH."

        separator()
        heading("Which one to use")

        let picker = NSSegmentedControl(
            labels: ["Automatic"] + AgentBackend.preferenceOrder.map(\.name),
            trackingMode: .selectOne, target: nil, action: nil)
        picker.selectedSegment = Settings.agentBackend
            .flatMap { AgentBackend.preferenceOrder.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        picker.selectedSegmentBezelColor = Brand.tint
        let handler = ActionHandler { [weak self] sender in
            guard let index = (sender as? NSSegmentedControl)?.selectedSegment else { return }
            Settings.agentBackend = index == 0
                ? nil : AgentBackend.preferenceOrder[index - 1]
            self?.fillList()
        }
        picker.target = handler
        picker.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(picker, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        stack.addArrangedSubview(picker)
        choice = picker

        note("Automatic takes whichever is installed and signed in, preferring "
             + "Claude Code. That preference is not a favour: Claude Code can be "
             + "started with no tools of its own at all, so the only thing it can "
             + "reach is this library. Codex keeps a shell, and while it cannot "
             + "write anything or reach the network, it can read files directly "
             + "instead of asking.")

        separator()
        heading("What it can reach")
        note("Everything the agent knows about your recordings arrives through "
             + "`listen mcp`, which is Listen answering questions about its own "
             + "library.\n\n"
             + "It can read: recordings, transcripts, people, tags and notes.\n"
             + "It can write: notes and tags, and only when you ask for something "
             + "that needs it.\n"
             + "It cannot: open a file, reach the network, change a transcript, "
             + "rename a speaker, retitle or delete a recording, or delete a note.\n\n"
             + "Your own agent settings do not apply here either. Hooks, plugins, "
             + "custom instructions and any other MCP servers you have configured "
             + "are all switched off for these questions, so asking about a meeting "
             + "cannot start something else running.")

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
             + "back. It runs on the subscription you are already signed into, so "
             + "it costs nothing beyond that.")

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
        for view in listStack.arrangedSubviews { view.removeFromSuperview() }
        for status in latest { listStack.addArrangedSubview(rowFor(status)) }
        tryButton?.isEnabled = AgentCLI.chosen() != nil
        resizeDocument()
    }

    /// One command, said plainly.
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

        let name = NSTextField(labelWithString: status.backend.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)

        let chosen = AgentCLI.chosen()?.backend == status.backend
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
        heading.alignment = .firstBaseline
        heading.spacing = 8
        // The icon has no baseline worth aligning to, so it is centred on the
        // name by hand rather than dropping the whole row to centreY, which
        // would leave the two labels visibly off each other.
        heading.alignment = .centerY

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
    private func fixFor(_ status: AgentStatus) -> String? {
        if status.path == nil { return status.backend.installCommand }
        if status.signedIn == false { return status.backend.signInCommand }
        return nil
    }

    // MARK: - The test question

    private func tryIt() {
        guard let chosen = AgentCLI.chosen(), let path = chosen.path else { return }
        tryButton?.isEnabled = false
        result?.isHidden = false
        result?.stringValue = "Asking \(chosen.backend.name)…"
        resizeDocument()

        var answer = ""
        let question = AgentRun.Question(
            text: "How many recordings are in the library? Answer in one short sentence.",
            backend: chosen.backend, path: path)
        let run = AgentRun(question) { [weak self] event in
            guard let self else { return }
            switch event {
            case .text(let text):
                answer += (answer.isEmpty ? "" : "\n") + text
            case .toolCall(let name, _):
                self.result?.stringValue = "\(chosen.backend.name) is calling \(name)…"
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
