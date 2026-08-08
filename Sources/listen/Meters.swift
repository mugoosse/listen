import AppKit

/// Live level meters for the two tracks.
///
/// Ported from Speak's `Meters.swift`, constants and structure intact, because
/// the two apps are expected to become one and two meters that disagree about
/// what a level means would make that a reconciliation rather than a move.
/// Speak's three styles are not here: the style picker is a Speak setting, and
/// the waveform is the one that answers Listen's question. See `WaveMeter`.
///
/// Why this exists at all is written up in `CLAUDE.md`, and the short version is
/// that an hour of a WhatsApp call was recorded with the laptop lid shut, the
/// built-in microphone therefore switched off by macOS, and nothing on screen
/// said so, because the only moving thing in the recording panel was a clock
/// counting up. Listen's own iOS app already had this right: "a muted
/// microphone, a case over it and a headset that walked out of range all produce
/// a file of exactly the right length containing silence, and all three look
/// identical to a clock that is counting up."

/// A synthetic speech envelope, for the preview launches that put the strips on
/// screen with nothing being captured.
///
/// Syllables inside words inside phrases, with gaps between them, rather than a
/// sine wave. A sine exercises neither `Envelope`'s attack nor its release, and
/// the gaps speech has inside every word are the whole reason `Envelope` rises
/// fast and falls slowly, so a smooth input hides whether that works at all.
///
/// Shared by the recording screen and the floating panel so the two previews are
/// judged against the same movement.
enum FakeSpeech {
    static func level(_ t: Double) -> Float {
        let phrase = sin(t * 0.45) > -0.3 ? 1.0 : 0.0
        let word = max(0, sin(t * 2.3))
        let syllable = 0.55 + 0.45 * sin(t * 11)
        return Float(min(1, phrase * word * syllable))
    }
}

/// Draw a view into a PNG without going near the screen.
///
/// Lifted out of `LibraryWindow.writeShot` when the panel needed the same thing,
/// with its reasoning: `screencapture` and ScreenCaptureKit both photograph the
/// *screen*, so neither can see these windows when the Mac is locked, over SSH,
/// or with the lid shut. `cacheDisplay` asks the view to draw itself into a
/// bitmap, which needs no display, no session and no Screen Recording grant.
///
/// The flattening is not cosmetic. `cacheDisplay` draws views and not windows,
/// and an `NSVisualEffectView`'s material is the window server's work, so
/// without a background painted underneath a dark panel comes out as white text
/// on white. This is not what the thing looks like to the pixel and is not meant
/// to be: it is legible, and the colours and the layout are the app's own.
extension NSView {
    @discardableResult
    func writeShot(to path: String) -> Bool {
        // Laid out first: a window never ordered front has never been through a
        // layout pass, and the bitmap would show the frames the views were
        // created with rather than the ones they are drawn at.
        layoutSubtreeIfNeeded()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        cacheDisplay(in: bounds, to: rep)

        let flattened = NSImage(size: bounds.size)
        flattened.lockFocus()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: bounds.size))
        flattened.unlockFocus()

        guard let tiff = flattened.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            log("could not write \(path): \(error.localizedDescription)")
            return false
        }
    }
}

/// What a meter is currently doing.
private enum Mode {
    /// A track is open and every movement on screen is driven by it.
    case live
    /// The audio is finished and something is reading it. Still moving, because
    /// a frozen picture reads as a hung app, but nothing it does may be readable
    /// as "I can still hear you".
    case working
    case idle
}

/// Follows a target with a fast attack and a slow release.
///
/// Speech is bursts with gaps inside every word, so a meter that falls as fast
/// as it rises spends its time flickering between syllables rather than tracking
/// a voice. Rising fast and falling slowly is the whole difference between
/// something that reads as a level and something that reads as a strobe.
private struct Envelope {
    private(set) var value: CGFloat = 0
    var attack: CGFloat = 0.45
    var release: CGFloat = 0.08

    mutating func follow(_ target: CGFloat) {
        let k = target > value ? attack : release
        value += (target - value) * k
    }
}

