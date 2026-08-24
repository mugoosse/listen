import AppKit

/// Every address the app hands to a browser, in one place, and the two ways it
/// hands one to another person.
///
/// They were literals in an About pane, a dictionary pane and a CLI string, and
/// the one that mattered most was in none of them: the landing page. About
/// linked the author's personal site and the source repository, so the page
/// that says what Listen is, what it costs and how to install it could not be
/// reached from inside Listen. Somebody trying to send it to a friend had to go
/// and find it themselves, which is the report that started this.
enum Links {
    /// The landing page. What you send somebody who has not got it yet.
    static let website = URL(string: "https://mugoosse.github.io/listen/")!

    /// The README, which is the documentation until there is a docs site.
    ///
    /// `#readme` rather than the raw file: GitHub renders it, links inside it
    /// work, and the anchor means the repository page opens scrolled to the
    /// text rather than to the file list.
    static let docs = URL(string: "https://github.com/mugoosse/listen#readme")!

    static let source = URL(string: "https://github.com/mugoosse/listen")!
    static let issues = URL(string: "https://github.com/mugoosse/listen/issues")!

    /// The sentence that travels with the link.
    ///
    /// One line, because it is going into a message somebody else is writing.
    /// It says what the app does and where it runs, which are the two things
    /// the person receiving it will ask.
    static let blurb = "Listen records your meetings, writes them down and works "
        + "out who spoke, entirely on your Mac."

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// Handing the link to somebody else.
///
/// Two ways rather than one, because the macOS share sheet is only as good as
/// the services the user has set up and "Copy Link" is the one that is never
/// missing. Both are on the About window; the sheet is also on the Help menu
/// and the status menu, which is where somebody looks first.
@MainActor
enum Sharing {
    /// Held for the life of the process. An `NSSharingServicePicker` released
    /// at the end of the function that showed it takes its own popover with it,
    /// and the sheet flickers instead of opening.
    private static var picker: NSSharingServicePicker?

    static var items: [Any] { [Links.blurb, Links.website] }

    static func present(from view: NSView, edge: NSRectEdge = .maxY) {
        let picker = NSSharingServicePicker(items: items)
        Self.picker = picker
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: edge)
    }

    /// From a menu item, which has no view to hang a popover on.
    ///
    /// `anchor` is whatever the caller has: the status item's button for the
    /// status menu, so the sheet opens under the menu bar icon it was asked
    /// from. Failing that the key window, and failing that the About window,
    /// which is opened for the purpose rather than sharing from nowhere.
    static func presentFromMenu(anchor: NSView? = nil) {
        if let anchor {
            present(from: anchor, edge: .minY)
            return
        }
        if let content = NSApp.keyWindow?.contentView {
            present(from: content, edge: .minY)
            return
        }
        AboutWindow.show()
        AboutWindow.shared.presentShare()
    }

    static func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Links.website.absoluteString, forType: .string)
    }
}
