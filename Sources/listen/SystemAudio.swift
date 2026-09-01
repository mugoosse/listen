import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures everything the Mac is playing, through a Core Audio process tap.
///
/// Why a tap rather than ScreenCaptureKit: **a tap needs audio recording
/// permission, not screen recording permission**. Asking someone to hand over
/// their screen so an app can hear a meeting is a much larger request than the
/// feature needs, and on a managed Mac it is often simply refused.
///
/// Two traps live in here, both cheap to reintroduce:
///
/// 1. `AVAudioEngine` cannot be retargeted at a tap-backed aggregate device.
///    Setting `kAudioOutputUnitProperty_CurrentDevice` to the aggregate either
///    fails or produces silence, so the IO proc is driven on the aggregate
///    directly with `AudioDeviceCreateIOProcIDWithBlock`.
/// 2. The aggregate device does not report a usable stream format the instant
///    it is created. Reading it too early gives a zero sample rate, and a
///    converter built from that produces nothing for the whole meeting.
///    `deviceFormat` polls.
final class SystemAudioRecorder {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?

    private var writer: WAVWriter?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// The instant both tracks call zero, kept so a rebuild can pad the outage
    /// against the wall clock rather than against however long it thinks it has
    /// been running. Measured against the clock for the same reason
    /// `MicRecorder.padToWallClock` is: repeated small shortfalls otherwise
    /// accumulate over an hour.
    private var origin = Date()

    /// Raw bytes handed over by the IO proc, drained on a normal queue.
    ///
    /// The IO proc runs on a realtime thread. Converting and writing a file
    /// there would block it, and a blocked IO proc is a glitch in whatever the
    /// user is listening to, so the callback does nothing but memcpy under a
    /// lock.
    private var pending = [UInt8]()
    private let lock = NSLock()
    private var drain: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.mgo.listen.systemaudio")

    /// Rebuilding the tap, and the hardware notifications that ask for it.
    ///
    /// Separate from `queue` because that is where the IO proc is dispatched,
    /// and `AudioDeviceStop` blocks until the IO proc returns. `MicRecorder`
    /// keeps a `control` queue for the same reason.
    private let control = DispatchQueue(label: "com.mgo.listen.systemaudio.control")

    private(set) var isRecording = false
    /// Set when the first buffer with actual signal arrives, so the UI can say
    /// "capturing" rather than "started" when it means it.
    private(set) var sawAudio = false

    /// Health of the tap itself, as opposed to loudness of what it carries.
    /// See `TapHealth` for the failure this exists for and the measurements
    /// behind every threshold in it.
    private let health = TapHealth.Monitor()

    /// What the tap is doing, as opposed to what it is carrying.
    ///
    /// Handed over whole rather than read back off properties, because every
    /// value in here is written on the drain queue and read on the main actor,
    /// and the level path next door already had to learn that lesson.
    struct Health: Sendable, Equatable {
        /// Delivering audio with holes punched through it. Certain when true.
        var torn = false
        /// Seconds the far end has been bit-exact zero. **Meaningless on its
        /// own**, which is why `Capture` will not warn on it without the
        /// microphone having carried speech through the same stretch: the two
        /// benign long silences in the library are both recording lead-ins.
        var deafFor: TimeInterval = 0
        var restarts = 0
        /// The tapped device is a Bluetooth one. Not a fault, but every failure
        /// measured so far happened on one, so it belongs in the report.
        var tappingBluetooth = false
    }

    /// Announced when the health changes, so the panel, the recording screen
    /// and the menu bar all learn at once. Same shape and same reasoning as
    /// `MicRecorder.onSilenceChange`.
    var onHealthChange: (@Sendable (Health) -> Void)?

    private var published = Health()

    /// Whether the tapped device is a Bluetooth one, read when the tap is built
    /// and whenever the default output changes, never on the health tick.
    private var tappingBluetooth = false

