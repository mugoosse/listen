import AVFoundation
import AppKit

/// The right-hand pane: player on top, transcript below as speaker-grouped
/// turns.
///
/// Clicking a sentence plays from it. Clicking a speaker name opens the
/// labelling affordance. The playhead highlights the turn being spoken, which is
/// what makes this readable while listening rather than instead of listening.
@MainActor
final class DetailView: NSView {
    fileprivate var recording: Recording?
    private var turns: [Turn] = []
    private var sentences: [[Merge.Sentence]] = []

    /// Editable in place. A recording's name is the one piece of text in this
    /// window that belongs to the user rather than the pipeline, and putting it
    /// behind a dialog makes renaming feel like a settings change rather than
    /// typing.
    let titleLabel = NSTextField(string: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let chips = SpeakerChips()
    private let tagChips = TagChips()
    private let playerCard = NSView()
    private let playButton = NSButton()
    private let waveform = WaveformView()
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")

    /// Which speaker the transcript is narrowed to, or nil for everybody.
    ///
    /// **A view state, never a change to `turns`.** `refresh` finds the turn
    /// being spoken by indexing into `turns` and uses that index into
    /// `turnViews`, twenty times a second, so filtering either array would put
    /// the playhead's highlight on somebody else's paragraph. Both stay whole
    /// and the views that do not match are hidden, which `NSStackView` collapses
    /// for free.
    private var soloed: String?

    /// What says the transcript is not all of the meeting.
    ///
    /// Stated rather than left to be inferred from a shorter page. There is no
    /// button on it and it needs none: the filter lasts exactly as long as the
    /// popover that opened it, so the way back is to finish with the popover,
    /// which is where the pointer already is.
    private let soloBar = NSView()
    private let soloLabel = NSTextField(labelWithString: "")
    private var soloTop: NSLayoutConstraint!
    private var soloHeight: NSLayoutConstraint!

    /// Which popover owns the current solo.
    ///
    /// A `.transient` popover reports its close whenever it gets round to it,
    /// and clicking a second chip opens one popover while closing another, so a
    /// late close from the one being replaced would clear the filter the new one
    /// just set. Each opening takes the next token and a close only undoes its
    /// own, which makes the order the two callbacks arrive in stop mattering.
    private var soloToken = 0

    /// What stands in for the transport when the audio is on another Mac.
    ///
    /// In the card rather than instead of it, so the transcript does not move
    /// and the empty space is visibly the player's rather than a gap. See
    /// `setPlayer`.
    private let playerNote = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")

    /// The meeting being read, drawn while it happens. Replaces the sentence
    /// above for the one state that has something to show rather than something
    /// to explain.
    private let transcribing = TranscribingView()
    private let emptyIcon = BrandIcon.view(size: 64, accessibilityLabel: "Listen mascot")

    /// Which document this pane is showing.
    ///
    /// A mode rather than two panes side by side: the transcript and a note are
    /// both the whole width of the reading area, and neither is worth half of
    /// it. Held in a property rather than read back off the segmented control,
    /// which is `DictionaryPane`'s rule and for the same reason: a re-render
    /// would otherwise snap it back to whatever the control last drew.
    private enum Showing { case transcript, notes }
    private var showing: Showing = .transcript

    private let modeBar = NSView()
    private let modePicker = NSSegmentedControl(
        labels: ["Transcript", "Notes"], trackingMode: .selectOne, target: nil, action: nil)
    /// Analog's artifact switcher, which is the part of their notes design worth
    /// copying: a recording has any number of notes and they are all the same
    /// kind of thing, so the way to move between them is a list of their names.
    private let notePicker = NSPopUpButton()
    private let notesScroll = NSScrollView()
    private let notesText = NSTextView()
    /// Who wrote the note on screen, above it rather than inside it.
    ///
    /// It used to be the first paragraph of the text view, which was fine while
    /// every note was read-only and became a bug the moment one was not: the
    /// user's own note is editable, and provenance you can put the cursor in
    /// and delete is not provenance.
    private let noteInfo = LinkLine()
    private let notesPlaceholder = PassthroughLabel(labelWithString: "")

    /// Where the note's text starts inside `notesScroll`, split the way AppKit
    /// splits it: the scroll view's content inset, then the text view's own.
    /// Three things read these and have to agree, or the caret and the prompt
    /// it sits on end up on different lines.
    private static let notesTopInset: CGFloat = 14
    /// Small, because the provenance line above already separates the note from
    /// the toggle. It was 16, which stacked with that line and left the first
    /// character of an empty note a long way from anything.
    private static let notesTextInset: CGFloat = 2

    /// Pending write of the user's own note, and whether one is in flight.
    ///
    /// Their note materialises on the first keystroke, so every keystroke is a
    /// potential file write. Coalesced rather than debounced away entirely:
    /// losing a sentence because the app was killed is worse than a small write.
    private var noteSaveTimer: Timer?

    /// The notes on the selected recording, oldest first, and which one is up.
    private var notes: [Note] = []
    private var showingNote: String?
    /// What the notes folder looked like when it was last drawn, so an app that
    /// comes back to the front does not rebuild a pane nobody changed and lose
    /// the reader's scroll position doing it.
    private var notesSignature = ""

    private var modeTop: NSLayoutConstraint!
    private var modeHeight: NSLayoutConstraint!
    private var playerTop: NSLayoutConstraint!
    private var playerHeight: NSLayoutConstraint!
    private var noteInfoTop: NSLayoutConstraint!
    private var noteInfoHeight: NSLayoutConstraint!
    /// Whether this recording has anything to play. Held rather than recomputed,
    /// because the player is now collapsed by the mode as well as by the audio
    /// and both have to agree.
    private var hasAudio = false

    /// Fires when this pane changes something the list also shows.
    var onChanged: (() -> Void)?

    private var player: AVAudioPlayer?
    private var tick: Timer?
    private var turnViews: [TurnView] = []

    /// The playhead, kept here rather than read from the player.
    ///
    /// The player does not exist until somebody presses play, and building it
    /// can mean building a mixdown first. Scrubbing has to move the playhead
    /// now, not once an hour of audio has been mixed, so the view owns the
    /// position and hands it to the player when there is one.
    private var position: TimeInterval = 0
    private var length: TimeInterval = 0
    private var preparing = false
    private var currentTurn: Int?

    /// One load at a time. Clicking down a long sidebar starts a waveform read
    /// per recording, and without this the last one to finish wins rather than
    /// the one that is selected.
    private var waveformToken = 0

    /// The speaker row's two collapsible dimensions, kept so a recording with
    /// no transcript closes the gap entirely rather than showing an empty band
    /// where the chips would be.
    private var chipsTop: NSLayoutConstraint!
    private var chipsHeight: NSLayoutConstraint!

    /// Whether the transcript follows the playhead. Turned off the moment the
    /// user scrolls, because scrolling away during playback is a decision, and
    /// dragging somebody back to the playhead every two seconds makes the
    /// transcript unreadable while it plays.
    private var follows = true
    private var scrollingProgrammatically = false

    /// The turn with a sentence open for editing, if any.
    ///
    /// Held weakly and cleared on every re-render, because the view it points at
    /// is thrown away and rebuilt whenever the transcript changes.
    private weak var editingTurn: TurnView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        // Looks like a heading until it has focus, then behaves like a field.
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.focusRingType = .none
        titleLabel.delegate = self
        titleLabel.cell?.usesSingleLineMode = true
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        playButton.bezelStyle = .circular
        playButton.image = NSImage(
            systemSymbolName: "play.fill", accessibilityDescription: "Play")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.toolTip = "Play"

        waveform.onScrub = { [weak self] fraction in self?.scrub(to: fraction) }

        // A chip is a control, so its click never reaches `mouseDown` below and
        // it has to let the title field go itself. `editSpeaker` does that,
        // because it has to happen in a particular order: see the comment
        // there.
        chips.onName = { [weak self] speaker, anchor, rect in
            self?.editSpeaker(speaker, from: anchor, rect: rect)
        }
        chips.onChanged = { [weak self] in
            guard let self, let id = self.recording?.id,
                  let updated = Recording.find(id) else { return }
            self.show(updated)
            LibraryWindow.shared.reload()
        }
        // Named or unnamed, the same funnel. `editSpeaker` routes on the label,
        // and a chip that reports a name is a chip whose label is not a
        // placeholder, so the two agree by construction.
        chips.onPerson = { [weak self] speaker, anchor, rect in
            self?.editSpeaker(speaker, from: anchor, rect: rect)
        }

        // Clicking a tag is a lens on the library rather than an edit, so it
        // goes straight to the sidebar. `endEditing` first for the reason a chip
        // needs it: a pill is a control, so its click never reaches `mouseDown`
        // and the title field would keep the caret.
        tagChips.onTag = { [weak self] name, _, _ in
            self?.endEditing()
            LibraryWindow.shared.filter(byTag: name)
        }
        tagChips.onAdd = { [weak self] anchor, rect in
            self?.editTags(from: anchor, rect: rect)
        }
        tagChips.onChanged = { [weak self] in self?.refreshTags() }

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        // A card, so the player reads as one control rather than three that
        // happen to share a line. The transcript below is the page; this is the
        // instrument on top of it.
        playerCard.wantsLayer = true
        playerCard.layer?.cornerRadius = 12
        playerCard.layer?.borderWidth = 1
        styleCard()

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 4, bottom: 40, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The clip view has to be flipped, and it has to be replaced before the
        // document view is set. An NSClipView is not flipped by default, so its
        // origin is the bottom left and a document view shorter than the
        // viewport is placed at the *bottom*: a two-line transcript sat on the
        // floor of the window with the whole meeting's worth of empty space
        // above it, which reads as a rendering fault rather than as a layout
        // rule. Flipped, short content starts at the top and grows downward,
        // which is also the direction a conversation runs.
        scroll.contentView = TopAlignedClipView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(userScrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        buildNotesPane()

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        // Wrapping, and told what width to wrap at. An `NSTextField` computes
        // its height from `preferredMaxLayoutWidth` rather than from the width
        // it is given, so without both it stays one line and truncates: every
        // message here used to be short enough that nobody noticed, and the
        // first longer one came back as "…written by an agent connecte".
        empty.maximumNumberOfLines = 0
        empty.preferredMaxLayoutWidth = 320
        empty.cell?.wraps = true

        playerNote.font = .systemFont(ofSize: 12)
        playerNote.textColor = .secondaryLabelColor
        playerNote.lineBreakMode = .byTruncatingTail
        playerNote.isHidden = true

        soloLabel.font = .systemFont(ofSize: 12)
        soloLabel.textColor = .secondaryLabelColor
        soloLabel.lineBreakMode = .byTruncatingTail
        soloBar.isHidden = true
        soloLabel.translatesAutoresizingMaskIntoConstraints = false
        soloBar.addSubview(soloLabel)

        for v in [playButton, timeLabel, waveform, playerNote] {
            v.translatesAutoresizingMaskIntoConstraints = false
            playerCard.addSubview(v)
        }
        for v in [modePicker, notePicker] {
            v.translatesAutoresizingMaskIntoConstraints = false
            modeBar.addSubview(v)
        }
        for v in [titleLabel, subtitleLabel, chips, tagChips, playerCard, modeBar,
                  soloBar, scroll, noteInfo, notesScroll, notesPlaceholder, empty,
                  emptyIcon, transcribing] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        chipsTop = chips.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor,
                                              constant: 10)
        chipsHeight = chips.heightAnchor.constraint(equalToConstant: 24)

        // Above the player, not below it. The player belongs to the transcript:
        // a transcript is a thing you read while listening, and a note is a
        // thing you write. Under the player, the toggle read as a control on
        // the recording rather than a choice of document, and switching to
        // Notes left a 58 point transport on screen with nothing to transport.
        //
        // Collapsible for the reason the chips row is: a hidden view still
        // occupies its frame.
        modeTop = modeBar.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 14)
        modeHeight = modeBar.heightAnchor.constraint(equalToConstant: 24)
        playerTop = playerCard.topAnchor.constraint(equalTo: modeBar.bottomAnchor,
                                                    constant: 10)
        playerHeight = playerCard.heightAnchor.constraint(equalToConstant: 58)
        // An empty note has nothing to say about itself: no date, because it has
        // never been saved. A label with an empty string still occupies a line,
        // so the caret sat forty points below the toggle with nothing between
        // them, which reads as a field that has come loose from its heading.
        soloTop = soloBar.topAnchor.constraint(equalTo: playerCard.bottomAnchor,
                                               constant: 0)
        soloHeight = soloBar.heightAnchor.constraint(equalToConstant: 0)
        noteInfoTop = noteInfo.topAnchor.constraint(equalTo: scroll.topAnchor)
        noteInfoHeight = noteInfo.heightAnchor.constraint(equalToConstant: 0)
        noteInfoHeight.priority = .defaultHigh

