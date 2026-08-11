import AppKit

/// What the dictation pill puts to the left of the word "Listening".
///
/// All three answer "is Listen switched on". Only two of them answer "is Listen
/// hearing me", which is the question that actually goes wrong: a muted input, a
/// headset back in its case and a microphone pointed at the wrong edge of the
/// laptop are all indistinguishable from a working one if the indicator is
/// driven by a timer.
///
/// Ported from Speak's `Meters.swift`. The waveform is **not** ported: Listen's
/// own `WaveMeter` is already that same code, down to the constants and the
/// sweep, so dictation uses it rather than shipping a second copy that would
/// have to be kept in step. What is here is the two styles Listen had no use for
/// until now, and the enum that chooses between them.
///
/// `width` and `spans` are answered by the style rather than by the view class,
/// which is where Speak kept them. The pill needs both before it has built
/// anything, and a `class var` cannot be added to `MeterView` from here anyway:
/// members declared in an extension are not overridable.
enum MeterStyle: String, CaseIterable {
    /// A fixed dot fading in and out on a timer. Says "recording" and nothing
    /// else: it looks exactly the same into a dead microphone.
    case pulse
    /// One dot whose diameter, brightness and halo follow the voice.
    case orb
    /// A scrolling strip of mirrored bars, newest on the right: the last couple
    /// of seconds of loudness, so a gap is visible after it has passed.
    case waveform

    /// What Settings offers. `pulse` is not among them: it is kept only so the
    /// comparison harness can still show what the other two replaced, since "is
    /// this better" is a question about a moving thing and cannot be answered
    /// from a screenshot or from memory of the build before last.
    static let selectable: [MeterStyle] = [.waveform, .orb]

    func makeMeter() -> MeterView {
        switch self {
        case .pulse:    return PulseMeter()
        case .orb:      return OrbMeter()
        case .waveform: return WaveMeter()
        }
    }

    /// How much width the pill has to reserve for this style.
    var width: CGFloat {
        switch self {
        case .pulse:    return 10
        case .orb:      return 30
        case .waveform: return 216
        }
    }

    /// Whether this style takes the pill over while recording, pushing the word
    /// "Listening" out of it.
    ///
    /// Only the waveform earns that. A dot next to no text is a light on a
    /// dashboard and needs the word to say which light; a waveform reacting to
    /// your own voice already says "listening" more precisely than the word
    /// does, so keeping both is spending the pill's width to repeat itself.
    var spans: Bool { self == .waveform }

    /// For the comparison harness and for anything that has to name the choice
    /// in a sentence.
    var title: String {
        switch self {
        case .pulse:    return "Pulse"
        case .orb:      return "Orb"
        case .waveform: return "Waveform"
        }
    }

    /// What picking it costs, said on screen rather than hidden in a tooltip.
    var blurb: String {
        switch self {
        case .pulse:
            return "A blinking dot. It looks the same whether or not anything "
                + "is reaching the microphone."
        case .orb:
            return "A dot that grows and brightens with your voice. The "
                + "smaller pill, and still enough to tell a live microphone "
                + "from a dead one."
        case .waveform:
            return "The last two seconds of what the microphone heard, "
                + "scrolling. A wider pill, and the only one that shows a gap "
                + "after it has happened."
        }
    }
}

/// Follows a target with a fast attack and a slow release.
///
/// The same shape as the one in `Meters.swift`, and private to each file for the
/// same reason it is private there: it is four lines, and a shared one would be
/// a dependency between two files that otherwise have none.
private struct Envelope {
    private(set) var value: CGFloat = 0
    var attack: CGFloat = 0.45
    var release: CGFloat = 0.08

    mutating func follow(_ target: CGFloat) {
        let k = target > value ? attack : release
        value += (target - value) * k
    }
}

private enum Mode {
    /// The microphone is open and everything on screen is driven by it.
    case recording
    /// The microphone is closed and the transcriber is busy. Still moving, but
    /// nothing it does may be readable as "I can hear you".
    case working
    case idle
}

