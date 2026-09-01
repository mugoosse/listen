import AppKit

/// The made-up URL scheme a note's source links carry.
///
/// Made up rather than real, and read back by the delegate that owns the text
/// view, so an id in a note's provenance can never reach `NSWorkspace`: a note
/// naming its sources must not be a way to launch something.
enum RecordingLink {
    static let scheme = "listen-recording:"

    static func id(_ link: Any) -> String? {
        guard let url = link as? String, url.hasPrefix(scheme) else { return nil }
        return String(url.dropFirst(scheme.count))
    }
}

/// And for a note, for the same reason as `ChatLink`.
enum NoteLink {
    static let scheme = "listen-note:"

    static func id(_ link: Any) -> String? {
        guard let url = link as? String, url.hasPrefix(scheme) else { return nil }
        return String(url.dropFirst(scheme.count))
    }
}

/// And for somebody in the roster, which only an answer's references link to.
///
/// The name as it is shown, not the on-disk label: it is written by an agent
/// that was handed display names, and `People.findByDisplayName` is the one
/// lookup that accepts both.
enum PersonLink {
    static let scheme = "listen-person:"

    static func id(_ link: Any) -> String? {
        guard let url = link as? String, url.hasPrefix(scheme) else { return nil }
        return String(url.dropFirst(scheme.count))
    }
}

/// The same trick for a conversation, and separate rather than a parameter on
/// the one above, because the two are read by different delegates and a link
/// that resolves to the wrong kind of thing is the failure worth designing out.
enum ChatLink {
    static let scheme = "listen-chat:"

    static func id(_ link: Any) -> String? {
        guard let url = link as? String, url.hasPrefix(scheme) else { return nil }
        return String(url.dropFirst(scheme.count))
    }
}

// `LibraryCollection`, `CollectionPicker` and `NotesNav` were here, and all
// three went together. They were the three-segment switch at the top of the
// sidebar and the two lists it swapped in: Recordings, People, Notes.
//
// **What replaced them is a word you type and a heading you click.** See
// `LibraryKind` in `RecordingFilter.swift` for the argument, which is that a
// segment is a place you are in and have to leave, so the set could not say
// "all three" and an empty Notes tab read as the control being broken rather
// than as an empty answer. The one list holds all three kinds and a lens
// narrows it, which is a state with an off switch.
//
// `NoteCell` below stayed, because the one list draws notes with it. So did
// `NotePane`: reading a note is still a page, it is just not a collection.

/// One row: what the note is, who wrote it, and what it is about.
@MainActor
final class NoteCell: NSView {
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    /// The sentence that matched, on rows that are search results.
    private let excerpt = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        excerpt.font = .systemFont(ofSize: 11)
        excerpt.textColor = .secondaryLabelColor
        // Two, matching `RecordingCell`, and for the same reason: the row's
        // height is a constant answered without measuring the text.
        excerpt.maximumNumberOfLines = 2
        excerpt.lineBreakMode = .byTruncatingTail
        excerpt.cell?.usesSingleLineMode = false
        // Both are needed, for the reason `RecordingCell` records: the line cap
        // alone lays out three lines and draws them over the row below.
        excerpt.cell?.truncatesLastVisibleLine = true
        excerpt.isHidden = true

        let stack = NSStackView(views: [title, detail, excerpt])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ note: Note, match: SidebarViewController.RowMatch? = nil) {
        // A stack view hides a view's space along with it, unlike the pinned
        // constraints `RecordingCell` uses, so this is the whole of it here.
        excerpt.isHidden = match?.excerpt == nil
        if let line = match?.excerpt { excerpt.attributedStringValue = line }
        let sources = Notes.sources(of: note)
        // Every one of the user's own notes is titled "Your notes", so a list of
        // them is a column of identical rows distinguished only by a truncated
        // second line. The meeting is what tells them apart, so for those the
        // row leads with it and "Your notes" moves down to where the kind is
        // stated. An agent's note is the other way round: its title is the one
        // thing that is its own.
        title.stringValue = Notes.isYours(note)
            ? (sources.first?.title ?? note.title)
            : note.title
        var facts: [String] = [Notes.isYours(note) ? "Your notes" : "Agent"]
        // The meeting's own name when there is one, a count when there are
        // several. "4 recordings" is what makes a synthesis findable in this
        // list; a single note's own meeting is what makes the rest legible.
        if !Notes.isYours(note), sources.count == 1 {
            facts.append(sources[0].title ?? "recording deleted")
        } else if sources.count > 1 {
            facts.append("\(sources.count) recordings")
        }
        if let date = Timestamps.parse(note.updated) {
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .none
            facts.append(f.string(from: date))
        }
        // **Text in the existing line, not pills, and not a third line.**
        // `Sidebar.heightOfRow` returns a flat 52 for every row, so pills would
        // need variable heights. The stronger reason is that a *recording* row
        // shows no tags at all: giving notes pills and meetings nothing would
        // have the list say a note is more filed than the meeting it is about,
        // which is the opposite of what one shared vocabulary means. Pills on
        // both cells, with a height that moves for both, is a real change and
        // it is a separate one.
        facts += note.tags.map { "#" + $0 }
        detail.stringValue = facts.joined(separator: " · ")
        // The whole list in the tooltip, because the line truncates and the
        // tags are at the end of it, so they are the first thing to go.
        detail.toolTip = note.tags.isEmpty ? nil : note.tags.map { "#" + $0 }
            .joined(separator: ", ")
    }
}

