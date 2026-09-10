import EventKit
import Foundation

// The calendar both apps read, and the one place the rules about it live.
//
// **It moved here when the iPhone gained the same feature.** The Mac's
// `MeetingCalendar` was the only reader for a long time, and the phone had no
// calendar at all: it knew `calendar_event_id` as a field that arrived from a
// Mac and nothing more. A second implementation of "which meetings are worth
// showing" would be two answers to one question, and this repository's whole
// habit is that a rule with a measurement behind it is written once. See
// `.agents/notes/calendar.md`.
//
// What stayed on the Mac is everything about a **recording**: matching one to a
// meeting, and writing the name and the guest list into `metadata.json`. The
// phone never does either. What is here is what both do: read the calendar,
// decide what is coming up, and say it in words.
//
// **There is no OAuth here, and there is deliberately no backend.** Anarlog
// supports Google and Outlook by brokering OAuth through Nango and proxying
// every read through its own API behind a Supabase login, which is why those
// two providers are a paid, signed-in feature over there. Apple has already
// done that work on both platforms: an account added in System Settings syncs
// into the system calendar store, and EventKit hands it over with no
// distinction from iCloud. Measured on the development Mac: 16 calendars
// across two Google accounts (as calDAV), iCloud, a subscription and
// Birthdays, with attendee emails and organizers on the events.
//
// So the whole feature costs one permission prompt and no network connection,
// which is also why `InternetAccessPolicy.plist` needs no new entry.
//
// Read-only, always. Nothing here creates, edits or deletes an event.
public enum MeetingCalendar {
    /// One store for the whole process.
    ///
    /// Not a convenience. Anarlog ships a standalone reproducer
    /// (`crates/apple-calendar/examples/repro_empty_calendars.rs`) that fires
    /// concurrent event and calendar reads and counts how often the calendar
    /// list comes back **zero**. Zero calendars raises no error and is
    /// indistinguishable from a Mac with none configured, so the failure is
    /// silent in the worst way: the feature simply stops working and the app
    /// reports nothing.
    ///
    /// `public` rather than private because the Mac's `Permissions.requestCalendar`
    /// must ask on *this* store, and so must the phone's. A grant landing on a
    /// different store leaves this one answering from the access it was created
    /// with, and every read afterwards returns nothing.
    ///
    /// `nonisolated(unsafe)` because the iPhone target compiles under Swift 6
    /// strict concurrency and `EKEventStore` is not `Sendable`, while the Mac
    /// package is still Swift 5 and says nothing. The annotation is a claim
    /// about this file rather than a way past the compiler, and `lock` is what
    /// makes the claim true: every read below goes through it, for the reason
    /// recorded above, which is that concurrent reads make this store answer
    /// with zero calendars and report nothing.
    nonisolated(unsafe) public static let store = EKEventStore()

    /// Every read is serialized through here.
    ///
    /// The comment above is the reason; this is the enforcement. Listen does
    /// not currently read the calendar concurrently, but "does not currently"
    /// is a property of today's callers rather than of this file, and the bug
    /// it prevents leaves no trace to debug from.
    private static let lock = NSLock()

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // -----------------------------------------------------------------------

