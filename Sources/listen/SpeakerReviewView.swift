import AppKit

/// A persistent place to review every occurrence of one speaker without losing
/// the transcript that provides the evidence for the decision.
///
/// Selection and filtering are deliberately separate. Selecting a row keeps the
/// whole conversation on screen and dims everybody else. Filtering is the
/// explicit second action below, with its own visible "Show all transcript"
/// way out. That distinction is what keeps an ordinary click on a name from
/// looking like the app lost most of the meeting.
@MainActor
final class SpeakerReviewView: NSView {
    var onSelect: ((String) -> Void)?
    var onIdentify: ((String, NSView, NSRect) -> Void)?
    var onPlay: (() -> Void)?
    var onFilter: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Speakers")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let scroll = NSScrollView()
    private let rows = NSStackView()
    private let divider = NSBox()
    private let selectedLabel = NSTextField(labelWithString: "")
    private let selectedMeta = NSTextField(labelWithString: "")
    private let identifyButton = NSButton()
    private let playButton = NSButton()
    private let filterButton = NSButton()
    private let helpLabel = NSTextField(wrappingLabelWithString: "")
    private let separator = NSBox()

    private var selected = ""
    private var filtered = false
    private var playing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // See `Brand.raised`. Still translucent, so the transcript behind
        // it stays legible as context.
        layer?.backgroundColor = Brand.raised.withAlphaComponent(0.82).cgColor

        separator.boxType = .custom
        separator.borderType = .noBorder
        separator.fillColor = .separatorColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.cell?.wraps = true

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark", accessibilityDescription: "Close speaker review")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        closeButton.toolTip = "Close speaker review"
        closeButton.target = self
        closeButton.action = #selector(closePressed)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        rows.translatesAutoresizingMaskIntoConstraints = false

        scroll.contentView = TopAlignedClipView()
        scroll.documentView = rows
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        divider.boxType = .separator

        selectedLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        selectedLabel.lineBreakMode = .byTruncatingTail
        selectedMeta.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        selectedMeta.textColor = .secondaryLabelColor

        configureButton(identifyButton, action: #selector(identifyPressed))
        identifyButton.bezelColor = Brand.accent
        identifyButton.contentTintColor = Brand.onAccent

        configureButton(playButton, action: #selector(playPressed))
        configureButton(filterButton, action: #selector(filterPressed))

        helpLabel.font = .systemFont(ofSize: 11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.maximumNumberOfLines = 0
        helpLabel.preferredMaxLayoutWidth = 220
        helpLabel.stringValue = "Right-click a transcript label to change one turn. "
            + "Select text to change only those sentences."

        for view in [separator, titleLabel, summaryLabel, closeButton, scroll, divider,
                     selectedLabel, selectedMeta, identifyButton, playButton,
                     filterButton, helpLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),

            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor,
                                                 constant: -8),

            summaryLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            summaryLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            summaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            divider.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            selectedLabel.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),
            selectedLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            selectedLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            selectedMeta.topAnchor.constraint(equalTo: selectedLabel.bottomAnchor, constant: 2),
            selectedMeta.leadingAnchor.constraint(equalTo: selectedLabel.leadingAnchor),
            selectedMeta.trailingAnchor.constraint(equalTo: selectedLabel.trailingAnchor),

            identifyButton.topAnchor.constraint(equalTo: selectedMeta.bottomAnchor, constant: 10),
            identifyButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            identifyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            identifyButton.heightAnchor.constraint(equalToConstant: 30),

            playButton.topAnchor.constraint(equalTo: identifyButton.bottomAnchor, constant: 6),
            playButton.leadingAnchor.constraint(equalTo: identifyButton.leadingAnchor),
            playButton.trailingAnchor.constraint(equalTo: identifyButton.trailingAnchor),
            playButton.heightAnchor.constraint(equalToConstant: 30),

            filterButton.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: 6),
            filterButton.leadingAnchor.constraint(equalTo: identifyButton.leadingAnchor),
            filterButton.trailingAnchor.constraint(equalTo: identifyButton.trailingAnchor),
            filterButton.heightAnchor.constraint(equalToConstant: 30),

            helpLabel.topAnchor.constraint(equalTo: filterButton.bottomAnchor, constant: 12),
            helpLabel.leadingAnchor.constraint(equalTo: identifyButton.leadingAnchor),
            helpLabel.trailingAnchor.constraint(equalTo: identifyButton.trailingAnchor),
            helpLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),

            scroll.bottomAnchor.constraint(greaterThanOrEqualTo: divider.topAnchor, constant: -8),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configureButton(_ button: NSButton, action: Selector) {
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.target = self
        button.action = action
    }

