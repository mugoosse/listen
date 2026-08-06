import AVFoundation
import AppKit
import CoreAudio

/// The user's own voice, through `AVAudioEngine`, to 16 kHz mono Float32.
///
/// Ported from Speak's `Recorder`, with one change that matters: this one
/// streams to a file instead of accumulating samples in an array. A dictation
/// is seconds long and fits in memory; an hour of a meeting is 230 MB of
/// Float32 that would be lost entirely if anything went wrong before the end.
///
/// Keeping this track separate from the system track is not just tidiness. The
/// mic is definitionally the user and the system output is definitionally
/// everyone else, which is a perfect first-level speaker split for free, and it
/// removes the most common diarization error: confusing the user with a
/// participant.
///
/// The other thing it does, and the reason this file is not thirty lines long,
/// is survive the microphone changing underneath it. See `restart`.
final class MicRecorder {
    /// Rebuilt on every restart rather than reused. `AVAudioEngine` caches the
    /// input format, and a device that has just changed format is exactly the
    /// case where a stale cache produces a converter resampling from a rate the
    /// hardware no longer has.
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var writer: WAVWriter?
    private let lock = NSLock()

    /// Everything that starts, stops or rebuilds the engine runs here, so a
    /// restart raised by the hardware cannot interleave with `stop()`. `start`
    /// and `stop` come in on the main actor and hop across with `sync`; nothing
    /// on this queue ever waits on the main thread, so that cannot deadlock.
    private let control = DispatchQueue(label: "com.mgo.listen.mic.control")

    private(set) var isRecording = false
    private(set) var sawAudio = false

    /// How many times the engine had to be rebuilt mid-recording. Reported
    /// rather than hidden: this is the user's own voice going missing for a few
    /// seconds, and the only other evidence is a gap in a file nobody will
    /// re-listen to.
    private(set) var restarts = 0

    private var url: URL?
    private var startedAt: Date?

    /// Watchdog state. `lastFrames` is what the writer had at the last tick.
    private var watchdog: DispatchSourceTimer?
    private var lastFrames = 0
    private var lastGrowth = Date()
    private var lastRestartAttempt = Date.distantPast