        // Speakers grow rightward from the title, tags grow leftward from the
        // window's edge, and the gap between them is whatever is spare. See
        // `TagChips` for why they share one band rather than taking two.
        //
        // The tags yield first when the pane is narrowed. A speaker's name
        // truncated to "Dan…" is a person you cannot identify; a tag that has
        // gone into `+2` is one click away and still says how many there are.
        // Left to the defaults the two would compress in whatever order the
        // engine liked, which is the same at one width and different at
        // another.
        chips.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        tagChips.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chips.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            chipsTop,
            chipsHeight,
            chips.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: tagChips.leadingAnchor,
                                            constant: -12),

            tagChips.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            tagChips.centerYAnchor.constraint(equalTo: chips.centerYAnchor),
            tagChips.heightAnchor.constraint(equalTo: chips.heightAnchor),
            // Never past the title's leading edge, so a recording with six tags
            // and nobody named still starts where every other row of this
            // header does.
            tagChips.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                              constant: 24),
        ])

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            playerTop,
            playerHeight,
            playerCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            playerCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            playerNote.leadingAnchor.constraint(equalTo: playerCard.leadingAnchor, constant: 14),
            playerNote.trailingAnchor.constraint(lessThanOrEqualTo: playerCard.trailingAnchor,
                                                 constant: -14),
            playerNote.centerYAnchor.constraint(equalTo: playerCard.centerYAnchor),

            playButton.leadingAnchor.constraint(equalTo: playerCard.leadingAnchor, constant: 10),
            playButton.centerYAnchor.constraint(equalTo: playerCard.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 30),
            playButton.heightAnchor.constraint(equalToConstant: 30),
            timeLabel.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 10),
            timeLabel.centerYAnchor.constraint(equalTo: playerCard.centerYAnchor),
            // Fixed rather than hugging, so the waveform does not shift sideways
            // when the clock ticks past ten minutes.
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            waveform.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            waveform.trailingAnchor.constraint(equalTo: playerCard.trailingAnchor, constant: -14),
            waveform.centerYAnchor.constraint(equalTo: playerCard.centerYAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 36),

            modeTop,
            modeHeight,
            modeBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            modeBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            modePicker.leadingAnchor.constraint(equalTo: modeBar.leadingAnchor),
            modePicker.centerYAnchor.constraint(equalTo: modeBar.centerYAnchor),
            // Trailing, and allowed to shrink. A note titled with a whole
            // sentence would otherwise push the segmented control off the
            // leading edge of the pane.
            notePicker.trailingAnchor.constraint(equalTo: modeBar.trailingAnchor),
            notePicker.centerYAnchor.constraint(equalTo: modeBar.centerYAnchor),
            notePicker.leadingAnchor.constraint(
                greaterThanOrEqualTo: modePicker.trailingAnchor, constant: 12),

            // Between the player and the transcript, and collapsing to nothing
            // when nobody is soloed, for the reason the chips row collapses: a
            // hidden view keeps its frame, so leaving it would open a gap under
            // the player of every recording in the library.
            soloTop,
            soloHeight,
            soloBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            soloBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            soloLabel.leadingAnchor.constraint(equalTo: soloBar.leadingAnchor),
            soloLabel.centerYAnchor.constraint(equalTo: soloBar.centerYAnchor),
            soloLabel.trailingAnchor.constraint(lessThanOrEqualTo: soloBar.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: soloBar.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            noteInfoTop,
            noteInfo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            noteInfo.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            notesScroll.topAnchor.constraint(equalTo: noteInfo.bottomAnchor, constant: 6),
            notesScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            notesScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            notesScroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Exactly where the caret will be, and derived rather than measured
            // so the two cannot come apart again: the text starts at the scroll
            // view's top inset plus the text view's own. An `NSTextView` has no
            // placeholder of its own.
            notesPlaceholder.topAnchor.constraint(
                equalTo: notesScroll.topAnchor,
                constant: Self.notesTopInset + Self.notesTextInset),
            notesPlaceholder.leadingAnchor.constraint(equalTo: notesScroll.leadingAnchor),
            notesPlaceholder.trailingAnchor.constraint(equalTo: notesScroll.trailingAnchor),

            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -20),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            emptyIcon.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            emptyIcon.bottomAnchor.constraint(equalTo: empty.topAnchor, constant: -14),

            // Wider than the 320 the sentence is capped at, because it is a
            // picture of the recording rather than a paragraph: the wider it is
            // the more of the meeting each bar covers less of, which is the
            // whole point of drawing the envelope instead of a plain bar.
            transcribing.centerXAnchor.constraint(equalTo: centerXAnchor),
            transcribing.centerYAnchor.constraint(equalTo: centerYAnchor),
            transcribing.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor,
                                                  constant: 40),
            transcribing.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            transcribing.heightAnchor.constraint(equalToConstant: 210),
        ])

        // The pane's width up to that cap, which is `Pane.widthCapped`'s trick:
        // a low-priority equality against a required maximum resolves to the
        // smaller of the two. A custom view has no intrinsic width to fall back
        // on, so without an equality here it would lay out at zero and the
        // picture would be invisible rather than merely narrow.
        let width = transcribing.widthAnchor.constraint(equalTo: widthAnchor, constant: -80)
        width.priority = .defaultHigh
        width.isActive = true
    }

    // MARK: - Notes

    private func buildNotesPane() {
        modePicker.selectedSegment = 0
        modePicker.selectedSegmentBezelColor = Brand.tint
        modePicker.target = self
        modePicker.action = #selector(switchShowing)

        notePicker.target = self
        notePicker.action = #selector(pickNote)
        notePicker.font = .systemFont(ofSize: 12)
        notePicker.toolTip = "Which note to read"

        // A text view rather than a label, because the meetings a note is also
        // about have to be links here for the same reason they are in the note
        // pane: naming them and leaving them dead is naming a place with no way
        // to get to it.
        noteInfo.isEditable = false
        noteInfo.isSelectable = true
        noteInfo.drawsBackground = false
        noteInfo.delegate = self
        noteInfo.textContainerInset = .zero
        noteInfo.textContainer?.lineFragmentPadding = 0
        noteInfo.textContainer?.widthTracksTextView = true
        noteInfo.isVerticallyResizable = true
        noteInfo.isHorizontallyResizable = false
        noteInfo.setContentHuggingPriority(.required, for: .vertical)
        noteInfo.linkTextAttributes = [
            .foregroundColor: Brand.accent,
            .cursor: NSCursor.pointingHand,
        ]
        notesPlaceholder.font = .systemFont(ofSize: 13)
        notesPlaceholder.textColor = .tertiaryLabelColor
        notesPlaceholder.maximumNumberOfLines = 0
        notesPlaceholder.cell?.wraps = true
        notesPlaceholder.isHidden = true

        notesText.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
        notesText.isEditable = false
        notesText.isSelectable = true
        notesText.drawsBackground = false
        notesText.delegate = self
        // No rich text, no substitutions, no smart quotes. What is typed here
        // is markdown that an agent reads, so a curly apostrophe or an em dash
        // AppKit inserted on somebody's behalf is a character they did not
        // write sitting in a file they will later be quoted from.
        notesText.isRichText = false
        notesText.isAutomaticQuoteSubstitutionEnabled = false
        notesText.isAutomaticDashSubstitutionEnabled = false
        notesText.isAutomaticTextReplacementEnabled = false
        notesText.allowsUndo = true
        // Sized by its scroll view rather than by autolayout. A text view in a
        // scroll view is the one AppKit arrangement that still wants the
        // autoresizing mask: the document view's height is the text's, which
        // constraints cannot know before the layout manager has run.
        notesText.minSize = NSSize(width: 0, height: 0)
        notesText.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
        notesText.isVerticallyResizable = true
        notesText.isHorizontallyResizable = false
        notesText.autoresizingMask = [.width]
        // Small, because the provenance line above already separates the note
        // from the toggle. It was 16, which stacked with that line and left the
        // first character of an empty note a long way from anything.
        notesText.textContainerInset = NSSize(width: 0, height: Self.notesTextInset)
        // Zero, not the default 5. A text container pads its line fragments,
        // so the note's first character sat five points right of the label
        // above it and of the transcript beside it: close enough to read as a
        // mistake rather than as a margin, which is the same test the sidebar's
        // row inset was measured against.
        notesText.textContainer?.lineFragmentPadding = 0
        notesText.textContainer?.widthTracksTextView = true
        notesText.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)

        notesScroll.documentView = notesText
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notesScroll.isHidden = true
        // Room at the bottom for the floating Record button, which is in the
        // window's content host and therefore over this. It matters more here
        // than in the transcript: this one is typed into, so what ends up under
        // the button is the caret rather than a line somebody could scroll past.
        //
        // **The top inset has to be stated with it.** Setting `contentInsets`
        // turns `automaticallyAdjustsContentInsets` off, and the automatic top
        // inset here was 14: the note's first line, and therefore the caret, sat
        // at 16 below this scroll view because of it, which is where
        // `notesTopInset` puts the placeholder. Adding only a bottom inset
        // silently zeroed the top one, the caret jumped a line above the prompt
        // it is supposed to sit on, and nothing else moved to explain it.
        notesScroll.automaticallyAdjustsContentInsets = false
        notesScroll.contentInsets = NSEdgeInsets(top: Self.notesTopInset, left: 0,
                                                 bottom: RecordButton.clearance, right: 0)

        // An agent writes notes while this window is open and nothing on disk
        // announces it. Coming back to the app is the moment somebody expects
        // to see what it wrote, and re-reading one directory is cheap enough to
        // do on every activation.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// A hidden view still occupies its frame, so both dimensions have to go.
    private func setModeBarCollapsed(_ collapsed: Bool) {
        modeBar.isHidden = collapsed
        modeTop.constant = collapsed ? 0 : 14
        modeHeight.constant = collapsed ? 0 : 24
    }

    /// The player is on screen for the transcript and gone for a note.
    ///
    /// Collapsed rather than hidden, for the reason the chips row is: a hidden
    /// view keeps its frame, and 58 points of nothing above a note is worse
    /// than the player itself would have been. This also closes the gap a
    /// recording with no audio yet used to leave, which was the same bug
    /// nobody had noticed.
    private func setPlayerCollapsed(_ collapsed: Bool) {
        playerCard.isHidden = collapsed
        playerTop.constant = collapsed ? 0 : 10
        playerHeight.constant = collapsed ? 0 : 58
    }

    /// The player area has three states, and only two of them were ever built.
    ///
    /// Collapsing it whenever there was nothing to play was right while the only
    /// way to have no audio was to be recording right now, which the pane says
    /// in the transcript area anyway. Sharing a library between two Macs makes
    /// "the transcript is here and the audio is not" the **ordinary** state of
    /// every recording made on the other machine, and collapsed, that is a
    /// transcript with an unexplained gap above it where the player belongs.
    /// Measured by looking: it reads as playback being broken.
    ///
    /// So the card keeps its 58 points and its border and says why it is empty.
    /// Same size and same styling deliberately: the transcript does not move
    /// when you click between a local recording and a synced one, and the space
    /// is visibly the player's rather than a hole in the layout.
    ///
    /// The wording says where the audio **is**, not that it is missing. It is
    /// not missing, it is on the Mac that recorded it, and that is both the true
    /// sentence and the one that tells somebody what to do about it.
    private func setPlayer(hasAudio: Bool, hidden: Bool) {
        setPlayerCollapsed(hidden)
        for v in [playButton, timeLabel, waveform] as [NSView] { v.isHidden = !hasAudio }
        playerNote.isHidden = hasAudio
        playerNote.stringValue = "The audio for this meeting is on the Mac that recorded it."
    }

    @objc private func switchShowing(_ sender: NSSegmentedControl) {
        // A control swallows its own click, so it has to let the title field go
        // itself. Every control in this pane does the same.
        endEditing()
        saveYours()
        showing = sender.selectedSegment == 0 ? .transcript : .notes
        // A transport nobody can see is a transport nobody can pause, which is
        // the rule `enter(.settings)` already follows for the same reason.
        if showing == .notes { stopPlayback() }
        // Re-read on the way in rather than only on selection, so switching to
        // Notes is also the gesture that refreshes them.
        if showing == .notes { reloadNotes(reset: false) }
        applyShowing()
    }

    @objc private func pickNote(_ sender: NSPopUpButton) {
        endEditing()
        // Read the choice **first**. `saveYours` rebuilds this menu, and
        // `rebuildNotePicker` re-selects the note that is on screen, so asking
        // the sender afterwards returns the note you were leaving rather than
        // the one you picked. The symptom is a switcher that appears to do
        // nothing at all, which is exactly what it did.
        let picked = sender.selectedItem?.representedObject as? String
        // Before the selection moves, or the pending text is written to
        // whichever note is chosen next.
        saveYours()
        showingNote = picked
        rebuildNotePicker()
        renderNote()
    }

    @objc private func appBecameActive() {
        reloadNotes(reset: false)
    }

    // MARK: - The user's own note

    /// Open the Notes tab, on `slug` when one is named.
    ///
    /// The entry point from the Notes collection: clicking one of a note's
    /// source meetings lands on that recording, and landing on its transcript
    /// would be answering a question nobody asked. The note that was being read
    /// is selected too, so a synthesis of four meetings can be walked through
    /// its sources without losing your place in it.
    /// Open the Transcript tab, whatever mode this pane was left in.
    ///
    /// The mode survives a selection change, so arriving at a recording from a
    /// note's "Also about" line kept the Notes tab up, showing the same note
    /// again because the note is about both meetings. Only the title moved, and
    /// a page that does not visibly change is a click that did not appear to
    /// work. The transcript is the meeting, and it is different.
    func showTranscript() {
        saveYours()
        showing = .transcript
        applyShowing()
    }

    func showNote(_ slug: String?) {
        showing = .notes
        if let slug, notes.contains(where: { $0.slug == slug }) {
            showingNote = slug
            rebuildNotePicker()
            renderNote()
        }
        applyShowing()
    }

    /// Is the note on screen the one the user types into?
    private var showingYours: Bool {
        guard let recording else { return false }
        return showingNote == Notes.yoursSlug(for: recording.id)
    }

    /// Every keystroke schedules a write, and never more than one.
    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject === notesText, showingYours else { return }
        notesPlaceholder.isHidden = !notesText.string.isEmpty
        noteSaveTimer?.invalidate()
        noteSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in
            Task { @MainActor in self.saveYours() }
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as AnyObject === notesText else { return }
        saveYours()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any,
                  at charIndex: Int) -> Bool {
        guard let id = RecordingLink.id(link) else { return false }
        // No note named, so it lands on the transcript. See `showTranscript`:
        // the note being read is about that meeting too, so staying on the
        // Notes tab would show the same words under a different title.
        LibraryWindow.shared.open(recording: id, note: nil)
        return true
    }

    /// Write what is in the text view, if it is the user's own note.
    ///
    /// Called from everything that could take the text off screen: switching
    /// note, switching mode, switching recording, losing focus, closing the
    /// window. It is cheap and idempotent, so calling it too often costs a
    /// string comparison and calling it too rarely costs somebody a paragraph.
    func saveYours() {
        noteSaveTimer?.invalidate()
        noteSaveTimer = nil
        guard showingYours, let recording, notesText.isEditable else { return }
        do {
            let saved = try Notes.setYours(notesText.string, for: recording)
            // The in-memory list and the signature are updated here rather than
            // by re-reading, because re-reading would re-render the very text
            // view the caret is sitting in.
            notes = Notes.list(about: recording)
            if !notes.contains(where: { $0.slug == Notes.yoursSlug(for: recording.id) }) {
                notes.insert(Notes.yoursOrEmpty(for: recording), at: 0)
            }
            setProvenance(of: saved ?? Notes.yoursOrEmpty(for: recording))
            notesSignature = signature()
            rebuildNotePicker()
        } catch {
            // Said out loud rather than swallowed. A note that silently failed
            // to save is the worst thing this pane could do: the text is on
            // screen, so it looks kept.
            log("could not save your note: \(error.localizedDescription)")
        }
    }

    /// Re-read the notes folder, and redraw only if it changed.
    ///
    /// The signature check is what makes this safe to call on every activation:
    /// rebuilding the text view scrolls it back to the top, and losing your
    /// place in a note because you switched to another app and back is exactly
    /// the failure `renderTurns(scrollToTop:)` exists to avoid next door.
    private func reloadNotes(reset: Bool) {
        guard let recording else {
            notes = []
            notesSignature = ""
            return
        }
        // Never underneath somebody who is typing. Re-rendering the text view
        // would take the caret with it, and this runs on every activation.
        if !reset, showingYours, notesText.window?.firstResponder === notesText { return }

        notes = Notes.list(about: recording)
        // Their own note is offered whether or not it exists on disk. That is
        // what makes "open the tab and there is a cursor" true: no New Note
        // button, no naming step, and nothing written until a key is pressed.
        if !notes.contains(where: { $0.slug == Notes.yoursSlug(for: recording.id) }) {
            notes.insert(Notes.yoursOrEmpty(for: recording), at: 0)
        }
        if reset || showingNote == nil
            || !notes.contains(where: { $0.slug == showingNote }) {
            showingNote = notes.first?.slug
        }
        // Only when the recording changed. The mode survives a selection, so a
        // recording with no notes arriving under somebody reading notes has to
        // put them back on the transcript rather than on an empty pane.
        //
        // It must not fire on the other calls. Doing that made the Notes
        // segment unpressable on any recording with no notes: the click set the
        // mode, this line put it straight back, and the control snapped to
        // Transcript with nothing said. Asking for an empty pane on purpose is
        // allowed, and the empty pane is where it says what notes are.
        if reset, showing == .notes, notes.isEmpty { showing = .transcript }

        let now = signature()
        guard now != notesSignature else { return }
        notesSignature = now
        rebuildNotePicker()
        renderNote()
        if !reset { applyShowing() }
    }

    private func signature() -> String {
        notes.map { "\($0.slug)|\($0.updated)" }.joined(separator: ",")
            + "#" + (showingNote ?? "")
    }

    private func rebuildNotePicker() {
        notePicker.removeAllItems()
        for note in notes {
            // A note about four meetings is listed under all four, so under any
            // one of them its title alone reads as a note that has wandered off
            // the subject. The count is what says it belongs here as well as
            // elsewhere.
            notePicker.addItem(withTitle: note.recordings.count > 1
                ? "\(note.title)  ·  \(note.recordings.count) meetings"
                : note.title)
            // The slug on the item, because two notes may legitimately share a
            // title and the title is not the identity. Same reason the CLI
            // prints the slug rather than the name it was asked for.
            notePicker.lastItem?.representedObject = note.slug
            if note.slug == showingNote {
                notePicker.select(notePicker.lastItem)
            }
        }
    }

    /// Put a note on screen: theirs to type in, anything else to read.
    ///
    /// The two are drawn differently on purpose. An agent's note is rendered
    /// markdown, because it is finished writing somebody else did. The user's
    /// own note is the plain source in a plain text view, because it is being
    /// written, and rendering text under a caret is a text editor, which this
    /// deliberately is not: anybody who wants a document already has a notes
    /// app and will use it. What earns its place here is that this file is
    /// attached to the recording and readable by an agent.
    private func renderNote() {
        guard let note = notes.first(where: { $0.slug == showingNote }) else {
            notesText.isEditable = false
            notesText.textStorage?.setAttributedString(NSAttributedString())
            noteInfo.textStorage?.setAttributedString(NSAttributedString())
            updatePlaceholder()
            return
        }
        setProvenance(of: note)

        if Notes.isYours(note) {
            notesText.isEditable = true
            notesText.font = .systemFont(ofSize: 13)
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            // Set on the view as well as on the string, or the first character
            // typed into an empty note arrives in whatever AppKit last used.
            notesText.typingAttributes = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
            notesText.textStorage?.setAttributedString(
                NSAttributedString(string: note.body, attributes: notesText.typingAttributes))
        } else {
            notesText.isEditable = false
            // Without the heading the switcher above already shows. See
            // `MarkdownText.attributed(_:without:)`.
            notesText.textStorage?.setAttributedString(
                MarkdownText.attributed(note.body, without: note.title))
        }
        updatePlaceholder()
        // Here as well as in `applyShowing`, because the text and the mode do
        // not change together. `applyShowing` decides whether this line is
        // drawn from whether it has anything to say, and `renderNote` is what
        // gives it something to say: without this, a line rendered while the
        // pane was on the transcript stayed hidden after switching to Notes,
        // laid out at its full height and drawing nothing. A blank band where
        // the provenance goes reads as a note that has lost its own history.
        showProvenance()
        notesText.scroll(NSPoint(x: 0, y: 0))
    }

    private func showProvenance() {
        noteInfo.isHidden = showing != .notes || noteInfo.string.isEmpty
        // Collapsed as well as hidden: a hidden view keeps its frame, which is
        // the trap the chips row and the player already record.
        noteInfoHeight.isActive = noteInfo.isHidden
        noteInfoTop.constant = noteInfo.isHidden ? -6 : 0
    }

    /// An `NSTextView` has no placeholder, so this is a label behind one.
    ///
    /// Computed from the state rather than set where the text is, because the
    /// two do not change together: switching to the Notes tab does not
    /// re-render a note whose text has not changed, and the first version hid
    /// the prompt on the way past and never put it back.
    private func updatePlaceholder() {
        notesPlaceholder.stringValue =
            "What you are thinking. Only you write this, and an agent can read it."
        notesPlaceholder.isHidden = showing != .notes
            || !showingYours
            || !notesText.string.isEmpty
    }

    /// Who wrote this note and what they were asked for, above it.
    ///
    /// Above rather than inside, because the user's note is editable and
    /// provenance somebody can put a caret in and delete is not provenance. It
    /// is on screen at all because a note is derived and a transcript is
    /// evidence: somebody reading a meeting's summary in a month needs to know
    /// whether a person or a model wrote it before acting on it, and the
    /// frontmatter that says so is not rendered.
    private func setProvenance(of note: Note) {
        let when = Timestamps.parse(note.updated).map { date -> String in
            let f = DateFormatter()
            f.doesRelativeDateFormatting = true
            f.dateStyle = .medium
            f.timeStyle = .short
            return f.string(from: date)
        }
        var parts: [String] = []
        // Nothing that repeats the switcher directly above it. That control
        // already says "Your notes", so a line under it reading "Yours" is a
        // word spent saying nothing: what is worth knowing about your own note
        // is when you last touched it, and about anything else is who wrote it.
        if Notes.isYours(note) {
            if let when { parts.append("Edited \(when)") }
        } else {
            parts.append(note.source == Notes.Source.cli.rawValue
                ? "Written from the command line" : "Written by an agent")
            if let when { parts.append(when) }
            if !note.updated.isEmpty, note.updated != note.created {
                parts.append("edited since")
            }
        }
        var text = parts.joined(separator: " · ")
        if let prompt = note.prompt, !prompt.isEmpty { text += "\nAsked for: \(prompt)" }

        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let line = NSMutableAttributedString(string: text, attributes: plain)

        // The other meetings a note draws on, named and reachable. A synthesis
        // of four catch-ups appears under all four, and reading it from one of
        // them without being told about the other three makes it look like a
        // note about this meeting that has wandered off the subject. They are
        // links for the same reason they are in the note pane: naming a place
        // with no way to get to it is worse than not naming it.
        let others = Notes.sources(of: note).filter { $0.id != recording?.id }
        if !others.isEmpty {
            if line.length > 0 { line.append(NSAttributedString(string: "\n", attributes: plain)) }
            line.append(NSAttributedString(string: "Also about: ", attributes: plain))
            for (index, source) in others.enumerated() {
                if index > 0 {
                    line.append(NSAttributedString(string: ", ", attributes: plain))
                }
                var attributes = plain
                if let title = source.title {
                    attributes[.link] = RecordingLink.scheme + source.id
                    attributes[.foregroundColor] = Brand.accent
                    line.append(NSAttributedString(string: title, attributes: attributes))
                } else {
                    attributes[.foregroundColor] = NSColor.tertiaryLabelColor
                    line.append(NSAttributedString(
                        string: source.id + " (no longer in the library)",
                        attributes: attributes))
                }
            }
        }
        noteInfo.textStorage?.setAttributedString(line)
        noteInfo.invalidateIntrinsicContentSize()
    }

    /// Put the chosen document on screen. The only place either pane is hidden.
    private func applyShowing() {
        modePicker.selectedSegment = showing == .transcript ? 0 : 1
        // Collapsed for a note, and for a recording that is still running: that
        // one already says so in the transcript area, and it would be wrong
        // besides, since its audio is on *this* Mac and simply is not finished.
        // Everything else keeps the card, with or without a transport in it.
        setPlayer(hasAudio: hasAudio,
                  hidden: showing == .notes || recording?.isLive == true)
        scroll.isHidden = showing != .transcript
        notesScroll.isHidden = showing != .notes
        // A solo is a lens on the transcript, so it goes with the transcript.
        // Leaving the bar up over a note would be a sentence about paragraphs
        // that are not on screen, and the player it narrows is collapsed here
        // anyway: switching to Notes already stops playback.
        if showing != .transcript { setSolo(nil) }
        showProvenance()
        updatePlaceholder()
        // One note is still worth a switcher: it is also where the note's title
        // is written, and the pane would otherwise show a document with no name
        // on it.
        notePicker.isHidden = showing != .notes || notes.isEmpty
        updateEmpty()
    }

    /// Show the meeting being read, or put the picture away.
    ///
    /// Called on every piece, which is thirty times a track, so it does as
    /// little as possible: it sets two numbers on a view that is already on
    /// screen. The full `reload` path is what a job *starting or finishing*
    /// takes, and it must not be what a job *advancing* takes, because that one
    /// re-shows the recording, which stops playback and puts the playhead back
    /// to the beginning. Somebody listening to yesterday's meeting while today's
    /// transcribes would have had it stopped from under them thirty times.
    func showProgress() {
        guard let recording, Queue.shared.running == recording.id else {
            transcribing.progress = nil
            return
        }
        transcribing.progress = Queue.shared.progress
        // The sentence changes with the stage, so the label under the picture
        // has to be refreshed as well as the picture. Cheap: one string compare
        // per piece, against a pane that is already laid out.
        updateEmpty()
    }

    /// Put the transcription picture up with a made-up position.
    ///
    /// `LISTEN_PANEL=transcribing:0.6`, and the same argument as the recording
    /// panel's preview clock next door. This state lasts under thirty seconds a
    /// track on a fast Mac and needs a meeting to reach at all, so without this
    /// the only way to look at the drawing is to catch it, and a picture nobody
    /// can put on screen on demand is a picture nobody checks. It is also the
    /// only way to see the two lanes at different fills, which is the frame most
    /// likely to be laid out wrongly.
    func previewTranscribing(_ fraction: Double) {
        showing = .transcript
        applyShowing()
        transcribing.progress = TranscriptionProgress(
            message: fraction < 0.5 ? "transcribing the other participants"
                                    : "transcribing you",
            everyone: min(1, fraction * 2),
            you: max(0, fraction * 2 - 1))
        transcribing.isHidden = false
        empty.isHidden = true
        emptyIcon.isHidden = true
        // As `updateEmpty` does. Without it the preview draws over whatever
        // transcript the chosen recording already has, which is not a state the
        // app can be in and would have somebody chasing a bug that is only in
        // the preview.
        scroll.isHidden = true
    }

    /// What this pane says when it has nothing to show, per mode.
    ///
    /// One owner for the whole empty area, which is why the picture is chosen
    /// here rather than by whoever happens to be updating it. It is the same
    /// state as "Transcribing. This stays here if you quit." was, drawn instead
    /// of said, so it belongs in the same switch and cannot end up on screen at
    /// the same time as the sentence it replaces.
    private func updateEmpty() {
        guard let recording else { return }
        var message: String
        var showPicture = false
        switch showing {
        case .transcript:
            message = turns.isEmpty ? Self.emptyTranscriptMessage(recording) : ""
            // Whenever this recording is the running job, and deliberately not
            // only when there is no transcript yet.
            //
            // Transcribe Again is the case that settles it. It overwrites a
            // transcript that is already on screen, so gated on `turns.isEmpty`
            // the pane went on showing the old transcript for the whole re-run
            // and the only sign anything had happened was a word in the sidebar
            // row. Reported as "I pressed it and it didn't really do anything",
            // which is exactly right: a job that takes under a minute and shows
            // nothing is indistinguishable from a menu item that does nothing.
            //
            // The transcript underneath is about to be replaced, so covering it
            // costs a reader nothing and is the only acknowledgement the click
            // gets.
            showPicture = Queue.shared.running == recording.id
        case .notes:
            // Never empty any more: the user's own note is always offered, and
            // an empty one is a cursor rather than a message. The placeholder
            // inside the text view is what says what this is for.
            message = ""
        }
        // The sentence and the picture are both centred in the pane, so they
        // cannot both be up. "This stays here if you quit" moves *into* the
        // picture rather than being dropped: it is the reason the window can be
        // closed on an hour-long job, and a picture of work in progress is
        // exactly what makes somebody wonder whether they have to sit and watch
        // it finish.
        if showPicture { message = "" }

        empty.stringValue = message
        empty.isHidden = message.isEmpty
        transcribing.isHidden = !showPicture
        // The transcript goes away while the picture is up, or a re-run draws
        // the picture on top of the paragraphs it is in the middle of replacing.
        scroll.isHidden = showing != .transcript || showPicture
        // Not just hidden: clearing the progress is what stops the thirty a
        // second timer inside it. Clicking from a transcribing recording to any
        // other one would otherwise leave it running against a view nobody can
        // see, for as long as the window is open.
        if !showPicture { transcribing.progress = nil }
        if showPicture { emptyIcon.isHidden = true }
    }

    /// Why there is no transcript on screen, in the order the reasons rule each
    /// other out.
    ///
    /// Pulled out of `updateEmpty` when the fifth reason arrived: five nested
    /// ternaries is a sentence nobody can check, and the order between them is
    /// the whole correctness of it.
    private static func emptyTranscriptMessage(_ recording: Recording) -> String {
        if recording.isLive { return "Recording. The transcript appears when you stop." }
        // A transcript that exists and yields no turns is a recording with no
        // speech in it, whether or not the audio is on this Mac.
        if recording.hasTranscript { return "This recording has no speech in it." }
        if Queue.shared.isQueued(recording.id) {
            // Named, because the model is the thing somebody just chose and the
            // run is the hour they have to wait to find out whether it was the
            // right choice. It is also the only place the model appears until
            // there is a transcript to carry it.
            return "Transcribing with \(recording.asrModel.title)."
                + " This stays here if you quit."
        }
        // Before "Not transcribed yet", which would be a promise this Mac cannot
        // keep. On a Mac sharing a library with the machine that recorded the
        // meeting, the transcript arrives when that machine has made it, and
        // nothing here is waiting to run. See `Recording.hasAudio`.
        if !recording.hasAudio {
            return "The audio is on the Mac that recorded this."
                + " The transcript appears here when that Mac has made it."
        }
        return "Not transcribed yet."
    }

    /// Layer colours do not follow the appearance on their own, so the card is
    /// restyled when it changes. Without this a window opened in light mode
    /// keeps a light border after the Mac switches to dark at sunset.
    private func styleCard() {
        playerCard.layer?.borderColor = NSColor.separatorColor.cgColor
        playerCard.layer?.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.55).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { [self] in styleCard() }
    }

    // MARK: - Showing

    func show(_ recording: Recording?) {
        // Stop the player when the selection changes. Leaving one meeting
        // playing while reading another is never what anyone meant.
        stopPlayback()
        // Before `self.recording` moves, or a half-typed note is written to the
        // recording that arrives next.
        saveYours()
        // A lens on one transcript, so it does not travel to the next one. The
        // sidebar's lenses are the opposite and deliberately survive a selection
        // change: those narrow the library, and this narrows one meeting.
        soloed = nil
        waveform.soloed = nil
        self.recording = recording

        guard let recording else {
            setChromeHidden(true)
            empty.isHidden = false
            let libraryIsEmpty = Recording.all().isEmpty && Capture.shared.current == nil
            // The character welcomes a new library. In a library that already
            // has recordings, it would only turn a simple selection prompt into
            // decoration and make the detail pane feel less calm.
            emptyIcon.isHidden = !libraryIsEmpty
            empty.stringValue = libraryIsEmpty
                ? "No recordings yet. Start a new recording from the sidebar."
                : "Select a recording."
            return
        }

        emptyIcon.isHidden = true

        // An unnamed recording shows the placeholder as a placeholder rather
        // than as its name, so clicking the title gives an empty field to type
        // into instead of a word to delete first.
        titleLabel.stringValue = recording.isUntitled ? "" : recording.metadata.title
        titleLabel.placeholderString = Metadata.untitled

        // Read once. `storedTranscript` decodes the whole file, which on an hour
        // of meeting is several hundred segments, and the subtitle and the
        // sentence spans below both want it.
        let stored = recording.storedTranscript

        // The app goes here rather than in the title. Blackbox names a
        // recording after the app it was in, which is where the imported
        // library's "2607-17-Google Chrome" comes from; doing that in Listen
        // would break calendar naming outright, because `isUntitled` is the
        // literal placeholder and a recording called "Google Chrome" is one
        // the calendar will never name.
        //
        // The model is the fourth fact, and it is here unconditionally rather
        // than only when it differs from the default. Nothing anywhere used to
        // say what produced a transcript, so a meeting held in Dutch and decoded
        // by the English-only model read as fluent nonsense with no fact on
        // screen to explain it, and the model that did it was the default. A
        // fact that only appears sometimes is one nobody learns to read.
        subtitleLabel.stringValue = [recording.when, recording.lengthText,
                                     recording.appLabel ?? "",
                                     stored.map { Recording.modelName($0.model) } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")

        // Who is in this recording and what it is about, on one line above the
        // player. Collapsed to nothing when there is neither, so a live or
        // untranscribed recording keeps the layout it had before this row
        // existed.
        chips.configure(recording)
        tagChips.configure(recording)
        setChipsCollapsed(chips.isEmpty && tagChips.isEmpty)

        turns = recording.storedTurns
        // The sentence spans come from `transcript.json`, which keeps one row
        // per ASR sentence, while the paragraphs come from `turns.json`. Both
        // files are written together and neither is derived here, so the
        // transcript on screen is still exactly the one the CLI and the MCP
        // server serve.
        sentences = Merge.sentences(in: turns, from: stored?.segments ?? [])
        renderTurns()

        // No player while it is being recorded. The tracks exist and are
        // growing, so a mixdown made now would be of half a meeting and the
        // waveform cache would keep that half for ever: the cache is keyed on
        // its format version, not on how long the audio was when it was drawn.
        // `Recording.hasAudio` rather than a second reading of the same folder,
        // so this pane, the queue and the Transcribe Again item cannot disagree
        // about whether there is anything here to play.
        hasAudio = !recording.isLive && recording.hasAudio
        setChromeHidden(false)
        length = recording.metadata.duration
        position = 0
        currentTurn = nil
        follows = true
        refresh()
        if hasAudio { loadWaveform(recording) }

        // After `setChromeHidden(false)`, which unhides both panes, because
        // `applyShowing` is the only thing that decides which of the two is up.
        //
        // The mode survives the selection change, the way the Dictionary pane's
        // does: somebody reading notes down a list of meetings is in a mode, not
        // repeating a choice. `reloadNotes` puts it back to the transcript when
        // the recording that arrives has no notes, so the mode never leaves
        // anybody on an empty pane.
        notesSignature = ""
        // Notes first, so the default for a recording with nothing else to show
        // is decided against a list that exists.
        //
        // A recording being made now has no transcript and cannot have one for
        // an hour, so Transcript is an empty pane and Notes is the only thing
        // on this screen anybody can use. It is also the moment the note is
        // worth the most: what somebody types during a call is exactly what no
        // transcript will ever contain.
        if recording.isLive { showing = .notes }
        reloadNotes(reset: true)
        // Always, now that every recording has a note to type into. It used to
        // collapse when there was nothing to switch between, and there always
        // is.
        setModeBarCollapsed(false)
        applyShowing()
    }

    private func setChromeHidden(_ hidden: Bool) {
        titleLabel.isHidden = hidden
        subtitleLabel.isHidden = hidden
        playerCard.isHidden = hidden
        scroll.isHidden = hidden
        notesScroll.isHidden = hidden
        if hidden {
            // `clear` and not just the collapse: the strip would otherwise keep
            // the last recording's tags and its `＋` would offer to tag a
            // recording that is no longer selected.
            tagChips.clear()
            setChipsCollapsed(true)
            setModeBarCollapsed(true)
            // `show` clears `soloed` before it gets here, so this closes the bar
            // rather than leaving the last recording's solo announced over an
            // empty pane.
            applySolo()
        }
    }

    /// A hidden view still occupies its frame, so the row's height and the
    /// space above it both have to go: leaving them would open a 34 point gap
    /// under the date of every recording that has no speakers yet.
    ///
    /// Both halves of the band at once, because they are one band: see
    /// `TagChips` for why the tags share the speakers' row.
    private func setChipsCollapsed(_ collapsed: Bool) {
        chips.isHidden = collapsed
        // Not `|| tagChips.isEmpty`: when the band is open for the speakers, an
        // untagged recording still needs its `＋` on screen, which is how a
        // first tag is put on one without going to a menu.
        tagChips.isHidden = collapsed
        chipsTop.constant = collapsed ? 0 : 10
        chipsHeight.constant = collapsed ? 0 : 24
    }

    // MARK: - Tags

    /// Opening the tag popover, with the same three steps `editSpeaker` takes.
    ///
    /// The rect is taken while the pill is still in the window, then the title
    /// edit is committed, then the popover is pointed at **the pane**. A
    /// committed title reloads, a reload rebuilds the strip, and one line after
    /// `endEditing` the button that was clicked is out of the hierarchy: a view
    /// with no window cannot be converted from, which silently yields a nonsense
    /// rect, and cannot position a popover, which aborts the app rather than
    /// failing quietly. That sequence shipped once already; see `editSpeaker`.
    private func editTags(from view: NSView, rect: NSRect) {
        guard let recording else { return }
        let anchor = convert(rect, from: view)
        endEditing()
        TagPopover.show(for: recording, from: self, rect: anchor) { [weak self] in
            self?.refreshTags()
        }
    }

    /// Redraw the strip after a tag changed, and nothing else.
    ///
    /// Not `show(_:)`, which stops playback and puts the playhead back to zero.
    /// Filing a meeting is something people do while listening to it, which is
    /// the argument `applyEdit` already makes for reloading in place rather than
    /// re-showing. The sidebar is told because a tag can be the lens the list is
    /// currently under, so the row may belong somewhere else now.
    func refreshTags() {
        guard let recording, let updated = Recording.find(recording.id) else { return }
        self.recording = updated
        tagChips.configure(updated)
        setChipsCollapsed(chips.isEmpty && tagChips.isEmpty)
        LibraryWindow.shared.reload()
    }

    private func renderTurns(scrollToTop: Bool = true) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        turnViews = []
        editingTurn = nil
        for (index, turn) in turns.enumerated() {
            let view = TurnView(turn: turn,
                                sentences: index < sentences.count ? sentences[index] : [])
            view.onSeek = { [weak self] sentence in
                self?.endEditing()
                // The sentence that was clicked, falling back to the turn for a
                // click that landed between sentences or on an imported
                // transcript whose segments could not be located in their turn.
                self?.seek(to: sentence?.start ?? turn.start, playing: true)
            }
            view.onSpeaker = { [weak self] anchor, rect in
                self?.editSpeaker(turn.speaker, from: anchor, rect: rect)
            }
            view.onEdit = { [weak self] sentence, was, text in
                self?.applyEdit(sentence, was: was, to: text)
            }
            view.onEditingChanged = { [weak self] turn, editing in
                guard let self else { return }
                if editing {
                    // Only one at a time. Clicking another paragraph normally
                    // commits the first through the responder chain, but the
                    // menu can be opened without that ever happening.
                    if let open = editingTurn, open !== turn { open.commitEditing() }
                    editingTurn = turn
                    endEditingTitle()
                } else if editingTurn === turn {
                    editingTurn = nil
                }
            }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -20).isActive = true
            turnViews.append(view)
        }

        // Room at the end for the floating Record button, which is in the
        // window's content host and therefore over this. A spacer in the stack
        // and not `scroll.contentInsets`, which is what the note beside this
        // has to use: setting `contentInsets` turns
        // `automaticallyAdjustsContentInsets` off, taking the *top* inset with
        // it, and this scroll view's top is measured against nothing that would
        // report the change. A view at the end of the document moves only the
        // end of the document.
        let tail = NSView()
        tail.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(tail)
        NSLayoutConstraint.activate([
            tail.heightAnchor.constraint(equalToConstant: RecordButton.clearance),
            tail.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
        ])

        // Whoever was soloed stays soloed across a re-render, so correcting a
        // sentence while reading one person does not silently put everybody
        // else back on the page.
        applySolo()

        // Not after an edit. A reload that jumps to the top of an hour-long
        // meeting loses the reader's place every time they correct a word.
        guard scrollToTop else { return }
        scrollTranscriptToTop()
    }

    /// Open at the beginning.
    ///
    /// A freshly selected recording used to open somewhere near the end of the
    /// meeting with half a paragraph cut off above it, which reads as a
    /// rendering fault rather than as a scroll position.
    ///
    /// The top is `bounds.maxY`, not zero. `TopAlignedClipView` flips the *clip
    /// view*, which decides where a short transcript sits and which way the
    /// scrollers run, and changes nothing about the stack view's own
    /// coordinates: its arranged subviews are still laid out with the first turn
    /// at the highest y. Measured both ways round on an 80 minute recording,
    /// because the two flags read as if they should agree and do not: y = 0
    /// opens on the last turn, y = maxY - 1 on the first.
    ///
    /// Deferred, because soloing hides most of the arranged subviews and the
    /// stack has not shrunk to fit what is left until the next layout pass.
    private func scrollTranscriptToTop() {
        DispatchQueue.main.async { [self] in
            layoutSubtreeIfNeeded()
            scrollingProgrammatically = true
            stack.scrollToVisible(NSRect(x: 0, y: stack.bounds.maxY - 1,
                                         width: 1, height: 1))
            DispatchQueue.main.async { self.scrollingProgrammatically = false }
        }
    }

    // MARK: - Waveform

    private func loadWaveform(_ recording: Recording) {
        waveform.peaks = []
        transcribing.peaks = []
        // The same turns the transcript below is built from, so a coloured bar
        // and the paragraph it belongs to cannot name different people. Set
        // before the audio arrives: `spans` is read against `duration`, and both
        // are in place by the first draw that has bars to colour.
        waveform.spans = turns.map { ($0.start, $0.end, $0.speaker) }
        waveformToken += 1
        let token = waveformToken
        let target = recording
        Task.detached(priority: .userInitiated) {
            // Off the main thread on purpose: this reads every sample in the
            // recording, which for an hour-long meeting is tens of millions of
            // them. The pane draws without a waveform until it arrives.
            let wave = Waveform.load(for: target)
            await MainActor.run {
                guard self.waveformToken == token, let wave else { return }
                self.waveform.peaks = wave.peaks
                self.waveform.duration = wave.duration
                // The same envelope, so the picture of the work and the
                // scrubber under it are unmistakably the same recording.
                self.transcribing.peaks = wave.peaks
                // The audio is the authority on how long the recording is.
                // `metadata.duration` is what the recorder believed when it
                // stopped, and an imported recording's can be a rounded number.
                if self.player == nil, wave.duration > 0 {
                    self.length = wave.duration
                    self.refresh()
                }
            }
        }
    }

    // MARK: - Playback

    /// The track to play.
    ///
    /// Prefers the mixdown, generated on demand rather than at transcription
    /// time so a library of recordings nobody replays costs nothing. Falls back
    /// to the system track, which is the one with the other participants on it
    /// and therefore the one worth hearing if only one exists.
    /// Not main-actor isolated, because building the mixdown is exactly the
    /// work that must not happen on the main thread.
    nonisolated private static func playbackURL(_ recording: Recording) -> URL? {
        if FileManager.default.fileExists(atPath: recording.mixURL.path) {
            return recording.mixURL
        }
        if let mix = try? Mixdown.make(for: recording) { return mix }
        return recording.tracks.first
    }

    /// Run `body` with a player, building one first if this is the first press.
    ///
    /// Asynchronous because the first press may have to mix two hour-long
    /// tracks into `mix.m4a`, and doing that on the main thread froze the
    /// window for seconds with a pressed play button and no sound.
    private func withPlayer(_ body: @escaping (AVAudioPlayer) -> Void) {
        if let player { body(player); return }
        guard let recording, !preparing else { return }
        preparing = true
        playButton.isEnabled = false
        let target = recording
        Task.detached(priority: .userInitiated) {
            let url = Self.playbackURL(target)
            await MainActor.run {
                self.preparing = false
                self.playButton.isEnabled = true
                // The selection can change while a mixdown is being built.
                guard self.recording?.id == target.id else { return }
                guard let url, let player = try? AVAudioPlayer(contentsOf: url) else {
                    log("could not open audio for \(target.id)")
                    return
                }
                player.prepareToPlay()
                self.player = player
                self.length = player.duration
                self.waveform.duration = player.duration
                player.currentTime = min(self.position, max(0, player.duration - 0.05))
                body(player)
            }
        }
    }

    @objc private func togglePlay() {
        // A button click never reaches `mouseDown` below, so the controls that
        // do claim their click each have to let the fields go themselves.
        endEditing()
        if let player, player.isPlaying {
            pausePlayback()
            return
        }
        follows = true
        withPlayer { player in
            // Pressing play on a finished recording plays it, rather than
            // sitting silently at the end wondering what the button did.
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
            // While somebody is soloed, start inside one of their turns rather
            // than wherever the playhead was left. `updatePlayhead` would jump
            // there on its first tick anyway, and a press that plays a twentieth
            // of a second of the wrong person first is a press that sounds
            // broken.
            switch self.soloStep(at: player.currentTime) {
            case .carryOn:
                break
            case .jump(let time):
                player.currentTime = time
            case .finished:
                // Past their last turn, so start again at their first, which is
                // the soloed reading of the finished-recording rule above.
                if let first = self.soloTurns.first { player.currentTime = first.start }
            }
            self.position = player.currentTime
            player.play()
            self.setPlaying(true)
            self.tick?.invalidate()
            // Twenty times a second. The playhead is a line moving across a
            // waveform, and at the five-a-second the slider was happy with it
            // visibly steps.
            self.tick = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                Task { @MainActor in self.updatePlayhead() }
            }
        }
    }

    /// Stop where it is, keeping the playhead. Split out of `togglePlay` because
    /// the speaker picker's own control has to be able to stop a preview without
    /// starting one when it is already stopped.
    private func pausePlayback() {
        guard let player, player.isPlaying else { return }
        player.pause()
        setPlaying(false)
        tick?.invalidate()
    }

    private func setPlaying(_ playing: Bool) {
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? "Pause" : "Play")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        playButton.toolTip = playing ? "Pause" : "Play"
    }

    /// Move the playhead without starting playback.
    ///
    /// Dragging through a meeting to find a moment is a way of reading it, not
    /// of listening to it, so scrubbing a paused recording leaves it paused.
    private func scrub(to fraction: Double) {
        endEditing()
        guard length > 0 else { return }
        follows = true
        seek(to: fraction * length, playing: player?.isPlaying ?? false)
    }

    private func seek(to time: TimeInterval, playing: Bool) {
        position = max(0, time)
        refresh()
        guard playing else {
            // No player yet means nothing to tell: `withPlayer` starts whatever
            // it builds at `position`.
            player?.currentTime = position
            return
        }
        if let player {
            player.currentTime = min(position, max(0, player.duration - 0.05))
            if !player.isPlaying { togglePlay() }
        } else {
            togglePlay()
        }
    }

    private func updatePlayhead() {
        guard let player else { return }
        position = player.currentTime
        if player.duration > 0 { length = player.duration }

        // While somebody is soloed, playback runs through their turns and skips
        // what is between them. Announced on the bar above the transcript rather
        // than left to be discovered, because this is the only place in the app
        // where play does not play what comes next.
        if player.isPlaying {
            switch soloStep(at: position) {
            case .carryOn:
                break
            case .jump(let time):
                // `seek` refreshes on the way through, so there is nothing left
                // to do on this tick.
                seek(to: time, playing: true)
                return
            case .finished:
                // Stop at the end of the last thing they said rather than
                // playing the rest of the meeting behind a page that says it is
                // showing one person.
                pausePlayback()
            }
        }

        refresh()
        if !player.isPlaying {
            setPlaying(false)
            tick?.invalidate()
        }
    }

    /// Push the playhead into everything that shows it.
    private func refresh() {
        // One source of truth for the length, so the hover readout on the
        // waveform cannot be describing the recording before this one.
        waveform.duration = length
        waveform.progress = length > 0 ? position / length : 0
        timeLabel.stringValue = TranscriptFormat.stamp(position)
            + " / " + TranscriptFormat.stamp(length)

        // The turn being spoken, then the sentence inside it. Only the two
        // views whose state changed are touched, which is what keeps this cheap
        // enough to run twenty times a second on an hour-long transcript.
        let index = turns.firstIndex { position >= $0.start && position < $0.end }
        if index != currentTurn {
            if let old = currentTurn, old < turnViews.count {
                turnViews[old].isCurrent = false
                turnViews[old].highlight(nil)
            }
            currentTurn = index
            if let index, index < turnViews.count {
                turnViews[index].isCurrent = true
                reveal(index)
            }
        }
        if let currentTurn, currentTurn < turnViews.count {
            turnViews[currentTurn].highlight(position)
        }
    }

    /// Scroll the turn being spoken into view, if the reader has not gone
    /// somewhere else.
    private func reveal(_ index: Int) {
        guard follows, index < turnViews.count else { return }
        // A hidden turn has no frame worth scrolling to, and while somebody is
        // soloed most of them are hidden. Without this, the moment before a skip
        // scrolls the reader to a collapsed view somewhere else in the meeting.
        guard !turnViews[index].isHidden else { return }
        let frame = turnViews[index].frame
        guard !scroll.documentVisibleRect.contains(frame) else { return }
        scrollingProgrammatically = true
        stack.scrollToVisible(frame.insetBy(dx: 0, dy: -50))
        DispatchQueue.main.async { self.scrollingProgrammatically = false }
    }

    @objc private func userScrolled() {
        guard !scrollingProgrammatically else { return }
        follows = false
    }

    func stopPlayback() {
        tick?.invalidate()
        tick = nil
        player?.stop()
        player = nil
        position = 0
        currentTurn = nil
        waveform.progress = 0
        setPlaying(false)
    }

    // MARK: - Soloing one speaker

    /// This speaker's turns, in order.
    private var soloTurns: [Turn] {
        guard let soloed else { return [] }
        return turns.filter { $0.speaker == soloed }
    }

    /// Show one speaker's turns and nothing else, or everybody again.
    ///
    /// The argument is checked against the transcript rather than trusted: a
    /// stale menu or a picker left open across a rename can name somebody who is
    /// no longer in it, and soloing them would empty the pane with nothing on
    /// screen to explain it.
    func setSolo(_ label: String?) {
        let next = label.flatMap { wanted in
            turns.contains { $0.speaker == wanted } ? wanted : nil
        }
        guard next != soloed else { return }
        soloed = next
        waveform.soloed = next
        applySolo()
        // Their first turn, rather than wherever the reader happened to be.
        // Soloing changes the whole page, and a page that has changed without
        // appearing to is the failure "Also about" already has a rule for.
        if next != nil { scrollTranscriptToTop() }
    }

    /// Narrow the transcript to one speaker for as long as a popover is asking
    /// about them, and hand back the closure that puts it right.
    ///
    /// Both chip kinds go through here so there is one rule rather than two that
    /// agree today. See `soloToken` for why the undo is guarded.
    private func soloWhile(_ speaker: String) -> () -> Void {
        soloToken += 1
        let token = soloToken
        setSolo(speaker)
        return { [weak self] in
            guard let self, self.soloToken == token else { return }
            self.setSolo(nil)
        }
    }

    /// Hide the paragraphs that are not this speaker's, and say so above them.
    ///
    /// Hiding views rather than rebuilding the stack from a filtered list, which
    /// keeps `turns`, `sentences` and `turnViews` the same length and the same
    /// order. `refresh` indexes all three against each other twenty times a
    /// second; a filtered array would put the playing highlight on somebody
    /// else's paragraph, and the sentence editor would write to the wrong
    /// segment.
    private func applySolo() {
        for (index, view) in turnViews.enumerated() where index < turns.count {
            view.isHidden = soloed != nil && turns[index].speaker != soloed
        }

        let showing = soloed != nil
        soloBar.isHidden = !showing
        soloHeight.constant = showing ? 22 : 0
        soloTop.constant = showing ? 10 : 0

        guard let soloed else { return }
        let mine = soloTurns
        let spoken = Recording.length(mine.reduce(0) { $0 + max(0, $1.end - $1.start) })
        let counted = mine.count == 1 ? "1 turn" : "\(mine.count) turns"
        // What play does is stated rather than left in a tooltip. A player that
        // silently jumps is one you stop trusting, and this is the only place in
        // the app where pressing play does not play what comes next.
        soloLabel.stringValue = ["Showing only " + SpeakerName.display(soloed),
                                 counted, spoken]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            + ". Play runs through them in order."
    }

    /// What playback should do next while somebody is soloed.
    private enum SoloStep {
        /// Inside one of their turns, or nobody is soloed.
        case carryOn
        /// Between two of them: go here.
        case jump(TimeInterval)
        /// Past the last thing they said.
        case finished
    }

    private func soloStep(at time: TimeInterval) -> SoloStep {
        guard let soloed else { return .carryOn }
        if turns.contains(where: {
            $0.speaker == soloed && time >= $0.start && time < $0.end
        }) { return .carryOn }
        if let next = turns.first(where: { $0.speaker == soloed && $0.start > time }) {
            return .jump(next.start)
        }
        return .finished
    }

    /// Play everything the soloed speaker said, in order, one turn after the
    /// next.
    ///
    /// **From their first turn, not their longest.** Starting at the longest
    /// gives the best single voice sample soonest, which is what identifying
    /// somebody wants, and it was the first thing this did. It is still the
    /// wrong rule: `soloStep` only ever moves forward, so starting in the middle
    /// means the turns before it can never be reached and pressing play twice
    /// gives two different halves of the same person. One press plays all of
    /// them, from the beginning, which is the only behaviour that needs no
    /// explaining.
    ///
    /// No offset into the turn either, for the same reason: the jumps between
    /// turns land on `start`, so an offset here would make the first snippet the
    /// one clipped differently from the rest.
    func playSolo() {
        guard let first = soloTurns.first else { return }
        follows = true
        seek(to: first.start, playing: true)
    }

    /// Whether the pane is playing, or about to be once a mixdown has been
    /// built.
    ///
    /// The second half matters to a control drawing itself from this. The first
    /// press on an hour-long meeting spends seconds mixing two tracks before
    /// there is a player at all, and a button that stays on "Play" throughout
    /// reads as a press that did nothing.
    var isPlaying: Bool { (player?.isPlaying ?? false) || preparing }

    // MARK: - Labelling

    /// Clicking a speaker, wherever the click came from.
    ///
    /// One rule, so the pill in the transcript and the chip under the title are
    /// the same control in two places: a name opens their card, and an unnamed
    /// speaker opens the picker. Neither is a dialog. The alert this replaced
    /// asked "Who is Ryan?" with a text field even when the answer was a
    /// person the library had known for months.
    /// **The pane is the anchor, and the rect is converted before anything
    /// else runs.** Both halves of that were a crash.
    ///
    /// A turn's pill is inside the transcript stack, which `renderTurns`
    /// empties: `endEditing` commits a title, a committed title reloads, and a
    /// reload rebuilds every turn, so one line after it the view that was
    /// clicked is out of the hierarchy. A view with no window can neither be
    /// converted from, which silently yields a nonsense rect, nor position a
    /// popover, which raises rather than failing quietly. Measured: rename a
    /// recording, click a speaker in the transcript, and
    /// `showRelativeToRect:ofView:preferredEdge:` aborted the app from inside
    /// the deferred block that shows it.
    ///
    /// So the order is: take the rect while the view is still in the window,
    /// then end the edit, then point the popover at the pane, which is on
    /// screen for as long as the transcript is. `SpeakerChips` already hands
    /// out its row rather than a chip for the same reason; this makes the rule
    /// hold for every caller instead of each one remembering it.
    private func editSpeaker(_ speaker: String, from view: NSView, rect: NSRect) {
        guard let recording else { return }
        let anchor = convert(rect, from: view)
        endEditing()
        let refresh = { [weak self] in
            guard let self, let updated = Recording.find(recording.id) else { return }
            self.show(updated)
            LibraryWindow.shared.reload()
        }
        // **Asking about somebody narrows the page to them, for as long as the
        // asking lasts.** Opening the popover shows only what that speaker said
        // and makes play run through their turns in order; closing it, by
        // dismissing or by applying a name, puts the whole meeting back. So the
        // filter has exactly one lifetime and it is one the user is already
        // holding in their hand, which is why there is no control anywhere for
        // turning it off: the popover in front of them is the off switch.
        //
        // Both kinds of chip, because "click a speaker to read only them" is one
        // rule and two implementations of it would be two rules by the next
        // change. The named side gets no play button of its own: the pane's own
        // play already runs through their turns while they are soloed.
        let restore = soloWhile(speaker)
        if VoiceBank.isPlaceholder(speaker) {
            SpeakerPicker.show(
                for: recording, speaker: speaker, from: self, rect: anchor,
                preview: SpeakerPreview(
                    play: { [weak self] in self?.playSolo() },
                    pause: { [weak self] in self?.pausePlayback() },
                    isPlaying: { [weak self] in self?.isPlaying ?? false },
                    end: restore),
                done: refresh)
        } else {
            PersonPopover.show(speaker, from: self, rect: anchor,
                               closed: restore, done: refresh)
        }
    }

    // MARK: - Correcting the transcript

    /// Write one edited sentence back to the segment it came from.
    ///
    /// To the *segment*, not to the turn. A turn is a fold over segments and
    /// `TranscriptEditor` rebuilds `turns.json` from them on every speaker
    /// change, so a correction written to the paragraph would survive until the
    /// next rename and then vanish with nothing to explain it.
    private func applyEdit(_ sentence: Merge.Sentence, was: String, to text: String) {
        guard let recording else { return }
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let before = was.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != before else { return }

        guard TranscriptEditor.apply(
            .retext(segment: sentence.index, was: before, to: typed), to: recording) else {
            // Refused: either the field was cleared, or the transcript changed
            // underneath and the index no longer names the sentence that was on
            // screen. Say so rather than dropping the typing silently.
            NSSound.beep()
            log(typed.isEmpty
                ? "a sentence cannot be emptied. Delete the speaker instead, or type over it."
                : "that sentence has changed since the pane was drawn; nothing was written.")
            return
        }

        // A targeted reload, not `show`. `show` stops playback and puts the
        // playhead back to zero, and correcting a word is something people do
        // while listening to it.
        guard let updated = Recording.find(recording.id) else { return }
        self.recording = updated
        turns = updated.storedTurns
        sentences = Merge.sentences(in: turns,
                                    from: updated.storedTranscript?.segments ?? [])
        currentTurn = nil
        renderTurns(scrollToTop: false)
        refresh()
        onChanged?()
    }
}

