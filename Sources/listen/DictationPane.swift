import AppKit

/// Settings for push-to-talk dictation.
///
/// Every control here changes the user's own words on their way to the
/// clipboard, so each one says what it costs on screen rather than behind a
/// tooltip. That is the house rule, and it matters more in this pane than
/// anywhere else in the app: a meeting transcript can be re-read against its
/// audio, and a dictation that came out wrong is just wrong.
@MainActor
final class DictationPane: Pane, NSTextFieldDelegate {
    private var shortcutField: NSTextField?
    private var changeButton: NSButton?
    private var riskyNote: NSTextField?
    private var engineMenu: NSPopUpButton?
    private var localeMenu: NSPopUpButton?
    private var localeRow: NSStackView?
    private var meterMenu: NSPopUpButton?
    private var startMenu: NSPopUpButton?
    private var doneMenu: NSPopUpButton?
    private var notesField: NSTextField?
    private var historyNote: NSTextField?
    private var enableBox: NSButton?
    private var accessibilityNote: PermissionStatusRow?
    private var grantButton: NSButton?

    /// Watches for the Accessibility grant while this pane is on screen.
    ///
    /// macOS sends no notification when a TCC grant changes and it is made in
    /// another app, so without this the row goes on saying "not granted" until
    /// something else happens to redraw the pane. Somebody who has just followed
    /// the button into System Settings and come back would be looking at a
    /// stale answer to the question they left to resolve.
    ///
    /// Only while visible, and that is the whole reason it is cheap: a
    /// permission check is a few microseconds and this is one a second for as
    /// long as a settings pane is open, rather than for the life of the app.
    private var poll: Timer?

    /// The widest chord seen while recording a replacement, and the pending
    /// commit. See `beginRecording`.
    private var widest: UInt64 = 0
    private var pendingCommit: DispatchWorkItem?

