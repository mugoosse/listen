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
/// the pulse on the bar at the head, and it says "working" rather than
/// "advancing": it pulses in place and never moves the edge forward.
///
/// **The head is a position, not an area, and it is a bar rather than a line.**
/// Read and unread meet where the work has got to, with no band of half-lit bars
/// behind it and no cursor ruled through the empty space above and below. Every
/// mark in the picture is part of the waveform. See `drawHead`.
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
        //
        // The single lane is whichever track has speech, and that is not always
        // the everyone track: an import fills `everyone`, while a room
        // recording with a silent system track fills `you`. Mirroring only
        // `everyone` left a room recording's picture empty for the whole job.
        let single = max(drawnEveryone, drawnYou)
        let upper = split ? drawnEveryone : single
        let lower = split ? drawnYou : single

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
        fill(above, upTo: upperX)
        fill(below, upTo: lowerX)

        drawHead(above, at: upperX, active: upper > 0.0001 && upper < 0.9999)
        drawHead(below, at: lowerX, active: lower > 0.0001 && lower < 0.9999)

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

    /// Fill the read part of a lane, cut off exactly at `x`.
    ///
    /// **Clipped, not filtered by bar.** Selecting the bars whose left edge is
    /// behind the head means the colour can only change where a bar starts, so
    /// the boundary advances three points at a time and a fill crossing the pane
    /// takes its steps visibly. Clipping cuts the bar the head is standing in,
    /// which costs one rounded corner on one bar and buys a boundary that moves
    /// as smoothly as the number behind it.
    private func fill(_ rects: [NSRect], upTo x: CGFloat) {
        guard x > 0, !rects.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: x, height: bounds.height)).setClip()
        fill(rects)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The head: the one bar the colour is currently crossing, lit.
    ///
    /// **A position rather than an area**, which is the second try. This was a
    /// band of brightened bars about 34 points wide behind the head, and a band
    /// is read at its middle: it put the apparent value half a band short of the
    /// reported one, and what it showed was something sweeping past rather than
    /// somewhere reached. (The band itself was already the second answer to the
    /// same question. A gradient over the lane rectangle came before it and was
    /// worse still, because it paints the gaps between the bars as well as the
    /// bars, so a solid blue block sat on top of the waveform and was the first
    /// thing the eye found in the picture.) Two flat colours meeting need no
    /// interpretation: where they meet is the answer.
    ///
    /// **Inside the silhouette, and never a line across the lane.** A hair line
    /// spanning the full lane height was the version between those two, and it
    /// is a ruled mark through empty space above and below the bars: it draws
    /// the eye to a rectangle nothing is in, and it makes the picture look like
    /// a chart with a cursor on it rather than a recording being read. Lighting
    /// the bar instead keeps every mark in the picture part of the waveform.
    /// The cost is that a head passing through a silence has only a 1.5 point
    /// stub to light, which is the honest version of "there is nothing here".
    ///
    /// It pulses, and the pulse is the only thing here not driven by counted
    /// work. That is deliberate and it is the honest half of the trade: a chunk
    /// of a busy meeting takes a couple of seconds on a small Mac, and a picture
    /// that is completely still for two seconds at a time is one people
    /// reasonably read as hung. It moves in brightness, never in position, so it
    /// cannot claim progress that has not happened.
    private func drawHead(_ rects: [NSRect], at x: CGFloat, active: Bool) {
        guard active, x > 0 else { return }
        let pulse = 0.5 + 0.5 * sin(phase * 3.2)
        // Down to nearly the fill colour at the trough, so the bar visibly
        // breathes. A narrower range around a pale value is a bar that just
        // looks permanently lighter than its neighbours, which reads as a
        // drawing mistake rather than as something happening.
        let bright = Brand.accent.blended(withFraction: 0.12 + 0.5 * pulse, of: .white)
            ?? Brand.accent
        bright.setFill()
        // One pitch back from the head, so it is the bar being crossed and at
        // most the one before it. Clipped both sides: the near edge keeps the
        // light off ground the work has not reached, and it is the same cut the
        // fill under it makes, so the two cannot disagree by a pixel.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: x - (barWidth + barGap), y: 0,
                                  width: barWidth + barGap, height: bounds.height)).setClip()
        fill(rects)
        NSGraphicsContext.restoreGraphicsState()
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