/// The paragraph of one turn.
///
/// A subclass so a right-click can be answered with the sentence it landed on.
/// The answering is done by `TranscriptFieldEditor` rather than here: a
/// right-click on a selectable text field installs the field editor *before*
/// the menu is built, and hit testing then lands on that text view rather than
/// on this field, so an override here would never run. Measured, because the
/// opposite is the natural assumption and it is wrong.
@MainActor
final class TranscriptBody: NSTextField {
    /// Where each sentence sits in this text, and which segment it is.
    var sentences: [Merge.Sentence] = []
    /// Chosen "Edit Sentence" on one of them.
    var onEdit: ((Merge.Sentence) -> Void)?
    /// Clicked, on the sentence under the pointer, or nil if it landed on none.
    var onClick: ((Merge.Sentence?) -> Void)?

    func sentence(at index: Int) -> Merge.Sentence? {
        if let hit = sentences.first(where: { NSLocationInRange(index, $0.range) }) {
            return hit
        }
        // An insertion point at the very end of the paragraph is one past every
        // range. Refusing there would make the end of a turn, which is where a
        // trailing mistranscription usually is, the one place you cannot edit.
        return sentences.last.flatMap { index == NSMaxRange($0.range) ? $0 : nil }
    }

    /// The click this paragraph last reported, so it is reported once.
    ///
    /// The first click on a paragraph runs **both** `mouseDown` overrides: this
    /// field's, and the field editor's from inside the tracking loop `super`
    /// starts. Every click after that runs only the editor's, because the editor
    /// is installed by then and hit testing lands on it. Measured:
    ///
    ///     click 1  hitTest -> Editor   ran -> Body.mouseDown + Editor.mouseDown
    ///     click 2  hitTest -> Editor   ran -> Editor.mouseDown
    ///
    /// Both paths therefore call `report`, and the timestamp keeps the first
    /// click from seeking twice. Handling it in this class alone was the bug:
    /// the first click on a paragraph played from the right sentence and every
    /// later one in the same paragraph did nothing at all.
    private var reported: TimeInterval = -1