    override func build() {
        enableBox = checkbox("Dictate with a keyboard shortcut", Settings.dictationEnabled) {
            [weak self] on in
            Settings.dictationEnabled = on
            Dictation.shared.activate()
            self?.refresh()
        }
        note("Press the shortcut anywhere, talk, press it again. What you said goes to "
             + "the clipboard and is typed into whatever you were using. Nothing leaves "
             + "this Mac, and the speech model is the one the Models tab names.")

        // The permission, said as a live state rather than as prose.
        //
        // This pane used to carry a sentence reading "Needs Accessibility, grant
        // it in the Permissions tab", printed whether or not the grant existed.
        // That is the failure this feature has: the switch is on, the shortcut
        // is listed, and pressing it does nothing at all, because a tap without
        // the grant is refused and there is no keystroke to report the refusal
        // with. Somebody in that state came to this pane to find out why and was
        // told, in the present tense, something that was already true.
        //
        // So the row is a status with a button, it is checked while the pane is
        // on screen, and it is loud when it is the thing standing in the way.
        accessibilityNote = statusRow()
        grantButton = button("Open System Settings") { [weak self] in
            Permissions.openAccessibilitySettings()
            // Arms the tap the moment the grant lands, so the switch above
            // starts working without a relaunch, and the poll below turns this
            // row green while the user is still looking at it.
            Dictation.shared.activate()
            self?.refresh()
        }
        note("Accessibility is what lets Listen watch for the shortcut and type for you. "
             + "Recording, transcribing and labelling meetings never use it, so this is "
             + "the only part of Listen that asks.")

        note("While this is on, Listen keeps the speech model loaded, which is about "
             + "2.5 GB of memory, so a dictation starts the moment you press the "
             + "shortcut instead of a minute later.")

        separator()
        heading("Shortcut")
        let field = NSTextField(labelWithString: DictationShortcut.description)
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        shortcutField = field
        let change = NSButton(title: "Change…", target: nil, action: nil)
        change.bezelStyle = .rounded
        let changeHandler = ActionHandler { [weak self] _ in self?.beginRecording() }
        change.target = changeHandler
        change.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(change, "handler", changeHandler, .OBJC_ASSOCIATION_RETAIN)
        changeButton = change

        let reset = NSButton(title: "Reset", target: nil, action: nil)
        reset.bezelStyle = .rounded
        let resetHandler = ActionHandler { [weak self] _ in self?.resetShortcut() }
        reset.target = resetHandler
        reset.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(reset, "handler", resetHandler, .OBJC_ASSOCIATION_RETAIN)

        row([field, change, reset])
        riskyNote = note("")
        note("Up to three modifiers, optionally with one ordinary key. Left and right "
             + "are told apart, so \(Modifier.describe(DictationShortcut.defaultMask)) is "
             + "not the same chord as the one on the other side of the keyboard.")

        separator()
        heading("Speech")
        // Every popup here goes into a labelled row. `popup` only builds the
        // control: unlike `checkbox` and `button`, it does not add it to the
        // stack, because a bare menu with nothing beside it does not say what
        // it chooses.
        let engine = popup { [weak self] in self?.engineChanged() }
        engineMenu = engine
        row([NSTextField(labelWithString: "Engine:"), engine])
        note(Settings.dictationEngineChoice.blurb)
        let locale = popup { [weak self] in self?.localeChanged() }
        localeMenu = locale
        localeRow = row([NSTextField(labelWithString: "Language:"), locale])

        separator()
        heading("Result")
        checkbox("Type it into the app in front", Settings.dictationAutoPaste) { on in
            Settings.dictationAutoPaste = on
        }
        note("A synthetic Cmd-V, which needs the same Accessibility grant the shortcut "
             + "does. With this off the text is still copied, so you paste it yourself.")

        separator()
        heading("While dictating")
        checkbox("Show the floating pill", Settings.dictationShowHUD) { on in
            Settings.dictationShowHUD = on
        }
        note("The menu bar icon changes too, but it is 16 points wide at the top of a "
             + "screen you may not be looking at, and on a Mac with a notch it can be "
             + "hidden entirely.")
        let meter = popup { [weak self] in self?.meterChanged() }
        meterMenu = meter
        row([NSTextField(labelWithString: "Shows:"), meter])
        note(Settings.dictationMeterStyle.blurb)

        checkbox("Play a sound on start and finish", Settings.dictationSounds) { on in
            Settings.dictationSounds = on
        }
        note("The whole point of a shortcut is that you are looking at something else, "
             + "and a sound is the only feedback that needs no glance.")
        let start = soundPopup(Settings.dictationStartSound) { [weak self] in
            self?.startSoundChanged()
        }
        startMenu = start
        row([NSTextField(labelWithString: "Start:"), start,
             previewButton { Cue.preview(Settings.dictationStartSound) }])
        let done = soundPopup(Settings.dictationDoneSound) { [weak self] in
            self?.doneSoundChanged()
        }
        doneMenu = done
        row([NSTextField(labelWithString: "Done:"), done,
             previewButton { Cue.preview(Settings.dictationDoneSound) }])

        separator()
        heading("Tidying up what you said")
        buildPolish()

        separator()
        heading("History")
        historyNote = note("")
        button("Show the history file") {
            NSWorkspace.shared.activateFileViewerSelecting([DictationHistory.file])
        }
        note("Every dictation is appended to a plain JSONL file, including what the "
             + "speech model said before anything rewrote it. It is yours to grep, and "
             + "nothing else reads it: the agent cannot see your dictations.")
    }

