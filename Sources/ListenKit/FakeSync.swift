import Foundation

/// The whole sync, against a store in a dictionary, in about a second.
///
/// This is what replaces `roundtrip.sh`, which described itself as the whole
/// sync architecture on one machine in about a minute and did it by running
/// the real engine through a loopback server. **CloudKit has no loopback**, so
/// there is no second path to keep that alive on.
///
/// What is lost is nothing that was being tested: `roundtrip.sh` was never
/// testing TCP. What is gained is the two cases a real container will not
/// produce on demand, and which are the two that lose data: a change token the
/// server cannot resume from, and two devices racing for one ingest.
///
/// What this does **not** prove is that CloudKit behaves as documented. That is
/// a separate, slower pass against the Development container. Two layers, and
/// the fast one is hermetic.
public enum FakeSync {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Runs every seam and returns the lines to print. Throws on the first
    /// failure, because a suite that carries on after one is a suite whose
    /// later results nobody trusts.
    public static func run(root: URL) async throws -> [String] {
        var out: [String] = []
        func ok(_ what: String) { out.append("  ok: \(what)") }
        func check(_ condition: Bool, _ what: String) throws {
            guard condition else { throw Failure(description: what) }
        }

        try? FileManager.default.removeItem(at: root)
        let key = PairingKey.generate()

        // Two devices over one container, which is the shape everything here
        // is about. A Mac that ingests, and a phone that does not.
        let macLib = try scratchLibrary(root.appendingPathComponent("mac"))
        let phoneLib = try scratchLibrary(root.appendingPathComponent("phone"))

        // Per-device state is deliberately **outside** the library, which is
        // the whole point of `EngineState` and is why deleting the scratch
        // libraries above does not clear it. So a second run of this suite
        // began holding a change token from the first run's store, and a fresh
        // store has never heard of that token, so nothing was ever fetched and
        // the failure surfaced three assertions later as a missing file.
        //
        // Hermetic means starting from nothing, and nothing includes the state
        // that is correctly kept somewhere else.
        try? FileManager.default.removeItem(at: EngineState(library: macLib).root)
        try? FileManager.default.removeItem(at: EngineState(library: phoneLib).root)

        let store = MemoryStore()
        let mac = CloudSyncCore(library: macLib, state: EngineState(library: macLib),
                                store: store, key: key, policy: .mac,
                                device: "mac-1", ingests: true)
        let phone = CloudSyncCore(library: phoneLib, state: EngineState(library: phoneLib),
                                  store: store, key: key, policy: .phone,
                                  device: "phone-1", ingests: false)

        // MARK: sealing and naming

        let sealed = try key.seal(Data("a meeting nobody else may read".utf8))
        try check(String(decoding: sealed, as: UTF8.self) != "a meeting nobody else may read",
                  "the payload was not sealed")
        try check(try key.open(sealed) == Data("a meeting nobody else may read".utf8),
                  "the payload did not survive a round trip")
        ok("sealing round-trips, and the sealed form is not the plain one")

        let a = CloudNaming.recordName(.recording, "2026-08-12-101010-ABCD", key: key)
        let b = CloudNaming.recordName(.recording, "2026-08-12-101010-ABCD", key: key)
        let c = CloudNaming.recordName(.note, "2026-08-12-101010-ABCD", key: key)
        let d = CloudNaming.recordName(.recording, "2026-08-12-101010-ABCD",
                                       key: PairingKey.generate())
        try check(a == b, "two devices with one key derived different names")
        try check(a != c, "a note and a recording with one natural key collided")
        try check(a != d, "a different key produced the same name")
        try check(!a.contains("2026"), "the record name leaks the meeting time")
        ok("record names are deterministic, typed apart, key-bound and opaque")

        // MARK: a recording crosses, verbatim

        let id = "2026-08-12-101010-ABCD"
        let metadata = """
        {"id":"\(id)","title":"Quarterly review","recorded_at":"2026-08-12T10:10:10Z",\
        "duration":1800,"source":"mac","state":"done","tags":["board"],\
        "calendar_people":[{"name":"Rita","email":"r@example.com","is_me":false,\
        "is_organizer":true}],"mic_silent":true}
        """
        try seed(macLib, id: id, metadata: metadata,
                 transcript: #"{"segments":[],"duration":1800,"model":"parakeet-v3"}"#)

        var push = CloudReport()
        await mac.push(into: &push)
        try check(push.errors.isEmpty, "pushing failed: \(push.errors)")

        var pull = CloudReport()
        await phone.pull(into: &pull)
        try check(pull.errors.isEmpty, "pulling failed: \(pull.errors)")

        let landed = try Data(contentsOf: phoneLib.folder(for: id)
            .appendingPathComponent("metadata.json"))
        try check(landed == Data(metadata.utf8),
                  "metadata.json did not cross byte-identical")
        ok("metadata.json crosses verbatim, with fields neither device models")

        // MARK: what the phone must never receive

        try check(!FileManager.default.fileExists(
            atPath: phoneLib.folder(for: id).appendingPathComponent("embeddings.json").path),
                  "voiceprints reached a device whose policy excludes them")
        ok("voiceprints stay off a device that does not keep them")

        // MARK: it converges

        var second = CloudReport()
        await phone.pull(into: &second)
        try check(!second.didSomething,
                  "a settled pair still had work: \(second.summary)")
        ok("a second pass is a no-op, so nothing rewrites what it received")

        // MARK: notes, and the four cases

        try check(decideNote(base: nil, local: nil, remote: "r") == .pull, "never seen here")
        try check(decideNote(base: "b", local: "b", remote: "r") == .pull, "behind")
        try check(decideNote(base: "b", local: "l", remote: "b") == .push, "ahead")
        try check(decideNote(base: "b", local: "l", remote: "r") == .conflict, "both moved")
        try check(decideNote(base: nil, local: "l", remote: "r") == .conflict, "both new")
        try check(decideNote(base: "b", local: "x", remote: "x") == .nothing, "agreed")
        ok("decideNote's table is unchanged by the move to a container")

        // MARK: the reclaim invariant

        let memoID = "2026-08-12-111111-BEEF"
        try seed(phoneLib, id: memoID,
                 metadata: #"{"id":"\#(memoID)","title":"Memo","source":"iphone","state":"done"}"#,
                 transcript: nil, audio: Data(repeating: 7, count: 4096))
        var up = CloudReport()
        await phone.push(into: &up)

        var down = CloudReport()
        await phone.pull(into: &down)
        try check(FileManager.default.fileExists(
            atPath: phoneLib.find(memoID)!.micURL.path),
            "the phone deleted its only copy before any Mac held it")
        ok("audio survives an upload that no device has acknowledged")

        // Now a Mac says it holds the bytes.
        let memoName = CloudNaming.recordName(.recording, memoID, key: key)
        var acknowledged = try await store.fetch(memoName, in: .library)!
        acknowledged.audioOn = "mac-1"
        _ = try await store.save(acknowledged)

        var reclaim = CloudReport()
        await phone.pull(into: &reclaim)
        try check(!FileManager.default.fileExists(
            atPath: phoneLib.folder(for: memoID).appendingPathComponent("mic.wav").path),
            "the phone kept audio a Mac had acknowledged")
        ok("audio is freed only once a Mac names itself in audioOn")

        // MARK: exactly one claimant

        let contested = StoredRecord(
            name: CloudNaming.recordName(.audioTransfer, "2026-08-12-121212-CAFE", key: key),
            type: .audioTransfer, payload: try key.seal(Data("x".utf8)))
        let saved = try await store.save(contested)
        let second_mac = CloudSyncCore(library: macLib, state: EngineState(library: macLib),
                                       store: store, key: key, policy: .mac,
                                       device: "mac-2", ingests: true)
        async let first = mac.claim(saved, preferred: nil, window: 300)
        async let other = second_mac.claim(saved, preferred: nil, window: 300)
        let winners = [try await first, try await other].filter { $0 }.count
        try check(winners == 1, "\(winners) devices claimed one ingest, not 1")
        ok("exactly one device wins a contested ingest, before downloading it")

        // MARK: deletion, and the token that expired

        macLib.deleteNote("nothing")   // no-op, proves a delete of the absent is fine
        let noteSlug = "quarterly-review"
        try macLib.writeNote(Note(slug: noteSlug, title: "Quarterly review", created: "",
                                  updated: "", source: "you", recordings: [id],
                                  body: "What we agreed."), expecting: nil)
        var notePush = CloudReport()
        await mac.push(into: &notePush)
        var notePull = CloudReport()
        await phone.pull(into: &notePull)
        try check(phoneLib.note(noteSlug) != nil, "the note did not arrive")
        ok("a note reaches the other device")

        try await store.delete(CloudNaming.recordName(.note, noteSlug, key: key), in: .library)
        var deletion = CloudReport()
        await phone.pull(into: &deletion)
        try check(phoneLib.note(noteSlug) == nil, "a deletion did not propagate")
        ok("a deletion propagates rather than coming back")

        // The case a real container will not stage on demand, and the one that
        // silently resurrects deleted meetings.
        await store.setExpireNextToken(true)
        var expired = CloudReport()
        await phone.pull(into: &expired)
        try check(phoneLib.note(noteSlug) == nil,
                  "an expired change token resurrected a deleted note")
        try check(phoneLib.find(id) != nil,
                  "an expired change token deleted a recording that still exists")
        ok("a refetch after an expired token neither resurrects nor destroys")

        return out
    }

    // MARK: - Scratch

    private static func scratchLibrary(_ root: URL) throws -> Library {
        let library = Library(root: root)
        try library.prepare()
        return library
    }

    private static func seed(_ library: Library, id: String, metadata: String,
                             transcript: String?, audio: Data? = nil) throws {
        let folder = library.folder(for: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let transcript {
            try Data(transcript.utf8).write(to: folder.appendingPathComponent("transcript.json"))
        }
        if let audio {
            try audio.write(to: folder.appendingPathComponent("mic.wav"))
        }
        // Last, always.
        try Data(metadata.utf8).write(to: folder.appendingPathComponent("metadata.json"))
    }
}
