import AppKit

/// The meeting being read, drawn as it happens.
///
/// This fills the pane that used to hold one grey sentence saying "Transcribing"
/// while an hour of audio went through the model with nothing to look at. The
/// waveform is the same envelope the scrubber below it draws, so what is being
/// worked through is visibly *this* recording rather than a generic bar.
///
/// **Two lanes, because there are two tracks.** Listen captures everybody else
/// through a process tap and the user through the microphone, transcribes them
/// separately, and merges them by time. So the upper half is the far side of the
/// call and the lower half is you, each filling during its own pass, and at the
/// end both are full. A single bar would have had to sweep twice and reset in
/// the middle, which reads as starting over. An imported recording has one mixed
/// track and gets one lane, for the same reason: the picture says what the job
/// actually is.
///
/// Nothing here is an estimate. The fill is pieces decoded over pieces to
/// decode, so on a slower Mac it simply moves more slowly, which is the honest
/// form of that information. The one thing that moves without new information is
/// the glow at the head of the fill, and it says "working" rather than
/// "advancing": it pulses in place and never moves the edge forward.
@MainActor
final class TranscribingView: NSView {
    /// The recording's envelope, as stored. Empty draws the lanes flat, which
    /// is right for a recording whose waveform has not been computed yet.
    var peaks: [Float] = [] {
        didSet { bars = []; needsDisplay = true }
    }

    /// What the pipeline last reported. nil stops the animation.
    var progress: TranscriptionProgress? {
        didSet {
            guard let progress else { stopTicking(); return }
            message.stringValue = progress.message.prefix(1).uppercased()
                + progress.message.dropFirst()
            percent.stringValue = "\(Int((progress.overall * 100).rounded()))%"
            startTicking()
            needsDisplay = true
        }
    }

    private let message = NSTextField(labelWithString: "")
    private let percent = NSTextField(labelWithString: "")

    /// The one thing somebody watching this needs to be told, which is that
    /// they do not have to watch it. It lives here rather than in the pane's
    /// own empty label because that label is centred where the picture is, and
    /// the two cannot share the middle of the pane.
    private let hint = NSTextField(labelWithString: "This stays here if you quit.")

    /// Where the fill is drawn, which chases where it has been reported to be.
    ///
    /// A piece takes a second or two, so the reported fraction arrives in steps
    /// and a bar that jumped would spend most of its life still. This eases
    /// toward the target and therefore always shows **at most** what has been
    /// reported: it lags the truth and never leads it, which is the only
    /// direction a progress bar is allowed to be wrong in.
    private var drawnEveryone: Double = 0
    private var drawnYou: Double = 0
    private var phase: Double = 0
    private var ticker: Timer?

    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 1
    private var bars: [Float] = []

    /// Half the height of one lane's bars, so the pair fills `laneHeight * 2`
    /// around the middle line.
    private let laneHeight: CGFloat = 38

    /// The channel down the middle. Wide enough that two lanes read as two:
    /// at 2 points each side they closed up into one mirrored waveform, which
    /// is a picture of one track rather than of the two there are.
    private let laneGap: CGFloat = 5
    private let labelGap: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // Away until somebody says otherwise. `updateEmpty` owns this, and it
        // returns early when no recording is selected, so a view that started
        // visible drew its lane captions and two flat grey lanes across the
        // "Select a recording" page of a freshly launched window. Found in the
        // first offscreen shot, which is the argument for taking them.
        isHidden = true

        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byTruncatingTail
        // Monospaced digits, so a percentage counting up does not shuffle the
        // words beside it sideways on every change.
        percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        percent.textColor = .tertiaryLabelColor

        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        for label in [message, percent, hint] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        // Below the lower lane and the caption under it, which are drawn rather
        // than laid out, so the offset is stated from the middle: the channel,
        // half a lane, the caption gap, the caption, and a line of air.
        //
        // A positive constant on a y anchor is *downwards* in Auto Layout
        // whichever way the view is flipped, which is the opposite of the y that
        // `draw` uses a few lines below. Getting that backwards put the sentence
        // above the picture with the caption wedged between them.
        NSLayoutConstraint.activate([
            message.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -18),
            message.topAnchor.constraint(equalTo: centerYAnchor,
                                         constant: laneGap + laneHeight + labelGap + 26),
            percent.leadingAnchor.constraint(equalTo: message.trailingAnchor, constant: 10),
            percent.firstBaselineAnchor.constraint(equalTo: message.firstBaselineAnchor),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    deinit { ticker?.invalidate() }

    // MARK: - Ticking

    /// Thirty a second while a job is running, and nothing at all when one is
    /// not. The pane is on screen for as long as the library is open, so a timer
    /// left running would be a redraw of an idle window for ever.
    private func startTicking() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A modal run loop mode as well, so the picture keeps moving while a
        // menu is open or the divider is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
        drawnEveryone = 0
        drawnYou = 0
        needsDisplay = true
    }

    private func tick() {
        guard let progress, window != nil, !isHiddenOrHasHiddenAncestor else { return }
        // A fifth of the remaining gap per frame: fast enough to arrive within
        // about a fifth of a second, slow enough to read as movement.
        drawnEveryone += (progress.everyone - drawnEveryone) * 0.2
        drawnYou += (progress.you - drawnYou) * 0.2
        phase += 1.0 / 30
        needsDisplay = true
    }

