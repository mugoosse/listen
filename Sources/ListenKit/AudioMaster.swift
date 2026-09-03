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
/// **Measured again on a real meeting**, once the encoder was wired into the
/// sync rather than only into the seam suite. `listen audio <id> --build` on a
/// 1.07 hour two-track conversation:
///
///     tracks   494.4 MB   (Float32, 461 MB/h)
///     master    61.0 MB   (12% of the tracks, 57 MB/h)
///     built in   3.8 s
///
/// Two things that run of the whole file showed and three seconds of tones
/// could not. It is fast: an hour of conversation is four seconds, so building
/// a library's worth is minutes rather than the hour that was budgeted for.
/// And it is **not free of memory**: both tracks are read whole as `[Float]`,
/// which was about a gigabyte resident at the peak for that recording. That is
/// the same shape `Mixdown` has and the reason it is not worse is that
/// `pushMasters` builds three a pass; a version that built forty at once would
/// be a different question.
///
/// The master is deleted locally once `pushMasters` has landed it. The device
/// that publishes one holds the raw tracks by construction, and those are the
/// better copy for everything on that machine; keeping both would add 12% to
/// every recording on the one Mac that never needs it.
///
/// The encoder also pads its final packet, so a master is up to 4608 frames
/// longer than the tracks it came from: 513 frames, or 32 ms of silence, on
/// the recording above. Nothing is lost and nothing shifts, and the seam
/// compares the overlap for that reason rather than the lengths.
///
/// **Stereo, mic left and system right.** A mono sum is what `Mixdown` makes
/// for playback and it is worthless here: the pipeline transcribes the two
/// tracks separately on purpose, and `.agents/notes/asr.md` records why
/// ("Both tracks are clustered, so the letters are handed out once", "The far
/// end comes back in through the microphone"). Interleaving keeps them apart
/// inside one file, which also means the master fits the `asset_mic_wav` field
/// that Production already has. A second asset field would have been permanent.
public enum AudioMaster {
    /// What a master's channels are, which decides what they must be split
    /// back into.
    ///
    /// **The name on disk carries it, and that is deliberate.** A one-channel
    /// master is either a voice memo, whose channel is the microphone, or an
    /// imported meeting, whose channel is everybody at once. Those go to
    /// opposite sides of the pipeline: written back as `mic.wav`, an import
    /// would be transcribed as the user's own voice and every speaker in it
    /// would come out labelled `Me`, which is the trap
    /// `.agents/notes/speakers.md` records as "An imported recording has no mic
    /// track, and must not pretend otherwise". The channel count cannot tell
    /// them apart, so the file says which it is: a recording is a folder and
    /// the files in it are the truth, and a fact kept anywhere else is a fact
    /// that can be lost while the audio survives.
    public enum Layout: String, Codable, Sendable, CaseIterable {
        /// Microphone left, system right, or the microphone alone. Split back
        /// into the two tracks the pipeline reads.
        case tracks
        /// One track holding everybody, which is what an import has. Split back
        /// as the everyone-track and never as the microphone.
        case everyone

        var filename: String {
            switch self {
            case .tracks:   return "master.flac"
            case .everyone: return "master-everyone.flac"
            }
        }
    }

    /// One file, whatever the recording is made of.
    public static let filename = Layout.tracks.filename

    /// Every name a master can have on disk, so a caller looking for one does
    /// not have to know which kind it is.
    public static var filenames: [String] { Layout.allCases.map(\.filename) }

    /// What is actually here, if anything.
    public static func found(in folder: URL) -> (url: URL, layout: Layout)? {
        for layout in Layout.allCases {
            let url = folder.appendingPathComponent(layout.filename)
            if FileManager.default.fileExists(atPath: url.path) { return (url, layout) }
        }
        return nil
    }

    public static func url(in folder: URL, _ layout: Layout) -> URL {
        folder.appendingPathComponent(layout.filename)
    }

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
    /// What one build produced, so a caller can publish it without opening it
    /// again to find out what it is.
    public struct Built: Sendable {
        public var url: URL
        public var layout: Layout
        public var channels: Int
    }

