import AppKit

/// The stepped first-run window.
///
/// Three rules here are load-bearing and were each a shipped bug in Speak.
/// Read them before changing anything in this file.
///
/// 1. **Setup downloads nothing on its own.** The model step selects nothing
///    until the user acts, and the primary button *is* the consent: it reads
///    "Download Parakeet v2 (2.47 GB)". Starting a download without a press
///    means everyone who wanted a different model pays for one they were about
///    to replace, and on a metered connection the choice is moot by the time
///    they reach it.
/// 2. **`updateControls()` must never call `render()`.** `render()` ends by
///    calling `updateControls()`, so if that can call back the two recurse
///    until the stack dies. In Speak this only reproduced on machines without
///    a cached model, which is every new user. Re-rendering here is driven by
///    `structuralKey()`, a comparison of state rather than a scan of rendered
///    text, and the elapsed-time line is deliberately excluded from that key
///    and updated in place: including it would rebuild the body every second
///    for the length of a download, replacing the radio buttons under the
///    cursor of somebody trying to click one.
/// 3. **The window floats and re-activates after each permission prompt.** A
///    window behind a system dialog is unreachable, and the dialog is modal to
///    the system rather than to us.
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    static let shared = Onboarding()

    enum Step: Int, CaseIterable {
        case welcome, microphone, systemAudio, model, done
    }

    private var window: NSWindow?
    private var step: Step = .welcome
    private var body: NSStackView!
    private var titleLabel: NSTextField!
    private var primary: NSButton!
    private var secondary: NSButton!
    private var lastKey = ""
    private var poll: Timer?

    func show() {
        if window == nil { build() }
        render()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Listen"
        w.center()
        w.isReleasedWhenClosed = false
        // Floating, so a system permission dialog cannot bury it.
        w.level = .floating
        w.delegate = self

        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12

        primary = NSButton(title: "Continue", target: self, action: #selector(next))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        secondary = NSButton(title: "Skip", target: self, action: #selector(skip))
        secondary.bezelStyle = .rounded

        let buttons = NSStackView(views: [secondary, primary])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let content = NSView()
        for v in [titleLabel, body, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        w.contentView = content
        window = w

        // Permissions land asynchronously and there is no notification for
        // them, so the step polls rather than trusting the last answer.
        poll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateControls() }
        }
    }

    /// Everything that decides what the body looks like.
    ///
    /// Compared as a string rather than scanning the rendered labels, so
    /// `updateControls` can decide whether a re-render is needed without ever
    /// calling `render` speculatively.
    private func structuralKey() -> String {
        [
            String(step.rawValue),
            String(Permissions.microphone),
            String(Permissions.systemAudio),
            Settings.modelChosen ? Settings.model.id : "none",
            String(Settings.model.isDownloaded),
        ].joined(separator: "|")
    }

    private func render() {
        lastKey = structuralKey()
        for view in body.arrangedSubviews { view.removeFromSuperview() }

        switch step {
        case .welcome:
            titleLabel.stringValue = "Listen"
            paragraph("Listen records your meetings, writes them down, and works out "
                      + "who said what. All of it happens on this Mac.")
            paragraph("Nothing is uploaded. The only time Listen uses the network is to "
                      + "download the speech model once, and to check for updates.")

        case .microphone:
            titleLabel.stringValue = "Your microphone"
            paragraph("Listen records your own voice on its own track, separate from "
                      + "everyone else's. That separation is what makes it reliable at "
                      + "telling you apart from the other people in the call.")
            status(Permissions.microphone, "Microphone access granted",
                   Permissions.microphoneDenied
                     ? "Denied. Open System Settings to change it."
                     : "Not granted yet")

        case .systemAudio:
            titleLabel.stringValue = "The other side of the call"
            paragraph("Listen captures what your Mac is playing with a Core Audio "
                      + "process tap. That asks for audio recording, not screen "
                      + "recording, so Listen never sees your screen.")
            if !Permissions.systemAudioSupported {
                status(false, "", "This needs macOS 14.2 or later. Listen will record "
                       + "only your microphone on this Mac.")
            } else {
                status(Permissions.systemAudio, "Working",
                       "Not available yet. It uses the same permission as the "
                       + "microphone, so granting that usually fixes it.")
            }

        case .model:
            titleLabel.stringValue = "Speech model"
            paragraph("Pick the model that transcribes your meetings. You can change "
                      + "this later in Settings.")
            for choice in ModelChoice.all {
                let radio = NSButton(radioButtonWithTitle: choice.title,
                                     target: self, action: #selector(pickModel(_:)))
                radio.tag = ModelChoice.all.firstIndex { $0.id == choice.id } ?? 0
                // Nothing is selected until the user selects it. `modelChosen`
                // is the presence of the key, not a value that always has one,
                // which is what lets this express "not yet asked".
                radio.state = Settings.modelChosen && Settings.model.id == choice.id
                    ? .on : .off
                body.addArrangedSubview(radio)
                let detail = NSTextField(labelWithString:
                    choice.isSharedWithSpeak
                        ? choice.blurb + " · already on disk, shared with Speak"
                        : (choice.isDownloaded ? choice.blurb + " · already on disk"
                                               : choice.detail))
                detail.font = .systemFont(ofSize: 11)
                detail.textColor = .secondaryLabelColor
                body.addArrangedSubview(detail)
            }

        case .done:
            titleLabel.stringValue = "You are set"
            paragraph("Start a recording from the menu bar, or turn on meeting detection "
                      + "in Settings and Listen will offer when a call starts.")
            paragraph("Recording begins the moment you press Start, and asks whether to "
                      + "keep it afterwards. That way the first minute of a meeting is "
                      + "never the part you lose.")
        }

        updateControls()
    }

    /// Never calls `render()` directly. See the note on the class.
    private func updateControls() {
        // A structural change re-renders exactly once, and only from here.
        if structuralKey() != lastKey, window?.isVisible == true {
            render()
            return
        }

        switch step {
        case .welcome:
            primary.title = "Continue"
            secondary.isHidden = true
        case .microphone:
            primary.title = Permissions.microphone ? "Continue" : "Allow microphone"
            secondary.isHidden = false
            secondary.title = "Skip"
        case .systemAudio:
            primary.title = "Continue"
            secondary.isHidden = false
            secondary.title = "Open System Settings"
        case .model:
            // The button is the consent. It names the model and its size, so
            // nobody can start a 2.5 GB download without having read what it
            // costs.
            if !Settings.modelChosen {
                primary.title = "Choose a model"
                primary.isEnabled = false
            } else if Settings.model.isDownloaded {
                primary.title = "Continue"
                primary.isEnabled = true
            } else {
                primary.title = "Download \(Settings.model.title) "
                    + "(\(ModelChoice.humanBytes(Settings.model.approxBytes)))"
                primary.isEnabled = true
            }
            secondary.isHidden = false
            secondary.title = "Later"
        case .done:
            primary.title = "Start using Listen"
            primary.isEnabled = true
            secondary.isHidden = true
        }
    }

    // MARK: - Actions

    @objc private func pickModel(_ sender: NSButton) {
        guard sender.tag < ModelChoice.all.count else { return }
        Settings.model = ModelChoice.all[sender.tag]
        render()
    }

    @objc private func next() {
        switch step {
        case .microphone where !Permissions.microphone:
            Permissions.requestMicrophone { _ in
                // Re-activate: the system dialog took focus, and an
                // unactivated window can end up behind whatever was in front.
                Task { @MainActor in
                    NSApp.activate(ignoringOtherApps: true)
                    Onboarding.shared.window?.makeKeyAndOrderFront(nil)
                    Onboarding.shared.render()
                }
            }
            return

        case .model where Settings.modelChosen && !Settings.model.isDownloaded:
            download()
            return

        case .done:
            finish()
            return

        default:
            break
        }
        advance()
    }

    @objc private func skip() {
        switch step {
        case .microphone:
            if Permissions.microphoneDenied { Permissions.openMicrophoneSettings() }
            advance()
        case .systemAudio:
            Permissions.openMicrophoneSettings()
        default:
            advance()
        }
    }

    private func advance() {
        let next = min(step.rawValue + 1, Step.allCases.count - 1)
        step = Step(rawValue: next) ?? .done
        render()
    }

    private func download() {
        let choice = Settings.model
        primary.isEnabled = false
        primary.title = "Downloading \(choice.title)…"
        Task {
            do {
                try await ASR().load(choice) { message in
                    Task { @MainActor in self.primary.title = message }
                }
                self.advance()
            } catch {
                self.primary.isEnabled = true
                self.primary.title = "Try again"
                let alert = NSAlert()
                alert.messageText = "Could not download the model"
                alert.informativeText = error.localizedDescription
                alert.window.level = .floating
                alert.runModal()
            }
        }
    }

    private func finish() {
        Settings.onboarded = true
        poll?.invalidate()
        poll = nil
        window?.orderOut(nil)
        LibraryWindow.shared.show()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window counts as finishing. Leaving `onboarded` false
        // would show setup again on the next launch, which reads as the app
        // having forgotten.
        Settings.onboarded = true
        poll?.invalidate()
        poll = nil
    }

    // MARK: - Building

    private func paragraph(_ text: String) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 460
        body.addArrangedSubview(label)
    }

    private func status(_ ok: Bool, _ good: String, _ bad: String) {
        // A tick or a circle, matching Speak. The prefix is only ever read by
        // a person: nothing branches on it, which is what went wrong when
        // `updateControls` scanned rendered text to decide whether to
        // re-render.
        let label = NSTextField(labelWithString: (ok ? "✓ " : "○ ") + (ok ? good : bad))
        label.font = .systemFont(ofSize: 12)
        label.textColor = ok ? .systemGreen : .secondaryLabelColor
        body.addArrangedSubview(label)
    }
}
