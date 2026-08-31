import AppKit
import Carbon.HIToolbox

/// Push-to-talk dictation: press the chord, talk, press it again, and the words
/// land wherever the caret is.
///
/// This is Speak (https://mugoosse.github.io/speak/) inside Listen. The two
/// apps shared a microphone, a model, a dictionary and a build system, and the
/// only thing dictation ever needed that meeting recording did not is a global
/// shortcut and a way to type. Both are here.
///
/// The controller owns the state machine and nothing else: the chord is
/// `DictationHotkey`, the microphone is `DictationRecorder` or a tap on the
/// meeting's own, and the words come from `DictationEngine`.
@MainActor
final class Dictation {
    static let shared = Dictation()

    /// `starting` is the device being opened, which is not instant and on a
    /// faulty microphone is not close to it. It is a phase of its own rather
    /// than an early `recording` because the two answer different questions:
    /// the microphone is not live yet, and nothing may claim it is.
    enum Phase { case idle, starting, recording, transcribing }
    private(set) var phase: Phase = .idle

    /// The chord came again, or Escape did, while the device was still opening.
    /// The open cannot be called off, so it is allowed to finish and then hands
    /// the device straight back.
    private var startCancelled = false

    /// Puts the pill up if the open runs long. Cancelled by every exit from
    /// `starting`, so a fast open never shows anything at all.
    private var slowStartNotice: Timer?

    /// Longer than any healthy device takes to open, and far short of a broken
    /// one. Measured on one Mac: 25 ms on a USB microphone, 50 ms on the
    /// built-in, 65 ms on a webcam's, against a repeatable 5.1 s on a USB
    /// microphone that had wedged. Bluetooth sits between the two, and
    /// `.agents/notes/dictation.md` puts its profile switch at past a second,
    /// so this clears that as well.
    private static let slowOpen: TimeInterval = 1.5

    private let hotkey = DictationHotkey()
    private let recorder = DictationRecorder()
    private let engine = DictationEngine()
    private let hud = DictationHUD()

    /// Where samples go while dictating during a meeting. See
    /// `Capture.beginDictationTap`.
    private var tapping = false
    private let tapped = SampleBuffer()

    /// Somewhere for the audio thread to put samples that is not the main actor.
    ///
    /// A lock and not an actor: `MicRecorder.onSamples` fires on the render
    /// thread, which cannot await, and hopping to the main actor per buffer
    /// would put a dictation's audio behind whatever the window is drawing.
    /// `@unchecked Sendable` is the honest label for that, and the lock is what
    /// earns it.
    private final class SampleBuffer: @unchecked Sendable {
        private var samples: [Float] = []
        private let lock = NSLock()

        func append(_ chunk: [Float]) {
            lock.lock(); samples.append(contentsOf: chunk); lock.unlock()
        }

        func drain() -> [Float] {
            lock.lock(); defer { lock.unlock() }
            let out = samples
            samples.removeAll()
            return out
        }
    }

    /// True once the weights are resident, mirrored onto the main actor so the
    /// shortcut can answer without awaiting the engine. A dictation that has to
    /// wait for an actor hop before deciding whether it can run is a dictation
    /// that opens the microphone late.
    private(set) var isReady = false

    /// Set when the microphone refuses to start, cleared by the next dictation
    /// that works. Separate from the model state, which is about the weights.
    private(set) var micError: String?

    /// Fires whenever anything above changes, so the menu bar can follow without
    /// polling. Same shape as `Capture.onChange`.
    var onChange: (() -> Void)?

    /// Called with each finished transcript, nil when nothing was heard. Setup's
    /// try-it-out step listens here, so the user sees their own words rather
    /// than being told it worked.
    var onTranscript: ((String?) -> Void)?

    var isEnabled: Bool { Settings.dictationEnabled }

    /// What the shortcut is, for anything that has to name it on screen.
    var shortcutDescription: String { DictationShortcut.description }

    var hotkeyInstalled: Bool { hotkey.isInstalled }