    /// `LISTEN_FAKE_EVENTS` stands in for the calendar entirely, permission
    /// included: a fixture is only useful if it answers the same question the
    /// real store would, on a machine that has never been asked for access.
    ///
    /// Asked of EventKit directly rather than through either app's own
    /// permissions type, because those are two types with one answer between
    /// them. The Mac's `Permissions.calendar` is this line.
    public static var isAuthorized: Bool {
        fakeEvents != nil || EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Whether asking has already been answered, either way.
    ///
    /// A phone that has been refused needs to say so and send somebody to
    /// Settings; a phone that has never been asked needs a button. Those are
    /// different screens, and `isAuthorized` cannot tell them apart.
    public static var wasAsked: Bool {
        EKEventStore.authorizationStatus(for: .event) != .notDetermined
    }

    /// Ask for it, on this store for the reason `store` gives.
    @discardableResult
    public static func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Every calendar, as "Google / Work".
    ///
    /// The source is half the answer: two accounts routinely have a calendar
    /// with the same name, and on the development machine three do.
    public static func calendars() -> [(source: String, title: String, id: String)] {
        guard isAuthorized else { return [] }
        return locked { store.calendars(for: .event) }
            .map { (source: $0.source?.title ?? "Unknown",
                    title: $0.title,
                    id: $0.calendarIdentifier) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// Events between two dates, soonest first.
    public static func events(from: Date, to: Date) -> [CalendarEvent] {
        if let path = fakeEvents {
            return faked(path).filter { $0.start >= from && $0.start <= to }
                .sorted { $0.start < $1.start }
        }
        guard isAuthorized, from < to else { return [] }
        let found = locked { () -> [EKEvent] in
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
            return store.events(matching: predicate)
        }
        return found.map(CalendarEvent.init).sorted { $0.start < $1.start }
    }

    // MARK: - What is about to happen

    /// How far ahead the sidebar looks.
    ///
    /// Twelve hours rather than "the rest of today", which is the obvious rule
    /// and is wrong twice a day: at 18:00 it says the calendar is empty when
    /// tomorrow starts at 09:00, and at 23:00 it has said so for five hours.
    /// Twelve covers an evening from the morning it belongs to without ever
    /// reaching the day after tomorrow.
    public static let horizon: TimeInterval = 12 * 3600

    /// How long a meeting stays listed after its start time has passed.
    ///
    /// A meeting you are five minutes late for is the one you most want the
    /// row for, and its link is on that row. Fifteen rather than the length of
    /// the event: a two hour block that began at nine would otherwise sit at
    /// the top of the library until eleven, which is a calendar rather than a
    /// heads-up.
    public static let lateness: TimeInterval = 15 * 60

    /// The meetings worth putting at the top of the library.
    ///
    /// Two filters and a cap. `couldBeAMeeting` is the one that keeps
    /// Birthdays, Holidays and every subscribed feed out without anybody
    /// configuring a calendar, because they are all all-day; `kinds` is what
    /// each app is willing to list, and both list everything today. See
    /// `MeetingKind` for why that is not the guest test it started as.
    ///
    /// Capped, and the cap is the point. This list sits above the library, and
    /// a nine-meeting day would push every recording somebody owns off the
    /// screen to say what is coming instead.
    ///
    /// It knows nothing about what is being recorded, deliberately. The meeting
    /// being recorded is still an upcoming event by every rule here, and
    /// dropping it belongs to whichever list would show it twice. See
    /// `SidebarViewController.appendUpcoming`.
    public static func upcoming(limit: Int = 3, now: Date = Date(),
                                including kinds: Set<MeetingKind> = MeetingKind.everything)
        -> [CalendarEvent] {
        guard isAuthorized else { return [] }
        var seen = Set<String>()
        return events(from: now.addingTimeInterval(-lateness),
                      to: now.addingTimeInterval(horizon))
            .filter(\.couldBeAMeeting)
            .filter { kinds.contains($0.kind) }
            // **The same meeting can be in two calendars**, and the id is the
            // iCal UID, which is deliberately shared between the organizer's
            // copy and everybody else's: `calendar.md` records two calendars on
            // the development Mac holding one 15:00 meeting under different
            // names. Listed twice that is a wrong answer on either device, and
            // on the phone it is also a `ForEach` over duplicate ids, which
            // SwiftUI draws wrongly and complains about at runtime.
            //
            // The first one wins, which is the earliest start and then whatever
            // order EventKit gave, and that is as arbitrary as the tie-break in
            // `candidates`. Which copy of one meeting you get is not a question
            // with a right answer; having one is.
            .filter { seen.insert($0.id).inserted }
            .prefix(limit)
            .map { $0 }
    }

    /// Who this app already knows an address belongs to.
    ///
    /// **The contact book is each app's and the calendar is shared, so this is
    /// the seam between them.** `CalendarPerson.bestName` has to ask the book
    /// first, because `calendar_people` is a snapshot frozen when a recording
    /// was matched and the book is the one place a human has said who an
    /// address is: `calendar.md` records a rename that never reached the
    /// speaker picker for exactly this reason, for days.
    ///
    /// A function rather than a type, because the two books are not the same
    /// object. On the Mac it is `ContactBook`, keyed on the transcript label
    /// and living beside the library; on the phone it is `PersonDirectory` read
    /// against that device's own root. Neither belongs in here.
    ///
    /// Installed once at launch, before anything reads a calendar, which on the
    /// Mac is `main.swift` and on the phone is `ListenApp`. Unset, `bestName`
    /// falls through to the invitation's own name field and then to
    /// `PersonDirectory.suggestedName`, which is the weakest of the three and
    /// the only one that cannot be wrong about a person, because it derives a
    /// word from the address rather than claiming to know somebody.
    nonisolated(unsafe) public static var knownName: (@Sendable (String) -> String?)?

    /// Somebody changed the calendar, wherever they changed it.
    ///
    /// `EKEventStoreChangedNotification` is what a local app gets instead of
    /// the server-side push and sync tokens `calendar.md` records giving up,
    /// and this is the first thing here that needs it: everything else reads
    /// the calendar once, at the moment a recording starts, and answers a
    /// question about that instant. A list of what is coming up is wrong the
    /// second somebody moves a meeting in Calendar.
    ///
    /// The observer is never removed, because its one caller lives as long as
    /// the window. The notification arrives in bursts during a sync, so the
    /// handler has to be cheap or idempotent; `tickUpcoming` is both.
    public static func onChange(_ handler: @MainActor @escaping () -> Void) {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                // **`reset()` first, or the re-read answers from the cache the
                // notification was sent to invalidate.** An `EKEventStore` is a
                // long-lived connection with its own cache, and everything this
                // app did with the calendar before was a one-shot read in a
                // process that had just started, so a store that goes stale had
                // never cost anything. A window that is open all day is the
                // first thing here that keeps one for hours.
                //
                // Apple's own guidance on this notification is that cached
                // objects are no longer valid and the store should be reset.
                // Without it, adding a meeting in Calendar posts the
                // notification, the sidebar re-reads, and the answer is the
                // list from before the meeting existed.
                //
                // Behind the same lock as every other read, for the reason the
                // lock exists: a reset racing a read is the shape that returns
                // zero calendars and reports nothing.
                locked { store.reset() }
                Task { @MainActor in handler() }
            }
    }

    /// A file standing in for the calendar, so the sidebar can be tested.
    ///
    /// `LISTEN_FAKE_EVENTS=/tmp/events.json` makes every read here come from
    /// that file. It exists for `LISTEN_FAKE_CALLERS`' reason: the alternative
    /// is holding a real meeting at a known time to test a list, and nobody
    /// will, so the list ships untested. `verify_upcoming.sh` is what uses it.
    ///
    /// Starts are written as minutes from now rather than as dates, because
    /// every assertion worth making is relative ("in 12 min", "listed while it
    /// is 5 minutes late, gone at 20") and a fixture with wall-clock times in
    /// it is a fixture that passes until midnight.
    public static let fakeEvents = ProcessInfo.processInfo.environment["LISTEN_FAKE_EVENTS"]

    private struct FakeEvent: Decodable {
        var title: String
        /// Minutes from now. Negative for a meeting that has already started.
        var `in`: Double
        var minutes: Double?
        /// `Name <address>`, or either half on its own.
        var people: [String]?
        var link: String?
        public var agenda: String?
        var calendar: String?
        var allDay: Bool?
        var declined: Bool?
    }

    private static func faked(_ path: String) -> [CalendarEvent] {
        guard let data = FileManager.default.contents(atPath: path),
              let list = try? JSONDecoder().decode([FakeEvent].self, from: data)
        else {
            FileHandle.standardError.write(Data(
                "[Listen] could not read LISTEN_FAKE_EVENTS at \(path)\n".utf8))
            return []
        }
        let now = Date()
        return list.enumerated().map { index, fake in
            let start = now.addingTimeInterval(fake.in * 60)
            return CalendarEvent(
                id: "fake-\(index)-" + fake.title,
                title: fake.title,
                start: start,
                end: start.addingTimeInterval((fake.minutes ?? 30) * 60),
                calendar: fake.calendar ?? "Fake / Work",
                isAllDay: fake.allDay ?? false,
                declined: fake.declined ?? false,
                people: (fake.people ?? []).map(CalendarPerson.init(fixture:)),
                link: fake.link.flatMap(URL.init(string:)),
                agenda: fake.agenda)
        }
    }

}

// ---------------------------------------------------------------------------

/// What a calendar entry is, which decides both whether it is worth listing and
/// what there is to do about it.
///
/// **This is the vocabulary that replaced a yes-or-no.** The Mac listed only
/// meetings with somebody else on the invitation, borrowing the guest test from
/// `beganDuring`, and that was wrong for the case it was reported on: an event
/// somebody types into their own calendar to hold an hour, or to remember a
/// coffee, has no attendees at all, and most in-person meetings are entered
/// that way. Hiding those was the expensive direction.
///
/// The guest test is still exactly right where it came from, which is
/// **naming a recording**: `attach` writes a title without asking, a wrong
/// title is expensive, and `calendar.md` records the solo block that a thirty
/// minute window once renamed a WhatsApp call after. Nothing here changes that.
/// A row in a list is not a title.
public enum MeetingKind: String, Sendable, CaseIterable {
    /// Somebody else is invited and there is a link. The device that can join
    /// it is the one with the link on screen.
    case call
    /// Somebody else is invited and there is nowhere to click. A room, and the
    /// phone is the only device that can record one.
    case inPerson
    /// Nobody else is invited: an hour held for work, a reminder, a coffee
    /// nobody was sent an invitation for. Worth a voice memo rather than a
    /// meeting recording, and worth saying so.
    case blocked

    public static let everything = Set(MeetingKind.allCases)
    /// What the Mac lists, which is what it listed before blocks were added.
    public static let meetings: Set<MeetingKind> = [.call, .inPerson]
}

extension CalendarEvent {
    /// A link **and** somebody to click it with. A join URL in an event nobody
    /// else is invited to is a personal room or a leftover, not a call.
    public var kind: MeetingKind {
        guard hasGuests else { return .blocked }
        return link == nil ? .inPerson : .call
    }
}

// ---------------------------------------------------------------------------

/// One person on an invitation, as stored beside the recording.
///
/// Snapshotted into `metadata.json` rather than re-read on demand, for the same
/// reason the voiceprints live beside the audio: the event can be edited or
/// deleted, permission can be revoked, and the library has to keep answering
/// afterwards. A recording is a folder and the files in it are the truth.
public struct CalendarPerson: Codable, Equatable, Sendable {
    /// Only when EventKit gave a real one. It hands back the email address in
    /// this field far more often than a name: measured over 72 events with
    /// attendees, 118 of 140 entries had the email here and 22 had a name.
    public var name: String?
    /// Lowercased. From `EKParticipant.url`, which carries a `mailto:` scheme.
    /// There is no public email property on a participant.
    public var email: String?
    /// The user themselves, who is already `Me` by construction on the
    /// microphone track and must never be offered as a name for anybody else.
    public var is_me: Bool
    public var is_organizer: Bool

    /// What to call them, best evidence first. Nil when there is nothing to go
    /// on, which measurement says never happens: every entry carried either a
    /// name or an address.
    ///
    /// **The book comes first, and it used to come last.** `calendar_people` is
    /// a snapshot taken when the recording was matched, so the name in it is
    /// frozen at that moment; the book is the one place a human has said who an
    /// address belongs to, and `People.rename` moves the entry with the name.
    /// Reading the snapshot first meant renaming somebody left the invitation
    /// row in the speaker picker still offering their old name, days after every
    /// transcript had been rewritten, and picking it would have created the old
    /// person over again.
    ///
    /// `suggestedName` stays last, because it is the weakest of the three by
    /// construction: it derives a name from the address itself, which is how
    /// `justadecisionpod@gmail.com` becomes "Justadecisionpod".
    public var bestName: String? {
        if let email, let known = MeetingCalendar.knownName?(email) { return known }
        if let name, !name.isEmpty, !Self.looksLikeAnEmail(name) { return name }
        guard let email else { return nil }
        return PersonDirectory.suggestedName(from: email)
    }

    /// A name field holding an address. Anarlog's `parse_email_from_name` makes
    /// the same check, for the same reason.
    public static func looksLikeAnEmail(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.contains("@") && !t.contains(" ")
    }

    /// A person out of a fixture line: `Ryan Mitchell <ryan@example.com>`,
    /// or either half on its own.
    public init(fixture: String) {
        let text = fixture.trimmingCharacters(in: .whitespaces)
        if let open = text.firstIndex(of: "<"), text.hasSuffix(">") {
            name = String(text[text.startIndex..<open])
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
            email = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
                .lowercased().trimmingCharacters(in: .whitespaces).nilIfEmpty
        } else if Self.looksLikeAnEmail(text) {
            name = nil
            email = text.lowercased()
        } else {
            name = text.nilIfEmpty
            email = nil
        }
        is_me = false
        is_organizer = false
    }

    public init(_ participant: EKParticipant, isOrganizer: Bool = false) {
        email = Self.address(of: participant)
        // A name field holding an address is stored as nil, so nothing
        // downstream has to re-check whether this "name" is really an email.
        let raw = participant.name?.trimmingCharacters(in: .whitespaces) ?? ""
        name = (raw.isEmpty || Self.looksLikeAnEmail(raw)) ? nil : raw
        is_me = participant.isCurrentUser
        is_organizer = isOrganizer
    }

    /// The address behind a participant.
    ///
    /// `EKParticipant` has no public email property. What it has is a `url`
    /// with a `mailto:` scheme, which is where Anarlog reads it from too.
    /// Anything else (a phone number, a room resource) has no address at all.
    private static func address(of participant: EKParticipant) -> String? {
        let url = participant.url
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        let raw = String(url.absoluteString.dropFirst("mailto:".count))
        let decoded = raw.removingPercentEncoding ?? raw
        return decoded.lowercased().trimmingCharacters(in: .whitespaces).nilIfEmpty
    }
}

/// One meeting, flattened out of `EKEvent`.
public struct CalendarEvent: Identifiable, Sendable {
    /// The iCal UID, which is stable across syncs and shared between the
    /// organizer's copy and everybody else's. `eventIdentifier` is not: it is
    /// per-store, and for a repeating event it is the same for every occurrence.
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var calendar: String
    public var isAllDay: Bool
    /// The user declined this invitation, so they are probably not in it.
    public var declined: Bool
    public var people: [CalendarPerson]
    public var link: URL?
    /// The invitation's own body, which is where an agenda is written.
    ///
    /// **Never snapshotted into `metadata.json`.** `calendar_people` is stored
    /// beside the recording because the library has to keep answering after the
    /// event is edited or deleted; this is read to prepare for a meeting that
    /// has not happened, and by the time there is a recording the transcript is
    /// the better copy of what was discussed. Keeping it in memory also keeps
    /// somebody else's invitation body out of a file this app syncs.
    var agenda: String?

    public init(_ event: EKEvent) {
        id = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString
        // Collapsed, not truncated. A title arrives from someone else's calendar
        // and can carry newlines, which would break every single-line row that
        // prints it. Cutting it short would lose information the user cannot get
        // back, and they can always edit it.
        title = (event.title ?? "").collapsingWhitespace
        start = event.startDate ?? Date.distantPast
        end = event.endDate ?? start
        calendar = [event.calendar?.source?.title, event.calendar?.title]
            .compactMap { $0 }.joined(separator: " / ")
        isAllDay = event.isAllDay

        let organizer = event.organizer.map { CalendarPerson($0, isOrganizer: true) }
        var everyone = (event.attendees ?? []).map { attendee -> CalendarPerson in
            var person = CalendarPerson(attendee)
            if let mine = person.email, mine == organizer?.email { person.is_organizer = true }
            return person
        }
        // The organizer is usually also in `attendees`, but not always: a
        // meeting booked on somebody's behalf lists them only here, and they
        // are exactly the person whose name is worth having. Matched on the
        // address, because the name field is unreliable by construction.
        if let organizer,
           !everyone.contains(where: { $0.email != nil && $0.email == organizer.email }) {
            everyone.insert(organizer, at: 0)
        }

        // Deduplicated, and entries with nothing to show dropped.
        //
        // Both were measured on a real invitation, which came back as: Ryan
        // Mitchell (organizer, no address), Ryan Mitchell (again, no address),
        // an entry with no name and no address at all, and Ryan under a work
        // address. The organizer check above only folds duplicates that share
        // an address, so somebody listed without one arrives twice, and a
        // nameless entry becomes a button reading "(unnamed)".
        //
        // The key is the address when there is one and the name otherwise,
        // which deliberately keeps two different addresses apart: the same
        // human under a personal and a work address is not something this file
        // can know, and merging them here would file one person's meetings
        // under the other. That is exactly the question the contact book
        // exists to let a human answer once.
        var seen = Set<String>()
        people = everyone.filter { person in
            guard let key = person.email ?? person.name?.lowercased() else { return false }
            return seen.insert(key).inserted
        }

        declined = (event.attendees ?? []).contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        }

        // The link is in the notes, not in `url`. Measured on the development
        // machine: `event.url` was nil on every Google event, and the Meet link
        // sat in the notes body. Anarlog's `parse_meeting_link` reads the same
        // place for the same reason.
        link = event.url ?? MeetingLink.find(in: event.notes)
            ?? MeetingLink.find(in: event.location)
        agenda = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Every field, for the fixtures. Written out because a struct with an
    /// initialiser of its own has no memberwise one, and `.agents/notes` records
    /// that a public struct's memberwise init is internal anyway.
    public init(id: String, title: String, start: Date, end: Date, calendar: String,
         isAllDay: Bool, declined: Bool, people: [CalendarPerson], link: URL?,
         agenda: String?) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.calendar = calendar
        self.isAllDay = isAllDay
        self.declined = declined
        self.people = people
        self.link = link
        self.agenda = agenda
    }

    /// Everybody on the invitation except the user.
    ///
    /// The user is `Me` by construction on the microphone track, so they are
    /// never a name to suggest and never a person to be briefed about. Same
    /// rule `CalendarPerson.is_me` exists for.
    public var guests: [CalendarPerson] { people.filter { !$0.is_me } }

    /// Somebody else is invited.
    ///
    /// The test `beganDuring` makes on the Mac, hoisted here so `MeetingKind`
    /// can make it too. **It does not decide whether a meeting is listed**, and
    /// for one build it did: see `MeetingKind` for why a rule that is right
    /// about naming a recording was wrong about drawing a row.
    public var hasGuests: Bool { !guests.isEmpty }

    /// What to call them, in the order a sentence would.
    public var guestNames: [String] { guests.compactMap { $0.bestName ?? $0.email } }

    /// Worth considering as the meeting a recording is of.
    ///
    /// All-day events are the whole reason there is no per-calendar setting:
    /// Birthdays, Holidays and subscribed feeds are all all-day, so excluding
    /// them here excludes those calendars without anybody having to configure
    /// anything.
    public var couldBeAMeeting: Bool { !isAllDay && !declined && !title.isEmpty }

    /// "Google / Work · 14:30, 2 invited", for the CLI report.
    public var summary: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let invited = people.isEmpty ? "no attendees"
            : "\(people.count) invited"
        return "\(calendar) · \(f.string(from: start)) · \(invited)"
    }
}