    /// Play from the sentence that was clicked, not from the top of the turn.
    ///
    /// A turn can run for minutes, so "clicking a turn plays from there" was
    /// only true of its first word: clicking the third sentence of a paragraph
    /// started the recording several minutes before the words under the pointer.
    ///
    /// The editor is what is asked, because it is the only accurate answer: a
    /// layout manager rebuilt here to work out the same thing agreed with AppKit
    /// on 341 of 1026 sampled points, off by as much as 65 characters, because
    /// it cannot see the cell's own insets. Measured rather than assumed, since
    /// the reconstruction looks exact when you write it.
    ///
    /// A drag that selected something is not a click. Copying a quote out of a
    /// transcript should not move the playhead.
    func report(_ event: NSEvent, from editor: NSTextView) {
        guard event.timestamp != reported else { return }
        reported = event.timestamp
        guard editor.selectedRange().length == 0 else { return }
        let point = editor.convert(event.locationInWindow, from: nil)
        onClick?(sentence(at: editor.characterIndexForInsertion(at: point)))
    }

    /// After `super`: the tracking loop inside it installs the field editor and
    /// returns on mouse up, so by this line there is one to ask.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let editor = currentEditor() as? NSTextView else { return }
        report(event, from: editor)
    }

    /// An arrow, not an I-beam.
    ///
    /// The field is selectable, so AppKit offers the text cursor, and that reads
    /// as an invitation to type in something that is not editable. The primary
    /// gesture here is a click that plays from a word, which is an arrow's job.
    /// Both hooks, because a text view answers the cursor with tracking areas
    /// and a plain view answers it with cursor rects, and this is both at once.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

