import AVFoundation
import Foundation

/// Pulls individual tracks out of a multi-track audio file.
///
/// This exists for the import. The legacy recorder wrote **one m4a with two
/// tracks in it**: a stereo one carrying what the Mac was playing, and a mono
/// one carrying the microphone. Everything that reads such a file casually
/// reads only the first track, which is why the diarizer heard exactly one
/// person in an 80 minute two-person call and reported it without complaint.
///
/// Split properly, an imported recording is the same shape as one Listen
/// captured itself, and the whole two-track pipeline applies to it: diarize the
/// system side, label the microphone side as the user, merge.
enum AudioExtract {

    struct Tracks {
        /// The stereo track: what the Mac was playing, so everyone else.
        var system: Int?
        /// The mono track: the microphone, so the user.
        var mic: Int?
        var count: Int
    }

    /// Work out which track is which.
    ///
    /// By channel count, not by index. A system mixdown is stereo and a
    /// microphone is mono, which is a property of what they are rather than of
    /// the order this particular recorder happened to write them in. Index is
    /// only the tiebreak.
    static func classify(_ asset: AVAsset) async -> Tracks {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else {
            return Tracks(system: nil, mic: nil, count: 0)
        }
        var system: Int?
        var mic: Int?
        for (index, track) in tracks.enumerated() {
            let channels = await channelCount(track)
            if channels >= 2, system == nil { system = index }
            else if channels == 1, mic == nil { mic = index }
        }
        // One track and nothing to split: it is a mixdown, and the caller
        // treats it as such rather than pretending either side is isolated.
        if tracks.count == 1 { return Tracks(system: nil, mic: nil, count: 1) }
        if system == nil, mic == nil, !tracks.isEmpty { system = 0 }
        return Tracks(system: system, mic: mic, count: tracks.count)
    }

    private static func channelCount(_ track: AVAssetTrack) async -> Int {
        guard let descriptions = try? await track.load(.formatDescriptions) else { return 0 }
        for description in descriptions {
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                return Int(basic.pointee.mChannelsPerFrame)
            }
        }
        return 0
    }

    /// Decode one track to a 16 kHz mono Float32 WAV.
    ///
    /// The reader is asked for that format directly, so the downmix and the
    /// sample-rate conversion happen inside AVFoundation rather than here.
    static func extract(track index: Int, from url: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard index < tracks.count else { throw ExtractError.noSuchTrack(index) }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: tracks[index],
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: SAMPLE_RATE,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
        guard reader.canAdd(output) else { throw ExtractError.cannotRead }
        reader.add(output)
        guard reader.startReading() else {
            throw ExtractError.cannotRead
        }

        let writer = try WAVWriter(url: destination)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == noErr,
                  let pointer, length >= MemoryLayout<Float>.size else { continue }
            let samples = pointer.withMemoryRebound(to: Float.self,
                                                    capacity: length / MemoryLayout<Float>.size) {
                Array(UnsafeBufferPointer(start: $0, count: length / MemoryLayout<Float>.size))
            }
            try writer.append(samples)
        }
        writer.close()

        if reader.status == .failed {
            try? FileManager.default.removeItem(at: destination)
            throw reader.error ?? ExtractError.cannotRead
        }
    }

    enum ExtractError: Error, LocalizedError {
        case noSuchTrack(Int)
        case cannotRead

        var errorDescription: String? {
            switch self {
            case .noSuchTrack(let i): return "the file has no audio track \(i)"
            case .cannotRead:         return "could not decode the audio"
            }
        }
    }
}
