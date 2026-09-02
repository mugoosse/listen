// What is in a track, for scripts that need a number rather than a file size.
//
// Reads the Float32 mono WAVs `WAVWriter` produces and prints one line per
// file, key=value so a shell can `awk` it:
//
//   mic.wav duration=9.24 rate=16000 rms=-54.0 peak=-31.2 nonzero=97.5 live=18/18
//
// `live` is how many half-second windows held anything above -80 dBFS, the
// floor `MicRecorder.signalFloor` uses. A file can be the right length and
// 100% nonzero and still hold nothing anybody said, which is why `peak` is
// the number the capture checks assert on: -80 dBFS is dither, -60 dBFS is a
// phrase reaching the microphone from across the desk.
//
//   swiftc -O -o .xcbuild/tools/wavstats tools/wavstats.swift
//   .xcbuild/tools/wavstats <file.wav> ...
import Foundation

for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path), data.count >= 44 else {
        print("\((path as NSString).lastPathComponent) unreadable=1")
        continue
    }
    let rate = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
    let n = (data.count - 44) / 4
    var sumSq = 0.0, peak: Float = 0, nonzero = 0
    var windows = 0, live = 0
    let window = max(1, Int(rate) / 2)
    var windowPeak: Float = 0
    data.withUnsafeBytes { raw in
        let p = raw.baseAddress!.advanced(by: 44).assumingMemoryBound(to: Float.self)
        for i in 0..<n {
            let x = p[i], a = abs(x)
            sumSq += Double(x * x)
            if a > peak { peak = a }
            if x != 0 { nonzero += 1 }
            if a > windowPeak { windowPeak = a }
            if (i + 1) % window == 0 {
                windows += 1
                if windowPeak > 0.0001 { live += 1 }
                windowPeak = 0
            }
        }
    }
    let rms = n > 0 ? (sumSq / Double(n)).squareRoot() : 0
    // -180 stands for "no signal at all", so a silent file still parses.
    let db: (Double) -> String = { $0 > 0 ? String(format: "%.1f", 20 * log10($0)) : "-180.0" }
    print(String(format: "%@ duration=%.2f rate=%d rms=%@ peak=%@ nonzero=%.1f live=%d/%d",
                 (path as NSString).lastPathComponent, Double(n) / Double(rate), rate,
                 db(rms), db(Double(peak)), n > 0 ? 100 * Double(nonzero) / Double(n) : 0,
                 live, windows))
}
