import AppKit

/// Naming an unnamed speaker, as a popover rather than a dialog.
///
/// **What this replaces was a stack of buttons in an alert**: a text field, a
/// "sounds like" line of prose, invitation names as loose buttons, and Save,
/// Merge and Discard underneath. Everything it could tell you was written as a
/// sentence, everything it could do was a button of equal weight, and naming
/// somebody you have named nine times before still meant typing their name
/// again.
///
/// This offers the answers instead. Every candidate the app has is a row you
/// can click: the voice bank's guess first, then whoever was on the invitation,
/// then everybody the library already knows. Typing filters them, and typing
/// something new offers to make it a person. Merge and Discard are still here,
/// because a phantom speaker over silence is not a person, but they are at the
/// bottom in the size they deserve.
/// Hearing the speaker, without this popover owning a player.
///
/// The pane behind it already has the recording open, the mixdown built or
/// buildable, and a waveform with a playhead on it, so a preview is a message to
/// that rather than a second audio path. The visible consequence is the point:
/// pressing play here moves the playhead below, colours the scrubber where that
/// person talks, and scrolls the transcript to them.
@MainActor
struct SpeakerPreview {
    /// Play this speaker's turns in order, one after the next.
    var play: () -> Void
    var pause: () -> Void
    /// Playing, or about to be once a mixdown has been built.
    var isPlaying: () -> Bool
    /// This popover has gone: dismissed, or closed because a name was applied.
    ///
    /// **Playing one speaker belongs to the popover and ends with it.** The rule
    /// exists to answer the question this popover is asking, so one that outlived
    /// it would be a player that skips most of the meeting with nothing on screen
    /// still asking anything.
    var end: () -> Void
}

@MainActor
enum SpeakerPicker {
    private static var current: NSPopover?

    static func show(for recording: Recording, speaker: String,
                     from view: NSView, rect: NSRect,
                     preview: SpeakerPreview? = nil,
                     done: @escaping () -> Void) {
        present(PickerController(recording: recording, speaker: speaker,
                                 preview: preview, purpose: .name) {
                                     current?.performClose(nil)
                                     done()
                                 },
                from: view, rect: rect)
    }

    /// Choose somebody for one sentence or one turn, rather than for a speaker.
    ///
    /// The same list and deliberately the same controller. "Which of the people
    /// I know is this" is a question this app already answers well, with the
    /// voice bank's ranking, the invitation and the roster in one place, and a
    /// second smaller list built for the transcript's menu would be the first
    /// place somebody stopped being suggested.
    ///
    /// What it does not carry is Merge and Discard. Those are repairs to a whole
    /// speaker, and this popover is open about a paragraph.
    static func choose(for recording: Recording, speaker: String, asking: String,
                       from view: NSView, rect: NSRect,
                       pick: @escaping (String) -> Void) {
        present(PickerController(recording: recording, speaker: speaker,
                                 preview: nil,
                                 purpose: .pick(asking: asking, apply: pick)) {
                                     current?.performClose(nil)
                                 },
                from: view, rect: rect)
    }

    private static func present(_ controller: NSViewController,
                                from view: NSView, rect: NSRect) {
        current?.performClose(nil)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        // Downward, like every other popover in this window: these sit near the
        // top of the pane, and one that does not fit above is not moved, it is
        // closed.
        DispatchQueue.main.async {
            // Refused rather than raised, for the reason `PersonPopover.show`
            // gives: an anchor with no window aborts the app here.
            guard view.window != nil else {
                trace("picker: anchor left the window before it opened")
                return
            }
            popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
        }
        current = popover
    }

    static func close() {
        current?.performClose(nil)
        current = nil
    }
}

/// One candidate, from wherever it came.
private struct Candidate {
    /// What gets written into the transcript.
    ///
    /// Apart from the user this is the same string as `name`. The microphone
    /// track is `Me` on disk however you have chosen to be shown, so the two
    /// have to be carried separately or the row that reads "Maxime" writes a
    /// second person called Maxime beside the `Me` who is already you. This
    /// library holds that exact case from the import and it is not one to add
    /// to.
    var label: String
    /// What the row reads.
    var name: String
    /// The address that asserts *which* attendee this is, when the candidate
    /// came from an invitation. Picking the row claims it for that name.
    var email: String?
    var detail: String
    /// Sorts and groups the list. The order is confidence: what a human already
    /// said, then what the invitation says, then what the voice suggests.
    var section: String
}

