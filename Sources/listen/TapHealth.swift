import Foundation

/// Whether the far-end track is being captured, or only looks like it is.
///
/// This exists because of a measured failure on 2026-09-01: three consecutive
/// Google Meet calls where the process tap delivered bit-exact zero for most of
/// the meeting and torn audio for the rest, while the microphone track recorded
/// perfectly and the app said nothing. The far side was audible to the user
/// throughout. Twenty-one of thirty-eight minutes of one call have no far-end
/// audio at all, and the transcript lost the other person's half of the
/// conversation with no warning anywhere.
///
/// `SystemAudioRecorder` deliberately has no silence detector, and the reasoning
/// beside `onLevel` is still correct: bit-exact zero from a tap is the ordinary
/// state of a Mac with nothing playing, so "the track is quiet" says nothing.
/// What that reasoning missed is that **zero interleaved with signal inside one
/// 10 ms window is not ordinary**, and that is a different question with a
/// certain answer.
enum TapHealth {
    /// The tap's frames are 10 ms on every Mac measured, and the damage lands
    /// inside one: on 2026-09-01 the far end lost 39 samples of every 160 at
    /// 16 kHz, on an exact 160-sample grid, for 21 seconds either side of the
    /// point the voice became unintelligible.
    static let windowSeconds = 0.010

    /// Below this a sample is not signal. The same floor `SystemAudioRecorder`
    /// already uses for `sawAudio`, so the two cannot disagree about whether a
    /// buffer carried anything.
    static let signalFloor: Float = 0.0001

    /// A window with this many bit-exact zeros is not audio with quiet parts.
    /// A resampler does not emit exact zeros, and neither does any codec: this
    /// only happens when an IO proc misses its deadline and part of the buffer
    /// is zero-filled underneath it.
    static let tornZeroFraction = 0.10

    // -----------------------------------------------------------------------

    /// Torn windows in one batch of samples, and how many carried any signal.
    ///
    /// **The edge test is what makes this safe.** A window straddling the
    /// instant speech starts is half zeros and half signal, which looks exactly
    /// like damage, and a far side using DTX crosses that boundary every time
    /// the other person pauses. So a window only counts as torn when it carries
    /// signal in *both* its first and last quarter and holes in between: an
    /// onset has nothing in the first quarter, an offset nothing in the last.
    ///
    /// Measured over every recording in the library on 2026-09-01: 0 torn
    /// windows across six healthy calls totalling four hours (two Telegram, two
    /// WhatsApp, one Discord, one Chrome), against 328 to 2866 on the three
    /// broken ones. No threshold in here was guessed.
    /// **Scanned at two phases, and the worse answer wins.** Holes that happen
    /// to land on the window grid look exactly like an onset, so a single phase
    /// can miss damage entirely depending on where the batch boundary fell.
    /// That is not hypothetical: it is what the first live test of this code
    /// did, catching 96.6% of injected tearing when the file was scanned
    /// afterwards and none of it as the audio arrived. Half a window of offset
    /// puts any aligned hole in the middle of the other pass's window.
    static func scan(_ samples: [Float], sampleRate: Double) -> Counts {
        let width = max(16, Int(sampleRate * windowSeconds))
        guard samples.count >= width else { return Counts() }
        let aligned = scan(samples, sampleRate: sampleRate, from: 0)
        let offset = scan(samples, sampleRate: sampleRate, from: width / 2)
        return offset.torn > aligned.torn ? offset : aligned
    }

    private static func scan(_ samples: [Float], sampleRate: Double,
                             from first: Int) -> Counts {
        let width = max(16, Int(sampleRate * windowSeconds))
        guard samples.count >= first + width else { return Counts() }
        let quarter = max(1, width / 4)
        var counts = Counts()

        var start = first
        while start + width <= samples.count {
            let window = samples[start..<(start + width)]
            var zeros = 0
            var signal = false
            for value in window {
                if value == 0 { zeros += 1 }
                else if abs(value) > signalFloor { signal = true }
            }
            if signal {
                counts.withSignal += 1
                let head = samples[start..<(start + quarter)]
                let tail = samples[(start + width - quarter)..<(start + width)]
                let bothEnds = head.contains { abs($0) > signalFloor }
                    && tail.contains { abs($0) > signalFloor }
                if bothEnds, Double(zeros) / Double(width) >= tornZeroFraction {
                    counts.torn += 1
                }
            }
            counts.total += 1
            start += width
        }
        return counts
    }

