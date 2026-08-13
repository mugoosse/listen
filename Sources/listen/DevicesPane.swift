import AppKit

/// Settings, Devices: the CloudKit account and the devices seen in its zone.
///
/// There is no pairing surface here. The shared key arrives through iCloud
/// Keychain and every device exchanges sealed records through CloudKit, so a
/// QR code, a network address and a second connected-device registry would all
/// describe a transport that no longer exists.
final class DevicesPane: Pane {
    private var cloudStatus: NSTextField?
    private var cloudDevices: NSTextField?
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

        if Settings.cloudSync {
            let syncNow = NSButton(title: "Sync now", target: self,
                                   action: #selector(syncNowPressed(_:)))
            syncNow.bezelStyle = .rounded
            stack.addArrangedSubview(row([syncNow]))
        }

        let toggle = NSButton(checkboxWithTitle: "Sync this library through iCloud",
                              target: self, action: #selector(toggleCloud(_:)))
        toggle.state = Settings.cloudSync ? .on : .off
        stack.addArrangedSubview(toggle)
        separator()
    }

    override func refresh() { refreshCloud() }

    private func refreshCloud() {
        let host = CloudSyncHost.shared
        let status = cloudStatusText(host)
        if cloudStatus?.stringValue != status { cloudStatus?.stringValue = status }
        let devices = deviceListText(host)
        if cloudDevices?.stringValue != devices { cloudDevices?.stringValue = devices }
    }

    private func cloudStatusText(_ host: CloudSyncHost) -> String {
        guard Settings.cloudSync else {
            return "Off. This Mac keeps its local library, but no other device can "
                + "learn about changes until iCloud sync is turned on."
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
            rows.append("  \(device.name) (\(device.kind)), \(device.seenAgo)")
        }
        rows.append("")
        rows.append("A device that has said nothing for 30 days is dropped from this list by itself.")
        return rows.joined(separator: "\n")
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
        Settings.cloudSync = sender.state == .on
        if Settings.cloudSync { CloudSyncHost.shared.startIfEnabled() }
        else { CloudSyncHost.shared.stop() }
        rebuild()
    }
}
