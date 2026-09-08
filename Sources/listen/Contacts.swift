import Foundation
import ListenKit

/// One person, and every address they answer to.
///
/// The name is the label written in transcripts, which is the same join key
/// `People` uses. That is deliberate and it is the whole point: a contact is
/// not a fourth kind of identity, it is a second way of arriving at the one
/// Listen already has.
typealias Contact = PersonProfile

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
    static let file = PersonDirectory.file(root: Library.root)

    /// Read from disk on every call, as `CustomDictionary` does. A few
    /// kilobytes is nothing, and a cache here would need invalidating from the
    /// sheet, from a hand edit, and from the CLI in another process.
    static func load() -> [Contact] {
        PersonDirectory.load(root: Library.root)
    }

    static func save(_ contacts: [Contact]) {
        try? PersonDirectory.save(contacts, root: Library.root)
    }

    // MARK: - Reading

    static func normalize(_ email: String) -> String {
        PersonDirectory.normalize(email)
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

    /// Everything the book holds about one person, if anything.
    static func contact(_ name: String) -> Contact? {
        load().first { $0.name == name }
    }

    /// People the book knows, for a picker to offer.
    ///
    /// Searched by address as well as by name, which is most of the reason to
    /// store addresses: the name you remember at labelling time is often the
    /// one you have been mailing all week.
    static func matching(_ query: String) -> [Contact] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return load() }
        return load().filter {
            $0.name.lowercased().contains(q) || $0.emails.contains { $0.contains(q) }
        }
    }

    // MARK: - Writing

    /// Replace everything the book holds about one person.
    ///
    /// The one writer for the card, so a contact with notes and no address is
    /// possible: `link` drops a person with neither, and until notes existed
    /// there was nothing else to have.
    static func set(_ contact: Contact) {
        let name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !VoiceBank.isPlaceholder(name) else { return }
        var contacts = load()
        var updated = contact
        updated.name = name
        updated.emails = Array(Set(contact.emails.map(normalize).filter { !$0.isEmpty }))
            .sorted()
        updated.notes = contact.note.isEmpty ? nil : contact.note
        if updated.created == nil,
           let existing = contacts.first(where: { $0.name == name }) {
            updated.created = existing.created
        }
        // An address belongs to one person, the rule `link` already holds, so
        // taking one here takes it off whoever had it.
        for i in contacts.indices where contacts[i].name != name {
            contacts[i].emails.removeAll { updated.emails.contains($0) }
        }
        if let i = contacts.firstIndex(where: { $0.name == name }) {
            contacts[i] = updated
        } else {
            contacts.append(updated)
        }
        contacts.removeAll { $0.emails.isEmpty && $0.note.isEmpty && $0.created == nil }
        save(contacts)
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
        contacts.removeAll { $0.emails.isEmpty && $0.note.isEmpty && $0.created == nil }
        save(contacts)
        log("contacts: \(address) is \(person)")
    }

    @discardableResult
    static func unlink(_ email: String) -> Bool {
        let address = normalize(email)
        var contacts = load()
        let before = contacts.reduce(0) { $0 + $1.emails.count }
        for i in contacts.indices { contacts[i].emails.removeAll { $0 == address } }
        contacts.removeAll { $0.emails.isEmpty && $0.note.isEmpty && $0.created == nil }
        guard contacts.reduce(0, { $0 + $1.emails.count }) != before else { return false }
        save(contacts)
        return true
    }

    /// Delete the profile itself, including the marker that keeps a manually
    /// added name alive when it has no email or contact note.
    static func remove(_ name: String) {
        try? PersonDirectory.remove(name: name, root: Library.root)
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
        var moving = contacts.remove(at: i)
        moving.name = to
        if let j = contacts.firstIndex(where: { $0.name == to }) {
            // The two were the same person all along, which is what renaming
            // one into an existing name means everywhere else in this app.
            contacts[j].emails = Array(Set(contacts[j].emails + moving.emails)).sorted()
            contacts[j].created = contacts[j].created ?? moving.created
        } else {
            contacts.append(moving)
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