    struct Counts {
        var total = 0
        var withSignal = 0
        var torn = 0

        /// Torn as a share of the windows that carried anything, which is the
        /// only denominator that means something: a track that is 90% silence
        /// would otherwise read as healthy however badly its speech is cut up.
        var tornShare: Double {
            withSignal == 0 ? 0 : Double(torn) / Double(withSignal)
        }
    }

    // -----------------------------------------------------------------------

    /// Rolling health of a live tap, fed one converted batch at a time.
    ///
    /// Not an actor and not locked: `SystemAudioRecorder` only ever touches this
    /// from `flush()`, which runs on its own serial queue, and the values read
    /// out of it are plain copies.
    final class Monitor {
        /// Two seconds of history. Long enough that one speech onset cannot
        /// dominate the rate, short enough that the panel says "now".
        private let historySeconds: TimeInterval = 2

        /// A tap that tore this much of what it was carrying is starved. A
        /// clean recording scores exactly zero, so this only has to sit above
        /// nothing; it is set at 20% so that a single odd window in a quiet
        /// batch cannot raise the alarm on its own.
        private let tornThreshold = 0.20

        private var history: [(at: Date, counts: Counts)] = []
        private(set) var lastSignal: Date?
        private(set) var startedAt = Date()

        func reset() {
            history.removeAll()
            lastSignal = nil
            startedAt = Date()
        }

        func feed(_ samples: [Float], sampleRate: Double, now: Date = Date()) {
            let counts = scan(samples, sampleRate: sampleRate)
            if counts.withSignal > 0 { lastSignal = now }
            history.append((now, counts))
            let cutoff = now.addingTimeInterval(-historySeconds)
            history.removeAll { $0.at < cutoff }
        }

        /// True while the tap is delivering audio with holes punched through it.
        var isTorn: Bool {
            var total = Counts()
            for entry in history {
                total.total += entry.counts.total
                total.withSignal += entry.counts.withSignal
                total.torn += entry.counts.torn
            }
            // A handful of windows is not a rate. Ten windows with signal is a
            // tenth of a second of speech, which is the least that can carry a
            // meaningful share.
            guard total.withSignal >= 10 else { return false }
            return total.tornShare >= tornThreshold
        }

        /// How long the far end has been bit-exact zero, counting from the
        /// start of capture when it has never carried anything at all.
        func deafFor(_ now: Date = Date()) -> TimeInterval {
            now.timeIntervalSince(lastSignal ?? startedAt)
        }
    }

    // -----------------------------------------------------------------------

    /// Speech on the microphone track, as RMS over one second. About -42 dBFS,
    /// the floor the deafness test was calibrated against.
    static let speechFloor = 0.0079

    /// Seconds of far-end silence that need explaining, and how much of your
    /// own voice inside one makes it damage rather than a lull. The same two
    /// numbers `Capture` warns on, kept here so the report and the live warning
    /// cannot disagree about what counts as broken.
    static let deadThresholdSeconds = 45.0
    static let deadSpeechSeconds = 5.0

    /// One finished track, for `listen audio --check`.
    struct Report {
        var seconds = 0.0
        var signalSeconds = 0.0
        var tornSeconds = 0.0
        /// Every run of bit-exact zero over the threshold, with the seconds of
        /// your own voice inside it.
        var deadRuns: [(at: Double, seconds: Double, speech: Double)] = []
        var counts = Counts()

        /// The runs that mean something. A long silence you talked through is
        /// audio that was lost; one you did not is the head of a recording,
        /// which is what both of the library's benign cases turned out to be.
        var lostRuns: [(at: Double, seconds: Double, speech: Double)] {
            deadRuns.filter { $0.speech >= TapHealth.deadSpeechSeconds }
        }

