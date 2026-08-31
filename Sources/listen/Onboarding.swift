import AppKit
import ListenKit

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

    /// Ask sits after dictation, and it is the second optional one. It is a
    /// step rather than a card in the window for the reason the calendar is a
    /// step: Settings is the only other place it can be offered from, and a
    /// feature nobody is told about is one nobody turns on. What it must not
    /// do is sell itself on the home screen of an app somebody opened to
    /// record a meeting, which is what it did before this step existed. See
    /// `Settings.askEnabled`.
    ///
    /// The calendar sits between the two recording permissions and the model,
    /// and it is the only optional one. It is here at all because the Settings
    /// pane is the only other place the system prompt can be raised from, so
    /// leaving it out means anybody who never opens Settings never gets asked
    /// and the feature is silently off for them. Its buttons say so: the way
    /// past it is "Not now" rather than "Skip", and nothing about it blocks.
    enum Step: Int, CaseIterable {
        case welcome, microphone, systemAudio, calendar, model, dictation, ask, sync, done
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

    /// The model step's progress bar and status line, held so they can be
    /// updated in place. Rule 2 above is why they are not simply re-rendered:
    /// a percentage inside `structuralKey()` rebuilds the radio buttons under
    /// the cursor once a second, for the length of a 2.5 GB download.
    private var modelBar: NSProgressIndicator?
    private var modelNote: NSTextField?

    /// True between pressing the model step's button and an answer arriving.
    ///
    /// The answer is read from `ModelDownload`, which is polled rather than
    /// subscribed to: its `onChange` is a single slot that the Settings pane
    /// also claims, and two owners of one closure is a bug waiting for whoever
    /// opens Settings and then runs setup again.
    private var awaitingModel = false

    /// Start again from the first step.
    ///
    /// From the top, not from wherever the last visit ended: reaching for this
    /// means something has stopped working, and the earlier steps are usually
    /// where the answer is. Speak's About pane offers the same thing for the
    /// same reason.
    func restart() {
        step = .welcome
        // Closable, unlike the first run: somebody reviewing setup from
        // Settings must be able to leave without walking every step.
        show(closable: true)
    }

    /// `closable` decides whether the window has a close button at all.
    ///
    /// On a first run it does not. Every step already has its own way past
    /// (Skip, Not now, Later), so nothing blocks; what the close button added
    /// was a way to *vanish* the flow mid-download, which the first outside
    /// install took, and then met the library with no model chosen and no idea
    /// the wizard had counted that as finishing. The flow is quick and
    /// skippable; it is just no longer optional to walk.
    func show(closable: Bool = false) {
        if window == nil { build() }
        window?.styleMask = closable ? [.titled, .closable] : [.titled]
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
            // The grant is made in System Settings, in another app, and
            // there is no notification for it. The poll is the only thing
            // that notices, and it only re-renders when this changes.
            String(Permissions.accessibility),
            Settings.modelChosen ? Settings.model.id : "none",
            String(Settings.model.isDownloaded),
            // The sync step's tick, which the button on that step changes.
            String(Settings.cloudSyncApplies),
            // The phase, never the byte count. Starting, finishing and failing
            // each change what the pane contains; a percentage only changes
            // what one label says, and rule 2 is why that distinction matters.
            ModelDownload.shared.status.phaseKey,
        ].joined(separator: "|")
    }

    private func render() {
        lastKey = structuralKey()
        for view in body.arrangedSubviews { view.removeFromSuperview() }
        // Owned by the model step's body, so they die with it.
        modelBar = nil
        modelNote = nil

        switch step {
        case .welcome:
            titleLabel.stringValue = "Welcome to Listen"
            body.addArrangedSubview(BrandIcon.view(size: 64, accessibilityLabel: "Listen mascot"))
            paragraph("Listen records your meetings, writes them down, and works out "
                      + "who said what. All of it happens on this Mac.")
            paragraph("Your recordings never leave this Mac. Out of the box the network "
                      + "is used only to download the speech model once and to check for "
                      + "updates; anything more is a switch you turn on yourself.")

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
                // Off while the bytes are arriving. Switching mid-download
                // leaves 2.5 GB coming for a model nobody wants any more, and
                // the download it would have to cancel is the one thing on this
                // pane that cannot be undone in a second.
                radio.isEnabled = !ModelDownload.shared.isDownloading
                body.addArrangedSubview(radio)
                let detail = NSTextField(labelWithString:
                    choice.isDownloaded ? choice.blurb + " · already on disk"
                                        : choice.detail)
                detail.font = .systemFont(ofSize: 11)
                detail.textColor = .secondaryLabelColor
                body.addArrangedSubview(detail)
            }

            // A download with no visible progress is indistinguishable from a
            // button that does nothing, and that is exactly how it was
            // reported: "for some reason I can't download it", then "nope" to
            // whether an error had appeared. Two and a half gigabytes take
            // minutes, so the pane has to keep saying so for all of them.
            let bar = NSProgressIndicator()
            bar.isIndeterminate = false
            bar.minValue = 0
            bar.maxValue = 1
            bar.controlSize = .small
            bar.isHidden = true
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 460).isActive = true
            body.addArrangedSubview(bar)
            modelBar = bar

            // Wrapping and capped at the same width the paragraphs use, for the
            // reason recorded on `status`: a long line in a fixed-width label
            // widens the whole window.
            let line = NSTextField(wrappingLabelWithString: "")
            line.font = .systemFont(ofSize: 12)
            line.textColor = .secondaryLabelColor
            line.preferredMaxLayoutWidth = 460
            body.addArrangedSubview(line)
            modelNote = line

        case .dictation:
            titleLabel.stringValue = "Dictation"
            paragraph("Listen also types for you. Press a shortcut anywhere on the Mac, "
                      + "say what you want written, press it again, and the words are "
                      + "put into whatever you were using. The same speech model, still "
                      + "on this machine.")
            paragraph("The shortcut is \(DictationShortcut.description), and Settings, "
                      + "Dictation is where you change it or switch the whole thing off.")
            // Said plainly, because this is the one grant that sounds alarming
            // and the honest description is also the reassuring one.
            paragraph("This needs Accessibility, which is what lets Listen see the "
                      + "shortcut and type for you. Recording meetings never uses it, so "
                      + "skipping here costs you nothing else.")
            status(Permissions.accessibility, "Accessibility granted",
                   "Not granted yet. This opens System Settings, where Listen can be "
                   + "switched on under Accessibility.")

        case .ask:
            titleLabel.stringValue = "Ask about your meetings"
            // **Value first, and in the words somebody would use themselves.**
            // The card this replaced opened with "Ask needs an AI to answer
            // with", which is a requirement for a feature the reader has never
            // heard of: it asks for a decision about setting something up
            // before saying what it would be for.
            paragraph("Once a meeting is written down you can ask about it in "
                      + "plain words. What did we decide. What did I say I would "
                      + "do. What has this person told me about pricing, across "
                      + "every call you have had with them. The answer comes out "
                      + "of your own recordings, and you can keep it as a note.")
            // The cost, before the button rather than after it.
            paragraph("The answering is done by something of yours rather than "
                      + "anything of ours: Claude Code or Codex on a subscription "
                      + "you already pay for, or any provider that speaks the "
                      + "OpenAI chat API, which includes a model running on this "
                      + "Mac through Ollama. There is no Listen account and no "
                      + "server of ours in between.")
            paragraph("Recording and transcribing never use it, so leaving this "
                      + "off costs you nothing else. Settings, Ask is where it "
                      + "goes on later, and where you pick which one answers.")
            if Settings.askEnabled {
                status(true, "Ask is on", "")
            }

        case .sync:
            titleLabel.stringValue = "Your other devices"
            paragraph("With iCloud sync on, meetings recorded on your iPhone arrive "
                      + "here to be written down, and every transcript and note stays "
                      + "in step across your devices. Listen for iPhone connects by "
                      + "itself once this is on.")
            // The trade-off, before the button that accepts it. Sync is the
            // one feature here that sends anything anywhere, so the sentence
            // has to say what travels and what does not.
            paragraph("Everything it sends is sealed with a key only your devices "
                      + "hold, so Apple stores it and cannot read it. Audio stays "
                      + "on the Mac that recorded it.")
            if Settings.isForced("cloudSync") {
                status(Settings.cloudSyncApplies, "iCloud sync is on",
                       "iCloud sync is off, set by your organisation's device profile.")
            } else {
                status(Settings.cloudSyncApplies, "iCloud sync is on",
                       "Not on yet. Everything else works without it, on this "
                       + "Mac alone, and Settings, Sync can turn it on later.")
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

        // Nothing to go back to from the first step.
        backButton.isHidden = step == .welcome
        rail.isHidden = false
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
            // **This switch runs every 0.8 seconds, and whatever it assigns is
            // what the button says.** That is what broke: `download()` used to
            // set the title to "Downloading…" and disable the button itself,
            // and the next poll put "Download Parakeet v3 (2.51 GB)" back and
            // re-enabled it, about half a second later. So a download that had
            // started looked like a press that had done nothing, and pressing
            // again started a second one over the same directory. Two fetches
            // clearing and repopulating one cache is how a tester ended up
            // being told `Key decoder.prediction.embed.weight not found in
            // ParakeetModel…`, which is what mlx-swift says when the weights it
            // wants are not in the directory it was pointed at.
            //
            // Nothing here may be assigned from anywhere else. The state comes
            // from `ModelDownload`, which owns the fetch, refuses to start a
            // second one, and can be watched by Settings at the same time.
            let status = ModelDownload.shared.status
            let choice = Settings.model
            updateModelProgress(status)

            // The button is the consent. It names the model and its size, so
            // nobody can start a 2.5 GB download without having read what it
            // costs.
            if status.isBusy {
                primary.title = status.phaseKey == "loading" ? "Loading…" : "Downloading…"
                primary.isEnabled = false
            } else if !Settings.modelChosen {
                primary.title = "Choose a model"
                primary.isEnabled = false
            } else if case .failed = status {
                primary.title = "Try again"
                primary.isEnabled = true
            } else if choice.isDownloaded {
                // "Continue" whether or not it has been loaded yet. Pressing it
                // loads the weights before moving on, which takes a second or
                // two from a warm cache and is the only check that means
                // anything: a directory of the right size still has to parse.
                primary.title = "Continue"
                primary.isEnabled = true
            } else {
                primary.title = "Download \(choice.title) "
                    + "(\(ModelChoice.humanBytes(choice.approxBytes)))"
                primary.isEnabled = true
            }

            // The one step where the second button is load-bearing: with
            // nothing chosen the primary is deliberately disabled, so this is
            // the only way past. Once the model is on disk the primary reads
            // Continue and "Later" would be its twin. It stays during a
            // download, because a download is the longest wait in setup and
            // leaving is a reasonable thing to want; the fetch carries on in
            // the background, where Settings, Models can follow it.
            secondary.isHidden = Settings.modelChosen && choice.isDownloaded
                && !status.isBusy
            secondary.title = "Later"

            // Read here rather than in a callback, because the poll is already
            // running and `ModelDownload.onChange` has one slot that Settings
            // also wants. Only the press that started this is answered: a
            // `.ready` left over from the Settings pane must not skip the step.
            if awaitingModel, !status.isBusy {
                switch status {
                case .ready where ModelDownload.shared.isVerified(choice):
                    awaitingModel = false
                    advance()
                case .failed(let why):
                    awaitingModel = false
                    reportModelFailure(why)
                default:
                    awaitingModel = false
                }
            }
        case .dictation:
            // One label whichever way it goes, like the calendar step: the
            // promise is dictation, and the route underneath it changes.
            primary.title = Permissions.accessibility ? "Continue" : "Open System Settings"
            primary.isEnabled = true
            secondary.isHidden = Permissions.accessibility
            secondary.title = "Skip"
        case .ask:
            // The press is the consent, and nothing else here needs granting:
            // there is no system prompt to raise and no download to start, so
            // this step is over the moment it is answered either way.
            primary.title = Settings.askEnabled ? "Continue" : "Turn on Ask"
            primary.isEnabled = true
            secondary.isHidden = Settings.askEnabled
            // "Not now" and not "Skip", for the calendar step's reason:
            // declining costs a feature, not half of every recording.
            secondary.title = "Not now"
        case .sync:
            // One label whichever way it goes, like the calendar step: the
            // promise is sync, and pressing it is the consent. Forced values
            // get Continue alone, because the button could not keep it.
            let on = Settings.cloudSyncApplies
            primary.title = on || Settings.isForced("cloudSync")
                ? "Continue" : "Turn on iCloud sync"
            primary.isEnabled = true
            secondary.isHidden = on || Settings.isForced("cloudSync")
            secondary.title = "Not now"
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
        awaitingModel = false
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

        case .model where Settings.modelChosen:
            startModel()
            return

        case .dictation where !Permissions.accessibility:
            Permissions.openAccessibilitySettings()
            // Armed the moment the grant lands, without a relaunch. The window
            // stays on this step so the tick can appear where it was promised.
            Dictation.shared.activate()
            return

        case .ask where !Settings.askEnabled:
            // Turned on here and configured later, deliberately. The wizard
            // needs `LibraryWindow.sheetHost` to hang a sheet on and the
            // library window does not exist during a first run, so offering it
            // here would be a button that sometimes does nothing. Saying yes
            // puts Ask in the app, and the card there is what finishes the job.
            Settings.askEnabled = true
            MainMenu.refreshAsk()
            // The window stays on this step so the tick can appear where it
            // was promised, which is what the sync step does.
            render()
            return

        case .sync where !Settings.cloudSyncApplies && !Settings.isForced("cloudSync"):
            // The press is the consent, exactly as the Sync pane's checkbox
            // is, and it does the same things that checkbox does. The first
            // pass creates the shared key when this account has never synced;
            // see `KeyStore.provision`. The window stays on this step so the
            // tick can appear where it was promised.
            Settings.cloudSync = true
            ActivityLog.append("sync_enabled")
            Telemetry.featureUsed(.syncEnabled)
            CloudSyncHost.shared.startIfEnabled()
            render()
            return

        case .done:
            // One summary of the choices made here, sent only if the step
            // before said yes; `Telemetry` drops it silently otherwise.
            Telemetry.setupCompleted(
                micGranted: Permissions.microphone,
                model: Settings.modelChosen ? Settings.model.id : "none",
                dictationOn: Permissions.accessibility,
                syncOn: Settings.cloudSyncApplies,
                calendarOn: Permissions.calendar)
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
        case .ask:
            // The same, and `askEnabled` is left alone: it is already off, and
            // Settings, Ask is where it becomes now.
            advance()
        default:
            advance()
        }
    }

    private func advance() {
        // Leaving the model step ends the wait for it. Pressing Later during a
        // download does not cancel the download, so without this the answer
        // would be delivered to a pane that has moved on, and coming back would
        // skip the step on the strength of it.
        awaitingModel = false
        let next = min(step.rawValue + 1, Step.allCases.count - 1)
        step = Step(rawValue: next) ?? .done
        render()
    }

    /// Download the model if it is missing, load it either way, and move on
    /// only when it has actually loaded.
    ///
    /// **Continue and Download are the same action on purpose.** They used to
    /// differ: Download loaded the weights, and Continue believed
    /// `isDownloaded`, which is a file size. So after a failure the button read
    /// Try again, the failed attempt had left a directory of about the right
    /// size behind, and pressing it walked straight past the model step to "You
    /// are set" without ever loading anything. A tester reached the end of setup
    /// that way, holding a model that had just refused to load.
    ///
    /// The task lives in `ModelDownload`, not here, for the reason its own note
    /// gives and for one more: it refuses to start a second fetch while one is
    /// running, and this window used to have no such guard at all.
    private func startModel() {
        let choice = Settings.model
        // Loaded once already in this process, so there is nothing left to
        // find out and no reason to spend a second on it.
        if ModelDownload.shared.isVerified(choice) {
            advance()
            return
        }
        guard !ModelDownload.shared.isDownloading else { return }
        awaitingModel = true
        ModelDownload.shared.start(choice)
        // Directly, because a press should show its consequence now rather than
        // when the poll next fires. Safe here and not in `updateControls`: this
        // is an action, and rule 2 is about the loop between those two.
        render()
    }

    /// The bar and the line under the radio buttons, updated in place.
    private func updateModelProgress(_ status: ModelStatus) {
        if let bar = modelBar {
            if let fraction = status.fraction {
                bar.isHidden = false
                bar.isIndeterminate = false
                bar.stopAnimation(nil)
                bar.doubleValue = fraction
            } else if status.isBusy {
                // No reading yet, or loading rather than fetching. A bar that
                // sits at zero says stalled; a moving one says working, which
                // is the truth in both cases.
                bar.isHidden = false
                bar.isIndeterminate = true
                bar.startAnimation(nil)
            } else {
                bar.stopAnimation(nil)
                bar.isHidden = true
            }
        }

        guard let note = modelNote else { return }
        switch status {
        case .ready, .idle:
            // Nothing to say. "Ready" under a model the pane already describes
            // as being on disk is noise, and matches the Settings pane.
            note.stringValue = ""
        case .failed(let why):
            note.stringValue = why
            note.textColor = .systemRed
        default:
            note.stringValue = status.summary
            note.textColor = .secondaryLabelColor
        }
    }

    /// Said in a dialog as well as on the pane, because this is the one step
    /// that can fail while nobody is watching it.
    private func reportModelFailure(_ why: String) {
        let alert = NSAlert()
        // Not "Could not download the model". The download is only half of what
        // this button does, and the failure a tester actually hit was the other
        // half: the bytes had arrived and would not load.
        alert.messageText = "Could not set up \(Settings.model.title)"
        alert.informativeText = why.prefix(1).uppercased() + String(why.dropFirst()) + "."
            + "\n\nThe button below now reads Try again. Setup can also carry on "
            + "without it: Listen fetches the model again the first time it "
            + "transcribes a recording."
        alert.window.level = .floating
        alert.runModal()
    }

    private func finish() {
        Settings.onboarded = true
        stopPolling()
        // Setup is the only thing that arms dictation on a first run: launch
        // deliberately skips it, because on a fresh install nothing is granted
        // and no model is chosen, so there is no tap to install and nothing to
        // warm. Somebody who skipped the step gets a `dictationEnabled` that is
        // true and inert, which is the same state they would be in anyway.
        Dictation.shared.activate()
        // Setup mentioned it, so the menu row would be telling them twice.
        Settings.dictationIntroSeen = true
        window?.orderOut(nil)
        LibraryWindow.shared.show()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window counts as finishing. Leaving `onboarded` false
        // would show setup again on the next launch, which reads as the app
        // having forgotten. A first run has no close button any more (see
        // `show(closable:)`), so this now fires for the Settings re-run and
        // for quitting mid-setup, and both of those do mean "stop asking".
        Settings.onboarded = true
        stopPolling()
        Dictation.shared.activate()
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
