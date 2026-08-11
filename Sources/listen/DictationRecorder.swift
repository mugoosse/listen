import AppKit
import AVFoundation
import CoreAudio

// Audio capture for a dictation: mic -> 16 kHz mono Float32 held in memory,
// which is what Parakeet expects.
//
// Ported from Speak's `Recorder`, and deliberately not folded into
// `MicRecorder`. The two answer different questions. `MicRecorder` streams an
// hour of a meeting to a `WAVWriter` and carries the watchdog, the silence
// detection and the mid-recording device switching that an hour needs; a
// dictation is seconds long, fits in memory, and must not pay for any of that.
// Adding an in-memory mode to the meeting recorder would put a second set of
// branches through the code whose one rule is never to lose a recording.
//
// The HAL setup below is duplicated between the two files as the cheaper half
// of that trade. Both are the *same* setup, measured once in Speak: the order
// of the property calls is the fix, and it is written up in both places rather
// than in neither.

enum DictationRecorderError: Error {
    case noInputDevice
    case noAudioUnit
    case cannotSelectDevice(OSStatus, String)
    case badFormat
    case cannotStart(OSStatus)
}

final class DictationRecorder {
    /// The capture unit, built per recording and disposed at the end of it.
    ///
    /// Not an `AVAudioEngine`. `AVAudioEngine` chooses its input device the
    /// instant `inputNode` is touched, and the only way to move it afterwards
    /// is to reach through to this same audio unit, by which time the wrong
    /// device is already open. See `build(on:)` for what that cost.
    private var unit: AudioUnit?
    private var converter: AVAudioConverter?
    private var scratch: AVAudioPCMBuffer?
    private var samples: [Float] = []
    private let lock = NSLock()
    private(set) var isRecording = false

    /// Fired once per recording, when the first converted samples arrive.
    ///
    /// The start cue hangs off this rather than off `start()`, so it means
    /// "the microphone is live" instead of "a key was pressed". Those are not
    /// the same moment: the device takes a beat to spin up, and if another app
    /// holds it it may never arrive at all, in which case staying silent is the
    /// honest outcome.
    var onFirstBuffer: (@Sendable () -> Void)?
    private var sawFirstBuffer = false