    private var lastRestartAttempt = Date.distantPast
    /// Long enough that a rebuild is never mistaken for a fix that did not
    /// work, short enough to recover a meeting rather than a memory of one.
    private let restartDebounce: TimeInterval = 20
    private var defaultOutputListener: AudioObjectPropertyListenerBlock?

    /// The newest loudness of the far side, 0...1, about thirty times a second.
    ///
    /// Called off the IO proc's realtime thread: `receive` already hands its
    /// bytes to `queue` before converting, so this arrives on that queue and the
    /// consumer hops to the main actor with `DispatchQueue.main.async`.
    ///
    /// No *silence* detector on this track, deliberately, and the asymmetry is
    /// still the point. Bit-exact zero from a process tap is the ordinary state
    /// of a Mac with nothing playing, so the test that is certain for a
    /// microphone means nothing here. A quiet far side is a quiet far side.
    ///
    /// What that reasoning missed, and what cost three meetings on 2026-09-01:
    /// **a dead tap is also bit-exact zero, and the two are not the same
    /// thing.** `TapHealth` tells them apart on a question this comment never
    /// asked, whether the zeros are interleaved with signal inside a single
    /// 10 ms window, which no working audio path produces. That test is
    /// certain where a level test is worthless, and it is why a silence
    /// detector is still the wrong instrument here.
    var onLevel: (@Sendable (Float) -> Void)?

