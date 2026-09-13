import AppKit
import ListenKit

/// Generation controls live in Settings; a person's page is for reading.
@MainActor
final class PeopleContextPane: Pane {
    private let automatic = NSSwitch()
    private var provider: NSTextField?
    private var privacy: NSTextField?
    private var activity: NSTextField?
    private var detail: NSTextField?
    /// Corrections an agent has proposed and nobody has answered.
    ///
    /// **Its own field rather than another branch of the activity line.** That
    /// line is one string chosen by an if/else chain, so a count added to it
    /// would be hidden behind "Daily limit reached" or "Updates paused" on
    /// exactly the days somebody is most likely to have stopped reading the
    /// page. A worklist nobody is shown is the failure this row exists to
    /// avoid, so it does not compete for a slot.
    private var suggested: NSTextField?
    private var update: NSButton?
    private var chooseModel: NSButton?
    private var observer: NSObjectProtocol?
    private let budget = NSPopUpButton()
    private var usage: NSTextField?
    private let searchModel = NSPopUpButton()
    private var searchStatus: NSTextField?
    private var downloadButton: NSButton?
    private var downloadTask: Task<Void, Never>?
    /// The roster, and what is drawn from it.
    ///
    /// **Rebuilt only when it changes shape.** `refresh()` runs on every
    /// `PeopleMemory.changed`, which the sweep posts on every tick, and
    /// tearing down thirty-four rows under the pointer once a pass is how a
    /// checkbox stops being clickable. `rosterKey` is what makes that a
    /// comparison rather than a rebuild.
    private let enrolSwitch = NSSwitch()
    private var rosterList: NSStackView?
    private var rosterSummary: NSTextField?
    private var rosterWaiting: NSTextField?
    private var rosterRows: [ContextEnrolment.Roster.Row] = []
    private var catchUp: NSButton?
    private var catchUpNote: NSTextField?
    private var rosterKey = ""
    private var loadingRoster = false

