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

    /// And four for the library, where the same four would be wrong.
    ///
    /// A question about one meeting has its answer in one transcript. A question
    /// about the library only earns the trip if it crosses meetings, so these
    /// are the four shapes that do: what happened lately, what is still owed,
    /// what was settled, and what keeps coming back. "Summarise" is deliberately
    /// not among them, because summarising a library is summarising nothing.
    ///
    /// Each one names its own window, because the agent's first move otherwise
    /// is to decide how much of the library to read, and it decides badly: the
    /// brief in `Agent.swift` is a retrieval ladder, and a prompt that says "the
    /// last two weeks" puts it on the right rung without a round trip. They cite
    /// their meetings for the same reason the answers do: a claim about a
    /// library nobody can trace back is a claim nobody can check.
    private static let libraryStarters: [(String, String)] = [
        ("Catch me up",
         "What happened across my meetings in the last week? Give me the "
         + "highlights in under 200 words, and name the meeting each one is from."),
        ("Open items",
         "Go through my meetings from the last two weeks and list what is still "
         + "outstanding: commitments, action items, and questions nobody "
         + "answered. Say who owns each one and which meeting it came from."),
        ("Decisions",
         "What did we decide across my meetings in the last two weeks? One line "
         + "each, with the meeting it was decided in, and say which ones were "
         + "left open."),
        ("Recurring themes",
         "Look across my meetings from the last month and name the three "
         + "subjects that keep coming back. For each one, say what changed "
         + "between the first time it came up and the last, and cite the "
         + "meetings."),
    ]

    private let scroll = NSScrollView()
    private let turns = NSStackView()
    private let starterRow = NSStackView()
    /// The starters and the drawer's collapsed-state controls, on one line.
    private let starterLine = NSStackView()
    private let expandButton = HoverButton()
    private let notice = SetupNotice()
    /// The chips and the setup notice, in one slot above the composer. They are
    /// alternatives rather than neighbours: one invites a question and the other
    /// says why there is nobody to ask.
    private let invitation = NSStackView()
    private let field = ComposerField()
    private let sendButton = SendButton()
    private let modelButton = HoverButton()
    private lazy var composer = ComposerWell(field: field, model: modelButton,
                                             send: sendButton)
    private let status = NSTextField(labelWithString: "")
    private lazy var composerTrailing =
        composer.trailingAnchor.constraint(equalTo: trailingAnchor)
    /// **The status line is a slot, not a line that comes and goes.**
    ///
    /// It used to be zero points high until there was something to say, and
    /// because the composer's bottom hangs off the label's top, every one of
    /// those messages lifted the well 14 points and dropped it again when the
    /// message went. Nothing else on the pane moves under the caret, and the
    /// things that put text here are mid-question: a queued question, a note
    /// written, an answer that failed. So the space is held whether or not
    /// anything is in it. The label is positioned against the well, and never
    /// the other way round.
    ///
    /// It costs 14 points of empty space under an idle composer, and it is the
    /// same 14 `barHeight` has always reserved: the drawer's bar was already
    /// sized for a line that was usually not there, so this is the layout
    /// agreeing with the number rather than a new one.
    private static let statusHeight: CGFloat = 14

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
    /// Set instead of `recording` when a person's card is open. The two are
    /// alternatives: a question is about a meeting, about somebody, or about
    /// the library, and never about two of those at once.
    private var person: String?
    private var chat = Chat()
    /// Has a context ever been shown? See `show`.
    private var loaded = false
    /// Set by asking, cleared by merely arriving somewhere. Only a question
    /// deserves to take the page.
    private var wantsRoom = false
    /// The drawer's last reported state, so the caret can be re-evaluated when
    /// the conversation changes without the height changing.
    private var expandedNow = false
    /// Is the field being typed into? What the starter chips and the drawer's
    /// panel both key off. See `setComposing`.
    private var composing = false
    /// Armed only while `composing`, and the whole of "click away to stop
    /// asking". See `watchClicks`.
    private var clickAway: Any?
    /// Set when a conversation was opened on purpose, and cleared only by
    /// another deliberate act: starting one, opening another, or deleting this.
    ///
    /// **A context change then moves the context without moving the
    /// conversation.** Opening one from the landing screen selects nothing, so
    /// anything that arrives afterwards, including the sidebar picking a
    /// recording at launch, was overwriting a conversation the user had just
    /// asked for. Traced: two turns loaded, then `0 turns, id none`.
    ///
    /// Asking from somewhere else then continues the same conversation about
    /// both, which `persist` already handles by adding to `recordings` rather
    /// than replacing it.
    private var pinned = false
    private var run: AgentSession?
    /// The view being written into while an answer streams.
    private var answering: AnswerTurn?

    /// The one question typed while an answer was running, waiting its turn.
    ///
    /// Deliberately not in `chat.turns` and never persisted: `chat.json` is the
    /// record of what was actually asked, and a question that has not been sent
    /// yet is not that. If the pane goes away before it runs it goes with it.
    private var queued: String?
    /// Its bubble, kept so the cross can take it off screen again.
    private var queuedTurn: QuestionTurn?

    /// Told when a note is written, so the Notes mode can pick it up without
    /// being switched to and back.
    var onNoteWritten: (() -> Void)?

    /// Watches the network, so the line under the composer is right before a
    /// question is typed rather than only after one has failed. Released with
    /// the view, which is what unsubscribes it.
    private var connection: Reachability.Watcher?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        connection = Reachability.watch { [weak self] _ in
            // Off the monitor's queue: everything below this line is AppKit.
            DispatchQueue.main.async { self?.updateStatus() }
        }
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
        //
        // A `HoverButton` rather than a bare one, and that is the whole of what
        // it is for: the rest of the styling below is what it already brings.
        for button in [expandButton] {
            button.imagePosition = .imageOnly
            button.target = self
        }
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
        // The spacer is what pushes the controls to the trailing edge, and it
        // is the only thing in the row allowed to grow. Sideways, and only
        // sideways: see the height below.
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        starterRow.setContentHuggingPriority(.required, for: .horizontal)
        // **And it is zero points tall, which is what stopped a whole
        // conversation being drawn.**
        //
        // A bare `NSView` has no intrinsic content size, so nothing said how
        // tall this one is. That does not matter while something else in the
        // row is visible, and both of its neighbours are hidden in exactly the
        // state that matters: the chips go when there are turns, and the setup
        // card is only up when there is no agent. `NSStackView` detaches hidden
        // arranged views, so the row was left holding one view of no known
        // height, and its own height became a free variable. So did the row
        // above it, and so, therefore, did the conversation's scroll view,
        // which has no intrinsic content size either.
        //
        // Autolayout then split the drawer's spare height between the two of
        // them however it liked. Measured on the scratch library with
        // `LISTEN_CHAT`, drawer 548 points: scroll view 0 high over a document
        // 331 high, and this empty row 468. Every turn built, sized and laid
        // out, inside a view with no height. Content hugging cannot fix it,
        // because hugging pulls a view down to its intrinsic size and there is
        // no intrinsic size here to pull towards. Measured too: raising the
        // hugging priority on both rows changed nothing.
        //
        // It is history-dependent, which is why asking a new question always
        // looked fine and only reopening a saved one failed. Asking lays the
        // pane out with the chips visible, so the scroll view already holds a
        // real height when they disappear and the incremental solver leaves it
        // alone. Restoring goes the other way: the turns are added while the
        // drawer is still a bar, which pins the scroll view at 0, and every
        // point of the growth to 548 then goes to the empty row.
        spacer.heightAnchor.constraint(equalToConstant: 0).isActive = true

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

        // **The four things that are a column on a page.** Everything on this
        // pane is pinned to both of its sides in a card, which is right there
        // because a card is already a column: it is inset from the window and
        // sits over the meeting. A page is as wide as the window, and the same
        // constraints made a 168 character line of it. See `setPage`.
        //
        // The scroll view is deliberately not one of them. It stays pinned to
        // both edges, so the thing that scrolls is the page rather than a panel
        // inside it, and the scroller lands on the window's edge where a page's
        // scroller belongs.
        edgeWidth = [
            turns.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            turns.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            invitation.leadingAnchor.constraint(equalTo: leadingAnchor),
            invitation.trailingAnchor.constraint(equalTo: trailingAnchor),
            composer.leadingAnchor.constraint(equalTo: leadingAnchor),
            composerTrailing,
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ]
        // Centred on the scroll view rather than on the document, so the column
        // lines up with the composer under it. They are not the same number
        // when the scrollers are the always-visible kind: the document is then
        // narrower than the scroll view by the scroller's width, and a column
        // centred in it sits half a scroller to the left of the well.
        //
        // Only safe because the document's leading edge is pinned below. This
        // constraint reaches out of the clip view, and an unpinned document is
        // a way to satisfy it that the first scroll then undoes.
        columnWidth = [column(turns, in: document, centredOn: scroll),
                       column(invitation, in: self), column(composer, in: self),
                       column(status, in: self)].flatMap { $0 }

        NSLayoutConstraint.activate(edgeWidth + [
            // **The clip view's width, not the scroll view's.** They differ by
            // the scroller on a Mac set to show them always, which is a mouse
            // plugged in for most people, and the document was then wider than
            // the visible area: no horizontal scroller appeared, because the
            // constraint said there was nothing to scroll, and the right-hand
            // edge of every question bubble was simply cut off.
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            // **And its leading edge, or the solver moves the document instead
            // of the column.** A width on its own leaves the document's x free,
            // and the centring above crosses out of the clip view, so the
            // cheapest way to satisfy it is to slide the whole document
            // sideways: measured at `document.frame.origin.x == -249` with the
            // clip's bounds origin at -249 to match, which cancels out and looks
            // perfectly centred. The first scroll resets the bounds origin to
            // zero, nothing puts the document back, and the conversation jumps
            // by that many points and stays there.
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            turns.topAnchor.constraint(equalTo: document.topAnchor),
            turns.bottomAnchor.constraint(equalTo: document.bottomAnchor),

            scrollTop,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: invitation.topAnchor, constant: -8),

            invitation.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8),
            notice.widthAnchor.constraint(lessThanOrEqualTo: invitation.widthAnchor),
            wide,

            composer.heightAnchor.constraint(equalToConstant: ComposerWell.height),
            composer.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),

            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            status.heightAnchor.constraint(equalToConstant: Self.statusHeight),
        ])
    }

    /// One view, centred in a column of `Self.pageColumn` points.
    ///
    /// **The width is stated at 300, and the margins are what cannot be
    /// broken.** 300 is above everything inside this pane with an opinion about
    /// width, the highest of which is a stack view's own content hugging at
    /// 250, and below `windowSizeStayPut`, which is 500 and is where AppKit
    /// holds the window against its content. Both edges of that range were
    /// measured on the built app while this was being written: at 500 the
    /// column reached the window and shrank it from 1512 points to 1136, and
    /// then refused to be dragged wider; at 240 it lost to the hugging and came
    /// out 560 wide whatever the window did, 560 being `SetupNotice.maxWidth`
    /// and the hidden setup card the only thing left with an opinion.
    ///
    /// A width that can be broken is also what makes a narrow window work: the
    /// two margins are required, so a pane narrower than the column falls back
    /// to its edges instead of refusing to be that narrow.
    private func column(_ view: NSView, in parent: NSView,
                        centredOn centre: NSView? = nil) -> [NSLayoutConstraint] {
        let width = view.widthAnchor.constraint(equalToConstant: Self.pageColumn)
        width.priority = NSLayoutConstraint.Priority(300)
        return [
            view.centerXAnchor.constraint(equalTo: (centre ?? parent).centerXAnchor),
            view.leadingAnchor.constraint(greaterThanOrEqualTo: parent.leadingAnchor,
                                          constant: Self.pageMargin),
            view.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor,
                                           constant: -Self.pageMargin),
            width,
        ]
    }

    /// A card, or a page.
    ///
    /// The pane is the same in both: the difference is that a page is as wide
    /// as the window, so the conversation becomes a column in the middle of it
    /// and the space above it makes room for the toolbar the page's controls
    /// now live in. The window owns which of the two this is.
    func setPage(_ on: Bool) {
        guard on != isPage else { return }
        isPage = on
        // Off before on: the two sets both state a width, and a moment with
        // both active is a conflict the solver logs.
        NSLayoutConstraint.deactivate(on ? edgeWidth : columnWidth)
        NSLayoutConstraint.activate(on ? columnWidth : edgeWidth)
        // **The conversation stops at the toolbar rather than scrolling under
        // it.** A content inset was the other way, and is what `DetailView`
        // does with its notes pane, but the page's own controls sit in that
        // strip now: text sliding under a glass group with History and New chat
        // in it is legible through the glass and reads as two things in one
        // place.
        scrollTop.constant = on ? Self.pageTopPad : 0
        needsLayout = true
    }

    /// See `column`. 620 is 105 characters of the 13 point body, which measures
    /// 5.9 points a character, and is deliberately the same number
    /// `Pane.maxContentWidth` caps a settings pane at.
    private static let pageColumn: CGFloat = 620
    /// The least a column may have between it and the window's edge.
    private static let pageMargin: CGFloat = 24
    /// Clear of the toolbar, which floats over the content because the window
    /// is full-size-content.
    private static let pageTopPad: CGFloat = 52
    private var isPage = false
    private var edgeWidth: [NSLayoutConstraint] = []
    private var columnWidth: [NSLayoutConstraint] = []
    private lazy var scrollTop = scroll.topAnchor.constraint(equalTo: topAnchor)

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
        field.placeholderString = placeholder(for: nil)
        field.target = self
        field.action = #selector(send)
        field.delegate = self
        field.onFocusChanged = { [weak self] on in self?.setComposing(on) }
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
        modelButton.font = .systemFont(ofSize: 12)
        modelButton.imagePosition = .imageRight
        // Empty rather than nil. An SF Symbol carries its own description, so
        // nil leaves the chevron announcing itself and the button read as
        // "Claude Code, go down".
        modelButton.image = Self.modelChevron
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
        // **Opening the menu is the moment freshness matters**, and it is not
        // covered by `updateStatus`, which is event-driven: an app left idle
        // for a week and then clicked straight into this menu would build it
        // from a week-old cache. This lands for the next open rather than this
        // one, which is the same trade made there, and it is why the check is
        // in both places rather than only the tidier one.
        AgentCLI.refreshStaleProviders { [weak self] in self?.updateModelButton() }

        let menu = NSMenu()
        for status in AgentCLI.cached ?? [] {
            guard status.usable else { continue }
            let header = NSMenuItem(title: status.name, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            let chosen = AgentCLI.cachedChosen()?.key == status.key
            let current = Settings.agentModel(status.key)
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
                   at: NSPoint(x: 0, y: modelButton.bounds.height + 4), in: modelButton)
    }

    /// How many of a provider's models the composer's menu will show.
    static let modelsInMenu = 12

    /// The chevron on the model control, kept so the loading state can take it
    /// away and put it back.
    ///
    /// Empty description rather than nil: an SF Symbol carries its own, so nil
    /// leaves the chevron announcing itself and the button reads as "Claude
    /// Code, go down".
    static let modelChevron = NSImage(systemSymbolName: "chevron.down",
                                      accessibilityDescription: "")

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
        ModelPicker.present(models: status.models, current: Settings.agentModel(key),
                            over: window) { [weak self] id in
            self?.use(key, model: id)
        }
    }

    /// Switch to a backend and a model, and remember that the model was used.
    private func use(_ key: String, model: String?) {
        Settings.agentChoice = key
        Settings.setAgentModel(key, model)
        // Recorded on the choice rather than on a successful answer: a model
        // that turned out not to support tools is still one that was reached
        // for, and hiding it would make the failure awkward to retry.
        Settings.noteModelUsed(key, model)
        updateStatus()
    }

    /// What the composer's chooser says right now.
    private func updateModelButton() {
        // **"Still looking" and "nothing usable" are different states and only
        // one of them is worth a word.** Both used to hide this control and put
        // a line of grey text under the composer instead, which is the wrong
        // place twice over: it is a long way from the thing it describes, and
        // it made the bar change height a second after launch for everybody
        // with a working agent.
        //
        // Detection not finished is a *loading* state, and the control that is
        // about to say which model is the one that should say it is finding
        // out. Nothing usable stays silent here, because `SetupNotice` is
        // already up saying it properly.
        guard AgentCLI.cached != nil else {
            modelButton.isHidden = false
            modelButton.isEnabled = false
            modelButton.title = "Loading…"
            // No chevron while there is nothing to pop up. A disclosure on a
            // control that cannot be pressed is an offer the app cannot keep.
            modelButton.image = nil
            modelButton.setAccessibilityLabel("Looking for an agent")
            composer.needsLayout = true
            return
        }
        guard let chosen = AgentCLI.cachedChosen() else {
            modelButton.isHidden = true
            return
        }
        modelButton.isHidden = false
        modelButton.isEnabled = true
        modelButton.image = Self.modelChevron
        let model = Settings.agentModel(chosen.key)
        let name = chosen.models.first { $0.id == model }?.name
        // The backend's name when nothing is chosen, the model's when one is.
        // Never both: the row is 11 point text in a 36 point well, and "Claude
        // Code · Sonnet" is the kind of label that makes a composer look busy.
        modelButton.title = name ?? chosen.name
        modelButton.setAccessibilityLabel(
            "Agent and model: \(chosen.name), \(name ?? "default")")
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
    static func prompt(for recording: Recording?, person: String? = nil) -> String {
        if let person { return "Ask about \(person)…" }
        return recording == nil ? "Ask about your library…" : "Ask about this meeting…"
    }

    /// And what it offers while an answer is running, which is a different
    /// thing: Return still works, and what it does then is queue rather than
    /// ask. The send button cannot say so, because it is the Stop control for
    /// exactly as long as this is true, so the empty field is the only surface
    /// left that can say it *before* somebody finds out by pressing it.
    static let waitingPrompt = "Ask a follow-up. It goes when this answer finishes…"

    private func placeholder(for recording: Recording?, person: String? = nil) -> String {
        isRunning ? Self.waitingPrompt : Self.prompt(for: recording, person: person)
    }

    /// The same, for the places that already know what the pane is about.
    private func refreshPlaceholder() {
        field.placeholderString = placeholder(for: recording, person: person)
    }

    func show(_ recording: Recording?) {
        // Pinned: take the new context, keep the conversation.
        if pinned {
            self.recording = recording
            person = nil
            field.placeholderString = placeholder(for: recording)
            updateStatus()
            return
        }
        field.placeholderString = placeholder(for: recording)
        // `loaded` is what gets the first call through. Both ids are nil at
        // launch, so guarding on the id alone meant the library context never
        // loaded its conversation at all: the bar came up empty next to a
        // history full of them.
        guard recording?.id != self.recording?.id || !loaded else { return }
        loaded = true
        stop()
        self.recording = recording
        person = nil
        // **Always a fresh conversation, and resuming is History's job.**
        //
        // This used to load the newest conversation in whatever context you had
        // arrived at: the newest about this meeting, or the newest about
        // nothing. It meant opening the app put you back into an old
        // conversation you had not asked for, and clicking a meeting somebody
        // had asked about once silently swapped an empty composer for a page of
        // last week's answers. The starter chips went with it, because there
        // were turns, so the pane you were given depended on history you could
        // not see.
        //
        // Nothing is lost by dropping it. Every conversation is in History, and
        // a meeting's own are named on the page under "Also about this".
        chat = Chat()
        wantsRoom = false
        redraw()
    }

    /// A person's card is a context like any other.
    ///
    /// Their recordings are named in the question rather than filtered to,
    /// which is the rule `start` already follows for a meeting: a hard filter
    /// would make "is this like what she said last year" unanswerable.
    func show(person name: String) {
        guard name != person else { return }
        if pinned {
            recording = nil
            person = name
            field.placeholderString = placeholder(for: nil, person: name)
            updateStatus()
            return
        }
        stop()
        loaded = true
        recording = nil
        person = name
        field.placeholderString = placeholder(for: nil, person: name)
        // Fresh, for the reason `show(_:)` records. Their conversations are in
        // History like everybody else's.
        chat = Chat()
        wantsRoom = false
        redraw()
    }

    /// Open a conversation from the history, whatever it is about.
    ///
    /// The recording is taken from the conversation rather than the other way
    /// round, so resuming a question about four meetings does not silently
    /// narrow it to one. A conversation about none leaves the recording nil,
    /// which is the library-wide case.
    func open(_ chat: Chat) {
        trace("askview open: \(chat.id ?? "none") with \(chat.turns.count) turns")
        stop()
        self.chat = chat
        recording = chat.sources.first.flatMap { Recording.find($0) }
        person = chat.person
        field.placeholderString = placeholder(for: recording, person: person)
        loaded = true
        // Picked out of the history on purpose, so this one does deserve room,
        // and deserves to survive whatever selection arrives next.
        wantsRoom = true
        pinned = true
        redraw()
        onWantsOpen?()
    }

    /// Start a new conversation, keeping whatever is on screen as its subject.
    ///
    /// **`wantsRoom` goes with the turns.** It is set by asking and by opening
    /// something from History, and it is the whole of the height report: while
    /// it is true `reportHeight` says 560 whatever is in the view. Leaving it
    /// set here meant the empty conversation this leaves behind still claimed a
    /// card's worth of room, and the drawer believed it: `applyHeight` reads
    /// the last reported height to decide whether a bar should open itself, so
    /// pressing the cross cleared the answers and then immediately reopened the
    /// card around nothing. Both header discs land here, so both did it. The
    /// other three fresh-conversation paths, `show`, `show(person:)` and
    /// `discard`, already cleared it; this was the one that did not.
    func startNew() {
        stop()
        chat = Chat()
        pinned = false
        wantsRoom = false
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

    /// Give up the caret, wherever the click landed.
    ///
    /// `NSView` does not accept first responder, so a click on the page behind
    /// the bar goes nowhere and the field keeps the caret: the chips stayed up
    /// and the drawer stayed backed over a meeting somebody had gone back to
    /// reading. Only another control took it away. See `watchClicks` for why
    /// this is driven by an event monitor rather than by `mouseDown`.
    func endComposing() {
        guard field.currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
    }

    private func redraw() {
        trace("askview redraw: \(chat.turns.count) turns, id \(chat.id ?? "none"), "
              + "scrollHidden \(scroll.isHidden), expandedNow \(expandedNow)")
        for view in turns.arrangedSubviews { view.removeFromSuperview() }
        answering = nil
        // The bubble has just been removed with everything else, so this is the
        // pointer rather than the view. Every route here goes through `stop`
        // first, which empties the queue; this is what keeps that true if a
        // fourth one is ever added.
        queued = nil
        queuedTurn = nil
        // The question each answer belongs to, tracked while walking the list so
        // a conversation saved before `Chat.Turn.question` existed still titles
        // its notes from the right place.
        var asked = ""
        for (index, turn) in chat.turns.enumerated() {
            if turn.who == Chat.you { asked = turn.text }
            let built = view(for: turn, asking: turn.question ?? asked)
            // Only the last turn may offer Try again, and `view(for:)` cannot
            // know which one that is. A failure halfway up a conversation is
            // history: re-asking it would put an old question after everything
            // said since, and answer it with all of that as context.
            if index == chat.turns.count - 1, let answer = built as? AnswerTurn,
               answer.failed {
                answer.onRetry = { [weak self, weak answer] in
                    guard let self, let answer else { return }
                    self.retry(answer)
                }
            }
            addTurn(built)
        }
        // The chips are drawn by `updateStatus`, which is the only thing that
        // knows whether there is anything to ask.
        updateStatus()
        // And the caret is re-evaluated here rather than only when the drawer
        // resizes. Starting a new conversation changes what there is to expand
        // without changing any height, so the caret was left offering to open a
        // conversation that no longer existed.
        setExpanded(expandedNow)
        scrollToEnd()
    }

    /// The field gained or lost the caret.
    ///
    /// The height is re-reported even though it does not change: the drawer's
    /// panel is decided in `applyHeight`, and this is the only thing that tells
    /// it to look again. The bar's height is deliberately the same either way,
    /// because the chips share their line with the drawer's own controls, so
    /// clicking into the field brings a panel and four chips rather than a
    /// panel, four chips and a jump.
    private func setComposing(_ on: Bool) {
        guard composing != on else { return }
        composing = on
        watchClicks(on)
        drawStarters()
        reportHeight()
    }

    /// Watch for the click that means somebody has stopped asking.
    ///
    /// **A monitor rather than `mouseDown`, and the labels are why.** The
    /// pattern this app already uses for the title field is a `mouseDown` on
    /// the pane, which catches every click no subview claimed because
    /// `NSView.mouseDown` forwards up the responder chain. `NSControl` does not
    /// forward, and every piece of text on these pages is an `NSTextField`, so
    /// clicking the empty state's own sentence, a transcript line or a speaker
    /// name would have left the caret exactly where the complaint started. A
    /// local monitor sees the click whoever ends up claiming it.
    ///
    /// **The whole bar is "inside", not just the well.** The test is this
    /// view's bounds, so the chips, the conversation and the model menu all
    /// keep the caret. Anything narrower breaks the chips: the monitor runs
    /// before the click is dispatched, so ending editing on a chip press empties
    /// the row under the mouse and the press then lands on nothing. That trap is
    /// the reason `ComposerField.textDidEndEditing` was left alone.
    private func watchClicks(_ on: Bool) {
        if let clickAway { NSEvent.removeMonitor(clickAway) }
        clickAway = nil
        guard on else { return }
        clickAway = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window, window === event.window else { return event }
                if !bounds.contains(convert(event.locationInWindow, from: nil)) {
                    endComposing()
                }
                return event
            }
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
        //
        // **And only once somebody is actually asking.** Standing over a
        // meeting page they were four unbacked chips lying on the transcript,
        // with its text running straight through them, because the drawer draws
        // no panel until it has something to hold. Waiting for the field solves
        // both halves at once: nothing covers the page until you mean to ask,
        // and by the time the chips are up the panel is up behind them.
        //
        // **The library gets four of its own, and a person still gets none.**
        // `recording != nil` used to be the whole test, which was right about
        // the meeting chips and wrong about the screen it left bare: clicking
        // into the library composer drew a well and a frame with nothing in it,
        // on the one screen where somebody has the least idea what to ask. A
        // person is the case still left out, because a pane narrowed to one
        // name has a question in it already and four chips would each have to
        // guess which.
        guard composing, chat.turns.isEmpty, person == nil,
              AgentCLI.cachedChosen() != nil else {
            starterRow.isHidden = true
            return
        }
        starterRow.isHidden = false
        for (label, prompt) in recording != nil ? Self.starters : Self.libraryStarters {
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
            // Not "Claude Code or Codex" any more: naming two of three backends
            // in the line that appears while all three are being looked for
            // reads as the third one not being supported.
            // Nothing here. The composer's model control says "Loading…"
            // instead, which is where somebody is already looking when they
            // want to know what will answer.
            say("")
            notice.isHidden = true
            setAskable(false)
            // **Reported here too, and this branch is the one that runs first.**
            //
            // Without it the drawer kept the height it was built with, which is
            // below what the well needs, and `ComposerWell` lays its field,
            // model control and send button out by frame: the first thing on
            // screen at launch was a squashed capsule with the send button as a
            // flattened oval and the model name clipped to "Claude Co". It
            // corrected itself a second later, when detection finished and the
            // branches below reported a height for the first time, which made
            // it look like a loading state rather than a layout fault.
            reportHeight()
            // Once, and the callback puts the real state up.
            AgentCLI.warmUp { [weak self] in self?.updateStatus() }
            return
        }
        guard let chosen = AgentCLI.cachedChosen() else {
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
        // A provider's catalogue goes stale while the app sits in the menu bar
        // for a week. This is a date comparison in the common case and a few
        // background HTTP GETs when it is not, and it lands in the cache for
        // the next menu rather than this one. `updateStatus` runs on every
        // selection and after every answer, which is often enough that the list
        // is rarely more than its staleness window behind.
        AgentCLI.refreshStaleProviders()

        // A fact about right now, which is exactly what this label is for.
        //
        // Said here as well as on the failed turn because the two arrive at
        // different moments: this one is up before the question is typed, and
        // costs nobody the wait. The composer is deliberately **not** disabled:
        // see `Reachability.offline`, a wrong reading has to cost a sentence
        // rather than the feature.
        // `needsNetwork`, not the bare check: a model running on this Mac
        // answers with the Wi-Fi off, and there is nothing to warn somebody on
        // that backend about.
        if chosen.needsNetwork, Reachability.offline(waitingUpTo: 0) {
            say("No internet connection. \(chosen.name) answers over the "
                + "network, so a question asked now will not get through.")
            return
        }

        // Nothing at all when everything is working.
        //
        // It said "Answers come from your recordings only", which is true and
        // was still the wrong thing to put under every question forever: it is
        // a fact about the feature, not a fact about right now, and a standing
        // line of small grey text is read once and then becomes furniture. The
        // place for it is Settings › Ask, which says it in full.
        //
        // The label stays for the things that *are* about right now: looking
        // for an agent, not finding one, and confirming a note was written.
        say("")
    }

    /// Pressed on the clock and on the chevron in the starters line. The drawer
    /// owns what they mean, because only it knows how tall it is.
    /// Carries the button, because the menu has to pop up from the control
    /// that was pressed and that control lives here, not in the drawer.
    var onExpand: (() -> Void)?

    @objc private func expandPressed() { onExpand?() }

    /// Both controls belong to the collapsed bar. Expanded, the drawer's own
    /// header carries the title and the size controls, and a second clock under
    /// it would be the same action offered twice, six points apart.
    func setExpanded(_ on: Bool) {
        expandedNow = on
        expandButton.isHidden = on || !hasConversation
        // **The conversation is taken out of the view, not merely squeezed.**
        // Collapsed, the scroll view still had the whole answer in it at a few
        // points high: legible through the glass and scrollable with a
        // trackpad, which is a conversation nobody asked to see behind a bar
        // that says it is put away.
        scroll.isHidden = !on
        // **Un-hiding is not enough.** The turns are added while this is hidden,
        // because the drawer only asks to expand once the conversation is
        // loaded, and a scroll view whose document was built out of sight comes
        // back with nothing laid out in it. Same staleness as `ComposerWell`,
        // same cure: ask for the pass explicitly.
        guard on else { return }
        needsLayout = true
        layoutSubtreeIfNeeded()
        scrollToEnd()
        trace("askview expanded: scroll \(scroll.frame.height) high over a document of "
              + "\(scroll.documentView?.frame.height ?? 0), invitation "
              + "\(invitation.frame.height)")
    }

    /// The height this needs as a bar: the well, its status line, and the
    /// starters line, which is always there because the controls live in it.
    ///
    /// Asked for rather than assumed. The drawer hardcoded 68, which is below
    /// this, so collapsing squeezed the well until autolayout gave up somewhere
    /// and the send button came back a flattened oval.
    ///
    /// **Every gap is counted, and the status line is what made that worth
    /// saying.** The old sum came to 14 points less than the constraints
    /// require, and got away with it for exactly as long as the status label was
    /// zero high with nothing to say: that spare 14 was quietly paying for the
    /// gap above the starters. The moment the label became a permanent slot the
    /// same points were spent twice, the pane was solved 14 short of its own
    /// contents, and the starters came out flat against the top edge of the
    /// drawer with nothing above them.
    var barHeight: CGFloat {
        // Floor to ceiling, in the order the constraints below state them: the
        // pane's own inset inside the drawer, under the status line, between it
        // and the well, the well, and the gap over the starters row. The
        // scrolling conversation is what takes up the difference when there is
        // more room than this, and it is zero points high in a bar.
        var height = Self.paneBottomInset + 6 + Self.statusHeight + 6
            + ComposerWell.height + 8
        if !notice.isHidden {
            height += notice.fittingSize.height + 8
        } else {
            height += max(starterLine.fittingSize.height, 20) + 8
        }
        return height
    }

    /// How far the pane's floor is off the drawer's, which is
    /// `DetailWithComposer`'s number and is stated here because `barHeight` is
    /// a height for the drawer rather than for this view.
    private static let paneBottomInset: CGFloat = 12

    /// Is there a conversation to go back to, as opposed to an empty composer?
    var hasConversation: Bool { !chat.turns.isEmpty }

    /// Is the composer in use, as opposed to sitting there waiting to be?
    ///
    /// The drawer asks, because it is what decides whether to draw a panel
    /// behind all this. See the note on `backdrop` in `applyHeight`.
    ///
    /// The setup card counts as in use whether or not anybody has clicked into
    /// the field: it is several lines of text explaining why asking will not
    /// work, and it has to be readable over whatever is behind it.
    var isActive: Bool { composing || !notice.isHidden }

    /// Which conversation is open, so the history can tick it.
    var currentID: String? { chat.id }

    /// The recording this composer is about, or nil for the library. What the
    /// history scopes itself to.
    var contextID: String? { person.map { "person:" + $0 } ?? recording?.id }

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

    /// Fired when a conversation has been loaded and wants to be on screen.
    ///
    /// Separate from the height report, which the drawer has to interpret. This
    /// one is unambiguous, and it arrives *after* the turns are in, so the view
    /// being un-hidden already has something in it.
    var onWantsOpen: (() -> Void)?

    private func reportHeight() {
        // A conversation needs the room a bar does not have. The owner clamps
        // this to what the window can spare, so asking for more than exists is
        // safe and asking for a share of an unknown height is not.
        onHeightChanged?(wantsRoom || run != nil ? 560 : barHeight)
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

    /// Put a transient line under the composer.
    ///
    /// Text only: the space it goes in is already there, for the reason
    /// `statusHeight` records.
    private func say(_ text: String) {
        status.stringValue = text
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
        // Before `stop`, which drops it. Stop means this conversation has gone
        // far enough for now, and firing the queued question a moment later
        // would be the pane answering a press to stop by starting something.
        let waiting = takeQueued()
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
        if let waiting {
            returnToComposer(waiting)
            say("Stopped. The question waiting behind that answer is back in "
                + "the composer.")
        }
        refreshPlaceholder()
    }

    // MARK: - Asking

    /// Return, or the arrow. Which of the two things it does depends on whether
    /// an answer is already streaming, and neither of them loses the text.
    ///
    /// **The field is cleared by whoever takes the question, never before.** It
    /// used to be cleared here and the text handed to `ask`, whose first line is
    /// `guard run == nil`: a follow-up typed while an answer was running was
    /// wiped out of the field and then dropped by that guard, silently. Nothing
    /// on screen changed, so it looked like a keystroke that had not registered.
    /// Same swallowing the comment in `ask` records for a different guard on the
    /// same path, and the fix is the same one: accept first, clear second.
    @objc private func send() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard isRunning ? queue(text) : ask(text) else { return }
        field.stringValue = ""
        updateSendButton()
    }

    /// Park a follow-up until the answer on screen has finished.
    ///
    /// **Not injected into the running turn, because no backend here can take
    /// it.** A CLI question is one spawned process carrying its own `--resume`,
    /// and the endpoint backend is one loop over one question; none of the three
    /// has a way to hear a second message mid-answer. Claude Code's own composer
    /// can queue into a turn because it owns the loop. This one cannot, so
    /// queueing means "ask this next", and the bubble is drawn as something
    /// waiting rather than as something said.
    ///
    /// **One slot.** A stack of questions against a session that answers them
    /// one at a time reads as a batch job, and by the time the third ran it
    /// would usually be stale or already covered by the second. A further Return
    /// is refused and the text stays in the field, which is the rule this whole
    /// change is about: nothing typed is thrown away without being asked.
    ///
    /// **Stop is the way out**, and the line says so, because the bubble carries
    /// no control of its own. See `QuestionTurn`.
    private func queue(_ text: String) -> Bool {
        guard queued == nil else {
            say("One question is already waiting. It goes as soon as this answer "
                + "finishes, and Stop brings it back to the composer.")
            return false
        }
        queued = text
        let bubble = QuestionTurn(text, waiting: true)
        queuedTurn = bubble
        addTurn(bubble)
        reportHeight()
        scrollToEnd()
        return true
    }

    /// Take the waiting question off the screen, and hand back what it said.
    @discardableResult
    private func takeQueued() -> String? {
        guard let text = queued else { return nil }
        queued = nil
        queuedTurn?.removeFromSuperview()
        queuedTurn = nil
        reportHeight()
        return text
    }

    /// Put a question that is not going to be asked back where it was typed.
    ///
    /// Only into an empty field. Somebody who has started typing something else
    /// is owed their own words more than the ones they had queued, and there is
    /// no way to hold both without inventing a second place to keep text.
    private func returnToComposer(_ text: String) {
        guard field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        field.stringValue = text
        updateSendButton()
    }

    /// Ask now. Returns whether the question was taken, which is what tells the
    /// composer it may clear itself.
    @discardableResult
    private func ask(_ text: String) -> Bool {
        // **No `let recording`.** A guard that fails here is a question that
        // never happens, and for as long as `send` cleared the field first it
        // was also one nobody could get back: the text vanished and nothing
        // else moved. That is what asking about the library did from the moment
        // the composer left the meeting pane.
        //
        // Nothing downstream needed the recording. `start` already scopes the
        // question to one only when there is one, and deliberately as a
        // sentence rather than a hard filter, so the library case was written
        // and reachable everywhere except through this line.
        guard run == nil else { return false }
        guard let chosen = AgentCLI.cachedChosen(), let path = chosen.path else {
            updateStatus()
            return false
        }

        // A backend change invalidates the session: a Codex thread id means
        // nothing to Claude, and resuming with one is an error rather than a
        // fresh conversation.
        if chat.backend != chosen.key {
            chat.session = nil
            chat.backend = chosen.key
        }

        append(Chat.Turn(who: Chat.you, text: text, at: Metadata.iso(Date())))
        starterRow.isHidden = true

        // The answer carries the question that produced it. Looking the
        // question up at save time takes the *latest* one instead, so pressing
        // Save on an older answer filed it under a question asked afterwards,
        // which was measured and is exactly as confusing as it sounds.
        let answer = AnswerTurn(question: text) { [weak self] body, asked in
            self?.saveAsNote(body, asked: asked) ?? false
        }
        answer.onRetry = { [weak self, weak answer] in
            guard let self, let answer else { return }
            self.retry(answer)
        }
        answering = answer
        addTurn(answer)
        answer.begin(with: chosen.name)
        updateSendButton()
        scrollToEnd()

        start(text, status: chosen, path: path, resuming: chat.session)
        // **Again, and this is the call that makes the button a Stop.** `run` is
        // set inside `start`, so the call above it reads `isRunning == false`
        // and styles an arrow: the stop control existed, answered to a press,
        // and drew itself as Ask for the whole run. It corrected itself on the
        // first keystroke, because `controlTextDidChange` asks again, which is
        // why a pane nobody typed into while it worked never showed it.
        updateSendButton()
        refreshPlaceholder()
        return true
    }

    /// Run one question. Split out because a failed resume runs it again.
    private func start(_ text: String, status: AgentStatus, path: URL,
                       resuming: String?) {
        let backend = status.backend
        // Everything before this question, which an endpoint needs and a CLI
        // does not: a CLI is handed `resume` and remembers its own thread,
        // while an endpoint is stateless and is handed the messages every time.
        // The turn just appended by `ask` is dropped, because it is `text`.
        let history = Array(chat.turns.dropLast())

        // **Does the model know anything about this conversation yet?**
        //
        // `resuming == nil` used to be the whole test, and it was right while
        // every backend was a CLI that owns its thread. An endpoint has no
        // thread and no id, so that test is true on every turn and would
        // prefix "About the recording …" onto question five of a conversation
        // that has been about that recording since question one.
        //
        // History cannot replace it either, and the case that proves it is the
        // retry below: a CLI whose session has been forgotten starts again
        // knowing nothing, while `chat.turns` is full. It would lose the one
        // sentence saying which meeting is being discussed.
        //
        // So the question is asked of each backend in its own terms.
        let opening = backend.isCLI ? resuming == nil : history.isEmpty

        // The question is asked *about* a recording, and the agent is given
        // that as a sentence rather than as a hidden filter. It can still look
        // at the rest of the library, which is the point: "is this the same
        // thing we said last week" is a reasonable follow-up and a hard filter
        // would make it unanswerable.
        var scoped = text
        if opening, let recording {
            scoped = "About the recording `\(recording.id)` (\(recording.metadata.title)): \(text)"
        } else if opening, let person {
            // Named, not filtered, for the reason above. The instruction points
            // at the person's own material first, which is the retrieval ladder
            // the brief already describes, rather than fencing the library off.
            scoped = "About the person \(person). Start from the recordings they "
                + "speak in and the notes about those, then widen if you need to: \(text)"
        }
        let question = AgentRun.Question(
            text: scoped, backend: backend, path: path, resume: resuming,
            provider: status.provider, history: history,
            // Writes are on because "write this up as a note" is a thing to ask
            // a meeting assistant, and refusing it would mean the Save button
            // is the only route to something the agent could do itself.
            allowWrites: true, model: Settings.agentModel(status.key), streaming: true)

        var wroteAnything = false
        let run = question.session { [weak self] event in
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
            case .offline(let trouble):
                answer.offline(trouble)
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
                    self.start(text, status: status, path: path, resuming: nil)
                    return
                }
                self.finish(outcome, answer)
            }
        }
        self.run = run
        do {
            try run.start()
        } catch {
            // Through `finish`, not through `fail` alone. A run that never
            // started still has to end the turn: clear `answering`, write the
            // failure into `chat.json` so it is still there tomorrow, and put
            // the send button back. Without it the composer kept the Stop it
            // had been given a moment earlier and there was nothing left to
            // stop, which is how "no internet" would have looked worse than
            // the hang it replaces.
            if let answering {
                finish(AgentRun.Outcome(session: chat.session, costUSD: nil,
                                        durationMS: nil, toolCalls: 0,
                                        failure: error.localizedDescription),
                       answering)
            }
        }
    }

    /// Ask a failed turn's question again, in place.
    ///
    /// The failed answer is dropped from `chat.turns` first, so the retry is
    /// not appended *after* a red paragraph saying the same question could not
    /// be sent. The question turn above it stays: it was asked once.
    ///
    /// Nothing here is automatic. The connection coming back does not re-send a
    /// question by itself, because a question somebody has stopped wanting is
    /// worse than one they press a button for, and by then they may have typed
    /// a different one.
    private func retry(_ answer: AnswerTurn) {
        guard run == nil else { return }
        guard let chosen = AgentCLI.cachedChosen(), let path = chosen.path else {
            // The agent went away between the failure and the press. The line
            // under the composer says which, and it is the same sentence
            // somebody would get by typing the question again.
            updateStatus()
            return
        }
        // The last turn, and only if it is the failure this button belongs to.
        // A conversation that has moved on since is not one to rewrite.
        if let last = chat.turns.last, last.who == Chat.agent, last.failure != nil,
           last.text.isEmpty {
            chat.turns.removeLast()
            persist()
        }
        answering = answer
        answer.restart(with: chosen.name)
        updateSendButton()
        scrollToEnd()
        start(answer.question, status: chosen, path: path, resuming: chat.session)
        // After `start`, for the reason `ask` records: `run` is what makes the
        // button a Stop, and it is set in there.
        updateSendButton()
        refreshPlaceholder()
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

        // The follow-up somebody typed while this was running, which is the
        // whole reason the queue exists: it goes now, by itself, without a
        // second press.
        //
        // **Only after an answer that worked.** Sending it into a session that
        // has just failed spends a second question on the same broken thing and
        // leaves two red paragraphs where there was one problem, and it does it
        // while nobody is necessarily looking. A failure hands the question back
        // to the composer instead, where the same Try again decision applies to
        // it: pressed by a person, or not at all.
        if let next = takeQueued() {
            guard outcome.failure == nil else {
                returnToComposer(next)
                say("That answer failed, so the question waiting behind it is "
                    + "back in the composer rather than sent.")
                refreshPlaceholder()
                return
            }
            // `ask` can still decline it, if the agent went away in the minute
            // this answer took. Then it goes back to the composer too, and
            // `ask` has already put the reason on the status line.
            if !ask(next) { returnToComposer(next) }
        }
        refreshPlaceholder()
    }

    private func append(_ turn: Chat.Turn) {
        chat.turns.append(turn)
        addTurn(view(for: turn, asking: turn.text))
        persist()
        // The first turn is what turns the bar into a conversation, so the
        // height has to be re-asked here rather than only when the status
        // changes: an answer streaming into a view with no room to draw it is
        // indistinguishable from a question that was never sent.
        wantsRoom = true
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
        if chat.person == nil { chat.person = person }
        chat.save()
    }

    func stop() {
        run?.cancel()
        run = nil
        answering = nil
        // A question waiting behind an answer that is being abandoned goes with
        // it, and without being handed back. `stopAndTidy` takes it before
        // calling this and does hand it back, because somebody pressing Stop is
        // still in the conversation; every other caller here is a context change
        // (another meeting, another person, another conversation, a new one)
        // where the question was about something no longer on screen.
        takeQueued()
    }

    /// Throw the open conversation away and start a fresh one.
    ///
    /// It used to load whatever was left in this context, on the argument that
    /// deleting should land you on the previous conversation rather than on an
    /// empty composer. That is the same argument `show(_:)` used to make and it
    /// is wrong for the same reason: the composer is never a conversation
    /// nobody asked for, and one you have just deleted is the last moment to
    /// start guessing.
    func discard() {
        stop()
        pinned = false
        if let id = chat.id { Chat.forget(id: id) }
        chat = Chat()
        wantsRoom = false
        redraw()
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
    ///
    /// **No `guard let recording`, for the reason `persist` records.** There
    /// used to be one, and it made the button silently dead on the one screen
    /// most questions are asked from: a question asked with nothing selected is
    /// about the library, so `recording` was nil, so the press wrote nothing and
    /// said nothing. An answer that spans the library is the *most* worth
    /// keeping, and it is the case the library-level note store was built for.
    ///
    /// Returns whether a note was written, so the button that was pressed can
    /// say so itself. See `AnswerTurn.saveTapped`.
    private func saveAsNote(_ body: String, asked: String) -> Bool {
        let asked = asked.isEmpty ? "Asked in Listen" : asked
        let title = String(asked.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let note = try Notes.create(title: title, body: body, source: .agent,
                                        prompt: asked, recordings: sourcesForNote(),
                                        requiringSources: false)
            onNoteWritten?()
            say(note.recordings.isEmpty
                ? "Saved as a note about the library. It is in Notes in the sidebar."
                : "Saved as a note. It is in the Notes tab.")
            return true
        } catch {
            say(error.localizedDescription)
            return false
        }
    }

    /// The meetings a note out of this conversation is about.
    ///
    /// `chat.sources` rather than the recording on screen, because `persist` has
    /// already named the meeting every turn was asked on and the selection can
    /// have moved since: a conversation reopened from History is pinned, so
    /// clicking down the sidebar changes what is selected without changing what
    /// the conversation was about. Filing last week's answer against whatever is
    /// open now would be provenance that is confidently wrong.
    ///
    /// Filtered to what the library still has, because `Notes.create` refuses an
    /// id it cannot resolve and a conversation can outlive one of its
    /// recordings. An empty result is a note about the library, which is allowed.
    private func sourcesForNote() -> [String] {
        var ids = chat.sources
        if let id = recording?.id, !ids.contains(id) { ids.append(id) }
        return ids.filter { Recording.find($0) != nil }
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
            self?.saveAsNote(body, asked: asked) ?? false
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
    /// `waiting` is a question that has been typed and not yet asked.
    ///
    /// Drawn as the same bubble, fainter, with a line under it saying what it
    /// is waiting for. It belongs in the column because that is where it will
    /// appear when it goes, and it has to be told apart from the questions that
    /// were actually asked, because the difference between "the agent has heard
    /// this" and "the agent will hear this next" is the whole of what somebody
    /// needs to know about it.
    ///
    /// **No cancel control on the bubble.** A cross in front of a message is a
    /// second way to say stop, six points from the one the composer already has
    /// and pointing at a different thing, and it puts a control in the reading
    /// column where everything else is text. Stop is the way back: it takes the
    /// waiting question with it and hands it to the composer, which is where it
    /// was typed and where it can be edited or sent again.
    init(_ text: String, waiting: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier(waiting ? "queued-question" : "question")

        let bubble = NSView()
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.layer?.backgroundColor = Brand.accent
            .withAlphaComponent(waiting ? 0.08 : 0.16).cgColor
        bubble.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = waiting ? .secondaryLabelColor : .labelColor
        // Said out loud, because the colour is the only other thing that says
        // it and a colour is not readable by anything.
        if waiting { label.setAccessibilityLabel("Waiting to be asked: \(text)") }
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        addSubview(bubble)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),

            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Never the full width: a question that reaches the left edge stops
            // reading as a bubble and starts reading as a paragraph.
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                            constant: 60),
        ])

        guard waiting else {
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            return
        }
        // The caption, where a timestamp would go. Text rather than a symbol,
        // and under the bubble rather than in front of the words, so the column
        // stays a column of things somebody said.
        let caption = NSTextField(labelWithString: "Waiting for this answer to finish")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .tertiaryLabelColor
        caption.alignment = .right
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 3),
            caption.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -2),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
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

