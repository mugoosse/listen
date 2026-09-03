import AVFoundation
import AppKit
import ListenKit

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
    /// Find in page. Collapsed to nothing until Cmd-F, see `findTop`.
    private let findBar = FindBar()
    private let playButton = NSButton()
    private let waveform = WaveformView()
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let activityLabel = NSTextField(labelWithString: "")
    private let activityValue = NSTextField(labelWithString: "")
    private let activityBar = BrandProgressBar()

    /// Which speaker the pane is asking about, or nil for none.
    ///
    /// **It changes the playing, never the reading.** This used to hide every
    /// paragraph but theirs, and that was wrong twice over: clicking a name to
    /// find out who somebody is should not take the transcript away, and a page
    /// that empties on a click reads as a fault rather than as a filter. What is
    /// left is the part that could not be had any other way: play runs through
    /// their turns in order, and the waveform picks their bars out of everybody
    /// else's, which is how you find a speaker who says four words in an hour.
    ///
    /// The transcript stays whole, so nothing here may filter `turns`,
    /// `sentences` or `turnViews`. `refresh` indexes all three against each
    /// other twenty times a second and the sentence editor writes back through
    /// the same indices.
    private var focused: String?

    /// True while the **popover's own Play** is what is running.
    ///
    /// Skipping everybody else is what that button offers in so many words, so
    /// it is the one press that may do it. Anything that means "play the
    /// meeting", the pane's play button or a scrub, clears this, and the
    /// playhead stops jumping at once.
    ///
    /// **This is what a bar over the transcript used to say instead.** It read
    /// "Play runs through Edgar, skipping everybody else · 16 turns · 1:32",
    /// which was honest and cost a line of layout under the player that appeared
    /// and vanished on a click, moving the transcript under the reader's eyes
    /// every time they asked who somebody was. Removing the bar and leaving the
    /// skipping to the button that names it costs one `Bool` and no layout.
    private var playingFocused = false

    /// Which popover owns the current focus.
    ///
    /// A `.transient` popover reports its close whenever it gets round to it,
    /// and clicking a second chip opens one popover while closing another, so a
    /// late close from the one being replaced would clear the focus the new one
    /// just set. Each opening takes the next token and a close only undoes its
    /// own, which makes the order the two callbacks arrive in stop mattering.
    private var focusToken = 0

    /// What stands in for the transport when the audio is on another Mac.
    ///
    /// In the card rather than instead of it, so the transcript does not move
    /// and the empty space is visibly the player's rather than a gap. See
    /// `setPlayer`.
    private let playerNote = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let scroll = NSScrollView()

    /// The transcript's margins, which belong to the document and not to the
    /// scroll view around it.
    ///
    /// **An overlay scroller rides its own scroll view's edge, so a scroll view
    /// inset from the pane hangs its scroller in mid air.** This one was inset
    /// 20 on both sides and its scroller came out 23 points short of the
    /// window, floating over the transcript rather than sitting at the edge of
    /// it, which is where every Mac app that scrolls a document puts one. The
    /// scroll view is flush with the pane now, and the margin it was holding is
    /// here instead, along with the 20 points the document was narrower than
    /// the scroll view by and the stack's own padding. The text does not move:
    /// 20 + 4 on the left and 20 + 20 + 16 on the right are what these two
    /// numbers add up to.
    ///
    /// Left is 24, which is where every heading on this page starts. Right is
    /// 56: the same 24 of margin plus a 32 point gutter, so a line of dialogue
    /// never runs under the scroller. Top is 6 rather than 16 because the player
    /// card is directly above and the scroll view's own gap already separates
    /// them, so 16 was a third margin stacked on two others.
    private static let transcriptInsets = NSEdgeInsets(top: 6, left: 24,
                                                       bottom: 40, right: 56)
    /// What every row in the stack gives back to `transcriptInsets`.
    ///
    /// `NSStackView` lays its arranged views out inside `edgeInsets` but does
    /// not size them, so each row states its own width and the two have to
    /// agree. Derived rather than written out, because they came apart once
    /// already: the insets moved and three constants elsewhere did not.
    private static var transcriptSides: CGFloat {
        transcriptInsets.left + transcriptInsets.right
    }
    private let empty = NSTextField(labelWithString: "")

    /// The meeting being read, drawn while it happens. Replaces the sentence
    /// above for the one state that has something to show rather than something
    /// to explain.
    private let transcribing = TranscribingView()
    private let emptyIcon = BrandIcon.view(size: 64, accessibilityLabel: "Listen mascot")

    /// The recording as it happens: a page to write on and both tracks moving.
    ///
    /// Takes the whole pane below the header while capture runs, with the mode
    /// picker collapsed, because there is nothing to switch between yet. See
    /// `RecordingView`.
    private let live = RecordingView()

    /// Which document this pane is showing.
    ///
    /// A mode rather than two panes side by side: the transcript and a note are
    /// both the whole width of the reading area, and neither is worth half of
    /// it. Held in a property rather than read back off the segmented control,
    /// which is `DictionaryPane`'s rule and for the same reason: a re-render
    /// would otherwise snap it back to whatever the control last drew.
    /// **The page, or the asking.** Transcript and Notes were peers here, which
    /// made the two halves of one meeting into two places you had to choose
    /// between: the notes you took and the record of what was said, one hidden
    /// behind the other. They are one page now, notes above and transcript
    /// below, and what is left of the picker is a way in and out of Ask.
    private enum Showing { case page, ask }
    private var showing: Showing = .page

    private let modeBar = NSView()
    /// One segment, and it toggles.
    ///
    /// It held three: Transcript, Notes and Ask. Two of those are the same page
    /// now, so what is left is not a choice between documents but a way into the
    /// one surface that is not a document at all. `.selectAny` rather than
    /// `.selectOne`, so pressing it again is the way back, which a control with
    /// nothing else to select cannot otherwise offer.
    /// Never shown any more, and kept only until `Showing.ask` is deleted with
    /// it. The composer moved to the window, so a control here that swapped the
    /// pane for a conversation would be a second way to ask, sitting above a
    /// bar that is already asking.
    private let modePicker = NSSegmentedControl(
        labels: ["Ask"], trackingMode: .selectAny,
        target: nil, action: nil)
    /// Which half of the meeting is on screen.
    ///
    /// **Tabs rather than sections.** The two halves were stacked: a note box
    /// of between 30 and 154 points, and the transcript under it taking what
    /// was left. That is right while the note is a margin annotation and wrong
    /// as soon as it is a document: the note could never be more than six lines
    /// tall without scrolling inside a box smaller than the window, and the
    /// transcript permanently started a third of the way down the pane.
    ///
    /// As tabs each one gets the whole reading area. The cost is that they
    /// cannot be read at the same time, which is the trade the stacked layout
    /// was making in the other direction, and the count on the Notes tab is
    /// what keeps a written note from becoming invisible behind it.
    private enum Tab { case recording, notes, chats }
    /// Recording, always, until somebody says otherwise.
    ///
    /// A meeting is what was said; the note is what you made of it, and you
    /// cannot have made anything of a meeting you have not opened yet. It
    /// survives a selection change for the reason the mode always has: reading
    /// notes down a list of meetings is a mode, not a choice repeated at every
    /// row. Stopping a recording puts it back, because pressing Stop is a
    /// request to see what was said.
    private var tab: Tab = .recording
    /// The tab bar, on the row the mode picker used to have to itself.
    ///
    /// `.selectOne`, unlike `modePicker` next door: these are documents and
    /// exactly one of them is up, so pressing the selected one again must do
    /// nothing rather than leave the pane showing neither.
    ///
    /// Fixed widths so the bar does not resize under the pointer when a count
    /// changes. 104 is "Recording" at the control's own font plus its padding,
    /// measured, and the other segments match it rather than hugging a shorter
    /// word: tabs of different widths read as one being more important than the
    /// others.
    ///
    /// **Three segments, and the third is not always there.** Chats is built
    /// with the control and removed from it when `Settings.askEnabled` is off:
    /// with Ask off there is no composer on this window at all, so a tab whose
    /// empty state says "ask a question below" would point at a card that does
    /// not exist. `setTabs` is what applies that, and it is the only place the
    /// segment count is written.
    private let tabPicker = NSSegmentedControl(
        labels: ["Recording", "Notes", "Chats"], trackingMode: .selectOne,
        target: nil, action: nil)
    /// What the note being read is filed under.
    ///
    /// **Its own strip, not the one in the header.** That one is the
    /// recording's, and the two are different claims: a meeting tagged
    /// `kinsight` and the write-up of it tagged `kinsight` are two filings, and
    /// nothing here infers one from the other. This is also the only place a
    /// note about a single meeting can be tagged by hand, because such a note
    /// is read in this pane and never gets a page of its own in the sidebar.
    private let noteTagChips = TagChips()
    /// The greeting over an empty pane, with the mascot beside it.
    ///
    /// The empty state used to be one grey sentence of instruction. This screen
    /// is where somebody arrives and where they can now work from, so it opens
    /// with their name rather than with a direction.
    private let greeting = NSTextField(labelWithString: "")
    /// The conversations about the library, listed on the screen you land on.
    ///
    /// This is what replaced the history control on this screen. The library
    /// screen lists its own here, a recording page has a Chats tab, and the
    /// card carries the rest: its title while a conversation is open, and
    /// History on the starters line while one is not.
    private let recentChats = LinkLine()
    /// The agent notes about this meeting that are not the user's own, on one
    /// line above the note being read.
    ///
    /// **It named the conversations too, and no longer does.** They are a tab
    /// now: see `chatList`. What is left here is the notes half, which belongs
    /// on this line because every link in it opens a document in the box
    /// directly underneath, and the line is on the Notes tab only for the same
    /// reason.
    private let chatLinks = LinkLine()
    private var chatLinksTop: NSLayoutConstraint!
    private var chatLinksHeight: NSLayoutConstraint!
    /// The same conversations as a tab of their own. See `ChatList`.
    ///
    /// **It took the conversations off `chatLinks`, and that line kept the
    /// notes.** They were together there on the argument that both are somebody
    /// else's reading of this meeting, which is true and was not enough: an
    /// agent's note is a document the Notes tab already holds and opens in
    /// place, and a conversation is a page you leave this one for. One line
    /// offering both, in one run of accent-coloured text, made the difference
    /// between them a thing you found out by clicking.
    private let chatList = ChatList()

    /// How much of the bottom of this pane the drawer is covering.
    ///
    /// The drawer overlays rather than pushes, which is what keeps the page's
    /// layout and scroll position intact. The cost is that the last lines of a
    /// transcript sit underneath it: not clipped, but unreachable, because the
    /// scroll had nothing telling it there is furniture over its floor.
    ///
    /// **Room at the end of the document, not a content inset.** Both leave the
    /// last turn clear of the composer, and they differ in where the scroller
    /// ends: the scroller is laid out inside the content area, so any bottom
    /// content inset shortens its track by the same amount. With the composer up
    /// that stopped the transcript's track 140 points above the window's floor,
    /// with nothing under it, which reads as a scroller that has run out of
    /// window rather than one that has run out of document. A spacer at the end
    /// of the stack moves only the end of the document: the track runs the whole
    /// height of the pane and the knob reaches the floor.
    ///
    /// Nothing else changes. Content passed behind the drawer while scrolling
    /// either way, because a content inset limits how far a document may go, not
    /// what may be drawn over it, and the last turn ends up in the same place:
    /// `RecordButton.clearance` plus this, under the stack's own bottom inset.
    ///
    /// Kept in a field because the transcript is rebuilt from its turns and the
    /// tail is built with it, so the spacer has to be told again each time.
    private var drawerCover: CGFloat = 0
    /// The spacer at the end of the transcript, which is the room above.
    private var tailHeight: NSLayoutConstraint?

    func setBottomInset(_ points: CGFloat) {
        guard abs(drawerCover - points) > 0.5 else { return }
        drawerCover = points
        tailHeight?.constant = RecordButton.clearance + points
        // The note reaches the floor now, so the drawer covers it exactly as it
        // covers the transcript. A constraint rather than a content inset, for
        // the reason this file records twice over: an inset is a scroll offset
        // and will not hold a view in place.
        notesBottom?.constant = -(RecordButton.clearance + points)
        chatListBottom?.constant = -(RecordButton.clearance + points)
    }

    private let askView = AskView()
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

    /// The air above the note, which is a gap between two views and no longer
    /// anything AppKit has an opinion about.
    ///
    /// **It was the scroll view's `contentInsets.top`, and a content inset is
    /// not a position.** It is a scroll offset: the clip view honours it while
    /// the document is scrolled to the top of its range and clamps it away when
    /// the document is shorter than the clip view, which an empty note always
    /// is. So the caret came out at the text view's own 2 points and the
    /// placeholder, positioned honestly at 16, sat a line below it, on the one
    /// screen where the two are looked at together. The 14 points now live in
    /// the constraint above `notesScroll`, where nothing can reclaim them, and
    /// the pane's geometry is unchanged: the box starts 14 lower and is 14
    /// shorter, so everything below it is where it was.
    private static let notesTopInset: CGFloat = 14
    /// The air under the tab bar, above whatever the tab puts first.
    ///
    /// Two points more than the player's own 14, because a card's top edge is
    /// where it says it is and a line of text carries its leading above the cap
    /// height: measured against each other on the two tabs, equal constants
    /// read as the Notes tab being the tighter of the two.
    private static let underTabs: CGFloat = 16
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
    /// The note reaches the floor of the pane, less the room the record capsule
    /// and the conversation drawer need.
    ///
    /// **This replaced a measured height.** The box used to be sized to its own
    /// text between a floor of 30 and a ceiling of 154, because it was sharing
    /// the pane with the transcript and had to leave it something. On a tab of
    /// its own there is nothing to share with, so a note is as tall as the
    /// window and `sizeNotes` has gone with the constants it used.
    ///
    /// The gap at the bottom is invisible: the scroll view does not draw a
    /// background, so what is under the last line is the pane. See
    /// `setBottomInset`, which is the only thing that moves it.
    private var notesBottom: NSLayoutConstraint!
    private var chatListBottom: NSLayoutConstraint!
    private var playerTop: NSLayoutConstraint!
    private var playerHeight: NSLayoutConstraint!
    /// The find bar's pair. Closed is 0 and 0, which puts `findBar.bottom`
    /// exactly on `playerCard.bottom` and leaves the page laid out as it was
    /// before this existed. That is the whole argument for putting it here.
    private var findTop: NSLayoutConstraint!
    private var findHeight: NSLayoutConstraint!
    /// Every match on the page, in reading order: the title, then the note on
    /// screen, then the paragraphs. The array is the order; nothing sorts it.
    private var found: [FindMatch] = []
    /// Which of them the bar is sitting on.
    private var foundAt: Int?
    /// What is being searched for, empty when the bar is shut.
    private var finding = ""
    /// The note ranges the layout manager is currently decorating.
    ///
    /// Held because a range into text that has since been replaced is a range
    /// into nothing, and taking a temporary attribute off has to name where it
    /// was put.
    private var noteHighlighted: [NSRange] = []
    private var noteInfoTop: NSLayoutConstraint!
    private var noteInfoHeight: NSLayoutConstraint!
    /// Whether this recording has anything to play. Held rather than recomputed,
    /// because the player is now collapsed by the mode as well as by the audio
    /// and both have to agree.
    private var hasAudio = false

    /// Fires when this pane changes something the list also shows.
    var onChanged: (() -> Void)?
    /// A conversation named on this page, handed to whoever owns the composer.
    var onOpenChat: ((Chat) -> Void)?

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

    /// When the paragraph the playhead is in begins.
    ///
    /// The identity `currentTurn` cannot carry: an index names a position in a
    /// list that every edit renumbers, and this names the paragraph itself. See
    /// `refresh`, which is the only reader.
    private var currentStart: Double?

    /// Where the reader is in the transcript, kept so a rebuild can put them
    /// back.
    ///
    /// **Remembered rather than read off the clip view when it is wanted.** A
    /// rebuild empties the stack, the document collapses to nothing for a pass,
    /// and a clip view whose document is shorter than its own bounds clamps its
    /// origin to zero, so by the time anything asks the clip view where the
    /// reader was, the answer is the top. `userScrolled` is what keeps this
    /// honest, and it deliberately ignores exactly that one bounds change.
    private var readingOrigin: NSPoint = .zero

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
        playButton.action = #selector(playPressed)
        playButton.toolTip = "Play"

        waveform.onScrub = { [weak self] fraction in self?.scrub(to: fraction) }

        // A chip is a control, so its click never reaches `mouseDown` below and
        // it has to let the title field go itself. `editSpeaker` does that,
        // because it has to happen in a particular order: see the comment
        // there.
        chips.onName = { [weak self] speaker, anchor, rect in
            self?.editSpeaker(speaker, from: anchor, rect: rect)
        }
        chips.onChanged = { [weak self] in self?.reloadAfterSpeakerChange() }
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

        // Two on the pane, and each writes to the thing its row is about. This
        // one is the note's; `tagChips` above is the recording's.
        noteTagChips.onTag = { name, _, _ in LibraryWindow.shared.filter(byTag: name) }
        noteTagChips.onAdd = { [weak self] anchor, rect in
            self?.editNoteTags(from: anchor, rect: rect)
        }
        noteTagChips.onChanged = { [weak self] in self?.refreshNoteTags() }

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        activityLabel.font = .systemFont(ofSize: 11, weight: .medium)
        activityLabel.textColor = .secondaryLabelColor
        activityLabel.lineBreakMode = .byTruncatingTail
        activityValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        activityValue.textColor = .secondaryLabelColor
        activityValue.alignment = .right
        for view in [activityLabel, activityValue, activityBar] as [NSView] {
            view.isHidden = true
        }

        // A card, so the player reads as one control rather than three that
        // happen to share a line. The transcript below is the page; this is the
        // instrument on top of it.
        playerCard.wantsLayer = true
        playerCard.layer?.cornerRadius = 12
        playerCard.layer?.borderWidth = 1
        styleCard()

        stack.orientation = .vertical
        stack.alignment = .leading
        // 10 rather than 18. Each turn already carries a speaker name in colour
        // above it, so the gap was doing a job the label does: at 18 a two-line
        // exchange read as two separate documents rather than as one
        // conversation. It went 18, 12, 10, and the padding inside each turn
        // came down with it: what separates two turns is the sum of three
        // numbers, so trimming only this one never moved much.
        stack.spacing = 10
        stack.edgeInsets = Self.transcriptInsets
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
        // No insets on any edge, so the scroller's track is the whole pane. The
        // room the drawer needs is at the end of the document instead, and this
        // says so once rather than leaving it to whether `setBottomInset` has
        // been called yet: automatic adjustment was on until the composer first
        // reported a height, and off afterwards.
        scroll.automaticallyAdjustsContentInsets = false
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

        for v in [playButton, timeLabel, waveform, playerNote,
                  activityLabel, activityValue, activityBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            playerCard.addSubview(v)
        }
        for v in [modePicker, notePicker, tabPicker] {
            v.translatesAutoresizingMaskIntoConstraints = false
            modeBar.addSubview(v)
        }

        for v in [titleLabel, subtitleLabel, chips, tagChips, playerCard, modeBar,
                  scroll, noteInfo, notesScroll, notesPlaceholder, askView,
                  chatLinks, chatList, noteTagChips, greeting,
                  recentChats, empty, emptyIcon, transcribing, live, findBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        live.isHidden = true

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
        // **It holds the tab bar now**, which is what it was emptied of when the
        // page started naming its two halves with headings instead. The row was
        // kept through that against exactly this: "a second document mode is a
        // live possibility and the bar is where it would go".
        //
        // Still collapsed at build time and opened by `show`, because a live
        // recording and a transcript being made both take the whole pane and
        // have nothing to switch between.
        modeTop = modeBar.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 0)
        modeHeight = modeBar.heightAnchor.constraint(equalToConstant: 0)
        modeBar.isHidden = true
        // **Under the tab bar, and inside the Recording tab.** The transport
        // and the dialogue are one document: you play a meeting to read along
        // with it, so the player collapses with the transcript when the Notes
        // tab is up rather than hanging over a page it cannot transport.
        //
        // That is also why switching to Notes stops playback, which is the rule
        // `switchShowing` already makes for Ask: a transport nobody can see is
        // a transport nobody can pause.
        playerTop = playerCard.topAnchor.constraint(equalTo: modeBar.bottomAnchor,
                                                    constant: 10)
        playerHeight = playerCard.heightAnchor.constraint(equalToConstant: 58)
        // **Under the player, and zero until somebody presses Cmd-F.**
        //
        // Three views hang off `playerCard.bottomAnchor` and now hang off this
        // instead, at the same constants; closed, its top and height are both 0
        // and its bottom edge is the player's own, so the page is laid out to
        // the point as it was before the bar existed. A collapsed state that
        // cannot be subtly wrong is worth more than a tidier hierarchy on a
        // page this heavily tuned.
        //
        // Not at the top of the pane: the window is `.fullSizeContentView` with
        // a transparent title bar, so the toolbar floats over the content and a
        // full-width bar up there runs under the ellipsis and the record
        // capsule. Left-aligned is not clearance either: `titleLabel` sat at 38
        // on that reasoning and a long title ran under both, which is why it is
        // 52 now and below everything in the title bar rather than beside it.
        //
        // Not an overlay either: it would cover the top of the transcript,
        // which is where the first match usually is, and every `scrollToVisible`
        // below would carry a permanent top margin for ever. The obvious fix is
        // not available, because a content inset is a scroll offset and will not
        // hold a view in place, which is why `scroll` runs with
        // `automaticallyAdjustsContentInsets = false` already.
        findTop = findBar.topAnchor.constraint(equalTo: playerCard.bottomAnchor,
                                                constant: 0)
        findHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
        findBar.isHidden = true
        findBar.onQuery = { [weak self] text in self?.findQueryChanged(text) }
        findBar.onStep = { [weak self] by in self?.stepFind(by) }
        findBar.onDone = { [weak self] in self?.closeFind() }
        // **The Notes tab, top to bottom: the other documents, then who wrote
        // this one, then the note.** All three hang off the find bar rather than
        // off the tab row, so the two tabs share one chain: closed, the bar and
        // the collapsed player are both zero high and zero away, which puts the
        // top of this column exactly on the bottom of the tab bar. Opening it
        // with Cmd-F on the Notes tab then pushes the note down instead of
        // drawing over it.
        //
        // The links moved above the note rather than below it. Under the note
        // they were a footnote on the page; above it they are what they have
        // always been, which is a way to swap the document underneath.
        // **The 16 is the gap under the tab bar, and it belongs to the column
        // rather than to this line.** Both of the two lines above the note
        // collapse: the links when nothing else has been written about the
        // meeting, the provenance when the note has never been saved. With the
        // gap on whichever one happened to be first, a note with neither opened
        // with its own date pinned to the bottom edge of the tabs, and the
        // page read as though the bar had landed on the text.
        chatLinksTop = chatLinks.topAnchor.constraint(equalTo: findBar.bottomAnchor,
                                                      constant: Self.underTabs)
        chatLinksHeight = chatLinks.heightAnchor.constraint(equalToConstant: 0)
        noteInfoTop = noteInfo.topAnchor.constraint(equalTo: chatLinks.bottomAnchor,
                                                    constant: 8)
        noteInfoHeight = noteInfo.heightAnchor.constraint(equalToConstant: 0)
        // The floor of the pane, less the room the record capsule needs and
        // whatever the conversation drawer is covering. `setBottomInset` is the
        // only other thing that touches it.
        notesBottom = notesScroll.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -RecordButton.clearance)
        // The same floor as the note, for the same reason: a list whose last
        // row is behind the conversation card is a conversation you cannot get
        // to. A constraint rather than a content inset, which this file records
        // twice over as a scroll offset that will not hold a view in place.
        chatListBottom = chatList.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -RecordButton.clearance)
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
            // **52, because the record capsule ends at 39.5 and the title used
            // to start at 38.** The window is `.fullSizeContentView`, so the
            // toolbar floats over this view rather than sitting above it, and
            // being left-aligned is not the clearance it looks like: a title
            // long enough to fill the width runs the whole way under the
            // capsule and the ellipsis. Measured off a screenshot at 2x, with
            // the 28 point capsule bottom 39.5 points below the window's top
            // edge, the label's frame began 1.5 points *above* it and only the
            // text field's own 5 points of leading kept the glyphs out of it.
            // 52 puts the frame 12.5 points clear and the capital letters 17.5,
            // which is the gap the eye reads as deliberate at 22 point.
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 52),
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
            playerNote.centerYAnchor.constraint(equalTo: playerCard.topAnchor, constant: 29),

            playButton.leadingAnchor.constraint(equalTo: playerCard.leadingAnchor, constant: 10),
            playButton.centerYAnchor.constraint(equalTo: playerCard.topAnchor, constant: 29),
            playButton.widthAnchor.constraint(equalToConstant: 30),
            playButton.heightAnchor.constraint(equalToConstant: 30),
            timeLabel.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 10),
            timeLabel.centerYAnchor.constraint(equalTo: playerCard.topAnchor, constant: 29),
            // Fixed rather than hugging, so the waveform does not shift sideways
            // when the clock ticks past ten minutes.
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 92),
            waveform.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 12),
            waveform.trailingAnchor.constraint(equalTo: playerCard.trailingAnchor, constant: -14),
            waveform.centerYAnchor.constraint(equalTo: playerCard.topAnchor, constant: 29),
            waveform.heightAnchor.constraint(equalToConstant: 36),

            activityLabel.topAnchor.constraint(equalTo: playerCard.topAnchor, constant: 57),
            activityLabel.leadingAnchor.constraint(equalTo: playerCard.leadingAnchor,
                                                   constant: 14),
            activityLabel.trailingAnchor.constraint(lessThanOrEqualTo:
                                                     activityValue.leadingAnchor,
                                                     constant: -8),
            activityValue.centerYAnchor.constraint(equalTo: activityLabel.centerYAnchor),
            activityValue.trailingAnchor.constraint(equalTo: playerCard.trailingAnchor,
                                                     constant: -14),
            activityValue.widthAnchor.constraint(greaterThanOrEqualToConstant: 34),
            activityBar.topAnchor.constraint(equalTo: activityLabel.bottomAnchor, constant: 4),
            activityBar.leadingAnchor.constraint(equalTo: playerCard.leadingAnchor, constant: 14),
            activityBar.trailingAnchor.constraint(equalTo: playerCard.trailingAnchor,
                                                   constant: -14),
            activityBar.heightAnchor.constraint(equalToConstant: 2),

            modeTop,
            modeHeight,
            modeBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            modeBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            modePicker.leadingAnchor.constraint(equalTo: modeBar.leadingAnchor),
            modePicker.centerYAnchor.constraint(equalTo: modeBar.centerYAnchor),
            tabPicker.leadingAnchor.constraint(equalTo: modeBar.leadingAnchor),
            tabPicker.centerYAnchor.constraint(equalTo: modeBar.centerYAnchor),
            // Trailing, and allowed to shrink. A note titled with a whole
            // sentence would otherwise push the segmented control off the
            // leading edge of the pane.
            notePicker.trailingAnchor.constraint(equalTo: modeBar.trailingAnchor),
            notePicker.centerYAnchor.constraint(equalTo: modeBar.centerYAnchor),
            notePicker.leadingAnchor.constraint(
                greaterThanOrEqualTo: modePicker.trailingAnchor, constant: 12),

            // **Its own scroller, and never the transcript's.**
            //
            // Playback scrolls the transcript to the sentence being spoken. In
            // one scroller with the note, following the playhead would drag the
            // note about while somebody has a caret in it, so the two documents
            // scroll independently even now that only one is ever up.
            chatLinksTop,
            chatLinksHeight,
            chatLinks.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            chatLinks.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            // Flush with the pane on both sides, so its scroller is at the
            // window's edge and not 23 points inside it. The margins the two
            // constants here used to hold are in `transcriptInsets`, where the
            // scroller cannot inherit them.
            // `findBar.bottomAnchor` rather than the player's, at the same 8.
            // The bar is zero-high and zero-from-the-player when it is closed,
            // so this is the same line it was; see `findTop`.
            findTop,
            findHeight,
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            scroll.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            // The transcript's box, because it is the third document about this
            // meeting and the three take turns in one reading area.
            //
            // **2, so that a row's text lands on the page's own column.** This
            // one is a table and the other two are not: `.inset` style holds
            // the rows 14 off the table's edge and `RecordingCell.textInset`
            // adds the 8 inside that, which is the 22 the sidebar states. The
            // pane's own 24 on top of it put every conversation title a
            // control's width in from the meeting's name above it, which reads
            // as a list that belongs to something else. 2 + 22 is the 24.
            chatList.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 8),
            chatList.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            chatList.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            chatListBottom,

            // Flush to the pane's edges rather than inset like the transcript,
            // because the bottom of it is a bar. Its own padding puts the note's
            // text where the transcript's would be, so the reading position does
            // not move when the recording stops and this is replaced.
            //
            // Level with the transcript it stands in for, so the note above
            // stays put when a running recording finishes.
            live.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 12),
            live.leadingAnchor.constraint(equalTo: leadingAnchor),
            live.trailingAnchor.constraint(equalTo: trailingAnchor),
            live.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Trailing on the tab bar's own row, which is the arrangement the
            // strip is built for: it grows leftward from the pane's edge, so
            // the tabs and the filing never fight for a fixed split. It is the
            // note's filing rather than the recording's, so it is on screen
            // only while the Notes tab is, one row under the recording's own
            // strip and never beside it.
            noteTagChips.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            noteTagChips.centerYAnchor.constraint(equalTo: modeBar.centerYAnchor),
            noteTagChips.heightAnchor.constraint(equalToConstant: 22),
            noteTagChips.leadingAnchor.constraint(
                greaterThanOrEqualTo: tabPicker.trailingAnchor, constant: 12),

            noteInfoTop,
            noteInfo.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            noteInfo.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),

            // The 4 is the gap under the provenance line; the rest is the air
            // above the note, which is a constraint rather than a scroll inset
            // for the reason `notesTopInset` records.
            notesScroll.topAnchor.constraint(equalTo: noteInfo.bottomAnchor,
                                             constant: 4 + Self.notesTopInset),
            notesScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            notesScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            notesBottom,

            // The same box the notes pane occupies, and for the same reason:
            // both are documents about the meeting whose title is above them.
            // Its own composer is pinned inside it, so this one reaches the
            // bottom of the window rather than stopping short of it.
            askView.topAnchor.constraint(equalTo: findBar.bottomAnchor, constant: 8),
            askView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            askView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            askView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

            // Exactly where the caret will be, and derived rather than measured
            // so the two cannot come apart again: the note's first line starts
            // at the text view's own inset and nothing else, so the prompt does
            // too. An `NSTextView` has no placeholder of its own.
            notesPlaceholder.topAnchor.constraint(
                equalTo: notesScroll.topAnchor, constant: Self.notesTextInset),
            notesPlaceholder.leadingAnchor.constraint(equalTo: notesScroll.leadingAnchor),
            notesPlaceholder.trailingAnchor.constraint(equalTo: notesScroll.trailingAnchor),

            // The document is as wide as the scroll view, and the gutter the
            // scroller needs is `transcriptInsets.right`. It used to be this
            // constant, which the rows below then had to know about as well.
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            greeting.centerXAnchor.constraint(equalTo: centerXAnchor),
            greeting.bottomAnchor.constraint(equalTo: empty.topAnchor, constant: -14),
            recentChats.topAnchor.constraint(equalTo: empty.bottomAnchor, constant: 22),
            recentChats.centerXAnchor.constraint(equalTo: centerXAnchor),
            recentChats.widthAnchor.constraint(equalToConstant: 420),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            emptyIcon.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            // Above the greeting, which is what it now introduces. Anchored to
            // `empty` it sat on top of the words: that constraint predates
            // there being anything between the mascot and the sentence.
            emptyIcon.bottomAnchor.constraint(equalTo: greeting.topAnchor, constant: -16),

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
        //
        // **Below the split view's holding priorities, which are 250 and 260.**
        // At `.defaultHigh` this equality outranked the constraint that holds
        // the divider where it was dragged, and the engine had a cheaper way to
        // satisfy it than the one intended: instead of narrowing this view to
        // the 620 point cap, it narrowed the *pane*. Measured on the running
        // window, in the recordings collection only: the content side was
        // exactly 700 wide whatever the window did (620 plus the two 40 point
        // margins), the sidebar took the rest, the divider would not move at
        // all, and the window itself refused to grow past 1168 or shrink below
        // 799. People and Notes dragged normally because this view is only in
        // the recording pane, and it did it while hidden because a hidden view
        // keeps its constraints as surely as it keeps its frame.
        let width = transcribing.widthAnchor.constraint(equalTo: widthAnchor, constant: -80)
        width.priority = NSLayoutConstraint.Priority(200)
        width.isActive = true
    }

    // MARK: - Notes

    private func buildNotesPane() {
        tabPicker.selectedSegment = 0
        tabPicker.selectedSegmentBezelColor = Brand.tint
        tabPicker.target = self
        tabPicker.action = #selector(switchTab)
        tabPicker.font = .systemFont(ofSize: 12)
        // Measured rather than left to hug: "Recording" is the longer word, and
        // the Notes segment grows a count as soon as anything is written there.
        // Left to autosize, the bar changed width under the pointer the first
        // time somebody typed a note.
        // Every tab on the bar is a document, so the bar says so out loud for
        // anybody driving this with the keyboard or a screen reader. The
        // segments carry their own labels; this names what they switch.
        tabPicker.setAccessibilityLabel("What to show for this recording")
        setTabs()

        chatList.onOpen = { [weak self] chat in self?.openChat(chat) }

        modePicker.selectedSegment = 0
        modePicker.selectedSegmentBezelColor = Brand.tint
        modePicker.target = self
        modePicker.action = #selector(switchShowing)
        modePicker.isHidden = true

        // An answer saved from Ask is a note like any other, and the switcher
        // in Notes has to know about it without being switched away from and
        // back. Clearing the signature is what makes `reloadNotes` actually
        // re-read: it skips the work when the list looks unchanged.
        askView.onNoteWritten = { [weak self] in
            self?.notesSignature = ""
            self?.reloadNotes(reset: false)
        }
        askView.isHidden = true

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
        // Every line of this is `noteInfo`'s, and none of it is optional. An
        // `NSTextView` left at its defaults draws an opaque background and
        // colours a link system blue whatever the attributed string asks for,
        // which is a filled band across the pane in the wrong colour: measured
        // by leaving it out first.
        chatLinks.isEditable = false
        chatLinks.isSelectable = true
        chatLinks.drawsBackground = false
        chatLinks.delegate = self
        chatLinks.textContainerInset = .zero
        chatLinks.textContainer?.lineFragmentPadding = 0
        chatLinks.textContainer?.widthTracksTextView = true
        chatLinks.isVerticallyResizable = true
        chatLinks.isHorizontallyResizable = false
        chatLinks.setContentHuggingPriority(.required, for: .vertical)
        chatLinks.linkTextAttributes = [
            .foregroundColor: Brand.accent,
            .cursor: NSCursor.pointingHand,
        ]

        // Every setting `noteInfo` carries, for the reason recorded there: an
        // `NSTextView` left at its defaults draws an opaque background and
        // paints a link system blue whatever the string asks for.
        recentChats.isEditable = false
        recentChats.isSelectable = true
        recentChats.drawsBackground = false
        recentChats.delegate = self
        recentChats.textContainerInset = .zero
        recentChats.textContainer?.lineFragmentPadding = 0
        recentChats.textContainer?.widthTracksTextView = true
        recentChats.isVerticallyResizable = true
        recentChats.isHorizontallyResizable = false
        recentChats.setContentHuggingPriority(.required, for: .vertical)
        recentChats.alignment = .center
        recentChats.linkTextAttributes = [
            .foregroundColor: Brand.accent,
            .cursor: NSCursor.pointingHand,
        ]
        recentChats.isHidden = true

        greeting.font = .systemFont(ofSize: 26, weight: .semibold)
        greeting.textColor = .labelColor
        greeting.alignment = .center
        greeting.isHidden = true

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
        // The scroller is only wanted when the note is past its ceiling, which
        // is the only time this box has anything to scroll. Without this a Mac
        // set to show scroll bars always draws an empty legacy track down the
        // right of a two-line box, taking 17 points of the writing surface to
        // say nothing. Measured: the same note is 1149 points wide with the
        // scroller and 1166 without it.
        notesScroll.autohidesScrollers = true
        notesScroll.drawsBackground = false
        notesScroll.isHidden = true
        // **No insets, and every edge has to say so.** Setting `contentInsets`
        // at all turns `automaticallyAdjustsContentInsets` off, so each edge is
        // whatever is stated here, and the honest value on all four is zero: an
        // inset is a scroll offset rather than a position, and the air above the
        // note is a constraint. See `notesTopInset`.
        //
        // **The bottom was `RecordButton.clearance` and that was the bug.** It
        // was copied from the transcript while the Record button floated over
        // this pane's corner, and it never applied here: this box is 30 to 154
        // points tall between the chips and the player, and the transcript below
        // it is what actually reaches the window's floor. What 24 points of
        // inset bought instead was 24 points of scrollable nothing under every
        // note, so a one-line note could be scrolled until its own line left the
        // box, and a scroller whose track is the box minus the inset: 6 points
        // of track on an empty note, holding a 2-point knob that appeared
        // against the right edge as a sliver nothing on the page explained.
        notesScroll.automaticallyAdjustsContentInsets = false
        notesScroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        // An agent writes notes while this window is open and nothing on disk
        // announces it. Coming back to the app is the moment somebody expects
        // to see what it wrote, and re-reading one directory is cheap enough to
        // do on every activation.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    /// A hidden view still occupies its frame, so both dimensions have to go.
    ///
    /// 14 above and 24 high, which is the row the tab bar sits in. `applyShowing`
    /// is the only caller that opens it, so the bar cannot be on screen over a
    /// pane that has no two documents to switch between.
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
        // 14, which is `underTabs` less the leading a line of text carries and
        // a card does not. It was 10 under a section heading, which is a label
        // and lighter than a bar of two controls.
        playerTop.constant = collapsed ? 0 : 14
        let expanded: CGFloat
        if activityLabel.isHidden { expanded = 58 }
        else { expanded = activityBar.isHidden ? 78 : 86 }
        playerHeight.constant = collapsed ? 0 : expanded
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
        // Which device is coming for it depends on where it was made, and
        // saying "the Mac that recorded it" about a phone recording is simply
        // false: this Mac is the one that will fetch and transcribe it.
        //
        // Unless another Mac already took it. A claimed phone recording is on
        // a named machine and is never coming here, because audio does not
        // move once it lands, so the container's answer wins over the guess
        // from `metadata.source` whenever there is one.
        if let id = recording?.id, let holder = CloudSyncHost.audioHolder(of: id) {
            playerNote.stringValue = "The audio for this meeting is on \(holder)."
        } else if let recording, CloudSyncHost.nothingHolds(recording) {
            playerNote.stringValue = "No device has reported keeping the audio "
                + "for this meeting."
        } else {
            playerNote.stringValue = recording?.metadata.source == "iphone"
                ? "The audio is coming from your iPhone."
                : "The audio for this meeting is on the Mac that recorded it."
        }
    }

    /// Move between the transcript and the note.
    ///
    /// Playback stops on the way out of Recording, which is the rule
    /// `switchShowing` already makes for Ask and for the same reason: the
    /// transport goes with the transcript, and a player nobody can see is a
    /// player nobody can pause. It is the one thing the stacked layout could do
    /// that this cannot, and it is bought with a note as tall as the window.
    @objc private func switchTab(_ sender: NSSegmentedControl) {
        // A control swallows its own click, so it has to let the title field go
        // itself. Every control in this pane does the same.
        endEditing()
        // Before the note leaves the screen, never after.
        saveYours()
        let wanted: Tab
        switch sender.selectedSegment {
        case 1: wanted = .notes
        case 2: wanted = .chats
        default: wanted = .recording
        }
        guard wanted != tab else { return }
        tab = wanted
        if tab == .notes {
            stopPlayback()
            // Re-read on the way in rather than only on selection, so opening
            // the tab is also the gesture that picks up what an agent wrote.
            reloadNotes(reset: false)
        }
        // Same argument, one tab along: an answer streaming into the card at
        // the foot of this window rewrites `chat.json`, and the first exchange
        // is what gives a conversation its title at all, so arriving here is
        // the moment to look again.
        if tab == .chats {
            stopPlayback()
            reloadChats()
        }
        applyShowing()
        // After the hiding is done, because `findMatches` reads the note only
        // while it is on screen: the count and the highlights have to be for
        // the tab that is up now. It never scrolls, by construction.
        refreshFind()
    }

    @objc private func switchShowing(_ sender: NSSegmentedControl) {
        // A control swallows its own click, so it has to let the title field go
        // itself. Every control in this pane does the same.
        endEditing()
        saveYours()
        // One segment, so its selected state is the whole answer: on is Ask and
        // off is back to the page.
        showing = sender.isSelected(forSegment: 0) ? .ask : .page
        // A transport nobody can see is a transport nobody can pause, which is
        // the rule `enter(.settings)` already follows for the same reason.
        if showing == .ask { stopPlayback() }
        // Re-read on the way back rather than only on selection, so returning to
        // the page is also the gesture that refreshes the notes.
        if showing == .page { reloadNotes(reset: false) }
        // Same argument for Ask: the CLI can write to `chat.json` too, and
        // switching to the pane is the moment somebody expects to see it.
        if showing == .ask { askView.reload() }
        applyShowing()
        // Put the caret where somebody who just pressed Ask is about to type.
        if showing == .ask { askView.focusField() }
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
        showing = .page
        tab = .recording
        applyShowing()
    }

    func showNote(_ slug: String?) {
        showing = .page
        tab = .notes
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
        // The count on the tab, as it is typed: the first character written
        // into an empty note is what turns "Notes" into "Notes · 1", and it has
        // to happen before the 0.8s save or the tab is a second behind the
        // caret. `notes` has not been rewritten yet, so this reads the text
        // view rather than the list.
        updateTabLabels()
        // Nothing sizes the box any more: on a tab of its own the note is as
        // tall as the pane whatever is in it. See `notesBottom`.
        // Re-run rather than re-apply: a character typed at the top of the note
        // moves every range below it, so the ranges found before this keystroke
        // now point at the wrong words.
        refreshFind()
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
        // A conversation first, because both schemes arrive here and only one
        // of them is a recording id.
        if let id = ChatLink.id(link), let chat = Chat.load(id: id) {
            openChat(chat)
            return true
        }
        if let slug = NoteLink.id(link) {
            saveYours()
            showingNote = slug
            renderNote()
            showRelated()
            return true
        }
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
    /// Re-read the conversations about this meeting, for the tab and its count.
    ///
    /// Cheap enough to be unconditional: `Chat.about` is one listing of the
    /// conversation directory, filtered on a field, and it is asked once per
    /// selection rather than once per row of anything.
    private func reloadChats() {
        chatList.show(recording)
        updateTabLabels()
    }

    /// A conversation somewhere in the library has been written to or thrown
    /// away, so this meeting's list of them may be stale.
    ///
    /// The window calls it, because only the window hears about an answer
    /// landing in the card at the foot of this page. Deliberately unguarded by
    /// which tab is up: the count in the bar is the whole reason the tab is
    /// worth having, and a count that only refreshes once you are already
    /// looking at the list says nothing.
    func chatsChanged() { reloadChats() }

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

        let now = signature()
        guard now != notesSignature else { return }
        notesSignature = now
        rebuildNotePicker()
        renderNote()
        if !reset { applyShowing() }
    }

    /// What has to change for this pane to redraw its notes.
    ///
    /// **The tags are in here because `updated` deliberately does not move when
    /// they change.** `Notes.setTags` leaves the clock alone so that an agent
    /// tagging a note does not mark it hand-edited, which means a slug-and-date
    /// signature cannot see a tag land, and the pane sat showing the old ones
    /// until something else happened to it.
    private func signature() -> String {
        notes.map { "\($0.slug)|\($0.updated)|\($0.tags.joined(separator: "+"))" }
            .joined(separator: ",")
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
        // Before the storage is replaced, never after. A temporary attribute is
        // removed by naming the range it was put at, and every line below this
        // swaps the text under those ranges: run it afterwards and the removal
        // addresses characters that are not there any more.
        clearNoteMarks()
        defer { refreshFind() }
        guard let note = notes.first(where: { $0.slug == showingNote }) else {
            notesText.isEditable = false
            notesText.textStorage?.setAttributedString(NSAttributedString())
            noteInfo.textStorage?.setAttributedString(NSAttributedString())
            // No note being read, so no filing to show and nothing for the `＋`
            // to add to. `clear()` hides it, which is what keeps a lone button
            // off the heading of a recording with no notes at all.
            noteTagChips.clear()
            updatePlaceholder()
            return
        }
        setProvenance(of: note)
        noteTagChips.isHidden = false
        noteTagChips.configure(.note(note))

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
        updateTabLabels()
        notesText.scroll(NSPoint(x: 0, y: 0))
    }

    /// Open a conversation from a back link, in the pane that already draws
    /// conversations. This is what makes the link worth having: a meeting can
    /// tell you it has been asked about, and then show you what was said.
    private func openChat(_ chat: Chat) {
        saveYours()
        // **The window's composer, not this pane's.** `askView` here has been
        // dormant since the composer moved to the window, so opening a
        // conversation into it followed the link, loaded the turns and drew
        // them in a view nobody can see: a link that does nothing.
        onOpenChat?(chat)
    }

    /// How many segments the bar has, and how wide they are.
    ///
    /// **Rebuilt rather than hidden, because `NSSegmentedControl` cannot hide a
    /// segment.** Setting `segmentCount` is the only way to take one off, and
    /// it discards the labels and widths of the segments it keeps, so both are
    /// written again here every time. That also makes this the one place the
    /// widths are stated: `updateTabLabels` writes titles into segments this
    /// method has already decided exist, and a count written by a method that
    /// did not know Chats was gone would land on the wrong tab.
    ///
    /// Ask off takes the third one away for the reason `updateComposer` gives
    /// for taking the composer away: with the feature off there is no card at
    /// the foot of this window, so a tab whose empty state says "ask a question
    /// below" would be pointing at something that is not there.
    private func setTabs() {
        let wanted = Settings.askEnabled ? 3 : 2
        if tabPicker.segmentCount != wanted { tabPicker.segmentCount = wanted }
        tabPicker.setLabel("Recording", forSegment: 0)
        for segment in 0..<wanted { tabPicker.setWidth(104, forSegment: segment) }
    }

    /// Ask has been switched on or off in Settings.
    ///
    /// **The tab has to go, and so does anybody standing on it.** Settings is a
    /// mode of this window rather than a second window, so the toggle can be
    /// thrown with a meeting's Chats tab up behind it, and leaving somebody on
    /// a list of conversations they can no longer add to is the same fault
    /// `askEnabledChanged` already fixes for chat mode.
    func askEnabledChanged() {
        if !Settings.askEnabled, tab == .chats { tab = .recording }
        setTabs()
        applyShowing()
    }

    /// How many notes about this meeting have anything in them, on the tab.
    ///
    /// **The one thing tabs cost, bought back.** Stacked, a note was visible
    /// the moment the page opened; behind a tab it is not, so a meeting that
    /// has been written up and one that has not looked identical. The count is
    /// the smallest honest signal: it says there is something to read without
    /// claiming to say what.
    ///
    /// Empty notes do not count. Every recording is offered a note of its own
    /// whether or not one exists on disk, so counting the list would put
    /// "Notes · 1" on every meeting in the library and mean nothing anywhere.
    ///
    /// The note being typed into is counted from the text view rather than from
    /// `notes`, because the list is only rewritten 0.8 seconds after a
    /// keystroke and a tab that lags the caret by a second reads as broken.
    private func updateTabLabels() {
        var written = notes.filter {
            !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !($0.slug == showingNote && Notes.isYours($0))
        }.count
        if let note = notes.first(where: { $0.slug == showingNote }), Notes.isYours(note) {
            if !notesText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                written += 1
            }
        }
        tabPicker.setLabel(written > 0 ? "Notes · \(written)" : "Notes", forSegment: 1)
        // The same bargain as the note count, one tab along: a meeting that has
        // been asked about and one that has not are otherwise the same bar.
        // Read off the list rather than counted again, so the tab and the rows
        // it opens onto cannot disagree.
        guard tabPicker.segmentCount > 2 else { return }
        tabPicker.setLabel(chatList.count > 0 ? "Chats · \(chatList.count)" : "Chats",
                           forSegment: 2)
    }

    /// Everything else written about this recording, on one line.
    ///
    /// **The note area is yours and the switcher is gone.** A pop-up that
    /// silently swapped your own note for an agent's made the one editable
    /// document on the page indistinguishable from the read-only ones beside
    /// it, and it hid conversations entirely because they are not notes.
    ///
    /// So: the agent notes, named and reachable, in a line that collapses to
    /// nothing when there are none.
    ///
    /// **The conversations were here too, and that grouping was the mistake.**
    /// They were put together on the argument that both are somebody else's
    /// reading of this meeting, which is true and was not enough: a note opens
    /// in the box directly under this line and a conversation opens a card over
    /// the whole page, so the difference between two links that look identical
    /// was something you found out by pressing one. The conversations have a
    /// tab now, where a list can say when each one was had and how long it is.
    /// See `chatList`.
    /// "What's cooking, Maxime?", or without the name when there is none.
    ///
    /// The name is the one in Settings, which is also what the microphone track
    /// is displayed as. Nobody is asked for it twice, and a library where it was
    /// never set gets the question without a name rather than a placeholder
    /// standing in for one.
    /// The library's own conversations, newest first, as links.
    ///
    /// Five, because this is a landing screen and not an archive: older ones are
    /// reached through the meeting they were about, which is what the back links
    /// on a page are for.
    private func showRecentChats() {
        let chats = Chat.all()
            .filter { $0.sources.isEmpty && $0.person == nil }
            .prefix(5)
        guard !chats.isEmpty else {
            recentChats.isHidden = true
            return
        }
        recentChats.isHidden = false
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = 4
        let line = NSMutableAttributedString()
        for (index, chat) in chats.enumerated() {
            guard let id = chat.id else { continue }
            if index > 0 {
                line.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style,
                ]))
            }
            line.append(NSAttributedString(string: chat.displayTitle, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: Brand.accent,
                .paragraphStyle: style,
                .link: ChatLink.scheme + id,
            ]))
        }
        recentChats.textStorage?.setAttributedString(line)
        recentChats.invalidateIntrinsicContentSize()
    }

    private static func greetingText() -> String {
        guard let name = Settings.userName, !name.isEmpty else {
            return "What's cooking?"
        }
        return "What's cooking, \(name)?"
    }

    private func showRelated() {
        let others = notes.filter { !Notes.isYours($0) }
        let away = showingNote != nil && !showingYours
        // On the Notes tab only: it is the line that swaps the document
        // underneath it, so on the transcript it would be a row of links to a
        // pane that is not on screen.
        let show = showing == .page && tab == .notes
            && (!others.isEmpty || away)
        chatLinks.isHidden = !show
        chatLinksHeight.isActive = !show
        // The top is the column's, not this line's: see `chatLinksTop`. Only
        // the height collapses.
        chatLinksTop.constant = Self.underTabs
        guard show else { return }

        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let line = NSMutableAttributedString()
        func add(_ text: String, link: String?) {
            var attributes = plain
            if let link {
                attributes[.link] = link
                attributes[.foregroundColor] = Brand.accent
            }
            line.append(NSAttributedString(string: text, attributes: attributes))
        }

        // The way back, and only when somebody has gone somewhere. Reading an
        // agent's note over the top of your own with no route back was the
        // switcher's other failure.
        if away {
            add("Your notes",
                link: NoteLink.scheme + (recording.map { Notes.yoursSlug(for: $0.id) } ?? ""))
            add("   ", link: nil)
        }
        add("Also about this: ", link: nil)
        var first = true
        for note in others {
            if !first { add(", ", link: nil) }
            first = false
            add(note.title, link: NoteLink.scheme + note.slug)
        }
        chatLinks.textStorage?.setAttributedString(line)
        chatLinks.invalidateIntrinsicContentSize()
    }

    private func showProvenance() {
        noteInfo.isHidden = recording == nil || showing != .page
            || tab != .notes || noteInfo.string.isEmpty
        // Collapsed as well as hidden: a hidden view keeps its frame, which is
        // the trap the chips row and the player already record.
        noteInfoHeight.isActive = noteInfo.isHidden
        // 8 under the links when there are any, and nothing at all when there
        // are not: the gap under the tab bar is already spent above.
        noteInfoTop.constant = noteInfo.isHidden ? 0 : (chatLinks.isHidden ? 0 : 8)
    }

    /// An `NSTextView` has no placeholder, so this is a label behind one.
    ///
    /// Computed from the state rather than set where the text is, because the
    /// two do not change together: switching to the Notes tab does not
    /// re-render a note whose text has not changed, and the first version hid
    /// the prompt on the way past and never put it back.
    ///
    /// `recording == nil` is in the condition because this label is a sibling
    /// of the text view rather than a subview of it, so hiding the notes pane
    /// does not take it with them. Stopping a recording leaves the pane in
    /// Notes with nothing selected, and the prompt stayed on screen above
    /// "Select a recording.": an invitation to type into a note belonging to no
    /// meeting, over a sentence saying no meeting is open.
    private func updatePlaceholder() {
        notesPlaceholder.stringValue =
            "What you are thinking. Only you write this, and an agent can read it."
        notesPlaceholder.isHidden = recording == nil
            || showing != .page
            // A sibling of the text view rather than a subview of it, which is
            // the trap recorded below: taking the note off screen with the tab
            // leaves its invitation drawn over the transcript.
            || tab != .notes
            // With the note box itself away while the transcript is being made.
            // It is a sibling of that box rather than a child of it, which is
            // the trap this file records against the empty label, so hiding the
            // box left its invitation drawn over the progress picture. This runs
            // *after* `applyShowing` sets the rest of the page, so the rule has
            // to be here rather than there or it would be set and then undone.
            || isLoadingTranscript
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
    /// The meeting on screen is the job the queue is running now.
    ///
    /// The same test `updateEmpty` makes to put the transcription picture up
    /// (`showPicture`), named once because three other things on this page
    /// depend on it and the window depends on it too: nothing can be asked about
    /// a transcript that does not exist yet.
    ///
    /// Deliberately not "has no transcript". A recording whose audio is on
    /// another Mac has none either, and that is not a loading state: nothing is
    /// running, the page says so, and its note and its player belong on screen.
    var isLoadingTranscript: Bool {
        if previewingTranscription { return true }
        guard let recording else { return false }
        return Queue.shared.running == recording.id
    }

    private var currentActivity: CloudActivity? {
        if let previewActivity { return previewActivity }
        guard let recording else { return nil }
        if Queue.shared.running == recording.id {
            return CloudActivity(
                recordingID: recording.id, stage: .transcribing,
                fraction: Queue.shared.progress?.overall,
                detail: Queue.shared.progress?.message ?? "Starting transcription")
        }
        if Queue.shared.isQueued(recording.id) {
            return CloudActivity(recordingID: recording.id, stage: .queued)
        }
        if let cloud = CloudSyncHost.shared.activity(for: recording.id) {
            if cloud.stage == .ready, recording.hasTranscript { return nil }
            return cloud
        }
        if recording.effectiveState == .transcribing, !recording.transcribedHere {
            return CloudActivity(
                recordingID: recording.id, stage: .transcribingElsewhere,
                detail: "Transcribing on \(recording.transcriberName ?? "another Mac")")
        }
        if recording.effectiveState == .failed {
            return CloudActivity(recordingID: recording.id, stage: .failed)
        }
        if !recording.hasAudio, recording.metadata.source == "iphone" {
            return CloudActivity(
                recordingID: recording.id, stage: .waitingForMac,
                detail: "Waiting for audio from your iPhone")
        }
        return nil
    }

    private func updatePlayerActivity() {
        guard let activity = currentActivity else {
            activityBar.fraction = nil
            for view in [activityLabel, activityValue, activityBar] as [NSView] {
                view.isHidden = true
            }
            if !playerCard.isHidden { playerHeight.constant = 58 }
            return
        }

        // The reason beside the verb for the two states where the verb alone
        // sends somebody hunting: a retry that never seems to end, and a
        // failure. `detail` is a sentence thanks to `SyncTrouble`, so it can
        // stand on the page rather than hide in the tool tip. Everything else
        // keeps the short title: a percentage is its own explanation.
        let says: String
        if let why = activity.detail, !why.isEmpty,
           activity.stage == .retrying || activity.isFailure {
            says = "\(activity.title): \(why)"
        } else {
            says = activity.title
        }
        activityLabel.stringValue = says
        activityLabel.textColor = activity.isFailure ? .systemOrange : .secondaryLabelColor
        activityLabel.toolTip = activity.detail
        activityLabel.setAccessibilityLabel(says)
        activityValue.stringValue = activity.percentage ?? ""
        activityLabel.isHidden = false
        activityValue.isHidden = activity.percentage == nil

        let usesWaveform = activity.stage == .startingTranscription
            || activity.stage == .transcribing
            || activity.stage == .transcribingElsewhere
        if usesWaveform {
            // The transcript area already carries Listen's two-lane waveform
            // progress. Keep that visual language as the transcription meter
            // instead of drawing a second, generic line directly above it.
            activityBar.fraction = nil
            activityBar.isHidden = true
        } else if let fraction = activity.fraction {
            activityBar.isHidden = false
            activityBar.fraction = fraction
            activityBar.setAccessibilityValue(activity.percentage)
        } else if activity.isMoving {
            activityBar.isHidden = false
            activityBar.fraction = nil
            activityBar.setAccessibilityValue("In progress")
        } else {
            activityBar.fraction = nil
            activityBar.isHidden = true
        }
        if !playerCard.isHidden {
            playerHeight.constant = activityBar.isHidden ? 78 : 86
        }
    }

    /// `LISTEN_PANEL=transcribing:<fraction>` is showing the picture on a
    /// recording the queue is not actually running.
    ///
    /// Without this the preview drew the *old* page around the picture, player
    /// and note box included, which is a picture of a state the app is never in.
    /// The same reason `previewRecording` sets `showsComposer` by hand.
    private var previewingTranscription = false
    private var previewActivity: CloudActivity?

    private func applyShowing() {
        modePicker.setSelected(showing == .ask, forSegment: 0)
        updatePlayerActivity()
        // Collapsed while asking, and for a recording that is still running:
        // that one already says so in the transcript area, and it would be wrong
        // besides, since its audio is on *this* Mac and simply is not finished.
        // Everything else keeps the card, with or without a transport in it.
        setPlayer(hasAudio: hasAudio,
                  hidden: showing == .ask || recording?.isLive == true
                      || tab != .recording)
        // **Every piece of the page is gated on there being a page.** The
        // heading, the note and the transcript are furniture belonging to a
        // meeting, and with nothing selected the pane's whole content is one
        // centred sentence saying so. Without the `recording != nil` half, an
        // empty pane drew "Transcript" in the middle of it, over a note-shaped
        // hole holding the previous meeting's height. This is the same reason
        // `updatePlaceholder` tests `recording == nil`: these views are siblings
        // of the empty label rather than children of anything it hides.
        let page = showing == .page
        let open = page && recording != nil
        // **A meeting being transcribed is a loading state, and a loading state
        // has one thing on it.** The picture in the middle of the pane is what
        // this screen is about until the job finishes; a transport over audio
        // whose transcript does not exist yet, and a note box under a heading,
        // are two documents' worth of furniture around a progress bar. Measured
        // by looking at an hour-long call at 82%: three empty regions and the
        // one live thing in the middle of them.
        let readable = open && !isLoadingTranscript
        // **One tab at a time, and neither of them while there is no page.**
        // A meeting being transcribed is a loading state and a loading state has
        // one thing on it: the picture in the middle of the pane is what the
        // screen is about until the job finishes, and a tab bar over it would
        // be offering two documents that do not exist yet.
        let onNotes = readable && tab == .notes
        let onChats = readable && tab == .chats
        setModeBarCollapsed(!readable)
        tabPicker.isHidden = !readable
        switch tab {
        case .recording: tabPicker.selectedSegment = 0
        case .notes: tabPicker.selectedSegment = 1
        case .chats: tabPicker.selectedSegment = 2
        }
        updateTabLabels()
        scroll.isHidden = !open || tab != .recording
        notesScroll.isHidden = !onNotes
        chatList.isHidden = !onChats
        // **The note's filing, not the recording's, so it goes with the note.**
        // Pinned to the tab row, so a strip left behind would draw over the
        // tabs themselves rather than merely be wrong.
        //
        // Restored here as well as hidden, and this is the half that was
        // missing: the strip is filled by `renderNote`, which does not run on a
        // tab switch, because the note has not changed and only which tab is up
        // has. Hiding it on the way out and never putting it back left the note
        // on the Notes tab with no filing on it and no way to add any, on every
        // visit after the first. Visibility only, never content: `renderNote`
        // is still the one thing that says what is in it.
        noteTagChips.isHidden = !onNotes
            || !notes.contains { $0.slug == showingNote }
        askView.isHidden = page
        // The focus is about playing this transcript, so it goes with the
        // transcript. Leaving the bar up over Ask would be a sentence about a
        // player that is collapsed there anyway: switching to Ask already stops
        // playback. The Notes tab is the same argument, one tab in rather than
        // one mode over: the transcript it names is not on screen.
        if !page || tab != .recording { setFocus(nil) }
        // And the find bar with it, for the same reason: the three surfaces it
        // searches are the page's, and none of them is on screen in Ask. It
        // stays up across a tab switch, because the title and whichever
        // document is up are both still searchable and closing it would be the
        // pane deciding somebody had finished looking.
        if !page { closeFind() }
        showProvenance()
        showRelated()
        updatePlaceholder()
        // One note is still worth a switcher: it is also where the note's title
        // is written, and the pane would otherwise show a document with no name
        // on it.
        // Never. The line under the note carries the others now, and a control
        // that swapped the page's one editable document for a read-only one was
        // the thing that made "Your notes" feel like a filter rather than a
        // document.
        notePicker.isHidden = true
        updateEmpty()
        // Last, and from the one place the mode is ever applied, so the window
        // cannot be told about a mode this pane has not finished entering.
        onShowingChanged?()
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
        updatePlayerActivity()
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

    /// A cloud transfer can move without the queue moving. Update the compact
    /// player status and leave playback and the selected transcript untouched.
    func showActivity() {
        updatePlayerActivity()
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
    /// Open the pane on the Ask mode. `LISTEN_PANEL=ask`, and nothing else
    /// calls it.
    ///
    /// It exists for the state that has no agent to talk to, which is the one
    /// nobody can reach without uninstalling both CLIs first. Point the app at
    /// a scratch defaults domain whose `agentPath_claude` and `agentPath_codex`
    /// name files that do not exist, and the setup notice is on screen: an
    /// explicit path wins in `AgentCLI.locate` even when it is wrong, which is
    /// what makes "not installed" reproducible on a Mac that has both.
    func previewAsk() {
        showing = .ask
        askView.reload()
        applyShowing()
    }

    func previewTranscribing(_ fraction: Double) {
        showing = .page
        previewingTranscription = true
        if let id = recording?.id {
            previewActivity = CloudActivity(
                recordingID: id, stage: .transcribing, fraction: fraction,
                detail: fraction < 0.5 ? "Transcribing the other participants"
                                       : "Transcribing you")
        }
        applyShowing()
        transcribing.progress = TranscriptionProgress(
            message: fraction < 0.5 ? "transcribing the other participants"
                                    : "transcribing you",
            everyone: min(1, fraction * 2),
            you: max(0, fraction * 2 - 1))
        transcribing.isHidden = false
        empty.isHidden = true
        emptyIcon.isHidden = true
        greeting.isHidden = true
        recentChats.isHidden = true
        // As `updateEmpty` does. Without it the preview draws over whatever
        // transcript the chosen recording already has, which is not a state the
        // app can be in and would have somebody chasing a bug that is only in
        // the preview.
        scroll.isHidden = true
    }

    /// `LISTEN_PANEL=live`. Puts the recording screen up on the selected
    /// recording, which in a preview launch is not being captured at all, so the
    /// live branch in `updateEmpty` would never fire for it.
    func previewRecording(silent: Bool) {
        setModeBarCollapsed(true)
        // A preview points at a *finished* recording, which has audio and
        // therefore a player. A live one has neither, so leaving it up would be a
        // picture of a state the app is never in.
        setPlayerCollapsed(true)
        scroll.isHidden = true
        notesScroll.isHidden = true
        noteInfo.isHidden = true
        notesPlaceholder.isHidden = true
        askView.isHidden = true
        transcribing.isHidden = true
        transcribing.progress = nil
        empty.isHidden = true
        emptyIcon.isHidden = true
        if let recording { live.configure(recording) }
        live.isHidden = false
        live.preview(silent: silent)
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
        // The greeting and the library's conversations belong to the screen with
        // nothing open. They are siblings of the empty label rather than
        // children of anything that hides it, which is the trap this file
        // already records against `updatePlaceholder`, so arriving at a meeting
        // left them drawn over its page.
        greeting.isHidden = true
        recentChats.isHidden = true

        // While capture is running, the whole pane below the header is the
        // recording screen and the mode picker collapses.
        //
        // There is nothing to switch between yet: no transcript, nothing to ask
        // about, and the only document that can exist is the note somebody is
        // writing. Three tabs offering two empty documents and the sentence
        // "Recording. The transcript appears when you stop." was chrome charged
        // against the only minutes of a meeting that cannot be redone later.
        //
        // `begin` is idempotent, which it has to be: this runs again on every
        // capture change and every menu rebuild, and restarting the strips on
        // each one would wipe their history several times a second.
        if recording.isLive {
            live.configure(recording)
            live.begin()
            live.isHidden = false
            setModeBarCollapsed(true)
            // The pane below the header is `RecordingView`'s while this runs,
            // and there is no transcript to search: nothing is transcribed
            // until Stop. The same rule the composer already follows here.
            closeFind()
            scroll.isHidden = true
            notesScroll.isHidden = true
            noteInfo.isHidden = true
            notesPlaceholder.isHidden = true
            askView.isHidden = true
            transcribing.isHidden = true
            // Clearing the progress is what stops the timer inside it, the same
            // reason the non-live path below does it.
            transcribing.progress = nil
            empty.isHidden = true
            emptyIcon.isHidden = true
            return
        }
        // Ends the strips *and writes the note down*, so the transition from
        // recording to reading cannot drop what somebody typed in the last
        // seconds of the call. See `RecordingView.end`.
        live.end()
        live.isHidden = true

        var message: String
        var showPicture = false
        switch showing {
        case .page:
            // The transcript's message, not the note's. The note tab is never
            // empty, because the user's own is always offered and an empty one
            // is a cursor rather than a message: the placeholder inside the text
            // view says what it is for. So the only tab that can have nothing
            // to show is the dialogue, and this sentence is about that, which
            // is why it is silent while the other one is up.
            message = turns.isEmpty && tab == .recording
                ? Self.emptyTranscriptMessage(recording) : ""
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
        case .ask:
            // Same argument. An empty conversation is a field with starter
            // questions over it, and a sentence in the middle of the pane
            // would be a third thing saying what the other two already do.
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
        // And with the Notes tab, which is the other way it can be off screen.
        scroll.isHidden = showing != .page || showPicture || tab != .recording
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
        // Before the queue, because a recording another Mac took is one this
        // Mac's queue has already declined and would otherwise fall through to
        // a sentence about waiting for audio that is not coming.
        //
        // Named and timed, which is the whole point of the provenance fields:
        // "transcribing" on its own is indistinguishable from a run that died
        // hours ago on a machine nobody has opened since.
        if recording.effectiveState == .transcribing, !recording.transcribedHere,
           let who = recording.transcriberName {
            guard let started = recording.transcribeStarted else {
                return "Transcribing on \(who)."
            }
            return "Transcribing on \(who), started \(Recording.ago(started))."
        }
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
            // Named, when the container has named one. "This Mac transcribes
            // it once it arrives" is a promise about a claimed recording that
            // this Mac cannot keep and will never be asked to: the audio is on
            // the Mac that claimed it and stays there. Saying which one turns
            // a wait with nothing to do into a machine to go and open.
            if let holder = CloudSyncHost.audioHolder(of: recording.id) {
                return "The audio for this recording is on \(holder)."
                    + " The transcript appears here when that Mac has made it."
            }
            // Every device that is talking has let go of this one. Said as
            // what was reported rather than as what is true: a Mac shut in a
            // drawer still has whatever it had, and a library cannot tell that
            // apart from a disk that was wiped.
            if CloudSyncHost.nothingHolds(recording) {
                return "No device has reported keeping the audio for this recording."
                    + " Turn on Keep audio in Settings on a device that still has it."
            }
            // A phone recording is on its way *here*. Telling somebody to wait
            // for another Mac when this one is about to do the work sends them
            // looking at a machine that has nothing to say.
            if recording.metadata.source == "iphone" {
                return "The audio is coming from your iPhone."
                    + " This Mac transcribes it once it arrives."
            }
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
        // Which recording is on screen *now*, because two things below depend
        // on whether this is a different one or the same one again.
        let previous = self.recording?.id
        // Stop the player when the selection changes. Leaving one meeting
        // playing while reading another is never what anyone meant.
        stopPlayback()
        // Before `self.recording` moves, or a half-typed note is written to the
        // recording that arrives next.
        saveYours()
        // The same rule for the title, and the asymmetry cost a name: a note is
        // written on every keystroke and a title only when the field gives up
        // focus, so a title typed and left open belonged to nothing once the
        // pane moved on. `endEditingTitle` is a no-op unless the field is
        // actually being edited, and it commits against `self.recording`, which
        // is still the recording the name was typed for.
        if recording?.id != previous { endEditingTitle() }
        // A question about one transcript, so it does not travel to the next
        // one. The sidebar's lenses are the opposite and deliberately survive a
        // selection change: those narrow the library, and this is about the
        // meeting on screen.
        focused = nil
        waveform.focused = nil
        self.recording = recording
        updatePlayerActivity()

        guard let recording else {
            readingOrigin = .zero
            setChromeHidden(true)
            empty.isHidden = false
            greeting.stringValue = Self.greetingText()
            greeting.isHidden = false
            showRecentChats()
            let libraryIsEmpty = Recording.all().isEmpty && Capture.shared.current == nil
            // The character welcomes a new library. In a library that already
            // has recordings, it would only turn a simple selection prompt into
            // decoration and make the detail pane feel less calm.
            // The mascot now belongs to the greeting rather than to an empty
            // library, so it is here whenever the pane is.
            emptyIcon.isHidden = false
            // Selecting is no longer the only thing you can do here. With Ask
            // on, the composer under this sentence asks about the whole
            // library, so an instruction to go and pick something first is
            // untrue as well as unhelpful: this screen is a place you can
            // work from. With Ask off there is no composer to point at (see
            // `Settings.askEnabled`), so the second half offers the one other
            // thing this screen can do instead: start the next recording.
            empty.stringValue = libraryIsEmpty
                ? "No recordings yet. Press New Recording to capture your first meeting or voice memo."
                : Settings.askEnabled
                    ? "Select something from the list, or ask about your library below."
                    : "Select something from the list, or press New Recording to start your next meeting or voice memo."
            return
        }

        emptyIcon.isHidden = true

        // An unnamed recording shows the placeholder as a placeholder rather
        // than as its name, so clicking the title gives an empty field to type
        // into instead of a word to delete first.
        //
        // Never over an open edit of the same recording. `reload()` re-shows
        // whatever is selected on every capture change, every queue tick and
        // every activation, and each one used to put the stored title back into
        // a field somebody was typing in. Naming a recording while it ran was a
        // race against the next reload, and stopping it is itself a reload:
        // press Stop with the caret still in the field and the name went with
        // the redraw.
        if recording.id != previous || titleLabel.currentEditor() == nil {
            titleLabel.stringValue = recording.isUntitled ? "" : recording.metadata.title
        }
        // The display wording and never `Metadata.untitled`, which is a key
        // rather than a word. See `Recording.displayTitle`. Not `displayTitle`
        // itself, because this is the branch where the field is empty and the
        // placeholder is the only thing that can be shown.
        titleLabel.placeholderString = Metadata.untitledDisplay

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
        // The fifth fact: how long the transcription took, and which machine
        // did it when that was not this one. No gate on the library being
        // shared, which the first shape of this had: the duration is the same
        // fact on one Mac as on three, and it was the device name that was
        // noise on a single Mac rather than the whole line. See
        // `Recording.transcribedLine`.
        let provenance = recording.transcribedLine ?? ""
        let facts = [recording.when, recording.lengthText,
                     recording.appLabel ?? "",
                     stored.map { Recording.modelName($0.model) } ?? "",
                     provenance]
            .filter { !$0.isEmpty }.joined(separator: " · ")

        // The fifth fact, and the only one that is a warning. It goes on this
        // line rather than in a banner of its own because it is a fact about the
        // recording, which is what this line is for, and orange on the clause
        // alone is the rule the sidebar row already follows: a permanently
        // coloured line is decoration, one clause that turns orange is a state.
        //
        // It cannot be left to the transcript to imply. A meeting whose mic track
        // is silent transcribes into something that reads like an ordinary
        // one-sided conversation, and the recording this was written for was
        // filed as a 99%-one-speaker meeting with nothing anywhere disagreeing.
        if recording.micWasSilent {
            let font = subtitleLabel.font ?? .systemFont(ofSize: 11)
            let line = NSMutableAttributedString(
                string: facts.isEmpty ? "" : facts + " · ",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: font])
            line.append(NSAttributedString(
                string: "your microphone caught nothing",
                attributes: [.foregroundColor: NSColor.systemOrange, .font: font]))
            subtitleLabel.attributedStringValue = line
        } else {
            // Reset the colour as well as the text: a field that has held an
            // attributed string keeps nothing of its own styling, so selecting a
            // healthy recording after a silent one would otherwise inherit
            // whatever the last one was drawn with.
            subtitleLabel.stringValue = facts
            subtitleLabel.textColor = .secondaryLabelColor
        }

        // Who is in this recording and what it is about, on one line above the
        // player. Collapsed to nothing when there is neither, so a live or
        // untranscribed recording keeps the layout it had before this row
        // existed.
        chips.configure(recording)
        tagChips.configure(.recording(recording))
        setChipsCollapsed(chips.isEmpty && tagChips.isEmpty)

        turns = recording.storedTurns
        // The sentence spans come from `transcript.json`, which keeps one row
        // per ASR sentence, while the paragraphs come from `turns.json`. Both
        // files are written together and neither is derived here, so the
        // transcript on screen is still exactly the one the CLI and the MCP
        // server serve.
        sentences = Merge.sentences(in: turns, from: stored?.segments ?? [])
        // **Opening a recording opens at the top; re-showing the one already on
        // screen keeps the reader's place.** `show` is not only how a selection
        // is answered: a speaker edit goes through it because a rename changes
        // the title and the chips as well as the paragraphs, and the sidebar
        // reload that follows calls it again. Both of those used to throw away
        // an hour of scrolling, and the second one is why fixing it at the call
        // site did not work. See "A sidebar reload is not somebody choosing a
        // recording".
        // **Only when the recording actually changed.** `reload()` re-shows
        // whatever is selected on every activation, every queue tick and both
        // edges of capture, so closing the bar here unconditionally would shut
        // it under the reader several times a minute. The same test the three
        // lines around this one make, and for the same family of reasons.
        if recording.id != previous { closeFind() }
        renderTurns(scrollToTop: recording.id != previous)

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
        // **Following the playhead belongs to opening a recording**, the same
        // rule `scrollToTop` above follows and for the same reason. `show` is
        // also how a speaker edit reloads, and re-arming it there undid the
        // reader having scrolled away: the next playback tick found the turn
        // numbering had shifted under the edit, decided the playhead had entered
        // a new paragraph, and pulled the page to it. An hour of scrolling, lost
        // to correcting one sentence while the meeting played.
        if recording.id != previous {
            follows = true
            currentStart = nil
        }
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
        // Transcript, and this used to be Notes.
        //
        // The reasoning was that a live recording has no transcript for an hour,
        // so Notes was the only usable tab. `RecordingView` took that job over
        // and does it better, with the note and both meters on one screen and no
        // tabs at all, so the mode is no longer what somebody looks at *during*
        // the recording. It is what they are left on the instant it stops, and
        // stopping is a request to see what was said. Left as Notes, pressing
        // Stop landed on the page you had just finished typing on and hid the
        // transcript arriving behind a tab.
        // And on the transcript when it arrives, which is what Stop is asking
        // for. The tab otherwise survives a selection change, so a note left up
        // on the last meeting would hide the one being made from the person who
        // just finished making it.
        if recording.isLive { showing = .page; tab = .recording }
        // Before `reloadNotes`, which can put the mode back to the transcript.
        // The pane has to be pointed at the new recording either way: it stops
        // any answer still running for the last one and loads that one's
        // `chat.json`, and both have to happen whether or not Ask is up.
        askView.show(recording)
        reloadNotes(reset: true)
        // Always, and not only on the way into the tab: the count in the bar is
        // read off this list, so a meeting arriving with two conversations
        // behind it has to say so before anybody presses anything.
        reloadChats()
        // The tab bar is opened by `applyShowing` and by nothing else, so that
        // a pane with no two documents on it, one being transcribed or one being
        // recorded, cannot be left with a bar over it.
        applyShowing()
    }

    /// Room to leave on the right of the Ask pane's input row, for the record
    /// button that floats over this pane and belongs to the window.
    func setAskClearance(_ points: CGFloat) { askView.trailingClearance = points }

    /// True while the Ask pane is up, which is the one mode with a control of
    /// its own in the bottom right corner.
    var isAsking: Bool { showing == .ask }

    /// True while this pane is the recording screen, which is what the window
    /// takes the composer away for. `Recording.isLive` reads capture rather
    /// than a flag written when the screen was built, so it goes false the
    /// instant Stop is pressed, before anything reloads.
    var isShowingLive: Bool { recording?.isLive == true }

    /// Fired whenever the document on screen changes, so the window can decide
    /// again whether its floating button belongs over this pane.
    var onShowingChanged: (() -> Void)?

    private func setChromeHidden(_ hidden: Bool) {
        titleLabel.isHidden = hidden
        subtitleLabel.isHidden = hidden
        playerCard.isHidden = hidden
        scroll.isHidden = hidden
        notesScroll.isHidden = hidden
        askView.isHidden = hidden
        // **This list is the one that runs when nothing is selected**, because
        // `show(nil)` returns from here without reaching `applyShowing`. Anything
        // added to the page has to be added here too, and the section headings
        // this replaced were not: they drew the word "Transcript" halfway down
        // an otherwise empty pane, above "Select something from the list."
        // A tab bar there would be the same bug with two words instead of one.
        if hidden { setModeBarCollapsed(true) }
        // The list this comment is about, again. A find bar over "Select
        // something from the list" is a search of nothing, and its ticks would
        // outlive the recording that produced them.
        if hidden { closeFind() }
        // The list this comment is about. The strip lives on the tab bar's row,
        // so it has to go when the tabs do.
        if hidden { noteTagChips.clear() }
        chatLinks.isHidden = hidden
        if hidden {
            // Collapsed as well as hidden, spacing included, or the empty
            // sentence sits pushed down the pane by furniture nobody can see.
            chatLinksHeight.isActive = true
            chatLinksTop.constant = 0
        }
        // The list this comment is about, again. Added after the Chats tab
        // was, and missing here for exactly as long as that took to notice:
        // deselecting left it showing the previous recording's conversations,
        // pinned under the tab bar, over the home page's own greeting and
        // its own list of recent questions.
        chatList.isHidden = hidden
        if hidden { chatList.show(nil) }
        if hidden {
            // Deselecting while a meeting is being recorded is ordinary: the
            // recording carries on, so the note has to be written down and the
            // 60 Hz strips have to stop redrawing a view nobody can see.
            live.end()
            live.isHidden = true
            // A running answer belongs to the recording that is going away.
            askView.show(nil)
            // `clear` and not just the collapse: the strip would otherwise keep
            // the last recording's tags and its `＋` would offer to tag a
            // recording that is no longer selected.
            tagChips.clear()
            setChipsCollapsed(true)
            setModeBarCollapsed(true)
            // The two pieces of the notes pane that are not inside it. Both are
            // siblings of `notesScroll` rather than subviews, so hiding the
            // scroll view leaves them drawn: they have to be asked again, and
            // both now answer "nothing selected" first. This is the only route
            // that skips `applyShowing`, which is where they are otherwise
            // decided.
            updatePlaceholder()
            showProvenance()
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
        TagPopover.show(for: .recording(recording), from: self, rect: anchor) { [weak self] in
            self?.refreshTags()
        }
    }

    /// The add popover for the note being read.
    ///
    /// `saveYours()` before it opens, for the reason `editTags` calls
    /// `endEditing`: the user's own note is an editable text view on this page,
    /// tagging it reloads the drawer, and a reload that ran with an uncommitted
    /// caret in the box would take the last thing typed with it.
    private func editNoteTags(from view: NSView, rect: NSRect) {
        guard let note = notes.first(where: { $0.slug == showingNote }) else { return }
        let anchor = convert(rect, from: view)
        saveYours()
        TagPopover.show(for: .note(note), from: self, rect: anchor) { [weak self] in
            self?.refreshNoteTags()
        }
    }

    /// Redraw the note's strip, and only it.
    ///
    /// Not `reloadNotes`, which rebuilds the picker and re-renders the body: a
    /// note being read with a caret in it must not be rewritten from disk
    /// because a pill was clicked beside it.
    private func refreshNoteTags() {
        guard let slug = showingNote, let updated = Notes.find(slug) else { return }
        if let index = notes.firstIndex(where: { $0.slug == slug }) {
            notes[index] = updated
        }
        noteTagChips.isHidden = false
        noteTagChips.configure(.note(updated))
        // The signature has the tags in it, so the next `reloadNotes` would
        // redraw for a change this has already drawn. Restamping keeps that
        // from throwing away a caret the user still has in the box.
        notesSignature = signature()
        LibraryWindow.shared.reload()
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
        tagChips.configure(.recording(updated))
        setChipsCollapsed(chips.isEmpty && tagChips.isEmpty)
        LibraryWindow.shared.reload()
    }

    private func renderTurns(scrollToTop: Bool = true) {
        // Taken before the stack is emptied, because emptying it is what makes
        // the clip view forget. See `readingOrigin`.
        let keeping = scrollToTop ? nil : readingOrigin
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        turnViews = []
        editingTurn = nil
        for (index, turn) in turns.enumerated() {
            let view = TurnView(turn: turn,
                                sentences: index < sentences.count ? sentences[index] : [])
            view.onSeek = { [weak self] sentence in
                self?.endEditing()
                // Playing from a sentence is playing the meeting from there, so
                // it takes the playhead off one speaker's turns.
                self?.playingFocused = false
                // The sentence that was clicked, falling back to the turn for a
                // click that landed between sentences or on an imported
                // transcript whose segments could not be located in their turn.
                self?.seek(to: sentence?.start ?? turn.start, playing: true)
            }
            view.onSpeakerMenu = { [weak self] anchor, rect in
                self?.turnMenu(turn, anchor: anchor, rect: rect)
            }
            // The words and who said them, corrected from one menu. They are the
            // same repair at two depths, and having one on the paragraph and the
            // other only on the pill above it makes the reader hunt for the half
            // they want.
            view.onSentenceSpeaker = { [weak self] anchor, rect, sentences in
                guard let self else { return nil }
                let paragraph = turn.text as NSString
                let wanted = sentences
                    .filter { $0.range.location != NSNotFound
                        && NSMaxRange($0.range) <= paragraph.length }
                    .map { (index: $0.index, text: paragraph.substring(with: $0.range)) }
                guard !wanted.isEmpty else { return nil }
                // The count is in the words, because the reader is about to
                // hand some of a paragraph to somebody else and the one thing
                // they cannot check afterwards is how much of it went.
                let many = wanted.count > 1
                return self.reassignItem(
                    many ? "Speaker for These \(wanted.count) Sentences"
                         : "Speaker for This Sentence",
                    scope: .sentences(wanted), from: turn.speaker,
                    asking: many ? "Who said these \(wanted.count) sentences?"
                                 : "Who said this sentence?",
                    anchor: anchor, rect: rect)
            }
            view.onSentenceDelete = { [weak self] sentences in
                guard let self else { return nil }
                let paragraph = turn.text as NSString
                let wanted = sentences
                    .filter { $0.range.location != NSNotFound
                        && NSMaxRange($0.range) <= paragraph.length }
                    .map { (index: $0.index, text: paragraph.substring(with: $0.range)) }
                guard !wanted.isEmpty else { return nil }
                // No confirmation, and the words are why. This removes exactly
                // what is selected on screen, under a verb that says Delete, on
                // a gesture the reader made deliberately; `.discard` asks
                // because it removes a speaker's whole side of a meeting and
                // there is no way to see how much that is. Naming the count is
                // what this owes the reader instead.
                return Action(wanted.count > 1
                              ? "Delete \(wanted.count) Sentences" : "Delete Sentence",
                              "trash") { [weak self] in
                    self?.deleteSentences(wanted)
                }
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
                                        constant: -Self.transcriptSides).isActive = true
            turnViews.append(view)
        }

        // Room at the end: the plain reading margin `RecordButton.clearance` is,
        // plus whatever the composer drawer is covering, which is `drawerCover`.
        //
        // A spacer in the stack and not `scroll.contentInsets`, which is what
        // the note beside this has to use, for two reasons. Setting
        // `contentInsets` turns `automaticallyAdjustsContentInsets` off, taking
        // the *top* inset with it, and this scroll view's top is measured
        // against nothing that would report the change. And a bottom content
        // inset shortens the scroller by the same amount, because the scroller
        // is laid out inside the content area: see `setBottomInset`. A view at
        // the end of the document moves only the end of the document.
        let tail = NSView()
        tail.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(tail)
        let height = tail.heightAnchor.constraint(
            equalToConstant: RecordButton.clearance + drawerCover)
        tailHeight = height
        NSLayoutConstraint.activate([
            height,
            tail.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -Self.transcriptSides),
        ])

        // Every `TurnView` on the page is new, so the find highlights they were
        // carrying went with the old ones. One call here covers every rebuild
        // there is, because this is the only builder.
        refreshFind()

        // Not after an edit. A reload that jumps to the top of an hour-long
        // meeting loses the reader's place every time they correct a word.
        // Nothing to put back on the first render of a recording, and nothing
        // to put back when the reader has not read anything yet.
        guard let keeping else {
            readingOrigin = .zero
            scrollTranscriptToTop()
            return
        }
        restoreTranscriptScroll(to: keeping)
    }

    /// Put the reader back where they were before a rebuild.
    ///
    /// Deferred for the same reason `scrollTranscriptToTop` is: the turns are
    /// added to the stack in the pass that calls this, so the document is still
    /// the wrong height here and a scroll measured against it lands somewhere
    /// else.
    ///
    /// Clamped, because an edit can make the transcript shorter than the offset
    /// it was read at. `.discard` removes paragraphs, and a stale offset past the
    /// new end is a blank pane with a scroller that says there is something above
    /// it.
    ///
    /// **A number of points, and not the paragraph the reader was on.** An
    /// anchor was written and measured and thrown away, and the measurement is
    /// the reason to record it. It is the better idea in principle, because an
    /// offset is only the reader's place while nothing above them changes; it is
    /// worse in this view, on two counts that cost 214 points on the first edit
    /// tried. The transcript stack is a plain `NSStackView`, so it is
    /// **unflipped**: the first paragraph has the *largest* `frame.minY`, and a
    /// scan for "the last one starting above the viewport" walks the document
    /// backwards. And the second reload of a pass reads those frames before
    /// layout has run, when every one of them is still zero, so the anchor is
    /// whichever paragraph the loop happens to end on. Both are silent.
    ///
    /// What made the idea worth having was a pull rewriting the transcript under
    /// the reader, and that is now impossible: see `SyncState`, where a sidecar
    /// edit this device has not sent is no longer overwritten. What is left that
    /// changes the document above the reader is `.discard`, which is rare,
    /// deliberate and confirmed.
    private func restoreTranscriptScroll(to origin: NSPoint) {
        DispatchQueue.main.async { [self] in
            stack.layoutSubtreeIfNeeded()
            let visible = scroll.contentView.bounds.height
            let document = scroll.documentView?.bounds.height ?? 0
            let limit = max(0, document - visible)
            scrollingProgrammatically = true
            let put = NSPoint(x: origin.x, y: min(max(0, origin.y), limit))
            // Written back, because the clamp can have moved it and the next
            // rebuild has to agree with what is on screen rather than with what
            // was asked for.
            readingOrigin = put
            scroll.contentView.scroll(to: put)
            scroll.reflectScrolledClipView(scroll.contentView)
            DispatchQueue.main.async { self.scrollingProgrammatically = false }
        }
    }

    /// Open at the beginning.
    ///
    /// A freshly selected recording used to open somewhere near the end of the
    /// meeting with half a paragraph cut off above it, which reads as a
    /// rendering fault rather than as a scroll position.
    ///
    /// **The clip view's origin, not a point in the stack.** The clip view is
    /// flipped, so the top of the document is `y = 0` and stays `y = 0` however
    /// tall the document turns out to be. It used to scroll the stack's own
    /// `bounds.maxY - 1` into view, which is the top only while the stack's
    /// height is final: an unflipped view's top edge *is* its height, so every
    /// point in it moves when that height changes, and this runs one pass after
    /// the turns are added, with their heights still to be solved against their
    /// width.
    ///
    /// It was right for as long as the first layout pass happened to be the last
    /// one. Adding a spacer at the end of the transcript for the composer to
    /// cover gave it a second reason to grow, and a 2 hour meeting opened 66%
    /// and 82% down on two runs out of three, at the point the stale height put
    /// under the caret. The shipped build opened at the top on three runs out of
    /// three, which is what a race looks like from the outside: right until
    /// something else on the same pass takes slightly longer.
    ///
    /// Still deferred, because the turns are added to the stack in the pass that
    /// calls this, and a scroll before they exist has nothing to scroll.
    private func scrollTranscriptToTop() {
        DispatchQueue.main.async { [self] in
            scrollingProgrammatically = true
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
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
        if let track = recording.tracks.first { return track }
        // The master, for a Mac that never had the tracks. Played as it is
        // rather than mixed down: it is already one file, it is stereo with
        // the microphone on the left and the room on the right, and building
        // a mono sum of it would cost an encode to lose the separation the
        // format exists to keep. See `AudioMaster`.
        if FileManager.default.fileExists(atPath: recording.masterURL.path) {
            return recording.masterURL
        }
        return nil
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

    /// The pane's own play button, which always means the meeting.
    ///
    /// Separate from `togglePlay` because that is also how everything else in
    /// here starts playback, `playFocused` included, and this press is the one
    /// that has to say "not one person".
    @objc private func playPressed() {
        playingFocused = false
        togglePlay()
    }

    private func togglePlay() {
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
            // While somebody is focused, start inside one of their turns rather
            // than wherever the playhead was left. `updatePlayhead` would jump
            // there on its first tick anyway, and a press that plays a twentieth
            // of a second of the wrong person first is a press that sounds
            // broken.
            switch self.focusStep(at: player.currentTime) {
            case .carryOn:
                break
            case .jump(let time):
                player.currentTime = time
            case .finished:
                // Past their last turn, so start again at their first, which is
                // the focused reading of the finished-recording rule above.
                if let first = self.focusTurns.first { player.currentTime = first.start }
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
        // Dragging through the meeting is a way of reading the meeting, so the
        // playhead stops skipping to one person's turns from here on.
        playingFocused = false
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

        // While somebody is focused, playback runs through their turns and skips
        // what is between them. Announced on the bar above the transcript rather
        // than left to be discovered, because this is the only place in the app
        // where play does not play what comes next.
        if player.isPlaying {
            switch focusStep(at: position) {
            case .carryOn:
                break
            case .jump(let time):
                // `seek` refreshes on the way through, so there is nothing left
                // to do on this tick.
                seek(to: time, playing: true)
                return
            case .finished:
                // Stop at the end of the last thing they said rather than
                // playing the rest of the meeting under a bar that says play is
                // running through one person.
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
        let index = speakingTurn(at: position)
        let start = index.flatMap { $0 < turns.count ? turns[$0].start : nil }
        if index != currentTurn {
            trace("playhead \(TranscriptFormat.stamp(position)) -> "
                  + (index.map { "turn \($0) \(turns[$0].speaker)" } ?? "nobody"))
            if let old = currentTurn, old < turnViews.count {
                turnViews[old].isCurrent = false
                turnViews[old].highlight(nil)
            }
            currentTurn = index
            if let index, index < turnViews.count {
                turnViews[index].isCurrent = true
                // **Only when the playhead has entered a different paragraph,
                // and a paragraph is which one it is rather than where it sits
                // in the list.**
                //
                // Every edit renumbers the turns: reassigning one sentence
                // splits its paragraph in three, so every index after it moves
                // by two. Compared by index, the playhead had "arrived
                // somewhere" on the next tick after any edit, and the page was
                // dragged to it. The reader was somewhere else, looking at the
                // sentence they had just corrected, and an hour of scrolling
                // went with it.
                //
                // It only ever happened while something was playing, which is
                // what made it look intermittent, and **a drag across a
                // paragraph starts playback**: selecting text begins with a
                // click, and a click on a paragraph seeks and plays. So it
                // happened to exactly the gesture the sentence menu is opened
                // with, and to no other.
                if start != currentStart { reveal(index) }
            }
            currentStart = start
        }
        if let currentTurn, currentTurn < turnViews.count {
            turnViews[currentTurn].highlight(position)
        }
    }

    /// Which paragraph is being spoken at `time`.
    ///
    /// **Not the first one that spans it**, which is what this replaced and what
    /// made clicking a line highlight the line above it. Turns overlap, because
    /// people talk over each other and the two tracks are clustered separately:
    /// on the call this was reported from, 55 of 105 turns start before the
    /// previous one ends. `turns` is ordered by start, so the first turn spanning
    /// an instant is the *earliest* one still running, and clicking the first
    /// sentence of a turn highlighted a different paragraph in **59 of its 105
    /// turns**. Measured on that transcript, both numbers.
    ///
    /// Two rules, in order:
    ///
    /// 1. **A sentence beats a span.** A turn runs from its first sentence's
    ///    start to its last one's end and includes the silences between them; a
    ///    sentence is somebody actually talking. So a turn with a sentence over
    ///    this instant wins against one that merely surrounds it.
    /// 2. **The most recently begun wins.** Where two turns are genuinely
    ///    sounding at once, which is real in a meeting, the one that started
    ///    talking last is the one a listener hears as current.
    ///
    /// Linear over `turns` rather than short-circuiting, and that is affordable:
    /// the inner sentence scan runs only for the handful of turns that span the
    /// instant, and the rest is a pair of comparisons per turn.
    private func speakingTurn(at time: TimeInterval) -> Int? {
        var best: Int?
        var rank = (0, -Double.greatestFiniteMagnitude)
        for (index, turn) in turns.enumerated() {
            guard time >= turn.start, time < turn.end else { continue }
            let covering = index < sentences.count
                ? sentences[index].first { time >= $0.start && time < $0.end }?.start
                : nil
            let candidate = (covering != nil ? 1 : 0, covering ?? turn.start)
            if best == nil || candidate > rank {
                rank = candidate
                best = index
            }
        }
        return best
    }

    /// Scroll the turn being spoken into view, if the reader has not gone
    /// somewhere else.
    ///
    /// The `follows` gate is the playhead's and stays here. The mechanism under
    /// it is `bring`, because a find step is a deliberate navigation and must
    /// happen whether or not the reader is following the audio.
    private func reveal(_ index: Int) {
        guard follows else { return }
        bring(index)
    }

    /// Scroll a turn into view, whoever asked.
    ///
    /// `within` narrows the target to a range inside the paragraph. A turn is
    /// one person's uninterrupted stretch and can run for minutes, so a
    /// paragraph taller than the viewport lands on one of its edges and a match
    /// in the middle of it ends up off screen after a step that reported
    /// success.
    private func bring(_ index: Int, within range: NSRange? = nil,
                       atTop: Bool = false) {
        guard index < turnViews.count else { return }
        let view = turnViews[index]
        var frame = view.frame
        // **Nothing to scroll to before layout has run.**
        //
        // `renderTurns` empties the stack and fills it again in one pass, and
        // every frame in it is zero until the layout that follows. `refresh`
        // runs in that same pass, from both reloads, and clears `currentTurn`
        // first, so it always asks for a reveal there. On a zero frame
        // `scrollToVisible` is asked for `(0, -50, 0, 100)`, and the transcript
        // stack is an unflipped `NSStackView`, so y = 0 is the **bottom** of the
        // document: an hour-long meeting jumps to its last paragraph.
        //
        // A safety net rather than the fix for anything reported: what made the
        // transcript scroll away after an edit was being asked to reveal at all,
        // which `refresh(revealing:)` is about. This is here because scrolling
        // to a view that has no layout cannot be right whatever asked for it.
        guard frame.height > 0 else { return }
        // Converted rather than added: the stack is unflipped, so hand
        // arithmetic on y is the thing this whole comment is about.
        if let range, let inside = view.rect(of: range) {
            frame = view.convert(inside, to: stack)
        }
        guard !scroll.documentVisibleRect.contains(frame) else { return }
        scrollingProgrammatically = true
        defer { DispatchQueue.main.async { self.scrollingProgrammatically = false } }

        // **`scrollToVisible` scrolls the least it can, and the least it can put
        // a find match flush against the bottom edge of the window.**
        //
        // That is right for the playhead, which is following along and should
        // move the page as little as possible. It is wrong for a jump somebody
        // asked for: measured on a 41-minute call, opening on match 1 left the
        // matched paragraph on the last line of the viewport with the eight
        // turns before it filling the screen above, so the page looked like it
        // had not moved at all.
        //
        // The stack is **unflipped**, so the top of the viewport is the frame's
        // `maxY`, not its `minY`. Getting that backwards scrolls a whole
        // window's height the wrong way, which is the same trap `reveal`
        // records about a zero frame.
        guard atTop else {
            stack.scrollToVisible(frame.insetBy(dx: 0, dy: -50))
            return
        }
        // **Two coordinate systems, and they run opposite ways.** The stack is
        // unflipped, so a turn's frame counts up from the bottom of the
        // document and turn 0 has the *highest* y. `TopAlignedClipView` is
        // flipped, so what `scroll(to:)` wants counts down from the top. The
        // distance from the document's top to this frame's top edge is
        // therefore `document - frame.maxY`, and using the frame's y directly
        // scrolls most of a meeting the wrong way: measured on a 41-minute
        // call, opening on the match at 15:51 landed the page at 21:14, six
        // minutes past it, with the match off the top of the screen.
        let visible = scroll.contentView.bounds.height
        let document = stack.bounds.height
        let fromTop = document - frame.maxY
        let y = min(max(0, fromTop - Self.findLead), max(0, document - visible))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        // `lead` is how far below the top of the viewport the match landed, and
        // it is the whole assertion: the arithmetic above went the wrong way
        // once and every visible symptom of it was "the page did not move",
        // which a screenshot shows and no AX tree can. `verify_search.sh` reads
        // this line. Clamped at the two ends of the document, so it is only
        // `findLead` in the middle of one.
        trace("find scroll turn=\(index) fromTop=\(Int(fromTop)) "
            + "to=\(Int(y)) lead=\(Int(fromTop - y))")
    }

    /// Air above a match the find bar has jumped to.
    ///
    /// Not zero: a paragraph hard against the top edge reads as the top of the
    /// document rather than as a result, and the turn before it is usually the
    /// question the match is the answer to.
    private static let findLead: CGFloat = 60

    // MARK: - Find in page

    /// True while the bar is up, which the window asks before stepping.
    var isFinding: Bool { !findBar.isHidden }

    /// Open the bar, or focus it if it is already open.
    ///
    /// Cmd-F with the bar up selects everything in the field rather than
    /// closing it, which is what every other Mac app does.
    func openFind() {
        guard recording != nil else { NSSound.beep(); return }
        if findBar.isHidden {
            findBar.isHidden = false
            findTop.constant = 8
            findHeight.constant = FindBar.height
            // **Searching is the reader saying they are reading.** The same
            // rule `applyEdit` makes: once somebody is working on the page, the
            // playhead stops dragging it around. Closing does not put this
            // back, and that asymmetry is deliberate: `follows` is re-armed
            // only by opening a different recording, and re-arming it here
            // would pull the page away the moment the bar went down.
            follows = false
        }
        findBar.focus()
    }

    /// Take the bar down and every highlight with it.
    func closeFind() {
        finding = ""
        found = []
        foundAt = nil
        applyFind()
        findBar.setQuery("")
        findBar.report(nil, of: 0)
        guard !findBar.isHidden else { return }
        findBar.isHidden = true
        findTop.constant = 0
        findHeight.constant = 0
        // The field keeps first responder otherwise, and the next keystroke
        // goes into a bar nobody can see.
        // `nil`, not `self`: an `NSView` does not accept first responder by
        // default, so aiming it here fails quietly and leaves the caret in a
        // field nobody can see any more.
        if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
    }

    private func findQueryChanged(_ text: String) {
        let began = DEBUG ? Date() : nil
        finding = text
        found = findMatches(for: text)
        foundAt = found.isEmpty ? nil : 0
        applyFind()
        findBar.report(foundAt, of: found.count)
        if let foundAt { scrollToMatch(found[foundAt]) }
        if let began {
            trace("find \"\(text)\" \(found.count) matches over \(turns.count) turns "
                + "in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        }
    }

    /// Escape closes the bar, and otherwise means what it meant before.
    ///
    /// The split view controller's `cancelOperation` is deliberately last in the
    /// responder chain, *"so anything that wants Escape for itself gets it
    /// first"*. This wants it, and only while the bar is up: calling `super`
    /// otherwise leaves that arrangement exactly as it was. The bar's own field
    /// takes the key ahead of this whenever it holds the caret, through
    /// `doCommandBy`.
    override func cancelOperation(_ sender: Any?) {
        guard isFinding else { super.cancelOperation(sender); return }
        closeFind()
    }

    func findNext() { stepFind(1) }
    func findPrevious() { stepFind(-1) }

    /// Open the bar on a query somebody has already typed somewhere else.
    ///
    /// The route from a search result in the sidebar: the click already said
    /// which word, so the page opens knowing it rather than making the reader
    /// type it a second time into a bar they have to find first.
    ///
    /// Deferred, because this runs in the same pass as `show`'s `renderTurns`
    /// and every frame in the stack is still zero: scrolling now lands on the
    /// last paragraph of the meeting. See `bring`.
    func find(_ query: String) {
        guard recording != nil, !query.trimmingCharacters(in: .whitespaces).isEmpty
        else { return }
        showTranscript()
        openFind()
        findBar.setQuery(query)
        DispatchQueue.main.async { [self] in
            stack.layoutSubtreeIfNeeded()
            findQueryChanged(query)
        }
    }

    private func stepFind(_ by: Int) {
        guard !found.isEmpty else { NSSound.beep(); return }
        // Wrapping silently at both ends. A find bar that stops at the last
        // match is one you have to know the length of.
        let next = ((foundAt ?? 0) + by + found.count) % found.count
        foundAt = next
        applyFind()
        findBar.report(next, of: found.count)
        scrollToMatch(found[next])
    }

    /// Rebuild the list for what is on the page now, keeping the reader's place.
    ///
    /// Called by everything that changes any of the three documents, and it
    /// **never scrolls**: it runs at the end of `renderTurns`, in the same pass
    /// the stack was filled, where every frame is still zero and the stack is
    /// unflipped. That is the whole class of "scrolled into the last paragraph
    /// of an hour-long meeting", refused by construction.
    private func refreshFind() {
        guard !finding.isEmpty else { return }
        // The address, not the index. An edit renumbers every turn after it,
        // which is the same distinction `currentStart` records against
        // `currentTurn`.
        let was = foundAt.flatMap { $0 < found.count ? found[$0].place : nil }
        found = findMatches(for: finding)
        if let was, let again = found.firstIndex(where: { $0.place == was }) {
            foundAt = again
        } else if found.isEmpty {
            foundAt = nil
        } else {
            foundAt = min(foundAt ?? 0, found.count - 1)
        }
        applyFind()
        findBar.report(foundAt, of: found.count)
    }

    /// Every match on the page, in reading order.
    private func findMatches(for query: String) -> [FindMatch] {
        let wanted = query.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return [] }
        var out: [FindMatch] = []

        // The title first, because it is the top of the page. `stringValue`
        // rather than `displayTitle`: the placeholder is a word on screen and a
        // key on disk, and an untitled recording has an empty field here, so
        // the list can offer a recording for the word "untitled" that the page
        // then honestly cannot find.
        for range in Find.ranges(of: wanted, in: titleLabel.stringValue) {
            out.append(FindMatch(place: .title(range)))
        }

        // Then the note on screen, and only that one. The others are links in
        // `chatLinks` rather than documents on this page, so this is the whole
        // page rather than a cut of it, and it is also the safe reading:
        // `showNote` does not flush the pending save, so stepping into a note
        // that is not up would be the first caller that had not saved, and the
        // 0.8s timer behind it is guarded by `showingYours` and would drop the
        // keystrokes without a word.
        if !notesScroll.isHidden, let slug = showingNote {
            for range in Find.ranges(of: wanted, in: notesText.string) {
                out.append(FindMatch(place: .note(slug: slug, range)))
            }
        }

        // Then the paragraphs, in order.
        for (index, turn) in turns.enumerated() {
            for range in Find.ranges(of: wanted, in: turn.text) {
                out.append(FindMatch(place: .turn(index: index, range),
                                     time: time(of: range, in: index) ?? turn.start))
            }
        }
        return out
    }

    /// When a match in a turn is spoken, for the waveform's ticks.
    ///
    /// The sentence containing it, falling back to the turn's own start.
    /// A fallback rather than a skip: `Merge.sentences` drops segments it
    /// cannot locate in the turn text, and a match that lands in one of those
    /// gaps still happened and still deserves a mark.
    private func time(of range: NSRange, in index: Int) -> TimeInterval? {
        guard index < sentences.count else { return nil }
        return sentences[index].first { NSIntersectionRange($0.range, range).length > 0 }?.start
    }

    /// Push the current list onto all three surfaces.
    private func applyFind() {
        let current = foundAt.flatMap { $0 < found.count ? found[$0] : nil }

        // The title.
        var titleRanges: [NSRange] = []
        var titleCurrent: NSRange?
        // The note.
        var noteRanges: [NSRange] = []
        var noteCurrent: NSRange?
        // The paragraphs, gathered per turn so each view is written once.
        var byTurn: [Int: [NSRange]] = [:]
        var turnCurrent: (Int, NSRange)?

        for match in found {
            switch match.place {
            case .title(let range): titleRanges.append(range)
            case .note(_, let range): noteRanges.append(range)
            case .turn(let index, let range): byTurn[index, default: []].append(range)
            }
        }
        switch current?.place {
        case .title(let range): titleCurrent = range
        case .note(_, let range): noteCurrent = range
        case .turn(let index, let range): turnCurrent = (index, range)
        case nil: break
        }

        renderTitle(marking: titleRanges, current: titleCurrent)
        markNote(noteRanges, current: noteCurrent)
        for (index, view) in turnViews.enumerated() {
            let ranges = byTurn[index] ?? []
            view.setFind(ranges, current: turnCurrent?.0 == index ? turnCurrent?.1 : nil)
        }

        // Only the transcript is on the clock, which is why `FindMatch.time` is
        // optional. Cleared with everything else, or the previous query's ticks
        // outlive it: `loadWaveform` resets `peaks` and `spans` and would never
        // know about these.
        waveform.marks = found.compactMap(\.time)
        waveform.mark = current?.time
    }

    /// Mark the query in the title, or put the plain title back.
    ///
    /// **An attributed string brings its own truncation, which is none.**
    /// `lineBreakMode = .byTruncatingTail` is set on the field in `build` and is
    /// lost the instant an attributed value goes in without a paragraph style
    /// carrying it, so a long meeting name stops truncating and re-lays the
    /// whole header out. It is carried here by hand.
    ///
    /// Nothing at all while the field is being edited: the field editor owns
    /// the text then, and writing to it moves the caret to the end.
    private func renderTitle(marking ranges: [NSRange], current: NSRange?) {
        guard titleLabel.currentEditor() == nil else { return }
        let text = titleLabel.stringValue
        guard !ranges.isEmpty else {
            // Assigning `stringValue` is what takes an attributed value off, and
            // it must not run on every pass: it would fight the branch in `show`
            // that leaves an open edit alone.
            if titleLabel.attributedStringValue.length > 0,
               titleLabel.attributedStringValue.string == text,
               titleLabel.attributedStringValue.attribute(
                   .backgroundColor, at: 0, effectiveRange: nil) != nil {
                titleLabel.stringValue = text
            }
            return
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let marked = NSMutableAttributedString(string: text, attributes: [
            .font: titleLabel.font ?? NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        let length = marked.length
        for range in ranges where NSMaxRange(range) <= length {
            marked.addAttribute(.backgroundColor,
                                value: NSColor.systemYellow.withAlphaComponent(0.35),
                                range: range)
        }
        if let current, NSMaxRange(current) <= length {
            marked.addAttribute(.backgroundColor, value: NSColor.systemOrange,
                                range: current)
            marked.addAttribute(.foregroundColor, value: NSColor.black, range: current)
        }
        titleLabel.attributedStringValue = marked
    }

    /// Highlight ranges in the note, through the layout manager.
    ///
    /// **Temporary attributes, never an edit to the storage.** The storage is
    /// what the user is typing into, and an edit
    /// under a caret is an undo event that merges with `typingAttributes`, so
    /// the next character typed would inherit the highlight. `LinkLine` records
    /// the same decision for the same reasons.
    private func markNote(_ ranges: [NSRange], current: NSRange?) {
        guard let layout = notesText.layoutManager else { return }
        let length = (notesText.string as NSString).length
        for range in noteHighlighted where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        noteHighlighted = []
        for range in ranges where NSMaxRange(range) <= length {
            let isCurrent = range == current
            layout.addTemporaryAttributes(
                isCurrent
                    ? [.backgroundColor: NSColor.systemOrange,
                       .foregroundColor: NSColor.black]
                    : [.backgroundColor: NSColor.systemYellow.withAlphaComponent(0.35)],
                forCharacterRange: range)
            noteHighlighted.append(range)
        }
    }

    /// Take the note's highlights off before its storage is replaced.
    ///
    /// Before, not after: `LinkLine.set` records that a range into text that
    /// has already been swapped addresses nothing, so the attributes are never
    /// removed and the next pass measures against a length that has moved.
    private func clearNoteMarks() {
        guard let layout = notesText.layoutManager else { return }
        let length = (notesText.string as NSString).length
        for range in noteHighlighted where NSMaxRange(range) <= length {
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        noteHighlighted = []
    }

    /// Scroll to a match, on whichever surface it is.
    private func scrollToMatch(_ match: FindMatch) {
        switch match.place {
        case .title:
            // The title never scrolls; it is pinned to the top of the pane.
            break
        case .note(_, let range):
            notesText.scrollRangeToVisible(range)
        case .turn(let index, let range):
            bring(index, within: range, atTop: true)
        }
    }

    @objc private func userScrolled() {
        // Where the transcript is, for the next rebuild to put back. Every
        // bounds change and not only the ones a hand made, because the playhead
        // scrolls this too and a reload after that has to land where the reader
        // is actually looking.
        //
        // **Except while the document is shorter than the clip view**, which is
        // the one bounds change that must not be believed: `renderTurns` removes
        // every turn before it adds them again, and a clip view clamps its
        // origin to zero for that pass. Believing it is how the remembered place
        // became the top a moment after being restored to.
        if let document = scroll.documentView,
           document.bounds.height > scroll.contentView.bounds.height {
            readingOrigin = scroll.contentView.bounds.origin
        }
        guard !scrollingProgrammatically else { return }
        follows = false
    }

    func stopPlayback() {
        tick?.invalidate()
        tick = nil
        player?.stop()
        player = nil
        playingFocused = false
        position = 0
        currentTurn = nil
        currentStart = nil
        waveform.progress = 0
        setPlaying(false)
    }

    // MARK: - Asking about one speaker

    /// This speaker's turns, in order.
    private var focusTurns: [Turn] {
        guard let focused else { return [] }
        return turns.filter { $0.speaker == focused }
    }

    /// Mark one speaker as the one being asked about, or nobody.
    ///
    /// **All this changes on screen is the waveform**, which draws their bars in
    /// their own colour and greys the rest. Nothing moves, nothing is hidden,
    /// and no paragraph changes place: a click on a name must not shift the page
    /// it was asked from.
    ///
    /// The argument is checked against the transcript rather than trusted: a
    /// stale menu or a picker left open across a rename can name somebody who is
    /// no longer in it, and the popover's Play would then run to the end of the
    /// meeting finding nothing of theirs.
    func setFocus(_ label: String?) {
        let next = label.flatMap { wanted in
            turns.contains { $0.speaker == wanted } ? wanted : nil
        }
        guard next != focused else { return }
        focused = next
        waveform.focused = next
        // Their turns are no longer what is playing, whoever is focused now.
        playingFocused = false
    }

    /// Mark a speaker for as long as a popover is asking about them, and hand
    /// back the closure that puts it right.
    ///
    /// Both chip kinds go through here so there is one rule rather than two that
    /// agree today. See `focusToken` for why the undo is guarded.
    private func focusWhile(_ speaker: String) -> () -> Void {
        focusToken += 1
        let token = focusToken
        setFocus(speaker)
        return { [weak self] in
            guard let self, self.focusToken == token else { return }
            self.setFocus(nil)
        }
    }

    /// What playback should do next while the popover's Play is running.
    private enum FocusStep {
        /// Inside one of their turns, or nobody is focused.
        case carryOn
        /// Between two of them: go here.
        case jump(TimeInterval)
        /// Past the last thing they said.
        case finished
    }

    /// **`playingFocused` is the whole gate.** Skipping the rest of the meeting
    /// is what the popover's Play button says it does, so that press is the only
    /// one allowed to do it. Every other way to start playback is the meeting,
    /// and a player that jumped for those would be jumping with nothing on
    /// screen saying why, which is how you stop trusting one.
    private func focusStep(at time: TimeInterval) -> FocusStep {
        guard playingFocused, let focused else { return .carryOn }
        if turns.contains(where: {
            $0.speaker == focused && time >= $0.start && time < $0.end
        }) { return .carryOn }
        if let next = turns.first(where: { $0.speaker == focused && $0.start > time }) {
            return .jump(next.start)
        }
        return .finished
    }

    /// Play everything the focused speaker said, in order, one turn after the
    /// next.
    ///
    /// **From their first turn, not their longest.** Starting at the longest
    /// gives the best single voice sample soonest, which is what identifying
    /// somebody wants, and it was the first thing this did. It is still the
    /// wrong rule: `focusStep` only ever moves forward, so starting in the middle
    /// means the turns before it can never be reached and pressing play twice
    /// gives two different halves of the same person. One press plays all of
    /// them, from the beginning, which is the only behaviour that needs no
    /// explaining.
    ///
    /// No offset into the turn either, for the same reason: the jumps between
    /// turns land on `start`, so an offset here would make the first snippet the
    /// one clipped differently from the rest.
    func playFocused() {
        guard let first = focusTurns.first else { return }
        follows = true
        // Before the seek, not after: `seek` starts playback through
        // `togglePlay`, which asks `focusStep` where to begin, and a flag set
        // afterwards would let the first tick run as ordinary playback.
        playingFocused = true
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
    private func editSpeaker(_ speaker: String, from view: NSView, rect: NSRect,
                             turn: TurnChoice? = nil) {
        guard let recording else { return }
        let anchor = convert(rect, from: view)
        endEditing()
        let refresh: () -> Void = { [weak self] in self?.reloadAfterSpeakerChange() }
        // **Asking about somebody points the player at them, and leaves the
        // transcript alone.** Opening the popover makes play run through their
        // turns in order and picks their bars out of the waveform; closing it,
        // by dismissing or by applying a name, puts playback back. So the rule
        // has exactly one lifetime and it is one the user is already holding in
        // their hand, which is why there is no control anywhere for turning it
        // off: the popover in front of them is the off switch.
        //
        // What this used to do as well was hide every paragraph that was not
        // theirs, and that is the complaint it earned. Clicking a name to find
        // out who somebody is is a question, not a filter, and answering it by
        // taking the meeting off the screen reads as the app having mislaid the
        // transcript. Nothing was gained by it that the waveform does not show
        // without moving a word.
        //
        // Both kinds of chip, because this is one rule and two implementations
        // of it would be two rules by the next change. The named side gets no
        // play button of its own: the pane's own play already runs through their
        // turns while the card is up, which is what the bar says.
        let restore = focusWhile(speaker)
        if VoiceBank.isPlaceholder(speaker) {
            SpeakerPicker.show(
                for: recording, speaker: speaker, from: self, rect: anchor,
                // The paragraph this was opened over, when it was opened over
                // one. Naming a placeholder from its pill is still nearly always
                // about the whole speaker, and the checkbox says so; what it adds
                // is the other size, in the one place the reader can see which
                // paragraph it means.
                turn: turn,
                preview: SpeakerPreview(
                    play: { [weak self] in self?.playFocused() },
                    pause: { [weak self] in self?.pausePlayback() },
                    isPlaying: { [weak self] in self?.isPlaying ?? false },
                    end: restore),
                done: refresh)
        } else {
            PersonPopover.show(speaker, from: self, rect: anchor,
                               closed: restore, done: refresh)
        }
    }

    /// Somebody's identity changed, which changes the whole page.
    ///
    /// `show` rather than the targeted reload below, because a rename, a merge
    /// or a discard changes who is in this recording: the chips, the title
    /// derived from the people in it, and the sidebar row all have to be asked
    /// again. It costs the playhead, which is the trade the chips row has always
    /// made here.
    private func reloadAfterSpeakerChange() {
        guard let id = recording?.id, let updated = Recording.find(id) else { return }
        // The reader's place survives it: `show` renders at the top only for a
        // recording that was not already on screen. See `readingOrigin`.
        show(updated)
        LibraryWindow.shared.reload()
    }

    // MARK: - Who said this

    /// Everything that applies to a speaker, from the pill above their
    /// paragraph.
    ///
    /// The pill had no menu at all until the transcript could correct who said
    /// something, which left the chip under the title carrying verbs the pill
    /// standing for the same person did not. `PersonPopover.menu` is called
    /// rather than copied so the two can never come apart.
    ///
    /// **The two sizes are one item now.** This menu used to carry both "Not
    /// Nick…", which renames every turn Nick has, and "Speaker for This Turn ▸",
    /// which moves one paragraph, sitting one above the other with nothing on
    /// either saying that was the difference. Reported as confusing, and then
    /// reported again from the other end, as a name made on one turn that had
    /// gone by the time its author looked back. Both go through the picker now,
    /// and the size is a checkbox in it that counts what it is about to change:
    /// see `TurnChoice`.
    ///
    /// Built when the menu opens rather than when the turn is drawn. An hour of
    /// meeting is hundreds of turns, and a menu apiece, held for the life of the
    /// pane, to be opened on perhaps one of them.
    private func turnMenu(_ turn: Turn, anchor: NSView, rect: NSRect) -> NSMenu? {
        guard let recording else { return nil }
        let choice = TurnChoice(noun: "turn") { [weak self] label in
            // No reload: the picker closes on the next line and closing is what
            // runs `reloadAfterSpeakerChange`, which is also what keeps the
            // reader's place. See `reassign(reload:)`.
            self?.reassign(.turn(start: turn.start, end: turn.end),
                           from: turn.speaker, to: label, reload: false)
        }
        let menu = PersonPopover.menu(
            for: turn.speaker, in: recording,
            // The pane, not the pill, and the rect converted when the popover
            // asks for it rather than now: opening one of these can rebuild the
            // transcript first, and a positioning view that has left the window
            // aborts the app. Same rule as `editSpeaker`, for the same reason.
            anchor: { [weak self, weak anchor] in
                guard let self, let anchor, anchor.window != nil else { return nil }
                return (self, self.convert(rect, from: anchor))
            },
            // The first item does what clicking the pill used to do, because
            // clicking the pill is now how this menu is opened. See
            // `PersonPopover.menu(open:)`: without it, the shortest path from a
            // transcript to naming a voice would be the alert the picker was
            // built to replace.
            open: { [weak self] view, rect in
                self?.editSpeaker(turn.speaker, from: view, rect: rect, turn: choice)
            },
            // "Not Nick…", carrying the paragraph it was opened over. The picker
            // is the same one the chips row opens; the checkbox is what only a
            // transcript can offer, because only here is there one turn in mind.
            identify: { [weak self] view, rect in
                guard let self, let recording = self.recording else { return }
                SpeakerPicker.show(for: recording, speaker: turn.speaker,
                                   from: view, rect: rect, turn: choice) {
                    [weak self] in self?.reloadAfterSpeakerChange()
                }
            },
            done: { [weak self] in self?.reloadAfterSpeakerChange() })
        return menu
    }

    /// The submenu that hands some words to somebody else.
    ///
    /// **Everybody already in this recording is one click.** The mistake this
    /// fixes is nearly always the diarizer giving one person's sentence to
    /// another person who is also in the room, so the answer is almost always
    /// two names away and should not cost a dialog. Anybody else is one click
    /// further, through the same picker that names a speaker, because "which of
    /// the people I know is this" is a question this app already answers with
    /// the voice bank, the invitation and the roster, and answering it twice is
    /// how one of the two stops being kept up.
    ///
    /// The speaker it is attributed to now is in the list, ticked and doing
    /// nothing. A menu of names with the current one missing makes the reader
    /// work out which one is absent to find out where they are.
    private func reassignItem(_ title: String, scope: TranscriptEditor.Scope,
                              from speaker: String, asking: String,
                              anchor: NSView, rect: NSRect) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        // Stated rather than left to AppKit: with `autoenablesItems` on, an item
        // is enabled by whether its target answers, and the ticked one has no
        // action precisely because it is not a choice.
        submenu.autoenablesItems = false
        for label in recording?.speakers ?? [] {
            guard label != speaker else {
                let current = NSMenuItem(title: SpeakerName.display(label),
                                         action: nil, keyEquivalent: "")
                current.state = .on
                current.isEnabled = false
                submenu.addItem(current)
                continue
            }
            let entry = Action(SpeakerName.display(label), nil) { [weak self] in
                self?.reassign(scope, from: speaker, to: label)
            }
            entry.image = Self.dot(for: label)
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(Action("Someone Else…", "person.crop.circle.badge.plus") {
            [weak self, weak anchor] in
            guard let self, let recording = self.recording else { return }
            // The pill's rect while it is still in the window, or the pane's own
            // top corner once it is not. A menu item can be chosen after
            // something else has rebuilt the transcript, and a popover pointed
            // at a view that has left the window aborts rather than failing.
            let at = anchor.map { self.convert(rect, from: $0) }
                ?? NSRect(x: 24, y: self.bounds.midY, width: 1, height: 1)
            SpeakerPicker.choose(for: recording, speaker: speaker, asking: asking,
                                 from: self, rect: at) { [weak self] label in
                self?.reassign(scope, from: speaker, to: label)
            }
        })
        item.submenu = submenu
        return item
    }

    /// A speaker's colour, as something a menu item can carry.
    ///
    /// A menu cannot hold a view, so the disc the rest of the app uses is a
    /// filled circle here. Nil for a placeholder, which is colourless
    /// everywhere: see `SpeakerColour.tint`.
    private static func dot(for label: String) -> NSImage? {
        guard let colour = SpeakerColour.tint(for: label) else { return nil }
        return NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            colour.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }

    /// Hand one sentence, or one paragraph, to the person who actually said it.
    ///
    /// Not a destructive edit and deliberately not confirmed: the words and the
    /// audio are untouched, both speakers are still in the transcript, and the
    /// way back is the same menu on the paragraph it just moved to. What would
    /// need a confirmation is a question this cannot ask usefully, since the
    /// only way to see whether it was right is to look at the result.
    /// `reload` is false for the one caller that is about to reload anyway.
    ///
    /// The picker calls this and then closes, and closing is what runs
    /// `reloadAfterSpeakerChange`. Reloading here as well rebuilt the transcript
    /// twice for one edit, and the second rebuild read the reader's place out of
    /// a clip view the first had just emptied, so it was zero: the pane kept its
    /// place and then jumped to the top a moment later.
    private func reassign(_ scope: TranscriptEditor.Scope, from speaker: String,
                          to target: String, reload: Bool = true) {
        guard let recording else { return }
        endEditing()
        guard TranscriptEditor.apply(.reassign(scope, from: speaker, to: target),
                                     to: recording) else {
            // Refused: the transcript moved under the pane between the menu
            // being built and an item in it being chosen. Said out loud rather
            // than dropped, for the reason `applyEdit` gives.
            NSSound.beep()
            log("that has changed since the pane was drawn; nothing was written.")
            return
        }
        if reload { reloadTranscript() }
    }

    /// Take some sentences out of the transcript.
    ///
    /// The paragraph closes over the gap, which is what `Merge.turns` does with
    /// whatever is left; if the sentences were the whole paragraph, the
    /// paragraph goes, and if they were the last of a speaker, the speaker goes
    /// with them and `TranscriptEditor` drops their voiceprint.
    private func deleteSentences(_ wanted: [(index: Int, text: String)]) {
        guard let recording else { return }
        endEditing()
        guard TranscriptEditor.apply(.remove(wanted), to: recording) else {
            NSSound.beep()
            log("that has changed since the pane was drawn; nothing was written.")
            return
        }
        reloadTranscript()
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
                ? "an emptied field is not a deletion. Right-click the sentence "
                  + "and choose Delete Sentence."
                : "that sentence has changed since the pane was drawn; nothing was written.")
            return
        }
        reloadTranscript()
    }

    /// Re-read the transcript and redraw it, keeping the playhead.
    ///
    /// **A targeted reload, not `show`.** `show` stops playback and puts the
    /// playhead back to zero, and both edits that come through here, correcting
    /// a word and correcting who said it, are things people do while listening.
    ///
    /// The chips are asked again as well as the turns, because a reassignment
    /// can be the last thing a speaker said: the row under the title is a view
    /// over who is in the transcript, and one that kept a name the transcript no
    /// longer has would offer a card for somebody who is not in the meeting.
    private func reloadTranscript() {
        guard let recording, let updated = Recording.find(recording.id) else { return }
        self.recording = updated
        turns = updated.storedTurns
        sentences = Merge.sentences(in: turns,
                                    from: updated.storedTranscript?.segments ?? [])
        currentTurn = nil
        // **Correcting the transcript stops the playhead dragging the page
        // about, and does not stop the audio.**
        //
        // The two go together and only one of them is obvious. `show` is the
        // other reload and it stops playback outright, so nothing follows
        // anything afterwards; this one deliberately keeps playing, because
        // correcting a word is something people do while listening, and that
        // left `follows` armed with the reader no longer where the playhead is.
        //
        // Armed by what, is the part worth writing down: **a drag across a
        // paragraph starts playback.** Selecting text begins with a click, and a
        // click on a paragraph seeks and plays. So the gesture that opens the
        // sentence menu is the gesture that turns following on, and a second or
        // two after the edit the playhead crossed into the next paragraph and
        // took the page with it. Reported twice as the transcript scrolling
        // away, and only ever from the sentence menu, which is why it looked
        // intermittent.
        //
        // Editing is the reader saying they are reading. `reveal` already had
        // the rule, in the words "if the reader has not gone somewhere else".
        follows = false
        chips.configure(updated)
        setChipsCollapsed(chips.isEmpty && tagChips.isEmpty)
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
    /// The submenu that changes who said the selected sentences, built when the
    /// menu opens so it lists the speakers the recording has now.
    var speakerItem: (([Merge.Sentence]) -> NSMenuItem?)?
    /// Take the selected sentences out of the transcript.
    var deleteItem: (([Merge.Sentence]) -> NSMenuItem?)?

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
        guard let body = delegate as? TranscriptBody else { return standard }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard let sentence = body.sentence(at: index) else { return standard }

        // **A selection is the reader saying which words they mean.**
        //
        // Selecting the second half of a paragraph and asking who said it used
        // to move the sentence under the pointer and leave the rest of the
        // selection with the old speaker, silently. Reported, and the report is
        // the whole argument: a menu opened over a selection is about the
        // selection.
        //
        // Only when the click is inside it, which is what every other item in
        // this menu does. A right-click somewhere else is a new place, not a
        // second opinion about the old one.
        let selected = selectedRange()
        let inside = selected.length > 0
            && (NSLocationInRange(index, selected) || index == NSMaxRange(selected))
        let touched = inside
            ? body.sentences.filter { NSIntersectionRange($0.range, selected).length > 0 }
            : []
        let chosen = touched.isEmpty ? [sentence] : touched

        let menu = standard ?? NSMenu()
        let item = NSMenuItem(title: "Edit Sentence",
                              action: #selector(editSentence), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        var next = 1
        // Under Edit Sentence, because they are the same repair: the model got
        // the words wrong, or the diarizer got the person wrong, and a reader
        // who has just noticed one is looking in this menu for the other.
        //
        // Edit Sentence stays on the one under the pointer whatever is
        // selected: there is one field, and editing four paragraphs' worth of
        // sentences in it is not an operation.
        if let speaker = body.speakerItem?(chosen) {
            menu.insertItem(speaker, at: next)
            next += 1
        }
        // Under both, because it is the third thing that can be wrong with a
        // sentence and the rarest: the words are right, the speaker is right,
        // and the sentence should not be there at all.
        if let delete = body.deleteItem?(chosen) {
            menu.insertItem(delete, at: next)
            next += 1
        }
        menu.insertItem(.separator(), at: next)
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

/// The field one sentence is corrected in.
///
/// A subclass because an editable `NSTextField` does not grow to the text it
/// holds. `wraps` makes the words wrap, and all of them are in the field
/// editor, but the field's own height comes from `intrinsicContentSize`, which
/// measures one line unless the field is told how wide the text may run. So a
/// sentence longer than the pane opened as a single line with the rest scrolled
/// out of sight, and the only way to read what you were correcting was to
/// arrow through it.
///
/// The width is not known when the field is built, because the stack hands it
/// out, so `preferredMaxLayoutWidth` is kept level with the bounds here and the
/// height is measured again on every keystroke: the wrapped line count changes
/// as somebody types.
@MainActor
final class SentenceField: NSTextField {
    override func layout() {
        // Before `super`, so the height this pass reports is the one for the
        // width this pass was given.
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }

    override var intrinsicContentSize: NSSize {
        let width = preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : bounds.width
        guard width > 0, let measure = cell?.copy() as? NSTextFieldCell else {
            return super.intrinsicContentSize
        }
        // A copy of the cell, given the editor's text: while a field editor is
        // up the cell still holds the string editing began with, so measuring
        // the cell itself would leave the field at the height the sentence had
        // before a word was typed into it. The copy carries the font, the bezel
        // and `wraps`, so what comes back includes the insets.
        measure.stringValue = (currentEditor() as? NSTextView)?.string ?? stringValue
        let box = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: ceil(measure.cellSize(forBounds: box).height))
    }

    override func textDidChange(_ note: Notification) {
        super.textDidChange(note)
        invalidateIntrinsicContentSize()
    }
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
    /// The pill was clicked, either button: everything that applies to this
    /// speaker, and to this paragraph. Asked for when the menu opens, never
    /// before: a meeting is hundreds of turns and this is a menu apiece.
    var onSpeakerMenu: ((NSView, NSRect) -> NSMenu?)?
    /// Some sentences in this turn were right-clicked, and this is the item that
    /// changes who said them. A list because a selection is what the reader
    /// means; one entry is the case where they selected nothing.
    var onSentenceSpeaker: ((NSView, NSRect, [Merge.Sentence]) -> NSMenuItem?)?
    /// The item that removes them from the transcript.
    var onSentenceDelete: (([Merge.Sentence]) -> NSMenuItem?)?
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

    /// This turn's find matches, pushed down by the pane.
    ///
    /// Held rather than written onto the label, because `highlight` rebuilds
    /// the whole string from `base` whenever the playhead enters a different
    /// sentence. A background colour written straight onto `bodyLabel` survives
    /// until the next such tick and no longer, which reads as a highlight that
    /// works except sometimes.
    private var findRanges: [NSRange] = []
    /// Which of them the find bar is sitting on, when it is in this turn.
    private var findCurrent: NSRange?

    /// The find bar's matches in this turn, and which one is current.
    ///
    /// The equality guard is what makes a blanket loop over every turn on the
    /// page affordable: comparing two small arrays two hundred times costs
    /// nothing, and re-assigning two hundred `attributedStringValue`s
    /// invalidates two hundred intrinsic sizes and re-lays the whole stack out.
    ///
    /// **Measured, because the fear was a coalescing timer would be needed and
    /// it is not.** `LISTEN_DEBUG=1` times the whole pass; on the longest
    /// transcript to hand, 156 turns, the worst query anybody can type is one
    /// character:
    ///
    ///     find "e"     2546 matches over 156 turns in 2 ms
    ///     find "th"     700 matches over 156 turns in 1 ms
    ///     find "the"    385 matches over 156 turns in 0 ms
    ///
    /// So no debounce and no two-character minimum: both would be latency added
    /// to hide two milliseconds. That is the synchronous half; the layout the
    /// changed labels ask for happens on the next pass and was not visible.
    func setFind(_ ranges: [NSRange], current: NSRange?) {
        guard ranges != findRanges || current != findCurrent else { return }
        findRanges = ranges
        findCurrent = current
        render()
    }

    /// Where a range sits inside this paragraph, in the view's own coordinates.
    ///
    /// A layout manager built here over `base` at the label's width. Not exact:
    /// `report` records a hand-built one disagreeing with AppKit on 341 of 1026
    /// sampled points, because it cannot see the cell's insets. That mattered
    /// there, where the answer decided which character had been clicked. Here
    /// it is a scroll target and being a line out is invisible.
    ///
    /// nil before layout has run, which is what makes the caller fall back to
    /// the whole paragraph rather than scroll somewhere wrong.
    func rect(of range: NSRange) -> NSRect? {
        let width = bodyLabel.bounds.width
        guard width > 1, NSMaxRange(range) <= base.length else { return nil }
        let storage = NSTextStorage(attributedString: base)
        let container = NSTextContainer(
            size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range,
                                       actualCharacterRange: nil)
        let box = layout.boundingRect(forGlyphRange: glyphs, in: container)
        // A layout manager measures from the top down. An `NSTextField` is not
        // a flipped view, so the box has to be turned over inside the label
        // before it means anything to anybody else.
        let inLabel = bodyLabel.isFlipped
            ? box
            : NSRect(x: box.minX, y: bodyLabel.bounds.height - box.maxY,
                     width: box.width, height: box.height)
        return bodyLabel.convert(inLabel, to: self)
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
        render()
    }

    /// **The only place `bodyLabel`'s string is written**, so the playhead and
    /// the find bar cannot each undo the other.
    ///
    /// They used to be one function, and adding a second writer was not an
    /// option: this rebuilds from `base` and assigns wholesale, so whatever it
    /// was not told about is gone. The playhead goes on first and the find
    /// ranges over it, because a match inside the sentence being spoken is
    /// still a match and is the one the reader asked for.
    ///
    /// Yellow rather than a third alpha of the accent. The page already spends
    /// that colour twice on one paragraph, 0.07 for the turn and 0.30 for the
    /// sentence, and the comment above `isCurrent` is about keeping those two
    /// apart; a third shade would be a third thing to tell apart at a glance.
    /// Black on the current match is fixed rather than `labelColor` for
    /// `Brand.onAccent`'s reason: the fill does not change between appearances,
    /// so the ink on it must not either.
    private func render() {
        guard editing == nil else { return }
        let text = NSMutableAttributedString(attributedString: base)
        if let highlighted {
            text.addAttribute(.backgroundColor,
                              value: Brand.accent.withAlphaComponent(0.30),
                              range: sentences[highlighted].range)
        }
        let length = text.length
        for range in findRanges where NSMaxRange(range) <= length {
            text.addAttribute(.backgroundColor,
                              value: NSColor.systemYellow.withAlphaComponent(0.35),
                              range: range)
        }
        if let findCurrent, NSMaxRange(findCurrent) <= length {
            text.addAttribute(.backgroundColor, value: NSColor.systemOrange,
                              range: findCurrent)
            text.addAttribute(.foregroundColor, value: NSColor.black,
                              range: findCurrent)
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
        // What the first item of the menu will say, since that is what a click
        // is for; the rest of it is the same either way.
        speakerButton.toolTip = (VoiceBank.isPlaceholder(turn.speaker)
            ? "Name this speaker" : "Open their card")
            + ", or hand this turn to somebody else."
        // Empty, and filled by `menuNeedsUpdate` the moment it opens. An
        // `NSMenu` with a delegate is how AppKit builds a menu late; assigning a
        // built one here would build hundreds of them for a meeting, on a pane
        // that is rebuilt on every correction.
        let menu = NSMenu()
        menu.delegate = self
        speakerButton.menu = menu

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
        bodyLabel.speakerItem = { [weak self] sentences in
            guard let self else { return nil }
            return self.onSentenceSpeaker?(self, self.speakerButton.frame, sentences)
        }
        bodyLabel.deleteItem = { [weak self] sentences in
            guard let self else { return nil }
            return self.onSentenceDelete?(sentences)
        }

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 6

        for v in [speakerButton, timeLabel, body] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            speakerButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            // 8 and not 6: the pill's own padding used to hold the name clear of
            // this edge, and without it the name has to line up with the
            // paragraph under it or the turn reads as two indents.
            speakerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            timeLabel.centerYAnchor.constraint(equalTo: speakerButton.centerYAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: speakerButton.trailingAnchor,
                                               constant: 8),
            body.topAnchor.constraint(equalTo: speakerButton.bottomAnchor, constant: 1),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            // 4 rather than 8. This is half of the gap to the next speaker's
            // name and the stack's spacing is the other half, so it was being
            // paid twice.
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        fill(with: [bodyLabel])

        // No click gesture recogniser: `TranscriptBody.mouseDown` does this,
        // because only it runs late enough to have a field editor to ask which
        // word was under the pointer.
        bodyLabel.onClick = { [weak self] sentence in self?.onSeek?(sentence) }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// **Both buttons open the same menu.** A left click used to go straight to
    /// the popover about that speaker, which put the two questions a reader has
    /// about a name on different buttons: who is this, on the left, and who
    /// really said this, on the right. Nobody finds the second one that way, and
    /// a name in a transcript is exactly where the doubt about it appears.
    ///
    /// Nothing is lost by the extra click. The first item of the menu is the
    /// popover the click used to open, so the old gesture is now click, click.
    ///
    /// Positioned like `SpeakerChips.showOverflow`, so the two places a speaker
    /// menu drops from behave the same.
    @objc private func speakerTapped() {
        guard let menu = speakerButton.menu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: speakerButton.bounds.height + 4),
                   in: speakerButton)
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

        let field = SentenceField(string: whole.substring(with: sentence.range))
        field.font = .systemFont(ofSize: 13)
        field.delegate = self
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        // The body has been laid out for as long as the paragraph has been on
        // screen, so its width is the one the field is about to be given. Said
        // here as well as in `layout` so the field opens at the height of the
        // whole sentence rather than appearing as one line and growing a pass
        // later.
        field.preferredMaxLayoutWidth = body.bounds.width
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
        // But the find highlight has no tick to wait for. Without this, a turn
        // whose sentence was just edited comes back with its matches missing
        // until the audio happens to reach it, which on a paused meeting is
        // never.
        render()
        onEditingChanged?(self, false)
    }
}

extension TurnView: NSMenuDelegate {
    /// Filled as it opens, and emptied by being filled again.
    ///
    /// The items are moved out of the menu the pane just built rather than
    /// copied: an `NSMenuItem` belongs to one menu, and adding one that already
    /// has a `menu` raises.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let built = onSpeakerMenu?(self, speakerButton.frame) else { return }
        for item in built.items {
            built.removeItem(item)
            menu.addItem(item)
        }
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
        titleLabel.stringValue = typed
        // `Recording.rename` owns what an empty field means and answers whether
        // anything changed, so committing the same string again is not a write
        // and not a redraw. It is shared with `listen title` on purpose.
        guard (try? current.rename(to: typed)) == true else { return }
        recording = current
        // The line above wrote `stringValue`, which takes any attributed value
        // with it, so a title that was carrying find highlights has just lost
        // them. It is also new text, so the ranges have moved.
        refreshFind()
        onChanged?()
    }

    func beginEditingTitle() {
        // The plain string first. A find highlight is an attributed value, and
        // handing the field editor one means typing inherits the yellow.
        titleLabel.stringValue = titleLabel.stringValue
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
        if showing == .page, notesText.isEditable, !notesScroll.isHidden,
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

    /// Forwarded so the window can tell the Ask pane how much room its floating
    /// button needs, without reaching into the view hierarchy itself.
    ///
    /// None of these load the view. `detail` is a stored property built at
    /// `init`, the way `onChanged` above already assumes, so there is nothing
    /// to wait for; calling `loadViewIfNeeded` here instead forced the pane to
    /// load before the window had put it in the hierarchy, which is how the
    /// cross-hierarchy constraint this replaced came to be activated too early.
    func setAskClearance(_ points: CGFloat) { detail.setAskClearance(points) }

    /// Commit whatever field is open, for something outside this pane that is
    /// about to change what the pane is showing.
    func endEditing() { detail.endEditing() }

    var isAsking: Bool { detail.isAsking }

    var isShowingLive: Bool { detail.isShowingLive }

    var isLoadingTranscript: Bool { detail.isLoadingTranscript }

    /// The Chats tab comes and goes with `Settings.askEnabled`, and the window
    /// is the only thing that hears the toggle. `loadViewIfNeeded` first,
    /// because Settings can be entered before any meeting has been opened.
    func askEnabledChanged() {
        loadViewIfNeeded()
        detail.askEnabledChanged()
    }

    /// A conversation has been written to or thrown away somewhere. Only
    /// forwarded while the pane exists: the tab's count is re-read on every
    /// selection anyway, so building the pane to tell it about a conversation
    /// nobody is looking at would be work for a screen that is not up.
    func chatsChanged() {
        guard isViewLoaded else { return }
        detail.chatsChanged()
    }

    var isFinding: Bool { detail.isFinding }
    func openFind() { detail.openFind() }
    func closeFind() { detail.closeFind() }
    func findNext() { detail.findNext() }
    func findPrevious() { detail.findPrevious() }
    func find(_ query: String) { detail.find(query) }

    var onShowingChanged: (() -> Void)? {
        get { detail.onShowingChanged }
        set { detail.onShowingChanged = newValue }
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

    func showActivity() {
        guard isViewLoaded else { return }
        detail.showActivity()
    }

    func previewAsk() {
        loadViewIfNeeded()
        detail.previewAsk()
    }

    func previewTranscribing(_ fraction: Double) {
        loadViewIfNeeded()
        detail.previewTranscribing(fraction)
    }

    func previewRecording(silent: Bool) {
        loadViewIfNeeded()
        detail.previewRecording(silent: silent)
    }

    func showNote(_ slug: String?) {
        loadViewIfNeeded()
        detail.showNote(slug)
    }

    func showTranscript() {
        loadViewIfNeeded()
        detail.showTranscript()
    }


    var onOpenChat: ((Chat) -> Void)? {
        get { detail.onOpenChat }
        set { loadViewIfNeeded(); detail.onOpenChat = newValue }
    }

    func setBottomInset(_ points: CGFloat) {
        loadViewIfNeeded()
        detail.setBottomInset(points)
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