    /// The polish half, which is a different pane on a Mac that cannot run it.
    ///
    /// A disabled checkbox with no explanation is the thing this avoids. There
    /// are three separate ways to be unable to polish and the user can act on
    /// two of them, so the reason is on screen instead of the control.
    private func buildPolish() {
        if let why = Polisher.unavailableReason {
            note(why)
            return
        }

        checkbox("Clean up punctuation and fillers", Settings.dictationPolishEnabled) { on in
            Settings.dictationPolishEnabled = on
            Task { await Polisher.shared.prewarm() }
        }
        note("Runs your words through Apple Intelligence, on this Mac, before they reach "
             + "the clipboard: punctuation and capitalisation added, um and uh removed, "
             + "paragraphs where the topic turns. It adds about a second, and it rewrites "
             + "what you said, which is why it is off until you ask for it.")
        note("It is a copy editor and never an assistant. A dictated question comes back "
             + "as a question rather than an answer, and a sentence you cut off stays cut "
             + "off. If a reply ever collapses or grows past what editing can explain, "
             + "Listen throws it away and keeps what you actually said.")

        checkbox("Also fix false starts", Settings.dictationRepairEnabled) { on in
            Settings.dictationRepairEnabled = on
        }
        note("A second pass for the case where you start a phrase, break off and say it "
             + "again: \"send me the notes the meeting notes\" becomes \"send me the "
             + "meeting notes\". It only runs on sentences that look like that, which "
             + "measured over a real history is about one dictation in ten, so the rest "
             + "pay nothing for it.")

        let field = NSTextField(string: Settings.dictationPolishInstructions)
        field.placeholderString = "British spelling. Keep it terse."
        field.delegate = self
        notesField = field
        stack.addArrangedSubview(field)
        widthCapped(field)
        note("Style notes, applied where they do not conflict with the rules above. They "
             + "change how the cleaned text reads, never what it says.")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        poll?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Only when it changed. `refresh` rebuilds menus and re-reads
                // the history file, and doing that once a second under somebody
                // reading the pane would close a popup they had just opened.
                guard Permissions.accessibility != self.lastGrant else { return }
                self.refresh()
            }
        }
        // `.common`, so it keeps ticking while a menu is open, which is exactly
        // when somebody is picking a sound and has not noticed the warning.
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    /// Stops the poll, and never leaves the tap in record mode: a pane that goes
    /// away mid-capture would otherwise swallow every keystroke on the Mac until
    /// the next launch.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        poll?.invalidate()
        poll = nil
        pendingCommit?.cancel()
        Dictation.shared.endRecordingShortcut()
        changeButton?.isEnabled = true
    }

    /// What the last refresh saw, so the poll can do nothing most seconds.
    private var lastGrant = false

    override func refresh() {
        shortcutField?.stringValue = DictationShortcut.description
        updateRiskyNote()
        updateAccessibility()

        if let engineMenu {
            engineMenu.removeAllItems()
            engineMenu.addItem(withTitle: Settings.DictationEngineChoice.parakeet.title)
            if Settings.appleDictationAvailable {
                engineMenu.addItem(withTitle: Settings.DictationEngineChoice.apple.title)
            }
            engineMenu.selectItem(withTitle: Settings.dictationEngineChoice.title)
        }
        // Only Apple's engine takes a locale. mlx-audio's `language` parameter is
        // copied into its output struct and never reaches the decoder, so a
        // picker for Parakeet would be a control that silently does nothing.
        localeRow?.isHidden = Settings.dictationEngineChoice != .apple
        if Settings.dictationEngineChoice == .apple { loadLocales() }

        if let meterMenu {
            meterMenu.removeAllItems()
            meterMenu.addItems(withTitles: MeterStyle.selectable.map(\.title))
            meterMenu.selectItem(withTitle: Settings.dictationMeterStyle.title)
        }
        startMenu?.selectItem(withTitle: Settings.dictationStartSound)
        doneMenu?.selectItem(withTitle: Settings.dictationDoneSound)

        let recent = DictationHistory.recent(200)
        if recent.isEmpty {
            historyNote?.stringValue = "Nothing dictated yet."
        } else {
            let words = recent.reduce(0) { $0 + $1.text.split(separator: " ").count }
            let last = recent[0].text.replacingOccurrences(of: "\n", with: " ")
            historyNote?.stringValue =
                "\(recent.count) dictation\(recent.count == 1 ? "" : "s"), "
                + "\(words) word\(words == 1 ? "" : "s"). "
                + "Most recent: \(last.count > 60 ? String(last.prefix(59)) + "…" : last)"
        }
    }

    // MARK: - Accessibility

    /// Three states, and only one of them is quiet.
    private func updateAccessibility() {
        let granted = Permissions.accessibility
        lastGrant = granted
        // The sidebar's badge depends on this pane's switch as much as on the
        // grant: turning dictation off is what makes a missing Accessibility
        // grant stop being a fault.
        LibraryWindow.shared.refreshSettingsBadges()
        guard let accessibilityNote, let grantButton else { return }

        // Switched off: the permission is not the thing standing in the way, so
        // saying anything about it here would be answering a question nobody
        // asked. The row goes away entirely rather than greying out, because a
        // disabled warning still reads as a warning.
        guard Settings.dictationEnabled else {
            accessibilityNote.isHidden = true
            grantButton.isHidden = true
            return
        }
        accessibilityNote.isHidden = false

        // The same row, the same symbol and the same colours as the Permissions
        // pane, because it is the same fact. Two spellings of one state is how
        // somebody ends up believing the two screens disagree.
        if granted {
            accessibilityNote.set(
                .granted,
                "Accessibility is granted. \(DictationShortcut.description) starts a "
                + "dictation in any app.")
            // Nothing to do, so nothing to press. The Permissions tab is where
            // somebody goes to take a grant away, and offering that here would
            // be a button whose only use is breaking the feature it sits under.
            grantButton.isHidden = true
        } else {
            accessibilityNote.set(
                .blocked,
                "Accessibility is not granted, so the shortcut does nothing. Listen "
                + "cannot see the keys or type for you until it is. Switch Listen on in "
                + "Privacy & Security, Accessibility: it takes effect immediately and "
                + "you do not have to restart anything.")
            grantButton.isHidden = false
        }
    }

    // MARK: - Shortcut

    private func updateRiskyNote() {
        guard let riskyNote else { return }
        if DictationShortcut.isRisky(DictationShortcut.mask, DictationShortcut.keyCode) {
            riskyNote.stringValue = "A single modifier fires every time you reach for it, "
                + "including in the middle of a word. Workable on a keyboard with a key "
                + "to spare, and worth knowing before you wonder why dictation keeps "
                + "starting."
            riskyNote.isHidden = false
        } else {
            riskyNote.isHidden = true
        }
    }

    /// Put the event tap into record mode until a chord is finished.
    ///
    /// The commit waits 0.45 s after everything is released rather than firing on
    /// the first all-clear. Three keys rarely go down in one event, and a brief
    /// gap between presses would otherwise cut the chord short. The field shows
    /// the *widest* chord seen rather than what is held right now, or it counts
    /// back down as the keys come up and then jumps again when it commits.
    private func beginRecording() {
        widest = 0
        pendingCommit = nil
        changeButton?.isEnabled = false
        shortcutField?.stringValue = "Press the keys…"

        Dictation.shared.beginRecordingShortcut { [weak self] flags, keyCode in
            guard let self else { return }
            let held = flags.rawValue & Modifier.tracked

            // A character key ends the chord immediately: there is nothing more
            // to wait for, and holding it would just repeat.
            if let keyCode {
                self.pendingCommit?.cancel()
                self.commit(held, keyCode)
                return
            }

            if held != 0 {
                self.pendingCommit?.cancel()
                self.pendingCommit = nil
                if held.nonzeroBitCount > self.widest.nonzeroBitCount,
                   held.nonzeroBitCount <= DictationShortcut.maxKeys {
                    self.widest = held
                }
                self.shortcutField?.stringValue = Modifier.describe(self.widest)
                    + (held.nonzeroBitCount > DictationShortcut.maxKeys
                       ? "   (max \(DictationShortcut.maxKeys))" : "")
                return
            }

            self.pendingCommit?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.commit(self.widest, nil)
            }
            self.pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        }
    }

    private func commit(_ mask: UInt64, _ code: Int?) {
        Dictation.shared.endRecordingShortcut()
        changeButton?.isEnabled = true
        if DictationShortcut.isUsable(mask, code) {
            DictationShortcut.set(mask: mask, keyCode: code)
        } else {
            NSSound.beep()
        }
        shortcutField?.stringValue = DictationShortcut.description
        updateRiskyNote()
    }

    private func resetShortcut() {
        Dictation.shared.endRecordingShortcut()
        changeButton?.isEnabled = true
        DictationShortcut.set(mask: DictationShortcut.defaultMask, keyCode: nil)
        shortcutField?.stringValue = DictationShortcut.description
        updateRiskyNote()
    }

    // MARK: - Menus

    private func popup(_ action: @escaping () -> Void) -> NSPopUpButton {
        let menu = NSPopUpButton()
        let handler = ActionHandler { _ in action() }
        menu.target = handler
        menu.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(menu, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        return menu
    }

    /// A menu of the system sounds, plus None for silencing one cue without
    /// losing the other.
    private func soundPopup(_ selected: String, _ action: @escaping () -> Void) -> NSPopUpButton {
        let menu = popup(action)
        menu.addItem(withTitle: Cue.none)
        menu.menu?.addItem(.separator())
        menu.addItems(withTitles: Cue.available)
        menu.selectItem(withTitle: selected)
        return menu
    }

    private func previewButton(_ play: @escaping () -> Void) -> NSButton {
        let button = NSButton(title: "Play", target: nil, action: nil)
        button.bezelStyle = .rounded
        let handler = ActionHandler { _ in play() }
        button.target = handler
        button.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
        return button
    }

    private func loadLocales() {
        guard #available(macOS 26.0, *), let localeMenu else { return }
        Task { @MainActor in
            let installed = await AppleEngine.installedLocales()
            localeMenu.removeAllItems()
            localeMenu.addItem(withTitle: "Automatic")
            for locale in installed.sorted(by: { $0.identifier < $1.identifier }) {
                let tag = locale.identifier(.bcp47)
                localeMenu.addItem(withTitle:
                    (Locale.current.localizedString(forIdentifier: locale.identifier) ?? tag)
                    + "  (\(tag))")
                localeMenu.lastItem?.representedObject = tag
            }
            let saved = Settings.dictationAppleLocale
            let match = localeMenu.itemArray.first {
                ($0.representedObject as? String) == saved
            }
            localeMenu.select(match ?? localeMenu.itemArray.first)
        }
    }

    // MARK: - Actions

    private func engineChanged() {
        guard let title = engineMenu?.titleOfSelectedItem else { return }
        Settings.dictationEngineChoice =
            title == Settings.DictationEngineChoice.apple.title ? .apple : .parakeet
        // The engine is the model, so the loaded one has to go. `modelChanged`
        // drops it and warms whichever was just chosen.
        Dictation.shared.modelChanged()
        rebuild()
    }

    private func localeChanged() {
        Settings.dictationAppleLocale = localeMenu?.selectedItem?.representedObject as? String
        Dictation.shared.modelChanged()
    }

    private func meterChanged() {
        guard let title = meterMenu?.titleOfSelectedItem,
              let style = MeterStyle.allCases.first(where: { $0.title == title }) else { return }
        Settings.dictationMeterStyle = style
        rebuild()
    }

    private func startSoundChanged() {
        guard let name = startMenu?.titleOfSelectedItem else { return }
        Settings.dictationStartSound = name
        Cue.preview(name)
    }

    private func doneSoundChanged() {
        guard let name = doneMenu?.titleOfSelectedItem else { return }
        Settings.dictationDoneSound = name
        Cue.preview(name)
    }

    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField, field === notesField else { return }
        Settings.dictationPolishInstructions = field.stringValue
    }
}
