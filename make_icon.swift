#!/usr/bin/env swift
//
// Generates the README preview and Listen.icns from icon-master.png.
//
// The approved artwork includes a dark canvas around the icon shape. Keeping
// that source intact lets this script apply the standard macOS transparent
// corners and optical padding for every consumer.
//
// Run: swift make_icon.swift

import AppKit

let contentInset = 0.094
let cornerRatio = 0.224

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let masterURL = assets.appendingPathComponent("icon-master.png")

guard let master = NSImage(contentsOf: masterURL) else {
    FileHandle.standardError.write(
        "could not read Assets/icon-master.png\n".data(using: .utf8)!)
    exit(1)
}

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    let s = Double(size)
    let inset = (s * contentInset).rounded()
    let side = s - inset * 2
    let square = NSRect(x: inset, y: inset, width: side, height: side)
    let body = NSBezierPath(roundedRect: square,
                            xRadius: side * cornerRatio,
                            yRadius: side * cornerRatio)
    body.addClip()
    master.draw(in: square, from: .zero, operation: .copy, fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high])

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let iconset = assets.appendingPathComponent("Listen.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for (points, scale) in variants {
    let pixels = points * scale
    let rep = drawIcon(size: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try png.write(to: iconset.appendingPathComponent(name))
}

let preview = drawIcon(size: 512)
guard let previewPNG = preview.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode README preview\n".data(using: .utf8)!)
    exit(1)
}
try previewPNG.write(to: assets.appendingPathComponent("icon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path,
                  "-o", assets.appendingPathComponent("Listen.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

guard task.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

print("wrote Assets/icon.png and Assets/Listen.icns")
