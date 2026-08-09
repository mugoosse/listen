import AppKit

/// The Ask pane: a conversation with an agent about one recording.
///
/// A third mode beside Transcript and Notes rather than a panel of its own, and
/// the reason is the same one that put Notes there: these are three documents
/// about the meeting you already have open, and a floating window would make
/// the fourth thing you have to arrange on screen. The mode picker already
/// exists and already survives a selection change, so reading down a list of
/// meetings asking each one the same question is a mode, not a repeated
/// gesture.
///
/// **The conversation is disposable and a note is not.** Everything here is
/// kept in `chat.json` beside the recording, and `Save as note` is what
/// promotes an answer into the library where the rest of the app can see it.
/// Keeping the two apart is what lets this be cheap: you can ask a bad question
/// without leaving anything behind.
///
/// The view owns no agent knowledge beyond `AgentRun`. It cannot tell which
/// backend answered except by the label it is handed, which is deliberate: the
/// two dialects are reconciled in `Agent.swift` and nothing above it should
/// have to know that Codex counts tool calls differently.
@MainActor
final class AskView: NSView {
    /// Questions worth putting on screen before anybody types.
    ///
    /// Four, and all four are about *this* meeting. A starter chip is a way of
    /// saying what the pane is for, so a general one ("summarise") teaches less
    /// than a specific one and costs the same. They disappear once there is a
    /// conversation, because by then the pane has explained itself.
    private static let starters: [(String, String)] = [
        ("Summarise", "Summarise this meeting in a short paragraph, then the key points as bullets."),
        ("Action items", "What did each person commit to in this meeting? Say who owns each one, and say so plainly if nobody did."),
        ("Decisions", "What was actually decided in this meeting, and what was left open?"),
        ("Catch me up", "I missed this meeting. Tell me what I need to know in under 150 words."),
    ]

    private let scroll = NSScrollView()
    private let turns = NSStackView()
    private let starterRow = NSStackView()
    /// The starters and the drawer's collapsed-state controls, on one line.
    private let starterLine = NSStackView()
    private let historyButton = NSButton()
    private let expandButton = NSButton()
    private let notice = SetupNotice()
    /// The chips and the setup notice, in one slot above the composer. They are
    /// alternatives rather than neighbours: one invites a question and the other
    /// says why there is nobody to ask.
    private let invitation = NSStackView()
    private let field = NSTextField()
    private let sendButton = SendButton()
    private let modelButton = NSButton()
    private lazy var composer = ComposerWell(field: field, model: modelButton,
                                             send: sendButton)
    private let status = NSTextField(labelWithString: "")
    private lazy var composerTrailing =
        composer.trailingAnchor.constraint(equalTo: trailingAnchor)
    /// Zero unless there is something to say. A hidden view still occupies its
    /// frame, which is the rule `setChipsCollapsed` already records, so the
    /// height goes too or the composer sits 14 points off the floor for ever.
    private lazy var statusHeight = status.heightAnchor.constraint(equalToConstant: 0)

    /// How much room to leave on the right of the input row.
    ///
    /// The record button floats over this pane and is the window's, not this
    /// view's. It is hidden while Ask is up, so this is normally zero; the
    /// exception is a recording in progress, when the button becomes Stop and
    /// has to stay reachable however inconvenient that is.
    ///
    /// A number the window sets rather than a constraint against the button
    /// itself, which was tried and is wrong twice over: the two views have no
    /// common ancestor at the moment the window is built, so activating it
    /// threw and the window never appeared at all, and `PaneHost.show` tears
    /// the pane out of the hierarchy on every mode change, which would break
    /// any such constraint later even if it could be made at the right time.
    var trailingClearance: CGFloat = 0 {
        didSet {
            guard trailingClearance != oldValue else { return }
            composerTrailing.constant = -trailingClearance
        }
    }

    private var recording: Recording?
    private var chat = Chat()
    private var run: AgentRun?
    /// The view being written into while an answer streams.
    private var answering: AnswerTurn?

    /// Told when a note is written, so the Notes mode can pick it up without
    /// being switched to and back.
    var onNoteWritten: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    // MARK: - Layout