/// The animated half of anything that shows a track while it is being captured.
@MainActor
class MeterView: NSView {
    var tint: NSColor = .systemRed { didSet { needsDisplay = true } }

    /// Newest loudness, 0 for a silent room and 1 for shouting.
    func push(_ level: CGFloat) {}

    func begin() {}
    func working() {}
    func end() {}

    // MARK: - Frame clock

    private var frames: Timer?

    /// 60 Hz, in `.common` mode.
    ///
    /// The default run loop mode stops firing while a menu is open or a window
    /// is being dragged, and a meter that freezes mid-sentence is worse than one
    /// that never moved: it reads as the app having crashed at the moment the
    /// user is trusting it with an hour of a conversation.
    func startFrames() {
        stopFrames()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common)
        frames = t
    }

    func stopFrames() {
        frames?.invalidate()
        frames = nil
    }

    /// One animation frame. Subclasses advance their own state and redraw.
    func step() {}

    deinit { frames?.invalidate() }
}

/// A scrolling strip of bars, newest on the right.
///
/// The thing a dot cannot do: it keeps a couple of seconds of history, so a gap
/// is still visible after it has happened. That answers "did it catch the start
/// of that sentence", which is a question somebody asks a beat *after* the
/// moment a live dot could have told them.
///
/// Listen holds one of these per track and runs them for an hour, which Speak
/// never had to. Two consequences, both handled by the owners rather than here:
/// `end()` has to be called whenever the strip goes off screen, because a 60 Hz
/// timer redrawing a hidden view for the length of a meeting is an hour of
/// wakeups for nothing; and `levels` is capped at the column count, so the
/// history costs the same at minute fifty-eight as at minute one.
@MainActor
final class WaveMeter: MeterView {
    private let barWidth: CGFloat = 2
    private let gap: CGFloat = 1.5
    /// One column every second frame: thirty a second, which across a strip of a
    /// couple of hundred points is about two seconds of history. Slower and the
    /// scroll becomes a series of steps rather than a movement; faster and there
    /// is no history left to read.
    private let framesPerColumn = 2

    private var levels: [CGFloat] = []
    private var envelope = Envelope()
    private var target: CGFloat = 0
    private var frameCount = 0
    private var mode = Mode.idle
    private var sweep: CGFloat = 0

    /// The track is running and delivering bit-exact silence.
    ///
    /// Drawn rather than merely reported, and drawn as a change of colour on a
    /// strip that is already flat. A flat strip alone is ambiguous, because it is
    /// also what a room nobody is talking in looks like; a flat strip that has
    /// gone amber is a statement. The sentence next to it is what says which
    /// silence it is, and `MicRecorder.checkForSilence` is what decides.
    var isSilent = false {
        didSet { guard isSilent != oldValue else { return }; needsDisplay = true }
    }

    private var columns: Int {
        max(1, Int((bounds.width + gap) / (barWidth + gap)))
    }

    override func push(_ level: CGFloat) { target = level }

    override func begin() {
        mode = .live
        target = 0
        envelope = Envelope()
        levels = []
        frameCount = 0
        startFrames()
    }

    /// Stops scrolling and starts sweeping.
    ///
    /// The bars are left standing rather than cleared: what was just captured is
    /// worth looking at while it is being read, and clearing would blank the
    /// strip at the exact moment somebody glances at it to check it heard them.
    /// What travels across them is a highlight, which is the honest shape for
    /// this state: the audio is finished and something is reading it.
    override func working() {
        mode = .working
        sweep = 0
    }

    override func end() {
        mode = .idle
        stopFrames()
        needsDisplay = true
    }

