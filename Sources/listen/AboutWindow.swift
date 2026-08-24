import AppKit

/// The About box, as a window of its own.
///
/// It was a settings section, which is where Speak (https://mugoosse.github.io/speak/)
/// puts it and where nobody found it: "About Listen" opened a page inside the
/// library window, behind a sidebar, one row above Developers. Two things were
/// wrong with that and both came back as the same report from somebody trying
/// to pass the app on. The identity of the app read as one more preference, and
/// every link out of it was behind a mode switch and a scroll, the landing page
/// worst of all because it was not there at all. What that menu item is
/// expected to open is a small window with the icon in it, so that is what it
/// opens.
///
/// The updates half stayed in settings. Checking for a new version and running
/// setup again are preferences; what the app is and where to send it is not.
@MainActor
final class AboutWindow: NSObject, NSWindowDelegate {
    static let shared = AboutWindow()

    /// 400 points wide and never resizable, so every wrapping label is laid out
    /// against one number and the height is measured once from the content. An
    /// About box that can be dragged wider has nothing to do with the space.
    private static let width: CGFloat = 400
    private static let inset: CGFloat = 28
    private static var contentWidth: CGFloat { width - inset * 2 }

    private var window: NSWindow?
    private var shareButton: NSButton?
    private var copyButton: NSButton?
    private var copyReset: Timer?

    static func show() { shared.show() }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Open the share sheet on this window's own Share button.
    ///
    /// For `Sharing.presentFromMenu` when it has no other anchor: an app with
    /// no window open still has a status menu, and "Share Listen…" from it has
    /// to put the sheet somewhere a popover can point at.
    func presentShare() {
        guard let shareButton else { return }
        Sharing.present(from: shareButton)
    }

    /// `LISTEN_SHOT` draws this window into a bitmap. Same route the library
    /// window and the recording panel take, so a picture of About can be taken
    /// over SSH and with the screen locked.
    func writeShot(to path: String) -> Bool {
        guard let view = window?.contentView else { return false }
        return view.writeShot(to: path)
    }

    func windowWillClose(_ notification: Notification) {
        copyReset?.invalidate()
        copyReset = nil
    }