    /// Property listeners, kept so they can be removed: Core Audio matches on
    /// the block itself, so it has to be the same one that was registered.
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress,
                             AudioObjectPropertyListenerBlock)] = []

    /// How long the track may deliver nothing before the engine is rebuilt.
    ///
    /// Buffers arrive about ten times a second at 4096 frames, so two seconds is
    /// roughly twenty missed ones and is not something jitter produces. It is
    /// the backstop rather than the main mechanism: the listeners below react in
    /// about a third of a second, and this catches whatever they do not.
    private let stallGrace: TimeInterval = 2

    /// Two listeners fire for one hardware change (nominal rate and stream
    /// format), and a device mid-renegotiation can fire several. Without this,
    /// one headset connecting rebuilds the engine four times.
    private let restartDebounce: TimeInterval = 0.75

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SAMPLE_RATE,
        channels: 1, interleaved: false)!

    // -----------------------------------------------------------------------

    /// `origin` is the instant both tracks call zero. It is passed in rather
    /// than taken here because the system track starts second and can spend two
    /// seconds waiting for its aggregate device: measured at three seconds
    /// apart on this machine, which is three seconds of misattribution for the
    /// whole meeting if each file measures from its own start.
    func start(writingTo url: URL, from origin: Date) throws {
        guard !isRecording else { return }
        try control.sync {
            sawAudio = false
            restarts = 0
            self.url = url
            let now = Date()
            startedAt = origin
            lastGrowth = now
            lastFrames = 0
            lastRestartAttempt = .distantPast

            writer = try WAVWriter(url: url)
            do {
                try buildEngine()
            } catch {
                writer?.close()
                writer = nil
                self.url = nil
                startedAt = nil
                throw error
            }
            isRecording = true
            startWatchdog()
        }
    }

    func stop() {
        guard isRecording else { return }
        control.sync {
            isRecording = false
            watchdog?.cancel()
            watchdog = nil
            teardownEngine()
            lock.lock()
            writer?.close()
            writer = nil
            lock.unlock()
            url = nil
            startedAt = nil
        }
    }

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return writer?.duration ?? 0
    }

    // -----------------------------------------------------------------------
    // Engine lifecycle. All of this runs on `control`.

    /// Builds a converter and a tap against whatever the input device is
    /// reporting *now*, and starts rendering. The writer is deliberately not
    /// touched: a restart appends to the same file.
    private func buildEngine() throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        selectDevice(on: input)

        // Read the format *after* selecting the device. Switching inputs
        // changes the hardware sample rate, and a converter built from the
        // format read before selection resamples from the wrong source rate,
        // which records pitch-shifted and garbled.
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw CaptureError.badFormat(0, 0) }
        converter = AVAudioConverter(from: inFormat, to: target)
        trace("mic format \(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch")

        // Pad *before* the tap exists, so no buffer can land between measuring
        // the gap and filling it. See `padToWallClock` for why the gap has to be
        // filled at all.
        lock.lock()
        padToWallClock()
        lock.unlock()

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buf, _ in
            guard let self, let conv = self.converter else { return }
            let ratio = SAMPLE_RATE / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: self.target, frameCapacity: capacity)
            else { return }

            var err: NSError?
            var supplied = false
            conv.convert(to: out, error: &err) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buf
            }
            guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0]
            else { return }

            let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
            self.lock.lock()
            try? self.writer?.append(chunk)
            self.lock.unlock()
            if !self.sawAudio, chunk.contains(where: { abs($0) > 0.0001 }) {
                self.sawAudio = true
                trace("mic has signal")
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            // Undo the tap before rethrowing. `stop()` will not: it guards on
            // `isRecording`, which is still false because the line above threw.
            // A tap that outlives the failure means the next attempt installs a
            // second one on the same bus, which AVAudioEngine does not allow,
            // and one transient error then leaves capture broken until relaunch.
            input.removeTap(onBus: 0)
            engine.stop()
            converter = nil
            throw error
        }

        // Turning the listeners off is how the watchdog gets tested at all: it
        // is the backstop, the listeners always beat it to the same event, and a
        // backstop that has never once fired is not a backstop. Same family as
        // `LISTEN_CHUNK`, and for users it does nothing but make recovery take
        // two seconds instead of a third of one.
        if ProcessInfo.processInfo.environment["LISTEN_MIC_NO_LISTENERS"] == nil {
            watchHardware(on: input)
        }
    }

    private func teardownEngine() {
        removeListeners()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
    }

    /// Points the engine's input at the chosen device.
    ///
    /// `AVAudioEngine` has no device property of its own on macOS; you reach
    /// through to the input node's audio unit. Must happen before the engine
    /// starts.
    ///
    /// Re-resolved on every restart, which is what makes Listen *follow* a
    /// microphone change rather than merely survive it: `resolvedMicrophone`
    /// falls back to the system default, so plugging in a headset mid-meeting
    /// moves the recording onto it.
    private func selectDevice(on input: AVAudioInputNode) {
        guard let device = Settings.resolvedMicrophone, let unit = input.audioUnit else { return }
        var id = device.id
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            // Not fatal. Falling back to the default device records the meeting
            // from the wrong microphone, which is recoverable; refusing to
            // record does not record the meeting at all.
            log("could not select \(device.name) (status \(status)), using the default input")
        } else {
            trace("recording from \(device.name)")
        }
    }

    // -----------------------------------------------------------------------
    // Noticing that the microphone went away.

    /// Watch the device Listen is actually recording from, plus the system's
    /// choice of default input.
    ///
    /// Measured, because the obvious answer is wrong in two ways.
    /// `AVAudioEngineConfigurationChange` fires once when the engine starts and
    /// **not** when the hardware format changes underneath it, and
    /// `engine.isRunning` stays `true` throughout. So the framework reports
    /// nothing at all: the tap simply stops being called, for ever, and an hour
    /// of the user's own voice is missing with no error anywhere. Core Audio's
    /// own property listeners do fire, at the instant of the change.
    private func watchHardware(on input: AVAudioInputNode) {
        // The device the audio unit settled on, read back rather than assumed:
        // `selectDevice` may have failed, in which case the engine is on the
        // default and that is the one whose format matters.
        if let device = currentDevice(on: input) {
            listen(to: device, kAudioDevicePropertyNominalSampleRate,
                   reason: "the microphone's sample rate changed")
            listen(to: device, kAudioDevicePropertyStreamFormat,
                   scope: kAudioDevicePropertyScopeInput,
                   reason: "the microphone's format changed")
            listen(to: device, kAudioDevicePropertyDeviceIsAlive,
                   reason: "the microphone went away")
        }
        // Only when following the system default. Somebody who picked a specific
        // microphone in Settings meant it, and moving them off it because macOS
        // switched to a headset would be the opposite of what they asked for.
        if Settings.microphoneUID == nil {
            listen(to: AudioObjectID(kAudioObjectSystemObject),
                   kAudioHardwarePropertyDefaultInputDevice,
                   reason: "the system's default microphone changed")
        }
    }

    private func currentDevice(on input: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = input.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                   kAudioUnitScope_Global, 0, &id, &size) == noErr,
              id != 0
        else { return nil }
        return id
    }

    private func listen(to id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        reason: String) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // `async` rather than calling straight through: this block is
            // running *on* `control`, and a restart removes the very listener
            // being executed.
            self?.control.async { self?.restart(reason: reason) }
        }
        guard AudioObjectAddPropertyListenerBlock(id, &address, control, block) == noErr
        else { return }
        listeners.append((id, address, block))
    }

    private func removeListeners() {
        for (id, address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, control, block)
        }
        listeners.removeAll()
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + stallGrace, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.checkForStall() }
        timer.resume()
        watchdog = timer
    }

    /// The backstop, defined on the symptom rather than on a list of causes: if
    /// no samples have arrived for `stallGrace`, the track is dead whatever
    /// killed it, and a dead track is worth restarting even if the reason is one
    /// nobody has reproduced yet.
    private func checkForStall() {
        guard isRecording else { return }
        lock.lock()
        let frames = Int((writer?.duration ?? 0) * SAMPLE_RATE)
        lock.unlock()

        let idle = Date().timeIntervalSince(lastGrowth)
        if frames != lastFrames {
            lastFrames = frames
            lastGrowth = Date()
            return
        }
        guard idle >= stallGrace else { return }
        restart(reason: "no audio for "
                + String(format: "%.1f", Date().timeIntervalSince(lastGrowth)) + "s")
    }

    /// Rebuild the engine onto whatever the microphone is now, keeping the same
    /// file open.
    private func restart(reason: String) {
        guard isRecording else { return }
        guard Date().timeIntervalSince(lastRestartAttempt) >= restartDebounce else { return }
        lastRestartAttempt = Date()

        teardownEngine()
        do {
            try buildEngine()
            restarts += 1
            lastGrowth = Date()
            lock.lock()
            lastFrames = Int((writer?.duration ?? 0) * SAMPLE_RATE)
            lock.unlock()
            // stderr rather than `trace`, for the reason the dictionary counts
            // are: this is the user's own voice, and the seconds it costs are
            // not recoverable from anything else on disk.
            log("microphone: \(reason); restarted capture (\(restarts) so far)")
        } catch {
            log("microphone: \(reason); could not restart "
                + "(\(error.localizedDescription)), still trying")
        }
    }

    /// Fill the outage with silence so the rest of the meeting stays lined up.
    /// See `WAVWriter.pad(to:)` for why a gap is filled rather than closed up.
    private func padToWallClock() {
        guard let startedAt, let writer else { return }
        let added = writer.pad(to: Date().timeIntervalSince(startedAt))
        guard added > 0 else { return }
        trace("mic padded \(String(format: "%.1f", added))s to stay aligned with the system track")
    }
}
