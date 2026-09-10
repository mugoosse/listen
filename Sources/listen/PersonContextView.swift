import AppKit
import ListenKit

/// Plain sections in the person page's existing scrolling column. The identity
/// header stays put; the growing memory must not squeeze recordings offscreen.
@MainActor
final class PersonContextView: NSStackView, NSSearchFieldDelegate {
    private var person: String?
    private var memory: PersonMemory?
    private var lastProviderModel: (String, String)?
    private var problem: String?
    private var expanded: Set<String> = []
    private var lastHidden: String?
    private var loadTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private let searchField = NSSearchField()
    private var searchResult: ContextSearchResult?
    private var searchText = ""
    private var observer: NSObjectProtocol?
    private var showsDetails = false
    private var showsSources = false
    private var showsSearch = false
    private var showsHistory = false
    private var briefSheet: PersonBriefComposer?
    private var noteSheet: PersonNoteComposer?
    private var projectSheet: ContextProjectController?

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Find in summary"
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search this person’s summary")
        observer = NotificationCenter.default.addObserver(forName: PeopleMemory.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private var hasContent: Bool {
        !(memory?.summary.isEmpty ?? true)
            || !(memory?.facts.isEmpty ?? true)
            || !(memory?.relations.isEmpty ?? true)
    }

    func show(_ label: String) {
        guard label != person else { return }
        person = label; memory = nil; problem = nil; expanded = []; lastHidden = nil
        showsDetails = false; showsSources = false; showsSearch = false; showsHistory = false
        searchField.stringValue = ""; searchText = ""; searchResult = nil
        reload()
    }

    private func reload() {
        guard let person else { return }
        let query = searchText
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    let memory = try ContextRetrieval.displayPerson(person)
                    let search: ContextSearchResult? = query.isEmpty ? nil : try SemanticIndex.search(query, person: person, limit: 5)
                    let latest = PeopleMemory.validReceipts(try PeopleMemory.load()).filter { $0.source.people.contains(person) && $0.resolvedModel != nil }
                        .max { $0.processedAt < $1.processedAt }
                    return (memory, search, latest.map { ($0.backend, $0.resolvedModel!) })
                }.value
                guard !Task.isCancelled, self?.person == person else { return }
                self?.memory = result.0; self?.problem = nil
                self?.lastProviderModel = result.2
                if self?.searchText == query { self?.searchResult = result.1 }
                self?.render(); self?.renderSearchResults()
            } catch {
                guard !Task.isCancelled, self?.person == person else { return }
                self?.problem = error.localizedDescription; self?.render()
            }
        }
        render()
    }

    private func render() {
        // Keep the search field mounted while it owns the caret. Replacing it
        // on every streamed status event would throw away the user's selection.
        let editingSearch = window?.firstResponder === searchField.currentEditor()
            && searchField.currentEditor() != nil
        if editingSearch { return }
        for child in arrangedSubviews { removeArrangedSubview(child); child.removeFromSuperview() }
        let service = ContextService.shared
        let updating = service.isUpdating(person)
        let request = currentRequest()
        let waiting = request.map { ["pending", "running"].contains($0.state) } == true
        let heading = label("Summary", size: 16, weight: .semibold)
        let addNote = NSButton(title: "Add Note", target: self, action: #selector(addPersonNote))
        addNote.bezelStyle = .inline
        addNote.controlSize = .small
        addNote.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: nil)
        addNote.imagePosition = .imageLeading
        addNote.setAccessibilityLabel("Add a note about " + SpeakerName.display(person ?? "this person"))
        let title = updating ? "Stop" : ((memory?.failed ?? 0) > 0 ? "Retry" : (hasContent ? "Update" : "Create Summary"))
        let update = NSButton(title: title, target: self, action: #selector(updateNow))
        update.bezelStyle = .rounded
        update.controlSize = .small
        update.isEnabled = updating || ContextModel.chosen(cachedOnly: true)?.usable == true
        update.setAccessibilityLabel(updating ? "Stop summary update" : title + " for " + SpeakerName.display(person ?? "person"))
        let options = hasContent || waiting
            ? iconButton("ellipsis.circle", "Summary options", #selector(showOptions(_:)))
            : iconButton("gearshape", "People & Memory settings", #selector(openPeopleMemorySettings))
        let top = NSStackView(views: [heading, spacer(), addNote, update, options])
        top.orientation = .horizontal; top.alignment = .centerY; top.spacing = 8
        add(top)
        setCustomSpacing(16, after: top)
        if showsSearch {
            searchField.placeholderString = "Find in summary"
            add(searchField)
            renderSearchResults()
            return
        }
        if let problem {
            add(label("Couldn’t load this summary. " + problem, size: 12, color: .secondaryLabelColor))
        } else if let memory {
            if updating {
                let progress = NSProgressIndicator()
                progress.style = .spinning; progress.controlSize = .small
                progress.isIndeterminate = true; progress.startAnimation(nil)
                let status = label(service.status, size: 12, color: .secondaryLabelColor)
                status.setAccessibilityLabel("Summary update: " + service.status)
                let row = NSStackView(views: [progress, status])
                row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
                add(row)
            } else if let failure = memory.failure ?? (service.activePerson == person ? service.lastError : nil) {
                add(label("Couldn’t finish this summary", size: 13, weight: .medium))
                add(label(Self.friendlyFailure(failure), size: 12, color: .secondaryLabelColor))
            } else if !hasContent {
                add(label(memory.sources > 0
                    ? "No lasting details found in the selected sources."
                    : "Create a sourced summary from this person’s conversations and notes.", size: 13, color: .secondaryLabelColor))
            }
            if hasContent {
                if !memory.summary.isEmpty {
                    for sentence in memory.summary { add(label(sentence.text, size: 14)) }
                    let all = memory.facts + memory.relations
                    let evidence = memory.summary.flatMap { sentence in
                        sentence.claims.flatMap { id -> [MemoryEvidence] in
                            guard let item = all.first(where: { $0.id == id }) else { return [] }
                            return item.evidence + (item.changeEvidence ?? [])
                        }
                    }
                    let count = Set(evidence.map(\.source)).count
                    add(disclosure("\(count) source\(count == 1 ? "" : "s")", open: showsSources, #selector(toggleSources)))
                    if showsSources { sourceLinks(evidence) }
                } else {
                    // A useful preview while summary generation is pending.
                    for item in (memory.facts + memory.relations).filter({ !["historical", "retracted"].contains($0.status) }).prefix(2) {
                        add(label(item.value, size: 14))
                    }
                }
                if let updated = memory.updated {
                    add(label("Updated " + Self.date(updated), size: 11, color: .secondaryLabelColor))
                }
                let currentFacts = memory.facts.filter { !["historical", "retracted"].contains($0.status) }
                let currentRelations = memory.relations.filter { !["historical", "retracted"].contains($0.status) }
                let historical = (memory.facts + memory.relations).filter { ["historical", "retracted"].contains($0.status) }
                let count = currentFacts.count + currentRelations.count
                if count > 0 {
                    if let last = arrangedSubviews.last { setCustomSpacing(12, after: last) }
                    add(disclosure("Details (\(count))", open: showsDetails, #selector(toggleDetails)))
                    if showsDetails {
                        if !currentFacts.isEmpty {
                            for item in currentFacts { claim(item) }
                        }
                        if !currentRelations.isEmpty {
                            headingRow("Relationships")
                            for item in currentRelations { claim(item) }
                        }
                    }
                }
                if !historical.isEmpty {
                    add(disclosure("History (\(historical.count))", open: showsHistory, #selector(toggleHistory)))
                    if showsHistory { for item in historical { claim(item) } }
                }
            }
            if !updating, memory.pending > 0, memory.failed == 0, hasContent {
                add(label("\(memory.pendingSources ?? 1) more source\((memory.pendingSources ?? 1) == 1 ? "" : "s") to review", size: 11, color: .secondaryLabelColor))
            }
            if lastHidden != nil { add(button("Detail hidden · Undo", #selector(undoHide))) }
        } else { add(label("Loading summary…", size: 12, color: .secondaryLabelColor)) }

        if let request, ["pending", "running"].contains(request.state), !updating {
            // A request addressed to this Mac does not start while this Mac is
            // recording: `ContextService.refresh` returns on `isRecording`, so
            // every 30 second tick of a two hour call is a no-op. "Waiting for
            // this Mac to begin" is then a wait with no end and no reason, the
            // failure `MemoryPreferences.Plan` was written to avoid. Only this
            // Mac's own recording may be named, because another executor's is
            // invisible from here.
            let held = request.model.executor == ContextService.deviceID && Capture.shared.isRecording
            let message = held
                ? "Waiting until the current recording stops…"
                : (request.message ?? (request.state == "running"
                    ? "Creating this summary on your Mac…"
                    : "Waiting for this Mac to begin…"))
            let line = label(message, size: 12, color: .secondaryLabelColor)
            line.setAccessibilityLabel("Summary update: " + message)
            add(line)
        }
        if let chosen = ContextModel.chosen(cachedOnly: true) {
            let policy = person.flatMap { try? MemoryPreferences.policy(MemoryPreferences.personID($0, root: Library.root), root: Library.root) }
            let automaticModel = policy?.automatic == true ? policy?.model?.name : nil
            let model = updating ? (service.activeModel ?? ContextModel.configured) : (automaticModel ?? ContextModel.configured)
            let prefix = updating ? "Using " : (!hasContent ? "Will use " : (automaticModel == nil ? "Updates use " : "Automatic updates use "))
            let text = prefix + model
            let modelInfo = label(text, size: 11, color: .secondaryLabelColor)
            modelInfo.toolTip = chosen.needsNetwork ? "Selected conversation text is sent to this provider. Manage automatic updates in People & Memory." : "Summaries are generated by your model on this Mac."
            add(modelInfo)
            if !updating, ContextModel.model(chosen) == nil, let lastProviderModel, lastProviderModel.0 == chosen.key {
                add(label("Last used " + lastProviderModel.1, size: 11, color: .secondaryLabelColor))
            }
        } else {
            add(button("Choose a model in Settings…", #selector(openPeopleMemorySettings)))
        }

        if let person {
            let id = MemoryPreferences.personID(person, root: Library.root)
            let notes = Notes.all().filter { $0.aboutPersonID.map { MemoryPreferences.canonicalID($0, root: Library.root) } == id }
            if !notes.isEmpty {
                headingRow("Notes")
                for note in notes {
                    let title = label(note.title, size: 13)
                    let date = label(Self.date(note.created) + (note.excludedFromAI ? " · Excluded from AI" : ""), size: 11, color: .secondaryLabelColor)
                    let line = NSStackView(views: [title, spacer(), date]); line.orientation = .horizontal; line.spacing = 10
                    let row = HoverRow(content: line, target: self, action: #selector(openSource(_:)))
                    row.identifier = NSUserInterfaceItemIdentifier("note:" + note.slug)
                    add(row)
                }
            }
        }
    }

    private static func friendlyFailure(_ failure: String) -> String {
        if failure == "The person summary did not cite valid claims."
            || failure == "The model did not return the required context JSON. Retry the source." {
            return "The details were saved, but the final summary could not be verified. Try again."
        }
        if failure.hasPrefix("Context was not saved:") {
            return "The model returned details that could not be verified against the source. Try again. Your conversations are unchanged."
        }
        return failure
    }

    @objc private func toggleDetails() { showsDetails.toggle(); render() }
    @objc private func toggleHistory() { showsHistory.toggle(); render() }
    @objc private func toggleSources() { showsSources.toggle(); render() }
    @objc private func toggleSearch() {
        if showsSearch {
            window?.makeFirstResponder(nil)
            showsSearch = false; searchText = ""; searchField.stringValue = ""; searchTask?.cancel()
            render()
        } else {
            showsSearch = true; render(); window?.makeFirstResponder(searchField)
        }
    }

    private func disclosure(_ title: String, open: Bool, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline; b.isBordered = false; b.alignment = .left
        b.font = .systemFont(ofSize: 12, weight: .medium)
        b.image = NSImage(systemSymbolName: open ? "chevron.down" : "chevron.right", accessibilityDescription: "")
        b.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
        b.imagePosition = .imageLeading; b.imageHugsTitle = true
        b.setAccessibilityLabel(title + (open ? ", expanded" : ", collapsed"))
        return b
    }

    private func iconButton(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: action)
        b.bezelStyle = .inline; b.isBordered = false; b.contentTintColor = .secondaryLabelColor
        b.toolTip = title; b.setAccessibilityLabel(title)
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    private func claim(_ item: PersonMemory.Item) {
        let category = ContextPresentation.category(item.attribute, polarity: item.polarity ?? "positive")
            + (["historical", "retracted"].contains(item.status) ? " · Historical" : "")
            + (item.pinned == true ? " · Pinned" : "")
        let more = iconButton("ellipsis", "More options for " + category.lowercased(), #selector(claimMenu(_:)))
        more.identifier = NSUserInterfaceItemIdentifier(item.id)
        let metadata = NSStackView(views: [label(category, size: 11, color: .secondaryLabelColor), spacer(), more])
        metadata.orientation = .horizontal; metadata.alignment = .centerY; metadata.spacing = 8
        add(metadata)
        setCustomSpacing(2, after: metadata)
        let value: NSView
        if item.objectKind == "person" || item.objectKind == "project" {
            let name = item.objectKind == "person" ? SpeakerName.display(item.value) : item.value
            let text = NSTextField(labelWithString: name)
            text.font = .systemFont(ofSize: 13)
            text.lineBreakMode = .byTruncatingTail
            let row = HoverRow(content: text, target: self,
                action: item.objectKind == "project" ? #selector(openProject(_:)) : #selector(openPerson(_:)), inset: 0)
            row.identifier = NSUserInterfaceItemIdentifier(item.objectID ?? item.value)
            row.setAccessibilityElement(true); row.setAccessibilityRole(.button)
            row.setAccessibilityLabel("Open " + name)
            value = row
        } else {
            value = label(item.value, size: 13)
        }
        add(value)
        let qualifiers = ContextPresentation.qualifiers(modality: item.modality ?? "asserted", attribution: item.attribution ?? "direct")
        if !qualifiers.isEmpty { add(label(qualifiers.joined(separator: " · "), size: 11, color: .secondaryLabelColor)) }
        if item.corrected == true { add(label("Your correction", size: 11, color: .secondaryLabelColor)) }
        if item.status == "conflicted" { add(label("Sources disagree", size: 11, color: .secondaryLabelColor)) }
        if item.status == "needs_review" { add(label("Needs review · change evidence is no longer available", size: 11, color: .secondaryLabelColor)) }
        if let from = item.time?.from { add(label("From " + Self.date(from), size: 11, color: .secondaryLabelColor)) }
        if let to = item.time?.to { add(label("Ended " + Self.date(to), size: 11, color: .secondaryLabelColor)) }
        if expanded.contains(item.id) {
            for e in item.evidence {
                let by = e.speaker.map { SpeakerName.display($0) + ": " } ?? ""
                add(label(by + "“" + e.quote + "”", size: 12, color: .secondaryLabelColor))
                sourceLinks([e])
            }
            for evidence in item.changeEvidence ?? [] {
                add(label("Change recorded: “" + evidence.quote + "”", size: 12, color: .secondaryLabelColor))
                sourceLinks([evidence])
            }
        }
        setCustomSpacing(18, after: arrangedSubviews.last!)
    }

    private func sourceLinks(_ evidence: [MemoryEvidence]) {
        var seen: Set<String> = []
        for e in evidence where seen.insert(e.source).inserted {
            let title = NSTextField(labelWithString: e.title.isEmpty ? "Source" : e.title)
            title.font = .systemFont(ofSize: 13)
            title.lineBreakMode = .byTruncatingTail
            title.setContentHuggingPriority(.defaultLow, for: .horizontal)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let metadata = [e.date.isEmpty ? nil : Self.date(e.date),
                e.start.map { String(format: "%d:%02d", Int(max(0, $0)) / 60, Int(max(0, $0)) % 60) }]
                .compactMap { $0 }.joined(separator: " · ")
            let detail = NSTextField(labelWithString: metadata)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.setContentHuggingPriority(.required, for: .horizontal)
            let content = NSStackView(views: [title, detail])
            content.orientation = .horizontal; content.distribution = .fill; content.spacing = 8
            let row = HoverRow(content: content, target: self, action: #selector(openSource(_:)))
            row.identifier = NSUserInterfaceItemIdentifier(e.source)
            row.toolTip = e.quote
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.button)
            row.setAccessibilityLabel("Open " + title.stringValue + (metadata.isEmpty ? "" : ", " + metadata))
            add(row)
            setCustomSpacing(6, after: row)
        }
    }

    @objc private func updateNow() {
        if ContextService.shared.isUpdating(person) { ContextService.shared.stop() }
        else if let person, let window {
            Task {
                let sources = await Task.detached(priority: .userInitiated) {
                    ContextSources.all().filter { $0.extractable && $0.people.contains(person) && !$0.scoped(to: person).batches.isEmpty }
                }.value
                let sheet = PersonBriefComposer(person: person, sources: sources, updating: !(memory?.facts.isEmpty ?? true))
                briefSheet = sheet; sheet.present(from: window)
            }
        }
        render()
    }
    @objc private func addPersonNote() {
        guard let person, let window else { return }
        let sheet = PersonNoteComposer(person: person); noteSheet = sheet
        sheet.onSaved = { [weak self] in self?.reload(); ContextService.shared.sourcesChanged() }
        sheet.present(from: window)
    }
    private func setAutomatic(_ automatic: Bool) {
        guard let person else { return }
        do {
            try MemoryPreferences.automatic(automatic, person: MemoryPreferences.personID(person, root: Library.root), model: ContextService.modelChoice(), root: Library.root)
            if !automatic, ContextService.shared.isUpdating(person) { ContextService.shared.stop() }
            ContextService.shared.refresh(); reload()
        } catch { problem = error.localizedDescription; render() }
    }
    @objc private func toggleAutomatic(_ sender: NSMenuItem) { setAutomatic(sender.state != .on) }
    @objc private func cancelRequest() {
        guard let person else { return }
        let id = MemoryPreferences.personID(person, root: Library.root)
        do {
            for request in try MemoryPreferences.requests(root: Library.root) where request.personID == id && ["pending", "running"].contains(request.state) {
                try MemoryPreferences.cancel(request.id, root: Library.root)
            }
            if ContextService.shared.isUpdating(person) { ContextService.shared.stop() }
            reload()
        } catch { problem = error.localizedDescription; render() }
    }
    @objc private func openPeopleMemorySettings() { LibraryWindow.shared.showSettings(.peopleContext) }
    @objc private func showOptions(_ sender: NSButton) {
        let menu = NSMenu()
        if currentRequest().map({ ["pending", "running"].contains($0.state) }) == true {
            menu.addItem(Action("Cancel Summary Update", "xmark.circle") { [weak self] in self?.cancelRequest() })
            menu.addItem(.separator())
        }
        if hasContent {
            let search = NSMenuItem(title: showsSearch ? "Close Search" : "Search Summary…", action: #selector(toggleSearch), keyEquivalent: "")
            search.target = self; search.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            menu.addItem(search)
        }
        if hasContent, let person {
            let id = MemoryPreferences.personID(person, root: Library.root)
            let policy = try? MemoryPreferences.policy(id, root: Library.root)
            let automatic = NSMenuItem(title: "Keep Summary Updated", action: #selector(toggleAutomatic(_:)), keyEquivalent: "")
            automatic.target = self; automatic.state = policy?.automatic == true ? .on : .off
            menu.addItem(automatic)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(Action("People & Memory Settings…", "gearshape") { LibraryWindow.shared.showSettings(.peopleContext) })
        if hasContent, let person {
            menu.addItem(.separator())
            menu.addItem(Action("Delete Generated Summary…", "trash") { [weak self] in
                guard let self, let window = self.window else { return }
                let alert = NSAlert(); alert.messageText = "Delete this person’s generated summary?"
                alert.informativeText = "The summary, details and history are removed. Their notes and recordings stay. Automatic updates stop on all your devices."
                alert.addButton(withTitle: "Delete Summary"); alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { result in
                    guard result == .alertFirstButtonReturn else { return }
                    do {
                        try MemoryPreferences.deleteMemory(person: MemoryPreferences.personID(person, root: Library.root), root: Library.root)
                        if ContextService.shared.isUpdating(person) { ContextService.shared.stop() }
                        ContextService.shared.sourcesChanged(); self.reload()
                    } catch { self.problem = error.localizedDescription; self.render() }
                }
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }
    private func currentRequest() -> MemoryPreferences.Request? {
        guard let person else { return nil }
        let id = MemoryPreferences.personID(person, root: Library.root)
        return (try? MemoryPreferences.requests(root: Library.root))?.last(where: { $0.personID == id })
    }
    @objc private func toggleEvidence(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        if !expanded.insert(id).inserted { expanded.remove(id) }
        render()
    }
    @objc private func claimMenu(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        let menu = NSMenu()
        if let item = ((memory?.facts ?? []) + (memory?.relations ?? [])).first(where: { $0.id == id }) {
            let sourceCount = Set((item.evidence + (item.changeEvidence ?? [])).map(\.source)).count
            let sources = NSMenuItem(
                title: expanded.contains(id)
                    ? "Hide Sources"
                    : "Show \(sourceCount) Source\(sourceCount == 1 ? "" : "s")",
                action: #selector(toggleClaimEvidence(_:)), keyEquivalent: "")
            sources.target = self; sources.representedObject = id
            sources.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
            menu.addItem(sources)
            menu.addItem(.separator())
            for (title, action) in [("Correct Detail…", #selector(correctClaim(_:))),
                                     (item.pinned == true ? "Unpin Detail" : "Pin Detail", #selector(pinClaim(_:)))] {
                let option = NSMenuItem(title: title, action: action, keyEquivalent: "")
                option.target = self; option.representedObject = id; menu.addItem(option)
            }
            if item.corrected == true {
                let restore = NSMenuItem(title: "Use Source Wording", action: #selector(restoreWording(_:)), keyEquivalent: "")
                restore.target = self; restore.representedObject = id; menu.addItem(restore)
            }
            menu.addItem(.separator())
        }
        let hide = NSMenuItem(title: "Hide Detail", action: #selector(hideClaim(_:)), keyEquivalent: "")
        hide.target = self; hide.representedObject = id
        menu.addItem(hide)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func toggleClaimEvidence(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if !expanded.insert(id).inserted { expanded.remove(id) }
        render()
    }
    private func selectedClaim(_ sender: NSMenuItem) -> PersonMemory.Item? {
        guard let id = sender.representedObject as? String else { return nil }
        return ((memory?.facts ?? []) + (memory?.relations ?? [])).first { $0.id == id }
    }
    @objc private func pinClaim(_ sender: NSMenuItem) {
        guard let item = selectedClaim(sender) else { return }
        do { try ContextStore.override(id: item.id, pinned: item.pinned != true); reload() }
        catch { problem = error.localizedDescription; render() }
    }
    @objc private func restoreWording(_ sender: NSMenuItem) {
        guard let item = selectedClaim(sender) else { return }
        do { try ContextStore.override(id: item.id, replacement: ""); reload() }
        catch { problem = error.localizedDescription; render() }
    }
    @objc private func correctClaim(_ sender: NSMenuItem) {
        guard let item = selectedClaim(sender), let window else { return }
        let alert = NSAlert(); alert.messageText = "Correct Detail"
        alert.informativeText = "Your wording stays separate from what the source said. Keep it within 500 characters."
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        editor.isRichText = false; editor.font = .systemFont(ofSize: 13); editor.string = item.value
        editor.setAccessibilityLabel("Corrected detail")
        let scroll = NSScrollView(frame: editor.frame); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = editor; alert.accessoryView = scroll
        alert.beginSheetModal(for: window) { [weak self] result in
            guard result == .alertFirstButtonReturn else { return }
            do {
                guard !editor.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ContextProblem.message("The correction cannot be empty.")
                }
                try ContextStore.override(id: item.id, replacement: editor.string)
                self?.reload()
            } catch { self?.problem = error.localizedDescription; self?.render() }
        }
        alert.window.makeFirstResponder(editor)
    }
    @objc private func hideClaim(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        do { try PeopleMemory.dismiss(id); lastHidden = id; reload() }
        catch { problem = error.localizedDescription; render() }
    }
    @objc private func undoHide() {
        guard let id = lastHidden else { return }
        do {
            try ContextStore.override(id: id, hidden: false)
            lastHidden = nil; reload()
        } catch { problem = error.localizedDescription; render() }
    }
    @objc private func openSource(_ sender: NSView) {
        guard let id = sender.identifier?.rawValue else { return }
        if id.hasPrefix("rec:") { LibraryWindow.shared.reveal(String(id.dropFirst(4))) }
        else if id.hasPrefix("note:") { LibraryWindow.shared.open(note: String(id.dropFirst(5))) }
        else if id.hasPrefix("person:") { LibraryWindow.shared.showPerson(String(id.dropFirst(7))) }
    }
    @objc private func openPerson(_ sender: NSView) {
        guard let name = sender.identifier?.rawValue else { return }
        LibraryWindow.shared.showPerson((try? ContextRetrieval.resolve(name, kind: "person").name) ?? name)
    }
    @objc private func openProject(_ sender: NSView) {
        guard let name = sender.identifier?.rawValue, let window else { return }
        let controller = ContextProjectController(name: name)
        projectSheet = controller
        if let sheet = controller.window { window.beginSheet(sheet) { [weak self] _ in self?.projectSheet = nil } }
    }
    func controlTextDidChange(_ obj: Notification) {
        searchText = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResult = nil; searchTask?.cancel()
        guard !searchText.isEmpty else { renderSearchResults(); return }
        let query = searchText, person = person
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let result = try? await Task.detached(priority: .userInitiated) { try SemanticIndex.search(query, person: person, limit: 5) }.value
            guard !Task.isCancelled, self?.searchText == query else { return }
            self?.searchResult = result
            // Let a search result arrive without tearing down its editor.
            self?.renderSearchResults()
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) { render() }

    private func renderSearchResults() {
        guard let index = arrangedSubviews.firstIndex(of: searchField) else { return }
        for child in Array(arrangedSubviews.dropFirst(index + 1)) { removeArrangedSubview(child); child.removeFromSuperview() }
        if let result = searchResult, !searchText.isEmpty {
            if result.matches.isEmpty { add(label("No matching context yet.", size: 12, color: .secondaryLabelColor)) }
            for match in result.matches { add(label(String(match.text.prefix(500)), size: 12)); sourceLinks(match.evidence) }
        }
    }

    private func add(_ child: NSView) {
        addArrangedSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        child.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    private func headingRow(_ title: String) {
        if let last = arrangedSubviews.last { setCustomSpacing(18, after: last) }
        add(label(title, size: 13, weight: .semibold))
    }
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight); label.textColor = color
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline; b.font = .systemFont(ofSize: 11); b.alignment = .left
        b.isBordered = false
        b.lineBreakMode = .byTruncatingTail
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.linkColor,
        ])
        b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return b
    }
    private func spacer() -> NSView { let v = NSView(); v.setContentHuggingPriority(.defaultLow, for: .horizontal); return v }
    private static func date(_ text: String) -> String {
        guard let date = Timestamps.parse(text) else { return String(text.prefix(10)) }
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f.string(from: date)
    }
}

@MainActor
private final class ContextProjectController: NSWindowController {
    private let stack = NSStackView()
    init(name: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "Project"; panel.minSize = NSSize(width: 440, height: 320)
        let root = NSView(); panel.contentView = root
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = stack
        let done = NSButton(title: "Done", target: self, action: #selector(closeSheet))
        done.bezelStyle = .rounded; done.keyEquivalent = "\r"; done.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll); root.addSubview(done)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -12),
            done.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), done.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        line("Loading project…", size: 13)
        Task { [weak self] in
            do {
                let card = try await Task.detached(priority: .userInitiated) { try ContextRetrieval.card(name, kind: "project") }.value
                guard let self else { return }
                for view in self.stack.arrangedSubviews { self.stack.removeArrangedSubview(view); view.removeFromSuperview() }
                panel.title = card.name
                self.line(card.name, size: 22, weight: .semibold)
                for sentence in card.brief { self.line(sentence.text, size: 14) }
                for entry in card.entries where !["historical", "retracted"].contains(entry.status) {
                    self.line(entry.subjectName + " · " + ContextPresentation.category(entry.predicate, polarity: entry.polarity), size: 11, secondary: true)
                    self.line(entry.text, size: 13)
                    let qualifiers = ContextPresentation.qualifiers(modality: entry.modality, attribution: entry.attribution)
                    if !qualifiers.isEmpty { self.line(qualifiers.joined(separator: " · "), size: 11, secondary: true) }
                    if entry.status == "needs_review" { self.line("Needs review", size: 11, secondary: true) }
                    if entry.status == "conflicted" { self.line("Sources disagree", size: 11, secondary: true) }
                    if entry.corrected { self.line("Your correction", size: 11, secondary: true) }
                    for source in entry.evidence.prefix(2) {
                        let label = NSTextField(labelWithString: source.title)
                        label.font = .systemFont(ofSize: 12); label.lineBreakMode = .byTruncatingTail
                        let row = HoverRow(content: label, target: self, action: #selector(self.openSource(_:)))
                        row.identifier = NSUserInterfaceItemIdentifier(source.source); row.toolTip = source.quote
                        self.stack.addArrangedSubview(row)
                        row.widthAnchor.constraint(equalTo: self.stack.widthAnchor, constant: -48).isActive = true
                    }
                    if let last = self.stack.arrangedSubviews.last { self.stack.setCustomSpacing(22, after: last) }
                }
            } catch { self?.line(error.localizedDescription, size: 13) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func line(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, secondary: Bool = false) {
        let label = NSTextField(wrappingLabelWithString: text); label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor; label.isSelectable = true
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
    }
    @objc private func closeSheet() { if let window { window.sheetParent?.endSheet(window) } }
    @objc private func openSource(_ sender: NSView) {
        guard let id = sender.identifier?.rawValue else { return }
        closeSheet()
        if id.hasPrefix("rec:") { LibraryWindow.shared.reveal(String(id.dropFirst(4))) }
        else if id.hasPrefix("note:") { LibraryWindow.shared.open(note: String(id.dropFirst(5))) }
    }
}
