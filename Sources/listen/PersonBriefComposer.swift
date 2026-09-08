import AppKit
import ListenKit

/// The explicit source and model boundary shared by first generation and update.
@MainActor
final class PersonBriefComposer: NSWindowController {
    private final class SourceList: NSStackView { override var isFlipped: Bool { true } }
    private let person: String
    private let sources: [ContextSource]
    private var choices: [NSButton] = []
    private let model = NSButton(title: "Choose Provider & Model", target: nil, action: nil)
    private let automatic = NSButton(checkboxWithTitle: "Keep up to date for this person", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let generate = NSButton(title: "Create Summary", target: nil, action: nil)

    init(person: String, sources: [ContextSource], updating: Bool) {
        self.person = person; self.sources = sources
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = (updating ? "Update summary for " : "Create summary for ") + SpeakerName.display(person)
        let column = NSStackView(); column.orientation = .vertical; column.alignment = .leading; column.spacing = 16
        column.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24); column.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(column)
        if let content = panel.contentView { NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor), column.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            column.topAnchor.constraint(equalTo: content.topAnchor), column.bottomAnchor.constraint(equalTo: content.bottomAnchor)]) }
        let title = NSTextField(labelWithString: panel.title); title.font = .systemFont(ofSize: 18, weight: .semibold); column.addArrangedSubview(title)
        model.bezelStyle = .rounded; model.target = self; model.action = #selector(chooseModel)
        column.addArrangedSubview(model)
        let caption = NSTextField(wrappingLabelWithString: "Choose the sources to use. Only passages by or about this person are read; other participants won’t receive summaries.")
        caption.font = .systemFont(ofSize: 12); caption.textColor = .secondaryLabelColor; caption.preferredMaxLayoutWidth = 530
        column.addArrangedSubview(caption)
        let list = SourceList(); list.orientation = .vertical; list.alignment = .leading; list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        list.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.documentView = list; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let id = MemoryPreferences.personID(person, root: Library.root)
        let policy = try? MemoryPreferences.policy(id, root: Library.root)
        for source in sources {
            let item = NSButton(checkboxWithTitle: source.title + (source.date.isEmpty ? "" : " · " + String(source.date.prefix(10))), target: self, action: #selector(refresh))
            item.state = policy?.knownSources.contains(source.id) != true || policy?.sources.contains(source.id) == true ? .on : .off
            item.lineBreakMode = .byTruncatingTail; item.toolTip = source.title
            list.addArrangedSubview(item); choices.append(item)
            item.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -16).isActive = true
        }
        automatic.state = policy?.automatic == true ? .on : .off
        column.addArrangedSubview(automatic)
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.preferredMaxLayoutWidth = 530
        column.addArrangedSubview(status)
        generate.title = updating ? "Update Summary" : "Create Summary"
        generate.bezelStyle = .rounded; generate.target = self; generate.action = #selector(start); generate.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(dismiss)); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        let space = NSView(); space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [space, cancel, generate]); actions.orientation = .horizontal; actions.spacing = 8
        column.addArrangedSubview(actions); actions.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present(from parent: NSWindow) { if let window { parent.beginSheet(window) } }
    @objc private func chooseModel() {
        AgentModelMenu.present(from: model, background: true) { [weak self] in self?.refresh() }
    }
    @objc private func refresh() {
        model.title = ContextService.modelChoice()?.name ?? "Choose Provider & Model"
        let count = choices.filter { $0.state == .on }.count
        generate.isEnabled = count > 0 && ContextService.modelChoice() != nil
        let remote = ContextModel.chosen(cachedOnly: true)?.needsNetwork == true
        status.stringValue = "\(count) source\(count == 1 ? "" : "s") selected. " + (remote
            ? "Selected text and previously saved details will be sent to this provider. Your provider’s usage charges apply."
            : "Selected text will be processed by your model on this Mac.")
    }
    @objc private func start() {
        guard let choice = ContextService.modelChoice() else { return }
        do {
            let id = MemoryPreferences.personID(person, root: Library.root)
            let selected = Set(zip(sources, choices).filter { $0.1.state == .on }.map { $0.0.id })
            try MemoryPreferences.associate(person, id: id, root: Library.root)
            try MemoryPreferences.select(selected, known: Set(sources.map(\.id)), person: id, root: Library.root)
            try MemoryPreferences.automatic(automatic.state == .on, person: id, model: choice, root: Library.root)
            try MemoryPreferences.request(person: id, name: person, sources: selected, model: choice, root: Library.root)
            ContextService.shared.refresh(manual: true)
            NotificationCenter.default.post(name: PeopleMemory.changed, object: nil)
            dismiss()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func dismiss() { if let window { window.sheetParent?.endSheet(window); window.orderOut(nil) } }
}
