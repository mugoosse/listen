import Foundation
import ListenKit

/// Which model a set of languages means.
///
/// The half of `Languages` that knows models exist, which is why it is here and
/// not in ListenKit: the phone has no models to choose between, and the kit
/// deliberately depends on nothing.
///
/// The three engines disagree in ways that matter, and all three numbers are
/// measured over this library rather than taken from a leaderboard:
///
/// - **v2** reads English and nothing else, and is the most accurate on this
///   library's names: 94 domain proper nouns over 12.9 hours.
/// - **v3** reads 25 languages, is the only engine here that reads Dutch, and
///   loses 39% of those names.
/// - **Apple** reads 10 languages including Japanese, Korean and Chinese, which
///   no Parakeet here reads, and loses about a quarter of the names.
///
/// So no engine dominates and the right one depends on who is speaking.
extension Languages {
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
}
