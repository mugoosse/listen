import Foundation

/// The release notes, read out of the copy that ships inside the bundle.
///
/// `CHANGELOG.md` is the only place notes are written, and until this existed
/// nothing inside Listen could read it. `release.sh` takes the top section for
/// the GitHub release body and embeds it in the appcast, and Sparkle draws that
/// one section in the pane in front of an update. Both are about the version
/// being offered, both are dismissed and gone, and `SUAutomaticallyUpdate` is
/// on by default, so the ordinary path is a new version arriving on the next
/// quit with its notes never having been on screen at all. "What changed in the
/// copy I am running" had no answer that did not involve a browser.
///
/// **What ships is what shipped.** The bundled file stops at the version that
/// built it, so this can never show notes for a version nobody has installed.
/// Fetching the newest changelog instead would be an outbound connection nobody
/// asked for and another entry in `InternetAccessPolicy.plist`, on an app whose
/// whole claim is that it talks to two hosts. The window says so in one line
/// and links out for the rest.
enum Changelog {
    struct Release: Equatable {
        /// `0.18.2`, exactly as the heading writes it.
        let version: String

        /// `2026-08-25`, when the heading carries one. Kept as the string it
        /// was written as rather than parsed into a `Date`: it is shown and
        /// never compared, and a section being cut is allowed to say anything
        /// in there while it is being written.
        let date: String?

        /// The section's markdown, with the version heading taken off and the
        /// blank lines either end trimmed.
        let body: String
    }

    /// The bundled file, parsed once.
    ///
    /// Empty when there is no bundle to read, which is a `swift build` binary
    /// rather than a fault: `make_app.sh` is what puts the file in Resources.
    /// Callers show the empty case, they do not treat it as an error.
    ///
    /// `static let` rather than a function, because the file is 65 KB, it
    /// cannot change under a running app, and three separate controls open the
    /// window that reads it.
    static let releases: [Release] = {
        guard let url = bundledURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }()

    /// Where `make_app.sh` puts it. `Bundle.main` is right here for the reason
    /// `CLI.reexecAsRealBinary` exists: a process launched through the
    /// installed symlink has already replaced itself with the real binary
    /// inside the app before any of this is reachable.
    static var bundledURL: URL? {
        Bundle.main.url(forResource: "CHANGELOG", withExtension: "md")
    }

    /// The version this copy is, for marking the entry somebody is running.
    /// Through `AppInfo` rather than `Bundle.main`, the same way `listen
    /// --version` does it.
    static var running: String? { AppInfo.version }

    /// The release a version string names, if the bundled notes have it.
    static func release(_ version: String) -> Release? {
        releases.first { $0.version == version }
    }

    // -----------------------------------------------------------------------

    /// Split a changelog into its releases, newest first, in file order.
    ///
    /// The section rule is `release.sh`'s: a section starts at a `##` heading
    /// followed by a version number and runs to the next one. **Keyed on the
    /// version and not on the heading level**, because an entry is allowed its
    /// own sub-headings and a parser that stopped at those would end a release
    /// at its first sub-heading and hand the rest to nobody. The two splits
    /// have to agree: what this window shows and what `release.sh` publishes
    /// are the same file, and a disagreement would be invisible on both sides.
    ///
    /// Everything above the first version heading is the file's note to whoever
    /// writes it, and belongs to no release, so it is dropped here rather than
    /// shown to a user as though it were news.
    static func parse(_ markdown: String) -> [Release] {
        var releases: [Release] = []
        var open: (version: String, date: String?)?
        var body: [String] = []

        func close() {
            guard let open else { return }
            releases.append(Release(version: open.version, date: open.date,
                                    body: joined(body)))
        }

        for line in markdown.components(separatedBy: "\n") {
            if let heading = heading(line) {
                close()
                open = heading
                body = []
            } else if open != nil {
                body.append(line)
            }
        }
        close()
        return releases
    }

    /// `## 0.18.2 (2026-08-25)` to its two halves, or `nil` for any other line.
    private static func heading(_ line: String) -> (version: String, date: String?)? {
        guard line.hasPrefix("## ") else { return nil }
        let rest = line.dropFirst(3).drop { $0 == " " }
        let version = String(rest.prefix { !$0.isWhitespace && $0 != "(" })
        guard isVersion(version) else { return nil }

        var date: String?
        if let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"),
           open < close {
            let inside = rest[rest.index(after: open)..<close]
                .trimmingCharacters(in: .whitespaces)
            date = inside.isEmpty ? nil : inside
        }
        return (version, date)
    }

    /// Three dot-separated numbers to start with, which is what `release.sh`
    /// keys its own awk on (`^## [0-9]+\.[0-9]+\.[0-9]+`). A heading that
    /// script would not treat as a section must not be one here either.
    private static func isVersion(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return false }
        return parts.prefix(3).allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    /// The body, with the blank lines either end dropped. A section always
    /// opens with one, because the heading is followed by a blank line, and it
    /// would otherwise be drawn as a paragraph of air under every version.
    private static func joined(_ lines: [String]) -> String {
        var lines = lines
        while let first = lines.first,
              first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last,
              last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
