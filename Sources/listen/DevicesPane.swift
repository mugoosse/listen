import AppKit
import ListenKit

/// Settings, Sync: one switch, one status line, and the devices on the account.
///
/// There is no pairing surface here. The shared key is created by the first
/// Mac that turns sync on and arrives everywhere else through iCloud Keychain,
/// so a QR code, a network address and a second connected-device registry
/// would all describe a transport that does not exist. The one fallback is
/// typing the key, for an account whose iCloud Keychain is off, and it lives
/// behind a button that only appears while the key is what is missing.
///
/// The pane used to open with two status paragraphs, two buttons and a key
/// warning before the switch itself, and a tester's honest report was that
/// they could not find how to turn sync on. The switch comes first now, and
/// everything below it appears only in the states where it can do something.
final class DevicesPane: Pane {
    private var cloudStatus: NSTextField?
    private var cloudDevices: NSTextField?
    private var audioStatus: NSTextField?
    private var poll: Timer?
    /// What the pane was built for, so the poll can tell a value change (update
    /// a label) from a state change (rebuild the pane).
    private var builtShape = ""

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshCloud()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshCloud() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        poll?.invalidate()
        poll = nil
    }

    /// Everything that decides which controls exist. Compared by the poll:
    /// a change here is a rebuild, anything else is a label update.
    ///
    /// The key has three phases here, not two. Between the toggle going on
    /// and the first pass answering, this Mac may be about to *create* the
    /// key, and an Enter key button in that window would ask somebody to go
    /// hunting for a code that is seconds from existing.
    private func keyPhase() -> String {
        if KeyStore.shared.load() != nil { return "have" }
        switch CloudSyncHost.shared.keyState {
        case .unknown, .present: return "settingUp"
        case .onItsWay, .unreachable: return "missing"
        }
    }

    private func shape() -> String {
        [String(Settings.cloudSyncApplies), keyPhase()].joined(separator: "|")
    }

    override func build() {
        builtShape = shape()
        heading("iCloud")

        // The switch first. It is the one control this pane exists for, and
        // everything else on the pane is a consequence of its position.
        let toggle = NSButton(checkboxWithTitle: "Sync this library through iCloud",
                              target: self, action: #selector(toggleCloud(_:)))
        // Ticked for the library on screen, not for the install. With sync on
        // for the real library and a scratch one open, the box used to read
        // "on" over a pane where nothing was syncing, which is the one reading
        // that would have prevented this whole guard being needed. Ticking it
        // here consents to *this* library, because the setter stamps the path.
        toggle.state = Settings.cloudSyncApplies ? .on : .off
        // A forced value gets a disabled control and a sentence naming who
        // decided, rather than a checkbox that snaps back.
        if Settings.isForced("cloudSync") {
            toggle.isEnabled = false
            stack.addArrangedSubview(toggle)
            note("iCloud sync is set by your organisation's device profile "
                 + "and cannot be changed here.")
        } else {
            stack.addArrangedSubview(toggle)
        }

        let host = CloudSyncHost.shared
        cloudStatus = note(cloudStatusText(host))

        if Settings.cloudSyncApplies {
            switch keyPhase() {
            case "have":
                let syncNow = NSButton(title: "Sync now", target: self,
                                       action: #selector(syncNowPressed(_:)))
                syncNow.bezelStyle = .rounded
                let saveKey = NSButton(title: "Back up key\u{2026}", target: self,
                                       action: #selector(showKey(_:)))
                saveKey.bezelStyle = .rounded
                stack.addArrangedSubview(row([syncNow, saveKey]))
                // One sentence, not a paragraph: the fuller warning is inside
                // the Back up key dialog, beside the key it is about.
                note("iCloud holds only what your key seals, so Apple cannot read "
                     + "it. Keep a copy of the key in a password manager.")
            case "missing":
                // The key is what is missing, so the way to supply it by hand
                // is offered here and nowhere else. iCloud Keychain is the
                // ordinary route and needs no button.
                let enter = NSButton(title: "Enter key\u{2026}", target: self,
                                     action: #selector(enterKey(_:)))
                enter.bezelStyle = .rounded
                stack.addArrangedSubview(row([enter]))
                note("The key normally arrives by itself through iCloud Keychain. "
                     + "Enter it only if that is off, or if the device that has "
                     + "the key is gone: it is the code behind Back up key on "
                     + "your other device, or the copy in your password manager.")
            default:
                // Setting up: the first pass is deciding whether this Mac
                // creates the key or receives it, and nothing here can help
                // until it has.
                break
            }

            cloudDevices = note(deviceListText(host))
        }
        separator()

        // Audio, and the switch that decides whether this Mac keeps any.
        //
        // Here rather than in Storage, although it is a decision about the
        // disk, because it is only legible beside the device list above: what
        // makes "do not keep audio" safe is another device saying it is
        // keeping it, and that sentence is a few lines up. A switch in Storage
        // would be a delete button with its reason on another screen.
        if Settings.cloudSyncApplies {
            heading("Audio")
            let keep = NSButton(checkboxWithTitle: "Keep a copy of every recording's audio "
                                + "on this Mac",
                                target: self, action: #selector(toggleKeepAudio(_:)))
            keep.state = Settings.keepAudio ? .on : .off
            if Settings.isForced("keepAudio") {
                keep.isEnabled = false
                stack.addArrangedSubview(keep)
                note("Whether this Mac keeps audio is set by your organisation's "
                     + "device profile and cannot be changed here.")
            } else {
                stack.addArrangedSubview(keep)
            }
            audioStatus = note(audioStatusText())
            note("On, this Mac fetches every recording's audio, so any meeting "
                 + "can be played back and transcribed again here. Off, it frees "
                 + "its copy once another device that is keeping audio has those "
                 + "bytes: the last copy is never deleted to save space.")
            separator()
        }
    }

    override func refresh() { refreshCloud() }

    private func refreshCloud() {
        // A state change replaces the controls; a value change updates them.
        // Without the split, either the pane never grew a Sync now button
        // after the key arrived, or it rebuilt every two seconds under the
        // cursor of somebody about to click one.
        guard shape() == builtShape else {
            cloudStatus = nil; cloudDevices = nil; audioStatus = nil
            rebuild()
            return
        }
        let host = CloudSyncHost.shared
        let status = cloudStatusText(host)
        if cloudStatus?.stringValue != status { cloudStatus?.stringValue = status }
        let devices = deviceListText(host)
        if cloudDevices?.stringValue != devices { cloudDevices?.stringValue = devices }
        if let audioStatus {
            let audio = audioStatusText()
            if audioStatus.stringValue != audio { audioStatus.stringValue = audio }
        }
    }

    /// What this Mac holds, and the warning that matters.
    ///
    /// The count of recordings nothing has reported keeping is the whole
    /// reason the devices tell each other what they hold. It is said as what
    /// was reported rather than as what is true, because a Mac shut in a
    /// drawer still has whatever it had and is simply not saying so.
    private func audioStatusText() -> String {
        let recordings = Recording.all()
        let here = recordings.filter(\.hasAudio)
        var lines = ["Audio for \(here.count) of \(recordings.count) recordings is on "
                     + "this Mac, using "
                     + ModelChoice.humanBytes(here.reduce(0) { $0 + Self.audioSize(of: $1) })
                     + "."]
        let unheld = CloudSyncHost.unheld()
        if !unheld.isEmpty {
            lines.append("")
            lines.append("\(unheld.count) recording\(unheld.count == 1 ? " has" : "s have") "
                         + "no device reporting that it keeps the audio. Turn Keep audio "
                         + "on here, or on whichever device still has it.")
        }
        return lines.joined(separator: "\n")
    }

    private static func audioSize(of recording: Recording) -> Int64 {
        recording.audioFiles.reduce(0) { total, url in
            total + Int64((try? FileManager.default.attributesOfItem(
                atPath: url.path)[.size] as? Int) ?? 0)
        }
    }

    @objc private func toggleKeepAudio(_ sender: NSButton) {
        guard !Settings.isForced("keepAudio") else { return }
        Settings.keepAudio = sender.state == .on
        // Say so at once. Every other device's reclaim rule reads this Mac's
        // heartbeat, and a switch whose effect waits out a two minute poll is
        // one somebody presses twice.
        CloudSyncHost.shared.syncSoon()
        refreshCloud()
    }

    /// A path as somebody would say it out loud, which is the same shortening
    /// the Storage pane makes on the library it prints.
    private func short(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// One short answer per state, directly under the switch. What went wrong
    /// before was not that the pane said too little: it printed the keyless
    /// report as "Last synced just now: No sync key yet." and again as "Last
    /// error: No sync key yet.", which reads as a malfunction, above two
    /// buttons that silently did nothing without the key.
    private func cloudStatusText(_ host: CloudSyncHost) -> String {
        guard Settings.cloudSync else {
            return "Off. Recordings, transcripts and notes stay on this Mac."
        }
        // Said as its own sentence rather than folded into "Off", because the
        // two have different repairs and this one is usually a surprise: the
        // Mac is a syncing Mac, and the library in front of you is not the one
        // it syncs. Both paths are named, since the whole confusion is which
        // library is open.
        guard Settings.cloudSyncApplies else {
            return "Off for this library. iCloud sync is on for \(short(Settings.cloudSyncLibrary)), "
                + "and the library open now is \(short(ListenKit.Library.mac().root.path)). "
                + "Nothing here is sent anywhere. Tick the box above to sync this one instead."
        }

        if KeyStore.shared.load() == nil {
            // Which sentence depends on why, and the host knows. Before the
            // first pass answers, the honest line is that it is being set up.
            switch host.keyState {
            case .onItsWay:
                return "Waiting for your sync key. It arrives by itself through "
                    + "iCloud Keychain from the device already syncing this "
                    + "account, usually within a minute or two."
            case .unreachable(let why):
                return "Could not reach iCloud: \(why)"
            case .unknown, .present:
                return "Setting up\u{2026}"
            }
        }

        var lines: [String] = []
        if let progress = host.progress {
            lines.append("Syncing now: \(progress)")
        } else if let run = host.lastRun {
            let ago = Date().timeIntervalSince(run)
            let when: String
            if ago < 60 { when = "just now" }
            else if ago < 3600 { when = "\(Int(ago / 60)) minutes ago" }
            else if ago < 86_400 { when = "\(Int(ago / 3600)) hours ago" }
            else { when = "\(Int(ago / 86_400)) days ago" }
            lines.append("On. Last synced \(when): \(host.lastReport?.summary ?? "nothing to do").")
        } else {
            lines.append("On. Waiting for the first sync.")
        }

        if let error = host.lastReport?.errors.first {
            lines.append("The last pass hit a problem: \(error)")
        }
        if let conflicts = host.lastReport?.conflicts, !conflicts.isEmpty {
            lines.append("Both sides edited, so neither was touched: "
                         + conflicts.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    private func deviceListText(_ host: CloudSyncHost) -> String {
        guard KeyStore.shared.load() != nil else {
            return "No devices have checked in yet."
        }
        guard !host.devices.isEmpty else { return "No devices have checked in yet." }
        var rows = ["On this account:"]
        for device in host.devices {
            // What it is keeping, which is the half of this list that decides
            // anything. A device that has never said either way is a build
            // that predates the question, and saying nothing about it is
            // better than guessing on its behalf.
            var row = "  \(device.name) (\(device.kind)), \(device.seenAgo)"
            if let holds = device.holdsAudio {
                row += device.keeps ? ", keeping audio for \(holds.count)"
                                    : ", not keeping audio (\(holds.count) left)"
            }
            rows.append(row)
        }
        rows.append("")
        rows.append("A device that has said nothing for 30 days is dropped from this list by itself.")
        return rows.joined(separator: "\n")
    }


    /// Show the key, once, behind a press.
    ///
    /// Never drawn on the pane itself. It is short enough to fit in any
    /// screenshot of this window, and anybody holding it can read every
    /// transcript the container has, so a settings screen that displays it
    /// by default is a settings screen nobody can safely photograph.
    @objc private func showKey(_ sender: NSButton) {
        guard let key = KeyStore.shared.load() else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Your key"
        alert.informativeText = key.code + "\n\nThis opens everything Listen "
            + "keeps in iCloud. Treat it the way you would treat the "
            + "recordings it opens."
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            // The general pasteboard is the least private place on this Mac:
            // every process can read it and Universal Clipboard carries it to
            // nearby devices. The concealed type asks clipboard managers not
            // to keep it, and the timer takes it back after a minute. The
            // changeCount guard is what makes the timer safe: it must never
            // destroy something the user copied afterwards.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(key.code, forType: .string)
            pasteboard.setString("", forType:
                NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            let written = pasteboard.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if NSPasteboard.general.changeCount == written {
                    NSPasteboard.general.clearContents()
                }
            }
        }
    }

    /// Type the key, for the account whose iCloud Keychain cannot carry it.
    ///
    /// Validated before it is kept: 32 bytes of Base32 or nothing. Writing an
    /// almost-right code into the keychain would have every later pass fail
    /// to open records with no hint that the key is the reason.
    @objc private func enterKey(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "Enter your sync key"
        alert.informativeText = "The code behind Back up key on your other "
            + "device, or the copy in your password manager."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "XXXX-XXXX-XXXX-\u{2026}"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Use this key")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let key = PairingKey(code: field.stringValue) else {
            let wrong = NSAlert()
            wrong.messageText = "That is not a complete key"
            wrong.informativeText = "A key is 52 letters and digits, usually "
                + "written in groups of four. Copy it whole and try again."
            wrong.runModal()
            return
        }
        KeyStore.shared.save(key)
        Task { @MainActor in
            await CloudSyncHost.shared.syncNow()
            self.refreshCloud()
        }
        refreshCloud()
    }

    @objc private func syncNowPressed(_ sender: NSButton) {
        sender.isEnabled = false
        sender.title = "Syncing…"
        Task { @MainActor in
            await CloudSyncHost.shared.syncNow()
            sender.isEnabled = true
            sender.title = "Sync now"
            self.refreshCloud()
        }
    }

    @objc private func toggleCloud(_ sender: NSButton) {
        guard !Settings.isForced("cloudSync") else { return }
        // Turning it on consents to the library that is open, which is what
        // `cloudSync`'s setter stamps. Turning it off is the install's answer
        // and not this library's: there is one container, and "stop sending my
        // meetings" has to mean all of them.
        Settings.cloudSync = sender.state == .on
        ActivityLog.append(Settings.cloudSync ? "sync_enabled" : "sync_disabled")
        if Settings.cloudSync { Telemetry.featureUsed(.syncEnabled) }
        if Settings.cloudSyncApplies { CloudSyncHost.shared.startIfEnabled() }
        else { CloudSyncHost.shared.stop() }
        rebuild()
    }
}