    override func build() {
        let introduction = note("Remember the people in your conversations. Listen builds a summary with key details and relationships, each linked to its source.")
        introduction.font = .systemFont(ofSize: 13)
        introduction.textColor = .labelColor
        separator()

        let title = NSTextField(labelWithString: "Allow automatic updates")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        automatic.target = self
        automatic.action = #selector(toggleAutomatic)
        automatic.setAccessibilityLabel("Automatic person summaries")
        let enableRow = row([title, space, automatic])
        widthCapped(enableRow)
        note("Turning this off pauses automatic work on this Mac. People you have turned on stay on, and manual updates from a person's page still work.")

        separator()
        heading("Who is remembered")
        let enrolTitle = NSTextField(labelWithString: "Remember new people automatically")
        enrolTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let enrolSpace = NSView()
        enrolSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        enrolSwitch.target = self
        enrolSwitch.action = #selector(toggleEnrol)
        enrolSwitch.setAccessibilityLabel("Remember new people automatically")
        widthCapped(row([enrolTitle, enrolSpace, enrolSwitch]))
        note("Everybody named in a conversation gets a summary unless you turn them off here. Reading happens in the background, a few sources at a time, and it never starts while you are recording.")
        rosterSummary = note("")
        rosterWaiting = note("")
        // Raw buttons rather than the `button` helper, like `DictionaryPane`'s
        // bar: the helper adds to `stack` and `row` then re-parents them out
        // of it, which works and reads like a mistake.
        let catchUpButton = NSButton(title: "Read Everything Now", target: self,
                                     action: #selector(toggleCatchUp))
        catchUp = catchUpButton
        let everyone = row([
            NSButton(title: "Turn On for Everyone", target: self, action: #selector(enableEveryone)),
            NSButton(title: "Turn Off for Everyone", target: self, action: #selector(disableEveryone)),
            catchUpButton,
        ])
        widthCapped(everyone)
        // The daily limit is a pace, and this is the way past it for somebody
        // who would rather wait once than wait a fortnight. It says what it
        // will spend before it spends it, because that is a provider bill.
        catchUpNote = note("")
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        stack.addArrangedSubview(list)
        rosterList = list

        separator()
        heading("Summary model")
        chooseModel = button("Choose Provider & Model") { [weak self] in self?.pickModel() }
        chooseModel?.font = .systemFont(ofSize: 13)
        chooseModel?.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "")
        chooseModel?.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        chooseModel?.imagePosition = .imageRight
        chooseModel?.setAccessibilityLabel("Choose provider and model")
        provider = note("")
        button("Provider Settings…") { LibraryWindow.shared.showSettings(.agent) }
        note("Follow Ask, or choose a separate model for summaries. Each update keeps its provider and model until it finishes.")
        privacy = note("")

        separator()
        heading("Automatic work limit")
        budget.addItems(withTitles: ["10 requests per day", "40 requests per day", "100 requests per day", "250 requests per day"])
        budget.target = self; budget.action = #selector(changeBudget)
        budget.setAccessibilityLabel("Daily automatic memory request limit")
        widthCapped(row([budget]))
        note("Includes reading, checking and summarising. Requests stop at this limit and resume the next day. Manual updates remain available.")
        usage = note("")

        separator()
        heading("Activity")
        activity = note("")
        activity?.font = .systemFont(ofSize: 13)
        activity?.textColor = .labelColor
        detail = note("")
        suggested = note("")
        suggested?.textColor = .labelColor
        update = button("Check for Updates") { [weak self] in
            let service = ContextService.shared
            if service.isGenerating {
                service.stop()
                self?.refresh()
            } else {
                self?.syncWithPhone()
            }
        }

        separator()
        heading("Search on this Mac")
        searchModel.addItems(withTitles: ["Apple · Included with macOS", "Multilingual · E5 Small"])
        searchModel.target = self; searchModel.action = #selector(changeSearchModel)
        searchModel.setAccessibilityLabel("Local search model")
        widthCapped(row([searchModel]))
        searchStatus = note("")
        downloadButton = button("Download Multilingual Search") { [weak self] in self?.downloadSearch() }
        note("Search runs on this Mac. Apple uses the languages available in macOS. Multilingual search adds a local model for finding the same idea across languages. Keyword search stays available.")
        note("Summaries, notes and your memory choices sync through your encrypted library. iPhone summary requests wait for their selected Mac provider. Search vectors stay on each device.")

        observer = NotificationCenter.default.addObserver(forName: PeopleMemory.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        AgentCLI.warmUp { [weak self] in self?.refresh() }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    /// "Marcia", "Marcia and Ion", "Marcia, Ion and Edgar".
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    // MARK: - The roster

    /// Read the library off the main thread, then draw whatever came back.
    ///
    /// `ContextEnrolment.roster` reads every recording's turns to work out who
    /// is in the library, which is not something to do on the main thread of a
    /// pane that refreshes on every sweep tick. One at a time: a second request
    /// arriving while the first is out would answer with the same numbers.
    private func loadRoster() {
        guard !loadingRoster else { return }
        loadingRoster = true
        Task.detached(priority: .userInitiated) {
            let roster = ContextEnrolment.roster()
            await MainActor.run { [weak self] in
                self?.loadingRoster = false
                self?.apply(roster)
            }
        }
    }

    private func apply(_ roster: ContextEnrolment.Roster) {
        guard isViewLoaded else { return }
        enrolSwitch.state = roster.enrolsNewPeople ? .on : .off
        rosterRows = roster.rows

        let people = roster.rows.count
        var summary = "\(roster.enrolled) of \(people) \(people == 1 ? "person" : "people") remembered."
        if roster.backlog > 0 {
            let daily = max(1, Settings.contextDailyRequests)
            let days = max(1, (roster.backlog + daily - 1) / daily)
            summary += " \(roster.backlog) conversations left to read, about \(days) day\(days == 1 ? "" : "s") at \(daily) requests a day."
        } else if roster.enrolled > 0 {
            summary += " Everything they are in has been read."
        }
        rosterSummary?.stringValue = summary

        let running = ContextService.shared.catchingUp
        catchUp?.title = running ? "Stop Reading" : "Read Everything Now"
        catchUp?.isEnabled = running || roster.backlog > 0
        if roster.backlog == 0 {
            catchUpNote?.stringValue = ""
        } else if running {
            catchUpNote?.stringValue = "Reading everything now, ignoring the daily limit. It keeps going while Listen is open."
        } else {
            // Priced from this Mac's own recorded requests rather than a
            // guess. `ContextBudget` writes one usage row per provider call
            // with what it actually cost, so the estimate is this library on
            // this model, and it says so when there is nothing to go on yet.
            let spent = (try? ContextBudget.recent()) ?? []
            let priced = spent.compactMap(\.apiEquivalentUSD).filter { $0 > 0 }
            if priced.count >= 5 {
                let each = priced.sorted()[priced.count / 2]
                catchUpNote?.stringValue = String(
                    format: "Read all %d now, past the daily limit. About $%.0f at this library's measured cost per request.",
                    roster.backlog, each * Double(roster.backlog))
            } else {
                catchUpNote?.stringValue = "Read all \(roster.backlog) now, past the daily limit. Your provider's usage charges apply."
            }
        }
        catchUpNote?.isHidden = catchUpNote?.stringValue.isEmpty ?? true
        // The one number on this pane that names something to go and do.
        rosterWaiting?.stringValue = roster.waitingForNames == 0 ? ""
            : "\(roster.waitingForNames) recording\(roster.waitingForNames == 1 ? " is" : "s are") waiting for speaker names. Nothing can be read from them until somebody says who is talking."
        rosterWaiting?.isHidden = roster.waitingForNames == 0

        // Shape, not content: the state words change every pass and must not
        // cost a rebuild. See `rosterKey`.
        let key = roster.rows.map { "\($0.id):\($0.automatic.map(String.init) ?? "-")" }.joined(separator: "|")
        if key != rosterKey { rosterKey = key; rebuildRoster() } else { restyleRoster() }
        resizeDocument()
    }

    private func rebuildRoster() {
        guard let list = rosterList else { return }
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        if rosterRows.isEmpty {
            let empty = NSTextField(labelWithString: "Nobody is named in this library yet.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            list.addArrangedSubview(empty)
            return
        }
        for (index, person) in rosterRows.enumerated() {
            // Added first, then widened: `widthCapped` constrains against the
            // pane's stack, and two views with no common ancestor yet is an
            // exception rather than a layout that sorts itself out.
            let view = rosterRow(person, index: index)
            list.addArrangedSubview(view)
            widthCapped(view)
        }
    }

    private func rosterRow(_ person: ContextEnrolment.Roster.Row, index: Int) -> NSView {
        let name = NSTextField(labelWithString: person.display + (person.isYou ? " (you)" : ""))
        name.font = .systemFont(ofSize: 12, weight: person.isYou ? .medium : .regular)
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = person.summary

        let state = NSTextField(labelWithString: Self.state(person))
        state.font = .systemFont(ofSize: 11)
        state.textColor = person.automatic == true ? .secondaryLabelColor : .tertiaryLabelColor
        state.identifier = NSUserInterfaceItemIdentifier("state:" + person.id)
        state.alignment = .right

        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleOne(_:)))
        box.state = person.automatic == true ? .on : .off
        box.tag = index
        box.setAccessibilityLabel("Remember " + person.display)

        // A spacer so every checkbox lands in the same column. Without it each
        // row is only as wide as its own name and the controls come out in a
        // ragged diagonal that reads as thirty-four unrelated switches.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let view = NSStackView(views: [name, spacer, state, box])
        view.orientation = .horizontal
        view.spacing = 8
        view.alignment = .centerY
        view.distribution = .fill
        return view
    }

    /// The words beside a name. Ordered by what somebody would act on first.
    private static func state(_ person: ContextEnrolment.Roster.Row) -> String {
        guard person.automatic == true else { return person.automatic == nil ? "Not asked" : "Off" }
        if person.failed > 0 { return "Needs another attempt" }
        if person.pending > 0 {
            return person.claims > 0 ? "\(person.claims) details · \(person.pending) to read"
                                     : "\(person.pending) to read"
        }
        if person.claims > 0 { return "\(person.claims) detail\(person.claims == 1 ? "" : "s")" }
        return "Nothing found yet"
    }

    private func restyleRoster() {
        guard let list = rosterList else { return }
        for (index, view) in list.arrangedSubviews.enumerated() where index < rosterRows.count {
            let person = rosterRows[index]
            for field in view.subviews.compactMap({ $0 as? NSTextField })
            where field.identifier?.rawValue == "state:" + person.id {
                field.stringValue = Self.state(person)
            }
        }
    }

    @objc private func toggleCatchUp() {
        let service = ContextService.shared
        service.catchingUp.toggle()
        if service.catchingUp { service.refresh(manual: true) }
        refresh()
    }

    @objc private func toggleEnrol() {
        let on = enrolSwitch.state == .on
        try? MemoryPreferences.enrolNewPeople(on, root: Library.root)
        if on { enrolEverybodyNow() } else { loadRoster() }
    }

    @objc private func enableEveryone() {
        enrolSwitch.state = .on
        try? MemoryPreferences.enrolNewPeople(true, root: Library.root)
        // Everybody, including anybody who was explicitly turned off: this
        // button says "everyone" and a switch that leaves some of them alone
        // would be a switch that lies.
        setAll(true)
    }

    @objc private func disableEveryone() {
        enrolSwitch.state = .off
        try? MemoryPreferences.enrolNewPeople(false, root: Library.root)
        setAll(false)
    }

    /// Write an explicit register for every person on the roster.
    private func setAll(_ on: Bool) {
        let rows = rosterRows
        let model = ContextService.modelChoice()
        Task.detached(priority: .userInitiated) {
            for person in rows {
                try? MemoryPreferences.automatic(on, person: person.id, model: model, root: Library.root)
            }
            await MainActor.run {
                ContextService.shared.sourcesChanged()
                NotificationCenter.default.post(name: PeopleMemory.changed, object: nil)
            }
        }
    }

    /// Give everybody who has never been asked a register, now rather than on
    /// the next sweep tick, so the numbers on this pane answer the switch.
    private func enrolEverybodyNow() {
        let model = ContextService.modelChoice()
        Task.detached(priority: .userInitiated) {
            ContextEnrolment.sync(ContextSources.all(), model: model)
            await MainActor.run {
                ContextService.shared.sourcesChanged()
                NotificationCenter.default.post(name: PeopleMemory.changed, object: nil)
            }
        }
    }

    @objc private func toggleOne(_ sender: NSButton) {
        guard sender.tag < rosterRows.count else { return }
        let person = rosterRows[sender.tag]
        let on = sender.state == .on
        do {
            try MemoryPreferences.automatic(on, person: person.id, model: ContextService.modelChoice(), root: Library.root)
            ContextService.shared.sourcesChanged()
            loadRoster()
        } catch {
            sender.state = on ? .off : .on
            let alert = NSAlert()
            alert.messageText = "Couldn’t change this person"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    override func refresh() {
        guard isViewLoaded else { return }
        loadRoster()
        let service = ContextService.shared
        automatic.state = Settings.peopleContextEnabled ? .on : .off
        searchModel.selectItem(at: Settings.multilingualSearch ? 1 : 0)
        searchModel.item(at: 1)?.isEnabled = MultilingualEmbedding.available
        searchModel.isEnabled = downloadTask == nil
        downloadButton?.isHidden = MultilingualEmbedding.available
        downloadButton?.isEnabled = downloadTask == nil
        if downloadTask == nil {
            searchStatus?.stringValue = MultilingualEmbedding.available
                ? "Multilingual model downloaded. All search text stays on this Mac."
                : "Multilingual search needs a one-time model download of about 500 MB."
        }
        let chosen = ContextModel.chosen(cachedOnly: true)
        chooseModel?.isEnabled = (AgentCLI.cached ?? []).contains(where: { $0.usable })
        if let chosen {
            let selected = ContextModel.model(chosen)
            let title = chosen.name + " · " + ContextModel.name(chosen, model: selected)
            chooseModel?.title = title
            chooseModel?.setAccessibilityLabel("Provider and model: " + title)
            provider?.stringValue = Settings.contextModelChoice == nil
                ? "Following your Ask selection."
                : "Used for summaries instead of your Ask selection."
            privacy?.stringValue = chosen.needsNetwork
                ? "Selected conversation text is sent to \(chosen.name) to generate summaries. Your existing subscription or provider pricing applies."
                : "Conversation text is processed by your model on this Mac."
        } else {
            chooseModel?.title = AgentCLI.cached == nil ? "Looking for your model…" : "Choose Provider & Model"
            provider?.stringValue = "Choose a provider and model in Ask to get started."
            privacy?.stringValue = "No conversation text is sent until you start an update."
        }
        if service.isGenerating {
            activity?.stringValue = service.status
            detail?.stringValue = service.activeModel.map { "Using " + $0 } ?? "Preparing the local search index."
        } else if service.budgetLimited {
            activity?.stringValue = "Daily limit reached"
            detail?.stringValue = "Automatic updates resume tomorrow. You can still update a summary manually."
        } else if let error = service.lastError {
            activity?.stringValue = "The last update needs attention"
            detail?.stringValue = error
        } else if !Settings.askEnabled {
            activity?.stringValue = "Ask is off"
            detail?.stringValue = "Turn on Ask to enable automatic updates. You can still update a summary manually with a configured model."
        } else if !Settings.peopleContextEnabled {
            activity?.stringValue = "Automatic updates are off"
            detail?.stringValue = "Create a summary from a person’s page and choose whether to keep it up to date."
        } else if service.isPaused {
            activity?.stringValue = "Updates paused"
            detail?.stringValue = "Choose Resume Updates to continue."
        } else if !Settings.cloudSyncApplies {
            activity?.stringValue = "iPhone requests need Sync"
            detail?.stringValue = "Turn on Sync to share this model with your iPhone and receive its summary requests."
        } else {
            activity?.stringValue = "This Mac is ready"
            detail?.stringValue = service.status == "More conversations are waiting."
                ? "Earlier conversations will be processed in the background while Listen is open."
                : "Leave Listen open. Summary requests from your iPhone will sync here and run automatically."
        }
        detail?.isHidden = detail?.stringValue.isEmpty ?? true

        // Named rather than counted. "3 waiting" sends somebody hunting through
        // the roster; the names say which pages to open, which is the whole job
        // of this row. Accepting one happens beside the claim and its evidence,
        // on the person's own page, and never here.
        let waiting = ContextSuggestions.pending()
        var people: [String] = []
        for one in waiting where !people.contains(SpeakerName.display(one.entityName)) {
            people.append(SpeakerName.display(one.entityName))
        }
        suggested?.stringValue = waiting.isEmpty ? "" :
            "\(waiting.count) suggested correction\(waiting.count == 1 ? "" : "s") on "
            + Self.list(people) + ". Open "
            + (people.count == 1 ? "that page" : "those pages") + " to accept or dismiss."
        suggested?.isHidden = waiting.isEmpty
        let limits = [10, 40, 100, 250]
        if let index = limits.firstIndex(of: Settings.contextDailyRequests) { budget.selectItem(at: index) }
        if let today = try? ContextBudget.today() {
            let count = today.filter(\.automatic).count
            let tokens = today.compactMap { item in item.promptTokens.flatMap { input in item.completionTokens.map { input + $0 } } }
            usage?.stringValue = "Today: \(count) of \(Settings.contextDailyRequests) automatic requests. "
                + (tokens.isEmpty ? "Token usage not reported by the provider." : "\(tokens.reduce(0, +).formatted()) reported tokens\(tokens.count < today.count ? " (some requests did not report usage)" : "").")
        }
        update?.title = service.isGenerating ? "Stop Update" : (Settings.cloudSyncApplies ? "Sync with iPhone" : "Check Now")
        update?.isEnabled = service.isGenerating || chosen?.usable == true
        view.needsLayout = true
    }

    @objc private func toggleAutomatic() {
        ContextService.shared.setAutomatic(automatic.state == .on)
        refresh()
    }

    private func pickModel() {
        guard let chooseModel else { return }
        AgentModelMenu.present(from: chooseModel, background: true) { [weak self] in
            self?.refresh()
            NotificationCenter.default.post(name: PeopleMemory.changed, object: nil)
        }
    }
    private func syncWithPhone() {
        // The pass below publishes this Mac's offer with its heartbeat, so
        // there is nothing to write here first.
        update?.isEnabled = false
        activity?.stringValue = Settings.cloudSyncApplies ? "Syncing with iPhone…" : "Checking for summary updates…"
        detail?.stringValue = ""
        Task { [weak self] in
            if Settings.cloudSyncApplies { _ = await CloudSyncHost.shared.syncNow() }
            ContextService.shared.refresh(manual: true)
            self?.refresh()
        }
    }
    @objc private func changeBudget() {
        Settings.contextDailyRequests = [10, 40, 100, 250][max(0, budget.indexOfSelectedItem)]
        refresh()
    }
    private func downloadSearch() {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            do {
                try await MultilingualEmbedding.download { message in
                    Task { @MainActor [weak self] in self?.searchStatus?.stringValue = message }
                }
                self?.downloadTask = nil
                self?.refresh()
            } catch {
                self?.downloadTask = nil
                self?.refresh()
                self?.searchStatus?.stringValue = error.localizedDescription
            }
        }
        refresh()
    }
    @objc private func changeSearchModel() {
        Settings.multilingualSearch = searchModel.indexOfSelectedItem == 1
        ContextService.shared.refresh()
        refresh()
    }
}
