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
/// Every set here is measured or from a model card, and they disagree in ways
/// that matter:
///
/// - **v2** reads English and nothing else, and is the most accurate on this
///   library's names: 94 domain proper nouns over 12.9 hours.
/// - **v3** reads 25 languages, the only engine here that reads Dutch, and
///   loses 39% of those names.
/// - **Apple** reads 10 languages including Japanese, Korean and Chinese, which
///   no Parakeet here reads, and loses about a quarter of the names.
///
/// So no engine dominates, the right one depends on who is speaking, and this
/// is the one place that rule is written.
enum Languages {
    /// Parakeet v3's 25, as ISO 639-1 codes in the order its model card lists
    /// them alphabetically by English name. Irish is absent, so this is not
    /// simply the EU's official languages.
    static let parakeet: Set<String> = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de",
        "el", "hu", "it", "lv", "lt", "mt", "pl", "pt", "ro", "ru",
        "sk", "sl", "es", "sv", "uk",
    ]

    /// Apple's 10, measured from `SpeechTranscriber.supportedLocales` on macOS
    /// 26.6 rather than read off a page. `DictationTranscriber` has more, and
    /// is a different and lower-quality model: see `.agents/notes/asr.md`.
    static let apple: Set<String> = [
        "de", "en", "es", "fr", "it", "ja", "ko", "pt", "yue", "zh",
    ]

    /// Every language anything here can read, sorted by name.
    static var all: [String] {
        Array(parakeet.union(apple)).sorted { name($0) < name($1) }
    }

    /// The language's name in the reader's own language.
    ///
    /// From the system rather than a table, so it is right in every locale the
    /// app runs in. Cantonese is the one the system declines to name on some
    /// installs, and a code shown to a person is not an answer.
    static func name(_ code: String) -> String {
        if let name = Locale.current.localizedString(forLanguageCode: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return code == "yue" ? "Cantonese" : code.uppercased()
    }

    /// Whether this model reads this language.
    static func reads(_ choice: ModelChoice, _ code: String) -> Bool {
        if choice.isApple { return apple.contains(code) }
        switch choice.id {
        case "v2": return code == "en"
        case "v3": return parakeet.contains(code)
        // A legacy import names a model this app has never had, and nothing
        // may claim to know what it could read.
        default: return false
        }
    }

    static func reads(_ choice: ModelChoice, all codes: [String]) -> Bool {
        codes.allSatisfy { reads(choice, $0) }
    }

    /// The languages this model cannot read, named, for a sentence that has to
    /// say which.
    static func missing(from choice: ModelChoice, _ codes: [String]) -> [String] {
        codes.filter { !reads(choice, $0) }.map(name)
    }

    /// The order to prefer engines in when more than one would do.
    ///
    /// v2 first because it is the most accurate on names and names are what
    /// this library is made of. v3 next because it reads the most languages.
    /// Apple last: it costs a quarter of the names against v2, and its case is
    /// the download it does not need rather than the words it gets right.
    static var preference: [ModelChoice] {
        // Apple's engine is only a candidate on a Mac that has it. Recommending
        // it to a Japanese speaker on macOS 15 would name the one engine here
        // that reads Japanese and then fail to run it, which is worse than
        // saying plainly that nothing reads it.
        ModelChoice.all + (ModelChoice.appleIsAvailable ? [.apple] : [])
    }

    /// The model to use for somebody who speaks these languages.
    ///
    /// Falls back to whichever reads the most rather than to a default, so a
    /// Japanese and Dutch speaker gets the engine that covers one of them and a
    /// caller can say what is left over. Nothing here downloads anything: this
    /// is a recommendation, and `Settings.model` is where it lands.
    static func model(for codes: [String]) -> ModelChoice {
        guard !codes.isEmpty else { return .fallback }
        if let fits = preference.first(where: { reads($0, all: codes) }) { return fits }
        return preference.max { a, b in
            codes.filter { reads(a, $0) }.count < codes.filter { reads(b, $0) }.count
        } ?? .fallback
    }

    /// What choosing these languages means, in one sentence, for the pane that
    /// has to justify a 2.5 GB download.
    static func consequence(of codes: [String]) -> String {
        let choice = model(for: codes)
        let unread = codes.filter { !reads(choice, $0) }
        guard !unread.isEmpty else { return "\(choice.title): \(choice.tradeoff)" }

        // Which of them nothing here reads, and which another engine would.
        // The difference is the whole of what a reader can do about it: one is
        // "pick a different model and lose something else", the other is "this
        // app cannot read your meetings and you should know before you spend
        // 2.5 GB finding out".
        let nowhere = unread.filter { code in !preference.contains { reads($0, code) } }
        var sentence = "\(choice.title): \(choice.tradeoff)"
        sentence += " It does not read \(list(unread.map(name)))."
        if !nowhere.isEmpty {
            sentence += " Nothing here reads \(list(nowhere.map(name)))"
                + ", so those meetings will come out as confident nonsense."
        } else {
            sentence += " No single model reads all of them, so those meetings"
                + " need the other one, per recording."
        }
        return sentence
    }

    /// "Dutch", "Dutch and German", "Dutch, German and Polish".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The languages this Mac is set up in, as a starting point for the
    /// question rather than as an answer to it.
    ///
    /// `Locale.preferredLanguages` is the list in System Settings, which is the
    /// closest thing the machine knows to "languages this person uses". English
    /// is added because a meeting in English is the case that needs no
    /// declaring and the one every reader here has.
    static var likely: [String] {
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
