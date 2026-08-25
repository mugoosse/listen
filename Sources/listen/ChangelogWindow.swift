import AppKit

/// What changed, as a window of its own.
///
/// A sibling of `AboutWindow` and for the same reason: this is a thing to be
/// read, not a preference to be set, and it was reachable from nowhere. See
/// `Changelog` for why the file it draws ships inside the bundle rather than
/// being fetched.
///
/// Three ways in, because three different questions land here. Help › Release
/// Notes is somebody looking for it by name, the About window has it beside the
/// version number it belongs to, and Settings › Updates has it under the line
/// that says whether this copy is current.
@MainActor
final class ChangelogWindow: NSObject, NSWindowDelegate {
    static let shared = ChangelogWindow()

    /// 560 to open, which is `Pane.paneWidth`: the same measure the settings
    /// panes set their prose at, and a line much wider than that is one nobody
    /// tracks back to the left. Resizable, unlike About, because this is a
    /// document rather than a card, and somebody reading five releases back
    /// should be able to make it taller.
    private static let width: CGFloat = 560
    private static let height: CGFloat = 640

    private var window: NSWindow?

    static func show() { shared.show() }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// `LISTEN_SHOT` draws this window into a bitmap, the same route About and
    /// the library window take, so a picture of it can be taken over SSH and
    /// with the screen locked.
    ///
    /// This window is what found the fault in that route: being almost nothing
    /// but text, it photographed as an empty page while it was perfectly
    /// correct on screen. `NSView.writeShot` has the measurement and the fix.
    func writeShot(to path: String) -> Bool {
        guard let view = window?.contentView else { return false }
        return view.writeShot(to: path)
    }

    // -----------------------------------------------------------------------

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        w.title = "Release Notes"
        w.isReleasedWhenClosed = false
        w.delegate = self
        // Narrower than this and a bulleted line inside an entry wraps every
        // three words; shorter and the footer is most of the window.
        w.minSize = NSSize(width: 420, height: 320)

        let view = NSTextView()
        // Sized by its scroll view rather than by autolayout, which is the one
        // AppKit arrangement that still wants the autoresizing mask: the
        // document's height is the text's, and constraints cannot know that
        // before the layout manager has run. Same shape as the notes pane.
        view.frame = NSRect(x: 0, y: 0, width: Self.width, height: 100)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        // The margin is the document's, not the scroll view's. Insetting the
        // scroller instead would take the whole track 24 points in from the
        // window's edge, where nobody expects a scroller, and a content inset
        // is a scroll offset rather than a position. `window.md` has both.
        view.textContainerInset = NSSize(width: 24, height: 20)
        // Zero, not the default 5, so the text's left edge is the inset above
        // and not the inset plus a padding nothing else in the window shares.
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        view.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .cursor: NSCursor.pointingHand,
        ]
        view.textStorage?.setAttributedString(document())

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false

        // The one thing a bundled changelog has to admit, said where it is
        // read rather than in a tooltip: these notes were built into this copy,
        // so the newest thing here is the version you have.
        let caption = NSTextField(wrappingLabelWithString:
            "These notes ship inside Listen, so they end at the version you have.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        // Hugs at nothing, so the stack gives it whatever the button leaves and
        // the button keeps its own width.
        caption.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let github = NSButton(title: "Full Changelog", target: nil, action: nil)
        github.bezelStyle = .rounded
        github.setContentHuggingPriority(.required, for: .horizontal)
        github.setContentCompressionResistancePriority(.required, for: .horizontal)
        attach(github) { Links.open(Links.changelog) }

        let footer = NSStackView(views: [caption, github])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 12, right: 20)
        footer.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(line)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content

        // Centred first, then autosaved: the autosave has nothing in it the
        // first time and an unplaced window opens at the bottom left.
        w.center()
        w.setFrameAutosaveName("ListenChangelog")
        window = w
    }

    /// Every release, drawn as one document.
    ///
    /// One text view rather than a stack of them per release. Twenty-three
    /// entries is twenty-three text views with their own layout managers, and
    /// the thing a reader wants from a changelog is to scroll and to select
    /// across it, both of which a single document does for free.
    private func document() -> NSAttributedString {
        let releases = Changelog.releases
        guard !releases.isEmpty else { return nothingHere() }

        let out = NSMutableAttributedString()
        for (index, release) in releases.enumerated() {
            out.append(header(release, first: index == 0))
            out.append(MarkdownText.attributed(release.body, width: 13))
        }
        return out
    }

    /// The version number, and the line under it that says when it shipped and
    /// whether it is the copy running now.
    private func header(_ release: Changelog.Release, first: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()

        let top = NSMutableParagraphStyle()
        // 30 points of air before every version but the first. `MarkdownText`
        // draws no rules, deliberately, because it cannot know the width it
        // would draw one at, so this gap is the only thing between the end of
        // one release and the start of the next. At the 14 a heading inherits
        // the two ran together.
        top.paragraphSpacingBefore = first ? 0 : 30
        top.paragraphSpacing = 1
        out.append(NSAttributedString(
            string: release.version + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: top]))

        var line = release.date ?? ""
        // Which of these is yours. Almost always the newest one, because a
        // bundled changelog cannot hold a version that has not shipped, and
        // that is exactly why it is worth saying: after an update installs on
        // quit, this line is the confirmation that the entry at the top is what
        // arrived.
        if release.version == Changelog.running {
            line += line.isEmpty ? "Installed" : "  ·  Installed"
        }
        guard !line.isEmpty else { return out }

        let under = NSMutableParagraphStyle()
        under.paragraphSpacing = 10
        out.append(NSAttributedString(
            string: line + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: under]))
        return out
    }

    /// A build with no bundled notes, which is a `swift build` binary rather
    /// than a broken app. Said plainly instead of opening an empty window or
    /// silently sending somebody to a browser they did not ask for.
    private func nothingHere() -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        return NSAttributedString(
            string: "This build does not carry its release notes. "
                + "Every version's notes are in the changelog on GitHub.",
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: style])
    }

    /// Closure to selector, the way About and the settings panes do it.
    private func attach(_ button: NSButton, _ action: @escaping () -> Void) {
        let handler = ActionHandler { _ in action() }
        button.target = handler
        button.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
    }
}
