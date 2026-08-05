import AppKit

/// The colour a person is drawn in.
///
/// One palette and one hash, shared by the roster's initials disc, the person
/// popover's, and the speaker pills in a transcript. Deterministic from the
/// label rather than handed out in the order people arrive, so somebody is the
/// same colour in every meeting and a list is scannable without being read.
///
/// It was already written twice, in `InitialsDisc` and privately in
/// `PersonPopover`, and the pills would have been a third copy. Two discs
/// disagreeing about a colour is invisible; a chip disagreeing with the disc it
/// stands for is the sort of thing that reads as the colour meaning nothing.
enum SpeakerColour {
    private static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal,
                                             .systemIndigo, .systemPink, .systemBrown,
                                             .systemGreen, .systemOrange]

    /// The colour standing for a transcript label.
    static func colour(for label: String) -> NSColor {
        var hash = 5381
        for byte in label.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }

    /// The same colour, or nil when nobody has named this speaker yet.
    ///
    /// A placeholder is deliberately colourless. `A` in one meeting has nothing
    /// to do with `A` in another, so giving it a colour would claim a continuity
    /// across recordings that the label does not carry, and grey is what says
    /// "not named yet" without a word. The discs use `colour(for:)` instead,
    /// because a disc with no fill is not a disc.
    static func tint(for label: String) -> NSColor? {
        VoiceBank.isPlaceholder(label) ? nil : colour(for: label)
    }
}

/// A speaker's name in their own colour: the chips under a recording's title,
/// and the label above every turn in its transcript.
///
/// Both were `NSButton` with `bezelStyle = .inline`, which is one grey for
/// everybody. They are drawn here instead so a named speaker can carry the
/// colour of their own avatar, which is the only cue in a transcript that
/// survives not being read.
///
/// One class rather than two because the comment on `SpeakerChips` is load
/// bearing: the chip and the turn label are the same object seen twice, and the
/// moment they are built separately they start to look like two kinds of badge.
/// What differs is only how much of the colour is drawn.
@MainActor
final class SpeakerPill: NSButton {
    /// How much of the colour to draw.
    ///
    /// A recording has one row of chips and a transcript has hundreds of turns,
    /// so the same wash that makes a chip a chip is a page of tinted boxes
    /// running down a column of text. The turn label keeps the colour and drops
    /// the box: the name is already the only thing in that line, so the
    /// background was carrying nothing the ink was not.
    enum Style {
        /// A filled capsule, for a row of chips read as objects.
        case chip
        /// The name alone, coloured, for the label above a turn.
        case name
    }

    /// Tall enough for 12 point semibold with room either side, and drawn as a
    /// capsule, which is what `.inline` was drawing before this.
    static let height: CGFloat = 20
    private static let padding: CGFloat = 9

    /// What was last shown, kept because both colours have to be mixed again on
    /// an appearance change: a `cgColor` in a layer is a resolved colour and
    /// does not follow light and dark on its own, unlike everything AppKit draws
    /// on our behalf.
    private var tint: NSColor?
    private var text = ""
    private let style: Style

    init(style: Style = .chip) {
        self.style = style
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 12, weight: .semibold)
        alignment = style == .chip ? .center : .left
        layer?.cornerRadius = Self.height / 2
        cell?.lineBreakMode = .byTruncatingTail
    }

    override convenience init(frame: NSRect) { self.init(style: .chip) }

    required init?(coder: NSCoder) { fatalError() }

    /// Show `label`, optionally under a different string: the chips append a
    /// share to the name and the pill must not go looking for a colour for
    /// "Daniel Andrade · 39%".
    func show(_ label: String, title: String? = nil) {
        tint = SpeakerColour.tint(for: label)
        text = title ?? SpeakerName.display(label)
        applyTint()
    }

    /// A pill that stands for nobody, in the same grey as an unnamed speaker.
    /// The overflow chip is a count rather than a person, and giving it a
    /// person's colour would be the one pill in the row whose colour is a lie.
    func showPlain(_ title: String) {
        tint = nil
        text = title
        applyTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }

    override var intrinsicContentSize: NSSize {
        // A name pays no padding, so it starts on the same vertical line as the
        // paragraph under it. The height is kept either way: it is what the
        // timestamp beside the label is centred on.
        let padding = style == .chip ? Self.padding * 2 : 0
        return NSSize(width: ceil(attributedTitle.size().width) + padding,
                      height: Self.height)
    }

    private func applyTint() {
        // Both colours are mixed rather than named, and a mix is resolved the
        // moment it is made, so it has to be made in the appearance it will be
        // drawn in. Outside this block a system colour blends against whatever
        // appearance happens to be current, which on a first layout is the
        // window's rather than this view's.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

            // The palette colour itself is too light on its own wash in a light
            // appearance (systemTeal and systemOrange are the worst of it) and a
            // touch too saturated in a dark one, so the ink is pushed away from
            // whatever is behind it. A name has the window behind it rather than
            // a wash of itself, which is further away to start with, so it is
            // pushed less: mixing a name as hard as a chip's ink turns the
            // palette pastel and stops telling two people apart.
            let mix: CGFloat = style == .chip ? (dark ? 0.30 : 0.35)
                                              : (dark ? 0.12 : 0.25)
            let ink = tint.map {
                (dark ? $0.blended(withFraction: mix, of: .white)
                      : $0.blended(withFraction: mix, of: .black)) ?? $0
            } ?? .secondaryLabelColor

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = style == .chip ? .center : .left
            paragraph.lineBreakMode = .byTruncatingTail
            attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: font ?? .systemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: ink,
                             .paragraphStyle: paragraph])

            let wash = tint?.withAlphaComponent(dark ? 0.22 : 0.14)
                ?? NSColor.labelColor.withAlphaComponent(dark ? 0.11 : 0.07)
            layer?.backgroundColor = style == .chip ? wash.cgColor : nil
        }
        invalidateIntrinsicContentSize()
    }
}
