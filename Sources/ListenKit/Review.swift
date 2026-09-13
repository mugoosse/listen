import Foundation

/// A review of a library, or of one person in it, as cards somebody can act on.
///
/// **Shared, because the phone wants the same page and cannot build it the same
/// way.** The Mac has the ledger, the roster and the calendar; the phone has its
/// own recordings and the sealed card projection that `ContextSync` hands it,
/// and nothing else. Everything above the fetch is identical: which cards exist,
/// which ones a person gets and which the library does, what they are called,
/// what order they come in and what verbs they carry. So the fetch is a
/// protocol and the rest of it lives here, where both apps compile it.
///
/// Nothing in this file imports AppKit, reads a file or knows what a galaxy is.
/// Star references leave as `(kind, key)` pairs for a caller that draws one.
public enum ReviewScope: Equatable, Sendable {
    case library
    case person(String)
    public var person: String? { if case .person(let label) = self { return label }; return nil }
}

/// What a card is, in the order a deck shows them.
public enum ReviewKind: String, Sendable {
    case week, newPeople, learned, changed, commitments, looseEnds
    case outOfTouch, upcoming, ask
}

public struct ReviewStat: Sendable {
    public var value: String
    public var label: String
    /// A node kind, so a caller that colours by shell can. Free text to this
    /// file: `Galaxy.Node` is a Mac type and this one must not know it.
    public var kind: String
    public init(value: String, label: String, kind: String) {
        self.value = value; self.label = label; self.kind = kind
    }
}

/// Something a card points at, for a caller that can open or draw it.
public struct ReviewRef: Sendable, Equatable {
    public var kind: String
    public var key: String
    public init(kind: String, key: String) { self.kind = kind; self.key = key }
    public static let recording = "recording", note = "note", chat = "chat", person = "person"
}

public struct ReviewItem: Sendable, Identifiable {
    public var id: String
    public var text: String
    public var quote: String = ""
    /// What opening this item should open.
    public var ref: ReviewRef?
    public var date: String = ""
    public init(id: String, text: String, quote: String = "", ref: ReviewRef? = nil, date: String = "") {
        self.id = id; self.text = text; self.quote = quote; self.ref = ref; self.date = date
    }
}

public struct ReviewCard: Sendable, Identifiable {
    public var id: String
    public var kind: ReviewKind
    public var title: String
    public var detail: String
    public var stats: [ReviewStat] = []
    public var items: [ReviewItem] = []
    public var verbs: [String] = []
    public var stars: [ReviewRef] = []
}

// MARK: - What a source has to answer

public struct ReviewConversation: Sendable {
    public var id: String
    public var title: String
    public var date: Date
    public var seconds: Double
    /// Named speakers only. Empty means nobody has been labelled yet, which is
    /// the one state a person can go and fix.
    public var speakers: [String]
    public init(id: String, title: String, date: Date, seconds: Double, speakers: [String]) {
        self.id = id; self.title = title; self.date = date
        self.seconds = seconds; self.speakers = speakers
    }
}

public struct ReviewNoteRef: Sendable {
    public var slug: String
    public var title: String
    public var created: Date
    public var recordings: [String]
    public init(slug: String, title: String, created: Date, recordings: [String]) {
        self.slug = slug; self.title = title; self.created = created; self.recordings = recordings
    }
}

public struct ReviewClaim: Sendable {
    public var id: String
    public var subject: String
    public var text: String
    public var attribute: String
    public var status: String
    public var quote: String
    public var source: String
    /// Newest evidence, ISO 8601, as the ledger stores it.
    public var date: String
    /// Whether this claim has an end date, which makes it a change rather than
    /// a fact however its status reads.
    public var ended: Bool
    public init(id: String, subject: String, text: String, attribute: String, status: String,
                quote: String, source: String, date: String, ended: Bool) {
        self.id = id; self.subject = subject; self.text = text; self.attribute = attribute
        self.status = status; self.quote = quote; self.source = source
        self.date = date; self.ended = ended
    }
}

public struct ReviewPerson: Sendable {
    public var label: String
    public var display: String
    public var isYou: Bool
    public var conversations: Int
    public var firstSeen: Date?
    public var lastSeen: Date?
    public init(label: String, display: String, isYou: Bool, conversations: Int,
                firstSeen: Date?, lastSeen: Date?) {
        self.label = label; self.display = display; self.isYou = isYou
        self.conversations = conversations; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }
}

