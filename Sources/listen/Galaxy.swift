import Foundation
import simd

/// The library as a set of concentric shells around this Mac.
///
/// ## What the picture claims, and what it deliberately does not
///
/// **The centre is this Listen instance, not you.** It is where the view is
/// drawn from, an anchor for the eye, and it has no edges to anything: a line
/// from the centre to every recording would be a claim that this Mac stands in
/// some relation to each of them, and the only true version of that sentence is
/// "they are in the library", which the picture already says by drawing them.
///
/// **Distance from the centre is the kind of a thing and nothing else.** Not
/// importance, not recency, not how much you talk to somebody. A shell is a
/// category, and the four are the four kinds of thing this library holds:
/// people, notes, conversations, recordings. Encoding importance in radius was
/// the obvious next idea and it is the reason this note exists: there is no
/// measure of importance in the library that is not a guess, and a guess drawn
/// as a distance reads as a fact.
///
/// **Every edge is something already written down.** A note names its
/// recordings, a conversation names the meetings it was asked about, a person
/// is a speaker in a transcript. Nothing here infers a relationship from
/// similarity, co-occurrence or timing, so a line between two stars is always
/// a row somebody can go and read.
///
/// ## Where a star sits
///
/// The angle is seeded from the id, so the same recording is in the same place
/// today as yesterday, and stays there when the library grows. Then the real
/// edges pull their endpoints together across the surface of the shell and
/// crowding pushes neighbours apart, for a fixed number of passes, once per
/// snapshot. It is not a live simulation: a layout that keeps moving is a
/// layout nobody can point at.
enum Galaxy {

    /// Exact radii, inside out. Read `GalaxyPane`'s legend beside them: these
    /// four numbers are the only thing that says which shell is which.
    static func shellRadius(kind: String) -> Float? {
        switch kind {
        case Node.person: return 5
        case Node.note: return 9
        case Node.chat: return 13
        case Node.recording: return 17
        default: return nil
        }
    }

    /// The presentation-only origin. Not a library object, and never an edge
    /// endpoint.
    static let deviceID = "view:this-mac"

    struct Node: Equatable {
        static let person = "person", note = "note", chat = "chat"
        static let recording = "recording", device = "device"

        /// Prefixed with its kind, and the suffix is the library's own
        /// identifier, so `GalaxyPane` can hand it straight to `LibraryWindow`
        /// rather than keeping a second map from stars to things.
        var id: String
        var kind: String
        var title: String
        /// One line under the title in the inspector. Never drawn on the star.
        var detail: String = ""
        var position: SIMD3<Float> = .zero
    }

    struct Edge: Equatable {
        var id: String
        var source: String
        var target: String
        /// What the inspector calls it, in the library's own words.
        var label: String
    }

    struct Snapshot: Equatable {
        var nodes: [Node] = []
        var edges: [Edge] = []
        /// What the inspector says the picture is, including anything left out.
        var label: String = ""

        func node(_ id: String) -> Node? { nodes.first { $0.id == id } }
    }

    // -----------------------------------------------------------------------
    // Identifiers
    // -----------------------------------------------------------------------

    static func recordingID(_ id: String) -> String { "recording:" + id }
    static func noteID(_ slug: String) -> String { "note:" + slug }
    static func chatID(_ id: String) -> String { "chat:" + id }
    /// A person is a name string and that is the whole identity model in this
    /// app, so it is the name that goes in the id. See `.agents/notes/speakers.md`.
    static func personID(_ label: String) -> String { "person:" + label }

    /// The library identifier back out of a star's id, or nil for the centre.
    static func subject(of id: String) -> (kind: String, key: String)? {
        guard id != deviceID, let separator = id.firstIndex(of: ":") else { return nil }
        let kind = String(id[id.startIndex..<separator])
        let key = String(id[id.index(after: separator)...])
        guard !key.isEmpty, [Node.person, Node.note, Node.chat, Node.recording].contains(kind) else { return nil }
        return (kind, key)
    }

