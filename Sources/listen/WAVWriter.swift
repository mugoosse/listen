import Foundation

/// Streams 32-bit float PCM to a WAV file, rewriting the length fields as it
/// goes.
///
/// Not `AVAudioFile`, and the difference is the whole point. `AVAudioFile`
/// finalises the header when it is closed, so a crash or a power cut during an
/// hour-long meeting leaves a file whose RIFF and data chunks claim a length of
/// zero. The samples are all there on disk and nothing will play them.
///
/// This writes a header with placeholder lengths, appends samples, and patches
/// the two length fields every `headerInterval` seconds. The worst case is
/// therefore a file that is playable up to a few seconds before the crash,
/// rather than a file that is not playable at all. That is the difference
/// between losing the tail of a meeting and losing the meeting.
final class WAVWriter {
    private let handle: FileHandle
    let url: URL
    private let sampleRate: Double
    private let channels: Int

    private var frames: Int = 0
    private var lastHeaderUpdate = Date()

    /// How often the length fields are rewritten. Two seconds costs two seeks
    /// and eight bytes; there is no reason to be stingier.
    private let headerInterval: TimeInterval = 2

    private static let headerBytes = 44

    init(url: URL, sampleRate: Double = SAMPLE_RATE, channels: Int = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels

        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels,
                                                 frames: 0))
    }

    /// A 44-byte canonical WAV header for IEEE float samples.
    ///
    /// Format tag 3, not 1: these are floats, and a reader told they are
    /// integers will decode noise at full scale.
    private static func header(sampleRate: Double, channels: Int, frames: Int) -> Data {
        let bitsPerSample = 32
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = Int(sampleRate) * blockAlign
        let dataBytes = frames * blockAlign

        var d = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v).littleEndian) {
            d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(truncatingIfNeeded: v).littleEndian) {
            d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                     // PCM header size
        u16(3)                      // IEEE float
        u16(channels)
        u32(Int(sampleRate))
        u32(byteRate)
        u16(blockAlign)
        u16(bitsPerSample)
        d.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return d
    }

    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        try samples.withUnsafeBufferPointer {
            try handle.write(contentsOf: Data(buffer: $0))
        }
        frames += samples.count / channels

        if Date().timeIntervalSince(lastHeaderUpdate) >= headerInterval {
            updateHeader()
            lastHeaderUpdate = Date()
        }
    }

    /// Patch the two length fields in place without disturbing the write
    /// position.
    private func updateHeader() {
        let end = (try? handle.offset()) ?? 0
        let blockAlign = channels * 4
        let dataBytes = frames * blockAlign
        func patch(at offset: UInt64, _ value: Int) {
            try? handle.seek(toOffset: offset)
            withUnsafeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian) {
                try? handle.write(contentsOf: Data($0))
            }
        }
        patch(at: 4, 36 + dataBytes)     // RIFF chunk size
        patch(at: 40, dataBytes)         // data chunk size
        try? handle.seek(toOffset: end)
        // Ask the file system to commit. Without this the patched header can
        // sit in the buffer cache while the samples are already on the platter,
        // which is the one ordering that defeats the point of patching it.
        fsync(handle.fileDescriptor)
    }

    var duration: TimeInterval { Double(frames) / sampleRate }

    /// Fill the file with silence up to `seconds` from the recording's origin,
    /// and report how much was added.
    ///
    /// The two tracks are separate files with no timestamps in them, so a
    /// sample's position in the file **is** its position on the clock, and the
    /// two only line up while both files measure from the same instant. Every
    /// way a track can lose time (a microphone changing underneath the engine,
    /// an aggregate device taking two seconds to become ready) is therefore a
    /// gap that has to be filled rather than closed up: closing it up loses no
    /// word, but moves every word after it earlier, which silently reattributes
    /// the rest of the meeting.
    ///
    /// Measured against the wall clock rather than against the last gap, so
    /// repeated small shortfalls cannot accumulate over an hour.
    @discardableResult
    func pad(to seconds: TimeInterval) -> TimeInterval {
        let gap = seconds - duration
        // Below this the pad is smaller than the buffers arriving anyway, and
        // padding every callback would be a file made mostly of rounding.
        guard gap > 0.05 else { return 0 }

        var remaining = Int(gap * sampleRate) * channels
        let chunk = Int(sampleRate)
        while remaining > 0 {
            let n = min(chunk, remaining)
            try? append([Float](repeating: 0, count: n))
            remaining -= n
        }
        return gap
    }

    func close() {
        updateHeader()
        try? handle.close()
    }

    deinit { try? handle.close() }
}