public struct ReviewMeeting: Sendable {
    public var id: String
    public var title: String
    public var start: Date
    /// Attendees already resolved to roster labels by the source, because
    /// matching an email address to a person is a thing each platform does its
    /// own way and neither of them should do here.
    public var people: [String]
    public init(id: String, title: String, start: Date, people: [String]) {
        self.id = id; self.title = title; self.start = start; self.people = people
    }
}

/// Where a review's facts come from. One conformance per platform.
public protocol ReviewSource {
    /// The owner's own display name, for `ContextPresentation.addressed`.
    var you: String? { get }
    /// Whether the app offers Ask at all, which decides the closing card.
    var asksEnabled: Bool { get }

    func conversations(from: Date, to: Date) -> [ReviewConversation]
    func notes(from: Date, to: Date) -> [ReviewNoteRef]
    func chats(from: Date, to: Date) -> [String]
    /// Everybody the library knows, with their whole history, not the window's.
    func roster() -> [ReviewPerson]
    /// Current claims about one person. Historical and retracted ones included:
    /// the builder decides which card they belong on.
    func claims(about person: String) -> [ReviewClaim]
    /// Recordings nothing can be read from until somebody names a speaker.
    func needingNames() -> [ReviewConversation]
    func upcoming(limit: Int) -> [ReviewMeeting]
}

public extension ReviewSource {
    func upcoming(limit: Int) -> [ReviewMeeting] { [] }
}

// MARK: - The builder

public struct Review: Sendable {
    public var from: Date
    public var to: Date
    public var scope: ReviewScope
    public var cards: [ReviewCard] = []
    /// What appeared in this window, for a caller that reveals it.
    public var appeared: [ReviewRef] = []

    /// How long a person has to be unheard from before a review mentions it.
    ///
    /// Sixty days rather than thirty: a monthly catch-up is a relationship in
    /// good standing, and saying so every fifth week is a nag. A choice rather
    /// than a measurement, which this comment exists to admit.
    public static let outOfTouchDays = 60.0
    /// One conversation with a stranger is not a lapsed relationship, and a
    /// library is full of those.
    public static let outOfTouchMinimum = 2
    /// The windows a deck offers, shortest first.
    public static let ranges: [Int] = [7, 30, 90, 365]

    public static func build(scope: ReviewScope, from: Date, to: Date,
                             source: ReviewSource) -> Review {
        scope.person.map { person($0, from: from, to: to, source: source) }
            ?? library(from: from, to: to, source: source)
    }

    // MARK: The library's own week

