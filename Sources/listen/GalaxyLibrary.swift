import Foundation

/// The library half of the galaxy: turning what is on disk into a snapshot.
///
/// Split from `Galaxy.swift` so that file depends on nothing but Foundation and
/// simd. That is not tidiness: it is what lets `verify_galaxy.sh` compile the
/// model, the layout and the camera on their own and assert things about them,
/// which is the only way a claim like "dragging right turns the scene right"
/// gets a test rather than a comment. See `tools/galaxy_geometry.swift`.
extension Galaxy {
    /// The whole library as a snapshot.
    ///
    /// **Call this off the main thread.** `Recording.all()` walks the library
    /// directory and `People.all` reads every transcript's speakers, which on a
    /// real library is tens of milliseconds and on a large one is not.
    static func build(recordings: [Recording]? = nil, maximumNodes: Int = 1200) -> Snapshot {
        let library = recordings ?? Recording.all()
        let people = People.all(in: library)
        let notes = Notes.all()
        let chats = Settings.askEnabled ? Chat.all() : []

        var nodes: [Node] = []
        var edges: [Edge] = []
        let recordingIDs = Set(library.map(\.id))

        for recording in library {
            nodes.append(Node(id: recordingID(recording.id), kind: Node.recording,
                              title: recording.displayTitle, detail: recordingDetail(recording)))
        }
        for person in people {
            nodes.append(Node(id: personID(person.label), kind: Node.person,
                              title: person.display, detail: person.summary))
            // Speaking in a transcript is the relationship, and it is the one
            // fact about a person this library actually holds.
            for recording in person.recordings where recordingIDs.contains(recording.id) {
                edges.append(Edge(id: "speaks:\(person.label):\(recording.id)",
                                  source: personID(person.label),
                                  target: recordingID(recording.id),
                                  label: "Speaks in", reverse: "Speaker"))
            }
        }
        for note in notes {
            nodes.append(Node(id: noteID(note.slug), kind: Node.note,
                              title: note.title, detail: noteDetail(note)))
            for id in note.recordings where recordingIDs.contains(id) {
                edges.append(Edge(id: "note-about:\(note.slug):\(id)",
                                  source: noteID(note.slug),
                                  target: recordingID(id),
                                  label: "Written about", reverse: "Written up in"))
            }
        }
        let peopleByLabel = Dictionary(people.map { ($0.label, $0) }, uniquingKeysWith: { a, _ in a })
        for chat in chats {
            guard let id = chat.id, !id.isEmpty else { continue }
            nodes.append(Node(id: chatID(id), kind: Node.chat,
                              title: chat.displayTitle, detail: chatDetail(chat)))
            for recording in chat.sources where recordingIDs.contains(recording) {
                edges.append(Edge(id: "asked-about:\(id):\(recording)",
                                  source: chatID(id),
                                  target: recordingID(recording),
                                  label: "Asked about", reverse: "Asked about in"))
            }
            // Only a person the library already knows. A conversation can name
            // somebody who has since been renamed away, and drawing a star for
            // that name would invent a person out of a stale string.
            if let person = chat.person, peopleByLabel[person] != nil {
                edges.append(Edge(id: "asked-about-person:\(id):\(person)",
                                  source: chatID(id),
                                  target: personID(person),
                                  label: "Asked about", reverse: "Asked about in"))
            }
        }
        return scene(nodes: nodes, edges: edges, maximumNodes: maximumNodes)
    }

    private static func recordingDetail(_ recording: Recording) -> String {
        var parts: [String] = []
        if let date = recording.date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append(formatter.string(from: date))
        }
        let length = Recording.length(recording.metadata.duration)
        if !length.isEmpty { parts.append(length) }
        return parts.joined(separator: " · ")
    }

    private static func noteDetail(_ note: Note) -> String {
        let about = note.recordings.count
        let meetings = about == 0 ? "not about a recording"
            : about == 1 ? "about 1 recording" : "about \(about) recordings"
        return note.tags.isEmpty ? meetings : meetings + " · " + note.tags.joined(separator: ", ")
    }

    private static func chatDetail(_ chat: Chat) -> String {
        let turns = chat.turns.filter { $0.who == Chat.you }.count
        return turns == 1 ? "1 question" : "\(turns) questions"
    }
}

extension Settings {
    private static let galaxyEnabledKey = "galaxyEnabled"

    /// Whether the galaxy is offered at all.
    ///
    /// **On by default, unlike `askEnabled`, and the difference is what the
    /// two ask of you.** Ask is off until somebody turns it on because it
    /// sends your library to a model you have to choose and pay for; this
    /// draws what is already on this disk, reaches no network, and consents to
    /// nothing. A feature with no cost to the user should not be hidden behind
    /// a switch nobody knows to look for.
    ///
    /// The switch exists all the same, because it does have a cost to the Mac:
    /// an open galaxy runs the GPU at 30 frames a second, and somebody
    /// transcribing a two-hour meeting on a laptop is entitled to say no. It
    /// is read through `object(forKey:)` rather than `bool(forKey:)` for the
    /// reason `dictationEnabled` is: a key that was never written cannot
    /// otherwise be told from one deliberately turned off.
    static var galaxyEnabled: Bool {
        get { forcedBool(galaxyEnabledKey) ?? (defaults.object(forKey: galaxyEnabledKey) as? Bool ?? true) }
        set { defaults.set(newValue, forKey: galaxyEnabledKey) }
    }
}
