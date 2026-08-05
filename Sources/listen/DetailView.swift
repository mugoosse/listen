import AVFoundation
import AppKit

/// The right-hand pane: player on top, transcript below as speaker-grouped
/// turns.
///
/// Clicking a turn seeks. Clicking a speaker name opens the labelling
/// affordance. The playhead highlights the turn being spoken, which is what
/// makes this readable while listening rather than instead of listening.
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
    private let playerCard = NSView()
    private let playButton = NSButton()
    private let waveform = WaveformView()
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")

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
        // it has to let the title field go itself. Everything else in this pane
        // that claims a click does the same.
        chips.onName = { [weak self] speaker in
            self?.endEditing()
            self?.editSpeaker(speaker)
        }
        chips.onPerson = { [weak self] speaker, anchor, rect in
            guard let self else { return }
            self.endEditing()
            PersonPopover.show(speaker, from: anchor, rect: rect) { [weak self] in
                guard let self, let id = self.recording?.id,
                      let updated = Recording.find(id) else { return }
                self.show(updated)
                LibraryWindow.shared.reload()
            }
        }

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

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        for v in [playButton, timeLabel, waveform] {
            v.translatesAutoresizingMaskIntoConstraints = false
            playerCard.addSubview(v)
        }
        for v in [titleLabel, subtitleLabel, chips, playerCard, scroll, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        chipsTop = chips.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor,
                                              constant: 10)
        chipsHeight = chips.heightAnchor.constraint(equalToConstant: 24)

        NSLayoutConstraint.activate([
            chipsTop,
            chipsHeight,
            chips.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            playerCard.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 14),
            playerCard.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            playerCard.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            playerCard.heightAnchor.constraint(equalToConstant: 58),

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

            scroll.topAnchor.constraint(equalTo: playerCard.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -20),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
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
        self.recording = recording

        guard let recording else {
            setChromeHidden(true)
            empty.isHidden = false
            empty.stringValue = "Select a recording."
            return
        }

        // An unnamed recording shows the placeholder as a placeholder rather
        // than as its name, so clicking the title gives an empty field to type
        // into instead of a word to delete first.
        titleLabel.stringValue = recording.isUntitled ? "" : recording.metadata.title
        titleLabel.placeholderString = Metadata.untitled
        subtitleLabel.stringValue = [recording.when, recording.lengthText]
            .filter { !$0.isEmpty }.joined(separator: " · ")

        // Who is in this recording, above the player. Collapsed to nothing when
        // there is no transcript to have speakers in, so a live or untranscribed
        // recording keeps the layout it had before this row existed.
        chips.configure(recording)
        setChipsCollapsed(chips.isEmpty)

        turns = recording.storedTurns
        // The sentence spans come from `transcript.json`, which keeps one row
        // per ASR sentence, while the paragraphs come from `turns.json`. Both
        // files are written together and neither is derived here, so the
        // transcript on screen is still exactly the one the CLI and the MCP
        // server serve.
        sentences = Merge.sentences(in: turns,
                                    from: recording.storedTranscript?.segments ?? [])
        renderTurns()

        // No player while it is being recorded. The tracks exist and are
        // growing, so a mixdown made now would be of half a meeting and the
        // waveform cache would keep that half for ever: the cache is keyed on
        // its format version, not on how long the audio was when it was drawn.
        let hasAudio = !recording.isLive && !recording.waveformSources.isEmpty
        setChromeHidden(false)
        playerCard.isHidden = !hasAudio
        length = recording.metadata.duration
        position = 0
        currentTurn = nil
        follows = true
        refresh()
        if hasAudio { loadWaveform(recording) }

        if turns.isEmpty {
            empty.isHidden = false
            empty.stringValue = recording.isLive
                ? "Recording. The transcript appears when you stop."
                : (recording.hasTranscript
                    ? "This recording has no speech in it."
                    : (Queue.shared.isQueued(recording.id)
                        ? "Transcribing. This stays here if you quit."
                        : "Not transcribed yet."))
        } else {
            empty.isHidden = true
        }
    }

    private func setChromeHidden(_ hidden: Bool) {
        titleLabel.isHidden = hidden
        subtitleLabel.isHidden = hidden
        playerCard.isHidden = hidden
        scroll.isHidden = hidden
        if hidden { setChipsCollapsed(true) }
    }

    /// A hidden view still occupies its frame, so the row's height and the
    /// space above it both have to go: leaving them would open a 34 point gap
    /// under the date of every recording that has no speakers yet.
    private func setChipsCollapsed(_ collapsed: Bool) {
        chips.isHidden = collapsed
        chipsTop.constant = collapsed ? 0 : 10
        chipsHeight.constant = collapsed ? 0 : 24
    }

    private func renderTurns(scrollToTop: Bool = true) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        turnViews = []
        editingTurn = nil
        for (index, turn) in turns.enumerated() {
            let view = TurnView(turn: turn,
                                sentences: index < sentences.count ? sentences[index] : [])
            view.onSeek = { [weak self] in
                self?.endEditing()
                self?.seek(to: turn.start, playing: true)
            }
            view.onSpeaker = { [weak self] in
                self?.endEditing()
                self?.editSpeaker(turn.speaker)
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
        // Not after an edit. A reload that jumps to the top of an hour-long
        // meeting loses the reader's place every time they correct a word.
        guard scrollToTop else { return }

        // Open at the beginning. A freshly selected recording used to open
        // somewhere near the end of the meeting with half a paragraph cut off
        // above it, which reads as a rendering fault rather than as a scroll
        // position.
        //
        // The top is `bounds.maxY`, not zero. `TopAlignedClipView` flips the
        // *clip view*, which decides where a short transcript sits and which
        // way the scrollers run, and changes nothing about the stack view's own
        // coordinates: its arranged subviews are still laid out with the first
        // turn at the highest y. Measured both ways round on an 80 minute
        // recording, because the two flags read as if they should agree and do
        // not: y = 0 opens on the last turn, y = maxY - 1 on the first.
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
            player.pause()
            setPlaying(false)
            tick?.invalidate()
            return
        }
        follows = true
        withPlayer { player in
            // Pressing play on a finished recording plays it, rather than
            // sitting silently at the end wondering what the button did.
            if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
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

    // MARK: - Labelling

    private func editSpeaker(_ speaker: String) {
        guard let recording else { return }
        SpeakerSheet.present(for: recording, speaker: speaker, in: window) { [weak self] in
            guard let self, let updated = Recording.find(recording.id) else { return }
            self.show(updated)
            LibraryWindow.shared.reload()
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

    func sentence(at index: Int) -> Merge.Sentence? {
        if let hit = sentences.first(where: { NSLocationInRange(index, $0.range) }) {
            return hit
        }
        // An insertion point at the very end of the paragraph is one past every
        // range. Refusing there would make the end of a turn, which is where a
        // trailing mistranscription usually is, the one place you cannot edit.
        return sentences.last.flatMap { index == NSMaxRange($0.range) ? $0 : nil }
    }
}

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
}

/// One speaker turn in the transcript.
@MainActor
final class TurnView: NSView {
    private let speakerButton = NSButton()
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

    var onSeek: (() -> Void)?
    var onSpeaker: (() -> Void)?
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
                ? NSColor.controlAccentColor.withAlphaComponent(0.07).cgColor
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
                              value: NSColor.controlAccentColor.withAlphaComponent(0.30),
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
        // code the reader is meant to decode.
        speakerButton.title = SpeakerName.display(turn.speaker)
        speakerButton.bezelStyle = .inline
        speakerButton.font = .systemFont(ofSize: 12, weight: .semibold)
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
            speakerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            timeLabel.centerYAnchor.constraint(equalTo: speakerButton.centerYAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: speakerButton.trailingAnchor,
                                               constant: 8),
            body.topAnchor.constraint(equalTo: speakerButton.bottomAnchor, constant: 3),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
        fill(with: [bodyLabel])

        let click = NSClickGestureRecognizer(target: self, action: #selector(bodyTapped))
        bodyLabel.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func speakerTapped() { onSpeaker?() }
    @objc private func bodyTapped() { onSeek?() }

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

extension DetailView: NSTextFieldDelegate {
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

    func stopPlayback() { detail.stopPlayback() }
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
}
