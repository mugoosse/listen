import AppKit

/// A way out for the copy running from the installer image.
///
/// Dragging the icon to Applications and then double-clicking the icon still
/// in the DMG window is one of the most natural first-run gestures there is,
/// and it launches the read-only copy on the mounted image: Sparkle cannot
/// update it, the login item registers a path that vanishes on eject, and
/// Gatekeeper may be running it translocated from a random read-only mount
/// besides. Nothing said any of that; the app simply worked until the image
/// was ejected. This is the standard remedy (LetsMove's shape): notice at
/// launch, offer the copy in Applications, and relaunch as it.
///
/// **Never blocks.** "Not now" continues in place, because a diagnosis this
/// heuristic must not be able to lock somebody out of their own recorder: a
/// deliberately read-only setup, a network volume, a future macOS quirk all
/// land on the same alert, and the worst a wrong diagnosis may cost is one
/// sentence.
///
/// It runs before `LoginItem.applyDefaultIfNeeded`, so a login item is never
/// registered against the image's path.
@MainActor
enum InstallGuard {
    enum Diagnosis: Equatable {
        case fine
        /// Gatekeeper is running this from a randomised read-only mount.
        case translocated
        /// Running from a mounted volume, which for a .app fresh off a DMG
        /// means the installer image.
        case installerVolume
    }

    static func diagnose(_ bundleURL: URL = Bundle.main.bundleURL) -> Diagnosis {
        let path = bundleURL.path
        if path.contains("/AppTranslocation/") { return .translocated }
        if path.hasPrefix("/Volumes/") { return .installerVolume }
        // A read-only volume that is neither of the above is caught too:
        // translocation mounts under a private path that has changed across
        // macOS versions, and the volume being unwritable is the actual
        // problem in every spelling of it.
        if let values = try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return .translocated
        }
        return .fine
    }

    /// Say so, offer the way out, and relaunch if taken.
    ///
    /// True means the escape was taken: the Applications copy is being opened
    /// and this process is about to terminate, so the caller must not set up
    /// anything else, the login item first among them. The terminate itself
    /// lands a beat later, from `openApplication`'s completion.
    @discardableResult
    static func offerEscapeIfNeeded() -> Bool {
        guard diagnose() != .fine else { return false }
        trace("install guard: running from \(Bundle.main.bundleURL.path)")

        let destination = URL(fileURLWithPath: "/Applications/Listen.app")
        let installed = FileManager.default.fileExists(atPath: destination.path)

        let alert = NSAlert()
        alert.messageText = "Listen is running from the installer"
        alert.informativeText = installed
            ? "This copy lives on the installer image, so updates cannot land "
                + "and it disappears when the image is ejected. The copy "
                + "already in Applications is the one to use."
            : "From here, updates cannot land and the app disappears when the "
                + "image is ejected. Listen can put a copy into Applications "
                + "and continue from there."
        alert.addButton(withTitle: installed
            ? "Open the Applications copy" : "Move to Applications")
        alert.addButton(withTitle: "Not now")
        guard alert.runModal() == .alertFirstButtonReturn else {
            trace("install guard: declined")
            return false
        }

        do {
            if !installed {
                try FileManager.default.copyItem(at: Bundle.main.bundleURL,
                                                 to: destination)
            }
            // Best effort, and worth the process: a quarantined copy launched
            // from where it was quarantined is what Gatekeeper translocates,
            // and clearing the flag on the Applications copy is what LetsMove
            // has done for years to stop the next launch repeating this alert.
            let strip = Process()
            strip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            strip.arguments = ["-dr", "com.apple.quarantine", destination.path]
            try? strip.run()
            strip.waitUntilExit()
        } catch {
            let failed = NSAlert()
            failed.messageText = "Could not copy Listen to Applications"
            failed.informativeText = error.localizedDescription
                + "\n\nDrag Listen.app to Applications in Finder instead, then "
                + "open it from there."
            failed.runModal()
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }
}