// ---------------------------------------------------------------------------

/// One note, read on its own rather than beside a recording.
///
/// Read-only, including the user's own, and that is deliberate rather than
/// unfinished. Their note is edited on the recording it belongs to, where the
/// audio and the transcript are, and having two editors for one file would be
/// two writers of the thing this app is most careful about. The sources are
/// buttons, so the way to edit it is one click and the click also takes you to
/// the meeting it is about.
@MainActor
final class NotePane: NSViewController {
    private let heading = NSTextField(labelWithString: "")
    /// Who wrote it, when, and what was asked for.
    ///
    /// A `LinkLine` rather than a label, because the question is a link when the
    /// conversation it was asked in is still here. **On the prompt itself and
    /// not on a row of its own**: a note's provenance is already two lines, and
    /// "Asked for: …" and "the conversation that asked it" are one fact written
    /// twice. The words that were typed are the handle, the way a source
    /// recording's title is the handle for the meeting.
    private let info = LinkLine()
    /// The meetings a note is about, as a line of links.
    ///
    /// A text view and not a row of buttons. Buttons with a trailing chevron
    /// each read as one step of a path, so four of them are a breadcrumb trail
    /// claiming a hierarchy that does not exist: these are four peers. A
    /// sentence with commas in it is a list, which is what they are, and it
    /// wraps, underlines on hover and turns the pointer into a hand for free.
    private let sources = LinkLine()
    /// What this note is filed under, and the way to change it.
    ///
    /// The same `TagChips` the transcript header uses, which is the point: the
    /// popover, its type-to-filter behaviour and the pill menu are one
    /// implementation, so a tag is added to a note exactly the way it is added
    /// to a meeting. Under the sources rather than beside the heading, because
    /// it is the same kind of fact as "what this note is about" and reads as
    /// the last line of the provenance block.
    private let tagChips = TagChips()
    private let text = NSTextView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "Select a note.")

    /// Find in page, over the one document this pane holds.
    private let findBar = FindBar()
    private var findTop: NSLayoutConstraint!
    private var findHeight: NSLayoutConstraint!
    private var found: [NSRange] = []
    private var foundAt: Int?
    private var finding = ""

    private var note: Note?

    /// Where a source button goes: the recording, and the note being read, so
    /// the pane it lands on opens on the same note rather than on a transcript
    /// nobody asked for.
    var onOpenRecording: ((String, String) -> Void)?
    /// And where the question goes: the conversation this note was promoted out
    /// of. See `Chat.wrote(_:)` for which notes have one.
    var onOpenChat: ((String) -> Void)?

    override func loadView() {
        let container = NSView()

        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.lineBreakMode = .byTruncatingTail
        // The two lines under the title are the same kind of thing, so they are
        // set up by one function rather than by two blocks that can part.
        for line in [info, sources] { prepare(line) }

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 0, height: 12)
        // See `DetailView.buildNotesPane`: the default padding puts the body
        // five points right of everything above it.
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 0,
                                                   height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor

        // Six rather than three, so the strip is as wide as it likes here.
        // The defaults were measured for the transcript header, where the row
        // is shared with the speaker chips; this row is the pane's own and has
        // nothing competing for it.
        tagChips.widen(maxChips: 6, maxChipWidth: 220)
        tagChips.onTag = { name, _, _ in LibraryWindow.shared.filter(byTag: name) }
        tagChips.onAdd = { [weak self] anchor, rect in
            self?.editTags(from: anchor, rect: rect)
        }
        tagChips.onChanged = { [weak self] in self?.refreshTags() }

        findBar.isHidden = true
        findBar.onQuery = { [weak self] text in self?.findQueryChanged(text) }
        findBar.onStep = { [weak self] by in self?.stepFind(by) }
        findBar.onDone = { [weak self] in self?.closeFind() }

        for v in [heading, info, sources, tagChips, scroll, empty, findBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        // The same collapsed pair the recording page uses: zero top and zero
        // height put the bar's bottom edge on the strip above it, so the note
        // is laid out exactly as it was before this existed.
        findTop = findBar.topAnchor.constraint(equalTo: tagChips.bottomAnchor, constant: 0)
        findHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: container.topAnchor, constant: 38),
            heading.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            heading.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                              constant: -24),
            info.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4),
            info.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            info.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            sources.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 6),
            sources.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            sources.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            tagChips.topAnchor.constraint(equalTo: sources.bottomAnchor, constant: 8),
            // Leading, unlike the transcript header's trailing pin. There is
            // nothing to its left to grow towards it here, and a row of pills
            // hard against the right edge of an otherwise left-aligned page
            // reads as a different pane's furniture.
            tagChips.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            tagChips.trailingAnchor.constraint(lessThanOrEqualTo: heading.trailingAnchor),
            tagChips.heightAnchor.constraint(equalToConstant: 24),
            findTop,
            findHeight,
            findBar.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                             constant: -24),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
        show(nil)
    }

    /// A line of text with links in it: read-only, transparent, as tall as it
    /// wraps to, and with the pointing hand on every link.
    private func prepare(_ line: LinkLine) {
        line.isEditable = false
        line.isSelectable = true
        line.drawsBackground = false
        line.delegate = self
        line.textContainerInset = .zero
        line.textContainer?.lineFragmentPadding = 0
        line.textContainer?.widthTracksTextView = true
        line.isVerticallyResizable = true
        line.isHorizontallyResizable = false
        line.setContentHuggingPriority(.required, for: .vertical)
        line.setContentCompressionResistancePriority(.required, for: .vertical)
        line.linkTextAttributes = [
            .foregroundColor: Brand.accent,
            .cursor: NSCursor.pointingHand,
        ]
    }

    // MARK: - Find in page

    /// True while the bar is up. The window asks before offering to step.
    var isFinding: Bool { isViewLoaded && !findBar.isHidden }

    func openFind() {
        loadViewIfNeeded()
        guard note != nil else { NSSound.beep(); return }
        if findBar.isHidden {
            findBar.isHidden = false
            findTop.constant = 8
            findHeight.constant = FindBar.height
        }
        findBar.focus()
    }

    func closeFind() {
        guard isViewLoaded else { return }
        found = []
        foundAt = nil
        finding = ""
        markFound()
        findBar.setQuery("")
        findBar.report(nil, of: 0)
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findTop.constant = 0
        findHeight.constant = 0
        // `nil` for the reason the recording page's copy gives.
        if view.window?.firstResponder is NSTextView {
            view.window?.makeFirstResponder(nil)
        }
    }

    func findNext() { stepFind(1) }
    func findPrevious() { stepFind(-1) }

    private func findQueryChanged(_ query: String) {
        finding = query
        found = Find.ranges(of: query, in: text.string)
        foundAt = found.isEmpty ? nil : 0
        markFound()
        findBar.report(foundAt, of: found.count)
        if let foundAt { text.scrollRangeToVisible(found[foundAt]) }
    }

    private func stepFind(_ by: Int) {
        guard !found.isEmpty else { NSSound.beep(); return }
        let next = ((foundAt ?? 0) + by + found.count) % found.count
        foundAt = next
        markFound()
        findBar.report(next, of: found.count)
        text.scrollRangeToVisible(found[next])
    }

    /// The ranges the layout manager is decorating, so they can be taken off.
    private var marked: [NSRange] = []

    /// **Temporary attributes, never an edit to the storage**, for the reason
    /// `LinkLine` records: the storage is what the height is measured from and
    /// what an answer streams into, and a decoration belongs to neither. They
    /// are also dropped for free when the text is replaced.
    private func markFound() {
        guard let layout = text.layoutManager else { return }
        let length = (text.string as NSString).length
        for range in marked where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        marked = []
        let current = foundAt.flatMap { $0 < found.count ? found[$0] : nil }
        for range in found where NSMaxRange(range) <= length {
            layout.addTemporaryAttributes(
                range == current
                    ? [.backgroundColor: NSColor.systemOrange,
                       .foregroundColor: NSColor.black]
                    : [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)],
                forCharacterRange: range)
            marked.append(range)
        }
    }

    func show(_ note: Note?) {
        loadViewIfNeeded()
        // A different note is a different document, so the search over the last
        // one goes with it. Unlike the recording page, this pane is only ever
        // shown for a selection, so there is no reload to guard against.
        if note?.slug != self.note?.slug { closeFind() }
        self.note = note
        let hidden = note == nil
        for v in [heading, info, sources, tagChips, scroll] as [NSView] {
            v.isHidden = hidden
        }
        empty.isHidden = !hidden
        guard let note else { return }

        heading.stringValue = note.title
        let when = Timestamps.parse(note.updated).map { date -> String in
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: date)
        }
        // One line. It carried three before: who wrote it, when, and a sentence
        // explaining that your own note is edited on the recording, on every
        // note, for ever. That sentence is a thing you need once, so it is the
        // text view's tooltip, and what is left fits where the sidebar row's
        // second line already puts the same two facts.
        var facts = [Notes.isYours(note) ? "Yours" : "Written by an agent"]
        if let when { facts.append(Notes.isYours(note) ? "edited \(when)" : when) }
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let provenance = NSMutableAttributedString(
            string: facts.joined(separator: " · "), attributes: plain)
        if let prompt = note.prompt, !prompt.isEmpty {
            provenance.append(NSAttributedString(string: "\nAsked for: ",
                                                 attributes: plain))
            var asked = plain
            // The conversation is looked up once, here, and the question is a
            // link only when there is one to open. A note written over MCP or
            // from the command line came from a conversation this app never
            // held, and one whose conversation has been deleted is the same
            // case: the words stay, the link does not appear, and nothing on
            // the page claims a destination that is not there.
            if let chat = Chat.wrote(note), let id = chat.id {
                asked[.link] = ChatLink.scheme + id
                asked[.foregroundColor] = Brand.accent
            }
            provenance.append(NSAttributedString(string: prompt, attributes: asked))
        }
        info.set(provenance)
        text.toolTip = Notes.isYours(note)
            ? "Your notes are written on the recording itself. An agent can read "
                + "this and cannot change it."
            : nil

        let list = NSMutableAttributedString()
        for source in Notes.sources(of: note) {
            if list.length > 0 {
                list.append(NSAttributedString(string: ", ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
            ]
            if let title = source.title {
                // A made-up scheme rather than a real URL. The delegate below
                // reads the id back out and never lets it reach `NSWorkspace`,
                // which is what stops a note's own provenance being a way to
                // launch something.
                attributes[.link] = RecordingLink.scheme + source.id
                list.append(NSAttributedString(string: title, attributes: attributes))
            } else {
                // An id with no recording behind it is shown and not a link, and
                // says why. Silently dropping it would make the note claim it
                // was never about that meeting.
                attributes[.foregroundColor] = NSColor.tertiaryLabelColor
                list.append(NSAttributedString(
                    string: source.id + " (no longer in the library)",
                    attributes: attributes))
            }
        }
        // Through `set`, which also drops the hover underline: a note swapped
        // under the pointer would otherwise keep a range highlighted into text
        // that has gone.
        sources.set(list)

        // The body without the heading the title already is. An agent writes
        // `# Decisions` at the top of a note called "Decisions", which is right
        // in the file and reads as a mistake on a page whose own title is two
        // lines above it.
        text.textStorage?.setAttributedString(
            MarkdownText.attributed(note.body, without: note.title))
        text.scroll(NSPoint(x: 0, y: 0))

        tagChips.configure(.note(note))
    }

    /// Cmd-T over a note. The strip is always on this page when a note is
    /// showing, so unlike the transcript header there is no collapsed case to
    /// find an anchor for.
    func beginEditingTags() {
        loadViewIfNeeded()
        guard note != nil else { return }
        editTags(from: tagChips, rect: tagChips.bounds)
    }

    /// The add popover, anchored the way `DetailView.editTags` anchors it.
    ///
    /// The rect is converted while the button is still in the window. Nothing
    /// on this page commits an edit first, so the sequence is shorter than the
    /// transcript header's, but the conversion still has to happen before
    /// anything can reload the strip out from under it.
    private func editTags(from anchor: NSView, rect: NSRect) {
        guard let note else { return }
        let target = view.convert(rect, from: anchor)
        TagPopover.show(for: .note(note), from: view, rect: target) { [weak self] in
            self?.refreshTags()
        }
    }

    /// Redraw the strip after a tag changed, and nothing else.
    ///
    /// Not `show(_:)`, which would scroll a note somebody is halfway down back
    /// to the top: filing something is done while reading it. The note is
    /// re-read from disk because the copy this pane is holding still has the
    /// tags it had, and the sidebar is told because a tag can be the lens the
    /// list is under, so this row may belong somewhere else now.
    private func refreshTags() {
        guard let note, let updated = Notes.find(note.slug) else { return }
        self.note = updated
        tagChips.configure(.note(updated))
        LibraryWindow.shared.reload()
    }
}