    private func build() {
        turns.orientation = .vertical
        turns.alignment = .leading
        turns.spacing = 18
        turns.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        turns.translatesAutoresizingMaskIntoConstraints = false

        // Flipped, for the reason `Pane` uses one: an unflipped document view
        // puts a short conversation on the floor of the pane instead of at the
        // top of it.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(turns)

        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        starterRow.orientation = .horizontal
        starterRow.spacing = 6
        starterRow.translatesAutoresizingMaskIntoConstraints = false

        notice.isHidden = true
        notice.onCheckAgain = { [weak self] in self?.recheck() }

        // The starters and the two drawer controls share one line, right
        // against left. A clock on a line of its own above the chips is a whole
        // row spent on one glyph, which is what it looked like.
        for button in [historyButton, expandButton] {
            button.isBordered = false
            button.bezelStyle = .inline
            button.imagePosition = .imageOnly
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        historyButton.image = NSImage(systemSymbolName: "clock.arrow.circlepath",
                                      accessibilityDescription: "Earlier conversations")
        historyButton.toolTip = "Earlier conversations"
        historyButton.action = #selector(historyPressed)
        expandButton.image = NSImage(systemSymbolName: "chevron.up",
                                     accessibilityDescription: "Show the conversation")
        expandButton.toolTip = "Show the conversation"
        expandButton.action = #selector(expandPressed)
        expandButton.isHidden = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        starterLine.orientation = .horizontal
        starterLine.alignment = .centerY
        starterLine.spacing = 6
        starterLine.translatesAutoresizingMaskIntoConstraints = false
        starterLine.addArrangedSubview(starterRow)
        starterLine.addArrangedSubview(spacer)
        starterLine.addArrangedSubview(expandButton)
        starterLine.addArrangedSubview(historyButton)
        // The spacer is what pushes the controls to the trailing edge, and it
        // is the only thing in the row allowed to grow.
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        starterRow.setContentHuggingPriority(.required, for: .horizontal)

        invitation.orientation = .vertical
        invitation.alignment = .leading
        invitation.spacing = 8
        invitation.translatesAutoresizingMaskIntoConstraints = false
        invitation.addArrangedSubview(starterLine)
        invitation.addArrangedSubview(notice)

        buildComposer()

        status.font = .systemFont(ofSize: 10)
        status.textColor = .tertiaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.translatesAutoresizingMaskIntoConstraints = false

        for view in [scroll, invitation, composer, status] { addSubview(view) }

        // Never wider than its text wants, and never wider than the pane.
        // Required against the pane, high against the number, so a narrow
        // window shrinks the card instead of breaking the layout.
        let wide = notice.widthAnchor.constraint(equalToConstant: SetupNotice.maxWidth)
        wide.priority = .defaultHigh

        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            turns.topAnchor.constraint(equalTo: document.topAnchor),
            turns.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            turns.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            turns.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: invitation.topAnchor, constant: -8),

            invitation.leadingAnchor.constraint(equalTo: leadingAnchor),
            invitation.trailingAnchor.constraint(equalTo: trailingAnchor),
            invitation.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            notice.widthAnchor.constraint(lessThanOrEqualTo: invitation.widthAnchor),
            wide,

            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerTrailing,
            composer.heightAnchor.constraint(equalToConstant: ComposerWell.height),
            composer.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),

            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            statusHeight,
        ])
    }

    /// The input row: one glass capsule holding the field, the model chooser
    /// and the send button.
    ///
    /// Bordered as a whole rather than as a text field, because a bezelled
    /// `NSTextField` next to two separate buttons reads as a form, and this is
    /// the one control on the pane.
    private func buildComposer() {
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = Self.prompt(for: nil)
        field.target = self
        field.action = #selector(send)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        // Which agent and which model, in the composer rather than only in
        // Settings. It belongs here for the reason the mode picker belongs
        // above the transcript: it is a property of the question being asked,
        // and somebody who wants a better answer to *this* question should not
        // have to leave the pane to ask for one.
        // Empty and hidden until `updateModelButton` has something to say. An
        // `NSButton` created with no title carries AppKit's own placeholder, so
        // a composer that had not been updated yet advertised a control called
        // "Button": measured on the window-level bar, which unlike the pane's
        // copy is built before any agent detection has finished.
        modelButton.title = ""
        modelButton.isHidden = true
        modelButton.bezelStyle = .inline
        modelButton.isBordered = false
        modelButton.font = .systemFont(ofSize: 12)
        modelButton.contentTintColor = .secondaryLabelColor
        modelButton.imagePosition = .imageRight
        // Empty rather than nil. An SF Symbol carries its own description, so
        // nil leaves the chevron announcing itself and the button read as
        // "Claude Code, go down".
        modelButton.image = NSImage(systemSymbolName: "chevron.down",
                                    accessibilityDescription: "")
        modelButton.symbolConfiguration = .init(pointSize: 8, weight: .semibold)
        modelButton.target = self
        modelButton.action = #selector(chooseModel)
        modelButton.translatesAutoresizingMaskIntoConstraints = false

        sendButton.onPress = { [weak self] in
            guard let self else { return }
            if self.isRunning { self.stopAndTidy() } else { self.send() }
        }
        // Everything inside is positioned by `ComposerWell.layout`, by frame,
        // for the reason `RecordButton` does the same: on macOS 26 the middle
        // view belongs to `NSGlassEffectView`, which places its content view
        // itself, and constraints pinned across that boundary are two things
        // fighting over one number.
    }

    // MARK: - Choosing the agent and the model

    /// One menu for both choices, because to a reader they are one choice.
    ///
    /// The backend is a section heading and the models are its rows, so picking
    /// "GPT-5.6-Sol" also switches to Codex. Two separate controls would be
    /// truer to how the preferences are stored and worse to use: nobody thinks
    /// "Codex, and within Codex, Sol".
    @objc private func chooseModel() {
        let menu = NSMenu()
        for status in AgentCLI.cached ?? [] {
            guard status.usable else { continue }
            let header = NSMenuItem(title: status.backend.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let chosen = AgentCLI.cachedChosen()?.backend == status.backend
            let current = Settings.agentModel(status.backend)
            add(to: menu, status.backend, model: nil,
                title: "Default", on: chosen && current == nil)
            for model in status.models {
                add(to: menu, status.backend, model: model.id,
                    title: model.name, on: chosen && current == model.id)
            }
            if status.backend != (AgentCLI.cached ?? []).last(where: { $0.usable })?.backend {
                menu.addItem(.separator())
            }
        }
        if menu.items.isEmpty {
            let empty = NSMenuItem(title: "No agent is set up", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: modelButton.bounds.height + 4), in: modelButton)
    }

    private func add(to menu: NSMenu, _ backend: AgentBackend, model: String?,
                     title: String, on: Bool) {
        let item = NSMenuItem(title: title, action: #selector(pickModel(_:)), keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        // Indented under the backend heading, which is what makes the heading
        // read as a heading rather than as a disabled row.
        item.indentationLevel = 1
        item.representedObject = [backend.rawValue, model as Any] as [Any]
        menu.addItem(item)
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any],
              let raw = pair.first as? String,
              let backend = AgentBackend(rawValue: raw) else { return }
        Settings.agentBackend = backend
        Settings.setAgentModel(backend, pair.count > 1 ? pair[1] as? String : nil)
        updateStatus()
    }

    /// What the composer's chooser says right now.
    private func updateModelButton() {
        guard let chosen = AgentCLI.cachedChosen() else {
            modelButton.isHidden = true
            return
        }
        modelButton.isHidden = false
        let model = Settings.agentModel(chosen.backend)
        let name = chosen.models.first { $0.id == model }?.name
        // The backend's name when nothing is chosen, the model's when one is.
        // Never both: the row is 11 point text in a 36 point well, and "Claude
        // Code · Sonnet" is the kind of label that makes a composer look busy.
        modelButton.title = name ?? chosen.backend.name
        modelButton.setAccessibilityLabel(
            "Agent and model: \(chosen.backend.name), \(name ?? "default")")
        composer.needsLayout = true
    }

    // MARK: - What it is about

    /// Point the pane at a recording, loading whatever was said about it before.
    ///
    /// A running answer belongs to the recording it was asked about, so
    /// changing recordings stops it. Letting it finish would file its turn into
    /// a conversation nobody is looking at, and its cost line would land under
    /// somebody else's meeting.
    /// What the field offers to answer, which is not the same question on every
    /// screen. "Ask about this meeting" over an empty library is a promise about
    /// a meeting that is not open, and it was the placeholder on every screen
    /// the moment the composer moved to the window.
    static func prompt(for recording: Recording?) -> String {
        recording == nil ? "Ask about your library…" : "Ask about this meeting…"
    }

    func show(_ recording: Recording?) {
        field.placeholderString = Self.prompt(for: recording)
        guard recording?.id != self.recording?.id else { return }
        stop()
        self.recording = recording
        // The newest conversation about this meeting, or a fresh one. There can
        // now be several, because a conversation is a library document naming
        // its sources rather than one sidecar per folder, and `about` returns
        // them most recently touched first.
        chat = recording.flatMap { Chat.about($0.id).first } ?? Chat()
        redraw()
    }

    /// Open a conversation from the history, whatever it is about.
    ///
    /// The recording is taken from the conversation rather than the other way
    /// round, so resuming a question about four meetings does not silently
    /// narrow it to one. A conversation about none leaves the recording nil,
    /// which is the library-wide case.
    func open(_ chat: Chat) {
        stop()
        self.chat = chat
        recording = chat.sources.first.flatMap { Recording.find($0) }
        field.placeholderString = Self.prompt(for: recording)
        redraw()
    }

    /// Start a new conversation, keeping whatever is on screen as its subject.
    func startNew() {
        stop()
        chat = Chat()
        redraw()
    }

    /// Re-read from disk, and redraw either way. The CLI can write to this file
    /// too.
    ///
    /// **The redraw is unconditional, and that is the point.** Re-reading is
    /// only possible once a conversation has an id, but a conversation with no
    /// id yet is exactly the state the window-level bar is built in, and
    /// `redraw` is what runs detection and decides whether to show the model
    /// control or the setup card. Returning early left the bar with neither:
    /// no way to choose a model, and no notice saying why asking would not
    /// work. The composer is on screen from launch now, so it has no later
    /// moment to be configured in.
    func reload() {
        guard run == nil else { return }
        if let id = chat.id, let fresh = Chat.load(id: id) { chat = fresh }
        redraw()
    }

    func focusField() { window?.makeFirstResponder(field) }


    private func redraw() {
        for view in turns.arrangedSubviews { view.removeFromSuperview() }
        answering = nil
        // The question each answer belongs to, tracked while walking the list so
        // a conversation saved before `Chat.Turn.question` existed still titles
        // its notes from the right place.
        var asked = ""
        for turn in chat.turns {
            if turn.who == Chat.you { asked = turn.text }
            addTurn(view(for: turn, asking: turn.question ?? asked))
        }
        // The chips are drawn by `updateStatus`, which is the only thing that
        // knows whether there is anything to ask.
        updateStatus()
        scrollToEnd()
    }

    private func drawStarters() {
        for view in starterRow.arrangedSubviews { view.removeFromSuperview() }
        // Only on an empty conversation. Four chips under a page of answers is
        // a toolbar, and this is an invitation.
        //
        // And only when a question would actually go somewhere. They were shown
        // whatever detection had found, so with no CLI installed the pane
        // offered four buttons that silently did nothing: `ask` returns at the
        // first guard, and the pane looks exactly as it did before the press.
        // `recording != nil` stays here, unlike in `updateStatus`. These four
        // are about *this* meeting ("Summarise", "Action items"), so over the
        // library they would be four questions about nothing. The setup card
        // and the model control are about the app and belong on every screen;
        // the starters are about a document and belong on one.
        guard chat.turns.isEmpty, recording != nil,
              AgentCLI.cachedChosen() != nil else {
            starterRow.isHidden = true
            return
        }
        starterRow.isHidden = false
        for (label, prompt) in Self.starters {
            starterRow.addArrangedSubview(StarterChip(label) { [weak self] in
                self?.ask(prompt)
            })
        }
    }

    private func updateStatus() {
        // **No `recording != nil` guard.** There used to be one, returning
        // before any of this: with no meeting open there was no pane, so there
        // was nothing to report about. The composer belongs to the window now
        // and asking about the library is a real question, so bailing out here
        // is what left the bar with no model control and, worse, no setup card
        // on the one screen somebody opens first. Missing configuration has to
        // announce itself wherever a question can be typed.

        // From the cache, never by running detection. `AgentCLI.chosen()`
        // spawns up to four processes, this runs on every recording selection,
        // and calling it here froze the window on every click down the sidebar.
        guard let found = AgentCLI.cached else {
            // The line rather than the card, because "still looking" is not yet
            // bad news. Putting the card up here and taking it down a second
            // later would flash a setup notice at everybody who has an agent.
            say("Looking for Claude Code or Codex…")
            notice.isHidden = true
            setAskable(false)
            // Once, and the callback puts the real state up.
            AgentCLI.warmUp { [weak self] in self?.updateStatus() }
            return
        }
        guard AgentCLI.cachedChosen() != nil else {
            // The card says all of it, so the line under the composer stays
            // empty: two messages about one problem, six points apart, and the
            // small grey one is the one nobody reads.
            say("")
            notice.show(found)
            setAskable(false)
            reportHeight()
            return
        }
        notice.isHidden = true
        setAskable(true)
        reportHeight()
        // Nothing at all when everything is working.
        //
        // It said "Answers come from your recordings only", which is true and
        // was still the wrong thing to put under every question forever: it is
        // a fact about the feature, not a fact about right now, and a standing
        // line of small grey text is read once and then becomes furniture. The
        // place for it is Settings › Agent, which says it in full.
        //
        // The label stays for the things that *are* about right now: looking
        // for an agent, not finding one, and confirming a note was written.
        say("")
    }

    /// Pressed on the clock and on the chevron in the starters line. The drawer
    /// owns what they mean, because only it knows how tall it is.
    var onHistory: (() -> Void)?
    var onExpand: (() -> Void)?

    @objc private func historyPressed() { onHistory?() }
    @objc private func expandPressed() { onExpand?() }

    /// Both controls belong to the collapsed bar. Expanded, the drawer's own
    /// header carries the title and the size controls, and a second clock under
    /// it would be the same action offered twice, six points apart.
    func setExpanded(_ on: Bool) {
        historyButton.isHidden = on
        expandButton.isHidden = on || !hasConversation
    }

    /// The height this needs as a bar: the well, its status line, and the
    /// starters line, which is always there because the controls live in it.
    ///
    /// Asked for rather than assumed. The drawer hardcoded 68, which is below
    /// this, so collapsing squeezed the well until autolayout gave up somewhere
    /// and the send button came back a flattened oval.
    var barHeight: CGFloat {
        var height = ComposerWell.height + 6 + 14 + 12
        if !notice.isHidden {
            height += notice.fittingSize.height + 8
        } else {
            height += max(starterLine.fittingSize.height, 20) + 8
        }
        return height
    }

    /// Is there a conversation to go back to, as opposed to an empty composer?
    var hasConversation: Bool { !chat.turns.isEmpty }

    /// Which conversation is open, so the history can tick it.
    var currentID: String? { chat.id }

    /// What the drawer's header calls what is open, which is the question that
    /// started it. See `Chat.displayTitle`.
    var conversationTitle: String { chat.displayTitle }

    /// How tall this needs to be as a bar, told to whoever is constraining it.
    ///
    /// The setup card is the reason this exists. It is several lines and a
    /// button, and in a bar sized for the well alone it is clipped to nothing:
    /// the one state that has something important to say would be the one state
    /// you cannot read. So the owner is told a number rather than guessing one.
    var onHeightChanged: ((CGFloat) -> Void)?

    private func reportHeight() {
        // A conversation needs the room a bar does not have. The owner clamps
        // this to what the window can spare, so asking for more than exists is
        // safe and asking for a share of an unknown height is not.
        onHeightChanged?(chat.turns.isEmpty && run == nil ? barHeight : 560)
    }

    /// Everything that has to agree about whether a question can be asked.
    ///
    /// The chips are in here rather than in `redraw` because they are one of
    /// those things. Detection finishing is what brings them back, and it
    /// arrives on a callback rather than on a selection.
    private func setAskable(_ on: Bool) {
        field.isEnabled = on
        updateSendButton()
        updateModelButton()
        drawStarters()
    }

    /// Look again, for somebody who has just installed or signed in elsewhere.
    ///
    /// The cached login-shell `PATH` is forgotten first, for the reason the
    /// Agent pane's button forgets it: an npm install that landed in a
    /// directory this process has never heard of is exactly the case being
    /// checked for.
    private func recheck() {
        notice.isBusy = true
        AgentCLI.forgetCachedPaths()
        AgentCLI.statuses { [weak self] _ in
            self?.notice.isBusy = false
            self?.updateStatus()
        }
    }

    /// Put a transient line under the composer, and take its space back when
    /// there is nothing to say.
    private func say(_ text: String) {
        status.stringValue = text
        statusHeight.constant = text.isEmpty ? 0 : 14
    }

    private func updateSendButton() {
        sendButton.isStop = isRunning
        sendButton.isReady = !isRunning && AgentCLI.cachedChosen() != nil
            && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        composer.needsLayout = true
    }

    /// Cancel a running answer and leave the pane in a state somebody can use.
    private func stopAndTidy() {
        guard let answer = answering else { return }
        stop()
        answer.finish(AgentRun.Outcome(session: chat.session, costUSD: nil,
                                       durationMS: nil, toolCalls: 0,
                                       failure: answer.body.isEmpty ? "Stopped." : nil))
        // Kept, not thrown away. A half-written answer is still an answer, and
        // the alternative is a stop button that also deletes what it stopped.
        if !answer.body.isEmpty {
            var turn = Chat.Turn(who: Chat.agent, text: answer.body,
                                 tools: answer.toolLines, steps: answer.steps,
                                 at: Metadata.iso(Date()))
            turn.question = answer.question
            chat.turns.append(turn)
            persist()
        }
        updateStatus()
    }

    // MARK: - Asking

    @objc private func send() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        field.stringValue = ""
        ask(text)
    }

    private func ask(_ text: String) {
        // **No `let recording`.** `send` clears the field before calling this,
        // so a guard that fails here swallows the question without a word: the
        // text vanishes and nothing happens, which is what asking about the
        // library did from the moment the composer left the meeting pane.
        //
        // Nothing downstream needed the recording. `start` already scopes the
        // question to one only when there is one, and deliberately as a
        // sentence rather than a hard filter, so the library case was written
        // and reachable everywhere except through this line.
        guard run == nil else { return }
        guard let chosen = AgentCLI.cachedChosen(), let path = chosen.path else {
            updateStatus()
            return
        }

        // A backend change invalidates the session: a Codex thread id means
        // nothing to Claude, and resuming with one is an error rather than a
        // fresh conversation.
        if chat.backend != chosen.backend.rawValue {
            chat.session = nil
            chat.backend = chosen.backend.rawValue
        }

        append(Chat.Turn(who: Chat.you, text: text, at: Metadata.iso(Date())))
        starterRow.isHidden = true

        // The answer carries the question that produced it. Looking the
        // question up at save time takes the *latest* one instead, so pressing
        // Save on an older answer filed it under a question asked afterwards,
        // which was measured and is exactly as confusing as it sounds.
        let answer = AnswerTurn(question: text) { [weak self] body, asked in
            self?.saveAsNote(body, asked: asked)
        }
        answering = answer
        addTurn(answer)
        answer.begin(with: chosen.backend.name)
        updateSendButton()
        scrollToEnd()

        start(text, backend: chosen.backend, path: path, resuming: chat.session)
    }

    /// Run one question. Split out because a failed resume runs it again.
    private func start(_ text: String, backend: AgentBackend, path: URL,
                       resuming: String?) {
        // The question is asked *about* a recording, and the agent is given
        // that as a sentence rather than as a hidden filter. It can still look
        // at the rest of the library, which is the point: "is this the same
        // thing we said last week" is a reasonable follow-up and a hard filter
        // would make it unanswerable.
        let scoped = resuming == nil && recording != nil
            ? "About the recording `\(recording!.id)` (\(recording!.metadata.title)): \(text)"
            : text
        let question = AgentRun.Question(
            text: scoped, backend: backend, path: path, resume: resuming,
            // Writes are on because "write this up as a note" is a thing to ask
            // a meeting assistant, and refusing it would mean the Save button
            // is the only route to something the agent could do itself.
            allowWrites: true, model: Settings.agentModel(backend), streaming: true)

        var wroteAnything = false
        let run = AgentRun(question) { [weak self] event in
            guard let self, let answer = self.answering else { return }
            switch event {
            case .started(let session):
                self.chat.session = session
            case .thinking:
                answer.thinking()
            case .toolCall(let name, let detail):
                answer.tool(name, detail)
                self.scrollToEnd()
            case .textDelta(let text):
                wroteAnything = true
                answer.append(text)
                self.scrollToEnd()
            case .text(let text):
                wroteAnything = true
                answer.appendBlock(text)
                self.scrollToEnd()
            case .note(let text):
                answer.tool("note", text)
            case .toolResult:
                break
            case .finished(let outcome):
                // A resumed session that the agent no longer has is the one
                // failure worth retrying by itself: the conversation is on
                // screen, the file is on disk, and the only thing missing is
                // the agent's own memory of it. Retried once, without the
                // resume, and only when nothing had been written yet.
                if outcome.failure != nil, resuming != nil, !wroteAnything {
                    self.chat.session = nil
                    answer.reset()
                    self.start(text, backend: backend, path: path, resuming: nil)
                    return
                }
                self.finish(outcome, answer)
            }
        }
        self.run = run
        do {
            try run.start()
        } catch {
            answer(error.localizedDescription)
        }
    }

    private func answer(_ failure: String) {
        answering?.fail(failure)
        run = nil
    }

    private func finish(_ outcome: AgentRun.Outcome, _ answer: AnswerTurn) {
        run = nil
        answering = nil
        answer.finish(outcome)
        var turn = Chat.Turn(who: Chat.agent, text: answer.body,
                             tools: answer.toolLines, steps: answer.steps,
                             at: Metadata.iso(Date()))
        turn.question = answer.question
        turn.durationMS = outcome.durationMS
        turn.failure = outcome.failure
        chat.turns.append(turn)
        persist()
        updateStatus()
        scrollToEnd()
    }

    private func append(_ turn: Chat.Turn) {
        chat.turns.append(turn)
        addTurn(view(for: turn, asking: turn.text))
        persist()
        // The first turn is what turns the bar into a conversation, so the
        // height has to be re-asked here rather than only when the status
        // changes: an answer streaming into a view with no room to draw it is
        // indistinguishable from a question that was never sent.
        reportHeight()
    }

    /// Write the conversation, naming what it is about.
    ///
    /// No `guard let recording`: a question asked with nothing selected is
    /// about the library, and refusing to save it was the whole reason a
    /// conversation could not exist without a folder to live in.
    ///
    /// The recording on screen is added to `recordings` rather than replacing
    /// it, and only once. A follow-up asked on a second meeting is the same
    /// conversation about both, which is what makes the back links on either
    /// page true.
    private func persist() {
        if let id = recording?.id, !chat.sources.contains(id) {
            chat.recordings = chat.sources + [id]
        }
        chat.save()
    }

    func stop() {
        run?.cancel()
        run = nil
        answering = nil
    }

    /// Throw the conversation away. Everything it was about keeps everything
    /// else: a conversation names its sources and owns none of them.
    func clear() {
        stop()
        if let id = chat.id { Chat.forget(id: id) }
        chat = Chat()
        redraw()
    }

    var isEmpty: Bool { chat.turns.isEmpty }
    var isRunning: Bool { run != nil }

    // MARK: - Promoting an answer

    /// Write one answer into the library as a note.
    ///
    /// Through `Notes.create` like everything else, and titled from the
    /// question rather than from the answer: the question is what somebody will
    /// be looking for in the note list, and an answer's first line is usually a
    /// sentence rather than a name.
    private func saveAsNote(_ body: String, asked: String) {
        guard let recording else { return }
        let asked = asked.isEmpty ? "Asked in Listen" : asked
        let title = String(asked.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try Notes.create(title: title, body: body, source: .agent,
                                 prompt: asked, recordings: [recording.id])
            onNoteWritten?()
            say("Saved as a note. It is in the Notes tab.")
        } catch {
            say(error.localizedDescription)
        }
    }

    // MARK: - Drawing a turn

    /// Add a turn, full width.
    ///
    /// A leading-aligned vertical stack gives each row its intrinsic width, and
    /// both turn views want the pane's width instead: the question bubble
    /// right-aligns itself inside it, and the answer wraps its paragraphs to
    /// it. Without this the answers wrapped at whatever width the pane happened
    /// to be when the turn was built, which on a wide window was about half of
    /// it.
    private func addTurn(_ view: NSView) {
        turns.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: turns.widthAnchor).isActive = true
    }

    private func view(for turn: Chat.Turn, asking: String) -> NSView {
        if turn.who == Chat.you { return QuestionTurn(turn.text) }
        let answer = AnswerTurn(question: asking) { [weak self] body, asked in
            self?.saveAsNote(body, asked: asked)
        }
        answer.restore(turn)
        return answer
    }

    private func scrollToEnd() {
        // After layout, not before. A turn added this pass has no height yet,
        // so scrolling now goes to where the end used to be.
        layoutSubtreeIfNeeded()
        guard let document = scroll.documentView else { return }
        let bottom = max(0, document.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

// ---------------------------------------------------------------------------
// The two kinds of turn
// ---------------------------------------------------------------------------

/// What was asked: right-aligned, in a tinted bubble.
///
/// Right-aligned because that is what every chat does and the convention is
/// worth more here than originality: it is the only cue that separates the two
/// speakers at a glance when both are plain text.
private final class QuestionTurn: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.layer?.backgroundColor = Brand.accent.withAlphaComponent(0.16).cgColor
        bubble.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        addSubview(bubble)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),

            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Never the full width: a question that reaches the left edge stops
            // reading as a bubble and starts reading as a paragraph.
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                            constant: 60),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no nib") }
}