    static let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SAMPLE_RATE,
        channels: 1, interleaved: false)!

    // -----------------------------------------------------------------------

    /// True where process taps exist at all.
    ///
    /// The API landed in 14.2 while Listen supports 14.0, so this is gated
    /// rather than raising the deployment target: on 14.0 and 14.1 the mic
    /// track still records, and half a meeting beats refusing to launch.
    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// `origin` is the instant both tracks call zero, handed over by `Capture`.
    /// This track starts second and everything above this line can take time:
    /// creating the tap, creating the aggregate, and `deviceFormat` polling for
    /// up to two seconds. Measured at three seconds behind the microphone on a
    /// busy machine, which without the pad below is three seconds of every turn
    /// being attributed to the wrong side for the whole meeting.
    func start(writingTo url: URL, from origin: Date) throws {
        guard !isRecording else { return }
        guard #available(macOS 14.2, *) else { throw CaptureError.tapUnsupported }

        self.origin = origin
        health.reset()
        writer = try WAVWriter(url: url)
        do {
            try buildTap()
        } catch {
            // The writer is created first now, because `buildTap` pads it, so
            // a tap that never comes up must not leave a stub file behind
            // holding the recording's system track open.
            writer?.close()
            writer = nil
            throw error
        }

        // Drain on a timer rather than from the IO proc, so the realtime thread
        // never waits on a file write.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.flush()
            // After the flush, so the check sees the batch that just landed.
            // Separate from it because a tap that has stopped calling the IO
            // proc altogether delivers nothing to flush, and that is precisely
            // the case worth catching.
            self?.checkHealth()
        }
        timer.resume()
        drain = timer

        isRecording = true
        watchDefaultOutput()
        trace("system capture started -> \(url.lastPathComponent)")
    }

    /// Everything between "there is a file" and "audio is arriving in it", so
    /// that a rebuild mid-meeting is the same code as the first build.
    @available(macOS 14.2, *)
    private func buildTap() throws {
        tapID = try createTap()
        deviceID = try createAggregate()
        try addTap(tapID, to: deviceID)

        var asbd = try deviceFormat(deviceID)
        // The pointer has to be used *inside* the closure. Returning it from
        // `withUnsafePointer(to:) { $0 }` hands back a pointer to a temporary
        // that no longer exists, which crashed here with SIGTRAP rather than
        // failing politely.
        guard let source = withUnsafePointer(to: &asbd, { AVAudioFormat(streamDescription: $0) }),
              source.sampleRate > 0 else {
            throw CaptureError.badFormat(asbd.mSampleRate, asbd.mChannelsPerFrame)
        }
        sourceFormat = source
        converter = AVAudioConverter(from: source, to: Self.target)
        trace("system tap format \(Int(source.sampleRate)) Hz, \(source.channelCount) ch")

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &procID, deviceID, queue
        ) { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }
        guard status == noErr, let procID else {
            teardown()
            throw CaptureError.ioProcFailed(status)
        }
        ioProc = procID

        // Before the IO proc runs, so nothing can land in the file ahead of the
        // silence that represents the time already spent getting here. On a
        // rebuild this is also what fills the outage, for the reason
        // `WAVWriter.pad(to:)` gives: closing the gap up would move every word
        // after it earlier and reattribute the rest of the meeting.
        let padded = writer?.pad(to: Date().timeIntervalSince(origin)) ?? 0
        if padded > 0 {
            trace("system padded \(String(format: "%.1f", padded))s to stay aligned with the mic")
        }

        let started = AudioDeviceStart(deviceID, procID)
        guard started == noErr else {
            teardown()
            throw CaptureError.deviceStartFailed(started)
        }
        tappingBluetooth = AudioDevices.defaultOutputIsBluetooth
        if tappingBluetooth {
            trace("system tap is on a Bluetooth output")
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        drain?.cancel()
        drain = nil
        unwatchDefaultOutput()
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
            self.ioProc = nil
        }
        flush()                       // whatever the last tick did not take
        writer?.close()
        writer = nil
        teardown()
        trace("system capture stopped")
    }

    var duration: TimeInterval { writer?.duration ?? 0 }

    /// `LISTEN_TAP_TEAR=0.25` damages the far-end track exactly the way a
    /// starved IO proc does, because waiting for a Mac to overload is not a
    /// test. The same reasoning as `LISTEN_OFFLINE`: the recovery is the
    /// interesting half, and it cannot be reached by hoping.
    ///
    /// The shape is measured rather than invented. On 2026-09-01 the far end
    /// lost the first 39 samples of every 160 at 16 kHz, so this zeroes the
    /// head of every 10 ms window and the default fraction is that 24%.
    private static let tearFraction = ProcessInfo.processInfo
        .environment["LISTEN_TAP_TEAR"].flatMap(Double.init) ?? 0

    private static func tear(_ samples: inout [Float]) {
        guard tearFraction > 0 else { return }
        let width = Int(SAMPLE_RATE * TapHealth.windowSeconds)
        // 1.0 is the other failure rather than a degenerate case of this one:
        // a tap that has gone deaf altogether, which is what `Capture` has to
        // catch against the microphone because nothing in the track itself can.
        let hole = max(1, Int(Double(width) * min(tearFraction, 1.0)))
        var start = 0
        while start < samples.count {
            // The tail matters. Stopping at the last whole window left up to
            // 159 samples of real audio in every batch, which is inaudible but
            // is signal, and signal is exactly what the deafness clock watches
            // for. The first run of this looked healthy for that reason alone.
            for index in start..<min(start + hole, samples.count) { samples[index] = 0 }
            start += width
        }
    }

    // -----------------------------------------------------------------------
    // Health, and recovering from what it reports.

    /// Ask for a rebuild from outside, for the one case this object cannot
    /// judge alone: the far end has been bit-exact zero for a long time, which
    /// only means something when the microphone says somebody was talking
    /// through it. `Capture` owns that combination because it owns both tracks.
    func requestRestart(reason: String) {
        control.async { [weak self] in self?.restart(reason: reason) }
    }

    /// Rebuild the tap onto whatever the default output is *now*, keeping the
    /// same file open and the same clock.
    ///
    /// Re-resolving the device is half the point rather than a side effect.
    /// `createTap` passes `deviceUID = nil`, which means "the default output",
    /// and that binds once when the tap is made. Somebody putting headphones on
    /// mid-meeting therefore moved the audio to a device the tap was not on,
    /// and nothing in here could follow it. See `watchDefaultOutput`.
    /// **Runs on `control`, never on `queue`.** `AudioDeviceStop` waits for the
    /// IO proc to return, and the IO proc is dispatched onto `queue`, so tearing
    /// the tap down from there deadlocks the recording it is trying to save.
    private func restart(reason: String) {
        dispatchPrecondition(condition: .onQueue(control))
        guard isRecording, #available(macOS 14.2, *) else { return }
        // A rebuild costs a fraction of a second of far-end audio, so a tap
        // that is failing continuously must not be rebuilt continuously: that
        // trades a torn recording for a shredded one.
        guard Date().timeIntervalSince(lastRestartAttempt) >= restartDebounce else { return }
        lastRestartAttempt = Date()

        // Nothing may flush or judge health while the tap is in pieces. The
        // `sync` is what makes the suspend mean something: suspending a timer
        // does not wait for a handler that is already running, and that handler
        // writes to the same file this is about to pad.
        drain?.suspend()
        queue.sync {}
        teardownTap()
        var rebuilt = false
        do {
            try buildTap()
            rebuilt = true
        } catch {
            log("system audio: \(reason); could not rebuild the tap "
                + "(\(error.localizedDescription)), still trying")
        }
        drain?.resume()

        guard rebuilt else { return }
        // The bookkeeping belongs to `queue`, which is the only place health is
        // read or written once the timer is running again.
        queue.async { [weak self] in
            guard let self else { return }
            self.published.restarts += 1
            self.health.reset()
            // stderr rather than `trace`, for the reason `MicRecorder.restart`
            // gives: the seconds this costs are not recoverable from anything
            // else on disk.
            log("system audio: \(reason); rebuilt the tap "
                + "(\(self.published.restarts) restart"
                + (self.published.restarts == 1 ? "" : "s") + " so far)")
            self.onHealthChange?(self.published)
        }
    }

    /// Stop and destroy the IO proc as well as the tap and aggregate. `stop()`
    /// does this inline; a rebuild needs it without ending the recording.
    private func teardownTap() {
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
            self.ioProc = nil
        }
        flush()                       // whatever the last tick did not take
        teardown()
    }

    /// Runs on the drain queue, four times a second.
    private func checkHealth() {
        guard isRecording else { return }
        var next = published
        next.torn = health.isTorn
        next.deafFor = health.deafFor()
        // Cached, not read here. This runs four times a second for the length
        // of a meeting, and the answer can only change when the default output
        // changes, which `watchDefaultOutput` is already told about.
        next.tappingBluetooth = tappingBluetooth

        // Torn is the certain one, so it acts on its own. Deafness is not, and
        // is left for `Capture` to judge against the microphone.
        if next.torn { requestRestart(reason: "the far side is arriving torn") }

        // Publishing four times a second would redraw the panel for a clock
        // nobody reads that precisely, so the seconds are bucketed. Everything
        // else is announced the moment it changes.
        //
        // The clock is only worth ticking once it is heading somewhere. Below
        // this the far end has merely paused, and publishing every five seconds
        // for an hour would rebuild the menus and redraw both meters for a
        // number nothing displays: `onChange` is not a cheap call.
        let ticking = max(next.deafFor, published.deafFor) >= 30
        let bucket = Int(next.deafFor) / 5
        let wasBucket = Int(published.deafFor) / 5
        let changed = next.torn != published.torn
            || next.tappingBluetooth != published.tappingBluetooth
            || (ticking && bucket != wasBucket)
        published = next
        if changed { onHealthChange?(published) }
    }

    /// Rebuild when the default output device changes, so the tap follows the
    /// audio instead of staying on the device it was born on.
    ///
    /// This is the honest version of "get off Bluetooth". Pinning the tap to
    /// the built-in output while somebody listens on a headset would record
    /// perfect silence, because a tap only hears the device it is on and the
    /// meeting is coming out of the headset. Following the route is the part
    /// that is always right.
    private func watchDefaultOutput() {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            trace("system tap: default output device changed")
            self?.requestRestart(reason: "the output device changed")
        }
        // `control` rather than `queue`, so the notification cannot arrive on
        // the queue the IO proc is dispatched to. See `restart`.
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, block)
        guard status == noErr else {
            trace("system tap: could not watch the output device (status \(status))")
            return
        }
        defaultOutputListener = block
        trace("system tap: watching the default output device")
    }

    private func unwatchDefaultOutput() {
        guard let defaultOutputListener else { return }
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, control, defaultOutputListener)
        self.defaultOutputListener = nil
    }

    // -----------------------------------------------------------------------

    /// Realtime context. Copy and return, nothing else.
    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let buffer = input.pointee.mBuffers
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
        let bytes = UnsafeRawBufferPointer(start: data, count: Int(buffer.mDataByteSize))
        lock.lock()
        pending.append(contentsOf: bytes)
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let raw = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !raw.isEmpty, let source = sourceFormat, let converter, let writer else { return }

        let frames = raw.count / Int(source.streamDescription.pointee.mBytesPerFrame)
        guard frames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: source,
                                           frameCapacity: AVAudioFrameCount(frames))
        else { return }
        inBuf.frameLength = AVAudioFrameCount(frames)
        raw.withUnsafeBytes { src in
            guard let dst = inBuf.floatChannelData?[0], let base = src.baseAddress else { return }
            // Clamp to what the destination channel actually holds. The tap is
            // asked for mono, but a format with more channels than expected
            // would otherwise write past the end of the buffer, which is a heap
            // overflow rather than a wrong-sounding recording.
            let capacity = Int(inBuf.frameCapacity) * MemoryLayout<Float>.size
            memcpy(dst, base, min(raw.count, capacity))
        }

        let ratio = SAMPLE_RATE / source.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity)
        else { return }

        var err: NSError?
        var supplied = false
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return inBuf
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else {
            if let err { trace("system convert failed: \(err.localizedDescription)") }
            return
        }

        var samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        Self.tear(&samples)
        if !sawAudio, samples.contains(where: { abs($0) > 0.0001 }) {
            sawAudio = true
            trace("system audio has signal")
        }
        // The converted samples rather than the source ones, deliberately: the
        // thresholds in `TapHealth` were measured on the 16 kHz files this
        // writes, so checking anything else would be checking a signal nobody
        // has calibrated against.
        health.feed(samples, sampleRate: SAMPLE_RATE)
        try? writer.append(samples)
        report(samples)
    }

    /// The same 32 ms windowing as the microphone track, through the same
    /// mapping, so the two lanes on screen are comparable. A far side that looks
    /// twice as loud as you for the same signal would send people hunting for a
    /// gain problem that is really a scale problem.
    private func report(_ samples: [Float]) {
        guard let onLevel else { return }
        let window = Int(SAMPLE_RATE / 31)
        var i = 0
        while i < samples.count {
            let end = min(i + window, samples.count)
            onLevel(MicRecorder.loudness(samples[i..<end]))
            i = end
        }
    }

    // -----------------------------------------------------------------------

    @available(macOS 14.2, *)
    private func createTap() throws -> AudioObjectID {
        let description = CATapDescription()
        description.name = "Listen"
        // Empty list plus `isExclusive` means "everything except nothing",
        // which is how you say "all processes". The two properties have to move
        // together: `processes = []` with `isExclusive = false` is an *include*
        // list of nothing, and it does not fail. It creates a tap, reports a
        // sensible 48 kHz mono format, and delivers correctly sized buffers of
        // pure zeros for as long as you care to record. An hour of silence with
        // no error anywhere is the worst failure this file can produce, so read
        // the header: "True if this description should tap all processes except
        // the process listed in the 'processes' property."
        //
        // Tapping everything is also what a meeting needs. The participants'
        // audio comes out of a browser or the Zoom client, and narrowing to a
        // guessed list of bundle identifiers is the other way to record silence.
        description.processes = []
        description.isExclusive = true
        description.isPrivate = true            // not visible to other apps
        description.isMixdown = true            // one stream, not one per process
        description.isMono = true               // the pipeline is mono anyway
        // Do not mute what is being tapped. Muting is right for a recorder that
        // replaces playback; here the user is in a meeting and still needs to
        // hear it.
        description.muteBehavior = .unmuted
        description.deviceUID = nil             // system default output
        description.stream = 0

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &id)
        guard status == noErr else { throw CaptureError.tapFailed(status) }
        return id
    }

    private func createAggregate() throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Listen",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceSubDeviceListKey: [] as CFArray,
            kAudioAggregateDeviceMasterSubDeviceKey: 0,
            // Private, so it does not appear in Sound preferences and cannot be
            // selected as anyone's output by accident.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
        ]
        var id = AudioObjectID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else { throw CaptureError.aggregateFailed(status) }
        return id
    }

    private func addTap(_ tap: AudioObjectID, to device: AudioObjectID) throws {
        var address = Self.address(kAudioTapPropertyUID)
        var size = UInt32(MemoryLayout<CFString>.stride)
        var uid: CFString = "" as CFString
        let read = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, $0)
        }
        guard read == noErr else { throw CaptureError.tapFailed(read) }

        address = Self.address(kAudioAggregateDevicePropertyTapList)
        let list = [uid] as CFArray
        let status = withUnsafePointer(to: list) {
            AudioObjectSetPropertyData(device, &address, 0, nil,
                                       UInt32(MemoryLayout<CFArray>.stride), $0)
        }
        guard status == noErr else { throw CaptureError.tapAssignFailed(status) }
    }

    /// The aggregate's input format, once it has one.
    ///
    /// Polls, because the device is not ready the moment it is created and an
    /// early read returns a zero sample rate. A converter built from that
    /// silently produces nothing, so the failure shows up an hour later as an
    /// empty file rather than here as an error.
    private func deviceFormat(_ device: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = Self.address(kAudioDevicePropertyStreamFormat,
                                   scope: kAudioDevicePropertyScopeInput)
        for attempt in 0..<20 {
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.stride)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &asbd)
            if status == noErr, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0 {
                if attempt > 0 { trace("aggregate ready after \(attempt) polls") }
                return asbd
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw CaptureError.deviceNotReady
    }

    private func teardown() {
        if tapID != kAudioObjectUnknown {
            // Leaking a tap is not free: it survives the process, and the next
            // run adds another to the same system.
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if deviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(deviceID)
            deviceID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    deinit { teardown() }
}

enum CaptureError: Error, LocalizedError {
    case tapFailed(OSStatus)
    case aggregateFailed(OSStatus)
    case tapAssignFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case deviceNotReady
    case badFormat(Double, UInt32)
    case tapUnsupported
    case noInputDevice
    case micUnitFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .tapFailed(let s):
            // The one people actually hit. A tap needs the microphone
            // permission even though it records no microphone, and the error
            // for "not granted" is indistinguishable from any other failure.
            return "could not create the audio tap (status \(s)). "
                 + "Listen needs audio recording permission in System Settings."
        case .aggregateFailed(let s):  return "could not create the audio device (status \(s))"
        case .tapAssignFailed(let s):  return "could not attach the tap (status \(s))"
        case .ioProcFailed(let s):     return "could not start reading audio (status \(s))"
        case .deviceStartFailed(let s): return "could not start the audio device (status \(s))"
        case .deviceNotReady:          return "the audio device never became ready"
        case .badFormat(let rate, let ch):
            return "the audio device reported an unusable format (\(rate) Hz, \(ch) ch)"
        case .tapUnsupported:
            return "capturing system audio needs macOS 14.2 or later; "
                 + "recording the microphone only"
        case .noInputDevice:
            return "there is no microphone to record from"
        case .micUnitFailed(let s):
            return "could not create the microphone capture unit (status \(s))"
        }
    }
}