        /// How bad, rather than whether. A binary test was wrong in both
        /// directions: `torn == 0` called a healthy 300 second control broken
        /// over a single window at 00:00.23, which is the tap starting up, and
        /// it gave the same verdict to that as to a call that lost 30 seconds.
        ///
        /// The bands are measured. Six healthy library recordings score 0.
        /// A fresh healthy control scored 1 window, 0.003%. A Bluetooth route
        /// reproducing the fault under load scored 22 windows, 0.1%, in two
        /// bursts. The three lost meetings scored 2.2%, 7.3% and 8.9%.
        enum Verdict { case intact, minor, lost }

        var verdict: Verdict {
            if !lostRuns.isEmpty { return .lost }
            let share = counts.tornShare
            if share >= 0.01 { return .lost }
            if share >= 0.0005 { return .minor }
            return .intact
        }

        var healthy: Bool { verdict == .intact }
    }

    /// Whole-track scan. Pass the microphone track as `against` to get the
    /// deafness gate: without it every dead run is reported, including the
    /// lead-in before anybody spoke.
    static func report(track samples: [Float], sampleRate: Double,
                       against mic: [Float]? = nil,
                       deadThreshold: Double = deadThresholdSeconds) -> Report {
        var report = Report()
        report.seconds = Double(samples.count) / sampleRate
        report.counts = scan(samples, sampleRate: sampleRate)
        report.signalSeconds = Double(report.counts.withSignal) * windowSeconds
        report.tornSeconds = Double(report.counts.torn) * windowSeconds

        var runStart: Int?
        for index in 0...samples.count {
            let isZero = index < samples.count && samples[index] == 0
            if isZero, runStart == nil { runStart = index }
            if !isZero, let start = runStart {
                let seconds = Double(index - start) / sampleRate
                if seconds >= deadThreshold {
                    report.deadRuns.append((Double(start) / sampleRate, seconds,
                                            speechSeconds(in: mic, sampleRate: sampleRate,
                                                          from: start, to: index)))
                }
                runStart = nil
            }
        }
        return report
    }

    /// Seconds of speech on `mic` between two sample offsets of the far-end
    /// track. The two tracks share a zero by construction, which is what makes
    /// comparing offsets across them legitimate: see `WAVWriter.pad(to:)`.
    private static func speechSeconds(in mic: [Float]?, sampleRate: Double,
                                      from: Int, to end: Int) -> Double {
        guard let mic, !mic.isEmpty else { return 0 }
        let width = Int(sampleRate)
        var seconds = 0.0
        var start = from
        while start + width <= min(end, mic.count) {
            var sum = 0.0
            for index in start..<(start + width) {
                let value = Double(mic[index])
                sum += value * value
            }
            if (sum / Double(width)).squareRoot() > speechFloor { seconds += 1 }
            start += width
        }
        return seconds
    }

    /// Read a Float32 WAV written by `WAVWriter`.
    ///
    /// `AudioFile.inspect` cannot be reused: it reads the Int16 files the sync
    /// pipeline makes, and the capture tracks are Float32.
    static func readFloatTrack(_ url: URL) -> (samples: [Float], sampleRate: Double)? {
        guard let data = try? Data(contentsOf: url), data.count > 44,
              data[0..<4].elementsEqual(Array("RIFF".utf8)) else { return nil }
        func u32(_ offset: Int) -> Int {
            Int(UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24)
        }
        var rate = 0.0
        var offset = 12
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            if id == "fmt " { rate = Double(u32(offset + 12)) }
            if id == "data" {
                let end = min(offset + 8 + size, data.count)
                let bytes = data[(offset + 8)..<end]
                let samples = bytes.withUnsafeBytes { raw -> [Float] in
                    Array(raw.bindMemory(to: Float.self))
                }
                guard rate > 0 else { return nil }
                return (samples, rate)
            }
            offset += 8 + size + (size % 2)
        }
        return nil
    }
}