    @discardableResult
    public static func make(micURL: URL, systemURL: URL?, mixURL: URL? = nil,
                            into folder: URL) throws -> Built? {
        if let existing = found(in: folder) {
            return Built(url: existing.url, layout: existing.layout,
                         channels: channels(in: existing.url))
        }

        let hasMic = FileManager.default.fileExists(atPath: micURL.path)
        let hasSystem = systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        // No separate tracks, only the mixdown a legacy recorder produced. That
        // is a real recording and it was getting no master at all, so a device
        // that had never seen it could neither play it nor transcribe it again,
        // for ever. It is decoded through `AVAssetReader` rather than read
        // straight, because an imported m4a is whatever sample rate and channel
        // count that recorder used and the master is 16 kHz: reading its
        // samples as though they were already 16 kHz would slow an hour of
        // conversation to three.
        guard hasMic || hasSystem else {
            guard let mixURL, FileManager.default.fileExists(atPath: mixURL.path),
                  let mixed = try decodeToMono(mixURL), !mixed.isEmpty else { return nil }
            let out = url(in: folder, .everyone)
            try writeAtomically(left: mixed, right: [], frames: mixed.count,
                                channels: 1, to: out, named: Layout.everyone.filename,
                                in: folder)
            return Built(url: out, layout: .everyone, channels: 1)
        }

        let out = url(in: folder, .tracks)
        let left = hasMic ? try read(micURL) : []
        let right = hasSystem ? try read(systemURL!) : []
        let frames = max(left.count, right.count)
        guard frames > 0 else { return nil }
        // One channel when there is only one track, rather than a silent right
        // half doubling a voice memo's size for nothing.
        let channels: AVAudioChannelCount = (hasMic && hasSystem) ? 2 : 1

        try writeAtomically(left: left, right: right, frames: frames, channels: channels,
                            to: out, named: Layout.tracks.filename, in: folder)
        return Built(url: out, layout: .tracks, channels: Int(channels))
    }

    /// Written beside the target and moved, so a master half-written by a
    /// process that died is never mistaken for one that is whole. The rest of
    /// this library writes `metadata.json` last for the same reason.
    private static func writeAtomically(left: [Float], right: [Float], frames: Int,
                                        channels: AVAudioChannelCount, to out: URL,
                                        named name: String, in folder: URL) throws {
        let temporary = folder.appendingPathComponent("." + name + ".part")
        try? FileManager.default.removeItem(at: temporary)
        try write(left: left, right: right, frames: frames, channels: channels, to: temporary)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: temporary, to: out)
    }

    /// Any audio file, as 16 kHz mono Float32, with the downmix and the sample
    /// rate conversion done inside AVFoundation rather than here.
    ///
    /// The same shape `AudioExtract` uses on the Mac, kept here because
    /// `AudioMaster` is in the shared framework and the phone compiles it too.
    private static func decodeToMono(_ url: URL) throws -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer, length >= MemoryLayout<Float>.size else { continue }
            pointer.withMemoryRebound(to: Float.self,
                                      capacity: length / MemoryLayout<Float>.size) {
                samples.append(contentsOf: UnsafeBufferPointer(
                    start: $0, count: length / MemoryLayout<Float>.size))
            }
        }
        guard reader.status != .failed else { return nil }
        return samples
    }

    /// How many channels a master carries: two for a meeting, one for a voice
    /// memo. Zero when the file is absent or will not open, which is the same
    /// answer a caller wants for both.
    public static func channels(in url: URL) -> Int {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Int(file.processingFormat.channelCount)
    }

    /// Take the master apart again, which is what makes it a master rather than
    /// a preview: a device holding only this can still re-transcribe, and gets
    /// the two separate tracks the pipeline needs rather than a mono sum.
    /// Take a master apart into whatever this device's pipeline reads.
    ///
    /// `layout` decides which side of the pipeline a one-channel master lands
    /// on, and getting it wrong is not a small error: an `everyone` master
    /// written to `mic.wav` is an imported meeting transcribed as the user's
    /// own voice, with every speaker in it labelled `Me`.
    @discardableResult
    public static func split(_ master: URL, layout: Layout = .tracks, into folder: URL,
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
        // Everybody at once goes to the system side, which is where
        // `Pipeline.run` looks for the everyone-track, and there is
        // deliberately no microphone track to go with it.
        let first = layout == .everyone ? systemURL : micURL
        try writeTrack(Array(UnsafeBufferPointer(start: data[0], count: n)), to: first)
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
        // **A track can be a header and nothing else, and reading it throws.**
        // A call whose microphone never opened leaves a 44-byte `mic.wav`, and
        // `read(into:)` fails a zero-capacity buffer with avfaudio -50 rather
        // than returning nothing. That threw out of `make`, so `pushMasters`
        // never stamped the recording and re-failed every pass for ever, while
        // the other Mac, told by the heartbeat that this one holds the audio,
        // sat on "Retrying sync: Audio is not available in iCloud yet". The
        // empty side still counts as a track: the file exists, so `make` keeps
        // both channels and the master splits back the way it was captured.
        guard file.length > 0 else { return [] }
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
