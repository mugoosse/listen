import AppKit

/// Listen's persistent menu-bar mark is its listening monkey, reduced to a
/// monochrome template. The recording state stays in the menu text and the
/// window indicator: at 16 points, a second badge makes this small drawing
/// harder to recognise than it makes capture easier to understand.
@MainActor
enum MenuBarIcon: Hashable {
    case ready
    case recording

    var image: NSImage { Self.mascot(side: Self.side) }

    /// 24 points gives the 48/64-pixel visible mark a roughly 18-point
    /// footprint, matching the stature of the surrounding menu-bar apps.
    private static let side: CGFloat = 24
    private static var cache: [CGFloat: NSImage] = [:]

    private static func mascot(side: CGFloat) -> NSImage {
        if let image = cache[side] { return image }

        let image = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        image.size = NSSize(width: side, height: side)
        image.isTemplate = true
        cache[side] = image
        return image
    }
}
