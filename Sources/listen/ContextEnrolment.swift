import Foundation
import ListenKit

/// Who the background sweep is allowed to read about.
///
/// Memory used to be off for everybody until somebody opened a person's page,
/// pressed Create Summary, worked through a sheet of source checkboxes and
/// ticked "Keep up to date for this person". Measured on the real library on
/// 11 September 2026: 34 named people, **one** of them enrolled, 321 pending
/// parts and 18 processed. The one enrolled person had nothing left to read,
/// so the sweep's entire permitted workload was finished and the queue was
/// never going to move again. The pipeline was not broken; nothing had ever
/// asked.
enum ContextEnrolment {
    /// Give everybody the library can speak for an explicit consent register.
    ///
    /// **An explicit register each, never a changed default.**
    /// `MemoryPreferences.Policy.automatic` reads `text == "true"`, so an
    /// absent key means off, and three separate things lean on that: the
    /// equal-clock merge rule makes `"false"` win for `person:*:automatic`
    /// keys, so a decline cannot lose a tie to an accept; `ContextCLI.Coverage`
    /// decides whether to print "on" by looking for a literal `"true"` and
    /// would report a default-on library as off; and a second Mac that has
    /// never heard of somebody would infer consent for them rather than wait
    /// to be told. Writing the registers keeps all three honest, and costs one
    /// line per person in a file that already carries one per opted-in person.
    ///
    /// **Only somebody with no register at all is touched.** A person turned
    /// off by hand stays off, here and on every device the register reaches.
    ///
    /// The candidates are the people an extractable source can actually speak
    /// for, which is `ContextSource.names(_:)` rather than `people`: enrolling
    /// somebody because another person said their first name once would queue
    /// work that has nothing of theirs in it.
    @discardableResult
    static func sync(_ sources: [ContextSource], model: MemoryPreferences.Model?) -> Int {
        let root = Library.root
        guard MemoryPreferences.enrolsNewPeople(root: root), let model else { return 0 }
        let values = (try? MemoryPreferences.read(root: root)) ?? [:]
        var enrolled = 0
        for label in candidates(sources) {
            let id = MemoryPreferences.personID(label, root: root)
            guard values["person:\(id):automatic"] == nil else { continue }
            // One failure is one person, not the end of the pass: `automatic`
            // throws when the model it is handed has no executor, and that is
            // a reason to leave this person alone rather than to stop
            // enrolling everybody after them in the sort order.
            guard (try? MemoryPreferences.automatic(true, person: id, model: model, root: root)) != nil else { continue }
            enrolled += 1
        }
        return enrolled
    }

    /// Everybody at least one extractable source speaks for.
    static func candidates(_ sources: [ContextSource]) -> [String] {
        Set(sources.filter(\.extractable).flatMap { $0.speakers ?? $0.people }).sorted()
    }

    /// Everybody in the library and what memory knows about them.
    ///
    /// One pass, off the main thread, so the settings roster and anything else
    /// that wants to show this reads the same numbers. Per person it is a
    /// SQLite read rather than a transcript one, because `personBatchCounts`
    /// was written by the index pass; the cost here is `Recording.all()` and
    /// the turns each person is derived from, which is why callers are expected
    /// to be a screen somebody opened rather than a timer.
    struct Roster: Sendable {
        struct Row: Sendable, Identifiable {
            var id: String
            var label: String
            var display: String
            /// "7 recordings · 3h 12m", or "no recordings yet".
            var summary: String
            /// `nil` when nobody has ever answered for this person.
            var automatic: Bool?
            var pending: Int
            var failed: Int
            var claims: Int
            var isYou: Bool
        }
        var rows: [Row] = []
        /// Recordings nothing can be read from until somebody names a speaker.
        /// A library fact rather than a person one: the people in them are, by
        /// definition, not on the roster yet.
        var waitingForNames = 0
        var enrolsNewPeople = false
        var enrolled: Int { rows.filter { $0.automatic == true }.count }
        var backlog: Int { rows.filter { $0.automatic == true }.reduce(0) { $0 + $1.pending } }
    }

