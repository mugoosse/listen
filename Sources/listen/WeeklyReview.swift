import Foundation
import ListenKit

/// The Mac's answers to `ReviewSource`, and the galaxy ids a review's
/// references turn into here.
///
/// **The cards moved to ListenKit and the fetch stayed.** Which cards exist,
/// what they are called, which ones a person gets and which the library does,
/// and every word on them, are in `ListenKit/Review.swift` so the phone can
/// compile the same page. What could not move is everything below: a ledger, a
/// roster derived from transcripts, EventKit. The phone has none of those and
/// reads the sealed card projection instead, which is the whole reason this is
/// a protocol rather than a shared file with two `#if`s in it.
struct LibraryReviewSource: ReviewSource {
    /// Read once and held, because `Review.build` asks for the roster and then
    /// for claims person by person, and every one of those would otherwise
    /// re-read the library from disk.
    private let library: [Recording]
    private let people: [Person]
    private let document: MemoryDocument?

    init() {
        library = Recording.all()
        people = People.roster(in: library)
        document = try? PeopleMemory.load()
    }

    var you: String? { Settings.userName }
    var asksEnabled: Bool { Settings.askEnabled }

    func conversations(from: Date, to: Date) -> [ReviewConversation] {
        library.compactMap { recording in
            guard let date = recording.date, date >= from, date <= to else { return nil }
            return Self.conversation(recording)
        }
    }

    func notes(from: Date, to: Date) -> [ReviewNoteRef] {
        Notes.all().compactMap { note in
            guard let created = Review.instant(note.created), created >= from, created <= to
            else { return nil }
            return ReviewNoteRef(slug: note.slug, title: note.title,
                                 created: created, recordings: note.recordings)
        }
    }

    func chats(from: Date, to: Date) -> [String] {
        guard Settings.askEnabled else { return [] }
        return Chat.all().compactMap { chat in
            guard let id = chat.id, let created = chat.created.flatMap(Review.instant),
                  created >= from, created <= to else { return nil }
            return id
        }
    }

    func roster() -> [ReviewPerson] {
        people.map { person in
            ReviewPerson(label: person.label, display: person.display, isYou: person.isYou,
                         conversations: person.recordings.count,
                         firstSeen: person.recordings.compactMap(\.date).min(),
                         lastSeen: person.lastSeen)
        }
    }

    func claims(about person: String) -> [ReviewClaim] {
        guard let memory = try? PeopleMemory.person(person, document: document) else { return [] }
        return (memory.facts + memory.relations).map { item in
            ReviewClaim(id: item.id, subject: person, text: item.value,
                        attribute: item.attribute, status: item.status,
                        quote: item.evidence.first?.quote ?? "",
                        source: item.evidence.first?.source ?? "",
                        date: (item.evidence + (item.changeEvidence ?? [])).map(\.date).max() ?? "",
                        ended: item.time?.to != nil)
        }
    }

    func needingNames() -> [ReviewConversation] {
        ContextEnrolment.needsNames(library).map(Self.conversation)
    }

    func upcoming(limit: Int) -> [ReviewMeeting] {
        MeetingCalendar.upcoming(limit: limit).map { event in
            // Attendees resolved to roster labels here, because matching an
            // email address to somebody is a thing each platform does its own
            // way and the shared builder must not have an opinion about it.
            let labels = event.people.filter { !$0.is_me }.compactMap { attendee -> String? in
                guard let wanted = attendee.name ?? attendee.email else { return nil }
                return people.first {
                    !$0.isYou && ($0.display.localizedCaseInsensitiveCompare(wanted) == .orderedSame
                        || wanted.localizedCaseInsensitiveContains($0.display))
                }?.label
            }
            return ReviewMeeting(id: event.id, title: event.title, start: event.start, people: labels)
        }
    }

    private static func conversation(_ recording: Recording) -> ReviewConversation {
        ReviewConversation(
            id: recording.id, title: recording.displayTitle,
            date: recording.date ?? .distantPast, seconds: recording.metadata.duration,
            speakers: Array(Set(recording.storedTurns.map(\.speaker)
                .filter { !VoiceBank.isPlaceholder($0) })).sorted())
    }
}

/// What the window and the CLI call. The name is kept because it is the one the
/// rest of this app already says, over a builder that is now shared.
enum WeeklyReview {
    // The names the rest of this app already says, over the shared types. A
    // rename across six files would be a bigger diff than the move itself and
    // would say nothing the move does not.
    typealias Scope = ReviewScope
    typealias Card = ReviewCard
    typealias Item = ReviewItem
    typealias Stat = ReviewStat
    typealias Kind = ReviewKind

    static let ranges = Review.ranges

    /// Off the main thread: the source reads every recording's turns.
    static func build(from: Date, to: Date = Date(), scope: ReviewScope = .library) -> Review {
        Review.build(scope: scope, from: from, to: to, source: LibraryReviewSource())
    }

    /// When the owner last finished a library review, so the next one covers
    /// what they have not seen rather than a fixed seven days.
    ///
    /// A defaults key rather than anything in the library, following
    /// `Settings.lastSeenVersion`: which weeks somebody has looked at is a fact
    /// about this Mac's screen, not about the recordings.
    static var lastReviewed: Date? {
        get {
            let seconds = Settings.defaults.double(forKey: "lastReviewedAt")
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        }
        set { Settings.defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "lastReviewedAt") }
    }

    /// The window a review opens on: since it was last read, never less than a
    /// day and never more than a month. A first run gets seven days, which is
    /// the cadence the feature is named for.
    static var defaultWindow: (from: Date, to: Date) {
        let now = Date()
        let since = lastReviewed ?? now.addingTimeInterval(-7 * 86_400)
        let clamped = min(max(since, now.addingTimeInterval(-31 * 86_400)),
                          now.addingTimeInterval(-86_400))
        return (clamped, now)
    }
}

/// The galaxy ids a review's references become, which is a Mac idea: the phone
/// draws no scene and its refs become a `NavigationLink` instead.
extension ReviewRef {
    var galaxyID: String? {
        switch kind {
        case ReviewRef.recording: return Galaxy.recordingID(key)
        case ReviewRef.note:      return Galaxy.noteID(key)
        case ReviewRef.chat:      return Galaxy.chatID(key)
        case ReviewRef.person:    return Galaxy.personID(key)
        default:                  return nil
        }
    }
    /// `rec:…`, `note:…` or a person label, which is what `openReviewSubject`
    /// has always taken.
    var target: String {
        switch kind {
        case ReviewRef.recording: return "rec:" + key
        case ReviewRef.note:      return "note:" + key
        default:                  return key
        }
    }
}
