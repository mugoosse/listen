import AppKit

/// Something in the library an answer pointed at.
///
/// The agent writes `[rec:<id>]`, `[note:<slug>]` or `[person:<name>]` straight
/// after the claim it supports, and the reader sees a small number they can
/// click. `Agent.brief` states that language and this file is the only thing
/// that reads it: those two are the whole contract, and nothing else in the app
/// writes a marker.
///
/// **An id, not a title.** The obvious alternative was to look for recording
/// titles in the prose and turn the matches into links, which needs no
/// cooperation from the model and is wrong for one measured reason: half this
/// library is called "New recording". A title is not an identity, and a
/// reference that opens the wrong meeting is worse than no reference at all.
enum Reference: Hashable {
    case recording(String)
    case note(String)
    case person(String)

    /// The made-up URL the attributed string carries, which is the same family
    /// the note pane's source links already use so one delegate could read
    /// both. Nothing ever hands one of these to `NSWorkspace`.
    var link: String {
        switch self {
        case .recording(let id):  return RecordingLink.scheme + id
        case .note(let slug):     return NoteLink.scheme + slug
        case .person(let name):   return PersonLink.scheme + name
        }
    }

    init?(link: Any) {
        if let id = RecordingLink.id(link) { self = .recording(id) }
        else if let slug = NoteLink.id(link) { self = .note(slug) }
        else if let name = PersonLink.id(link) { self = .person(name) }
        else { return nil }
    }
}

/// The thing itself, looked up once.
enum ReferenceTarget {
    case recording(Recording)
    case note(Note)
    case person(Person)
}

/// Markers in, numbers out.
///
/// Not on the main actor as a whole, because `strip` is wanted by the MCP
/// server as well: an agent told to cite in its answers cites in the notes it
/// writes too, and a marker in a file on disk is this app's private punctuation
/// showing up in somebody's editor. The two calls that touch AppKit or read the
/// library say so individually.
enum AnswerReferences {
    /// `[rec:2026-08-08-150112-42A1]`, and the two siblings.
    ///
    /// Deliberately not a markdown link. `[title](listen-recording:id)` would
    /// parse for free, and it puts the model in charge of the words as well as
    /// the id: the answer would then say the title twice, once in its own
    /// sentence and once in the link, and there would be no way to render the
    /// citation as a number without throwing the model's wording away.
    private static let marker: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"\[(rec|note|person):([^\]\n]{1,160})\]"#)

    /// Private-use characters, so a number can be parked in the markdown and
    /// found again after it has been rendered.
    ///
    /// The alternative was to record character offsets before rendering, which
    /// cannot work: `MarkdownText` joins wrapped lines, drops list markers and
    /// re-lays out tables, so an offset taken in the source names a different
    /// character in the output. These two survive both parsers untouched
    /// because neither markdown nor Foundation's inline parser has any use for
    /// U+E000.
    private static let opener = "\u{E000}"
    private static let closer = "\u{E001}"

    /// Every marker gone.
    ///
    /// For the text while it is still streaming, where markdown is not rendered
    /// yet and a half-typed `[rec:2026-08…` is the syntax showing through, and
    /// for a note saved out of an answer, which is a markdown file somebody may
    /// open in another editor.
    static func strip(_ text: String) -> String {
        guard let marker, text.contains("[") else { return text }
        return marker.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// Markers replaced by numbered sentinels, in the order they appear.
    ///
    /// `seen` carries across the blocks of one answer, so a recording cited in
    /// the first paragraph and again in the last is 1 both times. A marker
    /// naming something the library does not have is dropped rather than
    /// numbered: a reference that opens nothing is a promise the popover cannot
    /// keep, and a model that invented an id should cost the reader nothing.
    @MainActor
    static func number(_ text: String, into seen: inout [Reference]) -> String {
        guard let marker, text.contains("[") else { return text }
        let whole = NSRange(text.startIndex..., in: text)
        let matches = marker.matches(in: text, range: whole)
        guard !matches.isEmpty else { return text }

        let library = ReferenceLookup()
        var out = ""
        var cut = text.startIndex
        for match in matches {
            guard let range = Range(match.range, in: text),
                  let kind = Range(match.range(at: 1), in: text),
                  let value = Range(match.range(at: 2), in: text) else { continue }
            out += text[cut..<range.lowerBound]
            cut = range.upperBound

            guard let reference = reference(kind: String(text[kind]),
                                            value: String(text[value])),
                  library.resolve(reference) != nil else { continue }
            let number = (seen.firstIndex(of: reference) ?? {
                seen.append(reference)
                return seen.count - 1
            }()) + 1
            out += opener + String(number) + closer
        }
        out += text[cut...]
        return out
    }

    /// Sentinels replaced by the numbers themselves, clickable.
    ///
    /// A superscript rather than the filled pill other apps use. A pill has to
    /// be a text attachment, and an attachment cell takes the click before the
    /// link attribute under it is ever consulted; a raised number is one string
    /// with one attribute on it, which is what makes the whole thing a `.link`
    /// the text view already knows how to route.
    @MainActor
    static func decorate(_ out: NSMutableAttributedString, with seen: [Reference]) {
        while let open = out.string.range(of: opener),
              let close = out.string.range(of: closer,
                                           range: open.upperBound..<out.string.endIndex) {
            let digits = String(out.string[open.upperBound..<close.lowerBound])
            let range = NSRange(open.lowerBound..<close.upperBound, in: out.string)
            guard let number = Int(digits), number >= 1, number <= seen.count else {
                // Cannot happen from `number(_:into:)`, and if it ever does the
                // sentinel has to come out anyway: two private-use characters
                // left in the text draw as a pair of empty boxes.
                out.replaceCharacters(in: range, with: "")
                continue
            }
            out.replaceCharacters(in: range,
                                  with: badge(number, for: seen[number - 1]))
        }
    }

    /// The number as it is drawn: raised, small, and the accent colour.
    ///
    /// The thin space is load-bearing. Two references on the same sentence are
    /// written next to each other, and "12" is one number rather than two.
    private static func badge(_ number: Int, for reference: Reference) -> NSAttributedString {
        NSAttributedString(string: "\u{2009}\(number)", attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .baselineOffset: 4.0,
            .foregroundColor: Brand.accent,
            .link: reference.link,
        ])
    }

    private static func reference(kind: String, value: String) -> Reference? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        switch kind {
        case "rec":    return .recording(trimmed)
        case "note":   return .note(trimmed)
        case "person": return .person(trimmed)
        default:       return nil
        }
    }
}

/// The library, read at most once per answer.
///
/// A person is looked up by scanning every recording's speakers, which is the
/// same pass the roster makes and far too much to repeat per marker. The notes
/// folder is the same story. Both are lazy, so an answer citing only recordings
/// pays for neither.
@MainActor
final class ReferenceLookup {
    private var recordings: [Recording]?
    private var notes: [Note]?

    func resolve(_ reference: Reference) -> ReferenceTarget? {
        switch reference {
        case .recording(let id):
            // Not through `all()`: one recording is one file, and the id is
            // already the folder name.
            return Recording.find(id).map(ReferenceTarget.recording)
        case .note(let slug):
            if notes == nil { notes = Notes.all() }
            return (notes ?? []).first { $0.slug == slug }.map(ReferenceTarget.note)
        case .person(let name):
            if recordings == nil { recordings = Recording.all() }
            // By display name, because that is what the agent was given: the
            // roster hands out "Emily" for a track stored as `Me`.
            return People.findByDisplayName(name, in: recordings ?? [])
                .map(ReferenceTarget.person)
        }
    }
}