/// The composer's field, which says when it has the caret.
///
/// **`controlTextDidBeginEditing` is not that signal, and it looks like it.**
/// It is posted when the text first *changes*, so keying the starter chips off
/// it put them up one keystroke after the caret arrived, which is exactly one
/// keystroke too late for something whose whole job is to suggest what to type.
/// Measured: focusing the field left the chips down and the drawer unbacked.
///
/// `becomeFirstResponder` is called on the field itself before it hands over to
/// the field editor, and `textDidEndEditing` when the field editor gives up,
/// whether or not anything was typed. Between them they are the caret.
final class ComposerField: NSTextField {
    /// True when the caret arrives, false when it leaves.
    var onFocusChanged: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocusChanged?(true) }
        return took
    }

    /// **This is not what makes clicking away work.** `NSView` does not accept
    /// first responder, so a click on a plain view leaves the caret where it is
    /// and this never fires; only another control takes the field away.
    /// `AskView.watchClicks` is what turns a click on the page into a lost
    /// caret, and it does it by asking for this the ordinary way.
    ///
    /// Pressing a chip still does not end editing, and must not: an `NSButton`
    /// does not take first responder on a click, and if the row were emptied
    /// under the mouse between the press and the release the chip's action would
    /// never run. That is why the monitor treats the whole bar as inside.
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocusChanged?(false)
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
    private var hovering = false { didSet { restyle() } }

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

    /// **A button that announces itself has to be pressable.** This is an
    /// `NSView` with a `mouseDown`, so it had a role, a label and no way for
    /// anything but a mouse to use it. That was survivable while Stop only
    /// stopped; it is not now, because Stop is also the way to take back a
    /// question waiting behind an answer, and that would have been a control
    /// only reachable by pointer.
    override func accessibilityPerformPress() -> Bool {
        guard isReady || isStop else { return false }
        onPress?()
        return true
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
        // **Lighter under the pointer, and only while there is something to
        // send.** The disc is already at full alpha when it is live, so hover
        // cannot be more of the accent: it is a little white mixed into it,
        // which is the one direction left. Dimmed, it does nothing when
        // pressed, and a control that lights up and then ignores you is worse
        // than one that never lit up at all.
        let disc = live && hovering && !pressed
            ? Brand.accent.blended(withFraction: 0.16, of: .white) ?? Brand.accent
            : Brand.accent
        layer?.backgroundColor = disc.withAlphaComponent(fade).cgColor
        glyph.contentTintColor = Brand.onAccent.withAlphaComponent(live ? 1 : 0.55)
        setAccessibilityLabel(isStop ? "Stop" : "Ask")
    }

    /// Ours by name, for the reason `HoverButton` records: `trackingAreas` also
    /// holds whatever AppKit put there.
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

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
    /// **Two kinds of "there but not usable", and they are not one sentence.**
    /// A CLI that was never signed into is one command away, and naming that
    /// command is the whole value of this card. An endpoint that is not
    /// answering is a server to start or a URL to correct, and `refused` is
    /// what tells those apart without this card parsing prose meant for a
    /// settings row.
    ///
    /// The signed-out CLIs win when both kinds are present, because that is the
    /// one with a command in it.
    func show(_ statuses: [AgentStatus]) {
        isHidden = false
        let out = statuses.filter { $0.path != nil && $0.signedIn == false }
        guard !out.isEmpty else {
            heading.stringValue = "Ask needs an agent"
            say("Neither Claude Code nor Codex is installed, and no model endpoint "
                + "is set up. A CLI answers on a subscription you already have. An "
                + "endpoint can be a model running on this Mac, through Ollama, "
                + "which needs no account at all.\n\n"
                + "Agent settings has both.")
            return
        }
        let signedOut = out.filter { $0.backend.isCLI }
        guard signedOut.isEmpty else {
            heading.stringValue = signedOut.map(\.name).joined(separator: " and ")
                + (signedOut.count == 1 ? " is" : " are") + " installed but not signed in"
            say("Run " + signedOut.compactMap { status in
                    status.backend.signInCommand.map { "`\($0)`" }
                }.joined(separator: " or ")
                + " in a terminal, then check again.")
            return
        }
        // Only the endpoint is left, and it is configured and silent.
        let endpoint = out[0]
        heading.stringValue = "\(endpoint.name) is not answering"
        if endpoint.refused {
            say("It is there, and it refused the key. Settings › Ask is where to "
                + "change it.")
        } else {
            say("Nothing answered at `\(endpoint.path?.absoluteString ?? "the base URL")`. "
                + "Start the server, with `ollama serve` or whatever runs yours, then "
                + "check again.")
        }
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
///
/// A `ChipButton` and a closure, which is the whole class: four of these in a
/// row over a meeting were indistinguishable from four labels until one was
/// clicked, and the capsule that lights up under the pointer is shared with the
/// two controls under an answer rather than invented twice.
private final class StarterChip: ChipButton {
    private let onPress: () -> Void

    init(_ title: String, onPress: @escaping () -> Void) {
        self.onPress = onPress
        super.init(title)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    @objc private func fire() { onPress() }
}
