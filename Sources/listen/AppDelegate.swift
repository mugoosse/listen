import AppKit

/// The app itself: menu bar, capture control, and the confirm step.
@MainActor
final class App: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem?
    private let indicator = RecordingIndicator()
    /// The recording waiting for a Keep or Discard, if any.
    private var awaitingConfirm: Recording?

    func applicationDidFinishLaunching(_ note: Notification) {
        trace("launched, build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
        try? Library.prepare()

        // Anything nobody ever answered for, gone after 24 hours. Swept at
        // launch rather than on a timer: the app is not always running, and a
        // sweep that only happens while it is would never fire for the case it
        // exists to handle.
        Library.sweepStaging()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Listen")
        item.button?.image?.isTemplate = true
        status = item
        rebuildMenu()

        Capture.shared.onChange = { [weak self] in self?.rebuildMenu() }

        // A capture left staged by a crash is offered rather than resumed: the
        // audio is on disk and playable thanks to WAVWriter's rolling header,
        // so the only open question is whether the user wants it.
        if let orphan = Recording.staged().first {
            offerConfirm(orphan)
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        let recording = Capture.shared.isRecording

        if recording {
            let elapsed = Capture.shared.elapsed
            menu.addItem(withTitle: "Recording, \(Self.clock(elapsed))",
                         action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(withTitle: "Stop Recording",
                         action: #selector(stopRecording), keyEquivalent: "").target = self
        } else {
            menu.addItem(withTitle: "Start Recording",
                         action: #selector(startRecording), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        let count = Recording.all().count
        menu.addItem(withTitle: count == 1 ? "1 recording" : "\(count) recordings",
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(withTitle: "Reveal Library in Finder",
                     action: #selector(revealLibrary), keyEquivalent: "").target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Listen", action: #selector(quit), keyEquivalent: "q")
            .target = self
        status?.menu = menu

        status?.button?.image = NSImage(
            systemSymbolName: recording ? "waveform.circle.fill" : "waveform",
            accessibilityDescription: recording ? "Listen, recording" : "Listen")
        status?.button?.image?.isTemplate = true

        if recording {
            indicator.show(.recording)
        } else if awaitingConfirm == nil {
            indicator.hide()
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Capture

    @objc private func startRecording() {
        do {
            _ = try Capture.shared.start()
            if !Capture.shared.warnings.isEmpty {
                // Say which track failed rather than letting someone discover
                // at playback that half the meeting is missing.
                notify("Recording with one track only",
                       Capture.shared.warnings.joined(separator: "\n"))
            }
        } catch {
            notify("Could not start recording", error.localizedDescription)
        }
    }

    @objc private func stopRecording() {
        guard let recording = Capture.shared.stop() else { return }
        offerConfirm(recording)
    }

    /// Ask once, and keep the audio until answered.
    ///
    /// This is the "record first, decide later" half of SPEC 5.3. Nothing is
    /// deleted here: an unanswered recording stays in staging and is swept
    /// after 24 hours, so the failure mode of walking away is losing a
    /// recording you never wanted, not losing one you did.
    private func offerConfirm(_ recording: Recording) {
        awaitingConfirm = recording
        indicator.onKeep = { [weak self] in self?.resolveConfirm(keep: true) }
        indicator.onDiscard = { [weak self] in self?.resolveConfirm(keep: false) }
        indicator.show(.confirm)
    }

    private func resolveConfirm(keep: Bool) {
        guard let recording = awaitingConfirm else { return }
        awaitingConfirm = nil
        do {
            if keep {
                _ = try Capture.shared.keep(recording)
            } else {
                try Capture.shared.discard(recording)
            }
        } catch {
            notify(keep ? "Could not keep the recording" : "Could not discard the recording",
                   error.localizedDescription)
        }
        indicator.hide()
        rebuildMenu()
    }

    @objc private func revealLibrary() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Library.recordings.path)
    }

    /// An alert, floated and activated.
    ///
    /// An `LSUIElement` app has no Dock icon, so a dialog that falls behind the
    /// meeting window is unreachable and the app looks hung.
    private func notify(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.window.level = .floating
        alert.runModal()
    }

    @objc private func quit() {
        // Stop cleanly so the WAV headers are finalised. Quitting mid-capture
        // otherwise leaves the tap and the aggregate device behind in Core
        // Audio, which survives the process.
        if Capture.shared.isRecording { _ = Capture.shared.stop() }
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ note: Notification) {
        if Capture.shared.isRecording { _ = Capture.shared.stop() }
    }
}