extension AskView: NSTextFieldDelegate {
    /// The send button lights up on the first character and goes out on the
    /// last one deleted.
    func controlTextDidChange(_ notification: Notification) {
        updateSendButton()
    }
}

/// The glass capsule the question is typed into.
///
/// Liquid Glass where the OS has it and the same `.hudWindow` vibrancy below
/// that, which is the pair `RecordButton` already uses. Those two are the only
/// controls this app floats over its own content, and they should be made of
/// the same thing.
///
/// Laid out by frame rather than by constraints, and that is not a style
/// choice: `NSGlassEffectView` positions its `contentView` itself, so anything
/// pinned across that boundary is two systems fighting over one number. See
/// `RecordButton.layout`, which paid for this once already.
final class ComposerWell: NSView {
    /// Deliberately large. 36 was the first version and read as a search field;
    /// this is the primary control of the pane and the thing the whole mode
    /// exists for, so it is sized like one.
    static let height: CGFloat = 52
    private static let radius: CGFloat = height / 2
    private static let inset: CGFloat = 20
    private static let gap: CGFloat = 10
    private static let send: CGFloat = 36

    private let backdrop: NSView
    private let content = NSView()
    private let field: NSTextField
    private let model: NSButton
    private let sendButton: NSView

    init(field: NSTextField, model: NSButton, send: NSView) {
        self.field = field
        self.model = model
        self.sendButton = send
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = Self.radius
            backdrop = glass
        } else {
            let vibrant = NSVisualEffectView()
            vibrant.material = .hudWindow
            vibrant.blendingMode = .withinWindow
            vibrant.state = .active
            vibrant.wantsLayer = true
            vibrant.layer?.cornerRadius = Self.radius
            vibrant.layer?.masksToBounds = true
            backdrop = vibrant
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(field)
        content.addSubview(model)
        content.addSubview(sendButton)

        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            // The supported way in: the header says only `contentView` is
            // guaranteed a place inside the effect.
            glass.contentView = content
            addSubview(glass)
        } else {
            addSubview(backdrop)
            addSubview(content)
            // Liquid Glass brings its own edge. Below it the capsule is a flat
            // blur with nothing separating it from the answer above.
            backdrop.layer?.borderWidth = 1
            backdrop.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
        content.frame = bounds
        let b = content.bounds
        let sendSize = Self.send
        sendButton.frame = NSRect(x: b.width - sendSize - (Self.height - sendSize) / 2,
                                  y: (b.height - sendSize) / 2,
                                  width: sendSize, height: sendSize)
        let modelSize = model.intrinsicContentSize
        let modelWidth = model.isHidden ? 0 : ceil(modelSize.width)
        model.frame = NSRect(x: sendButton.frame.minX - Self.gap - modelWidth,
                             y: round((b.height - modelSize.height) / 2),
                             width: modelWidth, height: ceil(modelSize.height))
        let fieldSize = field.intrinsicContentSize
        let fieldRight = model.isHidden ? sendButton.frame.minX : model.frame.minX
        field.frame = NSRect(x: Self.inset,
                             y: round((b.height - fieldSize.height) / 2),
                             width: max(0, fieldRight - Self.gap - Self.inset),
                             height: ceil(fieldSize.height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // A `CGColor` is a snapshot of what it was resolved from, so a light
        // and dark switch leaves the old edge behind.
        if !(backdrop is NSVisualEffectView) { return }
        backdrop.layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// The send button: a filled circle with a glyph in it, not a tinted symbol.
///
/// `arrow.up.circle.fill` in the accent colour was the first version and looked
/// cheap next to everything else, because it is a picture of a button rather
/// than one: the ring is drawn by the font, so it does not match the capsule's
/// radius, does not fill, and has no pressed state.
///
/// It is also the stop control. A question that is running has to be
/// interruptible, and the alternative is a second button that is disabled and
/// meaningless for all but twenty seconds of the pane's life.
final class SendButton: NSView {
    var onPress: (() -> Void)?

    var isReady = false { didSet { restyle() } }
    var isStop = false { didSet { restyle() } }

    private let glyph = NSImageView()
    private var pressed = false { didSet { restyle() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        glyph.imageScaling = .scaleProportionallyUpOrDown
        addSubview(glyph)
        restyle()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        let side = round(bounds.height * 0.46)
        glyph.frame = NSRect(x: round((bounds.width - side) / 2),
                             y: round((bounds.height - side) / 2),
                             width: side, height: side)
    }

    private func restyle() {
        let name = isStop ? "stop.fill" : "arrow.up"
        glyph.image = NSImage(systemSymbolName: name,
                              accessibilityDescription: isStop ? "Stop" : "Ask")
        glyph.symbolConfiguration = .init(pointSize: 13, weight: .bold)
        // Dimmed when there is nothing to send, rather than hidden or disabled
        // looking: the shape stays put so the capsule does not change width as
        // somebody types the first character.
        //
        // The idle state is the accent faded, **not** a grey. `tertiaryLabelColor`
        // as a *background* is a translucent white in dark mode, so the first
        // version drew a white disc with a `secondaryLabelColor` arrow on it,
        // which is light grey on near-white: the button read as a blank blob
        // with no glyph at all. A label colour is for labels.
        let live = isReady || isStop
        let fade: CGFloat = live ? (pressed ? 0.75 : 1) : 0.3
        layer?.backgroundColor = Brand.accent.withAlphaComponent(fade).cgColor
        glyph.contentTintColor = Brand.onAccent.withAlphaComponent(live ? 1 : 0.55)
        setAccessibilityLabel(isStop ? "Stop" : "Ask")
    }

    override func mouseDown(with event: NSEvent) {
        guard isReady || isStop else { return }
        pressed = true
        // Tracked to mouse-up rather than acting on the way down, so a press
        // that slides off the button is a cancelled press.
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let point = convert(next.locationInWindow, from: nil)
            inside = bounds.contains(point)
            pressed = inside
            if next.type == .leftMouseUp { break }
        }
        pressed = false
        if inside { onPress?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// What the pane says when there is nothing to ask with.
///
/// It stands in the starter chips' place rather than over the conversation, and
/// that placement is the point: a recording can hold answers saved before the
/// CLI was removed or logged out, and those are still worth reading. A block in
/// the middle of the pane would cover them.
///
/// Both buttons earn their space. Every state this appears in is fixed in a
/// terminal rather than in Listen, and `AgentCLI` caches its answer for the life
/// of the process, so without "Check again" the reward for installing something
/// is having to quit the app. "Open Agent settings" goes to the pane that
/// already lists both commands with a copy button beside each, which is why this
/// card does not try to be that pane.
private final class SetupNotice: NSView {
    var onCheckAgain: (() -> Void)?

    /// Detection is running. The button says so itself rather than leaving a
    /// press unacknowledged for the second or so a sweep takes.
    var isBusy = false {
        didSet {
            check.isEnabled = !isBusy
            check.title = isBusy ? "Looking…" : "Check again"
        }
    }

    /// Capped where the settings panes cap theirs, and for the same reason: a
    /// paragraph as wide as a full-screen window is one nobody finishes.
    static let maxWidth: CGFloat = 560

    private let heading = NSTextField(wrappingLabelWithString: "")
    private let body = NSTextField(wrappingLabelWithString: "")
    private let check = NSButton(title: "Check again", target: nil, action: nil)
    private let settings = NSButton(title: "Open Agent settings",
                                    target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        body.font = .systemFont(ofSize: 12)

        for button in [settings, check] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 12)
        }
        settings.target = self
        settings.action = #selector(openSettings)
        check.target = self
        check.action = #selector(checkAgain)

        let buttons = NSStackView(views: [settings, check])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let column = NSStackView(views: [heading, body, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            // Both labels wrap to the card rather than to their own strings. A
            // vertical stack gives an arranged subview the width it asks for,
            // and a wrapping label asks for its whole sentence on one line.
            heading.widthAnchor.constraint(equalTo: column.widthAnchor),
            body.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    /// Say the shortest true thing about why nothing can be asked.
    ///
    /// A CLI that is installed and never signed into wins over a missing one
    /// whenever both are true. `usable` treats the two the same, but they are
    /// one command apart and the wrong sentence sends somebody to install
    /// something they already have.
    func show(_ statuses: [AgentStatus]) {
        isHidden = false
        let out = statuses.filter { $0.path != nil && $0.signedIn == false }
        guard !out.isEmpty else {
            heading.stringValue = "Ask needs Claude Code or Codex"
            say("Neither is installed on this Mac. The model is yours and so is "
                + "the subscription: there is no Listen account and no key to "
                + "paste.\n\nAgent settings has the command for each, ready to copy.")
            return
        }
        let names = out.map(\.backend.name)
        heading.stringValue = names.joined(separator: " and ")
            + (out.count == 1 ? " is" : " are") + " installed but not signed in"
        say("Run " + out.map { "`\($0.backend.signInCommand)`" }
                .joined(separator: " or ")
            + " in a terminal, then check again.")
    }

    /// The app's own renderer, for the one thing the copy needs it for: a
    /// command in a sentence, set in the face a command is set in.
    private func say(_ markdown: String) {
        let text = NSMutableAttributedString(
            attributedString: MarkdownText.attributed(markdown, width: 12))
        // Every paragraph carries the newline it ended with, and the last one
        // would be a blank line inside the card.
        while let last = text.string.last, last.isNewline {
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
        text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                          range: NSRange(location: 0, length: text.length))
        body.attributedStringValue = text
    }

    @objc private func openSettings() { LibraryWindow.shared.showSettings(.agent) }

    @objc private func checkAgain() { onCheckAgain?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // A `CGColor` is a snapshot of what it was resolved from, so without
        // this the light edge stays behind after a switch to dark. The text
        // needs no such help: an attributed string holds the `NSColor` itself,
        // and a semantic one resolves when it is drawn.
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// A canned question, shaped like the tag chips it sits near.
private final class StarterChip: NSButton {
    private let onPress: () -> Void

    init(_ title: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .large
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    @objc private func fire() { onPress() }
}