/// AppKit sets a field editor's delegate to the field it is editing, so this
/// conformance states a fact rather than an intention. No methods: it exists so
/// `delegate as? TranscriptBody` inside `TranscriptFieldEditor` is a cast
/// between related types.
///
/// Without it the compiler warns that the cast "always fails", and both things
/// that depend on it, the Edit Sentence menu and clicking a sentence to play it,
/// were working only because the optimiser had not yet taken the invitation to
/// fold them to nil.
extension TranscriptBody: NSTextViewDelegate {}

/// The field editor for a transcript paragraph, which exists to put "Edit
/// Sentence" at the top of the menu the user already gets.
///
/// It asks AppKit which character is under the pointer rather than rebuilding a
/// layout manager to work it out. The field editor is AppKit's own layout of
/// this exact string at this exact width, so its answer cannot disagree with
/// what is on screen; a second layout manager here would differ from it by the
/// cell's insets, which stays invisible until a click near a sentence boundary
/// quietly picks the neighbour.
///
/// Installed by `LibraryWindow.windowWillReturnFieldEditor(_:to:)`, and only for
/// `TranscriptBody`. Everything else in the window keeps the standard one.
@MainActor
final class TranscriptFieldEditor: NSTextView {
    /// The sentence the open menu refers to. One menu is open at a time, so one
    /// slot is enough, and it is cleared as soon as it is used.
    private var pending: (TranscriptBody, Merge.Sentence)?

