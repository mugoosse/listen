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

    /// The calendar sits between the two recording permissions and the model,
    /// and it is the only optional one. It is here at all because the Settings
    /// pane is the only other place the system prompt can be raised from, so
    /// leaving it out means anybody who never opens Settings never gets asked
    /// and the feature is silently off for them. Its buttons say so: the way
    /// past it is "Not now" rather than "Skip", and nothing about it blocks.
    enum Step: Int, CaseIterable {
        case welcome, microphone, systemAudio, calendar, model, done
    }

    private var window: NSWindow?
    private var step: Step = .welcome
    private var body: NSStackView!
    private var titleLabel: NSTextField!
    private var primary: NSButton!
    private var secondary: NSButton!
    private var backButton: NSButton!
    private var rail: NSStackView!
    private var lastKey = ""
    private var poll: Timer?

    /// Start again from the first step.
    ///
    /// From the top, not from wherever the last visit ended: reaching for this
    /// means something has stopped working, and the earlier steps are usually
    /// where the answer is. Speak's About pane offers the same thing for the
    /// same reason.
    func restart() {
        step = .welcome
        show()
    }

    func show() {
        if window == nil { build() }
        // Restarted here, not only in `build`. Both `finish` and
        // `windowWillClose` invalidate it, and `build` runs once for the life
        // of the process, so running setup a second time from Settings would
        // otherwise come back with a dead timer: permissions land
        // asynchronously and nothing else notices them, so every pane would sit
        // on whatever it said when it was drawn.
        startPolling()
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

        // Back, so setup is something you can look around rather than a
        // one-way corridor. Ported from Speak, where it earned its place on the
        // model step: a multi-minute download you cannot step away from and
        // return to is one people abandon.
        backButton = NSButton(title: "Back", target: self, action: #selector(back))
        backButton.bezelStyle = .rounded

        // Filled behind, ringed on the current step, hollow ahead. Speak's
        // rail, and it does two things at once: it says how much is left, and
        // it makes Back legible as navigation rather than as undo.
        rail = NSStackView()
        rail.orientation = .horizontal
        rail.spacing = 6
        rail.alignment = .centerY

        let buttons = NSStackView(views: [backButton, secondary, primary])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let content = NSView()
        for v in [titleLabel, body, rail, buttons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            body.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            // The rail is pinned to the left and the buttons to the right, as
            // two separate views rather than as one row stretched across.
            // Putting them in a single stack pinned on both sides would make
            // the row's minimum width a constraint on the window, and the model
            // step's button reads "Download Parakeet v2 (2.47 GB)": wide enough,
            // with three buttons beside it, to push the window out. That is the
            // same fault as the status label that could not wrap, arriving from
            // the other direction.
            rail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            rail.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        w.contentView = content
        window = w

        startPolling()
    }

    /// Permissions land asynchronously and there is no notification for them,
    /// so the step polls rather than trusting the last answer.
    private func startPolling() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateControls() }
        }
    }

    private func stopPolling() {
        poll?.invalidate()
        poll = nil
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
            // In the key, or the pane goes on saying "not granted yet" after
            // the grant lands. The prompt is answered outside this window and
            // there is no notification for it, so the poll below is the only
            // thing that notices, and it only re-renders when this string
            // changes. `calendarAsked` too, because spending the one dialog a
            // launch gets changes what the button can do without changing the
            // authorization status at all.
            String(Permissions.calendar),
            String(Permissions.calendarAsked),
            Settings.modelChosen ? Settings.model.id : "none",
            String(Settings.model.isDownloaded),
        ].joined(separator: "|")
    }

    private func render() {
        lastKey = structuralKey()
        for view in body.arrangedSubviews { view.removeFromSuperview() }

        switch step {
        case .welcome:
            titleLabel.stringValue = "Welcome to Listen"
            body.addArrangedSubview(BrandIcon.view(size: 64, accessibilityLabel: "Listen mascot"))
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

        case .calendar:
            titleLabel.stringValue = "Your calendar"
            paragraph("If a recording lines up with a meeting in your calendar, Listen "
                      + "names it after that meeting and offers the people who were "
                      + "invited when you come to name a speaker.")
            // Said before the prompt, not after. This is the only permission
            // Listen asks for that changes what it writes rather than what it
            // can hear, and it does it without asking again each time.
            paragraph("It only reads, and never writes anything back to a calendar. "
                      + "Google and Microsoft calendars come through whatever you have "
                      + "already added in System Settings, so there is no account to "
                      + "make and nothing leaves this Mac.")
            switch Permissions.calendarAction {
            case .granted:
                status(true, "Calendar access granted", "")
            case .canAsk:
                status(false, "", "Not granted yet. This one is optional: everything "
                       + "else works without it.")
            case .settingsOnly:
                // Said plainly, because the button below now goes somewhere
                // else and a button that changes destination without saying so
                // is worse than one that never worked.
                status(false, "", "Not granted. This opens System Settings, where "
                       + "Listen can be switched on under Calendars.")
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
            body.addArrangedSubview(BrandIcon.view(size: 44, accessibilityLabel: "Listen is ready"))
            // Said here rather than left to be discovered, because it is on
            // without being asked for. An app that records a call you did not
            // tell it about is only acceptable if it told you it would.
            paragraph("Listen watches for a call starting and records it, asking on "
                      + "screen whether you are in a meeting. Saying no deletes the "
                      + "audio straight away. You can turn this off in Settings.")
            paragraph("It records before you answer because the first minute of a "
                      + "meeting, where people say who they are, is the part worth "
                      + "keeping. Starting by hand from the menu bar always works too.")
            // Only when it can actually happen. Naming from the calendar is the
            // other thing Listen does without being asked each time, so it gets
            // said here for the same reason detection does; saying it to
            // somebody who declined the permission would just be noise about a
            // feature they do not have.
            if Permissions.calendar {
                paragraph("Recordings that line up with a meeting in your calendar are "
                          + "named after it. A name you type yourself is never replaced.")
            }
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

        // Nothing to go back to from the first step, so the button is absent
        // rather than present and dead.
        backButton.isHidden = step == .welcome
        buildRail()

        // The rule for the second button, and it is one sentence: **it appears
        // only when it does something the primary does not.**
        //
        // It used to appear whatever the state was, so a granted microphone
        // step offered "Skip" and "Continue" side by side, both of which simply
        // advanced. Two buttons doing one thing is worse than one, because it
        // implies a difference and makes the reader look for it. Speak avoids
        // the question by having no second button at all: its primary names the
        // action when there is one and says Continue when there is not.
        switch step {
        case .welcome:
            primary.title = "Continue"
            secondary.isHidden = true
        case .microphone:
            let granted = Permissions.microphone
            primary.title = granted ? "Continue" : "Allow microphone"
            secondary.isHidden = granted
            secondary.title = "Skip"
        case .systemAudio:
            primary.title = "Continue"
            // Hidden when it is working, and also when the Mac is too old for
            // process taps: there is nothing in System Settings that would fix
            // macOS 14.1, so the button would be an instruction to go and fail.
            secondary.isHidden = Permissions.systemAudio || !Permissions.systemAudioSupported
            secondary.title = "Open System Settings"
        case .calendar:
            // One label for both ways of getting there. The button's promise is
            // calendar access, and the route underneath it changes: a prompt
            // while macOS will still give one, System Settings afterwards.
            // Renaming the button mid-step made the step look like it had
            // changed its mind, so the route moves and the promise does not.
            // The status line above says which one applies.
            primary.title = Permissions.calendar ? "Continue" : "Allow calendar access"
            primary.isEnabled = true
            secondary.isHidden = Permissions.calendar
            // "Not now" and not "Skip". Skip is what the microphone step
            // offers, where declining costs you half of every recording; here
            // it costs a name, and the wording should not imply otherwise.
            secondary.title = "Not now"
        case .model:
            // The button is the consent. It names the model and its size, so
            // nobody can start a 2.5 GB download without having read what it
            // costs.
            let ready = Settings.modelChosen && Settings.model.isDownloaded
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
            // The one step where the second button is load-bearing: with
            // nothing chosen the primary is deliberately disabled, so this is
            // the only way past. Once the model is on disk the primary reads
            // Continue and "Later" would be its twin.
            secondary.isHidden = ready
            secondary.title = "Later"
        case .done:
            primary.title = "Start using Listen"
            primary.isEnabled = true
            secondary.isHidden = true
        }
    }

    /// Filled circles behind, a ring on the current step, hollow ahead.
    ///
    /// Rebuilt rather than mutated: six image views is nothing, and a rail that
    /// is rebuilt cannot hold a tint from a step somebody has since left.
    private func buildRail() {
        for view in rail.arrangedSubviews {
            rail.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for s in Step.allCases {
            let name = s.rawValue < step.rawValue ? "checkmark.circle.fill"
                     : (s == step ? "circle.inset.filled" : "circle")
            let dot = NSImageView(image: NSImage(
                systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
            dot.contentTintColor = s.rawValue <= step.rawValue
                ? Brand.accent : .tertiaryLabelColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 13).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 13).isActive = true
            rail.addArrangedSubview(dot)
        }
        // Not decoration to a screen reader: this is the only thing on the
        // window that says how far through setup you are.
        rail.setAccessibilityLabel(
            "Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    // MARK: - Actions

    @objc private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
        render()
    }

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

        case .calendar where !Permissions.calendar:
            // The dialog is available once per launch, so which of these two
            // is right changes under the button. Deciding here rather than in
            // a `where` clause keeps that decision next to the one
            // `updateControls` makes about the title.
            if Permissions.calendarAction == .canAsk {
                Permissions.requestCalendar { _ in
                    // Re-activated for the same reason the microphone step is:
                    // the system dialog took focus, and this window floats but
                    // is not brought back on its own.
                    NSApp.activate(ignoringOtherApps: true)
                    Onboarding.shared.window?.makeKeyAndOrderFront(nil)
                    Onboarding.shared.render()
                }
            } else {
                Permissions.openCalendarSettings()
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
        case .calendar:
            // Straight past, with nothing opened and nothing asked. "Not now"
            // means not now, and Settings, Permissions has the switch whenever
            // it does become now.
            advance()
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
        stopPolling()
        window?.orderOut(nil)
        LibraryWindow.shared.show()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window counts as finishing. Leaving `onboarded` false
        // would show setup again on the next launch, which reads as the app
        // having forgotten.
        Settings.onboarded = true
        stopPolling()
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
        //
        // Wrapping, and capped at the same width `paragraph` uses. This was a
        // plain `labelWithString`, which has no maximum width and no line
        // breaking, so a status line longer than the others made the whole
        // setup window grow sideways to fit it on one line. Every string here
        // was short until the calendar step needed to explain itself, and a
        // window that changes size when you press a button inside it reads as
        // the app having lost its footing.
        let label = NSTextField(wrappingLabelWithString:
                                    (ok ? "✓ " : "○ ") + (ok ? good : bad))
        label.font = .systemFont(ofSize: 12)
        label.textColor = ok ? .systemGreen : .secondaryLabelColor
        label.preferredMaxLayoutWidth = 460
        body.addArrangedSubview(label)
    }
}
