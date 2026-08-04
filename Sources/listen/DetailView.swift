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
    private var recording: Recording?
    private var turns: [Turn] = []

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton()
    private let slider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "0:00")
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")

    private var player: AVAudioPlayer?
    private var tick: Timer?
    private var turnViews: [TurnView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor

        playButton.bezelStyle = .circular
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.target = self
        playButton.action = #selector(togglePlay)

        slider.minValue = 0
        slider.maxValue = 1
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.controlSize = .small

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 4, bottom: 40, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        for v in [titleLabel, subtitleLabel, playButton, slider, timeLabel, scroll, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),

            playButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 14),
            playButton.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            slider.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),
            timeLabel.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 84),

            scroll.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -20),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
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
        renderTurns()

        let hasAudio = !recording.tracks.isEmpty
        setChromeHidden(false)
        playButton.isHidden = !hasAudio
        slider.isHidden = !hasAudio
        timeLabel.isHidden = !hasAudio

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
        playButton.isHidden = hidden
        slider.isHidden = hidden
        timeLabel.isHidden = hidden
        scroll.isHidden = hidden
    }

    private func renderTurns() {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        turnViews = []
        for (index, turn) in turns.enumerated() {
            let view = TurnView(turn: turn, index: index)
            view.onSeek = { [weak self] in self?.seek(to: turn.start) }
            view.onSpeaker = { [weak self] in self?.editSpeaker(turn.speaker) }
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -20).isActive = true
            turnViews.append(view)
        }
    }

    // MARK: - Playback

    /// The track to play.
    ///
    /// Prefers the mixdown, generated on demand rather than at transcription
    /// time so a library of recordings nobody replays costs nothing. Falls back
    /// to the system track, which is the one with the other participants on it
    /// and therefore the one worth hearing if only one exists.
    private func playbackURL(_ recording: Recording) -> URL? {
        if FileManager.default.fileExists(atPath: recording.mixURL.path) {
            return recording.mixURL
        }
        if let mix = try? Mixdown.make(for: recording) { return mix }
        return recording.tracks.first
    }

    @objc private func togglePlay() {
        if let player, player.isPlaying {
            player.pause()
            playButton.image = NSImage(systemSymbolName: "play.fill",
                                       accessibilityDescription: "Play")
            tick?.invalidate()
            return
        }
        guard let recording else { return }
        if player == nil {
            guard let url = playbackURL(recording),
                  let p = try? AVAudioPlayer(contentsOf: url) else {
                log("could not open audio for \(recording.id)")
                return
            }
            player = p
            slider.maxValue = p.duration
        }
        player?.play()
        playButton.image = NSImage(systemSymbolName: "pause.fill",
                                   accessibilityDescription: "Pause")
        tick = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePlayhead() }
        }
    }

    @objc private func sliderMoved() {
        player?.currentTime = slider.doubleValue
        updatePlayhead()
    }

    private func seek(to time: TimeInterval) {
        if player == nil { togglePlay() }
        player?.currentTime = time
        slider.doubleValue = time
        updatePlayhead()
    }

    private func updatePlayhead() {
        guard let player else { return }
        slider.doubleValue = player.currentTime
        timeLabel.stringValue = TranscriptFormat.stamp(player.currentTime)
            + " / " + TranscriptFormat.stamp(player.duration)

        // Highlight the turn being spoken. Comparing against the stored index
        // rather than searching keeps this cheap enough to run five times a
        // second on an hour-long transcript.
        let now = player.currentTime
        for (i, turn) in turns.enumerated() where i < turnViews.count {
            turnViews[i].isCurrent = now >= turn.start && now < turn.end
        }
        if !player.isPlaying {
            playButton.image = NSImage(systemSymbolName: "play.fill",
                                       accessibilityDescription: "Play")
            tick?.invalidate()
        }
    }

    private func stopPlayback() {
        tick?.invalidate()
        tick = nil
        player?.stop()
        player = nil
        slider.doubleValue = 0
        timeLabel.stringValue = "0:00"
        playButton.image = NSImage(systemSymbolName: "play.fill",
                                   accessibilityDescription: "Play")
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

    var isCurrent = false {
        didSet {
            guard isCurrent != oldValue else { return }
            layer?.backgroundColor = isCurrent
                ? NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
                : NSColor.clear.cgColor
        }
    }

    init(turn: Turn, index: Int) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        speakerButton.title = turn.speaker
        speakerButton.bezelStyle = .inline
        speakerButton.font = .systemFont(ofSize: 12, weight: .semibold)
        speakerButton.target = self
        speakerButton.action = #selector(speakerTapped)
        speakerButton.toolTip = "Name this speaker"

        timeLabel.stringValue = TranscriptFormat.stamp(turn.start)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .tertiaryLabelColor

        bodyLabel.stringValue = turn.text
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

extension Recording {
    var storedTurns: [Turn] {
        guard let data = try? Data(contentsOf: turnsURL),
              let turns = try? JSONDecoder().decode([Turn].self, from: data)
        else { return [] }
        return turns
    }
}
