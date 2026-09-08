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
    private var update: NSButton?
    private var chooseModel: NSButton?
    private var observer: NSObjectProtocol?
    private let budget = NSPopUpButton()
    private var usage: NSTextField?
    private let searchModel = NSPopUpButton()
    private var searchStatus: NSTextField?
    private var downloadButton: NSButton?
    private var downloadTask: Task<Void, Never>?

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
        note("Only people you enable on their own page are updated. New people start with memory off. Turning this off pauses automatic work on this Mac.")

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

    override func refresh() {
        guard isViewLoaded else { return }
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
        if let choice = ContextService.modelChoice() {
            try? MemoryPreferences.advertise(choice, root: Library.root)
        }
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