extension NotePane: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any,
                  at charIndex: Int) -> Bool {
        // Both made-up schemes, and told apart rather than guessed at: a link
        // that resolved to the wrong kind of thing is the failure the separate
        // schemes exist to design out. Anything else is refused, which is what
        // keeps a note's own text away from `NSWorkspace`.
        if let id = ChatLink.id(link) {
            onOpenChat?(id)
            return true
        }
        guard let id = RecordingLink.id(link), let note else { return false }
        onOpenRecording?(id, note.slug)
        return true
    }
}


/// A text view that is as tall as its text.
///
/// An `NSTextView` reports no intrinsic size, which is fine inside a scroll
/// view where its frame is managed for it and wrong everywhere else: pinned
/// into a stack of constraints with nothing saying how tall it is, it took the
/// whole pane and pushed the note's body off the bottom of the window. The
/// symptom is a note that renders its header and nothing else, which reads as
/// an empty note.
@MainActor
final class LinkLine: NSTextView {
    /// Replace the text, and say so.
    ///
    /// `textStorage` is written to directly rather than through `string`,
    /// because the attributes are the point here, and a programmatic write does
    /// not call `didChangeText`: without the invalidation the view keeps the
    /// height it was last measured at, which for an answer being streamed into
    /// is the height of its first sentence.
    func set(_ text: NSAttributedString) {
        // Before the write, not after: the range is into the storage that is
        // about to go, and taking the attribute off afterwards would be a
        // range into the new text.
        underline(nil)
        textStorage?.setAttributedString(text)
        invalidateIntrinsicContentSize()
    }