// ---------------------------------------------------------------------------

/// Finding the join link in whatever text a calendar invitation put it in.
///
/// Ported from Anarlog's `parse_meeting_link` (`crates/calendar/src/lib.rs`),
/// including the fallback to any URL at all: the known patterns cover the
/// common cases and a meeting on the fifth thing still has a link worth
/// keeping. This is the same argument `MeetingDetector` makes for not matching
/// on a list of bundle identifiers.
public enum MeetingLink {
    private static let patterns: [NSRegularExpression] = [
        #"https://meet\.google\.com/[a-z0-9]{3,4}-[a-z0-9]{3,4}-[a-z0-9]{3,4}"#,
        #"https://[a-z0-9.-]+\.zoom\.us/j/\d+(\?pwd=[a-zA-Z0-9._-]+)?"#,
        #"https://teams\.microsoft\.com/l/meetup-join/[^\s"'<>]+"#,
        #"https://app\.cal\.com/video/[a-zA-Z0-9]+"#,
        #"https?://[^\s"'<>]+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func find(in text: String?) -> URL? {
        guard let text, !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for pattern in patterns {
            guard let match = pattern.firstMatch(in: text, range: range),
                  let found = Range(match.range, in: text) else { continue }
            // Trailing punctuation is a sentence ending, not part of the URL.
            let trimmed = text[found].trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]"))
            if let url = URL(string: String(trimmed)) { return url }
        }
        return nil
    }
}

