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
    /// Orange is last, and last is reserved for you. See `colour(for:)`.
    ///
    /// `systemBrown` used to be in here and was dropped: beside the orange that
    /// is now permanently the user's, it is the one entry a reader has to look
    /// twice at, and the user's voice is in every recording, so that pair would
    /// have come up more than any other.
    private static let palette: [NSColor] = [.systemBlue, .systemPurple, .systemTeal,
                                             .systemIndigo, .systemPink,
                                             .systemGreen, .systemOrange]

    /// The colour standing for a transcript label.
    ///
    /// **You are reserved one entry and everybody else hashes over the rest.**
    /// The palette has eight colours and the user's own label is the constant
    /// `Me`, so without this a one-to-one call has both people in the same
    /// colour one time in eight, and a one-to-one call is the common case. It
    /// happened on the first two names tried for a screenshot: `Me` and
    /// "Priya Raman" both land in the last bucket.
    ///
    /// Reserving costs a colour and keeps every other property. Somebody is
    /// still the same colour in every meeting, because the hash is still over
    /// the label alone and nothing is handed out in arrival order. Two *other*
    /// speakers in one meeting can still collide, which is rarer and matters
    /// less: neither of them is the one voice that is on every recording.
    static func colour(for label: String) -> NSColor {
        guard label != SpeakerName.you else { return palette[palette.count - 1] }
        var hash = 5381
        for byte in label.utf8 { hash = (hash &* 33) &+ Int(byte) }
        return palette[abs(hash) % (palette.count - 1)]
    }

    /// The same colour, or nil when nobody has named this speaker yet.
    ///
    /// A placeholder is deliberately colourless. `A` in one meeting has nothing
    /// to do with `A` in another, so giving it a colour would claim a continuity
    /// across recordings that the label does not carry, and grey is what says
    /// "not named yet" without a word. The discs use `colour(for:)` instead,
    /// because a disc with no fill is not a disc.
    /// Empty is colourless too, which is how a pill that stands for nobody asks
    /// for the placeholder grey: `isPlaceholder` says false for "", because a
    /// speaker with no label is not a case the transcript can produce.
    static func tint(for label: String) -> NSColor? {
        label.isEmpty || VoiceBank.isPlaceholder(label) ? nil : colour(for: label)
    }

    /// What the colour is being drawn on, which decides how far the ink is
    /// pushed away from it.
    enum Ground {
        /// A wash of the speaker's own colour, as under a chip.
        case wash
        /// The window, as behind a name or a waveform bar.
        case window
    }

    /// The colour a speaker's name is written in.
    ///
    /// A mix is resolved the moment it is made, so this has to be called with
    /// the drawing appearance current: inside `draw`, or inside
    /// `performAsCurrentDrawingAppearance`. The waveform asks for this rather
    /// than mixing its own, because a bar that is nearly the colour of the name
    /// above it is worse than one that is plainly a different colour.
    static func ink(for label: String, on ground: Ground, dark: Bool) -> NSColor {
        // The palette colour itself is too light on its own wash in a light
        // appearance (systemTeal and systemOrange are the worst of it) and a
        // touch too saturated in a dark one. On the window it starts further
        // away and is pushed less: mixing a name as hard as a chip's ink turns
        // the palette pastel and stops telling two people apart.
        guard let tint = tint(for: label) else { return .secondaryLabelColor }
        let mix: CGFloat = ground == .wash ? (dark ? 0.30 : 0.35)
                                           : (dark ? 0.12 : 0.25)
        return (dark ? tint.blended(withFraction: mix, of: .white)
                     : tint.blended(withFraction: mix, of: .black)) ?? tint
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

    /// A glyph drawn after the title, or nil for a plain pill.
    ///
    /// The sidebar's lens is one of these with a cross on the end, so that the
    /// token saying the list is narrowed is the same object as the chip that
    /// narrowed it rather than a second thing drawn to look like it.
    ///
    /// **Text in the same run rather than the button's `image`.** An
    /// `.imageTrailing` glyph is aligned to the title's *baseline*, so at this
    /// size an `xmark` sat about two points below the centre of the letters
    /// beside it, and the usual cures are all fights with `NSButtonCell`:
    /// alignment rects, a scaling mode, or a hand-placed subview. A character
    /// in the same attributed string shares the font, the baseline and the
    /// paragraph style, so there is nothing left to misalign.
    var trailing: String? {
        didSet { applyTint() }
    }

    /// Space between the title and that glyph.
    private static let glyphGap = "  "

    /// What was last shown, kept because both colours have to be mixed again on
    /// an appearance change: a `cgColor` in a layer is a resolved colour and
    /// does not follow light and dark on its own, unlike everything AppKit draws
    /// on our behalf.
    private var label = ""
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
        self.label = label
        text = title ?? SpeakerName.display(label)
        applyTint()
    }

    /// A pill that stands for nobody, in the same grey as an unnamed speaker.
    /// The overflow chip is a count rather than a person, and giving it a
    /// person's colour would be the one pill in the row whose colour is a lie.
    func showPlain(_ title: String) {
        label = ""
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
        // `attributedTitle` already carries the trailing glyph, so it is
        // measured with the words and there is nothing to add for it here.
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
            let ink = SpeakerColour.ink(for: label,
                                        on: style == .chip ? .wash : .window,
                                        dark: dark)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = style == .chip ? .center : .left
            paragraph.lineBreakMode = .byTruncatingTail
            let face = font ?? .systemFont(ofSize: 12, weight: .semibold)
            let title = NSMutableAttributedString(
                string: text,
                attributes: [.font: face,
                             .foregroundColor: ink,
                             .paragraphStyle: paragraph])
            if let trailing {
                // Dimmer than the name. The glyph is how the token goes away,
                // not what it says, and drawn at full weight it is what the eye
                // lands on first.
                title.append(NSAttributedString(
                    string: Self.glyphGap + trailing,
                    attributes: [.font: face,
                                 .foregroundColor: ink.withAlphaComponent(0.55),
                                 .paragraphStyle: paragraph]))
            }
            attributedTitle = title

            let wash = SpeakerColour.tint(for: label)?
                .withAlphaComponent(dark ? 0.22 : 0.14)
                ?? NSColor.labelColor.withAlphaComponent(dark ? 0.11 : 0.07)
            layer?.backgroundColor = style == .chip ? wash.cgColor : nil
        }
        invalidateIntrinsicContentSize()
    }
}
