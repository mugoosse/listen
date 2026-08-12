import Foundation
import CryptoKit

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// What one sync pass did, so the UI can say something true rather than
/// spinning. A sync that reports nothing is indistinguishable from a sync that
/// silently failed, and the second one is the one that loses a session.
public struct SyncReport: Sendable, Equatable {
    public var pulledSidecars = 0
    public var pulledRecordings = 0
    public var uploadedRecordings = 0
    public var uploadedBytes = 0
    public var freedBytes = 0
    public var pulledNotes = 0
    public var pushedNotes = 0
    public var conflicts: [String] = []
    public var errors: [String] = []

    public var didSomething: Bool {
        pulledSidecars + pulledRecordings + uploadedRecordings + pulledNotes + pushedNotes > 0
            || freedBytes > 0
    }

    public var summary: String {
        if !errors.isEmpty { return errors[0] }
        if !didSomething { return "Up to date" }
        var parts: [String] = []
        if uploadedRecordings > 0 { parts.append("sent \(uploadedRecordings)") }
        if pulledRecordings > 0 { parts.append("\(pulledRecordings) new") }
        if pulledSidecars > 0 { parts.append("\(pulledSidecars) updated") }
        if freedBytes > 0 { parts.append("freed \(freedBytes / 1_048_576) MB") }
        if pulledNotes + pushedNotes > 0 { parts.append("\(pulledNotes + pushedNotes) notes") }
        return parts.joined(separator: ", ")
    }

    public init() {}
}

/// The phone's half of the sync. Everything here is plain logic over a
/// `SyncClient`, so it runs identically against the network and against a
/// loopback server on one machine, which is what makes seams S3, S4, S7 and S9
/// in spec/05-testing.md testable from a Mac command line.
public struct SyncEngine: Sendable {
    let library: Library
    let client: SyncClient
    let keepAudioLocally: Bool
    /// What this device keeps. Injectable rather than assumed, because this
    /// engine is run from a Mac command line by `listen-sync sync`, which is
    /// how seams S3, S4, S7 and S9 are proved without a simulator.
    let policy: DevicePolicy

    public init(library: Library, client: SyncClient, keepAudioLocally: Bool = false,
                policy: DevicePolicy = .phone) {
        self.library = library; self.client = client
        self.keepAudioLocally = keepAudioLocally; self.policy = policy
    }

    public func run() async -> SyncReport {
        var report = SyncReport()
        do {
            let (response, _) = try await client.send(Request(op: .manifest, token: ""))
            guard let manifest = response.manifest else {
                report.errors.append("The Mac sent no manifest.")
                return report
            }
            try library.prepare()
            await pull(manifest, into: &report)
            await push(manifest, into: &report)
            await reclaim(manifest, into: &report)
            await syncNotes(manifest, into: &report)
        } catch {
            report.errors.append(error.localizedDescription)
        }
        return report
    }

    // MARK: - Down

    /// Bring down everything this device is missing, `metadata.json` last.
    ///
    /// **The files arrive as bytes and are written as bytes.** `metadata.json`
    /// used to be rebuilt here out of the five scalar fields the manifest
    /// carries, which is why `tags`, `calendar_event_id`, `calendar_people` and
    /// `app_name` never reached the phone and were dropped again on every
    /// subsequent pull. There is no schema to be lossy about now: whatever the
    /// authoring device wrote is what lands here. See `DevicePolicy`.
    ///
    /// It is written last for the reason `RecordingWriter` exists. A folder
    /// without `metadata.json` does not load, and `Library.all` is a compactMap
    /// over `load`, so a recording being pulled is invisible rather than
    /// half-present, and a pull that dies halfway leaves nothing to clean up.
    ///
    /// **One assumption holds this up: every sidecar has exactly one author.**
    /// A transcript is written by the Mac that made it and by nothing else, so
    /// a digest that differs can only mean this device is behind, and taking
    /// the remote copy is not a choice between two versions but a catch-up.
    ///
    /// The day a phone transcribes for itself that stops being true of
    /// `transcript.json`, and this loop keeps working by accident: the Mac's
    /// copy would win because it is remote, which is also the answer ranking by
    /// model gives, for an unrelated reason. It would stop being the same
    /// answer the moment anything else changed. `CLOUDKIT-PLAN.md` §2.11 has
    /// the rule that has to replace it, and the rule is by `asr_model` and
    /// never by a clock.
    private func pull(_ manifest: Manifest, into report: inout SyncReport) async {
        for entry in manifest.recordings {
            let folder = library.folder(for: entry.id)
            let isNew = Recording.load(folder) == nil
            var wroteMetadata = false

            for file in policy.writeOrder {
                guard let want = entry.digests[file] else { continue }
                let local = folder.appendingPathComponent(file)
                if let have = try? Data(contentsOf: local), sha256Hex(have) == want { continue }
                do {
                    var request = Request(op: .get, token: "")
                    request.id = entry.id; request.file = file
                    let (_, data) = try await client.send(request, body: Data())
                    try FileManager.default.createDirectory(at: folder,
                                                            withIntermediateDirectories: true)
                    try data.write(to: local, options: .atomic)
                    if file == "metadata.json" { wroteMetadata = true } else {
                        report.pulledSidecars += 1
                    }
                } catch {
                    report.errors.append("\(entry.id)/\(file): \(error.localizedDescription)")
                    // Stop on the first failure for this recording rather than
                    // pressing on to `metadata.json`, which would publish a
                    // folder whose transcript never arrived.
                    break
                }
            }

            if isNew, wroteMetadata { report.pulledRecordings += 1 }
        }
    }

    // MARK: - Up