    private static func library(from: Date, to: Date, source: ReviewSource) -> Review {
        var review = Review(from: from, to: to, scope: .library)
        let you = source.you
        let roster = source.roster()
        let conversations = source.conversations(from: from, to: to)
        let notes = source.notes(from: from, to: to)
        let chats = source.chats(from: from, to: to)

        review.appeared = conversations.map { ReviewRef(kind: ReviewRef.recording, key: $0.id) }
            + notes.map { ReviewRef(kind: ReviewRef.note, key: $0.slug) }
            + chats.map { ReviewRef(kind: ReviewRef.chat, key: $0) }

        let seconds = conversations.reduce(0.0) { $0 + $1.seconds }
        let people = Set(conversations.flatMap(\.speakers)).subtracting(roster.filter(\.isYou).map(\.label))
        review.cards.append(ReviewCard(
            id: "week", kind: .week, title: "Your week",
            detail: [count(conversations.count, "conversation"), length(seconds),
                     count(people.count, "person", "people"),
                     notes.isEmpty ? "" : count(notes.count, "note")]
                .filter { !$0.isEmpty }.joined(separator: " · "),
            stats: [
                ReviewStat(value: "\(conversations.count)",
                           label: conversations.count == 1 ? "conversation" : "conversations",
                           kind: ReviewRef.recording),
                ReviewStat(value: length(seconds), label: "recorded", kind: ReviewRef.recording),
                ReviewStat(value: "\(people.count)",
                           label: people.count == 1 ? "person" : "people", kind: ReviewRef.person),
            ] + (notes.isEmpty ? [] : [
                ReviewStat(value: "\(notes.count)",
                           label: notes.count == 1 ? "note" : "notes", kind: ReviewRef.note),
            ]),
            stars: review.appeared))

        // Somebody is new when everything ever recorded of them is in this
        // window, which is the only claim on this page about the past.
        let arrived = roster.filter { person in
            guard !person.isYou, person.conversations > 0, let first = person.firstSeen else { return false }
            return first >= from && first <= to
        }
        if !arrived.isEmpty {
            review.cards.append(ReviewCard(
                id: "new-people", kind: .newPeople,
                title: arrived.count == 1 ? "Somebody new" : "\(arrived.count) new people",
                detail: "First recorded this week.",
                items: arrived.map {
                    ReviewItem(id: $0.label, text: $0.display,
                               ref: ReviewRef(kind: ReviewRef.person, key: $0.label))
                },
                // "Leave out", never "Don't remember": the action decides what
                // Listen keeps, and the words it had made it a judgement about
                // the person.
                verbs: ["Open", "Leave out"],
                stars: arrived.map { ReviewRef(kind: ReviewRef.person, key: $0.label) }))
        }

        var learned: [String: [ReviewItem]] = [:], changed: [ReviewItem] = [], owed: [ReviewItem] = []
        for person in roster where !person.isYou {
            for claim in source.claims(about: person.label) where inWindow(claim.date, from, to) {
                let line = item(claim, you: you)
                if claim.ended || ["historical", "retracted"].contains(claim.status) {
                    changed.append(line)
                } else if isPromise(claim) {
                    owed.append(line)
                } else {
                    learned[person.label, default: []].append(line)
                }
            }
        }
        for person in roster where !person.isYou {
            guard let items = learned[person.label], !items.isEmpty else { continue }
            review.cards.append(ReviewCard(
                id: "learned:" + person.label, kind: .learned,
                title: "What Listen learned about " + person.display,
                detail: count(items.count, "new detail"),
                items: Array(newestFirst(items).prefix(3)),
                verbs: ["Accept", "Correct", "Hide"],
                stars: [ReviewRef(kind: ReviewRef.person, key: person.label)]))
        }
        if !changed.isEmpty {
            review.cards.append(ReviewCard(
                id: "changed", kind: .changed, title: "Something changed",
                detail: "A newer conversation replaced what was recorded before.",
                items: Array(newestFirst(changed).prefix(3)),
                verbs: ["Confirm", "That's wrong"]))
        }

        let waiting = source.needingNames()
        if !waiting.isEmpty {
            review.cards.append(ReviewCard(
                id: "loose-ends", kind: .looseEnds,
                title: count(waiting.count, "recording") + (waiting.count == 1 ? " needs" : " need") + " a name",
                detail: "Nothing can be read from a conversation until somebody says who is talking.",
                items: Array(waiting.sorted { $0.date > $1.date }.prefix(3).map {
                    ReviewItem(id: $0.id, text: $0.title,
                               ref: ReviewRef(kind: ReviewRef.recording, key: $0.id),
                               date: stamp($0.date))
                }),
                verbs: ["Name the speakers"],
                stars: waiting.map { ReviewRef(kind: ReviewRef.recording, key: $0.id) }))
        }

        // The one retrospective card that is really about the future: a promise
        // is a thing still owed, and it is usually why this page was opened.
        if !owed.isEmpty {
            review.cards.append(ReviewCard(
                id: "commitments", kind: .commitments,
                title: owed.count == 1 ? "One thing was promised" : "\(owed.count) things were promised",
                detail: "Said out loud in a conversation, by you or to you.",
                items: Array(newestFirst(owed).prefix(4)),
                verbs: ["Open", "Done"]))
        }

        let stale = roster.filter { person in
            guard !person.isYou, person.conversations >= outOfTouchMinimum,
                  let last = person.lastSeen else { return false }
            return to.timeIntervalSince(last) > outOfTouchDays * 86_400
        }.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        if let first = stale.first {
            let days = Int(to.timeIntervalSince(first.lastSeen ?? to) / 86_400)
            review.cards.append(ReviewCard(
                id: "out-of-touch:" + first.label, kind: .outOfTouch,
                title: "You haven't spoken to " + first.display + " in a while",
                detail: "\(days) days, over \(count(first.conversations, "conversation")).",
                items: stale.prefix(3).map {
                    ReviewItem(id: $0.label, text: $0.display,
                               ref: ReviewRef(kind: ReviewRef.person, key: $0.label))
                },
                verbs: ["Open", "Snooze"],
                stars: stale.prefix(3).map { ReviewRef(kind: ReviewRef.person, key: $0.label) }))
        }

        review.cards.append(contentsOf: ahead(source: source, roster: roster, you: you))
        if source.asksEnabled {
            review.cards.append(ReviewCard(
                id: "ask", kind: .ask, title: "Ask about your week",
                detail: conversations.isEmpty ? "Ask anything about your library."
                                              : "What did I say I would do this week?",
                verbs: ["Ask"]))
        }
        return review
    }

