import AppKit

/// The scrubber: the recording drawn as bars, played part filled, click or drag
/// anywhere to move the playhead.
///
/// A waveform rather than a slider because a meeting is not uniform. Silence,
/// one person talking and everybody talking at once look different from each
/// other, and that is most of what somebody scrubbing an hour-long recording is
/// actually looking for.
@MainActor
final class WaveformView: NSView {
    /// Normalised 0...1, at `Waveform.resolution`. Resampled to the bars that
    /// fit the current width.
    var peaks: [Float] = [] {
        didSet { bars = []; needsDisplay = true }
    }

    /// How far through, 0...1.
    var progress: Double = 0 {
        didSet {
            // The playhead moves twenty times a second. Redrawing when it has
            // not moved half a pixel is work with nothing to show for it.
            // Measured against the last value *drawn* rather than the last one
            // set: an hour-long recording advances a hundredth of a pixel per
            // tick, and comparing consecutive ticks would round every one of
            // them away and freeze the playhead.
            guard abs(progress - drawn) * Double(bounds.width) >= 0.5 else { return }
            drawn = progress
            needsDisplay = true
        }
    }
    private var drawn: Double = -1

    /// Total length. The hover readout, and the clock the speaker spans are
    /// read against.
    var duration: Double = 0

    /// Who is talking when, so the played part can be drawn in their colours
    /// rather than in one accent.
    ///
    /// The turns of the transcript, unchanged: nothing here re-derives them, so
    /// a bar cannot claim a speaker the paragraph below it does not. Empty for
    /// a recording with no transcript yet, which keeps the single accent fill
    /// the player has always had rather than colouring an hour of audio after a
    /// speaker nobody has identified.
    var spans: [(start: Double, end: Double, speaker: String)] = [] {
        didSet { needsDisplay = true }
    }

    /// Fires continuously while scrubbing, with a fraction of the whole.
    var onScrub: ((Double) -> Void)?

    /// Bar geometry. Three points of pitch keeps the bars distinct at this
    /// height without turning an hour into a grey block.
    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 1
    private var bars: [Float] = []
    private var hover: CGFloat?
    private var tracking: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    // MARK: - Resampling

    /// Reduce the stored peaks to one value per bar, taking the maximum.
    ///
    /// The maximum and not the mean: averaging a bucket of speech against the
    /// pauses around it flattens exactly the difference the picture exists to
    /// show.
    private func rebuild() {
        let count = max(1, Int(bounds.width / (barWidth + barGap)))
        guard !peaks.isEmpty else { bars = []; return }
        bars = (0..<count).map { i in
            let from = i * peaks.count / count
            let to = max(from + 1, (i + 1) * peaks.count / count)
            return peaks[from..<min(to, peaks.count)].max() ?? 0
        }
    }

    override func layout() {
        super.layout()
        bars = []
        drawn = -1
        needsDisplay = true
        if tracking == nil || tracking!.rect != bounds {
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }
    }

    // MARK: - Drawing

    override func draw(_ dirty: NSRect) {
        if bars.isEmpty { rebuild() }
        guard !bars.isEmpty else { return }

        let pitch = barWidth + barGap
        let middle = bounds.midY
        // A recording is never all peaks, and a bar of zero height leaves a gap
        // that reads as damage rather than as silence. Silence draws as a line
        // of dots along the middle.
        let minimum: CGFloat = 2
        let usable = bounds.height - minimum

        var rects: [NSRect] = []
        let path = NSBezierPath()
        for (i, value) in bars.enumerated() {
            let x = CGFloat(i) * pitch
            guard x < bounds.width else { break }
            let height = minimum + CGFloat(value) * usable
            let rect = NSRect(x: x, y: middle - height / 2,
                              width: barWidth, height: height)
            rects.append(rect)
            path.appendRoundedRect(rect, xRadius: 1, yRadius: 1)
        }

        NSColor.tertiaryLabelColor.setFill()
        path.fill()

        // The played part, drawn by clipping the same shapes rather than
        // building new ones, so the two halves cannot disagree about where a bar
        // ends and the bar under the playhead is filled exactly as far as the
        // playhead has reached.
        let played = bounds.width * CGFloat(min(max(progress, 0), 1))
        if played > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: played, height: bounds.height))
                .setClip()
            for (colour, run) in runs(in: rects, upTo: played) {
                colour.setFill()
                run.fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if progress > 0 {
            NSColor.labelColor.withAlphaComponent(0.75).setFill()
            NSRect(x: played - 0.75, y: 0, width: 1.5, height: bounds.height).fill()
        }

        if let hover, hover >= 0, hover <= bounds.width {
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            NSRect(x: hover - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    /// The played bars grouped into stretches of one colour, in order.
    ///
    /// One path per stretch rather than one per bar: a two-person meeting is a
    /// few hundred bars and a few dozen stretches, and setting a fill colour per
    /// bar is the expensive half of drawing this at twenty frames a second.
    ///
    /// Called from `draw`, which is where a mixed colour has to be made: the
    /// appearance is current there, so the bars follow light and dark exactly as
    /// the names above them do.
    private func runs(in rects: [NSRect], upTo played: CGFloat) -> [(NSColor, NSBezierPath)] {
        let accent = Brand.accent
        guard !spans.isEmpty, duration > 0, bounds.width > 0 else {
            let path = NSBezierPath()
            for rect in rects where rect.minX < played {
                path.appendRoundedRect(rect, xRadius: 1, yRadius: 1)
            }
            return [(accent, path)]
        }

        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var inks: [String: NSColor] = [:]
        var out: [(NSColor, NSBezierPath)] = []
        var current: (colour: NSColor, path: NSBezierPath)?
        // The spans are in order and so are the bars, so this walks both once
        // rather than searching the turns for every bar.
        var cursor = 0

        for rect in rects where rect.minX < played {
            let time = Double(rect.midX / bounds.width) * duration
            while cursor < spans.count, spans[cursor].end <= time { cursor += 1 }
            // Nobody is talking between two turns, and a silence is not a person.
            // The same grey an unnamed speaker gets, which is the point: it says
            // played, and it says nothing about who.
            let speaker = cursor < spans.count && spans[cursor].start <= time
                ? spans[cursor].speaker : ""
            let colour = inks[speaker] ?? {
                let ink = SpeakerColour.ink(for: speaker, on: .window, dark: dark)
                inks[speaker] = ink
                return ink
            }()

            if current?.colour != colour {
                if let current { out.append((current.colour, current.path)) }
                current = (colour, NSBezierPath())
            }
            current?.path.appendRoundedRect(rect, xRadius: 1, yRadius: 1)
        }
        if let current { out.append((current.colour, current.path)) }
        return out
    }

    // MARK: - Scrubbing

    private func fraction(at point: NSPoint) -> Double {
        guard bounds.width > 0 else { return 0 }
        return min(max(Double(point.x / bounds.width), 0), 1)
    }

    /// Scrub a window that is not focused without focusing it first. Clicking a
    /// waveform means "go there", and needing two clicks to do it is the kind
    /// of thing nobody reports and everybody notices.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onScrub?(fraction(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        onScrub?(fraction(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hover = point.x
        // The tooltip is the only thing that makes the hover line mean
        // anything: a position in an hour-long recording is not readable off a
        // line on its own.
        if duration > 0 { toolTip = TranscriptFormat.stamp(fraction(at: point) * duration) }
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
