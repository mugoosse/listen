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

    /// Whether the transcript follows the playhead. Turned off the moment the
    /// user scrolls, because scrolling away during playback is a decision, and
    /// dragging somebody back to the playhead every two seconds makes the
    /// transcript unreadable while it plays.
    private var follows = true
    private var scrollingProgrammatically = false

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
        for v in [titleLabel, subtitleLabel, playerCard, scroll, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            playerCard.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
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

        titleLabel.stringValue = recording.metadata.title
        subtitleLabel.stringValue = [recording.when, recording.lengthText]
            .filter { !$0.isEmpty }.joined(separator: " · ")

        turns = recording.storedTurns
        // The sentence spans come from `transcript.json`, which keeps one row
        // per ASR sentence, while the paragraphs come from `turns.json`. Both
        // files are written together and neither is derived here, so the
        // transcript on screen is still exactly the one the CLI and the MCP
        // server serve.
        sentences = Merge.sentences(in: turns,
                                    from: recording.storedTranscript?.segments ?? [])
        renderTurns()

        let hasAudio = !recording.waveformSources.isEmpty
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
            empty.stringValue = recording.hasTranscript
                ? "This recording has no speech in it."
                : (Queue.shared.isQueued(recording.id)
                    ? "Transcribing. This stays here if you quit."
                    : "Not transcribed yet.")
        } else {
            empty.isHidden = true
        }
    }

    private func setChromeHidden(_ hidden: Bool) {
        titleLabel.isHidden = hidden
        subtitleLabel.isHidden = hidden
        playerCard.isHidden = hidden
        scroll.isHidden = hidden
    }

    private func renderTurns() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        turnViews = []
        for (index, turn) in turns.enumerated() {
            let view = TurnView(turn: turn,
                                sentences: index < sentences.count ? sentences[index] : [])
            view.onSeek = { [weak self] in self?.seek(to: turn.start, playing: true) }
            view.onSpeaker = { [weak self] in self?.editSpeaker(turn.speaker) }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -20).isActive = true
            turnViews.append(view)
        }

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
}

/// One speaker turn in the transcript.
@MainActor
final class TurnView: NSView {
    private let speakerButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")

    var onSeek: (() -> Void)?
    var onSpeaker: (() -> Void)?

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
    /// unless the sentence changed.
    func highlight(_ time: TimeInterval?) {
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

        for v in [speakerButton, timeLabel, bodyLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            speakerButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            speakerButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            timeLabel.centerYAnchor.constraint(equalTo: speakerButton.centerYAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: speakerButton.trailingAnchor,
                                               constant: 8),
            bodyLabel.topAnchor.constraint(equalTo: speakerButton.bottomAnchor, constant: 3),
            bodyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            bodyLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(bodyTapped))
        bodyLabel.addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func speakerTapped() { onSpeaker?() }
    @objc private func bodyTapped() { onSeek?() }
}

// MARK: - Renaming

extension DetailView: NSTextFieldDelegate {
    /// Commit the title when the field loses focus or Return is pressed.
    ///
    /// `metadata.json` already carried a `title` field in the Python version,
    /// so the key is unchanged and the existing tools keep reading it.
    func controlTextDidEndEditing(_ note: Notification) {
        guard var current = recording else { return }
        let name = titleLabel.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            // An empty title would leave a row with nothing to click. Put the
            // old one back rather than inventing a placeholder.
            titleLabel.stringValue = current.metadata.title
            return
        }
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
