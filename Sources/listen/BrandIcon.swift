import AppKit

/// The full Good Pair character is for first-run and quiet, empty moments.
/// Busy controls use the monochrome seal instead, so product state remains the
/// thing a person sees first.
@MainActor
enum BrandIcon {
    static func view(size: CGFloat, accessibilityLabel: String) -> NSImageView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel(accessibilityLabel)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: size).isActive = true
        icon.heightAnchor.constraint(equalToConstant: size).isActive = true
        return icon
    }
}