    /// A field editor has to say it is one. Made here rather than by an `init`
    /// override so the class inherits `NSTextView`'s initialisers untouched.
    ///
    /// **`init(frame:)`, never `init(frame:textContainer: nil)`.** The second is
    /// the designated initialiser and passing nil means "I will build the text
    /// system myself": the view comes back with no text container, no layout
    /// manager and no storage, and it fails silently rather than complaining.
    /// Measured on the two side by side, with `string` set on each:
    ///
    ///     init(frame:textContainer: nil)   container nil, storage nil, string EMPTY
    ///     init(frame:)                     container yes, storage yes, 40 chars
    ///
    /// Shipping the first one blanked the transcript. A right-click installs the
    /// field editor over the paragraph, so an editor that can hold no text drew
    /// no text, and `NSTextFieldCell` then wrote that emptiness back into the
    /// label: the words did not reappear when the menu closed, which reads as
    /// the transcript having been destroyed rather than as a view that cannot
    /// draw. Nothing reached disk, because only `TranscriptEditor` writes one.
    static func make() -> TranscriptFieldEditor {
        let editor = TranscriptFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        return editor
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Built on top of the standard menu rather than replacing it. Look Up,
        // Copy and the rest are why anyone right-clicks a transcript today, and
        // taking them away to add one item would be a poor trade.
        let standard = super.menu(for: event)
        guard let body = delegate as? TranscriptBody,
              let sentence = body.sentence(
                at: characterIndexForInsertion(at: convert(event.locationInWindow,
                                                           from: nil)))
        else { return standard }

        let menu = standard ?? NSMenu()
        let item = NSMenuItem(title: "Edit Sentence",
                              action: #selector(editSentence), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        pending = (body, sentence)
        return menu
    }

    @objc private func editSentence() {
        guard let (body, sentence) = pending else { return }
        pending = nil
        body.onEdit?(sentence)
    }

    /// Every click after the first one on a paragraph arrives here rather than
    /// at the field, because the editor is installed by then and hit testing
    /// lands on it. Without this, only the first click in a paragraph played
    /// from the sentence under the pointer. `report` is idempotent per event, so
    /// the first click, which runs both overrides, still seeks once.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let body = delegate as? TranscriptBody else { return }
        body.report(event, from: self)
    }

