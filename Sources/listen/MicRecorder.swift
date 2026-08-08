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
    /// The capture unit, rebuilt on every restart rather than reused.
    ///
    /// Not an `AVAudioEngine`, and that is not a style preference. See
    /// `buildEngine` for the measurement: the engine picks its device the
    /// instant `inputNode` is read, which is before this code has said which
    /// microphone it wants, and the request that follows arrives too late.
    private var unit: AudioUnit?

    /// Where the unit renders, reused across slices. Rebuilt with the unit
    /// because its format is the hardware's, which is the thing a restart is
    /// usually reacting to.
    private var scratch: AVAudioPCMBuffer?
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

    /// The newest loudness, 0 for a silent room and 1 for shouting, about thirty
    /// times a second. Called on the audio thread: the consumer hops to the main
    /// actor with `DispatchQueue.main.async` and not `Task {}`, because the
    /// waveform is a queue and a reordered sample is a bar drawn in the wrong
    /// place. Same ordering trap as `installHotkey` in Speak.
    var onLevel: (@Sendable (Float) -> Void)?

    /// True while the device is running and handing over bit-exact silence.
    ///
    /// This is the state the rest of the silence handling exists to reach, and
    /// the one the UI has to show, because it is the only one the user can do
    /// something about. Reported rather than merely acted on: the switch below
    /// cannot always find somewhere to go.
    private(set) var isSilent = false

    /// Fires when `isSilent` changes, so the recording screen and the panel can
    /// say so while there is still time to fix it.
    var onSilenceChange: (@Sendable (Bool) -> Void)?

    /// What is being recorded from, and why it is not the obvious choice.
    /// `deviceNote` is nil whenever the answer needs no explaining.
    private(set) var deviceName: String?
    private(set) var deviceNote: String?
    private(set) var currentUID: String?

    /// Whether the device in use is the Mac's own microphone.
    ///
    /// Asked so a warning can name the right cause. "Off while the lid is shut"
    /// is only true of the built-in one, and it was said about a USB microphone
    /// that had been unplugged mid-recording, which sends somebody to open a lid
    /// that was never the problem.
    private(set) var deviceIsBuiltIn = false

    /// Devices this recording has already watched deliver nothing.
    ///
    /// Grows, never shrinks, which is what bounds the switching: every failure
    /// takes one device out of `candidates`, so a machine where nothing works
    /// tries each input once and then stops rather than cycling for an hour.
    private var exhausted: Set<String> = []

    /// Captured frames since the last sample above `signalFloor`. Written on the
    /// audio thread under `lock`, read by the watchdog on `control`.
    ///
    /// Pad frames are deliberately not counted. `padToWallClock` writes zeros
    /// too, and counting those would call a device silent for the length of a
    /// gap it had just recovered from.
    private var silentFrames = 0

    /// Whether *this* device has produced audible audio since it was opened.
    ///
    /// Separate from `sawAudio`, which is about the whole recording. This one
    /// resets on every `buildEngine`, and it is what makes switching devices
    /// safe: see `checkForSilence`.
    private var heardSinceOpen = false

    /// Below this, treat a sample as nothing.
    ///
    /// Bit-exact zero was the first version and it is certain but not
    /// sufficient. Measured while testing this very code: a closed lid makes the
    /// built-in microphone deliver arithmetic zero, but a USB webcam microphone
    /// that is picking up nothing delivers dither around -85 dBFS instead, and an
    /// `!= 0` test called that "picking up again" and stopped looking.
    ///
    /// -80 dBFS is one ten-thousandth of full scale. It is roughly 35 dB below a
    /// real microphone in a silent office (the AT2020 measured -44.7 dBFS peak
    /// with nobody talking), so no analogue front end sits under it, and it is
    /// the same constant `sawAudio` has always used.
    private let signalFloor: Float = 0.0001

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
    /// Slices arrive at the device's own buffer size, measured at 512 frames on
    /// this machine, which is about ninety a second at 48 kHz. Two seconds is
    /// therefore some two hundred missed ones and is not something jitter
    /// produces. It is the backstop rather than the main mechanism: the
    /// listeners below react in about a third of a second, and this catches
    /// whatever they do not.
    private let stallGrace: TimeInterval = 2

    /// Two listeners fire for one hardware change (nominal rate and stream
    /// format), and a device mid-renegotiation can fire several. Without this,
    /// one headset connecting rebuilds the engine four times.
    private let restartDebounce: TimeInterval = 0.75

    /// How long a running device may hand over bit-exact silence before it is
    /// treated as not recording at all.
    ///
    /// Three seconds, because the test below is certain rather than statistical
    /// and does not need to accumulate evidence. It only has to outlast a device
    /// coming up cold, which `AppDelegate.startDictation` in Speak already
    /// waits a beat for.
    private let silentGrace: TimeInterval = 3

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SAMPLE_RATE,
        channels: 1, interleaved: false)!

    /// Biggest slice the unit may hand the callback. `scratch` is sized from it
    /// and the callback refuses anything larger rather than overrunning.
    private static let maxFrames: UInt32 = 4096

    /// The unit holds an unretained pointer back to this object, so it must not
    /// outlive it even when nobody called `stop()`. Deliberately not going
    /// through `control`: a `sync` from `deinit` deadlocks if the last reference
    /// was released on that queue.
    deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

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
            // Per recording, not per launch. A microphone that was unplugged
            // during this morning's call has to be allowed back this afternoon.
            exhausted = []
            isSilent = false
            deviceName = nil
            deviceNote = nil
            currentUID = nil
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

    /// Builds a capture unit already pointed at the chosen microphone, and
    /// starts it. The writer is deliberately not touched: a restart appends to
    /// the same file.
    ///
    /// The device is named *before* `AudioUnitInitialize`, and that order is the
    /// point of the whole function. This used to be an `AVAudioEngine`, which
    /// cannot do that: the engine binds its input the instant `inputNode` is
    /// read, and it binds to a `CADefaultDeviceAggregate` wrapping the system
    /// default devices rather than to a device. Measured in Speak, which had
    /// the identical code, with music on a Bluetooth headset and the built-in
    /// microphone chosen in Settings:
    ///
    /// - reading `inputNode` dropped the headset from 44100 Hz to 16000 Hz,
    ///   which is the hands-free profile. The music went mono and the headset
    ///   announced a call, before any preference had been expressed;
    /// - the `CurrentDevice` request that followed returned `noErr` and did not
    ///   take effect. The unit stayed on the aggregate and the first recording
    ///   captured **0 buffers in 1.5 seconds**. The second one bound correctly,
    ///   which is why nobody caught it.
    ///
    /// A HAL unit takes its device before it is initialised, so no default
    /// device is ever opened. Measured after: the headset held 44100 Hz
    /// throughout, its input never ran, and the first recording delivered
    /// buffers.
    ///
    /// The device is re-resolved on every restart, which is what makes Listen
    /// *follow* a microphone change rather than merely survive it:
    /// `resolvedMicrophone` falls back to the system default, so plugging in a
    /// headset mid-meeting moves the recording onto it.
    private func buildEngine() throws {
        // `chooseMicrophone`, not `resolvedMicrophone`. This is the line that
        // refuses a device macOS has disabled, which is the whole proactive half
        // of the fix: with the lid shut, the built-in microphone is still the
        // system default input and still reports itself healthy, so the only
        // way not to record an hour of nothing from it is to decline it here.
        //
        // The fallback keeps a hopeless machine recording rather than throwing:
        // when every input has been tried and none delivers anything, a file of
        // silence with `isSilent` set and the UI saying so beats no file, and
        // `checkForSilence` stops switching once `candidates` is empty.
        guard let choice = Settings.chooseMicrophone(excluding: exhausted)
                ?? Settings.resolvedMicrophone.map({ MicChoice(device: $0, rejected: nil) })
        else { throw CaptureError.noInputDevice }
        let device = choice.device
        deviceName = device.name
        deviceNote = choice.rejected
        currentUID = device.uid
        deviceIsBuiltIn = AudioDevices.isBuiltIn(device)
        heardSinceOpen = false
        lock.lock()
        silentFrames = 0
        lock.unlock()

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw CaptureError.micUnitFailed(-1)
        }
        var made: AudioUnit?
        let created = AudioComponentInstanceNew(component, &made)
        guard created == noErr, let unit = made else {
            throw CaptureError.micUnitFailed(created)
        }
        // Anything that throws from here on must not leak the unit, which holds
        // the device open for the rest of the meeting if it survives.
        var keep = false
        defer { if !keep { AudioComponentInstanceDispose(unit) } }

        // A capture unit: input bus on, output bus off. Left on, the unit opens
        // the default *output* device too, which on a Bluetooth headset is the
        // other half of the same profile switch.
        var on: UInt32 = 1
        var off: UInt32 = 0
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Input, 1, &on, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
                             kAudioUnitScope_Output, 0, &off, UInt32(MemoryLayout<UInt32>.size))

        var id = device.id
        let selected = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard selected == noErr else { throw CaptureError.micUnitFailed(selected) }

        // Read the format *after* selecting the device. Each device has its own
        // sample rate, and a converter built from another one's format resamples
        // from the wrong source rate, which records pitch-shifted and garbled.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 1, &hardware, &size) == noErr
        else { throw CaptureError.badFormat(0, 0) }
        guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
              let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: hardware.mSampleRate,
                                           channels: hardware.mChannelsPerFrame,
                                           interleaved: false)
        else { throw CaptureError.badFormat(hardware.mSampleRate, hardware.mChannelsPerFrame) }

        // Ask for the format the converter is built from rather than describing
        // the same thing twice. The down-mix to mono stays with
        // `AVAudioConverter`, which is where it was when this was last known
        // good.
        var client = inFormat.streamDescription.pointee
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1, &client,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
        else { throw CaptureError.badFormat(hardware.mSampleRate, hardware.mChannelsPerFrame) }

        var maxFrames = MicRecorder.maxFrames
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxFrames,
                             UInt32(MemoryLayout<UInt32>.size))

        guard let buffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                            frameCapacity: MicRecorder.maxFrames),
              let conv = AVAudioConverter(from: inFormat, to: target)
        else { throw CaptureError.badFormat(hardware.mSampleRate, hardware.mChannelsPerFrame) }
        scratch = buffer
        converter = conv
        trace("mic format \(Int(hardware.mSampleRate)) Hz, \(hardware.mChannelsPerFrame) ch")

        var callback = AURenderCallbackStruct(
            inputProc: MicRecorder.render,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0, &callback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        let initialised = AudioUnitInitialize(unit)
        guard initialised == noErr else { throw CaptureError.micUnitFailed(initialised) }

        // Pad *before* the unit runs, so no slice can land between measuring the
        // gap and filling it. See `padToWallClock` for why the gap has to be
        // filled at all. Safer here than it was with a tap: an initialised unit
        // delivers nothing until it is started, so the window is closed rather
        // than merely narrow.
        lock.lock()
        padToWallClock()
        lock.unlock()

        self.unit = unit
        let started = AudioOutputUnitStart(unit)
        guard started == noErr else {
            self.unit = nil
            AudioUnitUninitialize(unit)
            converter = nil
            scratch = nil
            throw CaptureError.deviceStartFailed(started)
        }
        keep = true
        if let note = choice.rejected {
            // stderr rather than `trace`, for the reason the restart message is:
            // this is Listen declining the device the user or the system asked
            // for, and an override nobody is told about is the thing this whole
            // change exists to remove.
            log("microphone: \(note); recording from \(device.name)")
        } else {
            trace("recording from \(device.name)")
        }

        // Turning the listeners off is how the watchdog gets tested at all: it
        // is the backstop, the listeners always beat it to the same event, and a
        // backstop that has never once fired is not a backstop. Same family as
        // `LISTEN_CHUNK`, and for users it does nothing but make recovery take
        // two seconds instead of a third of one.
        if ProcessInfo.processInfo.environment["LISTEN_MIC_NO_LISTENERS"] == nil {
            watchHardware(on: device.id)
        }
    }

    /// Releases the device.
    ///
    /// Disposed rather than kept for the next restart. A unit that is merely
    /// stopped still holds its device, so a Bluetooth headset would sit in
    /// hands-free mode from the first meeting until Listen quit, and the next
    /// `buildEngine` could not re-resolve onto a different microphone.
    private func teardownEngine() {
        removeListeners()
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        converter = nil
        scratch = nil
    }

    /// The audio thread. Renders one slice, converts it and appends it.
    ///
    /// Unretained `self`: `teardownEngine` disposes the unit, and `deinit`
    /// disposes it again for the case where nobody called `stop()`, so the unit
    /// cannot outlive the object whose pointer it holds.
    private static let render: AURenderCallback = { context, flags, timestamp, bus, frames, _ in
        Unmanaged<MicRecorder>.fromOpaque(context).takeUnretainedValue()
            .capture(flags, timestamp, bus, frames)
    }

    private func capture(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                         _ timestamp: UnsafePointer<AudioTimeStamp>,
                         _ bus: UInt32,
                         _ frames: UInt32) -> OSStatus {
        guard let unit, let scratch, let conv = converter else { return noErr }
        guard frames <= scratch.frameCapacity else { return noErr }

        // `frameLength` first, and nothing written into the buffer list by hand.
        // `AVAudioPCMBuffer` derives the list's `mDataByteSize` from
        // `frameLength` and recomputes it on *every* access to
        // `mutableAudioBufferList`, so sizing the list through one call and then
        // passing a second call's list to `AudioUnitRender` hands it a list
        // claiming zero bytes. That is `paramErr` (-50) on every slice for ever:
        // the device runs, so macOS shows the microphone indicator and the
        // meeting looks like it is being recorded, while the track stays empty.
        scratch.frameLength = frames

        let status = AudioUnitRender(unit, flags, timestamp, bus, frames,
                                     scratch.mutableAudioBufferList)
        guard status == noErr else { return status }

        let ratio = SAMPLE_RATE / scratch.format.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return noErr }

        var err: NSError?
        var supplied = false
        conv.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return scratch
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0]
        else { return noErr }

        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))

        // "Nothing at all", measured against a floor 35 dB below any real
        // microphone rather than against a level somebody could fall under by
        // going quiet. See `signalFloor`. A dead input reads zero or dither; a
        // room with nobody talking in it still reads its own noise floor, so this
        // separates the two without ever having to guess at how quiet a quiet
        // person is.
        let live = chunk.contains { abs($0) > signalFloor }
        lock.lock()
        try? writer?.append(chunk)
        silentFrames = live ? 0 : silentFrames + chunk.count
        lock.unlock()
        if live {
            heardSinceOpen = true
            if !sawAudio {
                sawAudio = true
                trace("mic has signal")
            }
        }
        report(chunk)
        return noErr
    }

    /// Splits one captured buffer into short windows and reports each one's
    /// loudness.
    ///
    /// Ported from Speak's `Recorder.report`, constants and all, because Speak
    /// and Listen are expected to become one app and two meters that disagree
    /// about what a level means would be a merge conflict rather than a move.
    ///
    /// Per window rather than per buffer: a buffer is tens of milliseconds and
    /// twelve updates a second reads as a meter struggling rather than
    /// listening. 32 ms windows give about thirty, which is enough for the
    /// animation to interpolate between real measurements instead of inventing
    /// motion between stale ones.
    private func report(_ chunk: [Float]) {
        guard let onLevel else { return }
        let window = Int(SAMPLE_RATE / 31)      // ~32 ms
        var i = 0
        while i < chunk.count {
            let end = min(i + window, chunk.count)
            onLevel(MicRecorder.loudness(chunk[i..<end]))
            i = end
        }
    }

    /// RMS mapped onto 0...1 through decibels rather than linearly.
    ///
    /// Speech through a laptop microphone peaks around 0.05 of full scale, so a
    /// linear meter lives in the bottom twentieth of its range and reads as
    /// nothing happening while somebody talks. The window is Speak's measured
    /// one on this same capture path: -55 dBFS is a quiet room and -14 is
    /// shouting.
    ///
    /// Listen's iOS app uses `(db + 55) / 55` with a visible floor instead.
    /// That is the right call for a meter one bar wide on a phone and the wrong
    /// one here, where a floor would draw a live strip for a dead microphone.
    static func loudness(_ window: ArraySlice<Float>) -> Float {
        guard !window.isEmpty else { return 0 }
        var sum: Float = 0
        for s in window { sum += s * s }
        let rms = (sum / Float(window.count)).squareRoot()
        guard rms > 0 else { return 0 }
        let db = 20 * log10f(rms)
        return min(1, max(0, (db + 55) / 41))
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
    private func watchHardware(on device: AudioDeviceID) {
        // No read-back any more. Selecting the device is now fatal when it
        // fails, so a unit that is running is a unit on this device, and there
        // is no second case where the engine quietly sat on the default.
        listen(to: device, kAudioDevicePropertyNominalSampleRate,
               reason: "the microphone's sample rate changed")
        listen(to: device, kAudioDevicePropertyStreamFormat,
               scope: kAudioDevicePropertyScopeInput,
               reason: "the microphone's format changed")
        listen(to: device, kAudioDevicePropertyDeviceIsAlive,
               reason: "the microphone went away")
        // Only when following the system default. Somebody who picked a specific
        // microphone in Settings meant it, and moving them off it because macOS
        // switched to a headset would be the opposite of what they asked for.
        if Settings.microphoneUID == nil {
            listen(to: AudioObjectID(kAudioObjectSystemObject),
                   kAudioHardwarePropertyDefaultInputDevice,
                   reason: "the system's default microphone changed")
        }
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
        // Two questions, and they are not the same one. `checkForStall` asks
        // whether anything is arriving; `checkForSilence` asks whether what
        // arrives is audio. A disabled device answers yes to the first and no to
        // the second, which is exactly the case that shipped as an hour of
        // nothing.
        timer.setEventHandler { [weak self] in
            self?.checkForStall()
            self?.checkForSilence()
        }
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

    /// The device is running, the file is growing, and every sample of it is
    /// zero.
    ///
    /// The failure `checkForStall` cannot see, and the more common of the two.
    /// A microphone that stops delivering announces itself: the writer stops
    /// growing and something is obviously wrong. A microphone macOS has switched
    /// off keeps delivering, at the right rate, in the right format, and the
    /// only thing wrong with it is the content. Every property a recorder would
    /// think to check says the device is healthy.
    ///
    /// Two things happen here and they are independent on purpose. `isSilent` is
    /// set whether or not there is anywhere to go, because telling the user is
    /// worth doing even when the app cannot fix it, and on a closed laptop with
    /// nothing plugged in there is genuinely nowhere to go. The switch is
    /// attempted only when `candidates` offers a device this recording has not
    /// already watched fail, which is what stops it cycling.
    ///
    /// **A device is only ever abandoned before it has been heard from.**
    /// `heardSinceOpen` is what makes that switch safe to run unattended. Once a
    /// microphone has produced audible audio, a later silence is somebody
    /// listening rather than a broken input, and moving them off a working mic
    /// mid-sentence would be a far worse bug than the one this fixes. It also
    /// disposes of the awkward case: macOS Voice Isolation gates hard, so a
    /// gated mic during a pause can look exactly like a dead one, and after the
    /// first word it is permanently distinguishable.
    ///
    /// The warning is not gated that way. A headset that goes back in its case
    /// half way through is worth saying out loud even though nothing should be
    /// switched for it.
    private func checkForSilence() {
        guard isRecording, unit != nil else { return }
        lock.lock()
        let frames = silentFrames
        lock.unlock()

        // Silence has to be cleared by hearing something, never by the counter
        // being reset. `buildEngine` zeroes `silentFrames`, so a plain
        // "quiet for less than the grace period" test reports every device
        // switch as a recovery: the first tick after the switch sees a fresh
        // counter and says the microphone is picking up again, when all that
        // happened is that a different dead device is now being listened to.
        // That shipped for about ten minutes and the log claimed a working
        // microphone over a file of bit-exact zeros.
        let quietFor = Double(frames) / SAMPLE_RATE
        let silent = heardSinceOpen
            ? quietFor >= silentGrace
            : isSilent || quietFor >= silentGrace
        if silent != isSilent {
            isSilent = silent
            onSilenceChange?(silent)
            if !silent { log("microphone: \(deviceName ?? "the microphone") is picking up") }
        }
        guard silent, !heardSinceOpen, let current = currentUID else { return }

        var tried = exhausted
        tried.insert(current)
        // Nothing better to move to, so stop asking. The report stands.
        guard let next = Settings.chooseMicrophone(excluding: tried),
              next.device.uid != current else { return }
        exhausted = tried
        restart(reason: "\(deviceName ?? "the microphone") is not picking anything up")
    }

    /// Move to the device Settings now names, without stopping the recording.
    ///
    /// Somebody choosing a microphone mid-meeting is the strongest possible
    /// signal about what to record from, so this clears `exhausted` and bypasses
    /// the debounce: both of those exist to stop the app thrashing on its own,
    /// and neither should stand between a person and the device they just asked
    /// for. Without the reset, a device this recording had already given up on
    /// could not be chosen again even after being plugged back in.
    func adoptChosenDevice() {
        control.async { [weak self] in
            guard let self, self.isRecording else { return }
            self.exhausted = []
            self.lastRestartAttempt = .distantPast
            self.restart(reason: "microphone changed by hand")
        }
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
            log("microphone: \(reason); now recording from "
                + "\(deviceName ?? "the default input") (\(restarts) restart"
                + (restarts == 1 ? "" : "s") + " so far)")
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
