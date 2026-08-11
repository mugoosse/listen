import AppKit

/// Every meter style at once, on one microphone, so they can be compared.
///
/// Ported from Speak's `--hud-demo`, and it exists because "is this better" is a
/// question about a moving thing. It cannot be answered from a screenshot, or
/// from memory of the build before last, so the styles have to be side by side
/// and running off the same audio.
///
/// `.pulse` is in the list and deliberately not improved. It is the thing the
/// other two replaced, and a comparison against a version that has quietly been
/// brought up to date is not a comparison.
///
/// Reached through `LISTEN_PANEL=dictation-demo`, which is the same family as
/// every other preview affordance: an environment variable, so a Finder launch
/// inherits no shell and can never see it, and nothing in the app can set it by
/// accident. Add `:fake` to drive it from a synthetic speech envelope instead of
/// the microphone, which is the only way to watch the handover from recording to
/// transcribing: a real transcription is over before you have looked down.
@MainActor
final class DictationHUDDemo {
    private var pills: [DictationHUD] = []
    private let recorder = DictationRecorder()
    private var clock: Timer?
    private var elapsed: Double = 0
    private let fake: Bool

    init(fake: Bool) {
        self.fake = fake
    }

    func run() {
        // Stacked bottom up in the order they are listed, 64 points apart, which
        // is the pill height plus enough air to read each one as its own object.
        for (i, style) in MeterStyle.allCases.enumerated() {
            let pill = DictationHUD(style: style)
            pill.bottomInset = 90 + CGFloat(i) * 64
            pill.caption = style.title
            pill.show(.recording)
            pills.append(pill)
        }

        if fake {
            startFakeAudio()
        } else {
            startRealAudio()
        }
        startStateCycle()
    }

    /// One microphone into every pill, so a difference on screen is a difference
    /// in the style rather than in what each was hearing.
    private func startRealAudio() {
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.pills.forEach { $0.level(level) }
                }
            }
        }
        do {
            try recorder.start()
        } catch {
            log("demo could not open the microphone: \(error). Try :fake.")
        }
    }

    /// `FakeSpeech` rather than a sine wave, and it is Listen's own, shared with
    /// the recording panel's preview so the two are judged against the same
    /// movement. A sine exercises neither the envelope's attack nor its release,
    /// and the gaps speech has inside every word are the whole reason the
    /// envelope rises fast and falls slowly.
    private func startFakeAudio() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed += 1.0 / 30.0
                let level = FakeSpeech.level(self.elapsed)
                self.pills.forEach { $0.level(level) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    /// Recording for eight seconds, then transcribing for four, then round
    /// again. The handover is the part worth watching and the part no real
    /// dictation gives you time to see.
    private func startStateCycle() {
        var recording = true
        let t = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                recording.toggle()
                let state: DictationHUD.State =
                    recording ? .recording : .polishing(step: 1, of: 2)
                self.pills.forEach { $0.show(state) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }
}
