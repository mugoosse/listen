import Foundation

/// The languages Listen can read, and which engine reads which.
///
/// **This exists because the model question is really a language question.**
/// Setup has always asked "which languages are your meetings in" rather than
/// "which model", because that is the question somebody can answer, but the
/// answer used to be one of two radio buttons standing in for the two
/// Parakeets. With a third engine that reads a different set again, and with
/// Apple's needing to be *told* a language before it decodes rather than
/// guessing one, the answer has to be an actual list of languages.
///
/// In ListenKit because the phone needs the same answer and for a sharper
/// reason than the Mac: a phone that cannot read the language in front of it
/// must not transcribe at all, and must say so rather than writing English
/// words over Dutch speech. The half that maps languages to a `ModelChoice`
/// stays in the Mac app, which is the only place models exist.
public enum Languages {
    /// Parakeet v3's 25, as ISO 639-1 codes. Irish is absent, so this is not
    /// simply the EU's official languages.
    public static let parakeet: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
        "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru",
        "sk", "sl", "es", "sv", "uk",
    ]

    /// Apple's 10, measured from `SpeechTranscriber.supportedLocales` on macOS
    /// 26.6 rather than read off a page. `DictationTranscriber` has more, and
    /// is a different and lower-quality model: see `.agents/notes/asr.md`.
    ///
    /// The list is asked of the framework at runtime wherever a decision turns
    /// on it. This copy is for the questions that have to be answered before
    /// any of that is loaded, and on an OS that has none of it.
    public static let apple: Set<String> = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "yue", "zh",
    ]

    /// Every language anything here can read, sorted by name.
    public static var all: [String] {
        Array(parakeet.union(apple)).sorted { name($0) < name($1) }
    }

    /// The language's name in the reader's own language.
    ///
    /// From the system rather than a table, so it is right in every locale the
    /// app runs in. Cantonese is the one the system declines to name on some
    /// installs, and a code shown to a person is not an answer.
    public static func name(_ code: String) -> String {
        if let name = Locale.current.localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return code == "yue" ? "Cantonese" : code.uppercased()
    }

    /// "Dutch", "Dutch and German", "Dutch, German and Polish".
    public static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default:
            return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The languages this device is set up in, as a starting point for the
    /// question rather than as an answer to it.
    ///
    /// `Locale.preferredLanguages` is the list in Settings, which is the
    /// closest thing a device knows to "languages this person uses". English is
    /// added because a meeting in English is the case that needs no declaring
    /// and the one every reader here has.
    public static var likely: [String] {
        var seen: [String] = []
        for tag in Locale.preferredLanguages {
            guard let code = Locale(identifier: tag).language.languageCode?.identifier,
                  all.contains(code), !seen.contains(code) else { continue }
            seen.append(code)
        }
        if !seen.contains("en") { seen.append("en") }
        return seen
    }
}