    // MARK: One person, over a window

    private static func person(_ label: String, from: Date, to: Date,
                               source: ReviewSource) -> Review {
        var review = Review(from: from, to: to, scope: .person(label))
        let you = source.you
        let roster = source.roster()
        let them = roster.first { $0.label == label }
        let display = them?.display ?? label
        let theirs = source.conversations(from: from, to: to).filter { $0.speakers.contains(label) }
        let ids = Set(theirs.map(\.id))
        let notes = source.notes(from: from, to: to).filter { !$0.recordings.filter(ids.contains).isEmpty }
        review.appeared = theirs.map { ReviewRef(kind: ReviewRef.recording, key: $0.id) }
            + notes.map { ReviewRef(kind: ReviewRef.note, key: $0.slug) }

        let seconds = theirs.reduce(0.0) { $0 + $1.seconds }
        let days = max(1, Int(to.timeIntervalSince(from) / 86_400))
        var detail = theirs.isEmpty ? "Nothing recorded in this window."
            : [count(theirs.count, "conversation"), length(seconds)]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        if theirs.isEmpty, let last = them?.lastSeen {
            let ago = Int(to.timeIntervalSince(last) / 86_400)
            detail += " Last spoken to \(ago) day\(ago == 1 ? "" : "s") ago."
        }
        review.cards.append(ReviewCard(
            id: "person", kind: .week,
            title: display + ", the last \(days) day\(days == 1 ? "" : "s")",
            detail: detail,
            stats: theirs.isEmpty ? [] : [
                ReviewStat(value: "\(theirs.count)",
                           label: theirs.count == 1 ? "conversation" : "conversations",
                           kind: ReviewRef.recording),
                ReviewStat(value: length(seconds), label: "together", kind: ReviewRef.recording),
            ],
            stars: [ReviewRef(kind: ReviewRef.person, key: label)] + review.appeared))

        var learned: [ReviewItem] = [], changed: [ReviewItem] = [], owed: [ReviewItem] = []
        for claim in source.claims(about: label) where inWindow(claim.date, from, to) {
            let line = item(claim, you: you)
            if claim.ended || ["historical", "retracted"].contains(claim.status) { changed.append(line) }
            else if isPromise(claim) { owed.append(line) }
            else { learned.append(line) }
        }
        if !owed.isEmpty {
            review.cards.append(ReviewCard(
                id: "commitments", kind: .commitments,
                title: owed.count == 1 ? "One thing was promised" : "\(owed.count) things were promised",
                detail: "Between you and " + display + ", in their own words.",
                items: Array(newestFirst(owed).prefix(4)),
                verbs: ["Open", "Done"],
                stars: [ReviewRef(kind: ReviewRef.person, key: label)]))
        }
        if !learned.isEmpty {
            review.cards.append(ReviewCard(
                id: "learned", kind: .learned,
                title: "What Listen learned about " + display,
                detail: count(learned.count, "new detail"),
                items: Array(newestFirst(learned).prefix(4)),
                verbs: ["Accept", "Correct", "Hide"],
                stars: [ReviewRef(kind: ReviewRef.person, key: label)]))
        }
        if !changed.isEmpty {
            review.cards.append(ReviewCard(
                id: "changed", kind: .changed, title: "Something changed",
                detail: "A newer conversation replaced what was recorded before.",
                items: Array(newestFirst(changed).prefix(4)),
                verbs: ["Confirm", "That's wrong"],
                stars: [ReviewRef(kind: ReviewRef.person, key: label)]))
        }
        if !theirs.isEmpty {
            review.cards.append(ReviewCard(
                id: "meetings", kind: .looseEnds,
                title: count(theirs.count, "conversation") + " with " + display,
                detail: "In this window, newest first.",
                items: theirs.sorted { $0.date > $1.date }.prefix(5).map {
                    ReviewItem(id: $0.id, text: $0.title,
                               ref: ReviewRef(kind: ReviewRef.recording, key: $0.id),
                               date: stamp($0.date))
                },
                verbs: ["Open"],
                stars: theirs.map { ReviewRef(kind: ReviewRef.recording, key: $0.id) }))
        }
        review.cards.append(contentsOf: ahead(source: source, roster: roster, you: you, only: label))
        if source.asksEnabled {
            review.cards.append(ReviewCard(
                id: "ask", kind: .ask, title: "Ask about " + display,
                detail: "What has " + display + " asked me for?",
                verbs: ["Ask"],
                stars: [ReviewRef(kind: ReviewRef.person, key: label)]))
        }
        return review
    }