    override func step() {
        switch mode {
        case .live:
            envelope.follow(target)
            frameCount += 1
            if frameCount % framesPerColumn == 0 {
                levels.append(envelope.value)
                if levels.count > columns { levels.removeFirst(levels.count - columns) }
            }
        case .working:
            // Leads out past 1 so the highlight finishes leaving the right edge
            // before it reappears on the left, rather than cross-fading between
            // the two ends.
            sweep += 1.0 / 60.0 / 1.3
            if sweep > 1.25 { sweep = -0.1 }
        case .idle:
            break
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let colour = isSilent ? NSColor.systemOrange : tint
        guard let base = colour.usingColorSpace(.sRGB) else { return }
        let n = columns
        let pitch = barWidth + gap
        let mid = bounds.midY
        let maxHalf = min(13, bounds.height / 2)
        let floorHalf: CGFloat = barWidth / 2

        for i in 0..<n {
            // Newest on the right, and the strip starts empty on the right too,
            // so a fresh recording grows into it instead of appearing whole.
            let age = n - 1 - i
            let index = levels.count - 1 - age
            let level = index >= 0 ? levels[index] : 0
            let half = floorHalf + (maxHalf - floorHalf) * pow(level, 0.75)

            // The oldest columns fade to nothing rather than to a dim grey, so
            // they read as scrolling out under the edge instead of stopping dead
            // at a line. Squared, because a linear ramp still leaves a visible
            // front edge where the fade begins. Only the oldest third fades:
            // taking it across the whole strip would make the left half
            // unreadable, and the left half is the history this exists for.
            let fade = min(1, CGFloat(i) / max(1, CGFloat(n) * 0.30))

            // While working, a soft band travels left to right and everything
            // outside it drops back. Left to right because that is the order the
            // words were said and the order they are being read in.
            var lit: CGFloat = 1
            if mode == .working {
                let position = CGFloat(i) / max(1, CGFloat(n - 1))
                let d = (position - sweep) / 0.14
                lit = 0.34 + 0.66 * exp(-d * d)
            }
            base.withAlphaComponent(fade * fade * lit).setFill()

            let rect = NSRect(x: CGFloat(i) * pitch, y: mid - half,
                              width: barWidth, height: half * 2)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2,
                         yRadius: barWidth / 2).fill()
        }
    }
}

/// One track's strip with its name beside it.
///
/// The label is not decoration, it is the diagnosis. One strip moving while the
/// other is flat says which half of the recording is broken, with no
/// investigation and nothing to remember; the same two strips unlabelled say
/// only that something is wrong. In the hour that prompted this, "Them" would
/// have been alive from the first second and "You" flat for fifty-eight minutes.
///
/// Named "You" and "Them" rather than "Microphone" and "System audio" because
/// the question being answered is whose voice is missing. `TranscribingView`
/// already draws the same two tracks in the same order for the same reason, so
/// the picture does not change meaning when capture ends and transcription
/// begins.
@MainActor
final class TrackMeter: NSView {
    let meter = WaveMeter()
    private let label = NSTextField(labelWithString: "")

    /// Width reserved for the name, measured from the font rather than guessed,
    /// because the strip is pinned to the label's trailing edge and a guess puts
    /// the two tracks' bars in different places.
    static let labelWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        let widest = ["You", "Them"].map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 30
        // Slack for the field's own inset. `NSTextField.sizeToFit` reports wider
        // than the string it holds, so pinning the frame to the bare string
        // width clipped the "m" off "Them" and left it touching the strip.
        return ceil(widest) + 6
    }()

    init(name: String, tint: NSColor) {
        super.init(frame: .zero)
        label.stringValue = name
        label.font = .systemFont(ofSize: 10, weight: .medium)
        // Secondary rather than tertiary. These sit on a header material, and at
        // tertiary "Them" was legible on the mock and not on the window, which
        // matters more here than for most labels: the whole diagnosis is reading
        // which of the two names is beside the flat strip.
        label.textColor = .secondaryLabelColor
        addSubview(label)
        meter.tint = tint
        addSubview(meter)
    }

    required init?(coder: NSCoder) { fatalError("not in a nib") }

    var isSilent: Bool {
        get { meter.isSilent }
        set {
            meter.isSilent = newValue
            label.textColor = newValue ? .systemOrange : .secondaryLabelColor
        }
    }

    override func layout() {
        super.layout()
        label.sizeToFit()
        let w = TrackMeter.labelWidth
        label.frame = NSRect(x: 0, y: (bounds.height - label.frame.height) / 2,
                             width: w, height: label.frame.height)
        meter.frame = NSRect(x: w + 8, y: 0,
                             width: max(0, bounds.width - w - 8), height: bounds.height)
    }
}
