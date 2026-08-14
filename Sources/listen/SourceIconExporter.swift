import AppKit
import ListenKit

/// Makes source application icons portable with their recordings.
///
/// `NSWorkspace` can resolve an application installed on this Mac. An iPhone
/// cannot, so the Mac writes one compact PNG into the recording folder and the
/// existing encrypted manifest carries it with the other display sidecars.
@MainActor
enum SourceIconExporter {
    private static let pixels = 64
    private static var encoded: [String: Data] = [:]

    static func prepare(_ recordings: [Recording]) {
        for recording in recordings {
            guard !FileManager.default.fileExists(atPath: recording.sourceIconURL.path),
                  let bundleID = recording.appBundleID,
                  let data = png(for: bundleID)
            else { continue }
            try? data.write(to: recording.sourceIconURL, options: .atomic)
        }
    }

    private static func png(for bundleID: String) -> Data? {
        if let cached = encoded[bundleID] { return cached }
        guard let source = AppNames.icon(bundleID),
              let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else {
            return nil
        }

        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                    from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let data = bitmap.representation(using: .png, properties: [:])
        encoded[bundleID] = data
        return data
    }
}