    static func roster() -> Roster {
        let root = Library.root
        let library = Recording.all()
        let values = (try? MemoryPreferences.read(root: root)) ?? [:]
        let document = try? PeopleMemory.load()
        var result = Roster(enrolsNewPeople: MemoryPreferences.enrolsNewPeople(root: root))
        for person in People.roster(in: library) {
            let id = MemoryPreferences.personID(person.label, root: root)
            let memory = document.flatMap { try? PeopleMemory.person(person.label, document: $0) }
            let current = ((memory?.facts ?? []) + (memory?.relations ?? []))
                .filter { !["historical", "retracted"].contains($0.status) }
            result.rows.append(Roster.Row(
                id: id, label: person.label, display: person.display, summary: person.summary,
                automatic: values["person:\(id):automatic"].map { $0.text == "true" },
                pending: memory?.pending ?? 0, failed: memory?.failed ?? 0,
                claims: current.count, isYou: person.isYou))
        }
        result.waitingForNames = needsNames(library).count
        return result
    }

    /// Recordings nothing can be read from until somebody names a speaker.
    ///
    /// **One definition, because two counts of one idea that disagree is a
    /// disagreement nobody can reproduce from either side.** This is the rule
    /// `ContextSources.all` applies when it decides a recording is not
    /// `extractable`, including the part that is easy to leave out: a
    /// transcript with turns but no words in them produces no passages, so it
    /// is not a recording somebody can fix by naming a speaker. Leaving that
    /// out is what made the review say four and `listen context status` say
    /// two about the same library.
    static func needsNames(_ library: [Recording]) -> [Recording] {
        library.filter { recording in
            guard recording.hasTranscript,
                  recording.metadata.state != "transcribing",
                  recording.metadata.state != "pending" else { return false }
            let turns = recording.storedTurns
            guard turns.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return false }
            return !turns.contains { !VoiceBank.isPlaceholder($0.speaker) }
        }
    }

    /// When each person was last given a turn, by entity id, as a Unix time.
    ///
    /// **In the library's own `context` directory, not in the settings file
    /// and not in defaults.** Whose turn it is next is this Mac's queue rather
    /// than a fact about the library, so it must not ride
    /// `people-memory-settings.json`, which is republished to CloudKit on every
    /// change: a key per person per pass would send it every thirty seconds for
    /// a reader that does not exist. `context/` is already the device-local
    /// half, which also means `LISTEN_LIBRARY` scopes it, so a scratch library
    /// cannot reorder the real one's queue. Two Macs scheduling independently
    /// is the behaviour you want anyway; they have different backlogs and may
    /// have different models.
    static func served() -> [String: Double] {
        ((try? ContextFiles.read([String: Double].self, "schedule.json")) ?? [:]) ?? [:]
    }
    static func markServed(_ id: String, in served: [String: Double]) {
        var next = served
        next[id] = Date().timeIntervalSince1970
        try? ContextFiles.write(next, "schedule.json")
    }

    /// The order the sweep should offer people in.
    ///
    /// **Least recently served first.** The sweep used to walk the labels
    /// alphabetically and stop at the first person with work, which is
    /// harmless while one person is enrolled and a starvation bug the moment
    /// the roster is: with 34 enrolled and a 40 request daily budget, the
    /// alphabetically first person who still has anything left spends the
    /// whole budget every day for as many days as their backlog lasts, and
    /// nobody after them is ever read. Nothing recorded whose turn it had
    /// been, so nothing could have noticed.
    ///
    /// On a cold start nobody has a stamp, so the tie-break carries the whole
    /// order: you first, because your own card is the one the feature is named
    /// after and it was the emptiest of all, then whoever there is most to read
    /// about, then alphabetically so a run is reproducible.
    static func order(_ labels: Set<String>, ids: [String: String],
                      weight: [String: Int], served: [String: Double]) -> [String] {
        labels.sorted { a, b in
            let x = served[ids[a] ?? a] ?? 0, y = served[ids[b] ?? b] ?? 0
            if x != y { return x < y }
            if (a == SpeakerName.you) != (b == SpeakerName.you) { return a == SpeakerName.you }
            if weight[a] != weight[b] { return (weight[a] ?? 0) > (weight[b] ?? 0) }
            return a < b
        }
    }
}
