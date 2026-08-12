import Foundation

/// WAV reading and writing, in the one format both apps use.
///
/// 16 kHz mono. Parakeet wants 16 kHz and there is nothing above 8 kHz in a
/// conversation worth keeping, so recording higher costs storage and buys
/// nothing the pipeline can use.
///
/// **Int16, not Float32.** The Mac records Float32 today, which is 512 kbps of
/// 16 kHz speech carrying 144 dB of dynamic range for a source with perhaps
/// 70. Measured 2026-08-07 on a real 33-minute recording: Float32 120.6 MB,
/// Int16 60.3 MB, Int16 as FLAC 23.6 MB. See spec/02-capture-and-transfer.md
/// for why the remaining 1.7x that AAC would buy is not worth having.
public enum AudioFile {
    public static let sampleRate = 16_000
    public static let channels = 1

    /// A streaming WAV writer whose header is rewritten as it goes.
    ///
    /// The header carries two lengths that are only known when the file is
    /// closed, so the obvious implementation writes it at the end and loses
    /// the whole session to a crash. Listen rewrites the header every couple
    /// of seconds instead, which costs eight bytes of seek and turns a crash
    /// from "the meeting is gone" into "the last two seconds are gone". Same
    /// trick here, and it is also the reason this app records WAV rather than
    /// anything in an MP4 container: an m4a needs its `moov` atom finalised
    /// and a process killed mid-write leaves nothing playable at all.
    public final class Writer {
        private let handle: FileHandle
        private var frames: Int = 0
        private var sinceFlush: Int = 0
        public let url: URL

        public init(url: URL) throws {
            self.url = url
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: AudioFile.header(frames: 0))
        }

        public func append(_ samples: [Int16]) throws {
            var data = Data(capacity: samples.count * 2)
            for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
            try handle.write(contentsOf: data)
            frames += samples.count
            sinceFlush += samples.count
            // Every two seconds of audio, matching the Mac.
            if sinceFlush >= AudioFile.sampleRate * 2 { try rewriteHeader(); sinceFlush = 0 }
        }

        private func rewriteHeader() throws {
            let end = try handle.offset()
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: AudioFile.header(frames: frames))
            try handle.seek(toOffset: end)
            try handle.synchronize()
        }

        @discardableResult
        public func close() throws -> Double {
            try rewriteHeader()
            try handle.close()
            return Double(frames) / Double(AudioFile.sampleRate)
        }

        public var duration: Double { Double(frames) / Double(AudioFile.sampleRate) }
    }

    static func header(frames: Int) -> Data {
        let bytes = frames * 2 * channels
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + bytes)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2))
        u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(bytes))
        return d
    }

    /// What a WAV actually contains, for asserting that a capture is usable
    /// before it is uploaded. A file of the right size that is silent, or at
    /// the wrong rate, is the failure this catches.
    public struct Info: Sendable, Equatable {
        public let sampleRate: Int
        public let channels: Int
        public let bitsPerSample: Int
        public let frames: Int
        public var duration: Double { Double(frames) / Double(max(sampleRate, 1)) }
        public var isListenFormat: Bool {
            sampleRate == AudioFile.sampleRate && channels == 1 && bitsPerSample == 16
        }
    }

    public static func inspect(_ url: URL) -> Info? {
        guard let d = try? Data(contentsOf: url), d.count >= 44 else { return nil }
        func u32(_ o: Int) -> Int { Int(d[o...].prefix(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }) }
        func u16(_ o: Int) -> Int { Int(UInt16(d[o]) | UInt16(d[o + 1]) << 8) }
        guard d[0...3].elementsEqual(Array("RIFF".utf8)) else { return nil }
        let channels = u16(22), rate = u32(24), bits = u16(34)
        // Walk the chunks rather than assuming `data` sits at offset 36:
        // afconvert writes a `LIST` chunk before it and a fixed offset reads
        // the metadata as samples, which measures as a file full of noise.
        var offset = 12
        while offset + 8 <= d.count {
            let id = String(decoding: d[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            if id == "data" {
                let bytes = min(size, d.count - offset - 8)
                return Info(sampleRate: rate, channels: channels, bitsPerSample: bits,
                            frames: bytes / max(1, channels * bits / 8))
            }
            offset += 8 + size + (size % 2)
        }
        return nil
    }

    /// Peak amplitude, 0 to 1. A capture whose peak is zero recorded silence,
    /// which is the failure a duration check cannot see and the one that
    /// actually happens: a muted microphone, a case over it, or a headset that
    /// walked out of range mid-session.
    public static func peak(_ url: URL) -> Double {
        guard let info = inspect(url), let d = try? Data(contentsOf: url),
              info.bitsPerSample == 16 else { return 0 }
        var peak: Int16 = 0
        var i = 44
        while i + 1 < d.count {
            let v = Int16(bitPattern: UInt16(d[i]) | UInt16(d[i + 1]) << 8)
            if v != Int16.min, abs(v) > peak { peak = abs(v) }
            i += 2 * 64          // every 64th sample; a peak does not hide from that
        }
        return Double(peak) / 32768.0
    }
}