// ---------------------------------------------------------------------------

extension String {
    public var nilIfEmpty: String? { isEmpty ? nil : self }

    /// Newlines and runs of spaces become one space.
    public var collapsingWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// ---------------------------------------------------------------------------

/// How a time in the near future is worded, in the one place everything reads.
///
/// Two copies of "in 12 min" is two answers to the same question, and this one
/// is printed on a row that redraws once a minute, in a page header, and in the
/// CLI.
public enum EventTime {
    /// "now", "in 12 min", "14:30", "Tomorrow 09:00".
    ///
    /// **"now" covers a meeting that has already started**, which is a state
    /// this list is in for up to `MeetingCalendar.lateness`. Counting the
    /// minutes upwards there ("12 min ago") is a reproach rather than a fact,
    /// and the row is most useful in exactly that minute because the link is
    /// on it.
    public static func relative(_ start: Date, now: Date = Date()) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 30 { return "now" }
        // Under the hour, counted. Past it, the clock time is what somebody is
        // actually comparing against: "in 4 hr" is not how anybody thinks about
        // a two o'clock meeting.
        if seconds < 3600 { return "in \(Int((seconds / 60).rounded())) min" }
        let calendar = Calendar.current
        if calendar.isDateInToday(start) { return stamp(start) }
        if calendar.isDateInTomorrow(start) { return "Tomorrow " + stamp(start) }
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f.string(from: start)
    }