    // -----------------------------------------------------------------------
    // Building it out of the library
    // -----------------------------------------------------------------------

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
                                  label: "Speaks in"))
            }
        }
        for note in notes {
            nodes.append(Node(id: noteID(note.slug), kind: Node.note,
                              title: note.title, detail: noteDetail(note)))
            for id in note.recordings where recordingIDs.contains(id) {
                edges.append(Edge(id: "note-about:\(note.slug):\(id)",
                                  source: noteID(note.slug),
                                  target: recordingID(id),
                                  label: "Written about"))
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
                                  label: "Asked about"))
            }
            // Only a person the library already knows. A conversation can name
            // somebody who has since been renamed away, and drawing a star for
            // that name would invent a person out of a stale string.
            if let person = chat.person, peopleByLabel[person] != nil {
                edges.append(Edge(id: "asked-about-person:\(id):\(person)",
                                  source: chatID(id),
                                  target: personID(person),
                                  label: "Asked about"))
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

    /// A short, stable fingerprint of where everything ended up.
    ///
    /// For `listen galaxy --json`, so a script can assert that two reads of the
    /// same library put every star in the same place. It carries no id and no
    /// title: a list of positions with names beside them would be a list of
    /// every recording, note and person in the library.
    static func digest(_ snapshot: Snapshot) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        func mix(_ text: String) {
            for byte in text.utf8 { value ^= UInt64(byte); value &*= 1_099_511_628_211 }
        }
        for node in snapshot.nodes.sorted(by: { $0.id < $1.id }) {
            mix(node.id)
            // Rounded, because the last bit of a float sum is not a position
            // and a layout that has not moved must not look as though it has.
            for axis in [node.position.x, node.position.y, node.position.z] {
                mix(String(format: "%.3f", axis))
            }
        }
        return String(format: "%016llx", value)
    }

    // -----------------------------------------------------------------------
    // The presentation
    // -----------------------------------------------------------------------

    /// Sorts, de-duplicates, caps, adds the centre and lays the shells out.
    ///
    /// The cap is a presentation limit and it is disclosed in the label rather
    /// than applied quietly: a picture that silently stops at 1200 stars is a
    /// picture that lies about a library of 3000.
    static func scene(nodes input: [Node], edges: [Edge], deviceTitle: String = "Listen · This Mac",
                      maximumNodes: Int = 1200) -> Snapshot {
        var seen: Set<String> = []
        // Sorted by kind and then id, so the picture is the same every launch.
        // The kind is first for a second reason: alphabetically it runs chat,
        // note, person, recording, so the cap below cuts recordings and keeps
        // everything else. That is the right way round rather than an accident
        // worth leaving unexplained. A library has far more recordings than it
        // has people, notes and conversations put together, so cutting the
        // largest kind is what keeps the shape of the picture; cutting a
        // proportional slice of each would empty the three shells that carry
        // the structure.
        let sorted = input
            .filter { $0.id != deviceID && shellRadius(kind: $0.kind) != nil }
            .sorted { ($0.kind, $0.id) < ($1.kind, $1.id) }
            .filter { seen.insert($0.id).inserted }
        let capacity = max(0, maximumNodes - 1)
        let visible = Array(sorted.prefix(capacity))
        let visibleIDs = Set(visible.map(\.id))
        var edgeIDs: Set<String> = []
        let kept = edges
            .sorted { $0.id < $1.id }
            .filter { edge in
                edge.source != edge.target && edge.source != deviceID && edge.target != deviceID
                    && visibleIDs.contains(edge.source) && visibleIDs.contains(edge.target)
                    && edgeIDs.insert(edge.id).inserted
            }
        let omitted = sorted.count - visible.count
        let device = Node(id: deviceID, kind: Node.device, title: deviceTitle, position: .zero)
        var label = "\(visible.count) of your library, on four shells."
        if omitted > 0 {
            label += " \(omitted) \(omitted == 1 ? "star is" : "stars are") not drawn:"
                + " the picture stops at \(maximumNodes)."
        }
        return relax(Snapshot(nodes: (visible + [device]).sorted { $0.id < $1.id },
                              edges: kept, label: label))
    }

    /// A bounded, one-shot relaxation across the shells.
    ///
    /// Every force acts along the surface: the radius a star was given by its
    /// kind is restored exactly at the end of each pass, so nothing can be
    /// pushed off its shell and the four bands stay readable no matter how
    /// crowded one of them is.
    ///
    /// Repulsion is between unit directions rather than positions, so it acts
    /// across shells as well as within one. That is deliberate: two stars on
    /// the same ray at different radii overlap from most angles, and letting
    /// the outer one slide aside is what stops the picture growing spokes.
    static func relax(_ snapshot: Snapshot, iterations: Int = 18) -> Snapshot {
        var nodes = snapshot.nodes.sorted { $0.id < $1.id }
        var indices: [String: Int] = [:]
        var anchors = Array(repeating: SIMD3<Float>.zero, count: nodes.count)
        for index in nodes.indices {
            guard let radius = shellRadius(kind: nodes[index].kind) else {
                nodes[index].position = .zero
                continue
            }
            let direction = seedDirection(id: nodes[index].id)
            anchors[index] = direction
            nodes[index].position = direction * radius
            indices[nodes[index].id] = index
        }
        let edges = snapshot.edges.sorted { $0.id < $1.id }
        let passes = max(0, min(iterations, 24))
        guard passes > 0 else { return Snapshot(nodes: nodes, edges: edges, label: snapshot.label) }

        // How many edges each star has, computed once. See the loop below for
        // why the number is needed rather than just the edges.
        var degree = Array(repeating: 0, count: nodes.count)
        for edge in edges {
            guard let a = indices[edge.source], let b = indices[edge.target], a != b else { continue }
            degree[a] += 1
            degree[b] += 1
        }

        for _ in 0..<passes {
            var pull = Array(repeating: SIMD3<Float>.zero, count: nodes.count)
            var delta = Array(repeating: SIMD3<Float>.zero, count: nodes.count)
            for edge in edges {
                guard let a = indices[edge.source], let b = indices[edge.target], a != b else { continue }
                let da = unit(nodes[a].position), db = unit(nodes[b].position)
                pull[a] += tangent(db - da * dot(db, da), at: da)
                pull[b] += tangent(da - db * dot(da, db), at: db)
            }
            // **Towards the average neighbour, not the sum of them.** Summing
            // pulls a star with forty edges forty times as hard as one with a
            // single edge, and every library has a person like that: you are in
            // all of your own recordings. Measured on a synthetic library where
            // three people spoke in all forty-eight meetings, the summed
            // version dragged the entire picture into one hemisphere and left
            // the other half of every shell empty.
            for index in pull.indices where degree[index] > 0 {
                delta[index] = pull[index] / Float(degree[index]) * 0.12
            }
            // Fixed-resolution buckets over the unit sphere, so crowding costs
            // a bounded number of comparisons rather than every pair. A library
            // of 1200 stars would otherwise be 719,400 of them per pass.
            var buckets: [Cell: [Int]] = [:]
            for index in nodes.indices where indices[nodes[index].id] != nil {
                buckets[cell(for: unit(nodes[index].position)), default: []].append(index)
            }
            // Sorted nodes and a fixed cell order, so the sum is the same every
            // run. A Dictionary's own iteration order is not.
            for a in nodes.indices where indices[nodes[a].id] != nil {
                let da = unit(nodes[a].position)
                var inspected = 0
                neighbours: for neighbour in cell(for: da).neighbours {
                    guard let others = buckets[neighbour] else { continue }
                    for b in others where a < b {
                        inspected += 1
                        let db = unit(nodes[b].position)
                        let separation = da - db
                        let distanceSquared = max(0.015, dot(separation, separation))
                        if distanceSquared < 0.24 {
                            delta[a] += tangent(separation / distanceSquared, at: da) * 0.018
                            delta[b] += tangent(-separation / distanceSquared, at: db) * 0.018
                        }
                        if inspected >= 96 { break neighbours }
                    }
                }
            }
            for index in nodes.indices where indices[nodes[index].id] != nil {
                let direction = unit(nodes[index].position)
                // Back towards where the id put it, so a star that nothing
                // pulls stays where a reader last saw it.
                delta[index] += tangent(anchors[index] - direction * dot(anchors[index], direction), at: direction) * 0.035
                nodes[index].position = unit(direction + delta[index]) * (shellRadius(kind: nodes[index].kind) ?? 0)
            }
        }
        return Snapshot(nodes: nodes, edges: edges, label: snapshot.label)
    }

    private struct Cell: Hashable {
        let x: Int, y: Int, z: Int
        var neighbours: [Cell] {
            (-1...1).flatMap { dx in (-1...1).flatMap { dy in (-1...1).map { dz in Cell(x: x + dx, y: y + dy, z: z + dz) } } }
        }
    }
    private static func cell(for direction: SIMD3<Float>) -> Cell {
        Cell(x: Int(floor(direction.x * 8)), y: Int(floor(direction.y * 8)), z: Int(floor(direction.z * 8)))
    }
    private static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { a.x * b.x + a.y * b.y + a.z * b.z }
    private static func unit(_ value: SIMD3<Float>) -> SIMD3<Float> {
        let magnitude = sqrt(max(0, dot(value, value)))
        return magnitude > 0.000_001 ? value / magnitude : SIMD3<Float>(0, 1, 0)
    }
    private static func tangent(_ value: SIMD3<Float>, at direction: SIMD3<Float>) -> SIMD3<Float> {
        value - direction * dot(value, direction)
    }

    /// FNV-1a, avalanche-mixed.
    ///
    /// Swift's own `Hasher` is seeded per process on purpose, so a star would
    /// be somewhere else after every launch. The mix is not optional either:
    /// raw FNV over ids that differ in their last character returns values that
    /// differ in their low bits, and taking `z` from those put a whole library
    /// into one band of the sphere. It was caught by a test, not by looking.
    private static func mixed(_ value: UInt64) -> UInt64 {
        var x = value
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        return x ^ (x >> 31)
    }
    private static func hash(_ value: String) -> UInt64 {
        var result: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { result ^= UInt64(byte); result &*= 1_099_511_628_211 }
        return result
    }
    private static func seedDirection(id: String) -> SIMD3<Float> {
        let first = mixed(hash(id)), second = mixed(hash("sphere:" + id))
        let z = Float(Double(first) / Double(UInt64.max) * 2 - 1)
        let angle = Float(Double(second) / Double(UInt64.max) * Double.pi * 2)
        let radius = sqrt(max(0, 1 - z * z))
        return SIMD3<Float>(cos(angle) * radius, z, sin(angle) * radius)
    }
}