    // MARK: - Drawing

    override func layout() {
        super.layout()
        bars = []
        needsDisplay = true
    }

    override func draw(_ dirty: NSRect) {
        let split = progress?.split ?? true
        let width = bounds.width
        guard width > 0 else { return }

        if bars.isEmpty {
            bars = Waveform.resample(peaks, to: max(1, Int(width / (barWidth + barGap))))
        }

        let middle = bounds.midY
        // A recording is never all peaks, and a bar of no height leaves a gap
        // that reads as damage rather than as silence. The same minimum the
        // scrubber uses, halved, because these bars are drawn one way from the
        // middle rather than centred on it.
        let minimum: CGFloat = 1.5
        let usable = laneHeight - minimum

        // Two lanes, or one lane drawn both ways from the middle. The mixed
        // track of an imported recording is everybody at once, so splitting it
        // into a side that is you and a side that is not would be a picture of
        // something that is not there.
        let upper = drawnEveryone
        let lower = split ? drawnYou : drawnEveryone

        var above: [NSRect] = []
        var below: [NSRect] = []
        let pitch = barWidth + barGap
        for (i, value) in bars.enumerated() {
            let x = CGFloat(i) * pitch
            guard x < width else { break }
            let height = minimum + CGFloat(value) * usable
            above.append(NSRect(x: x, y: middle + laneGap,
                                width: barWidth, height: height))
            below.append(NSRect(x: x, y: middle - laneGap - height,
                                width: barWidth, height: height))
        }

        // `tertiaryLabelColor` as it comes, not with an alpha of its own.
        // `withAlphaComponent` **replaces** the alpha rather than scaling it,
        // and this colour is already about 0.25, so asking for 0.35 to make the
        // unfilled part quieter made it brighter than the scrubber's bars and
        // the loudest thing in the picture was the half not done yet.
        NSColor.tertiaryLabelColor.setFill()
        fill(above + below)

        let upperX = width * CGFloat(min(max(upper, 0), 1))
        let lowerX = width * CGFloat(min(max(lower, 0), 1))
        Brand.accent.setFill()
        fill(above.filter { $0.minX < upperX })
        fill(below.filter { $0.minX < lowerX })

        drawEdge(above, upTo: upperX, active: upper > 0.0001 && upper < 0.9999,
                 top: middle + laneGap + laneHeight, bottom: middle + laneGap)
        drawEdge(below, upTo: lowerX, active: lower > 0.0001 && lower < 0.9999,
                 top: middle - laneGap, bottom: middle - laneGap - laneHeight)

        // Named, because two mirrored halves are only obvious once somebody has
        // been told what they are, and being told is one line of 11 point type.
        caption(split ? "Everyone else" : "The meeting",
                atTop: true, done: upper >= 0.9999)
        if split { caption("You", atTop: false, done: lower >= 0.9999) }
    }

    private func fill(_ rects: [NSRect]) {
        guard !rects.isEmpty else { return }
        let path = NSBezierPath()
        for rect in rects { path.appendRoundedRect(rect, xRadius: 1, yRadius: 1) }
        path.fill()
    }

    /// The working edge: the bars just behind the head, brightened, and a hair
    /// line at the head itself.
    ///
    /// **Brightened bars rather than a gradient over the rectangle they sit
    /// in**, which is what this was first. A gradient across the lane paints the
    /// gaps between the bars as well as the bars, so it came out as a solid blue
    /// block sitting on top of the waveform, and the block was the first thing
    /// the eye found in the whole picture. Tinting the bars keeps the silhouette,
    /// which is what the picture is made of.
    ///
    /// It pulses, and the pulse is the only thing here not driven by counted
    /// work. That is deliberate and it is the honest half of the trade: a chunk
    /// of a busy meeting takes a couple of seconds on a small Mac, and a picture
    /// that is completely still for two seconds at a time is one people
    /// reasonably read as hung. It moves in brightness, never in position, so it
    /// cannot claim progress that has not happened.
    private func drawEdge(_ rects: [NSRect], upTo x: CGFloat, active: Bool,
                          top: CGFloat, bottom: CGFloat) {
        guard active, x > 0 else { return }
        let pulse = 0.5 + 0.5 * sin(phase * 3.2)
        let bright = Brand.accent.blended(withFraction: 0.2 + 0.35 * pulse, of: .white)
            ?? Brand.accent
        bright.setFill()
        fill(rects.filter { $0.minX < x && $0.minX > x - 34 })
        bright.withAlphaComponent(0.55).setFill()
        NSRect(x: x - 0.5, y: bottom, width: 1, height: top - bottom).fill()
    }

    private func caption(_ text: String, atTop: Bool, done: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: done ? Brand.accent.withAlphaComponent(0.9)
                                   : NSColor.tertiaryLabelColor,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let y = atTop ? bounds.midY + laneGap + laneHeight + labelGap
                      : bounds.midY - laneGap - laneHeight - labelGap - size.height
        string.draw(at: NSPoint(x: 0, y: y))
    }
}
