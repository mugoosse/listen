import Foundation
import ListenKit

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main struct LibraryTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("listen-graph-test-" + UUID().uuidString)
        var refused = false
        do { _ = try GraphLibrary.read(root: root) } catch { refused = true }
        expect(refused, "missing library must fail, not masquerade as empty")
        expect(!FileManager.default.fileExists(atPath: root.path), "read must not create library")
        print("PASS: missing library is refused without writing")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingID = "2026-09-10-120000-A1B2"
        let recording = root.appendingPathComponent("recordings/" + recordingID)
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        let metadata = Metadata(id: recordingID, recordedAt: Date(timeIntervalSince1970: 0), duration: 10, title: "Synthetic meeting", titled: true, room: false)
        try JSONEncoder().encode(metadata).write(to: recording.appendingPathComponent("metadata.json"))
        let note = Note(slug: "synthetic-note", title: "Synthetic note", created: "", updated: "", source: "manual", recordings: [recordingID, "../../bad"], body: "Synthetic evidence only.")
        try note.serialised().write(to: root.appendingPathComponent("notes/synthetic-note.md"), atomically: true, encoding: .utf8)
        var hidden = note; hidden.slug = "excluded-note"; hidden.extra["exclude_from_ai"] = "true"
        try hidden.serialised().write(to: root.appendingPathComponent("notes/excluded-note.md"), atomically: true, encoding: .utf8)
        let input = try GraphLibrary.read(root: root)
        expect(input.sources.count == 2, "read actual recording and eligible note, omit excluded note")
        expect(input.sources.first(where: { $0.kind == "note" })?.recordings == [recordingID], "retain only valid existing recording references")
        expect(input.cards.isEmpty && !input.snapshotPresent, "missing memory projection remains explicitly absent")
        print("PASS: typed source discovery and source-link validation")
        let source = "note:synthetic-note"
        let evidence = ContextCard.Evidence(source: source, title: "Synthetic note", recordedAt: "2026-09-10", quote: "Synthetic evidence only.", speaker: nil, start: nil, revision: "fixture")
        let entry = ContextCard.Entry(id: "claim-a", subject: "person-a", subjectName: "Synthetic Alex", predicate: "works_on", text: "Synthetic Atlas", object: "project-a", objectKind: "project", status: "recorded", time: nil, evidence: [evidence], corrected: false, pinned: false, attribution: "direct", modality: "asserted", polarity: "positive")
        let card = ContextCard(id: "person-a", kind: "person", name: "Synthetic Alex", aliases: [], brief: [], entries: [entry], updated: nil, pending: 0, failed: 0)
        let notePath = "notes/synthetic-note.md"
        let digest = ContextIdentity.hash(try String(contentsOf: root.appendingPathComponent(notePath), encoding: .utf8))
        let snapshot = ContextSnapshot(cards: [card], proofs: [source: [notePath: digest]], overrides: [:], generatedAt: "2026-09-10T00:00:00Z")
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent(ContextSnapshot.filename))
        expect(tryReadCards(root) == 1, "existing ListenKit verifies real source proof")
        let correction = ContextOverride(id: "claim-a", hidden: true, updated: "2026-09-10T01:00:00Z")
        try ContextSync.write([correction.id: correction], root: root)
        expect(tryReadCards(root) == 0, "live hide override invalidates graph read")
        var reset = correction; reset.hidden = false; reset.updated = "2026-09-10T02:00:00Z"
        try ContextSync.write([reset.id: reset], root: root)
        expect(tryReadCards(root) == 1, "unhide restores eligible source-backed entry")
        let sourceURL = try GraphLibrary.evidenceURL(source: source, relativePath: notePath, root: root)
        expect(sourceURL.lastPathComponent == "synthetic-note.md", "evidence opens the exact current source")
        hidden.slug = "synthetic-note"
        try hidden.serialised().write(to: root.appendingPathComponent(notePath), atomically: true, encoding: .utf8)
        expect(tryReadCards(root) == 0, "excluded/edited proof source invalidates entry without indexing")
        var excludedRefused = false
        do { _ = try GraphLibrary.evidenceURL(source: source, relativePath: notePath, root: root) } catch { excludedRefused = true }
        expect(excludedRefused, "opening stale evidence rechecks current exclusion")
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.deletingLastPathComponent())
        for path in ["../outside", "/etc/passwd", "escape/outside"] {
            var unsafe = false
            do { _ = try GraphLibrary.safeURL(path, root: root) } catch { unsafe = true }
            expect(unsafe, "refuse traversal, absolute paths and symlink escapes")
        }
        print("PASS: source proofs, live hides, source exclusion and safe evidence paths")
    }
    static func tryReadCards(_ root: URL) -> Int { (try? GraphLibrary.read(root: root).cards.count) ?? -1 }
}
