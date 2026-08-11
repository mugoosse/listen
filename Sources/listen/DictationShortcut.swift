import AppKit
import Carbon.HIToolbox

// Ported from Speak's `Config.swift`, where these three types lived alongside
// the model and preference code. Split into their own file here because Listen
// keeps one concept per file and this one is about the keyboard.

/// One modifier key, identified by its device-dependent flag bit.
///
/// These IOKit-level bits are what distinguish left from right;
/// `NSEvent.modifierFlags` collapses both into a single `.shift`.
struct Modifier {
    let bit: UInt64
    let name: String

    static let all: [Modifier] = [
        .init(bit: 0x0080_0000, name: "fn"),        // maskSecondaryFn
        .init(bit: 0x0000_0002, name: "⇧ left"),
        .init(bit: 0x0000_0004, name: "⇧ right"),
        .init(bit: 0x0000_0001, name: "⌃ left"),
        .init(bit: 0x0000_2000, name: "⌃ right"),
        .init(bit: 0x0000_0020, name: "⌥ left"),
        .init(bit: 0x0000_0040, name: "⌥ right"),
        .init(bit: 0x0000_0008, name: "⌘ left"),
        .init(bit: 0x0000_0010, name: "⌘ right"),
    ]

    /// Every bit we track, so caps lock and friends are ignored.
    static let tracked: UInt64 = all.reduce(0) { $0 | $1.bit }

    static func describe(_ mask: UInt64) -> String {
        let parts = all.filter { mask & $0.bit != 0 }.map(\.name)
        return parts.isEmpty ? "none" : parts.joined(separator: " + ")
    }
}

/// Resolves a virtual key code to what that key actually prints.
///
/// Table-free, because a hardcoded map assumes US QWERTY: on AZERTY the key at
/// code 12 is "a", not "q". This asks the active keyboard layout instead.
enum KeyName {
    static func of(_ keyCode: Int) -> String {
        if let special = special[keyCode] { return special }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
                .takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(
                source, kTISPropertyUnicodeKeyLayoutData)
        else { return "key \(keyCode)" }

        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?
                    .assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, chars.count, &length, &chars)
        }

        guard status == noErr, length > 0 else { return "key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }

    /// Keys that print nothing, so the layout cannot name them.
    private static let special: [Int: String] = [
        49: "space", 36: "return", 48: "tab", 53: "esc", 51: "delete",
        117: "fwd delete", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "home", 119: "end", 116: "page up", 121: "page down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// The chord that toggles dictation.
///
/// Either a pure modifier chord (fn + ⇧) or modifiers plus one ordinary key
/// (fn + ⇧ + P). The two are matched differently: a modifier chord has no
/// keyDown to hook, so it is reconstructed from flag changes, while a chord
/// with a real key is matched on keyDown and swallowed so the character is not
/// also typed into whatever you are working in.
enum DictationShortcut {
    private static let maskKey = "dictationShortcutMask"
    private static let codeKey = "dictationShortcutKeyCode"

    /// Modifiers only; the key itself is extra.
    static let maxKeys = 3

    /// fn + left shift
    static let defaultMask: UInt64 = 0x0080_0000 | 0x0000_0002

    static var mask: UInt64 {
        get {
            let v = UInt64(Settings.defaults.integer(forKey: maskKey)) & Modifier.tracked
            return isUsable(v, keyCode) ? v : defaultMask
        }
        set { Settings.defaults.set(Int(newValue & Modifier.tracked), forKey: maskKey) }
    }

    /// nil means a pure modifier chord.
    static var keyCode: Int? {
        get {
            let v = Settings.defaults.integer(forKey: codeKey)
            return v > 0 ? v - 1 : nil          // 0 is "unset", so store code+1
        }
        set { Settings.defaults.set(newValue.map { $0 + 1 } ?? 0, forKey: codeKey) }
    }

    static func set(mask: UInt64, keyCode: Int?) {
        self.keyCode = keyCode
        self.mask = mask
    }

    static func isUsable(_ mask: UInt64, _ keyCode: Int?) -> Bool {
        // With a character key, one modifier is plenty and zero is not: a bare
        // letter would fire on every word containing it. Without one the same
        // range applies, since a chord of no modifiers at all is nothing.
        (1...maxKeys).contains(mask.nonzeroBitCount)
    }

    /// A lone modifier toggles every time you reach for it, including mid-word.
    /// Allowed, since some keyboards have a spare key worth dedicating, but
    /// worth saying out loud in the UI.
    static func isRisky(_ mask: UInt64, _ keyCode: Int?) -> Bool {
        keyCode == nil && mask.nonzeroBitCount == 1
    }

    static var description: String {
        let mods = Modifier.describe(mask)
        guard let c = keyCode else { return mods }
        return "\(mods) + \(KeyName.of(c))"
    }

    static var usesCharacterKey: Bool { keyCode != nil }

    /// Exact match, so fn+shift does not also fire on fn+shift+cmd.
    static func modifiersMatch(_ flags: CGEventFlags) -> Bool {
        (flags.rawValue & Modifier.tracked) == mask
    }
}