/// The world's slow rotation, shared by the shader, the labels and picking.
///
/// A rigid rotation about the origin, so every shell keeps its exact radius and
/// the centre does not move at all. Three consumers compute it, which is why it
/// lives here: a label drawn where the star used to be is worse than no label.
enum GalaxyMotion {
    static func position(_ position: SIMD3<Float>, kind: String, time: Double) -> SIMD3<Float> {
        guard kind != Galaxy.Node.device, position != .zero else { return .zero }
        let transformed = matrix(time: time) * SIMD4<Float>(position, 1)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    static func matrix(time: Double) -> simd_float4x4 {
        let angle = Float(time) * 0.012
        guard angle != 0 else { return matrix_identity_float4x4 }
        let axis = simd_normalize(SIMD3<Float>(0.16, 1, 0.09))
        let c = cos(angle), s = sin(angle), t = 1 - c
        let x = axis.x, y = axis.y, z = axis.z
        return simd_float4x4(
            SIMD4<Float>(t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0),
            SIMD4<Float>(t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0),
            SIMD4<Float>(t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0),
            SIMD4<Float>(0, 0, 0, 1))
    }
}

/// Whether the picture is allowed to animate right now.
///
/// Ambient motion is decoration and says nothing about the library, so every
/// reason to stop it wins: the user's own switch, the window being hidden or
/// covered, Reduce Motion, Low Power, and any interaction. A picture that keeps
/// redrawing behind another window is a battery cost for something nobody can
/// see, which is the whole reason this is a struct with a name rather than one
/// `if` in the draw method.
struct GalaxyMotionPolicy {
    var enabled = true
    var visible = false
    var reducedMotion = false
    var lowPower = false
    var interacting = false

    var ambient: Bool { enabled && visible && !reducedMotion && !lowPower && !interacting }
    /// A camera flight to a star somebody just clicked. It ignores
    /// `interacting`, because the selection *is* the interaction, but it still
    /// honours every system and user switch above it.
    var flights: Bool { enabled && visible && !reducedMotion && !lowPower }
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
