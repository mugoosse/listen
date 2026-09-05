import Foundation
import Speech

/// The parts of Apple's speech stack both engines need, and must agree about.
///
/// Dictation (`AppleEngine`) and meetings (`AppleMeetingEngine`) pick a locale
/// and install its assets by the same rules. They were dictation's alone until
/// meetings arrived; two copies of the ordering below is exactly how the two
/// come apart, and the ordering is not obvious enough to survive being written
/// twice. See `.agents/notes/dictation.md` for where it was first paid for.
@available(macOS 26.0, *)
enum AppleSpeech {
    /// The supported locale with exactly this BCP-47 tag, or nil.
    ///
    /// Nil is load-bearing and must not be quietly turned into English by a
    /// caller. `SpeechTranscriber` reads 30 locales over 10 languages
    /// (measured on macOS 26.6, listed in `.agents/notes/asr.md`), and a
    /// language that is missing is missing: handing Dutch audio to an English
    /// decoder is the worst failure in this app, and it does not error, it
    /// writes fluent confident English. Each caller decides what to do instead,
    /// and neither of them may decide "carry on".
    static func supported(_ tag: String) async -> Locale? {
        await SpeechTranscriber.supportedLocales.first { $0.identifier(.bcp47) == tag }
    }

    /// Picks a locale for the language this Mac is set to.
    ///
    /// **Order matters more than it looks, and the obvious orders are all
    /// wrong.** Measured on this Mac, whose `Locale.current` is `en-PT`:
    ///
    /// - Taking the first entry whose language matches yields **en-ZA**, because
    ///   `supportedLocales` is not ordered by usefulness.
    /// - Preferring an installed variant yields en-ZA as well: all nine English
    ///   variants report as installed, so "installed" separates nothing.
    /// - `SpeechTranscriber.supportedLocale(equivalentTo: .current)`, Apple's
    ///   own answer to this question, **also** yields en-ZA. It is not a better
    ///   version of this function.
    ///
    /// So the region has to come from the language rather than from the list or
    /// from the user, and `Locale.Language.maximalIdentifier` is where that
    /// lives: `en` maximalises to `en-Latn-US`, `pt` to `pt-Latn-BR`, `nl` to
    /// `nl-Latn-NL`. That step is what turns en-PT into en-US instead of en-ZA.
    static func best() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        let mine = Locale.current
        let myLang = mine.language.languageCode?.identifier
        let myRegion = mine.region?.identifier

        func tag(_ l: Locale) -> String { l.identifier(.bcp47) }

        // 1. Exactly what the user runs.
        if let exact = supported.first(where: { tag($0) == tag(mine) }) { return exact }

        // 2. Same language and region, e.g. nl-BE.
        if let lang = myLang, let region = myRegion,
           let m = supported.first(where: {
               $0.language.languageCode?.identifier == lang
                   && $0.region?.identifier == region
           }) { return m }

        // 3. Same language, in that language's own default region: the en-ZA
        //    fix. A speaker of English in Portugal means en-US far more than
        //    they mean whichever variant happens to sort first.
        if let lang = myLang {
            let sameLanguage = supported.filter {
                $0.language.languageCode?.identifier == lang
            }
            let home = Locale(identifier: Locale.Language(identifier: lang)
                .maximalIdentifier).region?.identifier
            if let home,
               let m = sameLanguage.first(where: { $0.region?.identifier == home }) {
                return m
            }
            // 4. Same language, favouring an installed variant over a download.
            if let ready = sameLanguage.first(where: { s in
                installed.contains { tag($0) == tag(s) }
            }) { return ready }
            if let any = sameLanguage.first { return any }
        }

        // 5. English, preferring the common variants over whatever sorts first.
        for preferred in ["en-US", "en-GB"] {
            if let m = supported.first(where: { tag($0) == preferred }) { return m }
        }
        return supported.first { $0.language.languageCode?.identifier == "en" }
            ?? Locale(identifier: "en-US")
    }

    /// Install whatever this module's locale needs, if anything.
    ///
    /// Assets are system managed and usually already present, because Notes,
    /// Voice Memos and system dictation use the same ones. A locale that has
    /// never been used still has to be fetched, and that is normally instant or
    /// a few seconds rather than Parakeet's 2.5 GB.
    static func install(for module: SpeechTranscriber,
                        progress: (@Sendable (String) -> Void)? = nil) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [module]) else { return }
        progress?("preparing Apple speech assets")
        try await request.downloadAndInstall()
    }
}
