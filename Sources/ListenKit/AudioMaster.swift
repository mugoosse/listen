import AVFoundation
import Foundation

/// The one audio file that travels, and the only copy that has to survive.
///
/// **Why this exists at all.** Audio used to move exactly once, from the phone
/// to whichever Mac claimed it, and then never again: `mic.wav` is not a
/// sidecar, and the transfer record it arrived in is deleted the moment a Mac
/// has the bytes. So the machine you were sitting at was usually not the
/// machine that could play your memo back, and a recording whose only Mac was
/// shut was a transcript with no sound under it.
///
/// A replicated master fixes that, and the whole question is what to replicate.
/// Measured on this library, 24.4 hours in 40 recordings:
///
///     raw Float32 mic.wav + system.wav   500 MB/h   12.2 GB   the truth
///     FLAC, stereo, Int16                 68 MB/h    1.7 GB   lossless
///     AAC, stereo, 48 kbps per channel    43 MB/h    1.0 GB   98.9% of words
///
/// **FLAC, because lossless is what makes the delete switch honest.** A device
/// that frees its raw tracks has to be giving up nothing, or "keep audio" is a
/// choice between space and quality rather than a choice about space. The AAC
/// row is real and was measured the same way (`orig.wav` against a round trip,
/// with a second run of the original as the control, which diverged 0.0%), and
/// 1.1% of words is a small price; it is just not a price anybody should pay
/// silently on the copy that is meant to be the master.
///
/// **Stereo, mic left and system right.** A mono sum is what `Mixdown` makes
/// for playback and it is worthless here: the pipeline transcribes the two
/// tracks separately on purpose, and `.agents/notes/asr.md` records why
/// ("Both tracks are clustered, so the letters are handed out once", "The far
/// end comes back in through the microphone"). Interleaving keeps them apart
/// inside one file, which also means the master fits the `asset_mic_wav` field
/// that Production already has. A second asset field would have been permanent.
public enum AudioMaster {
    /// One file, whatever the recording is made of.
    public static let filename = "master.flac"

    /// 16 kHz, because everything downstream of capture is, and Int16, because
    /// `AudioFile` measured Float32 as 144 dB of range for a source with about
    /// 70 and `tools/flac_control.sh` measured the conversion as costing the
    /// transcript nothing once the model's own run-to-run variance is
    /// subtracted.
    static let sampleRate = 16_000.0
    static let bitDepth = 16

    public static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(filename)
    }

    /// Build the master from whatever tracks are on disk, or return the one
    /// that is already there.
    ///
    /// Nil when there is no audio here at all, which is the ordinary state of a
    /// recording this device has only ever received.
    @discardableResult
    public static func make(micURL: URL, systemURL: URL?, into folder: URL) throws -> URL? {
        let out = url(in: folder)
        if FileManager.default.fileExists(atPath: out.path) { return out }

        let hasMic = FileManager.default.fileExists(atPath: micURL.path)
        let hasSystem = systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        guard hasMic || hasSystem else { return nil }

        let left = hasMic ? try read(micURL) : []
        let right = hasSystem ? try read(systemURL!) : []
        let frames = max(left.count, right.count)
        guard frames > 0 else { return nil }
        // One channel when there is only one track, rather than a silent right
        // half doubling a voice memo's size for nothing.
        let channels: AVAudioChannelCount = (hasMic && hasSystem) ? 2 : 1

        // Written beside the target and moved, so a master half-written by a
        // process that died is never mistaken for one that is whole. The rest
        // of this library writes `metadata.json` last for the same reason.
        let temporary = folder.appendingPathComponent("." + filename + ".part")
        try? FileManager.default.removeItem(at: temporary)
        try write(left: left, right: right, frames: frames, channels: channels, to: temporary)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: temporary, to: out)
        return out
    }

    /// Take the master apart again, which is what makes it a master rather than
    /// a preview: a device holding only this can still re-transcribe, and gets
    /// the two separate tracks the pipeline needs rather than a mono sum.
    @discardableResult
    public static func split(_ master: URL, into folder: URL,
                             micURL: URL, systemURL: URL) throws -> Int {
        let file = try AVAudioFile(forReading: master)
        let channels = Int(file.processingFormat.channelCount)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: file.fileFormat.sampleRate,
                                   channels: file.processingFormat.channelCount,
                                   interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { return 0 }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else { return 0 }

        // Through `AudioFile.Writer`, so the two tracks come out in exactly the
        // format the rest of Listen reads: 16 kHz Int16 mono WAV, with the
        // header rewritten on close. Anything else here would be a second
        // definition of "a Listen track".
        try writeTrack(Array(UnsafeBufferPointer(start: data[0], count: n)), to: micURL)
        if channels > 1 {
            try writeTrack(Array(UnsafeBufferPointer(start: data[1], count: n)), to: systemURL)
        }
        return channels
    }

    private static func writeTrack(_ samples: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AudioFile.Writer(url: url)
        var at = 0
        while at < samples.count {
            let count = min(48_000, samples.count - at)
            try writer.append((at..<(at + count)).map { quantise(samples[$0]) })
            at += count
        }
        _ = try writer.close()
    }

    // MARK: - The two traps

    private static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: file.fileFormat.sampleRate,
                                   channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func write(left: [Float], right: [Float], frames: Int,
                              channels: AVAudioChannelCount, to out: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVEncoderBitDepthHintKey: bitDepth,
        ]

        // **Int16 buffers, interleaved, or the encoder writes 24-bit.**
        // `AVEncoderBitDepthHintKey` is a hint and loses to the buffer it is
        // handed: with Float32 buffers the same audio came out 19.2 MB against
        // ffmpeg's 10.5 MB, and `afinfo` said "from 24-bit source". Feeding it
        // Int16 lands within 1% of ffmpeg, and the round trip is sample exact.
        var file: AVAudioFile? = try AVAudioFile(forWriting: out, settings: settings,
                                                 commonFormat: .pcmFormatInt16,
                                                 interleaved: true)
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                   channels: channels, interleaved: true)!
        var written = 0
        while written < frames {
            let count = min(48_000, frames - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(count))
            else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            guard let samples = buffer.int16ChannelData?[0] else { break }
            let stride = Int(channels)
            for i in 0..<count {
                let at = written + i
                samples[i * stride] = quantise(at < left.count ? left[at] : 0)
                if stride == 2 {
                    samples[i * stride + 1] = quantise(at < right.count ? right[at] : 0)
                }
            }
            try file?.write(from: buffer)
            written += count
        }

        // **Finalising is a deallocation, and nothing else does it.** A FLAC
        // stream's header carries totals that are only known at the end, the
        // way a WAV header does, and `AVAudioFile` rewrites them when it goes
        // away. Left alive to the end of the process the file was the right
        // size and the right length and `ffprobe` refused it outright:
        // "Invalid data found when processing input".
        file = nil
    }

    private static func quantise(_ v: Float) -> Int16 {
        Int16(max(-32_768, min(32_767, (v * 32_767).rounded())))
    }
}
