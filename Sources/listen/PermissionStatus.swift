import AppKit

/// How a permission is drawn, and whether anything is wrong.
///
/// The Permissions pane used to report all four grants in the same grey
/// sentence, which meant a missing one and a working one looked identical: the
/// only difference was the words, and the words are the thing somebody skims
/// past. A permission screen exists to answer "is anything wrong", and that
/// question should be answerable from across the room.
enum PermissionState {
    /// Working. Deliberately quiet: four green ticks in a column is a wall of
    /// colour that makes the one warning harder to find, not easier.
    case granted
    /// Not granted, and something the user has switched on does not work
    /// because of it.
    case blocked
    /// Not granted, and nothing is broken. The calendar is the case: Listen
    /// records, transcribes and labels perfectly well without it, so colouring
    /// it as a fault would be nagging somebody about a choice they made.
    case optional

    var symbol: String {
        switch self {
        case .granted:  return "checkmark.circle.fill"
        case .blocked:  return "exclamationmark.triangle.fill"
        case .optional: return "circle.dashed"
        }
    }

    var tint: NSColor {
        switch self {
        case .granted:  return .systemGreen
        case .blocked:  return .systemOrange
        case .optional: return .secondaryLabelColor
        }
    }

    /// Only the fault is coloured. The other two carry their meaning in the
    /// symbol, and a green sentence next to an orange one halves how much the
    /// orange one stands out.
    var textColor: NSColor {
        self == .blocked ? .systemOrange : .secondaryLabelColor
    }
}

/// One permission's state and its sentence, as a row.
///
/// A symbol beside wrapping text, aligned to the first line rather than centred
/// on the block: a two-line explanation with a tick floating in the middle of it
/// reads as a bullet point, and this is a status.
@MainActor
final class PermissionStatusRow: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            // Pinned to the top and nudged down to sit on the first line's
            // baseline, not centred on the whole block.
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The wrapping width has to be told, and only when it changed.
    ///
    /// An `NSTextField` computes its height from `preferredMaxLayoutWidth`
    /// rather than from the width it was given, so a row left at the old value
    /// reports the old height and loses its last line as the window narrows.
    /// The same trap `Pane.sizeDocument` handles for its own notes, and this row
    /// is not one of those because it is a view rather than a bare label.
    override func layout() {
        super.layout()
        let available = max(0, bounds.width - 22)
        guard abs(label.preferredMaxLayoutWidth - available) > 0.5 else { return }
        label.preferredMaxLayoutWidth = available
        label.invalidateIntrinsicContentSize()
        super.layout()
    }

    func set(_ state: PermissionState, _ text: String) {
        icon.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil)
        icon.contentTintColor = state.tint
        label.stringValue = text
        label.textColor = state.textColor
        // Said to accessibility as well, or the state is carried entirely by a
        // colour and a glyph, which is exactly the audience that cannot use it.
        setAccessibilityLabel({
            switch state {
            case .granted:  return "Granted. " + text
            case .blocked:  return "Not granted. " + text
            case .optional: return "Optional, not granted. " + text
            }
        }())
    }
}

extension Pane {
    /// A status row, added to the pane's stack like `note` is.
    @discardableResult
    func statusRow() -> PermissionStatusRow {
        let row = PermissionStatusRow()
        stack.addArrangedSubview(row)
        widthCapped(row)
        return row
    }
}

/// Whether any permission the user is relying on is missing.
///
/// One derivation, because the sidebar badge and the pane have to agree: a dot
/// on Permissions that leads to a pane where everything looks fine is worse than
/// no dot at all.
///
/// The rule is **something switched on does not work**, not "something is
/// ungranted". The calendar is excluded because Listen never needed it, and
/// Accessibility counts only while dictation is enabled: somebody who has turned
/// dictation off has not left a permission missing, they have declined a
/// feature.
@MainActor
enum PermissionsSummary {
    static var blocked: Bool {
        if !Permissions.microphone { return true }
        if Permissions.systemAudioSupported, !Permissions.systemAudio { return true }
        if Settings.dictationEnabled, !Permissions.accessibility { return true }
        return false
    }
}