    private func push(_ manifest: Manifest, into report: inout SyncReport) async {
        let known = Dictionary(uniqueKeysWithValues: manifest.recordings.map { ($0.id, $0) })
        for recording in library.all() {
            guard recording.metadata.source == "iphone" else { continue }
            if let there = known[recording.id], there.hasAudio { continue }
            guard recording.hasAudio else { continue }
            do {
                let bytes = try await upload(recording)
                report.uploadedRecordings += 1
                report.uploadedBytes += bytes
            } catch {
                report.errors.append("\(recording.id): \(error.localizedDescription)")
            }
        }
    }

    /// Send one recording's audio, in chunks, then publish it.
    ///
    /// Chunked because a phone loses wifi, and an upload that has to restart
    /// from zero on a 50-minute session is an upload that never completes on a
    /// train. `finish` is a separate call for the reason `RecordingWriter`
    /// exists: the Mac writes `metadata.json` only once every byte is there,
    /// so a half-sent recording is invisible rather than broken.
    private func upload(_ recording: Recording) async throws -> Int {
        // `mic.wav`, and only ever that. This line used to be a ternary whose
        // two branches were the same expression, left over from a FLAC path
        // that was specified and never written: `Recording.flacURL` exists and
        // counts towards `hasAudio`, but nothing in either app encodes one, so
        // every size estimate written against "25 MB as FLAC" is really Int16
        // WAV at about 1.9 MB per minute. Worth knowing before that number is
        // ever multiplied by a cloud egress price.
        let handle = try FileHandle(forReadingFrom: recording.micURL)
        defer { try? handle.close() }
        var offset = 0
        while true {
            let chunk = try handle.read(upToCount: Wire.chunkSize) ?? Data()
            let isLast = chunk.count < Wire.chunkSize
            var request = Request(op: .put, token: "")
            request.id = recording.id
            request.file = "mic.wav"
            request.offset = offset
            request.last = isLast
            _ = try await client.send(request, body: chunk)
            offset += chunk.count
            if isLast { break }
        }
        var finish = Request(op: .finish, token: "")
        finish.id = recording.id
        finish.metadata = recording.metadata
        _ = try await client.send(finish)
        return offset
    }

    // MARK: - Reclaim

    /// Delete audio the Mac has acknowledged.
    ///
    /// Off when the user has asked to keep it. Once this runs the phone is
    /// exactly the second-Mac case `SYNC.md` already describes, and the
    /// transcript screen has to say where the audio went rather than looking
    /// broken. `hasAudio` on the Mac's manifest is the acknowledgement: no
    /// separate receipt to lose, and the phone can only delete something the
    /// Mac has told it, in this pass, that it holds.
    private func reclaim(_ manifest: Manifest, into report: inout SyncReport) async {
        guard !keepAudioLocally else { return }
        let known = Dictionary(uniqueKeysWithValues: manifest.recordings.map { ($0.id, $0) })
        for recording in library.all() {
            guard recording.metadata.source == "iphone",
                  recording.hasAudio,
                  let there = known[recording.id], there.hasAudio else { continue }
            let size = (try? FileManager.default.attributesOfItem(
                atPath: recording.micURL.path)[.size] as? Int) ?? 0
            do {
                try FileManager.default.removeItem(at: recording.micURL)
                report.freedBytes += size
            } catch {
                report.errors.append("could not free \(recording.id)")
            }
        }
    }

    // MARK: - Notes

    /// Three-way, against the version both sides agreed on last time.
    ///
    /// Never a two-way timestamp comparison: see `SyncState` for the edit that
    /// was destroyed by one, and reported as a success.
    private func syncNotes(_ manifest: Manifest, into report: inout SyncReport) async {
        var state = SyncState.load(library)
        let theirs = Dictionary(uniqueKeysWithValues: manifest.notes.map { ($0.slug, $0.version) })
        let mine = Dictionary(uniqueKeysWithValues: library.allNotes().map { ($0.slug, $0) })

        var remoteNotes: [String: Note] = [:]
        do {
            let (response, _) = try await client.send(Request(op: .notes, token: ""))
            for note in response.notes ?? [] { remoteNotes[note.slug] = note }
        } catch {
            report.errors.append("notes: \(error.localizedDescription)")
            return
        }

        for slug in Set(mine.keys).union(theirs.keys) {
            let base = state[note: slug]
            let local = mine[slug]?.version
            let remote = theirs[slug]

            switch decideNote(base: base, local: local, remote: remote) {
            case .nothing:
                if let agreed = local ?? remote { state[note: slug] = agreed }

            case .pull:
                guard let note = remoteNotes[slug] else { continue }
                do {
                    // stamp: false, so both devices agree on one timestamp for
                    // one version. See `Library.writeNote`.
                    try library.writeNote(note, expecting: local, stamp: false)
                    state[note: slug] = note.version
                    report.pulledNotes += 1
                } catch {
                    report.conflicts.append(slug)
                }

            case .push:
                guard let note = mine[slug] else { continue }
                var request = Request(op: .putNote, token: "")
                request.note = note
                request.expecting = remote
                do {
                    let (response, _) = try await client.send(request)
                    if response.conflict != nil {
                        report.conflicts.append(slug)
                    } else {
                        state[note: slug] = note.version
                        report.pushedNotes += 1
                    }
                } catch {
                    report.errors.append("note \(slug): \(error.localizedDescription)")
                }

            case .conflict:
                // Touch neither side. The user is shown both and picks, which
                // is the only honest outcome: any automatic choice here throws
                // away something somebody typed on purpose.
                report.conflicts.append(slug)
            }
        }
        state.save(library)
    }
}