    /// The editor covers the paragraph once it is installed, so it has to answer
    /// the cursor the same way the paragraph does. See `TranscriptBody`.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

/// One speaker turn in the transcript.
@MainActor
final class TurnView: NSView {
    private let speakerButton = SpeakerPill(style: .name)
    private let timeLabel = NSTextField(labelWithString: "")
    private let bodyLabel = TranscriptBody(wrappingLabelWithString: "")

    /// The body region: the paragraph, or the three pieces it becomes while one
    /// sentence inside it is being edited.
    ///
    /// A stack rather than an overlay on the sentence itself. A sentence in a
    /// wrapped paragraph is not a rectangle: it starts mid-line and ends
    /// mid-line, so a field placed over it is either the wrong shape or covers
    /// its neighbours. Splitting the paragraph into what comes before, the
    /// sentence, and what comes after keeps every word on screen and leaves no
    /// doubt about which part is being edited.
    private let body = NSStackView()
    private var editField: NSTextField?
    private var editing: Merge.Sentence?

    /// Clicked, carrying the sentence under the pointer when there was one.
    var onSeek: ((Merge.Sentence?) -> Void)?
    /// The pill was clicked, with itself and its frame to point at.
    var onSpeaker: ((NSView, NSRect) -> Void)?
    /// A sentence was committed: which one, what it used to say, what it says
    /// now. The old text travels with it so the write can refuse if the
    /// transcript moved underneath.
    var onEdit: ((Merge.Sentence, String, String) -> Void)?
    /// Editing started or stopped, so the pane can end it from elsewhere.
    var onEditingChanged: ((TurnView, Bool) -> Void)?

    /// True while a sentence in this turn is being edited.
    var isEditing: Bool { editing != nil }

    /// Where each sentence sits in the body text, for the playhead.
    private let sentences: [Merge.Sentence]
    /// The body with everything but the highlight already applied, so following
    /// the playhead is one attribute change rather than a restyle.
    private let base: NSMutableAttributedString
    private var highlighted: Int?

