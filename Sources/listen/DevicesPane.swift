import AppKit
import CoreImage

/// Settings, Devices: what is paired with this Mac, and how to add one.
///
/// Listen does not run the sync itself. `listen-sync` does, as a LaunchAgent,
/// and this pane is a reader of the two files that agent keeps beside the
/// library: `.pairing-key` and `devices.json`. That split is deliberate. The
/// recorder should not have to hold a socket open to be useful, and a sync
/// daemon should be stoppable without stopping the recorder.
///
/// So everything here degrades to an explanation when the agent is not
/// installed, rather than to an empty list that looks like a bug.
final class DevicesPane: Pane {
    private var listStack: NSStackView?
    private var poll: Timer?
    /// What the list last drew, so a redraw only happens when something moved.
    /// Rebuilding the rows every tick would take the mouse out from under a
    /// button somebody was about to press.
    private var drawn: String = ""

    /// A device appears while this pane is open, not before it.
    ///
    /// The whole point of the screen is that you are looking at it while you
    /// scan the code on your phone, so a list read once when the pane was built
    /// is a list that is always one pairing out of date. `refresh` fires when
    /// the pane is shown and nothing fires after that, so this polls the file
    /// the agent writes.
    override func viewDidAppear() {
        super.viewDidAppear()
        fillList()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fillList() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        poll?.invalidate()
        poll = nil
    }

    override func build() {
        heading("Add a device")

        guard let code = DeviceSync.pairingCode() else {
            note("The sync agent is not set up on this Mac yet.\n\n"
                 + "Listen for iPhone talks to a small helper called `listen-sync`, "
                 + "which serves this library on your local network. Until it is "
                 + "installed there is nothing for a phone to pair with.")
            separator()
            unavailable()
            return
        }

        let url = DeviceSync.pairingURL(code: code)
        if let image = DevicesPane.qr(url, side: 200) {
            let view = NSImageView(image: image)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            // Nearest-neighbour, because a QR resampled smoothly is a QR with
            // grey edges, and a camera reading it off a screen has enough to
            // contend with already.
            view.imageScaling = .scaleNone
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 200),
                view.heightAnchor.constraint(equalToConstant: 200),
            ])
            stack.addArrangedSubview(view)
        }

        note("In Listen on your iPhone, open Settings and scan this. It carries "
             + "the key and this Mac's address, so there is nothing to type.\n\n"
             + "Anyone who scans it can read every transcript in this library, so "
             + "treat it the way you would treat the screen it is on.")

        let reveal = button("Copy the code instead") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
        }
        let rotate = button("Forget every device and start again") { [weak self] in
            let alert = NSAlert()
            alert.messageText = "Start again with a new key?"
            alert.informativeText = "Every iPhone paired with this Mac stops "
                + "syncing until it scans the new code. Nothing already on this "
                + "Mac is deleted."
            alert.addButton(withTitle: "New key")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            DeviceSync.rotate()
            self?.redrawPane()
        }
        rotate.contentTintColor = .systemRed
        stack.addArrangedSubview(row([reveal, rotate]))

        separator()
        heading("Connected")

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 12
        stack.addArrangedSubview(list)
        widthCapped(list)
        listStack = list
        drawn = ""
        fillList()
    }

    /// Draw the whole pane again, for the two buttons that change what it says.
    /// Named away from `rebuild`, which `Pane` already defines.
    private func redrawPane() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        build()
    }

    private func unavailable() {
        heading("Connected")
        note("Nothing, because nothing is serving this library yet.")
    }

    private func fillList() {
        guard let listStack else { return }
        let devices = DeviceSync.devices()
        let signature = devices.map { "\($0.id)\($0.revoked)\($0.lastSeen)" }.joined()
        guard signature != drawn else { return }
        drawn = signature
        for view in listStack.arrangedSubviews { view.removeFromSuperview() }
        guard !devices.isEmpty else {
            let empty = NSTextField(labelWithString:
                "No iPhone has connected yet. Scan the code above.")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 11)
            listStack.addArrangedSubview(empty)
            return
        }

        for device in devices {
            listStack.addArrangedSubview(rowFor(device))
        }
    }

    private func rowFor(_ device: DeviceSync.Device) -> NSView {
        let icon = NSImageView(image: NSImage(
            systemSymbolName: device.revoked ? "iphone.slash" : "iphone",
            accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = device.revoked ? .tertiaryLabelColor : .controlAccentColor

        let name = NSTextField(labelWithString: device.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        if device.revoked { name.textColor = .tertiaryLabelColor }

        let detail = NSTextField(labelWithString: device.revoked
            ? "Removed. It cannot sync until it pairs again."
            : "Last synced \(device.lastSeenPhrase)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let action = button(device.revoked ? "Forget" : "Remove") { [weak self] in
            if device.revoked {
                DeviceSync.forget(device.id)
            } else {
                let alert = NSAlert()
                alert.messageText = "Remove \(device.name)?"
                // Say what removal can and cannot do. It stops the Mac
                // answering; it does not reach into the phone.
                alert.informativeText = "This Mac stops answering it. Anything "
                    + "already synced stays on the phone, and this cannot delete "
                    + "it from there.\n\nIf the phone was lost, also use "
                    + "\"Forget every device and start again\", because a removed "
                    + "device still holds the key."
                alert.addButton(withTitle: "Remove")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                DeviceSync.revoke(device.id)
            }
            self?.fillList()
        }
        if !device.revoked { action.contentTintColor = .systemRed }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let line = NSStackView(views: [icon, text, spacer, action])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.spacing = 10
        return line
    }

    override func refresh() { drawn = ""; fillList() }

    /// A QR, drawn at whole-pixel scale.
    static func qr(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        // Integer scale only. A fractional one resamples module edges into
        // greys, which is the difference between a code that scans first time
        // and one somebody waves a phone at.
        let scale = max(1, floor(side / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
