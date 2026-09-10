import Foundation
import Darwin
import CryptoKit
import ListenKit

/// Text evidence has its own namespace. `embeddings.json` remains the voice bank.
enum ContextFiles {
    static var root: URL { Library.root.appendingPathComponent("context", isDirectory: true) }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func read<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    static func write<T: Encodable>(_ value: T, _ name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let url = root.appendingPathComponent(name)
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Source checks read file attributes, never transcripts. This is also the
    /// read gate: a deleted or edited source stops being evidence immediately.
    static func stamp(_ relative: String) -> String {
        if relative.hasPrefix("display:") { return SpeakerName.display(String(relative.dropFirst(8))) }
        if relative.hasPrefix("contact:") {
            let name = String(relative.dropFirst(8))
            guard let contact = ContactBook.contact(name) else { return "missing" }
            return hash(contact.name + "\n" + contact.note)
        }
        guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            return "missing"
        }
        let url = Library.root.appendingPathComponent(relative)
        var info = stat()
        guard url.path.withCString({ stat($0, &info) }) == 0 else { return "missing" }
        // Match Foundation's reference-date arithmetic, including its rounding,
        // so this cheaper check preserves existing receipt stamps exactly.
        let modified = Date(timeIntervalSinceReferenceDate: Double(info.st_mtimespec.tv_sec)
            - Date.timeIntervalBetween1970AndReferenceDate + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return "\(modified.timeIntervalSince1970):\(info.st_size):\(info.st_ino)"
    }

    static func relative(_ url: URL) -> String {
        // Foundation may enumerate /var as /private/var. Resolve both ends:
        // character-count slicing otherwise stamps library/library/... missing,
        // so an edit cannot invalidate its evidence.
        let root = Library.root.resolvingSymlinksInPath().standardizedFileURL
        let source = url.resolvingSymlinksInPath().standardizedFileURL
        return source.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
    }
}

/// An OS lock, so the window and an external `listen context update` cannot
/// process the same worklist. A crash releases it without stale lock cleanup.
final class ContextLock {
    private let descriptor: Int32
    init(_ name: String) throws {
        try FileManager.default.createDirectory(at: ContextFiles.root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        descriptor = open(ContextFiles.root.appendingPathComponent(name).path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ContextProblem.message("Cannot open the context lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ContextProblem.busy
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

enum ContextProblem: LocalizedError {
    case message(String), busy
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .busy: return "Context is already being updated by another Listen process."
        }
    }
}

struct ContextPassage: Codable {
    var ref: Int
    var text: String
    var speaker: String?
    var start: Double?
    var end: Double?
}

struct ContextSource: Codable {
    var id: String
    var title: String
    var date: String
    var kind: String
    var people: [String]
    var tags: [String]
    var dependencies: [String: String]
    var passages: [ContextPassage]
    var extractable: Bool
    var batchCount: Int? = nil
    var personBatchCounts: [String: Int]? = nil
    var contentRevision: String? = nil
    var sourceGroups: [String]? = nil
    var generated: Bool? = nil
    var subjectScope: String? = nil
    var aboutPerson: String? = nil

    var fingerprint: String {
        contentRevision ?? ContextFiles.hash(id + title + date + people.joined(separator: "\n")
            + tags.joined(separator: "\n") + dependencies.sorted { $0.key < $1.key }
                .map { $0.key + $0.value }.joined())
    }
    var isCurrent: Bool {
        MemoryPreferences.sourceAllowed(id, root: Library.root) && !dependencies.isEmpty && dependencies.allSatisfy { ContextFiles.stamp($0.key) == $0.value }
    }
    func scoped(to person: String?) -> ContextSource {
        guard let person else { return self }
        var source = self
        source.subjectScope = person
        source.people = [person]
        let names = ContextSources.reviewedNames(for: person).filter { $0 != SpeakerName.you }
        source.passages = passages.filter { passage in
            passage.speaker == person || aboutPerson == person || (kind == "contact" && people == [person])
                || names.contains { ContextSources.containsName(passage.text, $0) }
        }
        source.contentRevision = fingerprint
        return source
    }
    var catalogEntry: ContextSource {
        var source = self
        source.personBatchCounts = Dictionary(uniqueKeysWithValues: people.map { ($0, scoped(to: $0).batches.count) })
        source.batchCount = batches.count; source.passages = []
        return source
    }
    var marker: String { "[\(id)]" }
    var recordID: String? { kind == "recording" ? String(id.dropFirst(4)) : nil }
    var noteSlug: String? { kind == "note" ? String(id.dropFirst(5)) : nil }

    /// A bounded request covers all passages, including very long turns. No
    /// prefix truncation can mark the unseen end of a meeting as processed.
    var batches: [[ContextPassage]] {
        var batches: [[ContextPassage]] = [], current: [ContextPassage] = []
        var count = 0
        for passage in passages where kind != "recording" || passage.speaker.map({ !VoiceBank.isPlaceholder($0) }) == true {
            if count + passage.text.count > 8_000, !current.isEmpty {
                batches.append(current); current = []; count = 0
            }
            current.append(passage); count += passage.text.count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }
}

enum ContextSources {
    /// One compiled matcher per name, kept.
    ///
    /// `text.range(of:options:.regularExpression)` compiles a fresh
    /// `NSRegularExpression` on **every** call, and this is the expensive kind
    /// of pattern: `\p{L}` and `\p{N}` make ICU build two Unicode property
    /// sets and then case-close them. Measured on this library on 10 September
    /// 2026 by sampling the app while it sat at 115% CPU: of the 374 samples
    /// under `range(of:)`, 250 were inside `initWithPattern:` and only the rest
    /// were inside matching. `mentioned` asks once per roster name per
    /// recording and `ContextRetrieval.project` once per alias per fact, so a
    /// single pass over a 99-source library paid that compile tens of thousands
    /// of times.
    ///
    /// `NSCache` rather than a dictionary because this is called from detached
    /// tasks, the CLI and the MCP server at the same time, and an evicted entry
    /// costs only the compile it was saving.
    private static let matchers = NSCache<NSString, NSRegularExpression>()

    private static func matcher(for name: String) -> NSRegularExpression? {
        if let cached = matchers.object(forKey: name as NSString) { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        // The option set here used to carry `.diacriticInsensitive` and it did
        // nothing: Foundation drops it once `.regularExpression` is set, so
        // `Jose` has never matched `José` in this library and `José` has never
        // matched `Jose`. Measured before this was rewritten, precisely so that
        // the rewrite would not quietly start folding and change which people
        // every transcript is held to mention. Adding the fold is a real
        // decision with a backfill behind it, not a tidy-up.
        guard let regex = try? NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])",
            options: [.caseInsensitive]) else { return nil }
        matchers.setObject(regex, forKey: name as NSString)
        return regex
    }

    static func containsName(_ text: String, _ name: String) -> Bool {
        contains(text, name, in: wholeOf(text))
    }

    /// The UTF-16 extent `NSRegularExpression` wants, which is not free to work
    /// out for a long string. `mentioned` asks about one joined transcript once
    /// per roster name, so it computes this once and passes it in.
    static func wholeOf(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    static func contains(_ text: String, _ name: String, in range: NSRange) -> Bool {
        guard !name.isEmpty, let regex = matcher(for: name) else { return false }
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Full names, never guessed first names. Two people with the same display
    /// name are left unresolved. `Me` in ordinary prose is not a person mention.
    static func reviewedNames(for label: String) -> [String] {
        reviewedNames([label])[label] ?? [label, SpeakerName.display(label)]
    }
    static func reviewedNames(_ labels: [String]) -> [String: [String]] {
        let db = try? ContextStore.database()
        let entities = (try? db?.all(ContextEntity.self, in: .entities)) ?? [:]
        let aliases = (try? db?.all(String.self, in: .aliases)) ?? [:]
        return Dictionary(uniqueKeysWithValues: Set(labels).map { label in
            let id = aliases["person:" + ContextIdentity.normalized(label)] ?? ""
            return (label, Array(Set((entities[id]?.aliases ?? []) + [label, SpeakerName.display(label)])))
        })
    }

    static func mentioned(in text: String, roster: [Person], names: [String: [String]] = [:]) -> [String] {
        let grouped = Dictionary(grouping: roster, by: { $0.display.lowercased() })
        let whole = wholeOf(text)
        return roster.filter {
            grouped[$0.display.lowercased()]?.count == 1
                && (names[$0.label] ?? [$0.display]).contains { name in
                    name != SpeakerName.you && contains(text, name, in: whole)
                }
        }.map(\.label)
    }

    static func pieces(_ text: String, size: Int = 1_500) -> [String] {
        var result: [String] = [], rest = text[...]
        while !rest.isEmpty {
            var end = rest.index(rest.startIndex, offsetBy: min(size, rest.count))
            if end != rest.endIndex,
               let space = rest[..<end].lastIndex(where: { $0.isWhitespace }),
               rest.distance(from: rest.startIndex, to: space) > size / 2 { end = space }
            let piece = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            rest = rest[end...].drop(while: { $0.isWhitespace })
        }
        return result
    }

    /// Only called off the UI thread. Retrieval uses the stamps captured here.
    static func all() -> [ContextSource] {
        let library = Recording.all()
        let roster = People.roster(in: library)
        let names = reviewedNames(roster.map(\.label))
        let notes = Notes.all()
        var sources: [ContextSource] = []
        var participants: [String: [String]] = [:]
        for recording in library {
            let turns = recording.storedTurns
            let named = Array(Set(turns.map(\.speaker).filter { !VoiceBank.isPlaceholder($0) })).sorted()
            participants[recording.id] = named
            guard recording.hasTranscript,
                  recording.metadata.state != "transcribing",
                  recording.metadata.state != "pending" else { continue }
            var passages: [ContextPassage] = []
            for turn in turns {
                for text in pieces(turn.text) {
                    passages.append(ContextPassage(ref: passages.count + 1, text: text,
                                                    speaker: turn.speaker, start: turn.start, end: turn.end))
                }
            }
            guard !passages.isEmpty else { continue }
            let mentions = mentioned(in: passages.map(\.text).joined(separator: "\n"), roster: roster, names: names)
            let paths = [recording.metadataURL, recording.transcriptURL, recording.turnsURL]
                .map(ContextFiles.relative)
            var deps = Dictionary(uniqueKeysWithValues: paths.map { ($0, ContextFiles.stamp($0)) })
            for label in Set(named + mentions) {
                deps["contact:" + label] = ContextFiles.stamp("contact:" + label)
                deps["display:" + label] = ContextFiles.stamp("display:" + label)
            }
            sources.append(ContextSource(id: "rec:\(recording.id)", title: recording.metadata.title,
                date: recording.metadata.recorded_at, kind: "recording", people: Array(Set(named + mentions)).sorted(),
                tags: recording.metadata.tags ?? [], dependencies: deps, passages: passages,
                extractable: !named.isEmpty))
        }
        for note in notes where !note.excludedFromAI && !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let related = note.recordings.flatMap { participants[$0] ?? [] }
            let about = note.aboutPersonID.flatMap { id in roster.first { MemoryPreferences.personID($0.label, root: Library.root) == MemoryPreferences.canonicalID(id, root: Library.root) }?.label }
            let people = Array(Set((about.map { [$0] } ?? []) + related + mentioned(in: note.title + "\n" + note.body, roster: roster, names: names))).sorted()
            let path = "notes/\(note.slug).md"
            var deps = [path: ContextFiles.stamp(path)]
            for label in people {
                deps["contact:" + label] = ContextFiles.stamp("contact:" + label)
                deps["display:" + label] = ContextFiles.stamp("display:" + label)
            }
            for id in note.recordings {
                let turnPath = "recordings/\(id)/turns.json"
                deps[turnPath] = ContextFiles.stamp(turnPath)
            }
            sources.append(ContextSource(id: "note:\(note.slug)", title: note.title, date: note.created,
                kind: "note", people: people, tags: note.tags, dependencies: deps,
                passages: pieces(note.body).enumerated().map { ContextPassage(ref: $0.offset + 1, text: $0.element, speaker: note.source == "you" ? SpeakerName.you : nil) },
                extractable: !people.isEmpty, aboutPerson: about))
        }
        for contact in ContactBook.load() {
            let note = contact.note
            guard !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            sources.append(ContextSource(id: "person:\(contact.name)", title: "Notes about \(contact.name)", date: "",
                kind: "contact", people: [contact.name], tags: [],
                dependencies: ["contact:" + contact.name: ContextFiles.stamp("contact:" + contact.name)],
                passages: pieces(note).enumerated().map { ContextPassage(ref: $0.offset + 1, text: $0.element) }, extractable: true))
        }
        return sources.map { source in
            var source = source
            // Filing changes refresh display metadata without paying for the
            // same extraction again. Attribution and actual text are inputs.
            source.contentRevision = ContextFiles.hash(source.id + source.date + source.people.joined(separator: "\n")
                + source.passages.map { "\($0.ref):\($0.speaker ?? ""):\($0.start ?? -1):\($0.end ?? -1):\($0.text)" }.joined(separator: "\n"))
            source.sourceGroups = [source.id]
            if source.kind == "note", let note = notes.first(where: { "note:" + $0.slug == source.id }) {
                if !note.recordings.isEmpty { source.sourceGroups = note.recordings.map { "rec:" + $0 } }
                // A generated note can aid navigation, but is not an independent
                // observation. Extract from its original recordings instead.
                source.generated = note.chat?.isEmpty == false
                if source.generated == true { source.extractable = false }
            }
            return source
        }.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }
}
