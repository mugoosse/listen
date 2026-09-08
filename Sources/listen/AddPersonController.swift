import AppKit

/// The one entry point for creating somebody before Listen has heard them.
///
/// A sheet rather than a popover: the name is durable library data, and a
/// popover disappearing because the window moved would turn a simple form into
/// a timing exercise. The form stays deliberately small. Notes, recordings and
/// summaries belong on the person page it opens after Save.
@MainActor
final class AddPersonController: NSWindowController, NSTextFieldDelegate {
    private let nameField = NSTextField(string: "")
    private let emailField = NSTextField(string: "")
    private let problem = NSTextField(wrappingLabelWithString: "")
    private let addButton = NSButton(title: "Add Person", target: nil, action: nil)
    private let onCreated: (Person) -> Void

    init(suggestedName: String = "", onCreated: @escaping (Person) -> Void) {
        self.onCreated = onCreated
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 270),
                            styleMask: [.titled, .closable], backing: .buffered,
                            defer: false)
        super.init(window: panel)
        panel.title = "Add Person"
        panel.isReleasedWhenClosed = false
        build(in: panel)
        nameField.stringValue = suggestedName
        validate()
    }

    required init?(coder: NSCoder) { fatalError("no nib") }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
        DispatchQueue.main.async { window.makeFirstResponder(self.nameField) }
    }

    private func build(in panel: NSPanel) {
        guard let root = panel.contentView else { return }

        let intro = NSTextField(wrappingLabelWithString:
            "Add someone now, then keep notes and recordings together on their page.")
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = .secondaryLabelColor

        nameField.placeholderString = "Name"
        nameField.delegate = self
        nameField.font = .systemFont(ofSize: 13)
        nameField.setAccessibilityLabel("Name")

        emailField.placeholderString = "Email (optional)"
        emailField.delegate = self
        emailField.font = .systemFont(ofSize: 13)
        emailField.setAccessibilityLabel("Email, optional")

        let nameLabel = fieldLabel("Name")
        let emailLabel = fieldLabel("Email")

        problem.font = .systemFont(ofSize: 11)
        problem.textColor = .systemRed
        problem.isHidden = true

        let privacy = NSTextField(wrappingLabelWithString:
            "Adding a person or note does not use an AI model. You choose if a summary is created later.")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .tertiaryLabelColor

        let fields = NSStackView(views: [nameLabel, nameField, emailLabel, emailField,
                                         problem, privacy])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6
        fields.setCustomSpacing(12, after: nameField)
        fields.setCustomSpacing(12, after: emailField)
        for view in [nameField, emailField, problem, privacy] as [NSView] {
            view.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        addButton.target = self
        addButton.action = #selector(addPerson)
        addButton.bezelStyle = .rounded
        addButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, addButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        for view in [intro, fields, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            intro.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            intro.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            fields.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 18),
            fields.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            fields.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
    }

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    func controlTextDidChange(_ obj: Notification) {
        problem.isHidden = true
        validate()
    }

    private func validate() {
        addButton.isEnabled = !nameField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func addPerson() {
        do {
            let person = try People.create(nameField.stringValue,
                                           email: emailField.stringValue)
            Task { @MainActor in CloudSyncHost.shared.syncSoon() }
            closeSheet()
            onCreated(person)
        } catch {
            problem.stringValue = error.localizedDescription
            problem.isHidden = false
        }
    }

    @objc private func cancel() { closeSheet() }

    private func closeSheet() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        else { window.close() }
    }
}
