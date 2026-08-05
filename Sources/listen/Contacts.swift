import Foundation

/// One person, and every address they answer to.
///
/// The name is the label written in transcripts, which is the same join key
/// `People` uses. That is deliberate and it is the whole point: a contact is
/// not a fourth kind of identity, it is a second way of arriving at the one
/// Listen already has.
struct Contact: Codable {
    /// As written on disk in `turns.json`, so `People.find` locates them.
    var name: String
    /// Lowercased, unique. **Many per person, on purpose.** The same human is
    /// `ryan@example.org` on one invitation and `ryan.mitchell@example.com` on the
    /// next, and a book that could only hold one of them would ask the same
    /// question again every time the other one turned up.
    var emails: [String]
}

/// Which address belongs to whom.
///
/// Listen's own, and not the macOS Contacts framework. Anarlog resolves
/// participants through `CNContactStore` and a `contactPredicate`; that costs a
/// second permission prompt for an unmeasured gain, and it can only find people
/// who are already in the address book, which the far side of a work meeting
/// usually is not.
///
/// What this holds instead is what the user has already told Listen by naming
/// somebody. Measured over 72 events on the development machine, EventKit
/// returned a human name for 22 of 140 attendee entries and the email address
/// in the name field for the other 118, so without a book like this almost
/// every suggestion would be an address.
///
/// **Written only when a human asserts something.** Picking a suggested name in
/// the speaker sheet is an assertion that this address is this person; typing a
/// name freehand is not, and links nothing. That is the same standard `People`
/// already holds: two recordings hold the same person when somebody said so,
/// not when a score agreed.
enum ContactBook {
    /// Beside `dictionary.json`, and for the same reasons: it is a preference
    /// about the whole library rather than about any one recording, and it is
    /// small enough to rewrite whole.
    static let file = Library.root.appendingPathComponent("contacts.json")

    private struct Document: Codable {
        var version: Int
        var contacts: [Contact]
    }

    /// Read from disk on every call, as `CustomDictionary` does. A few
    /// kilobytes is nothing, and a cache here would need invalidating from the
    /// sheet, from a hand edit, and from the CLI in another process.
    static func load() -> [Contact] {
        guard let data = try? Data(contentsOf: file),
              let doc = try? JSONDecoder().decode(Document.self, from: data)
        else { return [] }
        return doc.contacts
    }

    static func save(_ contacts: [Contact]) {
        try? FileManager.default.createDirectory(
            at: Library.root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(Document(
            version: 1,
            contacts: contacts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name)
                == .orderedAscending })) else { return }
        // Atomic: a crash mid-write must not leave neither the old list nor the
        // new one.
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Reading

    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Who this address belongs to, if anybody has said.
    static func name(for email: String) -> String? {
        let wanted = normalize(email)
        guard !wanted.isEmpty else { return nil }
        return load().first { $0.emails.contains(wanted) }?.name
    }

    static func emails(of name: String) -> [String] {
        load().first { $0.name == name }?.emails ?? []
    }

    // MARK: - Writing

    /// Say that an address belongs to a person.
    ///
    /// An address belongs to exactly one person, so linking it moves it off
    /// whoever held it before rather than leaving it in two places. The
    /// alternative is a book that can answer the same question two ways, which
    /// is worse than one that is occasionally out of date.
    static func link(_ email: String, to name: String) {
        let address = normalize(email)
        let person = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !person.isEmpty else { return }
        // A placeholder is not a person: `A` in one meeting has nothing to do
        // with `A` in another, so an address filed under one would be handed to
        // a stranger in the next recording.
        guard !VoiceBank.isPlaceholder(person) else { return }

        var contacts = load()
        for i in contacts.indices { contacts[i].emails.removeAll { $0 == address } }
        if let i = contacts.firstIndex(where: { $0.name == person }) {
            contacts[i].emails.append(address)
            contacts[i].emails.sort()
        } else {
            contacts.append(Contact(name: person, emails: [address]))
        }
        // A person left with no addresses is nothing but a name `People`
        // already knows, so it is dropped rather than kept as an empty row.
        contacts.removeAll { $0.emails.isEmpty }
        save(contacts)
        log("contacts: \(address) is \(person)")
    }

    @discardableResult
    static func unlink(_ email: String) -> Bool {
        let address = normalize(email)
        var contacts = load()
        let before = contacts.reduce(0) { $0 + $1.emails.count }
        for i in contacts.indices { contacts[i].emails.removeAll { $0 == address } }
        contacts.removeAll { $0.emails.isEmpty }
        guard contacts.reduce(0, { $0 + $1.emails.count }) != before else { return false }
        save(contacts)
        return true
    }

    /// Follow a person being renamed across the library.
    ///
    /// Called from `People.rename`, and it has to be: the book is keyed on the
    /// transcript label, so without this a renamed person's addresses point at
    /// a name nobody has any more. Nothing would report that. The suggestions
    /// would simply stop appearing, which reads as the calendar having stopped
    /// working rather than as a stale key.
    static func rename(_ old: String, to new: String) {
        let to = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !to.isEmpty, to != old else { return }
        var contacts = load()
        guard let i = contacts.firstIndex(where: { $0.name == old }) else { return }
        let moving = contacts.remove(at: i).emails
        if let j = contacts.firstIndex(where: { $0.name == to }) {
            // The two were the same person all along, which is what renaming
            // one into an existing name means everywhere else in this app.
            contacts[j].emails = Array(Set(contacts[j].emails + moving)).sorted()
        } else {
            contacts.append(Contact(name: to, emails: moving))
        }
        save(contacts)
    }

    // MARK: - Guessing a name from an address

    /// A name to offer for an address nobody has claimed.
    ///
    /// The last resort in the three-step precedence, and the weakest by a long
    /// way: `emily.carter@example.com` gives "Emily Carter" and
    /// `byjenna0x@example.com` gives "Byjenna0x". That is acceptable **only**
    /// because this is never applied on its own. It fills a button in a list
    /// somebody picks from, and picking it is what writes the link.
    ///
    /// Role addresses are refused rather than turned into a person. "Noreply"
    /// and "Info" are not people, and a book that learns them starts suggesting
    /// them for real speakers.
    static func suggestedName(from email: String) -> String? {
        let address = normalize(email)
        guard let at = address.firstIndex(of: "@") else { return nil }
        // Everything from a plus is a tag the sender chose, not part of who
        // they are: `emily+lists@` is still Emily.
        var local = String(address[address.startIndex..<at])
        if let plus = local.firstIndex(of: "+") { local = String(local[local.startIndex..<plus]) }
        guard !roleAddresses.contains(local) else { return nil }

        let words = local
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            // A run of digits is a disambiguator somebody's mail provider added,
            // never a name.
            .filter { !$0.allSatisfy(\.isNumber) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }

        let name = words.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    /// Addresses that are a function rather than a person.
    private static let roleAddresses: Set<String> = [
        "noreply", "no-reply", "donotreply", "do-not-reply", "info", "hello",
        "support", "admin", "team", "contact", "sales", "billing", "help",
        "notifications", "updates", "invites", "calendar", "meetings",
    ]
}