    public static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// "Today 14:30 to 15:00", for the page's header and for the sentence the
    /// agent is handed.
    ///
    /// **Not `SidebarViewController.heading(for:)`, which is the list's.** That
    /// one answers about the past, because everything in the library has already
    /// happened: it can say Yesterday and it cannot say Tomorrow, which is half
    /// of what this list shows. It is also `@MainActor`, and this is read by the
    /// CLI as well as by the window.
    public static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: date)
    }

    public static func span(_ event: CalendarEvent) -> String {
        "\(day(event.start)) \(stamp(event.start)) to \(stamp(event.end))"
    }
}

// ---------------------------------------------------------------------------

/// The invitation, as sentences an agent can act on.
///
/// **The agent has no calendar.** It reaches the library through `listen mcp`
/// and that is all, so an invitation that is not in the question does not exist
/// as far as the answer is concerned. Everything the model needs about a
/// meeting that has not happened travels in the text of the question, which is
/// the rule the person chips already follow for a person's name.
public enum MeetingBrief {
    /// Who is coming, by the name the library would know them under.
    ///
    /// `bestName` asks the contact book first, so a guest whose invitation says
    /// `justadecisionpod@gmail.com` is named here as whoever the user has said
    /// that address is. That is the whole reason the names are worth sending:
    /// they are the strings `list_people` and `get_person_context` answer to.
    /// The address goes with them, because it is the reliable half and because
    /// it is what makes two people with one first name distinguishable.
    public static func guests(_ event: CalendarEvent) -> String {
        let named = event.guests.map { person -> String in
            switch (person.bestName, person.email) {
            case (let name?, let email?): return "\(name) (\(email))"
            case (let name?, nil):        return name
            case (nil, let email?):       return email
            default:                      return "somebody unnamed"
            }
        }
        guard !named.isEmpty else { return "nobody else" }
        guard named.count > 1 else { return named[0] }
        return named.dropLast().joined(separator: ", ") + " and " + named[named.count - 1]
    }

