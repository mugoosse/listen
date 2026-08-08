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

    private(set) var isRecording = false
    /// Set when the first buffer with actual signal arrives, so the UI can say
    /// "capturing" rather than "started" when it means it.
    private(set) var sawAudio = false

    /// The newest loudness of the far side, 0...1, about thirty times a second.
    ///
    /// Called off the IO proc's realtime thread: `receive` already hands its
    /// bytes to `queue` before converting, so this arrives on that queue and the
    /// consumer hops to the main actor with `DispatchQueue.main.async`.
    ///
    /// No silence detector on this track, deliberately, and the asymmetry is the
    /// point. Bit-exact zero from a process tap is the ordinary state of a Mac
    /// with nothing playing, so the test that is certain for a microphone means
    /// nothing here. A quiet far side is a quiet far side.
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

        writer = try WAVWriter(url: url)

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
        // silence that represents the time already spent getting here.
        let padded = writer?.pad(to: Date().timeIntervalSince(origin)) ?? 0
        if padded > 0 {
            trace("system padded \(String(format: "%.1f", padded))s to stay aligned with the mic")
        }

        let started = AudioDeviceStart(deviceID, procID)
        guard started == noErr else {
            teardown()
            throw CaptureError.deviceStartFailed(started)
        }

        // Drain on a timer rather than from the IO proc, so the realtime thread
        // never waits on a file write.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
        drain = timer

        isRecording = true
        trace("system capture started -> \(url.lastPathComponent)")
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        drain?.cancel()
        drain = nil
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

        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        if !sawAudio, samples.contains(where: { abs($0) > 0.0001 }) {
            sawAudio = true
            trace("system audio has signal")
        }
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
