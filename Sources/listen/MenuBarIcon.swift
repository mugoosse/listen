import AppKit

/// Listen's menu-bar mark is the Good Pair's listening seal. Its square stamp
/// carries 聞 (hear): a quiet nod to the Japanese origin of the three-wise-
/// monkeys reference, rather than a shrunken illustration of the mascot.
@MainActor
enum MenuBarIcon: Hashable {
    case ready
    case recording

    var image: NSImage { rendered(side: Self.side) }

    private static let side: CGFloat = 16

    private struct CacheKey: Hashable {
        let icon: MenuBarIcon
        let side: CGFloat
    }

    private static var cache: [CacheKey: NSImage] = [:]

    private func rendered(side: CGFloat) -> NSImage {
        let key = CacheKey(icon: self, side: side)
        if let hit = Self.cache[key] { return hit }

        let image = NSImage(size: NSSize(width: side, height: side))
        for scale in [1, 2] {
            image.addRepresentation(rep(side, scale: scale))
        }
        image.isTemplate = true
        Self.cache[key] = image
        return image
    }

    private func rep(_ side: CGFloat, scale: Int) -> NSBitmapImageRep {
        let pixels = Int(side) * scale
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)
        NSColor.black.setFill()
        NSColor.black.setStroke()

        switch self {
        case .ready:
            seal(CGFloat(pixels))
        case .recording:
            plate(CGFloat(pixels)).fill()
            seal(CGFloat(pixels), inverted: true)
        }

        NSGraphicsContext.restoreGraphicsState()
        rep.size = NSSize(width: side, height: side)
        return rep
    }

    /// Both apps use this same 14/16-square envelope. The only identity inside
    /// the stamp is the character; a template image lets macOS choose its own
    /// menu-bar colour in every appearance.
    private func seal(_ side: CGFloat, inverted: Bool = false) {
        let stamp = NSBezierPath(roundedRect: NSRect(x: side * 0.0625, y: side * 0.0625,
                                                      width: side * 0.875, height: side * 0.875),
                                 xRadius: side * 0.203, yRadius: side * 0.203)
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        if inverted {
            context.setBlendMode(.clear)
            stamp.fill()
            context.setBlendMode(.normal)
            drawCharacter("聞", side: side)
        } else {
            stamp.fill()
            context.setBlendMode(.clear)
            drawCharacter("聞", side: side)
            context.setBlendMode(.normal)
        }
    }

    private func drawCharacter(_ character: String, side: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let font = NSFont(name: "HiraginoSans-W8", size: side * 0.60)
            ?? NSFont.systemFont(ofSize: side * 0.60, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph,
        ]
        let glyph = NSAttributedString(string: character, attributes: attributes)
        glyph.draw(in: NSRect(x: side * 0.14, y: side * 0.145,
                              width: side * 0.72, height: side * 0.72))
    }

    private func plate(_ side: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: side * 0.07, y: side * 0.07,
                                         width: side * 0.86, height: side * 0.86),
                     xRadius: side * 0.25, yRadius: side * 0.25)
    }
}
