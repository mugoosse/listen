import AVFoundation
import Foundation

/// The peak envelope of a recording, for the player's scrubber.
///
/// Fixed resolution rather than one value per pixel, resampled when drawn. The
/// alternative is re-reading an hour of audio every time the window is resized
/// or the sidebar is dragged, which is the same work done again for a picture
/// that does not change.
struct Waveform: Codable {
    /// Bumped when the extraction changes, so an old cache is recomputed rather
    /// than drawn wrongly. Nothing else in the folder is versioned because
    /// nothing else is derived from a formula that might be adjusted.
    static let version = 2

    /// About twice the widest the pane realistically gets, so resampling is
    /// always downwards and the bars are an honest maximum rather than an
    /// interpolation of one.
    static let resolution = 1400

    var version: Int
    /// Peak amplitude per bucket, normalised to 0...1 across the recording.
    var peaks: [Float]
    var duration: Double
}

extension Recording {
    var waveformURL: URL { folder.appendingPathComponent("waveform.json") }

    /// What the waveform is drawn from.
    ///
    /// The mixdown when it exists, because it is one file rather than two and
    /// it is what playback will use. Otherwise both tracks, so the picture
    /// covers both sides of the conversation without paying for a mixdown a
    /// recording nobody replays does not need.
    var waveformSources: [URL] {
        let fm = FileManager.default
        if fm.fileExists(atPath: mixURL.path) { return [mixURL] }
        return tracks
    }
}

extension Waveform {
    /// The cached envelope, or nil if it has to be computed.
    static func cached(for recording: Recording) -> Waveform? {
        guard let data = try? Data(contentsOf: recording.waveformURL),
              let wave = try? JSONDecoder().decode(Waveform.self, from: data),
              wave.version == version, !wave.peaks.isEmpty
        else { return nil }
        return wave
    }

    /// Read the audio and reduce it to `resolution` peaks.
    ///
    /// Blocking and slow enough to matter: an hour of 16 kHz mono is 57 million
    /// samples per track. Call it off the main thread.
    static func make(for recording: Recording) -> Waveform? {
        let sources = recording.waveformSources
        guard !sources.isEmpty else { return nil }

        // The timeline is the longest track. Bucketing by time rather than by
        // frame index is what keeps two tracks of different lengths, or a track
        // at a different sample rate, lined up with each other and with the
        // playhead.
        var duration: Double = 0
        var files: [(AVAudioFile, Double)] = []
        for url in sources {
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            let rate = file.fileFormat.sampleRate
            guard rate > 0, file.length > 0 else { continue }
            files.append((file, rate))
            duration = max(duration, Double(file.length) / rate)
        }
        guard duration > 0 else { return nil }

        var peaks = [Float](repeating: 0, count: resolution)
        for (file, rate) in files {
            let scale = Double(resolution) / (duration * rate)
            let format = file.processingFormat
            let block: AVAudioFrameCount = 1 << 16
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block)
            else { continue }

            var frame: AVAudioFramePosition = 0
            while frame < file.length {
                do { try file.read(into: buffer) } catch { break }
                let count = Int(buffer.frameLength)
                guard count > 0, let channel = buffer.floatChannelData?[0] else { break }
                for i in 0..<count {
                    let bucket = min(resolution - 1, Int(Double(frame + AVAudioFramePosition(i)) * scale))
                    let value = abs(channel[i])
                    if value > peaks[bucket] { peaks[bucket] = value }
                }
                frame += AVAudioFramePosition(count)
            }
        }

        // Normalised for display, which is the opposite of the rule in
        // `Mixdown`: playback volume has to stay true to the recording, but a
        // scrubber drawn at true amplitude is a flat line for anyone who
        // recorded quietly, and a scrubber you cannot read is not one.
        let loudest = peaks.max() ?? 0
        if loudest > 0.0001 {
            // Square root, not linear. Speech is a few loud syllables over a
            // lot of quiet ones, so a linear envelope is spikes on a floor and
            // the quiet passages are indistinguishable from silence.
            for i in peaks.indices { peaks[i] = (peaks[i] / loudest).squareRoot() }
        } else {
            peaks = [Float](repeating: 0, count: resolution)
        }

        return Waveform(version: version, peaks: peaks, duration: duration)
    }

    /// Compute it if needed and leave it next to the audio.
    ///
    /// Cached on disk for the same reason `mix.m4a` is: it is derived, it is
    /// cheap to store, and recomputing it every time somebody clicks between
    /// two recordings is seconds of file reading for a picture that cannot have
    /// changed. Deleting `waveform.json` costs one recomputation, so it stays a
    /// cache rather than becoming state.
    static func load(for recording: Recording) -> Waveform? {
        if let cached = cached(for: recording) { return cached }
        guard let wave = make(for: recording) else { return nil }
        let enc = JSONEncoder()
        try? enc.encode(wave).write(to: recording.waveformURL, options: .atomic)
        return wave
    }
}