    /// Fired repeatedly while recording with how loud the microphone is right
    /// now, 0 for a silent room and 1 for somebody shouting into it.
    ///
    /// This exists so the recording pill can show that Listen is hearing *you*
    /// rather than only that it is switched on. Those are different claims, and
    /// the second one is the one that goes wrong: a muted input, a headset that
    /// went back to the case, a mic pointed at the wrong side of the laptop all
    /// look identical to a blinking dot.
    var onLevel: (@Sendable (Float) -> Void)?

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: SAMPLE_RATE,
        channels: 1,
        interleaved: false
    )!

    /// Biggest slice the unit may hand the callback. `scratch` is sized from
    /// it, and the callback refuses anything larger rather than overrunning.
    private static let maxFrames: UInt32 = 4096

    deinit { teardown() }

    func start() throws {
        guard !isRecording else { return }
        lock.lock(); samples.removeAll(); lock.unlock()
        sawFirstBuffer = false
        traced = 0

        guard let device = Settings.resolvedMicrophone else {
            throw DictationRecorderError.noInputDevice
        }
        let unit = try build(on: device)
        self.unit = unit

        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            // Tear the unit down before rethrowing. `stop()` will not: it guards
            // on `isRecording`, which is still false because this failed. A unit
            // that outlives the failure holds the device open for the rest of
            // the session, and on a Bluetooth headset that means holding it in
            // hands-free mode with nothing recording.
            teardown()
            throw DictationRecorderError.cannotStart(status)
        }
        isRecording = true
    }

    /// Builds a capture unit already pointed at `device`.
    ///
    /// The order here is the whole fix, and it is measured. `AVAudioEngine`
    /// binds its input to whatever the *system default* input is at the moment
    /// `inputNode` is first read, and it binds to a `CADefaultDeviceAggregate`
    /// wrapping both default devices rather than to the device itself. With
    /// music playing on a Bluetooth headset and the built-in microphone chosen
    /// in Settings, that one property read dropped the headset from 44100 Hz to
    /// 16000 Hz, which is the hands-free profile: the music went mono and the
    /// headset announced a call. Setting the device afterwards returned `noErr`
    /// and did not take effect until the *second* recording of the session, so
    /// the first dictation after launch captured 0 buffers in 1.5 seconds and
    /// produced nothing at all.
    ///
    /// A HAL unit takes the device before `AudioUnitInitialize`, so no default
    /// device is ever opened. Measured on the same machine and headset: the
    /// Bose stayed at 44100 Hz throughout, its input never ran, and the first
    /// recording delivered 141 buffers.
    private func build(on device: AudioDevice) throws -> AudioUnit {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw DictationRecorderError.noAudioUnit
        }
        var made: AudioUnit?
        guard AudioComponentInstanceNew(component, &made) == noErr, let unit = made else {
            throw DictationRecorderError.noAudioUnit
        }

        // A capture unit: input bus on, output bus off. Without disabling the
        // output the unit also opens the default *output* device, which on a
        // Bluetooth headset is the other half of the same profile switch.
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
        guard selected == noErr else {
            // Fatal, unlike a fallback to "whatever the unit already had". There
            // is no such thing here: an uninitialised unit with no device
            // recording is not a degraded recording, it is no recording, and
            // saying so beats capturing the wrong microphone in silence.
            AudioComponentInstanceDispose(unit)
            throw DictationRecorderError.cannotSelectDevice(selected, device.name)
        }

        // Read the hardware format *after* selecting the device: each device
        // has its own sample rate, and a converter built from another device's
        // format resamples from the wrong source rate.
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 1, &hardware, &size) == noErr,
              hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
              let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: hardware.mSampleRate,
                                           channels: hardware.mChannelsPerFrame,
                                           interleaved: false)
        else {
            AudioComponentInstanceDispose(unit)
            throw DictationRecorderError.badFormat
        }

        // Ask for the format the converter is built from, rather than taking
        // the hardware's and describing it twice. Channel count is left alone
        // and the down-mix to mono stays with `AVAudioConverter`.
        var client = inFormat.streamDescription.pointee
        guard AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 1, &client,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size)) == noErr
        else {
            AudioComponentInstanceDispose(unit)
            throw DictationRecorderError.badFormat
        }

        var maxFrames = DictationRecorder.maxFrames
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice,
                             kAudioUnitScope_Global, 0, &maxFrames,
                             UInt32(MemoryLayout<UInt32>.size))

        converter = AVAudioConverter(from: inFormat, to: target)
        scratch = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: DictationRecorder.maxFrames)
        guard converter != nil, scratch != nil else {
            AudioComponentInstanceDispose(unit)
            throw DictationRecorderError.badFormat
        }

        var callback = AURenderCallbackStruct(
            inputProc: DictationRecorder.render,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                             kAudioUnitScope_Global, 0, &callback,
                             UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        let initialised = AudioUnitInitialize(unit)
        guard initialised == noErr else {
            AudioComponentInstanceDispose(unit)
            throw DictationRecorderError.cannotStart(initialised)
        }

        trace("dictating from \(device.name) at \(Int(hardware.mSampleRate)) Hz, "
              + "\(hardware.mChannelsPerFrame) ch")
        return unit
    }

    /// The audio thread. Renders into `scratch`, converts, and hands the result
    /// on. Unretained `self`: `teardown()` stops and disposes the unit, and it
    /// runs from `stop()` and from `deinit`, so the unit cannot outlive the
    /// object whose pointer it holds.
    private static let render: AURenderCallback = { context, flags, timestamp, bus, frames, _ in
        let recorder = Unmanaged<DictationRecorder>.fromOpaque(context).takeUnretainedValue()
        return recorder.capture(flags, timestamp, bus, frames)
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
        // `mutableAudioBufferList`, so setting the sizes through one call and
        // then passing a second call's list to `AudioUnitRender` hands it a
        // list claiming zero bytes. That is `paramErr` (-50) on every slice
        // forever: the device runs, so macOS shows the microphone indicator,
        // but not one buffer arrives, `onFirstBuffer` never fires, and there is
        // no pill, no start cue and no audio.
        scratch.frameLength = frames

        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, scratch.mutableAudioBufferList)
        guard status == noErr else {
            traceAudio("render \(frames) frames failed: \(status)")
            return status
        }

        let ratio = SAMPLE_RATE / scratch.format.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { traceAudio("no output buffer"); return noErr }

        var err: NSError?
        var supplied = false
        conv.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return scratch
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0]
        else {
            traceAudio("convert \(frames) -> \(out.frameLength), err \(String(describing: err))")
            return noErr
        }
        traceAudio("captured \(frames) -> \(out.frameLength)")

        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        let first = !sawFirstBuffer
        sawFirstBuffer = true
        lock.unlock()
        if first { onFirstBuffer?() }
        report(chunk)
        return noErr
    }

    /// Debug-only, and capped at a handful of lines per recording.
    ///
    /// Named apart from the global `trace` on purpose: this runs on the audio
    /// thread, where logging every slice would both flood the log and stall the
    /// render callback into producing the very dropouts being chased. A call
    /// that looks like the ordinary one would get added to inside the loop.
    private var traced = 0
    private func traceAudio(_ s: String) {
        guard DEBUG, traced < 8 else { return }
        traced += 1
        log(s)
    }

    /// Splits one captured buffer into short windows and reports each one's
    /// loudness.
    ///
    /// Per window rather than per buffer: a buffer is about 85 ms, which is
    /// twelve updates a second, and a meter stepping twelve times a second
    /// looks like it is struggling rather than listening. 32 ms windows give
    /// about thirty, which is enough for the animation to be interpolating
    /// between real measurements instead of inventing motion between stale
    /// ones.
    ///
    /// The same windows and the same mapping as `MicRecorder.report`, so the
    /// dictation pill and the meeting strip cannot disagree about what a level
    /// means.
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

    /// Stops capture and hands back raw samples. No temp file: the samples go
    /// straight into an MLXArray.
    func stop() -> [Float]? {
        guard isRecording else { return nil }
        teardown()
        isRecording = false

        lock.lock(); let pcm = samples; samples.removeAll(); lock.unlock()
        return pcm.count > Int(SAMPLE_RATE / 10) ? pcm : nil   // ignore < 0.1 s
    }

    /// Releases the device.
    ///
    /// Disposed rather than kept for the next recording, which is the other
    /// half of leaving a Bluetooth headset alone: a unit that is merely stopped
    /// still holds its device, so the headset would sit in hands-free mode from
    /// the first dictation until the app quit. Disposing also means the device
    /// is re-resolved every time, so changing the microphone in Settings takes
    /// effect on the next dictation rather than the next launch.
    private func teardown() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        converter = nil
        scratch = nil
    }
}