    // -----------------------------------------------------------------------

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // Titled and hidden, rather than titled with an empty string. Nothing
        // should draw: the window says "Listen" in 22 point immediately below
        // the title bar, and two names one line apart read as a mistake rather
        // than as a title, which is the settings mode's own trap. But the title
        // is also what the Window menu lists and what VoiceOver announces, and
        // an empty one leaves both saying nothing.
        w.title = "About Listen"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 30, left: Self.inset,
                                        bottom: 26, right: Self.inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let image = NSApp.applicationIconImage {
            let icon = NSImageView(image: image)
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 88),
                icon.heightAnchor.constraint(equalToConstant: 88),
            ])
            stack.addArrangedSubview(icon)
            stack.setCustomSpacing(14, after: icon)
        }

        let name = text("Listen", size: 22, weight: .semibold)
        stack.addArrangedSubview(name)
        stack.setCustomSpacing(6, after: name)

        let tagline = text("A meeting recorder, transcriber and speaker labeller "
                           + "that runs entirely on your Mac.",
                           size: 12, color: .secondaryLabelColor)
        stack.addArrangedSubview(tagline)
        stack.setCustomSpacing(20, after: tagline)

        let versions = versionGrid()
        stack.addArrangedSubview(versions)
        stack.setCustomSpacing(20, after: versions)

        // The three places somebody goes from here, in the order they would
        // want them: what it is, how to use it, and what it is made of.
        let links = row([
            link("Website", Links.website),
            link("Docs", Links.docs),
            link("GitHub", Links.source),
        ])
        stack.addArrangedSubview(links)
        stack.setCustomSpacing(20, after: links)

        stack.addArrangedSubview(separator())

        let ask = text("Pass it on", size: 13, weight: .semibold)
        stack.addArrangedSubview(ask)
        stack.setCustomSpacing(4, after: ask)

        // Said plainly rather than as a nag, and said once. There is no
        // in-app prompt asking for a star later, deliberately: this window is
        // the one place somebody is already looking at the app rather than
        // using it.
        let why = text("Listen has no ads and nobody selling it. A link you send "
                       + "and a star on GitHub are the whole of how the next "
                       + "person finds it.",
                       size: 11, color: .secondaryLabelColor)
        stack.addArrangedSubview(why)
        stack.setCustomSpacing(12, after: why)

        let share = NSButton(title: "Share…", target: nil, action: nil)
        share.bezelStyle = .rounded
        attach(share) { [weak self] in
            guard let self, let shareButton = self.shareButton else { return }
            Sharing.present(from: shareButton)
        }
        shareButton = share

        let copy = NSButton(title: "Copy Link", target: nil, action: nil)
        copy.bezelStyle = .rounded
        attach(copy) { [weak self] in self?.copyLink() }
        // Pinned to the width it has now, so flipping the title to "Copied"
        // does not shuffle the two buttons beside it. Measured from
        // `fittingSize` rather than `intrinsicContentSize`, which comes out
        // four points short of the text on a label and would clip the wider of
        // the two words.
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.widthAnchor.constraint(equalToConstant: copy.fittingSize.width).isActive = true
        copyButton = copy

        let star = NSButton(title: "Star on GitHub", target: nil, action: nil)
        star.bezelStyle = .rounded
        star.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        star.imagePosition = .imageLeading
        // Without this the glyph is laid out against the leading edge of the
        // button and the title is centred in what is left, so they end up at
        // opposite ends of the capsule. `appkit.md` has it twice.
        star.imageHugsTitle = true
        attach(star) { Links.open(Links.source) }

        let actions = row([share, copy, star])
        stack.addArrangedSubview(actions)
        stack.setCustomSpacing(20, after: actions)

        stack.addArrangedSubview(separator())

        // A name and not a second link. The author's own site was here because
        // this window had no product page to point at; it has one now, at the
        // top, and two sites on one card is the reader choosing between them.
        let made = text("Made by Maxime Goossens", size: 12)
        stack.addArrangedSubview(made)
        stack.setCustomSpacing(12, after: made)

        stack.addArrangedSubview(text(
            "Built on Parakeet by NVIDIA, MLX by Apple, FluidAudio and Sparkle.",
            size: 11, color: .secondaryLabelColor))

        // The AGPL is a source-availability licence, so the About box is the
        // honest place to say where the source is and what the app does with
        // the network. Shorter than the paragraph the settings pane carried:
        // the same four claims, and this window is read standing up.
        stack.addArrangedSubview(text(
            "Free software under the AGPL 3.0. No account and no telemetry: on its "
            + "own Listen uses the network to fetch the model you chose and to ask "
            + "whether a newer version exists. iCloud sync and a hosted Ask "
            + "provider add a connection only if you turn them on.",
            size: 11, color: .secondaryLabelColor))

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content
        // Laid out first, then measured: `fittingSize` on a stack of wrapping
        // labels is only right once they have been given the width they wrap
        // at, and a window sized before that opens several lines too short.
        content.layoutSubtreeIfNeeded()
        w.setContentSize(NSSize(width: Self.width, height: stack.fittingSize.height))
        // Autosaved, so a window somebody has moved comes back where they left
        // it. `center()` first, because the autosave has nothing in it the
        // first time and an unplaced window opens at the bottom left.
        w.center()
        w.setFrameAutosaveName("ListenAbout")
        window = w
    }

    private func copyLink() {
        guard let copyButton else { return }
        Sharing.copyLink()
        // The whole confirmation. A pasteboard write has no other visible
        // effect, so a button that does not change is indistinguishable from
        // one that did nothing.
        copyButton.title = "Copied"
        copyReset?.invalidate()
        copyReset = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { _ in
            Task { @MainActor [weak copyButton] in copyButton?.title = "Copy Link" }
        }
    }

    // -----------------------------------------------------------------------

    private func text(_ string: String, size: CGFloat,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = .center
        field.preferredMaxLayoutWidth = Self.contentWidth
        return field
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        return row
    }

    private func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return line
    }

    private func link(_ title: String, _ url: URL) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        attach(button) { Links.open(url) }
        return button
    }

    /// Closure to selector, the way the settings panes do it, so this window
    /// reads as a list of controls rather than a list of `@objc` methods.
    private func attach(_ button: NSButton, _ action: @escaping () -> Void) {
        let handler = ActionHandler { _ in action() }
        button.target = handler
        button.action = #selector(ActionHandler.fire(_:))
        objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
    }

    /// Read from the bundle rather than written here, so bumping `VERSION` is
    /// enough and this cannot go stale.
    private func versionGrid() -> NSView {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String

        var pairs = [("Version", short)]
        if let build, build != short { pairs.append(("Build", build)) }

        let names = NSStackView()
        names.orientation = .vertical
        names.alignment = .trailing
        names.spacing = 3
        let values = NSStackView()
        values.orientation = .vertical
        values.alignment = .leading
        values.spacing = 3

        for (name, value) in pairs {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            names.addArrangedSubview(label)

            // Monospaced, because these are numbers somebody is about to read
            // out or type into a bug report rather than prose.
            let field = NSTextField(labelWithString: value)
            field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            field.isSelectable = true
            values.addArrangedSubview(field)
        }

        return row([names, values])
    }
}
