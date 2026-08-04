import AppKit

/// The app itself.
///
/// A skeleton at milestone 0: enough to prove the bundle launches, is signed
/// with a stable identity, and can be quit. Capture arrives at milestone 2 and
/// the library window at milestone 4, and both hang off here.
@MainActor
final class App: NSObject, NSApplicationDelegate {
    private var status: NSStatusItem?

    func applicationDidFinishLaunching(_ note: Notification) {
        trace("launched, build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A drawn glyph rather than an asset, so the icon has no artwork to
        // ship and no scale factor to get wrong. Replaced at milestone 2 by one
        // with a case per capture state.
        item.button?.image = NSImage(
            systemSymbolName: "waveform", accessibilityDescription: "Listen")
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.addItem(withTitle: "Listen \(Self.versionString)",
                     action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Listen", action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        status = item
    }

    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
