import Foundation

/// A person the user has deliberately kept in their Listen library.
///
/// Recordings remain the source of truth for who spoke. This small profile is
/// the other legitimate way a person can exist: somebody may want to remember a
/// name, add a note, or prepare for a first conversation before Listen has ever
/// heard their voice.
public struct PersonProfile: Codable, Equatable, Sendable {
    public var name: String
    public var emails: [String]
    public var notes: String?

    /// Present only when the person was explicitly added by the user.
    ///
    /// Older contacts came from calendar addresses and predate this field. The
    /// optional timestamp is therefore both backwards-compatible activity and
    /// the durable distinction that lets a name-only person survive after every
    /// optional field is empty.
    public var created: String?

    public init(name: String, emails: [String], notes: String? = nil,
                created: String? = nil) {
        self.name = name
        self.emails = emails
        self.notes = notes
        self.created = created
    }

    public var note: String { notes ?? "" }
    public var firstName: String { Self.split(name).first }
    public var lastName: String { Self.split(name).last }

    public static func split(_ full: String) -> (first: String, last: String) {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let space = trimmed.firstIndex(of: " ") else { return (trimmed, "") }
        return (String(trimmed[trimmed.startIndex..<space]),
                String(trimmed[trimmed.index(after: space)...])
                    .trimmingCharacters(in: .whitespaces))
    }

    public static func join(first: String, last: String) -> String {
        [first, last]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public var initials: String {
        let parts = [firstName, lastName].compactMap(\.first).map(String.init)
        return parts.isEmpty ? "?" : parts.joined().uppercased()
    }

    public var createdAt: Date? { created.flatMap(PersonDirectory.date) }
}

/// The synced, user-authored people directory at the library root.
///
/// It intentionally keeps the existing `contacts.json` format. Renaming the
/// file or creating a parallel `people.json` would make calendar identity and
/// manually-created people two directories that could disagree about the same
/// human. The optional `created` field extends the old document without making
/// older builds or existing libraries unreadable.
public enum PersonDirectory {
    public static let filename = "contacts.json"

    private struct Document: Codable {
        var version: Int
        var contacts: [PersonProfile]
    }

    public enum Problem: LocalizedError, Equatable {
        case emptyName
        case placeholder(String)
        case reservedName
        case invalidEmail

        public var errorDescription: String? {
            switch self {
            case .emptyName:
                return "Enter a name."
            case .placeholder(let name):
                return "\"\(name)\" is used for an unnamed speaker. Enter the person's name instead."
            case .reservedName:
                return "Me is reserved for you. Enter this person's name instead."
            case .invalidEmail:
                return "Enter a valid email address, or leave email empty."
            }
        }
    }

    public static func file(root: URL) -> URL {
        root.appendingPathComponent(filename)
    }

    public static func load(root: URL) -> [PersonProfile] {
        guard let data = try? Data(contentsOf: file(root: root)),
              let document = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        return document.contacts
    }

    public static func save(_ profiles: [PersonProfile], root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let sorted = profiles.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        try encoder.encode(Document(version: 1, contacts: sorted))
            .write(to: file(root: root), options: .atomic)
    }

    /// Add a person without invoking an AI provider or manufacturing a source.
    /// Existing profiles are enriched in place, so adding somebody already heard
    /// in a recording opens that person rather than creating a duplicate.
    @discardableResult
    public static func add(name: String, email: String = "", root: URL,
                           now: Date = Date()) throws -> PersonProfile {
        let proposed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { throw Problem.emptyName }
        if proposed.count == 1, proposed.first?.isUppercase == true {
            throw Problem.placeholder(proposed)
        }
        guard proposed.caseInsensitiveCompare("Me") != .orderedSame else {
            throw Problem.reservedName
        }

        let address = normalize(email)
        if !address.isEmpty,
           (!address.contains("@") || address.contains(where: \.isWhitespace)) {
            throw Problem.invalidEmail
        }

        var profiles = load(root: root)
        let existing = profiles.firstIndex {
            $0.name.caseInsensitiveCompare(proposed) == .orderedSame
        }
        var profile = existing.map { profiles[$0] }
            ?? PersonProfile(name: proposed, emails: [])
        if !address.isEmpty, !profile.emails.contains(address) {
            profile.emails.append(address)
            profile.emails.sort()
        }
        profile.created = profile.created ?? timestamp(now)

        if !address.isEmpty {
            for index in profiles.indices where index != existing {
                profiles[index].emails.removeAll { normalize($0) == address }
            }
        }
        if let existing { profiles[existing] = profile } else { profiles.append(profile) }
        profiles.removeAll { $0.emails.isEmpty && $0.note.isEmpty && $0.created == nil }
        try save(profiles, root: root)
        return profile
    }

    public static func remove(name: String, root: URL) throws {
        var profiles = load(root: root)
        profiles.removeAll { $0.name == name }
        try save(profiles, root: root)
    }

    public static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