    func configure(_ recording: Recording, selected: String, filtered: Bool) {
        self.selected = selected
        self.filtered = filtered

        let turns = recording.storedTurns
        let speakers = People.speakers(in: turns)
        let counts = Dictionary(grouping: turns, by: \.speaker).mapValues(\.count)
        let unnamed = speakers.filter { VoiceBank.isPlaceholder($0.label) }.count
        let speakerWord = speakers.count == 1 ? "speaker" : "speakers"
        if unnamed == 0 {
            summaryLabel.stringValue = "\(speakers.count) \(speakerWord) · everyone identified"
        } else {
            summaryLabel.stringValue = "\(speakers.count) \(speakerWord) · \(unnamed) unidentified"
        }

        for view in rows.arrangedSubviews { view.removeFromSuperview() }
        for speaker in speakers {
            let count = counts[speaker.label] ?? 0
            let button = row(label: speaker.label, turns: count, seconds: speaker.seconds,
                             selected: speaker.label == selected)
            rows.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
        }

        let display = SpeakerName.display(selected)
        let count = counts[selected] ?? 0
        let seconds = speakers.first { $0.label == selected }?.seconds ?? 0
        selectedLabel.stringValue = filtered ? "\(display) only" : display
        selectedMeta.stringValue = "\(count) \(count == 1 ? "turn" : "turns") · "
            + (Recording.length(seconds).isEmpty ? "0:00" : Recording.length(seconds))
        identifyButton.title = VoiceBank.isPlaceholder(selected) ? "Identify…" : "Change person…"
        identifyButton.image = NSImage(
            systemSymbolName: "person.crop.circle.badge.questionmark",
            accessibilityDescription: identifyButton.title)
        identifyButton.imagePosition = .imageLeading
        filterButton.title = filtered ? "Show all transcript" : "Show only \(display)"
        filterButton.image = NSImage(
            systemSymbolName: filtered ? "line.3.horizontal.decrease.circle.fill"
                                       : "line.3.horizontal.decrease.circle",
            accessibilityDescription: filterButton.title)
        filterButton.imagePosition = .imageLeading
        setPlaying(playing)
    }

    func setPlaying(_ playing: Bool) {
        self.playing = playing
        playButton.title = playing ? "Pause clips" : "Play clips"
        playButton.image = NSImage(
            systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playButton.title)
        playButton.imagePosition = .imageLeading
        playButton.toolTip = playing
            ? "Pause playback"
            : "Play every turn by \(SpeakerName.display(selected)), skipping other speakers"
    }

    private func row(label: String, turns: Int, seconds: Double, selected: Bool) -> NSButton {
        let button = NSButton()
        button.identifier = NSUserInterfaceItemIdentifier(label)
        button.target = self
        button.action = #selector(rowPressed(_:))
        button.bezelStyle = .inline
        button.isBordered = false
        button.alignment = .left
        button.image = paddedRowSymbol(NSImage(
            systemSymbolName: VoiceBank.isPlaceholder(label) ? "questionmark.circle.fill"
                                                              : "circle.fill",
            accessibilityDescription: nil))
        button.imagePosition = .imageLeading
        button.contentTintColor = SpeakerColour.tint(for: label) ?? .secondaryLabelColor
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        button.layer?.backgroundColor = selected
            ? Brand.accent.withAlphaComponent(0.13).cgColor : NSColor.clear.cgColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let name = SpeakerName.display(label)
            + (VoiceBank.isPlaceholder(label) ? "" : "  ✓")
        let duration = Recording.length(seconds).isEmpty ? "0:00" : Recording.length(seconds)
        let text = NSMutableAttributedString(
            string: name,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: paragraph])
        text.append(NSAttributedString(
            string: "\n\(turns) \(turns == 1 ? "turn" : "turns") · \(duration)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 10,
                                                                 weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: paragraph]))
        button.attributedTitle = text
        button.toolTip = "Review every turn by \(SpeakerName.display(label))"
        return button
    }

    /// Borderless AppKit buttons put a leading image almost against their
    /// bounds. Give the status dot a small optical gutter on both sides without
    /// moving the row's text or shrinking its 48-point hit target.
    private func paddedRowSymbol(_ symbol: NSImage?) -> NSImage? {
        guard let symbol else { return nil }
        let icon = NSSize(width: 16, height: 16)
        let canvas = NSImage(size: NSSize(width: 28, height: icon.height),
                             flipped: false) { _ in
            symbol.draw(in: NSRect(x: 12, y: 0, width: icon.width, height: icon.height))
            return true
        }
        canvas.isTemplate = true
        return canvas
    }

    @objc private func rowPressed(_ sender: NSButton) {
        guard let label = sender.identifier?.rawValue else { return }
        onSelect?(label)
    }

    @objc private func identifyPressed() {
        let rect = convert(identifyButton.bounds, from: identifyButton)
        onIdentify?(selected, self, rect)
    }

    @objc private func playPressed() { onPlay?() }
    @objc private func filterPressed() { onFilter?(!filtered) }
    @objc private func closePressed() { onClose?() }
}
