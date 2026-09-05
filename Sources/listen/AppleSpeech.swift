import Foundation
import ListenKit
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

    /// Picks a locale, preferring the languages the user says they speak.
    ///
    /// **Order matters more than it looks, and the obvious orders are all
    /// wrong.** Measured on a Mac whose `Locale.current` is `en-PT`:
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
    /// `nl-Latn-NL`.
    ///
    /// `preferring` is `Settings.spokenLanguages`, and it comes first because
    /// somebody who said their meetings are in German means it whatever the Mac
    /// is set to. The Mac's own language is the fallback, English the last
    /// resort, and a language Apple cannot read is skipped rather than
    /// substituted: the caller checked, and this is not the place to decide
    /// that a Dutch meeting is English.
    static func best(preferring codes: [String] = []) async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        let mine = Locale.current
        let myLang = mine.language.languageCode?.identifier

        var order = codes
        if let myLang, !order.contains(myLang) { order.append(myLang) }
        if !order.contains("en") { order.append("en") }

        for code in order {
            // The user's own locale, but only for their own language: an
            // en-PT Mac says nothing about which Dutch to use.
            if code == myLang {
                if let exact = supported.first(where: {
                    $0.identifier(.bcp47) == mine.identifier(.bcp47)
                }) { return exact }
                if let region = mine.region?.identifier,
                   let m = supported.first(where: {
                       $0.language.languageCode?.identifier == code
                           && $0.region?.identifier == region
                   }) { return m }
            }
            if let m = variant(of: code, supported: supported, installed: installed) {
                return m
            }
        }
        return Locale(identifier: "en-US")
    }

    /// The variant of one language to use when the user's own region has none.
    ///
    /// The language's home region first, which is the en-ZA fix, then an
    /// installed variant, then whatever there is.
    private static func variant(of code: String, supported: [Locale],
                                installed: [Locale]) -> Locale? {
        let candidates = supported.filter {
            $0.language.languageCode?.identifier == code
        }
        guard !candidates.isEmpty else { return nil }

        let home = Locale(identifier: Locale.Language(identifier: code)
            .maximalIdentifier).region?.identifier
        if let home, let m = candidates.first(where: { $0.region?.identifier == home }) {
            return m
        }
        if let ready = candidates.first(where: { c in
            installed.contains { $0.identifier(.bcp47) == c.identifier(.bcp47) }
        }) { return ready }
        return candidates.first
    }

    /// Whether this locale's assets are already on this Mac.
    ///
    /// **`installedLocales` is the only thing that can answer this**, and the
    /// two obvious alternatives both lie. Measured on macOS 26.6 against a Mac
    /// holding en-US: `AssetInventory.status(forModules:)` returns `supported`
    /// rather than `installed`, and `assetInstallationRequest(supporting:)`
    /// hands back a non-nil request anyway. So a caller that reads "there is a
    /// request, therefore something must be downloaded" says "downloading" on
    /// every single run, which is what the first version of `install` did.
    static func isInstalled(_ locale: Locale) async -> Bool {
        let tag = locale.identifier(.bcp47)
        return await SpeechTranscriber.installedLocales.contains {
            $0.identifier(.bcp47) == tag
        }
    }

    /// The supported locale for one language, or nil when Apple cannot read it.
    ///
    /// The same variant rules `best` uses, so what a pane offers to install and
    /// what an engine then decodes in cannot come apart.
    static func locale(for code: String) async -> Locale? {
        variant(of: code,
                supported: await SpeechTranscriber.supportedLocales,
                installed: await SpeechTranscriber.installedLocales)
    }

    /// Which of these languages Apple reads, and whether each is on disk.
    static func inventory(for codes: [String]) async -> [(code: String, locale: Locale,
                                                          installed: Bool)] {
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        return codes.compactMap { code in
            guard let locale = variant(of: code, supported: supported,
                                       installed: installed) else { return nil }
            let tag = locale.identifier(.bcp47)
            return (code, locale, installed.contains { $0.identifier(.bcp47) == tag })
        }
    }

    /// Install whatever this module's locale needs, if anything.
    ///
    /// Assets are system managed and usually already present, because Notes,
    /// Voice Memos and system dictation use the same ones. A locale that has
    /// never been used still has to be fetched, and that is normally instant or
    /// a few seconds rather than Parakeet's 2.5 GB.
    ///
    /// `locale` is passed rather than read off the module because the message
    /// has to be truthful about which of the two this is, and the request alone
    /// cannot say: see `isInstalled`.
    static func install(for module: SpeechTranscriber, locale: Locale,
                        progress: (@Sendable (String) -> Void)? = nil) async throws {
        let present = await isInstalled(locale)
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [module]) else { return }
        if !present {
            progress?("downloading Apple speech for "
                      + (locale.language.languageCode.map { Languages.name($0.identifier) }
                         ?? locale.identifier(.bcp47)))
        }
        try await request.downloadAndInstall()
    }

    /// Fetch the assets for one language, for a pane with a button on it.
    @discardableResult
    static func install(language code: String,
                        progress: (@Sendable (String) -> Void)? = nil) async -> Bool {
        guard let locale = await locale(for: code) else { return false }
        do {
            try await install(for: SpeechTranscriber(
                locale: locale, transcriptionOptions: [], reportingOptions: [],
                attributeOptions: []), locale: locale, progress: progress)
            return await isInstalled(locale)
        } catch {
            log("could not install Apple speech for \(Languages.name(code)): \(error)")
            return false
        }
    }
}
