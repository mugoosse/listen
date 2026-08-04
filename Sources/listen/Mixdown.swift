import AVFoundation
import Foundation

/// Combines the two tracks into one file for playback.
///
/// Generated on demand rather than at transcription time, the way
/// `meet_transcriptions` does it. A library of meetings nobody ever replays
/// should not cost a second file each, and the mixdown is worthless to the
/// pipeline: transcription reads the separate tracks precisely because they are
/// separate.
enum Mixdown {
    /// Build `mix.m4a`, or return the existing one.
    ///
    /// Returns the single track unchanged when there is only one, rather than
    /// re-encoding it to prove a point.
    @discardableResult
    static func make(for recording: Recording) throws -> URL? {
        if FileManager.default.fileExists(atPath: recording.mixURL.path) {
            return recording.mixURL
        }
        let tracks = recording.tracks
        guard !tracks.isEmpty else { return nil }
        guard tracks.count > 1 else { return tracks[0] }

        var sums: [Float] = []
        for url in tracks {
            let samples = try read(url)
            if samples.count > sums.count {
                sums.append(contentsOf: repeatElement(0, count: samples.count - sums.count))
            }
            for i in samples.indices { sums[i] += samples[i] }
        }
        guard !sums.isEmpty else { return nil }

        // Scale down only if the sum actually clipped. Normalising every
        // mixdown to full scale would make a quiet meeting and a loud one play
        // back at the same volume, which is a lie about the recording.
        let peak = sums.reduce(Float(0)) { Swift.max($0, abs($1)) }
        if peak > 1 { for i in sums.indices { sums[i] /= peak } }

        try writeM4A(sums, to: recording.mixURL)
        return recording.mixURL
    }

    private static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: file.fileFormat.sampleRate,
                                   channels: 1, interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func writeM4A(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: SAMPLE_RATE,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,     // speech at 16 kHz mono, plenty
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: SAMPLE_RATE, channels: 1, interleaved: false)!

        // Write in blocks. One buffer for an hour would be a 230 MB allocation
        // for a file that is about to be 14 MB.
        let block = 1 << 16
        var offset = 0
        while offset < samples.count {
            let count = Swift.min(block, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: count)
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}
