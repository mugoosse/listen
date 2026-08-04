import AVFoundation
import AppKit

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
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var writer: WAVWriter?
    private let lock = NSLock()

    private(set) var isRecording = false
    private(set) var sawAudio = false

    private let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SAMPLE_RATE,
        channels: 1, interleaved: false)!

    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        sawAudio = false

        let input = engine.inputNode
        selectDevice(on: input)

        // Read the format *after* selecting the device. Switching inputs
        // changes the hardware sample rate, and a converter built from the
        // format read before selection resamples from the wrong source rate,
        // which records pitch-shifted and garbled.
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { throw CaptureError.badFormat(0, 0) }
        converter = AVAudioConverter(from: inFormat, to: target)
        writer = try WAVWriter(url: url)
        trace("mic format \(Int(inFormat.sampleRate)) Hz, \(inFormat.channelCount) ch")

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
            engine.reset()          // the engine caches the input format
            converter = nil
            writer?.close()
            writer = nil
            throw error
        }
        isRecording = true
    }

    /// Points the engine's input at the chosen device.
    ///
    /// `AVAudioEngine` has no device property of its own on macOS; you reach
    /// through to the input node's audio unit. Must happen before the engine
    /// starts.
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

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        lock.lock()
        writer?.close()
        writer = nil
        lock.unlock()
    }

    var duration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return writer?.duration ?? 0
    }
}
