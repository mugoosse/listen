import Foundation
import ListenKit

@main
struct GraphCoreTests {
    static func evidence(_ source: String = "note:synthetic-note-1", title: String = "Synthetic planning note") -> ContextCard.Evidence {
        ContextCard.Evidence(
            source: source,
            title: title,
            recordedAt: "2026-03-01",
            quote: "Synthetic evidence only.",
            speaker: "Morgan",
            start: 12.5,
            revision: "synthetic-r1"
        )
    }

    static func entry(
        id: String,
        predicate: String = "works_on",
        text: String,
        object: String? = "project:atlas",
        objectKind: String? = "project",
        status: String = "current",
        corrected: Bool = false,
        attribution: String = "direct",
        modality: String = "asserted",
        polarity: String = "positive"
    ) -> ContextCard.Entry {
        ContextCard.Entry(
            id: id, subject: "person:morgan", subjectName: "Morgan", predicate: predicate,
            text: text, object: object, objectKind: objectKind, status: status, time: nil,
            evidence: [evidence()], corrected: corrected, pinned: false,
            attribution: attribution, modality: modality, polarity: polarity
        )
    }

    static func card(_ entries: [ContextCard.Entry]) -> ContextCard {
        ContextCard(id: "person:morgan", kind: "person", name: "Morgan", aliases: [], brief: [], entries: entries,
                    updated: nil, pending: 0, failed: 0)
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func testProjectionFiltersHistoricalAndRetractions() {
        let current = entry(id: "current", text: "Morgan works on Atlas.")
        let historical = entry(id: "historical", text: "Morgan worked on Legacy.", object: "project:legacy", status: "historical")
        let retracted = entry(id: "retracted", text: "Morgan works on Removed.", object: "project:removed", status: "retracted")
        let snapshot = GraphProjection.build(cards: [card([current, historical, retracted])])
        let ids = Set(snapshot.nodes.map(\.id))
        require(ids.contains("person:morgan") && ids.contains("project:atlas"), "current relationship must remain")
        require(!ids.contains("project:legacy") && !ids.contains("project:removed"), "historical/retracted-only nodes must be absent")
        require(snapshot.edges.allSatisfy { $0.id != "relationship:historical" && $0.id != "relationship:retracted" }, "historical/retracted edges must be absent")

        let withHistory = GraphProjection.build(cards: [card([current, historical, retracted])], includeHistory: true)
        require(Set(withHistory.nodes.map(\.id)).isSuperset(of: ["project:legacy", "project:removed"]), "history opt-in must include historical and retracted entries")
    }

    static func testProjectionKeepsSuppliedSourcesWithoutCards() {
        let recording = GraphNode(id: "recording:hidden", kind: "recording", title: "Hidden synthetic recording", evidence: [])
        let note = GraphNode(id: "note:hidden", kind: "note", title: "Hidden synthetic note", evidence: [])
        let sourceEdge = GraphEdge(id: "hidden-source-link", source: recording.id, target: note.id,
                                   kind: "source-link", label: "Hidden claim source", status: "current", evidence: [])
        let snapshot = GraphProjection.build(cards: [], sources: [recording, note], sourceEdges: [sourceEdge])
        require(Set(snapshot.nodes.map(\.id)) == [recording.id, note.id], "independently verified supplied sources must survive without facts")
        require(snapshot.edges.map(\.id) == [sourceEdge.id], "source topology between validated supplied sources must survive")

        let filtered = card([entry(id: "hidden-history", text: "Morgan worked on Hidden.", object: "project:hidden", status: "historical")])
        let filteredSnapshot = GraphProjection.build(cards: [filtered])
        require(!filteredSnapshot.nodes.contains(where: { $0.id == "note:synthetic-note-1" }), "filtered entries must not synthesize unsupported evidence sources")
    }

    static func testProjectionUsesEntrySubjectAndCanonicalObjectTitle() {
        let incoming = entry(id: "incoming", text: "Morgan works on Atlas.")
        let projectCard = ContextCard(id: "project:incoming", kind: "project", name: "Incoming", aliases: [], brief: [], entries: [incoming], updated: nil, pending: 0, failed: 0)
        let atlasCard = ContextCard(id: "project:atlas", kind: "project", name: "Atlas", aliases: [], brief: [], entries: [], updated: nil, pending: 0, failed: 0)
        let unknown = entry(id: "unknown", text: "Morgan is exploring an unnamed initiative.", object: "project:sha256-deadbeef")
        let snapshot = GraphProjection.build(cards: [projectCard, atlasCard, card([unknown])])
        let incomingEdge = snapshot.edges.first(where: { $0.id == "relationship:incoming" })
        require(incomingEdge?.source == "person:morgan", "relationships must use entry.subject rather than enclosing card ID")
        require(snapshot.nodes.first(where: { $0.id == "person:morgan" })?.title == "Morgan", "subject title must use entry.subjectName")
        require(snapshot.nodes.first(where: { $0.id == "project:atlas" })?.title == "Atlas", "object title must use its canonical card name")
        require(snapshot.nodes.first(where: { $0.id == "project:sha256-deadbeef" })?.title == unknown.text, "unknown object title must use entry text, never its opaque ID")
    }

    static func testProjectionCreatesDeduplicatedEvidenceTopologyAndRejectsUnsupportedEntries() {
        let recording = evidence("rec:2026-03-01-a", title: "Standup recording")
        let note = evidence("note:plan", title: "Plan note")
        let person = evidence("person:alex", title: "Alex")
        let claim = evidence("claim:source-a", title: "Imported claim")
        var supported = entry(id: "supported", text: "Morgan works on Atlas.")
        supported.evidence = [recording, recording, note, person, claim]
        supported.changeEvidence = [note]
        let supplied = GraphNode(id: "rec:2026-03-01-a", kind: "recording", title: "Library recording", evidence: [])
        let duplicateCard = ContextCard(id: "project:duplicate", kind: "project", name: "Duplicate", aliases: [], brief: [], entries: [supported], updated: nil, pending: 0, failed: 0)
        var unsupported = entry(id: "unsupported", text: "Morgan works on Unsupported.", object: "project:unsupported")
        unsupported.evidence = []; unsupported.changeEvidence = nil
        var blankSource = entry(id: "blank-source", text: "Morgan works on Blank.", object: "project:blank")
        blankSource.evidence = [evidence("")]
        let snapshot = GraphProjection.build(cards: [card([supported, unsupported, blankSource]), duplicateCard], sources: [supplied])
        let nodeIDs = Set(snapshot.nodes.map(\.id))
        require(nodeIDs.isSuperset(of: ["rec:2026-03-01-a", "note:plan", "person:alex", "claim:source-a"]), "eligible evidence must create exact source IDs")
        require(snapshot.nodes.first(where: { $0.id == supplied.id })?.title == supplied.title, "matching supplied source must be reused")
        require(snapshot.nodes.first(where: { $0.id == "note:plan" })?.kind == "note", "note evidence must synthesize a note node")
        require(snapshot.nodes.first(where: { $0.id == "person:alex" })?.kind == "person", "person evidence must synthesize a person node")
        require(snapshot.nodes.first(where: { $0.id == "claim:source-a" })?.kind == "claim", "other evidence must synthesize a claim/source node")
        require(snapshot.edges.filter { $0.id == "relationship:supported" }.count == 1, "entries repeated across cards must deduplicate")
        require(snapshot.edges.filter { $0.kind == "evidence" && $0.source == "person:morgan" }.count == 4, "repeated evidence must yield one edge per actual support")
        require(!nodeIDs.contains("project:unsupported") && !snapshot.edges.contains(where: { $0.id == "relationship:unsupported" }), "entries without evidence must be rejected defensively")
        require(!nodeIDs.contains("project:blank") && !snapshot.edges.contains(where: { $0.id == "relationship:blank-source" }), "entries without an actual evidence source must be rejected")
    }

    static func testProjectionCorrectedEvidenceTargetsClaimAndPreservesStatuses() {
        let corrected = entry(id: "corrected-evidence", text: "Morgan is focused on Orion now.", object: "project:atlas", status: "conflicted", corrected: true)
        let statuses = ["current", "historical", "conflicted", "negative", "planned", "reported"]
        let entries = statuses.map { entry(id: "status-\($0)", text: "Morgan status \($0).", object: "topic:\($0)", status: $0) }
        let snapshot = GraphProjection.build(cards: [card([corrected] + entries)], includeHistory: true)
        require(snapshot.edges.first(where: { $0.id == "relationship:corrected-evidence" })?.target == "claim:corrected-evidence", "corrected entries must not assert their original object")
        require(snapshot.edges.contains(where: { $0.kind == "evidence" && $0.source == "claim:corrected-evidence" && $0.target == "note:synthetic-note-1" }), "corrected claims must connect to their evidence")
        for status in statuses {
            require(snapshot.edges.first(where: { $0.id == "relationship:status-\(status)" })?.status == status, "status \(status) must remain intact")
        }
    }

    static func testProjectionKeepsQualifiersAndDoesNotInventAttendance() {
        let qualified = entry(id: "qualified", text: "Morgan may not join Atlas.", attribution: "reported", modality: "planned", polarity: "negative")
        let snapshot = GraphProjection.build(cards: [card([qualified])])
        let label = snapshot.edges.first(where: { $0.id == "relationship:qualified" })?.label ?? ""
        require(label.contains("Negative") && label.contains("Planned") && label.contains("Reported"), "negative, planned, and reported labels must survive")
        require(!snapshot.edges.contains(where: { $0.label.localizedCaseInsensitiveContains("attend") }), "a speaker/evidence record must not imply attendance")
    }

    static func testCorrectedTextDoesNotTargetOriginalObject() {
        let corrected = entry(id: "corrected", text: "Morgan is focused on Orion now.", object: "project:atlas", corrected: true)
        let snapshot = GraphProjection.build(cards: [card([corrected])])
        require(!snapshot.nodes.contains(where: { $0.id == "project:atlas" }), "corrected text must not retain its stale object identity")
        let relationship = snapshot.edges.first(where: { $0.id == "relationship:corrected" })
        require(relationship?.target == "claim:corrected", "corrected relationship must terminate at a textual claim, not the original object")
    }

    static func testEdgesHaveEndpointsAndLayoutIsStable() {
        let base = GraphFixture.make(nodeCount: 12)
        let reversed = GraphSnapshot(nodes: base.nodes.reversed(), edges: base.edges.reversed(), label: base.label)
        let laidOut = GraphLayout.apply(to: base)
        let laidOutReversed = GraphLayout.apply(to: reversed)
        let extra = GraphNode(id: "topic:extra", kind: "topic", title: "Extra", position: .zero, evidence: [])
        let expanded = GraphLayout.apply(to: GraphSnapshot(nodes: base.nodes + [extra], edges: base.edges, label: base.label))
        let positions = Dictionary(uniqueKeysWithValues: laidOut.nodes.map { ($0.id, $0.position) })
        let reversedPositions = Dictionary(uniqueKeysWithValues: laidOutReversed.nodes.map { ($0.id, $0.position) })
        let expandedPositions = Dictionary(uniqueKeysWithValues: expanded.nodes.map { ($0.id, $0.position) })
        require(laidOut.edges.allSatisfy { edge in positions[edge.source] != nil && positions[edge.target] != nil }, "every edge endpoint must exist")
        for (id, position) in positions {
            require(position == reversedPositions[id] && position == expandedPositions[id], "layout position must be independent of input order and node count for \(id)")
            require(position.x.isFinite && position.y.isFinite && position.z.isFinite, "positions must be finite")
        }
    }

    static func testFixtureIsExplicitlySynthetic() {
        let fixture = GraphFixture.make(nodeCount: 9)
        require(fixture.label.localizedCaseInsensitiveContains("synthetic"), "fixture must be labelled synthetic")
        require(Set(fixture.nodes.map(\.kind)).isSuperset(of: ["person", "project", "recording", "note"]), "fixture must cover required kinds")
        require(fixture.nodes.flatMap(\.evidence).allSatisfy { $0.relativePath == nil }, "fixture must not claim real source paths")
    }

    static func main() {
        testProjectionFiltersHistoricalAndRetractions()
        testProjectionKeepsSuppliedSourcesWithoutCards()
        testProjectionUsesEntrySubjectAndCanonicalObjectTitle()
        testProjectionCreatesDeduplicatedEvidenceTopologyAndRejectsUnsupportedEntries()
        testProjectionCorrectedEvidenceTargetsClaimAndPreservesStatuses()
        testProjectionKeepsQualifiersAndDoesNotInventAttendance()
        testCorrectedTextDoesNotTargetOriginalObject()
        testEdgesHaveEndpointsAndLayoutIsStable()
        testFixtureIsExplicitlySynthetic()
        print("Graph core tests passed")
    }
}
