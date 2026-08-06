import AppKit

/// Who is in this recording, as a row of chips under its title.
///
/// The same pill as the speaker label inside a turn, deliberately: it is the
/// same object, so it should not arrive on screen as a second kind of badge.
/// Until this existed the only way to find out who was in a meeting was to
/// scroll its transcript, while `listen show` had printed a `speakers:` line
/// all along.
///
/// A chip does one of two things depending on what it is. An unnamed speaker
/// opens the naming sheet, because naming is the only useful thing to do with
/// one. A named speaker opens their person popover, because by then the
/// interesting question is where else they turn up. Same control, and which
/// meaning applies is legible from the chip itself.
@MainActor
final class SpeakerChips: NSView {
    private let stack = NSStackView()

    /// An unnamed speaker was clicked, with the chip's rectangle in this
    /// view's coordinates, so the picker can point at it.
    var onName: ((String, NSView, NSRect) -> Void)?

    /// A named speaker was clicked, with the chip's rectangle in this view's
    /// coordinates.
    ///
    /// The row itself is the anchor rather than the chip, which matters more
    /// than it looks. `NSPopover` closes itself the moment its positioning view
    /// leaves the window, and `configure` replaces every chip on any reload, so
    /// a popover pointed at a button vanished as soon as anything rebuilt the
    /// pane behind it. Measured: it opened and closed inside the same
    /// `show(relativeTo:)` call, reporting `isShown == false` immediately after,
    /// with a close reason of "standard" and no other symptom.
    var onPerson: ((String, NSView, NSRect) -> Void)?

    /// Something in a chip's menu changed the recording or the library.
    ///
    /// Narrowing the transcript to one speaker is deliberately **not** here.
    /// It is not a mode a chip can put the pane into, it is what being asked
    /// about looks like: `DetailView.editSpeaker` turns it on with the popover
    /// and off again when that closes, so there is no state for this row to
    /// carry and no second control that could disagree with the popover about
    /// whether a filter is on.
    var onChanged: (() -> Void)?

    /// True when there is nobody to show, so the pane can close the gap rather
    /// than leaving an empty band under the date.
    private(set) var isEmpty = true

    /// The recording being shown, for the menus, which need to know what they
    /// are acting on.
    private var recording: Recording?

    /// How many chips before the rest go into an overflow menu.
    ///
    /// A count rather than a width measurement. Five real names fit the
    /// narrowest the pane can be dragged to, and a six-person call is rare
    /// enough that one extra click for the sixth is a better trade than a
    /// layout pass that has to run again every time the divider moves.
    private static let maxChips = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        // Long names in a narrow pane are clipped rather than drawn over the
        // window's edge.
        clipsToBounds = true

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ recording: Recording) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        self.recording = recording

        let speakers = People.speakers(in: recording)
        isEmpty = speakers.isEmpty
        isHidden = isEmpty
        guard !isEmpty else { return }

        // The share is only worth showing when there is somebody to share it
        // with. On a one-speaker recording it is always 100%, which is a number
        // that answers nothing.
        let total = speakers.reduce(0) { $0 + $1.seconds }
        let showShare = speakers.count > 1 && total > 0

        for speaker in speakers.prefix(Self.maxChips) {
            stack.addArrangedSubview(chip(
                speaker.label,
                share: showShare ? speaker.seconds / total : nil,
                seconds: speaker.seconds))
        }

        let overflow = speakers.dropFirst(Self.maxChips)
        guard !overflow.isEmpty else { return }
        let more = SpeakerPill()
        more.target = self
        more.action = #selector(showOverflow)
        more.showPlain("+\(overflow.count)")
        more.toolTip = overflow.map { SpeakerName.display($0.label) }
            .joined(separator: ", ")
        let menu = NSMenu()
        for speaker in overflow {
            let item = NSMenuItem(title: SpeakerName.display(speaker.label),
                                  action: #selector(overflowPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speaker.label
            menu.addItem(item)
        }
        more.menu = menu
        stack.addArrangedSubview(more)
    }

    private func chip(_ label: String, share: Double?, seconds: Double) -> NSButton {
        let name = SpeakerName.display(label)
        let percent = share.map { " · \(max(1, Int(($0 * 100).rounded())))%" } ?? ""
        let button = SpeakerPill()
        button.target = self
        button.action = #selector(chipClicked(_:))
        // The label decides the colour and the title decides the words. They
        // differ here: a chip carries a share, and "Me · 61%" is not somebody's
        // name to look a colour up under.
        //
        // Nothing is added while that speaker is the one being asked about. A
        // mark on the chip would be a second thing on screen saying what the bar
        // over the transcript already says, and it would have to be kept in step
        // with a state this row does not own.
        button.show(label, title: name + percent)
        button.identifier = NSUserInterfaceItemIdentifier(label)

        let spoken = Recording.length(seconds)
        if VoiceBank.isPlaceholder(label) {
            button.toolTip = spoken.isEmpty ? "Name this speaker."
                : "Spoke for \(spoken). Click to name them."
        } else if label == SpeakerName.you {
            button.toolTip = "This is you, on the microphone track. "
                + "Click to change what you are called."
        } else {
            button.toolTip = spoken.isEmpty ? "Click for every recording they are in."
                : "Spoke for \(spoken). Click for every recording they are in."
        }

        // The same actions on the right button. A popover is one window manager
        // decision away from not appearing, and a menu is not, so nothing this
        // feature does is reachable only through one of them.
        if let recording {
            button.menu = PersonPopover.menu(
                for: label, in: recording,
                anchor: { [weak self, weak button] in
                    guard let self, let button else { return nil }
                    return (self, self.convert(button.frame, from: self.stack))
                },
                done: { [weak self] in self?.onChanged?() })
        }
        return button
    }

    // MARK: - Clicks

    @objc private func chipClicked(_ sender: NSButton) {
        guard let label = sender.identifier?.rawValue else { return }
        route(label, at: convert(sender.frame, from: stack))
    }

    @objc private func overflowPicked(_ sender: NSMenuItem) {
        guard let label = sender.representedObject as? String else { return }
        // Anchored to the overflow chip, which is the last one in the row: the
        // menu item it was picked from has no view of its own by the time this
        // runs.
        let last = stack.arrangedSubviews.last.map { convert($0.frame, from: stack) }
        route(label, at: last ?? bounds)
    }

    @objc private func showOverflow(_ sender: NSButton) {
        guard let menu = sender.menu else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func route(_ label: String, at rect: NSRect) {
        if VoiceBank.isPlaceholder(label) {
            onName?(label, self, rect)
        } else {
            onPerson?(label, self, rect)
        }
    }
}