    // MARK: What is coming

    /// **The card that makes this more than a diary.** Everything else is about
    /// what happened; this is the same memory pointed the other way, at the next
    /// conversation rather than the last one. A source with no calendar returns
    /// nothing and the card simply does not appear.
    private static func ahead(source: ReviewSource, roster: [ReviewPerson],
                              you: String?, only: String? = nil) -> [ReviewCard] {
        let meetings = source.upcoming(limit: 3)
            .filter { only == nil || $0.people.contains(only!) }
        guard !meetings.isEmpty else { return [] }
        let items = meetings.map { meeting -> ReviewItem in
            // What you already know about whoever is coming, which is the only
            // reason to put a calendar entry on this page at all.
            let known = meeting.people.compactMap { label -> String? in
                source.claims(about: label)
                    .filter { !["historical", "retracted"].contains($0.status) }
                    .sorted { $0.date > $1.date }
                    .first.map { ContextPresentation.addressed($0.text, you: you) }
            }
            return ReviewItem(id: meeting.id, text: meeting.title, quote: known.first ?? "",
                              ref: meeting.people.first.map { ReviewRef(kind: ReviewRef.person, key: $0) },
                              date: when(meeting.start))
        }
        return [ReviewCard(
            id: "upcoming", kind: .upcoming,
            title: items.count == 1 ? "Before your next conversation"
                                    : "Before your next \(items.count) conversations",
            detail: "What you already know about who you are seeing.",
            items: items, verbs: ["Open"],
            stars: items.compactMap(\.ref))]
    }

    // MARK: Shared shaping

    /// A promise is a commitment or a decision, and it earns its own card
    /// because buried in a list of details it is the thing you miss.
    private static func isPromise(_ claim: ReviewClaim) -> Bool {
        ["commitment", "decision"].contains(claim.attribute)
    }

    private static func item(_ claim: ReviewClaim, you: String?) -> ReviewItem {
        ReviewItem(id: claim.id,
                   text: ContextPresentation.addressed(claim.text, you: you),
                   quote: claim.quote,
                   ref: claim.source.hasPrefix("note:")
                        ? ReviewRef(kind: ReviewRef.note, key: String(claim.source.dropFirst(5)))
                        : ReviewRef(kind: ReviewRef.recording,
                                    key: claim.source.hasPrefix("rec:")
                                        ? String(claim.source.dropFirst(4)) : claim.source),
                   date: claim.date)
    }

    private static func newestFirst(_ items: [ReviewItem]) -> [ReviewItem] {
        items.sorted { $0.date > $1.date }
    }

    private static func inWindow(_ stamp: String, _ from: Date, _ to: Date) -> Bool {
        guard let date = instant(stamp) else { return false }
        return date >= from && date <= to
    }

    /// Both shapes the library writes: whole seconds, and the fractional ones
    /// `ContextOverride` stamps.
    public static func instant(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// "Tomorrow 08:30", or a weekday further out.
    private static func when(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        if Calendar.current.isDateInToday(date) { formatter.dateFormat = "'Today' HH:mm" }
        else if Calendar.current.isDateInTomorrow(date) { formatter.dateFormat = "'Tomorrow' HH:mm" }
        else { formatter.dateFormat = "EEEE HH:mm" }
        return formatter.string(from: date)
    }

    /// The same shape `Recording.length` produces, because the two appear on one
    /// screen and a page that formats an hour two ways is a page that looks
    /// wrong without anybody being able to say why.
    static func length(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        guard total > 0 else { return "" }
        return total >= 3600 ? String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) " + (number == 1 ? singular : (plural ?? singular + "s"))
    }
}