    private init() {
        hotkey.onToggle = { [weak self] in self?.toggle() }
        // The pill's trash button, which is the only way out when another app
        // holds secure input and the Escape keystroke never reaches the tap.
        hud.onCancel = { [weak self] in self?.cancel() }
        // Off the audio thread, and in order. `DispatchQueue.main.async` and
        // never `Task {}`: the waveform is a queue, so a reordered sample is a
        // bar drawn in the wrong place, and independent Tasks have no ordering
        // guarantee. Same trap as the event tap, and as `Capture`'s own levels.
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.hud.level(level) }
            }
        }
        hotkey.onEscape = { [weak self] in
            // Only while a dictation is up, which includes the microphone still
            // opening: on a slow device that is seconds long, and Escape has to
            // mean the same thing there as it does a moment later. Swallowing
            // Escape at any other time would break every dialog and every
            // editor on the Mac, for a feature that is not even running.
            guard let self, self.phase == .recording || self.phase == .starting
            else { return false }
            self.cancel()
            return true
        }
    }

    // MARK: - Lifecycle

    /// Arm the shortcut and warm the model, if the user wants dictation and has
    /// granted what it needs.
    ///
    /// Safe to call more than once, and called on launch and whenever the
    /// setting changes.
    func activate() {
        guard Settings.dictationEnabled else {
            hotkey.uninstall()
            onChange?()
            return
        }
        if !hotkey.installIfPermitted() {
            // Granted in System Settings, minutes from now, in another app. The
            // watch is what turns that into a working shortcut without a
            // relaunch.
            hotkey.watchForAccessibility()
        }
        prewarm()
        onChange?()
    }

    /// Load the speech model before anybody presses anything.
    ///
    /// Never downloads: `DictationEngine.prepare` refuses unless the weights are
    /// already on disk. Somebody who has not chosen a model in Settings, Models
    /// has not agreed to 2.5 GB, and switching dictation on is not that
    /// agreement.
    func prewarm() {
        guard Settings.dictationEnabled else { return }
        // The polish model costs about 50 seconds the first time on any Mac, so
        // doing it here means that is spent while nobody is waiting rather than
        // between somebody letting go of the key and their words appearing.
        // Separate from the speech engine because it is a separate model and
        // either can be unavailable without the other.
        Task {
            CustomDictionary.warm()
            await Polisher.shared.prewarm()
        }

        guard !isReady else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.engine.prepare()
            } catch {
                log("dictation model failed to load: \(error)")
            }
            let ready = await self.engine.isReady
            self.isReady = ready
            self.onChange?()
        }
    }

    /// The model changed in Settings, so drop what was warmed.
    func modelChanged() {
        isReady = false
        Task { [weak self] in
            guard let self else { return }
            await self.engine.invalidate()
            self.prewarm()
        }
    }

    /// Let Settings capture a replacement chord without it also dictating.
    func beginRecordingShortcut(_ capture: @escaping (CGEventFlags, Int?) -> Void) {
        hotkey.recorder = capture
    }

    func endRecordingShortcut() {
        hotkey.recorder = nil
    }

    // MARK: - The dictation itself

    func toggle() {
        switch phase {
        case .recording:    finish()
        case .starting:     abandonStart()
        case .transcribing: break      // still working on the last one
        case .idle:         begin()
        }
    }

    private func begin() {
        guard isReady else {
            // A beep rather than a message. There is no window in front of the
            // user to put one in, and the state is temporary: the model is
            // loading, or no model has been chosen yet, and the menu bar says
            // which.
            NSSound.beep()
            prewarm()
            return
        }

        // Dictating while a meeting is being recorded listens in on the track
        // that recording already has, rather than opening a second unit on a
        // device it holds. The consequence is honest and stated in Settings:
        // what you dictate is also in the meeting's microphone track, because it
        // is your voice in the room.
        _ = tapped.drain()
        let buffer = tapped
        tapping = Capture.shared.beginDictationTap { buffer.append($0) }
        if tapping {
            micError = nil
            phase = .recording
            // No waiting for a first buffer here. The meeting's microphone has
            // been open and delivering for however long the call has run, so it
            // is live by definition and there is no profile switch to sit
            // through. The levels come from `Capture`, which already hops them
            // to the main actor in order for its own strips.
            Capture.shared.addLevelSink(self) { [weak self] track, level in
                guard track == .you else { return }
                self?.hud.level(level)
            }
            // Said straight out, not through `announceLive`: there is no open
            // to race, because the meeting's microphone has been delivering for
            // however long the call has run. The flag keeps the invariant that
            // `live()` is said once per dictation.
            announcedLive = true
            live()
            trace("dictating into a running recording")
            onChange?()
            return
        }

        // Tied to the first audio buffer, not to this line: it has to mean "the
        // microphone is live", and the device takes a moment. Over Bluetooth
        // that moment is the profile switch to HFP, which can run past a
        // second, and firing on `start()` returning instead told the user to
        // talk before the mic could hear them. If another app is holding the
        // device this never fires, which is the truthful outcome.
        //
        // Re-checks the phase because it arrives from the audio thread and the
        // chord may already be back up by the time it reaches the main actor,
        // in which case the state has moved on to transcribing and must not be
        // stomped back to recording.
        recorder.onFirstBuffer = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.firstBufferSeen = true
                self.announceLive()
            }
        }

        // Opened off the main thread, and never inline here. This runs inside
        // the `CGEventTap` callback, and an active tap holds the keystroke
        // until the callback returns: opening the device here made every key on
        // the Mac wait for the microphone, and had the tap disabled for running
        // long, which silently swallowed presses. See `DictationRecorder`'s
        // `lifecycle` queue for the measurement.
        phase = .starting
        startCancelled = false
        firstBufferSeen = false
        announcedLive = false
        armSlowStartNotice()
        onChange?()

        recorder.start { [weak self] result in
            MainActor.assumeIsolated { self?.opened(result) }
        }
    }

    /// Say the microphone is still coming up, but only when it is slow enough
    /// to be worth saying.
    ///
    /// A healthy device is open in tens of milliseconds, and a pill that
    /// appeared for those would be a flash nobody can read. This is for the
    /// case that has no other symptom: a chord that looks like it did nothing,
    /// which is exactly how a wedged microphone presents.
    private func armSlowStartNotice() {
        slowStartNotice?.invalidate()
        // `.common`, so it still fires with a menu open, for the same reason
        // the Accessibility watch in `DictationHotkey` uses it.
        let timer = Timer(timeInterval: Dictation.slowOpen, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .starting, !self.startCancelled,
                      Settings.dictationShowHUD else { return }
                self.hud.show(.starting)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        slowStartNotice = timer
    }

    /// The device finished opening, one way or the other.
    private func opened(_ result: Result<TimeInterval, any Error>) {
        slowStartNotice?.invalidate()
        slowStartNotice = nil

        // Abandoned while it was opening. The dictation the user asked for no
        // longer exists, so the device goes back rather than staying open with
        // nobody listening, which on a Bluetooth headset means holding it in
        // hands-free mode for nothing.
        guard phase == .starting, !startCancelled else {
            if case .success = result { _ = recorder.stop() }
            return
        }

        switch result {
        case .success(let took):
            micError = nil
            phase = .recording
            // The buffer may already have arrived while this was still on its
            // way to the main actor, in which case this is what says so.
            announceLive()
            // Logged rather than traced, so it is in the hands of anybody
            // reporting this. A microphone that takes seconds to open is the
            // difference between "dictation is broken" and "this one device is
            // broken", and nothing else on the Mac distinguishes them.
            if took > Dictation.slowOpen {
                log(String(format: "dictation microphone took %.1fs to open", took))
            }
            // Load the polishing model and the word list while the user is still
            // talking. The first request to a cold model is the slow one, and
            // this spends time they were going to spend anyway.
            Task {
                CustomDictionary.warm()
                await Polisher.shared.prewarm()
            }
            onChange?()
        case .failure(let error):
            // The raw CoreAudio error is unreadable and names nothing the user
            // can act on, so the menu gets a sentence and the log keeps the
            // detail for a bug report.
            micError = "The microphone could not be started"
            log("dictation mic error: \(error)")
            phase = .idle
            Cue.failed()
            hud.hide()
            onChange?()
        }
    }

    /// The chord came again before the microphone was open.
    ///
    /// The phase goes back now rather than when the open lands, so the menu bar
    /// and the next press see the truth immediately. `opened` does the
    /// releasing, because the open cannot be interrupted part way through.
    private func abandonStart() {
        startCancelled = true
        slowStartNotice?.invalidate()
        slowStartNotice = nil
        phase = .idle
        hud.hide()
        Cue.cancel()
        trace("dictation abandoned while the microphone was still opening")
        onChange?()
    }

    /// Whether the device has delivered audio, and whether `live()` has already
    /// been said for this dictation.
    ///
    /// These two race, and the order is not fixed. `opened` reaches the main
    /// actor through `DispatchQueue.main.async` while the first buffer reaches
    /// it through a `Task`, and the device can deliver audio before the open
    /// has even finished returning. Guarding the buffer on `phase == .recording`
    /// alone therefore loses the announcement outright whenever the buffer wins,
    /// which is no pill and no cue for the whole dictation.
    private var firstBufferSeen = false
    private var announcedLive = false

    /// Say the microphone is live, once, as soon as both halves have landed.
    ///
    /// Still gated on `recording`, which is what keeps a dictation the user has
    /// already stopped from chiming: the phase has moved on by then, and this
    /// says nothing.
    private func announceLive() {
        guard phase == .recording, firstBufferSeen, !announcedLive else { return }
        announcedLive = true
        live()
    }

    /// The microphone is live: say so, in both channels.
    ///
    /// The cue is here rather than on the audio thread where Speak fired it, so
    /// that the sound and the pill arrive together and neither can play for a
    /// dictation that has already ended. The cost is one main-loop turn, which
    /// is not perceptible; the gain is that a chord tapped twice in quick
    /// succession no longer chimes as though it had started listening.
    private func live() {
        Cue.start()
        if Settings.dictationShowHUD { hud.show(.recording) }
    }

    private func finish() {
        guard let pcm = collect() else {
            phase = .idle
            onChange?()
            return
        }

        phase = .transcribing
        if Settings.dictationShowHUD { hud.show(.transcribing) }
        onChange?()

        let seconds = Double(pcm.count) / SAMPLE_RATE
        Task { [weak self] in
            guard let self else { return }
            let raw = await self.engine.transcribe(pcm)
            var text = raw
            var fired: [String: Int] = [:]
            if let raw {
                // The same dictionary the meeting pipeline uses, applied to the
                // engine's own words. One list, two pipelines: a name Listen
                // mishears in a meeting is the same name it mishears in a
                // dictation, and keeping two lists would mean fixing it twice.
                //
                // Corrections run either side of polishing and still run when
                // there is no polishing to do. See `applyAround`.
                let corrected = await CustomDictionary.applyAround(raw) { text in
                    // Announced from inside the polisher rather than guessed at
                    // from the setting: this fires only when a request is
                    // actually about to be made, so nobody whose Mac cannot
                    // polish is told that it is polishing.
                    await Polisher.shared.polish(text) { step, total in
                        Task { @MainActor in
                            guard Settings.dictationShowHUD else { return }
                            self.hud.show(.polishing(step: step, of: total))
                        }
                    }
                }
                // Last, so it sees whatever the model and the dictionary settled
                // on rather than the engine's first guess.
                text = Punctuation.trimFragment(corrected.text)
                fired = corrected.fired
            }

            self.phase = .idle
            // Held up through transcription: the pill means "still working",
            // and from Phase 3 the wait it covers is longer than the
            // transcription itself.
            self.hud.hide()
            if let text {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                if Settings.dictationAutoPaste { self.paste() }
                Cue.done()
                // The raw transcript is kept only when something changed it, so
                // the history stays a record of what was said as well as what
                // was pasted. Nothing to compare against otherwise.
                DictationHistory.append(.init(date: Date(), duration: seconds,
                                              text: text,
                                              raw: text == raw ? nil : raw,
                                              fired: fired))
                // Buckets only. The history line above keeps the words, on
                // this Mac; the event keeps the fact that dictation happened.
                Telemetry.dictationCompleted(
                    duration: seconds,
                    wordCount: text.split(separator: " ").count,
                    engine: Settings.dictationEngineChoice.rawValue)
                trace("dictated \(text.split(separator: " ").count) words")
            } else {
                Cue.failed()
                trace("dictation produced nothing")
            }
            self.onChange?()
            self.onTranscript?(text)
        }
    }

    /// Abandon a dictation without producing a transcript.
    ///
    /// Without this, a shortcut pressed by accident has no way out that does not
    /// overwrite the clipboard, and the clipboard is somebody's working state.
    func cancel() {
        // Escape while the device is opening is the same instruction, and has
        // to take the other route: `collect()` would stop a recorder that has
        // not started yet, and would wait on the open in order to do it.
        if phase == .starting { abandonStart(); return }
        guard phase == .recording else { return }
        _ = collect()
        phase = .idle
        hud.hide()
        Cue.cancel()
        trace("dictation cancelled")
        onChange?()
    }

    /// Stop whichever microphone path is running and hand back the samples.
    /// nil for anything under a tenth of a second, which is a chord pressed
    /// twice rather than something somebody said.
    private func collect() -> [Float]? {
        guard tapping else { return recorder.stop() }
        Capture.shared.endDictationTap()
        // Unsubscribed as well as untapped. A level sink left behind would go on
        // pushing the meeting's microphone into a hidden pill for the rest of
        // the call, which is an hour of wakeups for something nobody can see.
        Capture.shared.removeLevelSink(self)
        tapping = false
        let pcm = tapped.drain()
        return pcm.count > Int(SAMPLE_RATE / 10) ? pcm : nil
    }

    /// Type Cmd-V into whatever is focused.
    ///
    /// Posted to `.cghidEventTap`, which is the level the keyboard itself
    /// arrives at, so the frontmost app handles it exactly as it would a real
    /// keystroke. Needs the same Accessibility grant the shortcut does, and
    /// under secure input it silently does nothing, which is why the clipboard
    /// is written first and the paste is the extra rather than the delivery.
    private func paste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// ---------------------------------------------------------------------------

extension Settings {
    private static let dictationEnabledKey = "dictationEnabled"
    private static let dictationAutoPasteKey = "dictationAutoPaste"
    private static let dictationIntroSeenKey = "dictationIntroSeen"

    /// Whether the one-time "New: dictate with a shortcut" row has been used.
    ///
    /// Dictation arrived in an app that had never had it, so there is a whole
    /// population of users for whom nothing on screen would otherwise mention
    /// it: no onboarding step, because they finished setup long ago, and no
    /// reason to open a Settings tab they have never seen. One menu row, gone
    /// the moment it is clicked.
    static var dictationIntroSeen: Bool {
        get { defaults.bool(forKey: dictationIntroSeenKey) }
        set { defaults.set(newValue, forKey: dictationIntroSeenKey) }
    }

    /// Whether the dictation shortcut is armed.
    ///
    /// **On** by default, and inert until Accessibility is granted. That grant
    /// is the real opt-in: nothing watches the keyboard, nothing can type, and
    /// nothing prompts for it until somebody goes looking. A default of off
    /// would instead hide the feature behind a switch nobody knows to look for,
    /// in an app whose menu bar would never mention it.
    ///
    /// The presence of the key is not the answer here, its truthiness is, but
    /// read through `object(forKey:)` all the same: `bool(forKey:)` returns
    /// false for a key that was never written, which cannot tell "not set yet"
    /// from "deliberately turned off", and would make a default of true
    /// impossible to express.
    static var dictationEnabled: Bool {
        get { defaults.object(forKey: dictationEnabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: dictationEnabledKey) }
    }

    /// Paste the transcript into the frontmost app, rather than only copying it.
    ///
    /// On by default: the clipboard alone means every dictation ends with a
    /// keystroke the user has to remember, and the point of talking to a field
    /// is not having to reach for the keyboard.
    static var dictationAutoPaste: Bool {
        get {
            if ProcessInfo.processInfo.environment["LISTEN_AUTOPASTE"] == "1" { return true }
            return defaults.object(forKey: dictationAutoPasteKey) as? Bool ?? true
        }
        set { defaults.set(newValue, forKey: dictationAutoPasteKey) }
    }
}