    /// The whole invitation in one paragraph, including the fact that it has
    /// not happened.
    ///
    /// **Saying so is load-bearing.** Without it the first move is a search for
    /// a transcript of this meeting, which does not exist, and the honest
    /// answer to that search is "I cannot find this meeting": measured on the
    /// first run, and it is a round trip and a wrong answer bought for one
    /// clause.
    public static func invitation(_ event: CalendarEvent) -> String {
        var text = "I have a meeting called \u{201C}\(event.title)\u{201D} "
            + "at \(EventTime.span(event)), with \(guests(event)). "
            + "It has not happened yet, so there is no recording or transcript of it "
            + "in my library."
        if let agenda = trimmedAgenda(event) {
            text += " The invitation says: \u{201C}\(agenda)\u{201D}"
        }
        return text
    }

    /// The invitation body, minus the boilerplate, capped.
    ///
    /// Measured on this machine's own calendar: a Google invitation's notes are
    /// usually the agenda in one or two lines followed by twelve of dial-in
    /// instructions, a phone PIN and a link to a help page. Everything from the
    /// first join-instruction line on is dropped, and what is left is capped at
    /// 600 characters, which is about a screen of agenda and far short of the
    /// point where it would crowd out the question.
    public static func trimmedAgenda(_ event: CalendarEvent) -> String? {
        guard let raw = event.agenda else { return nil }
        var kept: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let lower = text.lowercased()
            if boilerplate.contains(where: { lower.hasPrefix($0) }) { break }
            if !text.isEmpty { kept.append(text) }
        }
        let body = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        return body.count > 600 ? String(body.prefix(600)) + "…" : body
    }

    /// The lines that mean "the agenda has ended and the dial-in has begun".
    ///
    /// Prefixes rather than a regular expression, because the strings are
    /// fixed: Google, Zoom and Teams each write the same opener every time, and
    /// the one thing that must not happen is a heuristic eating somebody's
    /// actual agenda.
    private static let boilerplate = [
        "-::~", "join with google meet", "join zoom meeting", "join the meeting",
        "microsoft teams", "________", "join on your computer",
        "learn more about meet", "meeting id:", "one tap mobile",
        "dial in", "dial-in", "or dial:", "join by phone",
    ]

    /// The chips offered on a meeting that has not happened.
    ///
    /// Three shapes, and all three are only answerable because the subject is
    /// an invitation rather than a transcript: what I should know before this,
    /// what is outstanding with these people, and who they are. "Summarise" and
    /// "Decisions" are absent for the obvious reason.
    ///
    /// The fourth is conditional in `speakerStarter`'s spirit: a briefing on
    /// one named guest, offered only when there is exactly one, because "brief
    /// me on Ryan, Emily and Sam" is three answers in a paragraph and none of
    /// them is worth reading.
    public static func starters(for event: CalendarEvent) -> [(String, String)] {
        var offered: [(String, String)] = [
            ("Prepare",
             "Go through my recordings with these people and tell me what I need "
             + "before this meeting: what we last discussed, what I said I would do, "
             + "what they said they would do, and what is worth raising. Under 200 "
             + "words, and name the meeting behind each point."),
            ("Open items",
             "What is still outstanding between me and these people? Commitments "
             + "either way, and questions nobody answered. Say which meeting each "
             + "one came from, and say so plainly if there is nothing."),
        ]
        // Named here rather than left to the invitation sentence, so the chip
        // still reads correctly when the turn is retried or resumed, which is
        // the rule `personStarters` already follows.
        if let only = event.guests.first, event.guests.count == 1,
           let name = only.bestName {
            offered.append(("Brief me on \(name)",
                            "Who is \(name), what do they care about, and what have "
                            + "they said in our meetings that I should remember? If "
                            + "my library has nothing about them, say so rather than "
                            + "guessing."))
        } else {
            offered.append(("Who is coming",
                            "For each person invited: have I met them before, what do "
                            + "my recordings say about them, and what do they care "
                            + "about? Say plainly which of them my library knows "
                            + "nothing about."))
        }
        return offered
    }
}

// ---------------------------------------------------------------------------
