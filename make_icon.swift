#!/usr/bin/env swift
//
// Draws Assets/Listen.icns.
//
// The artwork is drawn rather than loaded from a master PNG, so there is no
// binary asset to keep in the repository and no scale factor to get wrong.
//
// Run: swift make_icon.swift

import AppKit

// macOS icon geometry: the rounded square sits inside the canvas with about
// 10% breathing room, and its corner radius is ~22.4% of the square's side.
// Getting these wrong is what makes an icon look subtly the wrong size next to
// every other one in the Dock.
let CONTENT_INSET = 0.094
let CORNER_RATIO = 0.224

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

/// One icon at one pixel size.
///
/// Everything is expressed as a fraction of `size` so the same code draws the
/// 16-point and the 1024-point version without a separate set of numbers.
func drawIcon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * CONTENT_INSET
    let square = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = square.width * CORNER_RATIO
    let squircle = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)

    // A single deep gradient rather than anything busy. At 16 points most of an
    // icon is gone, so the shape has to survive on silhouette and contrast.
    let background = NSGradient(colors: [
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1),
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.20, alpha: 1),
    ])!
    squircle.addClip()
    background.draw(in: square, angle: -90)

    // A waveform: five bars, symmetric, tallest in the middle. It reads as
    // sound at any size, and unlike a microphone it does not suggest that this
    // app only records you.
    let mint = NSColor(calibratedRed: 0.61, green: 0.86, blue: 0.69, alpha: 1)
    mint.setFill()

    let heights: [CGFloat] = [0.26, 0.52, 0.78, 0.52, 0.26]
    let barWidth = square.width * 0.088
    let gap = square.width * 0.062
    let total = barWidth * CGFloat(heights.count) + gap * CGFloat(heights.count - 1)
    var x = square.midX - total / 2

    for height in heights {
        let h = square.height * height
        let bar = NSRect(x: x, y: square.midY - h / 2, width: barWidth, height: h)
        // Rounded caps, because square ends look broken at small sizes where
        // antialiasing is doing most of the work.
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = assets.appendingPathComponent("Listen.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The (point size, scale) pairs iconutil expects. Missing one makes the icon
// blurry at exactly the size that was left out, which is easy to miss because
// it is usually the one you are not looking at.
let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

for (points, scale) in variants {
    let pixels = points * scale
    let rep = drawIcon(size: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try png.write(to: iconset.appendingPathComponent(name))
}

// A plain PNG too, for the README and the landing page.
if let png = drawIcon(size: 512).representation(using: .png, properties: [:]) {
    try png.write(to: assets.appendingPathComponent("icon.png"))
}

// iconutil does the .icns packing; there is no public API for it.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path,
                  "-o", assets.appendingPathComponent("Listen.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

print(task.terminationStatus == 0
      ? "wrote Assets/Listen.icns and Assets/icon.png"
      : "iconutil failed with status \(task.terminationStatus)")