    /// A turn can run for minutes, so its tint is deliberately fainter than the
    /// sentence highlight inside it. This one answers "who is talking"; the
    /// sentence answers "where are we".
    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            layer?.backgroundColor = isCurrent
                ? Brand.accent.withAlphaComponent(0.07).cgColor
                : NSColor.clear.cgColor
        }
    }

    /// Highlight the sentence containing `time`, or none.
    ///
    /// Called twenty times a second while playing, so it does nothing at all
    /// unless the sentence changed, and nothing at all while a sentence here is
    /// being edited: the paragraph is not on screen then, and restyling it
    /// would only be work nobody can see.
    func highlight(_ time: TimeInterval?) {
        guard editing == nil else { return }
        let index = time.flatMap { now in
            sentences.firstIndex { now >= $0.start && now < $0.end }
        }
        guard index != highlighted else { return }
        highlighted = index

        let text = NSMutableAttributedString(attributedString: base)
        if let index {
            text.addAttribute(.backgroundColor,
                              value: Brand.accent.withAlphaComponent(0.30),
                              range: sentences[index].range)
        }
        bodyLabel.attributedStringValue = text
    }

    init(turn: Turn, sentences: [Merge.Sentence]) {
        self.sentences = sentences
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // The line height is what makes a wall of transcript readable, and it
        // has to be set here because an attributed string replaces the label's
        // own layout rather than adding to it.
        paragraph.lineSpacing = 2
        self.base = NSMutableAttributedString(
            string: turn.text,
            attributes: [.font: NSFont.systemFont(ofSize: 13),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph])
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        // "Speaker A" rather than a bare "A". A letter on its own reads as a
        // code the reader is meant to decode. `show` also puts the person's own
        // colour on the pill, which is what makes a page of transcript legible
        // as a conversation before a word of it is read.
        speakerButton.show(turn.speaker)
        speakerButton.target = self
        speakerButton.action = #selector(speakerTapped)
        speakerButton.toolTip = "Name this speaker"

        timeLabel.stringValue = TranscriptFormat.stamp(turn.start)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor

        bodyLabel.attributedStringValue = base
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .labelColor
        // Not so anybody can change the font: this field is not editable. It
        // makes `NSTextFieldCell` round-trip its value as an *attributed*
        // string. A right-click installs a field editor, and when that editor
        // leaves the cell writes what it held back into the label, which for a
        // plain-text cell means the paragraph style is dropped. Measured on the
        // same wiring the app uses, right-clicking once and dismissing:
        //
        //     default                          lineSpacing 2.0 -> 0.0
        //     editor.isRichText = true         lineSpacing 2.0 -> 0.0
        //     allowsEditingTextAttributes      lineSpacing 2.0 -> 2.0
        //
        // So the paragraph quietly re-flowed tighter after the first
        // right-click and stayed that way until the pane was rebuilt.
        bodyLabel.allowsEditingTextAttributes = true
        bodyLabel.sentences = sentences
        bodyLabel.onEdit = { [weak self] in self?.beginEditing($0) }

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6

        for v in [speakerButton, timeLabel, body] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            speakerButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            // 8 and not 6: the pill's own padding used to hold the name clear of
            // this edge, and without it the name has to line up with the
            // paragraph under it or the turn reads as two indents.
            speakerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            timeLabel.centerYAnchor.constraint(equalTo: speakerButton.centerYAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: speakerButton.trailingAnchor,
                                               constant: 8),
            body.topAnchor.constraint(equalTo: speakerButton.bottomAnchor, constant: 3),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        fill(with: [bodyLabel])

        // No click gesture recogniser: `TranscriptBody.mouseDown` does this,
        // because only it runs late enough to have a field editor to ask which
        // word was under the pointer.
        bodyLabel.onClick = { [weak self] sentence in self?.onSeek?(sentence) }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func speakerTapped() {
        onSpeaker?(self, speakerButton.frame)
    }

    // MARK: - Editing a sentence

    /// Put `views` in the body, each as wide as the body itself.
    ///
    /// The width has to be said out loud. A vertical `NSStackView` sizes an
    /// arranged subview to what it asks for, and a wrapping label with no
    /// definite width asks for one long line, so without this the paragraph
    /// stops wrapping the moment it goes into the stack.
    private func fill(with views: [NSView]) {
        for view in body.arrangedSubviews { view.removeFromSuperview() }
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
    }

    /// The part of the paragraph either side of the sentence being edited.
    private func context(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        // Dimmed, so which of the three pieces is live needs no explaining.
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        return label
    }

    func beginEditing(_ sentence: Merge.Sentence) {
        guard editing == nil else { return }
        let whole = base.string as NSString
        guard NSMaxRange(sentence.range) <= whole.length else { return }
        editing = sentence

        let before = whole.substring(to: sentence.range.location)
        let after = whole.substring(from: NSMaxRange(sentence.range))

        let field = NSTextField(string: whole.substring(with: sentence.range))
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        editField = field

        var pieces: [NSView] = []
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pieces.append(context(before))
        }
        pieces.append(field)
        if !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pieces.append(context(after))
        }
        fill(with: pieces)

        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        onEditingChanged?(self, true)
    }

    /// Take what is in the field and hand it up. Returns false if nothing was
    /// being edited, which is what makes this safe to call from anywhere.
    @discardableResult
    func commitEditing() -> Bool {
        guard let sentence = editing, let field = editField else { return false }
        let whole = base.string as NSString
        let was = whole.substring(with: sentence.range)
        let typed = field.stringValue
        // Torn down before the callback, so the re-entrant
        // `controlTextDidEndEditing` that removing the field provokes finds
        // nothing left to commit.
        stopEditing()
        onEdit?(sentence, was, typed)
        return true
    }

    func cancelEditing() {
        guard editing != nil else { return }
        stopEditing()
    }

    private func stopEditing() {
        guard editing != nil else { return }
        editing = nil
        editField = nil
        fill(with: [bodyLabel])
        // The highlight was frozen while the field was up, so let the next
        // playhead tick reapply it rather than leaving a stale one.
        highlighted = nil
        onEditingChanged?(self, false)
    }
}

extension TurnView: NSTextFieldDelegate {
    /// Clicking away commits, which is what clicking away means everywhere else
    /// in this window.
    func controlTextDidEndEditing(_ note: Notification) { commitEditing() }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return commits rather than adding a line. A transcript sentence
            // has no line breaks in it, and the field is only multi-line so a
            // long one wraps instead of scrolling sideways.
            commitEditing()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditing()
            return true
        default:
            return false
        }
    }
}

// MARK: - Renaming

extension DetailView: NSTextFieldDelegate, NSTextViewDelegate {
    /// Commit the title when the field loses focus or Return is pressed.
    ///
    /// `metadata.json` already carried a `title` field in the Python version,
    /// so the key is unchanged and the existing tools keep reading it.
    func controlTextDidEndEditing(_ note: Notification) {
        guard var current = recording else { return }
        let typed = titleLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clearing the field un-names the recording rather than leaving a row
        // with nothing to click: the placeholder goes back on disk, which is
        // the same state it was in before anyone named it.
        let name = typed.isEmpty ? Metadata.untitled : typed
        titleLabel.stringValue = typed
        guard name != current.metadata.title else { return }
        current.metadata.title = name
        try? current.save()
        recording = current
        onChanged?()
    }

    func beginEditingTitle() {
        window?.makeFirstResponder(titleLabel)
        titleLabel.currentEditor()?.selectAll(nil)
    }

    /// Open the tag popover from a menu, where there is no pill to point at.
    ///
    /// The strip's own frame when there is one, and the trailing end of the
    /// subtitle when the band is collapsed, which is a live or untranscribed
    /// recording. It has to be somewhere real: a popover anchored to a
    /// zero-height rect opens and closes in the same call, reporting
    /// `isShown == false` immediately afterwards with nothing else to say so.
    func beginEditingTags() {
        guard recording != nil else { return }
        let rect = tagChips.isHidden || tagChips.bounds.height < 1
            ? NSRect(x: bounds.maxX - 44, y: subtitleLabel.frame.minY - 4,
                     width: 20, height: 20)
            : tagChips.frame
        editTags(from: self, rect: rect)
    }

    /// Give up the title field, wherever the click landed.
    ///
    /// A text field does not stop editing because the user clicked something
    /// that is not a control: `NSView` does not accept first responder, so the
    /// click goes nowhere and the caret stays blinking in a heading nobody is
    /// typing in any more. Clicking the transcript, the player or the empty
    /// space around them now commits the name, which is what clicking away
    /// means everywhere else.
    func endEditingTitle() {
        guard titleLabel.currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
    }

    /// Give up whichever field is open: the title, or a sentence.
    ///
    /// The two have the same problem and therefore the same answer. Neither
    /// stops editing because the user clicked something that is not a control,
    /// so every control in this pane that swallows its own click has to say
    /// so, and `mouseDown` catches the rest.
    func endEditing() {
        endEditingTitle()
        editingTurn?.commitEditing()
    }

    /// Clicks that no subview claimed arrive here through the responder chain,
    /// which is every part of this pane that is not a button or a link.
    override func mouseDown(with event: NSEvent) {
        // A click anywhere in the notes area is a click on the note.
        //
        // An `NSTextView` in a scroll view is only as tall as its own text, so
        // an empty note is one line high and the whole obvious writing surface
        // below it is scroll view that does nothing when clicked. Measured on
        // an empty note: the caret never appeared, which reads as a field that
        // is not really a field.
        if showing == .notes, notesText.isEditable, !notesScroll.isHidden,
           notesScroll.frame.contains(convert(event.locationInWindow, from: nil)) {
            window?.makeFirstResponder(notesText)
            // At the end rather than the start: a click below the text means
            // "carry on from here", and there is nothing below the text.
            notesText.setSelectedRange(
                NSRange(location: (notesText.string as NSString).length, length: 0))
            return
        }
        endEditing()
        super.mouseDown(with: event)
    }
}

/// Hosts `DetailView` so it can be a split view item.
@MainActor
final class DetailViewController: NSViewController {
    private let detail = DetailView()

    var onChanged: (() -> Void)? {
        get { detail.onChanged }
        set { detail.onChanged = newValue }
    }

    override func loadView() {
        let container = NSView()
        container.addSubview(detail)
        NSLayoutConstraint.activate([
            detail.topAnchor.constraint(equalTo: container.topAnchor),
            detail.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
    }

    func show(_ recording: Recording?) {
        loadViewIfNeeded()
        detail.show(recording)
    }

    func beginEditingTitle() {
        loadViewIfNeeded()
        detail.beginEditingTitle()
    }

    func beginEditingTags() {
        loadViewIfNeeded()
        detail.beginEditingTags()
    }

    func stopPlayback() { detail.stopPlayback() }

    /// The running job moved. Cheap by construction, and called per chunk.
    func showProgress() {
        guard isViewLoaded else { return }
        detail.showProgress()
    }

    func previewTranscribing(_ fraction: Double) {
        loadViewIfNeeded()
        detail.previewTranscribing(fraction)
    }

    func showNote(_ slug: String?) {
        loadViewIfNeeded()
        detail.showNote(slug)
    }

    func showTranscript() {
        loadViewIfNeeded()
        detail.showTranscript()
    }

    /// Flush a keystroke that has not reached disk yet. Safe at any time.
    func saveYours() {
        guard isViewLoaded else { return }
        detail.saveYours()
    }
}

/// A label that clicks pass straight through.
///
/// The note's placeholder sits over the text view, and a plain `NSTextField`
/// is hit-testable whether or not it is selectable: clicking the words that
/// say "type here" landed on the label and went nowhere. Nothing about a
/// placeholder is interactive, so it should not be in the hit chain at all.
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A clip view whose origin is the top left.
///
/// `NSClipView` is not flipped, so its origin is the bottom left and a document
/// view shorter than the viewport is laid out at the **bottom**. A short
/// transcript therefore sat on the floor of the detail pane with the rest of
/// the window empty above it.
///
/// This is the same rule that puts a short Settings pane on the floor of its
/// window, handled there by making the stack fill the clip view's height. Here
/// the content genuinely varies from two lines to an hour of meeting, so
/// flipping the clip view is the honest fix: content starts at the top and
/// grows downward, which is the direction a conversation runs, and scrolling to
/// the top becomes `y = 0` rather than an expression involving the document
/// height.
final class TopAlignedClipView: NSClipView {
    override var isFlipped: Bool { true }

    /// **Never draws a background, and that is here rather than at the call
    /// sites.**
    ///
    /// `NSScrollView.drawsBackground = false` reaches through to the clip view
    /// it holds *at that moment*, so whether it sticks depends on the order two
    /// lines are written in. Of the four places that install one of these, two
    /// assign the clip view first and were right by accident, and two set the
    /// flag first and then handed back a fresh clip view carrying its own
    /// default of `true`. Those two are both popovers, and both painted
    /// `.controlBackgroundColor` over the popover's material: the list read as
    /// a sunken grey well inside the card rather than as part of it, and it
    /// only showed when the list was short enough to see through.
    ///
    /// Every caller sets `drawsBackground = false` on the scroll view, so none
    /// of them wants one. Answering it here makes the ordering stop mattering.
    override var drawsBackground: Bool {
        get { false }
        set {}
    }
}
