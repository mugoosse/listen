import AppKit

/// A recording while it is happening: a page to write on, and the two tracks
/// moving underneath it.
///
/// This replaces the mode picker and the sentence "Recording. The transcript
/// appears when you stop." for the one state where there is nothing to switch
/// between. While capture runs there is no transcript to read and nothing to
/// ask, so three tabs offering two empty documents and a promise is a chrome tax
/// on the only minutes of a meeting that cannot be redone later.
///
/// **The note is here because afterwards is when nobody writes it.** Listen's
/// iOS `RecordView` made that call first and its reasoning holds on the Mac:
/// the user's own note is the thing no transcript contains, and the moment it
/// exists is while the conversation is still going on. It writes through
/// `Notes.setYours`, which is the same note the Notes tab edits once the meeting
/// is over, so this is a second way in rather than a second note.
///
/// **The two lanes are the reason this is urgent rather than nice.** An hour of a
/// WhatsApp call was recorded through a laptop whose lid was shut, which means
/// macOS had switched the built-in microphone off, and the only moving thing on
/// screen was a clock. A clock counting up looks exactly the same whether or not
/// anybody's voice is arriving. The upper lane is the far side and the lower one
/// is you, matching `TranscribingView`, so the picture does not change meaning
/// when capture ends and reading begins.
@MainActor
final class RecordingView: NSView {
    private let notesText = NSTextView()
    private let notesScroll = NSScrollView()
    private let placeholder = NSTextField(labelWithString: "Write notes here\u{2026}")

    private let bar = NSVisualEffectView()
    private let dot = NSView()
    private let you = TrackMeter(name: "You", tint: .systemRed)
    private let them = TrackMeter(name: "Them", tint: .systemTeal)

    /// Which microphone this recording is going through, and the way to change
    /// it without leaving the call.
    ///
    /// Naming it is half the fix on its own. The hour that prompted all of this
    /// was recorded from "MacBook Pro Microphone" while the lid was shut and an
    /// external microphone sat plugged in a foot away, and at no point did
    /// anything on screen say which device was in use. A name would have ended it
    /// in a second.
    ///
    /// A pull-down rather than a pop-up, because the title and the selection are
    /// **different facts**. The title is the device actually recording; the tick
    /// is the setting. Those disagree exactly when it matters, which is when the
    /// setting says "follow the system default" and Listen has had to decline the
    /// default because it cannot record.
    private let devicePicker = NSPopUpButton(frame: .zero, pullsDown: true)


    /// Why the microphone is not hearing anything, or which device Listen had to
    /// move to. One line, under the meters, and empty most of the time.
    ///
    /// A label rather than a sheet or a notification. Somebody is in a
    /// conversation: the fix is theirs to make when they get a moment, and
    /// interrupting the meeting to report a problem with recording the meeting
    /// is its own kind of cost.
    private let warning = NSTextField(labelWithString: "")

    private var recording: Recording?
    private var tick: Timer?
    private var pulse: Timer?
    private var bright = true

    /// Whether the meters are running, so `begin` is idempotent. `show` in the
    /// pane is called again on every capture change and on every menu rebuild,
    /// and restarting the strips on each one would clear their history a few
    /// times a second.
    private var running = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not in a nib") }

    // MARK: - Building

    private func build() {
        // No border and no caption on the note. It is a page you write on, and a
        // labelled box invites a sentence rather than a page. Same call the iOS
        // screen makes.
        notesText.isRichText = false
        notesText.font = .systemFont(ofSize: 13)
        notesText.drawsBackground = false
        notesText.isVerticallyResizable = true
        notesText.isHorizontallyResizable = false
        notesText.autoresizingMask = [.width]
        notesText.textContainerInset = NSSize(width: 20, height: 16)
        notesText.delegate = self

        notesScroll.documentView = notesText
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notesScroll)