    // MARK: - The link under the pointer

    /// Which link is underlined, so the last one can be put back.
    private var underlined: NSRange?
    /// Ours, kept apart from the several an `NSTextView` installs for itself.
    /// Clearing `trackingAreas` wholesale here is what takes the pointing hand
    /// off every link in the app, because that cursor is one of them.
    private var hoverArea: NSTrackingArea?

    /// Underline the link the pointer is over.
    ///
    /// A link in this app is the accent colour and nothing else, which is
    /// enough to read as a link in a paragraph and not enough to say *which*
    /// one is about to be clicked when five of them are stacked, which is
    /// exactly the shape the landing page's recent conversations are in. The
    /// pointing hand already appears, and a cursor is 16 points of feedback
    /// somewhere the eye is not.
    ///
    /// A temporary attribute rather than an edit to the text storage. The
    /// storage is what `intrinsicContentSize` measures and what an answer
    /// streams into, and neither should ever see a decoration that belongs to
    /// the mouse. Temporary attributes are the layout manager's own channel for
    /// exactly this, they do not re-wrap the text, and they are dropped when the
    /// text is replaced.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow,
                      .inVisibleRect],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        underline(link(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        underline(nil)
    }

    private func underline(_ range: NSRange?) {
        guard range != underlined else { return }
        if let old = underlined, let manager = layoutManager,
           NSMaxRange(old) <= (textStorage?.length ?? 0) {
            manager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: old)
        }
        if let range {
            layoutManager?.addTemporaryAttributes(
                [.underlineStyle: NSUnderlineStyle.single.rawValue],
                forCharacterRange: range)
        }
        underlined = range
    }

    /// The whole of the link at a point in the view, or nil for anything else.
    private func link(at point: NSPoint) -> NSRange? {
        guard let manager = layoutManager, let container = textContainer,
              let storage = textStorage, manager.numberOfGlyphs > 0 else { return nil }
        let inside = NSPoint(x: point.x - textContainerInset.width,
                             y: point.y - textContainerInset.height)
        let glyph = manager.glyphIndex(for: inside, in: container)
        // **`glyphIndex(for:in:)` answers with the nearest glyph however far
        // away the point is**, so the pointer anywhere in the margin past the
        // end of a line comes back as the last character of it, and a centred
        // list of links underlines whichever one the mouse is level with. The
        // bounding rect is what tells being over a letter from being beside it.
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                        in: container)
        guard rect.contains(inside) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange()
        guard storage.attribute(.link, at: index, effectiveRange: &range) != nil else {
            return nil
        }
        return range
    }

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else {
            return super.intrinsicContentSize
        }
        // The container tracks the view's width, which the constraints set, so
        // laying out first is what makes this the height *after* wrapping
        // rather than the height of one very long line.
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: used.height + textContainerInset.height * 2)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A width change re-wraps, and re-wrapping changes the height. Without
        // this the line is measured once at the width it happened to be built
        // at and never again, so narrowing the window clips it.
        invalidateIntrinsicContentSize()
    }
}
