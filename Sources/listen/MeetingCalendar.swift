import EventKit
import Foundation

/// The calendars already on this Mac, read through EventKit.
///
/// **There is no OAuth here, and there is deliberately no backend.** Anarlog
/// supports Google and Outlook by brokering OAuth through Nango and proxying
/// every read through its own API behind a Supabase login, which is why those
/// two providers are a paid, signed-in feature over there. macOS has already
/// done that work: an account added in System Settings, Internet Accounts syncs
/// into the system calendar store, and EventKit hands it over with no
/// distinction from iCloud. Measured on the development machine: 16 calendars
/// across two Google accounts (as calDAV), iCloud, a subscription and
/// Birthdays, with attendee emails and organizers on the events.
///
/// So the whole feature costs one permission prompt and no network connection,
/// which is also why `InternetAccessPolicy.plist` needs no new entry.
///
/// Read-only, always. Nothing here creates, edits or deletes an event.
enum MeetingCalendar {

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
    /// `internal` rather than private because `Permissions.requestCalendar`
    /// must ask on *this* store. A grant landing on a different store leaves
    /// this one answering from the access it was created with, and every read
    /// afterwards returns nothing.
    static let store = EKEventStore()

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

    static var isAuthorized: Bool { Permissions.calendar }

    /// Every calendar, as "Google / Work".
    ///
    /// The source is half the answer: two accounts routinely have a calendar
    /// with the same name, and on the development machine three do.
    static func calendars() -> [(source: String, title: String, id: String)] {
        guard isAuthorized else { return [] }
        return locked { store.calendars(for: .event) }
            .map { (source: $0.source?.title ?? "Unknown",
                    title: $0.title,
                    id: $0.calendarIdentifier) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    /// Events between two dates, soonest first.
    static func events(from: Date, to: Date) -> [CalendarEvent] {
        guard isAuthorized, from < to else { return [] }
        let found = locked { () -> [EKEvent] in
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
            return store.events(matching: predicate)
        }
        return found.map(CalendarEvent.init).sorted { $0.start < $1.start }
    }

    // MARK: - Matching a recording to a meeting

    /// How far a meeting's start may sit from a recording's and still be the
    /// same meeting.
    ///
    /// Measured over the 47 recordings in the real library, anchoring on start
    /// time. `matched` counts recordings with at least one candidate;
    /// `named` counts the seven that somebody had bothered to title by hand,
    /// which is the closest thing to ground truth available:
    ///
    ///     +/- 5m    matched  9/47   named 3/7   ambiguous 1
    ///     +/- 10m   matched 14/47   named 6/7   ambiguous 2
    ///     +/- 15m   matched 14/47   named 6/7   ambiguous 2
    ///     +/- 20m   matched 14/47   named 6/7   ambiguous 2
    ///     +/- 30m   matched 16/47   named 6/7   ambiguous 4
    ///
    /// Ten minutes is the knee. Ten, fifteen and twenty are identical, so the
    /// widest of them buys nothing; thirty buys two extra matches and **both
    /// are wrong** (a WhatsApp call matched a solo calendar block 26 minutes
    /// away, titled "Review the Q3 launch Reel"). Since the title is
    /// applied without asking, a wrong match is the expensive direction.
    static let window: TimeInterval = 10 * 60

    /// A meeting that began while the recording was already running.
    ///
    /// The second rule, and deliberately **asymmetric**. "The recording
    /// overlaps the event" would also cover a recording that started in the
    /// middle of somebody's hour-long focus block, which is exactly the wrong
    /// match the thirty minute row above bought: a WhatsApp call landing inside
    /// a solo block called "Review the Q3 launch Reel". This rule says
    /// something much narrower and much stronger, that capture was already
    /// running at the minute the invitation said the meeting would begin.
    ///
    /// It exists because of a real recording: a Google Meet link opened 26
    /// minutes early, capture started by detection at 17:19, and the meeting
    /// beginning at 17:45 while it ran. Every offset in the measured table was
    /// between -9 and +0 minutes, so joining early was simply not in the
    /// sample; it is not rare, it is what a link in an invitation invites.
    ///
    /// Somebody else has to be on the invitation. This rule reaches as far as
    /// the recording is long, which on an 80 minute meeting is far past the
    /// thirty minutes already measured as too wide, so it asks for a second
    /// piece of evidence that this is a meeting with people in it rather than a
    /// block somebody put in their own calendar. That is the same standard
    /// `people` is held to everywhere else here.
    ///
    /// Measured over the 42 recordings now in the library: with and without
    /// this check the rule finds the same one match, so today it costs nothing.
    /// It stays because the wrong match the thirty minute row bought was
    /// exactly a solo block, and a rule that reaches further should not be
    /// looser as well.
    private static func beganDuring(_ event: CalendarEvent,
                                    _ start: Date, _ end: Date) -> Bool {
        guard event.start >= start, event.start <= end else { return false }
        return event.people.contains { !$0.is_me }
    }

    /// Every meeting that could be the one this recording is of.
    ///
    /// Two rules: a meeting that **started when the recording did**, within
    /// `window` either way, and a meeting that **started while it ran**.
    ///
    /// Anchored on starts, never on overlap. A recording that merely overlaps
    /// an event is not evidence of anything on a Mac that is on all day.
    ///
    /// The second rule can only ever *add* a match, never change one. Anything
    /// it finds is by definition more than `window` from the recording's start,
    /// so it sorts behind everything the first rule found and the winner of a
    /// non-empty first rule is untouched. The fourteen matches in the table
    /// above are therefore still those fourteen.
    ///
    /// `duration` is zero for a recording that is still running, which switches
    /// the second rule off: capture has no span yet. That is why `Capture` asks
    /// again when it stops.
    static func candidates(for start: Date, lasting duration: TimeInterval = 0) -> [CalendarEvent] {
        let end = start.addingTimeInterval(max(0, duration))
        return events(from: start.addingTimeInterval(-window),
                      to: max(end, start.addingTimeInterval(window)))
            .filter(\.couldBeAMeeting)
            .filter { abs($0.start.timeIntervalSince(start)) <= window
                      || beganDuring($0, start, end) }
            .sorted {
                // Nearest start wins. Attendees only break a tie: the table
                // above was measured with nearest-start alone, and preferring
                // the invite with more people in it would be an unmeasured
                // change to a rule that produced fourteen plausible matches.
                let a = abs($0.start.timeIntervalSince(start))
                let b = abs($1.start.timeIntervalSince(start))
                if a != b { return a < b }
                return $0.people.count > $1.people.count
            }
    }

    static func match(for start: Date, lasting duration: TimeInterval = 0) -> CalendarEvent? {
        candidates(for: start, lasting: duration).first
    }

    /// The same, for a recording. Nil when it has no usable start time.
    ///
    /// The duration is the one on disk, which is zero while capture is running
    /// and the real length afterwards.
    static func match(for recording: Recording) -> CalendarEvent? {
        guard let date = recording.date else { return nil }
        return match(for: date, lasting: recording.metadata.duration)
    }

    // MARK: - Attaching a meeting to a recording

    /// A calendar title long enough to be a problem as a filename.
    ///
    /// Titles come from other people's calendars and Listen applies them
    /// without asking, so unlike a title somebody typed this one is not
    /// self-inflicted. The longest seen in the real library is 68 characters.
    private static let maxTitle = 120

    /// Record which meeting a recording is of, and name it if nobody has.
    ///
    /// One function, so the automatic path and `listen calendar backfill` write
    /// exactly the same fields in exactly the same order. Returns the updated
    /// recording, or nil when nothing changed.
    ///
    /// The attendees are stored **whether or not the title is applied**. A
    /// recording somebody named by hand still has a guest list worth keeping,
    /// and the speaker sheet is the thing that spends it.
    ///
    /// `refresh` re-reads a recording that is already attached. Only
    /// `listen calendar backfill --refresh` passes it, because the automatic
    /// path must not: a guest list that has already been picked from is a
    /// decision, and quietly replacing it with whatever the invitation says
    /// today would undo one. It exists for the case where this file learns to
    /// read the same event better, which has happened once already.
    @discardableResult
    static func attach(to recording: Recording, refresh: Bool = false) -> Recording? {
        guard isAuthorized else { return nil }
        // Attached once. A second pass must not overwrite a guest list that a
        // rename or a merge has already been reasoned about.
        guard refresh || recording.metadata.calendar_event_id == nil else { return nil }
        guard let event = match(for: recording) else { return nil }

        var updated = recording
        updated.metadata.calendar_event_id = event.id
        updated.metadata.calendar_people = event.people
        // Never over a name somebody typed. `isUntitled` is the whole guard:
        // the moment a title is edited it stops being the placeholder, and
        // nothing here matches again.
        if updated.isUntitled { updated.metadata.title = title(from: event) }
        try? updated.save()
        trace("calendar: \(recording.id) is \"\(event.title)\" (\(event.summary))")
        return updated
    }

    /// The automatic path, which the setting governs. `attach` itself does not
    /// consult it, so `listen calendar backfill` still works for somebody who
    /// turned the automatic naming off and wants to do one by hand.
    @discardableResult
    static func attachIfEnabled(to recording: Recording) -> Recording? {
        guard Settings.nameFromCalendar else { return nil }
        return attach(to: recording)
    }

    static func title(from event: CalendarEvent) -> String {
        guard event.title.count > maxTitle else { return event.title }
        return String(event.title.prefix(maxTitle))
            .trimmingCharacters(in: .whitespaces) + "…"
    }
}

// ---------------------------------------------------------------------------

/// One person on an invitation, as stored beside the recording.
///
/// Snapshotted into `metadata.json` rather than re-read on demand, for the same
/// reason the voiceprints live beside the audio: the event can be edited or
/// deleted, permission can be revoked, and the library has to keep answering
/// afterwards. A recording is a folder and the files in it are the truth.
struct CalendarPerson: Codable, Equatable {
    /// Only when EventKit gave a real one. It hands back the email address in
    /// this field far more often than a name: measured over 72 events with
    /// attendees, 118 of 140 entries had the email here and 22 had a name.
    var name: String?
    /// Lowercased. From `EKParticipant.url`, which carries a `mailto:` scheme.
    /// There is no public email property on a participant.
    var email: String?
    /// The user themselves, who is already `Me` by construction on the
    /// microphone track and must never be offered as a name for anybody else.
    var is_me: Bool
    var is_organizer: Bool

    /// What to call them before anybody has said. Nil when there is nothing to
    /// go on, which measurement says never happens: every entry carried either
    /// a name or an address.
    var bestName: String? {
        if let name, !name.isEmpty, !Self.looksLikeAnEmail(name) { return name }
        guard let email else { return nil }
        return ContactBook.suggestedName(from: email)
    }

    /// A name field holding an address. Anarlog's `parse_email_from_name` makes
    /// the same check, for the same reason.
    static func looksLikeAnEmail(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.contains("@") && !t.contains(" ")
    }

    init(_ participant: EKParticipant, isOrganizer: Bool = false) {
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
struct CalendarEvent {
    /// The iCal UID, which is stable across syncs and shared between the
    /// organizer's copy and everybody else's. `eventIdentifier` is not: it is
    /// per-store, and for a repeating event it is the same for every occurrence.
    var id: String
    var title: String
    var start: Date
    var end: Date
    var calendar: String
    var isAllDay: Bool
    /// The user declined this invitation, so they are probably not in it.
    var declined: Bool
    var people: [CalendarPerson]
    var link: URL?

    init(_ event: EKEvent) {
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
    }

    /// Worth considering as the meeting a recording is of.
    ///
    /// All-day events are the whole reason there is no per-calendar setting:
    /// Birthdays, Holidays and subscribed feeds are all all-day, so excluding
    /// them here excludes those calendars without anybody having to configure
    /// anything.
    var couldBeAMeeting: Bool { !isAllDay && !declined && !title.isEmpty }

    /// "Google / Work · 14:30, 2 invited", for the CLI report.
    var summary: String {
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
enum MeetingLink {
    private static let patterns: [NSRegularExpression] = [
        #"https://meet\.google\.com/[a-z0-9]{3,4}-[a-z0-9]{3,4}-[a-z0-9]{3,4}"#,
        #"https://[a-z0-9.-]+\.zoom\.us/j/\d+(\?pwd=[a-zA-Z0-9._-]+)?"#,
        #"https://teams\.microsoft\.com/l/meetup-join/[^\s"'<>]+"#,
        #"https://app\.cal\.com/video/[a-zA-Z0-9]+"#,
        #"https?://[^\s"'<>]+"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func find(in text: String?) -> URL? {
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
    var nilIfEmpty: String? { isEmpty ? nil : self }

    /// Newlines and runs of spaces become one space.
    var collapsingWhitespace: String {
        split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