/// What the popover is being opened to settle.
///
/// The list of candidates is the same in both, and everything else differs: the
/// question at the top, whether the two whole-speaker repairs are at the bottom,
/// and where the answer is written.
@MainActor
private enum Purpose {
    /// Name this speaker, everywhere they appear in this recording.
    case name
    /// Name whoever said one sentence or one turn, leaving the speaker
    /// otherwise as it was. The closure is handed the label to write.
    case pick(asking: String, apply: (String) -> Void)
}

@MainActor
private final class PickerController: NSViewController, NSTextFieldDelegate {
    private let recording: Recording
    private let speaker: String
    private let purpose: Purpose
    private let done: () -> Void

    private let field = NSTextField(string: "")
    private var rows: NSStackView!
    private var candidates: [Candidate] = []

    /// How to hear the speaker, or nil where there is no pane behind this to
    /// play it: `SpeakerSheet` presents the same question from a window.
    private let preview: SpeakerPreview?
    private let playButton = NSButton()
    /// Keeps the play button honest while the popover is open. See
    /// `viewDidAppear`.
    private var poll: Timer?

    private static let width: CGFloat = 320

    init(recording: Recording, speaker: String, preview: SpeakerPreview?,
         purpose: Purpose, done: @escaping () -> Void) {
        self.recording = recording
        self.speaker = speaker
        self.preview = preview
        self.purpose = purpose
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let asked: String
        switch purpose {
        // A named speaker is a different question with the same answers. "Who is
        // Céline Goossens?" reads as the app having forgotten, when what is
        // being said is that the name on this voice is wrong.
        case .name where !VoiceBank.isPlaceholder(speaker):
            asked = "Who is this really?"
        case .name:
            asked = "Who is \(SpeakerName.display(speaker))?"
        case .pick(let asking, _):
            asked = asking
        }
        let title = NSTextField(labelWithString: asked)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(title)

        // Only when there is a length to print. `Recording.length` gives an
        // empty string for anything under a second, and "Spoke for  of this
        // recording" is what that reads as in a sentence built around it.
        let spoken = People.speakers(in: recording).first { $0.label == speaker }?.seconds
        let howLong = spoken.map(Recording.length) ?? ""

        // **Hearing them is the evidence this question needs, and it was the one
        // thing not on offer.** Everything else here is inference: how long they
        // spoke, what the voice bank ranks them against, who was on the
        // invitation. Two seconds of the voice settles what all of that is
        // circling, and until this button existed the only way to get it was to
        // dismiss the popover, hunt the transcript for one of their paragraphs
        // and click it, which on a two hour meeting where somebody speaks for
        // one minute is a search rather than a click.
        //
        // It plays in the pane behind rather than owning a player: the mixdown
        // is loaded there, and the visible side effects are the point. See
        // `SpeakerPreview`.
        if preview != nil {
            playButton.bezelStyle = .rounded
            playButton.controlSize = .small
            playButton.imagePosition = .imageLeading
            playButton.target = self
            playButton.action = #selector(togglePreview)
            playButton.toolTip = "Play what they said, skipping everybody else"
            drawPreviewButton()

            // Says what the button does when there is no length to report,
            // rather than leaving a bare glyph with nothing beside it.
            let detail = NSTextField(labelWithString: howLong.isEmpty
                ? "Hear them before naming them"
                : "Spoke for " + howLong + " of this recording")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            let row = NSStackView(views: [playButton, detail])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            stack.addArrangedSubview(row)
        } else if case .pick = purpose {
            // What changes, and what does not. Handing a paragraph to somebody
            // else reads as an edit to the transcript until it says otherwise,
            // and the words being untouched is the reason this is safe to try.
            let detail = NSTextField(wrappingLabelWithString:
                "Only who it is attributed to changes. The words and the audio "
                + "stay as they are.")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            stack.addArrangedSubview(detail)
            detail.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true
        } else if !howLong.isEmpty {
            let detail = NSTextField(labelWithString:
                "Spoke for " + howLong + " of this recording")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            stack.addArrangedSubview(detail)
        }

        field.placeholderString = "Name, or search people"
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.target = self
        field.action = #selector(commitTyped)
        stack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true

        rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 1
        rows.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.contentView = TopAlignedClipView()
        scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: Self.width - 28),
            scroll.heightAnchor.constraint(equalToConstant: 220),
            rows.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])

        // Both belong to naming a speaker. Choosing who said one paragraph is a
        // narrower question, and Merge and Discard would answer a wider one than
        // was asked: they act on everything that speaker ever said.
        if case .name = purpose { addRepairs(to: stack) }

        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        view = container

        candidates = gather()
        render()
    }

    /// The repairs, at the bottom and small, and **which ones depends on whether
    /// this speaker has a name.**
    ///
    /// Discard is for a phantom: a stretch of silence the diarizer split off and
    /// Parakeet wrote filler over. A phantom is unnamed by definition, so on a
    /// speaker somebody has named it is never the right answer, and it was the
    /// wrong answer somebody reached for. They had named a placeholder to see
    /// what would happen, wanted that undone, found Merge and Discard, and
    /// pressed the destructive one. Discard is therefore not on the named side
    /// at all, and what stands in its place is the undo they were looking for.
    ///
    /// It stays reachable in one click: Leave Unnamed puts the speaker back to a
    /// letter, and this popover then offers Discard.
    ///
    /// No trailing ellipsis on any of them. The convention says one when a
    /// control opens something that asks for more, and in a popover that is
    /// *already* the thing asking, dotted verbs at the foot of a list read as
    /// unfinished rather than as considerate. The tooltips say what each one
    /// means, which the dots never did.
    private func addRepairs(to stack: NSStackView) {
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalToConstant: Self.width - 28).isActive = true

        var buttons: [NSButton] = []
        if !VoiceBank.isPlaceholder(speaker) {
            let unname = small("Leave Unnamed", #selector(unnameSpeaker))
            unname.toolTip = "Take the name off this speaker in this recording. "
                + "Everything they said stays, and you can name them again."
            buttons.append(unname)
        }
        let merge = small("Merge", #selector(mergeSpeaker))
        merge.toolTip = "This speaker is really one of the others in this recording"
        buttons.append(merge)
        if VoiceBank.isPlaceholder(speaker) {
            let discard = small("Discard", #selector(discardSpeaker))
            discard.toolTip = "There is no person here, only noise the diarizer "
                + "split off. Their lines are deleted."
            buttons.append(discard)
        }

        let footer = NSStackView(views: buttons)
        footer.orientation = .horizontal
        footer.spacing = 8
        stack.addArrangedSubview(footer)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)

        // The pane can stop on its own, at the end of the last thing this
        // speaker said, and nothing reports that back here. A button drawn once
        // would then be offering to pause something that has already stopped,
        // which is the small kind of lie that makes people stop trusting a
        // control. Three times a second, for as long as one popover is open.
        guard preview != nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in self.drawPreviewButton() }
        }
    }

    /// Closing puts the transcript back, however it was closed.
    ///
    /// The one lifecycle hook both routes go through: clicking away dismisses a
    /// `.transient` popover without telling anybody, and applying a name closes
    /// it from the inside. Hanging the undo on this rather than on a delegate
    /// means there is no case where the filter is left on with nothing on screen
    /// explaining it.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        poll?.invalidate()
        poll = nil
        // Stopped as well as unfiltered, because a preview that outlives the
        // question it was answering is a meeting playing to nobody.
        preview?.pause()
        preview?.end()
    }

    private func drawPreviewButton() {
        let playing = preview?.isPlaying() ?? false
        playButton.title = playing ? "Pause" : "Play"
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? "Pause" : "Play")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
    }

    @objc private func togglePreview() {
        guard let preview else { return }
        if preview.isPlaying() { preview.pause() } else { preview.play() }
        // Redrawn at once rather than waiting for the poll. `isPlaying` reports
        // "about to be" as well as "is", so the first press on a recording whose
        // mixdown has still to be built flips the button immediately instead of
        // sitting on "Play" for the seconds that takes.
        drawPreviewButton()
    }

    // MARK: - Candidates

    /// Everybody this app could mean, in descending order of confidence.
    private func gather() -> [Candidate] {
        var out: [Candidate] = []
        // Never offered: anybody already in this recording. They are accounted
        // for, and naming two speakers the same thing is a merge, which is the
        // button at the bottom that says so.
        let taken = Set(recording.speakers)

        // A word rather than a percentage, and how much was heard rather than a
        // score. See `VoiceConfidence`: the number it replaced ran on a scale
        // where the whole answer lives between 0.37 and 0.91, so "60%" read as a
        // coin flip on a match that was not close.
        let ranked = VoiceBank.suggestions(for: speaker, in: recording)
        for match in ranked where !taken.contains(match.name) {
            var detail = match.confidence.label
            detail += " · heard in \(match.recordings) "
                + (match.recordings == 1 ? "recording" : "recordings")
            // Named only when it is genuinely close, because the runner-up is
            // the thing a ranked list hides. Two candidates a hair apart look
            // identical to one candidate standing alone, and that is exactly the
            // case where somebody should listen before choosing.
            if match.name == ranked.first?.name, match.margin < VoiceBank.marginThreshold,
               let second = ranked.dropFirst().first {
                detail += " · close to \(SpeakerName.display(second.name))"
            }
            out.append(Candidate(label: match.name,
                                 name: SpeakerName.display(match.name), email: nil,
                                 detail: detail, section: "Sounds like"))
        }

        let named = Set(out.map(\.label))
        for person in (recording.metadata.calendar_people ?? [])
        where !person.is_me {
            guard let name = person.bestName, !taken.contains(name),
                  !named.contains(name) else { continue }
            out.append(Candidate(label: name, name: name, email: person.email,
                                 detail: [person.email,
                                          person.is_organizer ? "organizer" : nil]
                                     .compactMap { $0 }.joined(separator: " · "),
                                 section: "In the invitation"))
        }

        // You are in this list, unless you are already in this recording, and
        // `taken` is what says so: the microphone track is on disk as `Me`, so
        // the ordinary "anybody already accounted for" rule covers it. What
        // this replaced was an explicit `!person.isYou`, which left an imported
        // mix-only recording, the one kind with no microphone side, unable to
        // say that a speaker was you at all.
        let offered = Set(out.map(\.label))
        for person in People.roster()
        where !taken.contains(person.label) && !offered.contains(person.label) {
            out.append(Candidate(label: person.label, name: person.display, email: nil,
                                 detail: person.summary, section: "People"))
        }
        return out
    }

    private func render() {
        for row in rows.arrangedSubviews { row.removeFromSuperview() }
        let query = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = candidates.filter {
            query.isEmpty || $0.name.lowercased().contains(query)
                || $0.detail.lowercased().contains(query)
        }

        var section = ""
        for candidate in shown {
            if candidate.section != section {
                section = candidate.section
                let label = NSTextField(labelWithString: section.uppercased())
                label.font = .systemFont(ofSize: 10, weight: .semibold)
                label.textColor = .tertiaryLabelColor
                rows.addArrangedSubview(label)
            }
            addRow(for: candidate)
        }

        // Typing something nobody is called offers to make it somebody. The row
        // rather than a second button, so creating and choosing are one gesture
        // in one list.
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty, !shown.contains(where: {
            $0.name.localizedCaseInsensitiveCompare(typed) == .orderedSame }) {
            let new = NSButton(title: "New person “\(typed)”", target: self,
                               action: #selector(commitTyped))
            new.isBordered = false
            new.font = .systemFont(ofSize: 13, weight: .medium)
            new.alignment = .left
            new.contentTintColor = Brand.accent
            rows.addArrangedSubview(new)
            new.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            new.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }

        if shown.isEmpty, typed.isEmpty {
            let none = NSTextField(labelWithString:
                "Nobody to suggest yet. Type a name.")
            none.font = .systemFont(ofSize: 12)
            none.textColor = .tertiaryLabelColor
            rows.addArrangedSubview(none)
        }
    }

    private func addRow(for candidate: Candidate) {
        let disc = InitialsDisc(size: 22)
        // The label, not the name: the disc takes its colour from the string on
        // disk, so passing the display name gives you a different colour here
        // from the one your chip has two inches above.
        disc.show(Person(label: candidate.label, recordings: [], seconds: 0))
        let name = NSTextField(labelWithString: candidate.name)
        name.font = .systemFont(ofSize: 13)
        let detail = NSTextField(labelWithString: candidate.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        for label in [name, detail] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        let content = NSStackView(views: [disc, text])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8

        // A row that lights up, so a list of people reads as a list of things
        // you can pick rather than as a paragraph about them.
        let row = HoverRow(content: content, target: self, action: #selector(pick(_:)),
                           inset: 4, height: 34)
        row.identifier = NSUserInterfaceItemIdentifier(candidate.label)
        // Added and constrained in that order: a constraint between two views
        // with no common ancestor throws rather than laying out badly.
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    // MARK: - Choosing

    @objc private func pick(_ sender: NSView) {
        guard let label = sender.identifier?.rawValue else { return }
        let email = candidates.first { $0.label == label }?.email
        apply(label: label, email: email)
    }

    @objc private func commitTyped() {
        let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        // An exact match in the list is that person, not a new one of the same
        // name.
        let match = candidates.first {
            $0.name.localizedCaseInsensitiveCompare(typed) == .orderedSame
        }
        apply(label: match?.label ?? Self.label(for: typed), email: match?.email)
    }

    /// The string to write for a name somebody typed.
    ///
    /// Your own name resolves back to `Me`. `SpeakerName.display` turns that
    /// label into the name you chose everywhere it is read, so typing that name
    /// in means the microphone track; taking it literally would file a second
    /// person under a name that already appears in the roster, and the two
    /// would never merge because nothing on disk says they are the same. Same
    /// accept-what-they-meant rule as `People.findByDisplayName`.
    private static func label(for typed: String) -> String {
        typed.localizedCaseInsensitiveCompare(SpeakerName.display(SpeakerName.you))
            == .orderedSame ? SpeakerName.you : typed
    }

    private func apply(label: String, email: String?) {
        if let problem = check(label) {
            let alert = NSAlert()
            alert.messageText = problem.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        switch purpose {
        case .name:
            TranscriptEditor.apply(.rename(speaker, to: label), to: recording)
        case .pick(_, let write):
            write(label)
        }
        // The address, only when a row carrying one was picked. Typing a name
        // freehand asserts nothing about who was on the invitation, which is the
        // standard the book already holds.
        if let email { ContactBook.link(email, to: label) }
        done()
    }

    /// Whether this name can be written, which depends on what it is being
    /// written onto.
    ///
    /// `People.checkSpeaker` and not `People.check` for naming: that writes one
    /// label onto one speaker in one transcript, where `Me` is a legitimate
    /// answer and the library-wide rename's refusal of it is not. See the
    /// comment on `checkSpeaker`.
    ///
    /// **Picking refuses less still, and `recordingHasYou` is the difference.**
    /// Saying "that sentence was me" in a recording that already has a
    /// microphone track is not a collision to be sent to Merge: it is the merge,
    /// at the size of one sentence, and it is the exact repair for the case
    /// where the far end came back in through the microphone and the diarizer
    /// split it off as a stranger.
    private func check(_ label: String) -> People.RenameProblem? {
        switch purpose {
        case .name:
            return People.checkSpeaker(label, in: recording)
        case .pick:
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .empty }
            // A letter is still refused. Every placeholder in this recording is
            // already an item in the menu this popover was opened from, so
            // typing one here can only mean a person called "B", which is the
            // name that reads as a speaker nobody has labelled yet.
            if VoiceBank.isPlaceholder(trimmed) { return .looksLikePlaceholder(trimmed) }
            return nil
        }
    }

    func controlTextDidChange(_ note: Notification) { render() }

    // MARK: - The two repairs

    @objc private func mergeSpeaker() {
        let others = recording.speakers.filter { $0 != speaker }
        guard !others.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "There is nobody else in this recording to merge into."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Merge \(SpeakerName.display(speaker)) into which speaker?"
        alert.informativeText = "Every segment attributed to them is reassigned. "
            + "This is for a person diarization split in two."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        popup.addItems(withTitles: others.map(SpeakerName.display))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              popup.indexOfSelectedItem >= 0 else { return }
        TranscriptEditor.apply(.merge(speaker, into: others[popup.indexOfSelectedItem]),
                               to: recording)
        done()
    }

    /// Put a named speaker back to a letter, here and nowhere else.
    ///
    /// No confirmation, because there is nothing to lose: every word stays where
    /// it is, the voiceprint moves to the letter, and naming them again is the
    /// list this popover is already showing. Confirming a reversible edit only
    /// teaches people to click through the dialogs that matter.
    @objc private func unnameSpeaker() {
        People.unname(speaker, in: recording)
        done()
    }

    /// Delete everything a phantom speaker "said".
    ///
    /// The warning is `SpeakerSheet.confirmDiscard`, shared with the sheet that
    /// offers the same repair, so there is one account of what this costs rather
    /// than two that can disagree about how alarming it is.
    @objc private func discardSpeaker() {
        guard SpeakerSheet.confirmDiscard(speaker, in: recording) else { return }
        TranscriptEditor.apply(.discard(speaker), to: recording)
        done()
    }

    /// A capsule at the foot of the popover.
    ///
    /// **The width is stated, because an `.inline` bezel has no content inset
    /// to set.** AppKit draws one of these tight around its title, which reads
    /// as cramped beside the popover's own 14 point margins and the 34 point
    /// rows above it. Padding the title with spaces is the usual way out and it
    /// is not precise: a space is about three and a half points at this size,
    /// so the padding comes in steps of that and changes with the font.
    /// Measuring the string and adding a margin either side is what
    /// `SpeakerPill` already does, and it says what it means.
    ///
    /// `.regular` rather than `.small`: these are the only two controls at the
    /// bottom of the card, and a smaller-than-standard control is for a place
    /// that is short of room.
    private static let footerPadding: CGFloat = 18
    private static let footerHeight: CGFloat = 28

    private func small(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.controlSize = .regular
        b.translatesAutoresizingMaskIntoConstraints = false
        let font = b.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let text = ceil((title as NSString).size(withAttributes: [.font: font]).width)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: text + Self.footerPadding * 2),
            b.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
        return b
    }
}
