import AppKit

/// The colour a selected thing is filled with.
///
/// macOS hands every app `controlAccentColor`, which is whatever the user set
/// in System Settings and is blue by default. That is the right answer for a
/// utility and the wrong one for something with a face: every app on the
/// machine agrees, so a screenshot of this one is a screenshot of any of them.
///
/// The primary colour is the website download button (`#5C7CFF`). It carries
/// the icon's periwinkle highlight into the product without falling back to
/// the familiar macOS blue. The icon-derived alternatives remain available as
/// short-lived previews while the rest of the interface settles around it.
///
/// `LISTEN_ACCENT` remains a development-only override for comparing an
/// icon-derived alternative against the shipped website colour. It is not a
/// user preference and an unset value always means the Listen primary.
enum Brand {
    enum Accent: String, CaseIterable {
        /// The Listen website's download button, and the app's primary colour.
        case website
        /// Whatever the user set in System Settings, retained for comparison.
        case system
        /// The body of the icon, lifted to take white text.
        case indigo
        /// The highlight on the icon, which is the most blue of the three and
        /// still not the system's blue: it sits further round towards violet.
        case periwinkle
        /// The face. The only candidate nobody will mistake for another app.
        case coral
    }

    static let accentChoice: Accent = {
        let raw = ProcessInfo.processInfo.environment["LISTEN_ACCENT"] ?? ""
        return Accent(rawValue: raw.lowercased()) ?? .website
    }()

    /// The fill for a selected row, a chosen segment and a link.
    static var accent: NSColor {
        switch accentChoice {
        case .website:    return hex(0x5C7CFF)
        case .system:     return .controlAccentColor
        case .indigo:     return dynamic(light: 0x3B44C4, dark: 0x4A54D6)
        case .periwinkle: return dynamic(light: 0x4F6BE8, dark: 0x6E88F5)
        case .coral:      return dynamic(light: 0xD2604B, dark: 0xE0705A)
        }
    }

    /// The accent, or nil when the user has explicitly asked to compare the
    /// old system appearance.
    ///
    /// For the handful of AppKit properties that mean "leave it alone" when
    /// they are nil, `selectedSegmentBezelColor` among them. Setting them to
    /// `controlAccentColor` is not the same thing: it freezes the colour at the
    /// value it had when the control was built, so a segment stops following
    /// the user's own setting the moment they change it.
    static var tint: NSColor? { accentChoice == .system ? nil : accent }

    /// Text drawn *on* the accent. The website's CTA pairs its brighter blue
    /// with near-black text, which gives it a 5.35:1 contrast ratio instead of
    /// white's 3.63:1. The darker preview candidates still take white.
    static var onAccent: NSColor {
        switch accentChoice {
        case .website: return hex(0x0D0D0C)
        case .system:  return .alternateSelectedControlTextColor
        case .indigo, .periwinkle, .coral: return .white
        }
    }

    /// Slightly darker in a light appearance and lighter in a dark one, the way
    /// a system colour is. A single fixed value looks painted on in one of the
    /// two and there is no third option.
    private static func dynamic(light: Int, dark: Int) -> NSColor {
        let onLight = hex(light), onDark = hex(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? onDark : onLight
        }
    }

    static func hex(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