// MARK: - Pulse

/// A 10 point dot alternating between full and a third opacity every 0.6 s.
///
/// Kept exactly as it shipped in Speak so that a comparison against the other
/// two is a comparison and not a rewrite.
@MainActor
final class PulseMeter: MeterView {
    private var bright = true
    private var pulse: Timer?
    private let dot = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        addSubview(dot)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10)
    }

    override var tint: NSColor {
        didSet { dot.layer?.backgroundColor = tint.cgColor }
    }

    override func begin() {
        pulse?.invalidate()
        // A slow pulse rather than a blink: it has to be noticeable in
        // peripheral vision without being the most distracting thing on screen
        // while someone is trying to speak.
        let t = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bright.toggle()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.55
                    self.dot.animator().alphaValue = self.bright ? 1.0 : 0.35
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        pulse = t
    }

    /// Goes still, which is what it always did. Kept that way deliberately: it
    /// is here as the thing the other two replaced, and a comparison against a
    /// version that has quietly been improved is not a comparison.
    override func working() { end() }

    override func end() {
        pulse?.invalidate()
        pulse = nil
        dot.alphaValue = 1
    }

    deinit { pulse?.invalidate() }
}

// MARK: - Orb

/// One dot that grows, brightens and blooms with the voice.
///
/// The bloom is a radial gradient rather than a stroked ring on purpose: a ring
/// has an edge, and an edge at this size reads as a second object orbiting the
/// dot instead of as the dot being loud.
@MainActor
final class OrbMeter: MeterView {
    private var envelope = Envelope()
    private var target: CGFloat = 0
    private var breath: CGFloat = 0
    private var mode = Mode.idle

    private let minCore: CGFloat = 3.5
    private let maxCore: CGFloat = 8

    override func push(_ level: CGFloat) { target = level }

    override func begin() {
        mode = .recording
        target = 0
        envelope = Envelope()
        startFrames()
    }

    override func working() {
        mode = .working
        // Settle to the resting size rather than carrying on from wherever the
        // last syllable left it, so the working pulse starts from the same place
        // every time instead of inheriting the shape of the final word.
        target = 0
        envelope = Envelope()
    }

    override func end() {
        mode = .idle
        stopFrames()
        target = 0
        envelope = Envelope()
        needsDisplay = true
    }

    override func step() {
        envelope.follow(target)
        breath += 1.0 / 60.0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let base = tint.usingColorSpace(.sRGB) else { return }

        let l: CGFloat
        switch mode {
        case .recording:
            // A slow breath under the level, faded out as soon as there is a
            // voice to follow. Without it a silent room freezes the orb, and a
            // frozen indicator is the one thing this pill exists to never be.
            let idle = (0.5 + 0.5 * sin(breath * 2.6)) * 0.12
            l = min(1, max(envelope.value, idle * (1 - envelope.value)))
        case .working:
            // Deliberately deeper and slower than the recording breath, and it
            // is the whole movement rather than a floor under a live level.
            // Nothing here is driven by audio any more, so it must not be able
            // to be mistaken for something that is.
            l = 0.12 + 0.38 * (0.5 + 0.5 * sin(breath * 4.2))
        case .idle:
            l = 0
        }

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let core = minCore + (maxCore - minCore) * l
        let bloom = 7 + 8 * l

        let glow = base.withAlphaComponent(0.10 + 0.32 * l)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [glow.cgColor, base.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]) {
            ctx.drawRadialGradient(
                gradient, startCenter: centre, startRadius: core * 0.7,
                endCenter: centre, endRadius: bloom, options: [])
        }

        // Loud reads as hotter, not just bigger. Two channels carrying the same
        // signal is what makes it legible out of the corner of an eye, where a
        // size difference of four points is not.
        let hot = base.blended(withFraction: 0.30 * l, of: .white) ?? base
        ctx.setFillColor(hot.cgColor)
        ctx.fillEllipse(in: CGRect(x: centre.x - core, y: centre.y - core,
                                   width: core * 2, height: core * 2))
    }
}
