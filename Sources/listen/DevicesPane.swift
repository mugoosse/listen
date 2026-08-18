import AppKit
import ListenKit

/// Settings, Devices: the CloudKit account and the devices seen in its zone.
///
/// There is no pairing surface here. The shared key arrives through iCloud
/// Keychain and every device exchanges sealed records through CloudKit, so a
/// QR code, a network address and a second connected-device registry would all
/// describe a transport that no longer exists.
final class DevicesPane: Pane {
    private var cloudStatus: NSTextField?
    private var cloudDevices: NSTextField?
    private var audioStatus: NSTextField?
    private var poll: Timer?

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

    override func build() {
        heading("iCloud")

        let host = CloudSyncHost.shared
        cloudStatus = note(cloudStatusText(host))
        cloudDevices = note(deviceListText(host))

        if Settings.cloudSyncApplies {
            let syncNow = NSButton(title: "Sync now", target: self,
                                   action: #selector(syncNowPressed(_:)))
            syncNow.bezelStyle = .rounded
            let saveKey = NSButton(title: "Save your key\u{2026}", target: self,
                                   action: #selector(showKey(_:)))
            saveKey.bezelStyle = .rounded
            stack.addArrangedSubview(row([syncNow, saveKey]))

            // Here rather than beside the copies in Storage, although it is a
            // thing to write down. What the key opens is what iCloud holds, so
            // it belongs with iCloud: the copies on this Mac need no key at all
            // and never will.
            note("What iCloud holds is sealed with a key that only your devices "
                 + "have. Keep a copy somewhere safe, like a password manager, "
                 + "so you can still open it if you ever lose them all.")
        }

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
        separator()

        // Audio, and the switch that decides whether this Mac keeps any.
        //
        // Here rather than in Storage, although it is a decision about the
        // disk, because it is only legible beside the device list above: what
        // makes "do not keep audio" safe is another device saying it is
        // keeping it, and that sentence is a few lines up. A switch in Storage
        // would be a delete button with its reason on another screen.
        //
        // **After the sync checkbox and not before it.** Between the key
        // sentence and that checkbox, the checkbox read as part of this
        // section: "Sync this library through iCloud" appeared to be one of
        // the audio settings. Seen on screen rather than reasoned about.
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
            note("On, this Mac fetches the audio for every recording, so any meeting "
                 + "can be played back and transcribed again here. Off, it frees its "
                 + "copy as soon as another device that is keeping audio says it has "
                 + "those bytes, and never before: the last copy of a recording is "
                 + "never deleted to save space.")
            separator()
        }
    }

    override func refresh() { refreshCloud() }

    private func refreshCloud() {
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

    private func cloudStatusText(_ host: CloudSyncHost) -> String {
        guard Settings.cloudSync else {
            return "Off. This Mac keeps its local library, but no other device can "
                + "learn about changes until iCloud sync is turned on."
        }
        // Said as its own sentence rather than folded into "Off", because the
        // two have different repairs and this one is usually a surprise: the
        // Mac is a syncing Mac, and the library in front of you is not the one
        // it syncs. Both paths are named, since the whole confusion is which
        // library is open.
        guard Settings.cloudSyncApplies else {
            return "Off for this library. iCloud sync is on for \(short(Settings.cloudSyncLibrary)), "
                + "and the library open now is \(short(ListenKit.Library.mac().root.path)). "
                + "Nothing here is sent anywhere. Tick the box below to sync this one instead."
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
            lines.append("Last synced \(when): \(host.lastReport?.summary ?? "nothing to do")")
        } else {
            lines.append("Waiting for the first sync.")
        }

        if let error = host.lastReport?.errors.first {
            lines.append("")
            lines.append("Last error: \(error)")
        }
        if let conflicts = host.lastReport?.conflicts, !conflicts.isEmpty {
            lines.append("")
            lines.append("Both sides edited, so neither was touched: "
                         + conflicts.joined(separator: ", "))
        }

        lines.append("")
        lines.append("Your recordings stay on the Mac that made them. Everything "
                     + "else is sealed with a key that never leaves your devices, "
                     + "so Apple stores it and cannot read it.")
        return lines.joined(separator: "\n")
    }

    private func deviceListText(_ host: CloudSyncHost) -> String {
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
        if Settings.cloudSyncApplies { CloudSyncHost.shared.startIfEnabled() }
        else { CloudSyncHost.shared.stop() }
        rebuild()
    }
}