        // A label rather than the text view's own placeholder, which AppKit does
        // not offer for `NSTextView`. Positioned on the first line's baseline
        // inset, so typing replaces it in place rather than shifting the caret.
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.textColor = .placeholderTextColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)

        bar.material = .headerView
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4.5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(dot)

        // No clock here. The floating Stop button already reads "Stop 2:45" and
        // is on screen for the whole recording, and the same number twice on one
        // screen makes a reader check whether the two agree.
        devicePicker.isBordered = false
        devicePicker.font = .systemFont(ofSize: 11, weight: .medium)
        devicePicker.controlSize = .small
        devicePicker.target = self
        devicePicker.action = #selector(pickDevice(_:))
        devicePicker.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(devicePicker)

        for meter in [them, you] {
            meter.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(meter)
        }

        warning.font = .systemFont(ofSize: 11, weight: .medium)
        warning.textColor = .systemOrange
        warning.lineBreakMode = .byTruncatingTail
        warning.isHidden = true
        warning.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(warning)

        NSLayoutConstraint.activate([
            // Straight to the margin. Nothing floats over this corner: the record
            // and stop control is a toolbar item, which is what stopped it
            // covering the "You" strip.
            them.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -20),
            notesScroll.topAnchor.constraint(equalTo: topAnchor),
            notesScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            notesScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            notesScroll.bottomAnchor.constraint(equalTo: bar.topAnchor),

            placeholder.topAnchor.constraint(equalTo: notesScroll.topAnchor, constant: 16),
            placeholder.leadingAnchor.constraint(equalTo: notesScroll.leadingAnchor,
                                                 constant: 25),

            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Three rows: the far side, you, then the device and whatever needs
            // saying about it. The strips take the top two because they are what
            // somebody glances at, and their left edges are pinned to the same x
            // so that "one moving, one flat" reads as a comparison rather than
            // two unrelated pictures. Nothing of variable width sits to their
            // left, which is what keeps them from moving as a device name or a
            // clock changes length.
            them.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 20),
            you.leadingAnchor.constraint(equalTo: them.leadingAnchor),
            you.trailingAnchor.constraint(equalTo: them.trailingAnchor),
            them.topAnchor.constraint(equalTo: bar.topAnchor, constant: 12),
            them.heightAnchor.constraint(equalToConstant: 22),
            you.topAnchor.constraint(equalTo: them.bottomAnchor, constant: 2),
            you.heightAnchor.constraint(equalToConstant: 22),

            dot.leadingAnchor.constraint(equalTo: them.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: devicePicker.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 9),
            dot.heightAnchor.constraint(equalToConstant: 9),

            devicePicker.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 7),
            devicePicker.topAnchor.constraint(equalTo: you.bottomAnchor, constant: 6),

            warning.leadingAnchor.constraint(equalTo: devicePicker.trailingAnchor,
                                             constant: 10),
            warning.trailingAnchor.constraint(lessThanOrEqualTo: them.trailingAnchor),
            warning.centerYAnchor.constraint(equalTo: devicePicker.centerYAnchor),

            bar.heightAnchor.constraint(equalToConstant: 92),
        ])
    }

    // MARK: - Showing

    /// Point the screen at a recording and load whatever note it already has.
    ///
    /// Reloading the note text is guarded on the recording's identity. This is
    /// called again on every capture change, and rewriting `notesText` while
    /// somebody is typing into it would move their caret to the end of what they
    /// had just written.
    func configure(_ recording: Recording) {
        let changed = self.recording?.id != recording.id
        self.recording = recording
        if changed {
            notesText.string = Notes.yoursOrEmpty(for: recording).body
            updatePlaceholder()
        }
        refreshWarning()
    }

    /// Start the strips.
    func begin() {
        guard !running else { return }
        running = true
        them.meter.begin()
        you.meter.begin()

        // Subscribed here rather than at build time, and dropped in `end()`. The
        // strips are 60 Hz timers: leaving them running behind a transcript
        // somebody is reading would be an hour of redraws of a hidden view.
        Capture.shared.addLevelSink(self) { [weak self] track, level in
            guard let self else { return }
            switch track {
            case .you:  self.you.meter.push(CGFloat(level))
            case .them: self.them.meter.push(CGFloat(level))
            }
        }
        startTimers()
        refreshWarning()
    }

    /// Stop everything and write the note down.
    ///
    /// Saving here rather than only on Stop is what makes closing the window,
    /// clicking another recording, or quitting mid-meeting safe. `setYours`
    /// deletes on empty, so this cannot leave a blank note behind either.
    func end() {
        save()
        guard running else { return }
        running = false
        Capture.shared.removeLevelSink(self)
        them.meter.end()
        you.meter.end()
        stopTimers()
    }

    func save() {
        // Never in a preview launch. `LISTEN_PANEL=live` points at whichever real
        // recording is newest, and writing an empty note over it would delete
        // something somebody wrote in order to look at a layout.
        guard let recording, previewSilent == nil else { return }
        _ = try? Notes.setYours(notesText.string, for: recording)
    }

    // MARK: - Preview

    /// A fixed silence answer and a fixed clock for `LISTEN_PANEL=live`, both nil
    /// in every real run.
    private var previewSilent: Bool?
    private var previewClock: TimeInterval = 0
    private var fake: Timer?

    /// Drive both strips from a synthetic speech envelope.
    ///
    /// The strips are the reason this screen exists, and "can you tell at a
    /// glance which lane is dead" is a question about a moving thing: it cannot
    /// be answered from a screenshot, from memory of the build before last, or by
    /// holding a meeting every time somebody changes a constant. Speak's
    /// `--hud-demo` exists for the same reason and says so.
    ///
    /// `silent` is the case a real machine will not reproduce on demand unless
    /// somebody shuts a laptop lid on it.
    func preview(silent: Bool) {
        previewSilent = silent
        previewClock = 1994
        running = true
        them.meter.begin()
        you.meter.begin()
        startTimers()
        refreshWarning()

        // Thirty a second, which is the rate the real callback delivers windows
        // at, so the movement being judged is the movement that will ship.
        fake?.invalidate()
        fake = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.previewClock += 1.0 / 30.0
                self.them.meter.push(CGFloat(FakeSpeech.level(self.previewClock)))
                self.you.meter.push(silent ? 0
                    : CGFloat(FakeSpeech.level(self.previewClock + 2.6)))
            }
        }
    }

    // MARK: - The warning

    /// One sentence, chosen so that the most fixable thing is the thing on
    /// screen.
    ///
    /// A shut lid is top of the list on purpose. It is the failure nothing else
    /// on the machine reports, and the only one somebody can undo in a second
    /// without leaving the call.
    private func refreshWarning() {
        let capture = Capture.shared
        let silent = previewSilent ?? capture.micIsSilent
        you.isSilent = silent

        // The preview says the plain version, without the lid clause. There is no
        // capture behind it, so `micNotice` cannot tell whether the device on
        // screen is the built-in one, and a preview that claims a lid is shut
        // about a pair of headphones teaches the wrong sentence.
        let text = previewSilent == true
            ? "Your microphone is not picking anything up."
            : capture.micNotice(short: false)
        warning.stringValue = text ?? ""
        warning.isHidden = text == nil
        warning.textColor = silent ? .systemOrange : .secondaryLabelColor
        refreshDevices()
    }

    /// Rebuild the device menu, and title it with the device actually in use.
    ///
    /// The title and the tick answer different questions and are allowed to
    /// disagree: the title is what is being recorded from, the tick is what the
    /// setting asks for. They differ exactly when it matters, which is when the
    /// setting follows the system default and Listen has declined that default
    /// because it cannot record.
    private func refreshDevices() {
        let menu = NSMenu()
        let inUse = Capture.shared.micDeviceName
            ?? Settings.resolvedMicrophone?.name ?? "No microphone"
        // Item 0 of a pull-down is its title and is never chosen.
        menu.addItem(withTitle: inUse, action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let chosen = Settings.microphoneUID
        let automatic = NSMenuItem(title: "Follow the system default",
                                   action: #selector(pickDevice(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = chosen == nil ? .on : .off
        menu.addItem(automatic)
        menu.addItem(.separator())

        for device in AudioDevices.inputs() {
            let item = NSMenuItem(title: device.name, action: #selector(pickDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = chosen == device.uid ? .on : .off
            // Shown and disabled rather than hidden. A microphone missing from
            // the list reads as Listen not seeing it; one greyed out with the
            // reason beside it is the app telling you why it declined it, which
            // is the difference between a bug and an explanation.
            if !AudioDevices.isUsable(device) {
                item.isEnabled = false
                item.title = AudioDevices.isBuiltIn(device) && AudioDevices.lidClosed
                    ? "\(device.name) (off while the lid is shut)"
                    : "\(device.name) (cannot be recorded from)"
            }
            menu.addItem(item)
        }
        devicePicker.menu = menu
        devicePicker.contentTintColor = you.isSilent ? .systemOrange : .secondaryLabelColor
    }

    @objc private func pickDevice(_ sender: NSMenuItem) {
        Capture.shared.switchMicrophone(to: sender.representedObject as? String)
        refreshWarning()
    }

    // MARK: - Timers

    private func startTimers() {
        stopTimers()
        // No clock to advance any more, so this is the device and the warning:
        // both change without anything telling this view, since a microphone can
        // be unplugged at any moment.
        tick = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWarning() }
        }
        pulse = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bright.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.55
                    self.dot.animator().alphaValue = self.bright ? 1.0 : 0.35
                }
            }
        }
    }

    private func stopTimers() {
        tick?.invalidate(); tick = nil
        pulse?.invalidate(); pulse = nil
        fake?.invalidate(); fake = nil
        dot.alphaValue = 1
    }

    private func updatePlaceholder() {
        placeholder.isHidden = !notesText.string.isEmpty
    }

}

extension RecordingView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        updatePlaceholder()
    }

    /// Written on the way out of the field as well as on Stop, because a meeting
    /// can end with the user clicking away rather than pressing anything.
    func textDidEndEditing(_ notification: Notification) {
        save()
    }
}
