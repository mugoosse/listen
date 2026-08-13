import Foundation

/// What one sync pass decided, so a screen can say something true rather than
/// spinning. A sync that reports nothing is indistinguishable from a sync that
/// silently failed, and the second is the one that loses a session.
public struct CloudReport: Sendable, Equatable {
    public var pushedRecordings = 0
    public var pulledRecordings = 0
    public var pulledSidecars = 0
    public var pushedNotes = 0
    public var pulledNotes = 0
    public var deletedLocally = 0
    public var claimed = 0
    public var freedBytes = 0
    public var conflicts: [String] = []
    public var errors: [String] = []

    public var didSomething: Bool {
        pushedRecordings + pulledRecordings + pulledSidecars + pushedNotes
            + pulledNotes + deletedLocally + claimed > 0 || freedBytes > 0
    }

    public var summary: String {
        if !errors.isEmpty { return errors[0] }
        if !didSomething { return "Up to date" }
        var parts: [String] = []
        if pushedRecordings > 0 { parts.append("sent \(pushedRecordings)") }
        if pulledRecordings > 0 { parts.append("\(pulledRecordings) new") }
        if pulledSidecars > 0 { parts.append("\(pulledSidecars) updated") }
        if pulledNotes + pushedNotes > 0 { parts.append("\(pulledNotes + pushedNotes) notes") }
        if deletedLocally > 0 { parts.append("removed \(deletedLocally)") }
        if freedBytes > 0 { parts.append("freed \(freedBytes / 1_048_576) MB") }
        return parts.joined(separator: ", ")
    }

    public init() {}
}

/// The sync, as plain logic over a `RecordStore`.
///
/// Everything here runs identically against `MemoryStore` and against
/// CloudKit, which is the property that makes every seam provable offline. The
/// store knows about records and change tags; this knows about recordings,
/// notes and what a device is allowed to decide on its own.
public struct CloudSyncCore: Sendable {
    let library: Library
    let state: EngineState
    let store: any RecordStore
    let key: PairingKey
    let policy: DevicePolicy
    /// Who this device is, for `claimedBy` and `audioOn`.
    let device: String
    /// Whether this device may ingest a phone recording at all. A phone cannot:
    /// it is the one uploading.
    let ingests: Bool
    /// True when the user has asked to keep audio on this device whatever a
    /// Mac says. Turns `reclaim` off entirely.
    let keepAudio: Bool

    /// Said out loud as the pass runs, so a screen can show something moving.
    ///
    /// A first sync fetches every recording a library has, which on a real
    /// library is a minute of a spinner saying "Syncing…" and nothing else.
    /// That is indistinguishable from stuck, and a person watching it has no
    /// way to tell whether to wait or to give up.
    let progress: (@Sendable (String) -> Void)?

    public init(library: Library, state: EngineState, store: any RecordStore,
                key: PairingKey, policy: DevicePolicy, device: String,
                ingests: Bool, keepAudio: Bool = false,
                progress: (@Sendable (String) -> Void)? = nil) {
        self.library = library; self.state = state; self.store = store
        self.key = key; self.policy = policy; self.device = device
        self.ingests = ingests; self.keepAudio = keepAudio
        self.progress = progress
    }

    // MARK: - Down

    /// Take everything the container has that this device does not.
    ///
    /// `metadata.json` is written **last** for every recording, for the reason
    /// `RecordingWriter` exists: a folder without it does not load, and
    /// `Library.all` is a compactMap over `load`, so a recording arriving is
    /// invisible rather than half-present and a pull that dies halfway leaves
    /// nothing to clean up.
    public func pull(into report: inout CloudReport) async {
        var seen = state.everSeen
        var base = state.base
        defer { state.everSeen = seen; state.base = base }

        do {
            let changes = try await store.changes(in: .library, since: base[file: "token"])

            let total = changes.changed.count
            if total > 4 { progress?("Fetching \(total) items") }
            for (index, record) in changes.changed.enumerated() {
                if total > 4, index % 5 == 0 {
                    progress?("Fetching \(index + 1) of \(total)")
                }
                seen.insert(record.name)
                do {
                    switch record.type {
                    case .recording: try await pullRecording(record, into: &report)
                    case .note: try pullNote(record, base: &base, into: &report)
                    case .blob: try pullBlob(record, into: &report)
                    default: break
                    }
                } catch {
                    report.errors.append("\(record.name.prefix(8)): \(error.localizedDescription)")
                }
            }

            // Deletions, and the one case where a device cannot tell what a
            // silence means.
            //
            // When a change token expires the store refetches everything and
            // reports no deletions, because it has no way to describe what is
            // no longer there. A device that treated "absent from a full
            // refetch" as "still mine" would resurrect every meeting deleted
            // while it was away; one that treated it as "deleted" would delete
            // recordings it simply never had. `everSeen` is the difference: a
            // record this device has held before and that a full refetch does
            // not mention has genuinely gone.
            let gone: [String]
            if changes.refetchedEverything {
                let present = Set(changes.changed.map(\.name))
                gone = seen.subtracting(present).sorted()
            } else {
                gone = changes.deleted
            }
            for name in gone {
                if deleteLocally(named: name) { report.deletedLocally += 1 }
                seen.remove(name)
            }

            base[file: "token"] = changes.token
        } catch {
            report.errors.append(error.localizedDescription)
        }
    }

    private func pullRecording(_ record: StoredRecord,
                               into report: inout CloudReport) async throws {
        let blob = try CloudRecords.openRecording(record, key: key)
        guard Metadata.isValidID(blob.id) else { throw InvalidName.id(blob.id) }
        let folder = library.folder(for: blob.id)
        let isNew = Recording.load(folder) == nil

        // Sidecars first, metadata last, and only what this device keeps.
        for file in policy.files(for: blob.id) where file != "metadata.json" {
            guard let want = blob.digests[file] else { continue }
            let local = folder.appendingPathComponent(file)
            if let have = try? Data(contentsOf: local), sha256Hex(have) == want { continue }
            guard let data = try CloudRecords.openAsset(record, file, key: key) else { continue }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: local, options: .atomic)
            report.pulledSidecars += 1
        }

        let metadataURL = folder.appendingPathComponent("metadata.json")
        let have = try? Data(contentsOf: metadataURL)
        if have.map(sha256Hex) != blob.digests["metadata.json"] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Verbatim. The bytes the authoring device wrote, not a
            // re-encoding of them through whatever struct this device happens
            // to model. See `DevicePolicy`.
            try blob.metadata.write(to: metadataURL, options: .atomic)
            if isNew { report.pulledRecordings += 1 }
        }

        // The phone stops holding audio only when a Mac says it holds it.
        await reclaimIfAcknowledged(record, id: blob.id, into: &report)
    }

    private func pullNote(_ record: StoredRecord, base: inout SyncState,
                          into report: inout CloudReport) throws {
        let blob = try CloudRecords.openNote(record, key: key)
        guard Note.isValidSlug(blob.slug) else { throw InvalidName.slug(blob.slug) }
        let mine = library.note(blob.slug)

        switch decideNote(base: base[note: blob.slug], local: mine?.version,
                          remote: blob.version) {
        case .nothing:
            if let agreed = mine?.version ?? blob.version as String? {
                base[note: blob.slug] = agreed
            }
        case .pull:
            // Written as the markdown it arrived as, so hand-written
            // frontmatter and every key a later Listen invents survive. Parsed
            // only to hand `writeNote` its compare-and-swap.
            guard let note = Note.parse(slug: blob.slug, blob.markdown) else { return }
            try library.writeNote(note, expecting: mine?.version, stamp: false)
            base[note: blob.slug] = blob.version
            report.pulledNotes += 1
        case .push:
            break   // handled in push, with the record's change tag in hand
        case .conflict:
            // Touch neither side. Any automatic choice here throws away
            // something somebody typed on purpose.
            report.conflicts.append(blob.slug)
        }
    }

    private func pullBlob(_ record: StoredRecord, into report: inout CloudReport) throws {
        let blob = try CloudRecords.openBlob(record, key: key)
        guard policy.blobs.contains(blob.name) else { return }
        let url = library.root.appendingPathComponent(blob.name)
        if let have = try? Data(contentsOf: url), sha256Hex(have) == blob.version { return }
        try blob.contents.write(to: url, options: .atomic)
        report.pulledSidecars += 1
    }

    /// Remove a local thing whose record has gone from the container.
    private func deleteLocally(named recordName: String) -> Bool {
        for recording in library.all()
        where CloudNaming.recordName(.recording, recording.id, key: key) == recordName {
            try? FileManager.default.removeItem(at: recording.folder)
            return true
        }
        for note in library.allNotes()
        where CloudNaming.recordName(.note, note.slug, key: key) == recordName {
            library.deleteNote(note.slug)
            return true
        }
        return false
    }

    // MARK: - The reclaim invariant

    /// Delete this device's audio **only** when a Mac reports that audio on its
    /// own disk. Never when the upload completes.
    ///
    /// Between "upload finished" and "a Mac has ingested it" the only copy of
    /// that recording is an asset in a zone whose entire purpose is to be
    /// purged. Deleting the local copy in that window loses the recording
    /// permanently, and it is the only place in this design where that is
    /// possible.
    ///
    /// `audioOn` is the acknowledgement, and it is the right one because there
    /// is **no separate receipt to lose**: the Mac writes it after the bytes
    /// are on its disk, in the same record this device is already reading.
    private func reclaimIfAcknowledged(_ record: StoredRecord, id: String,
                                       into report: inout CloudReport) async {
        guard !keepAudio, !ingests else { return }
        guard let holder = record.audioOn, holder != device else { return }
        guard let recording = library.find(id), recording.hasAudio else { return }
        let size = (try? FileManager.default.attributesOfItem(
            atPath: recording.micURL.path)[.size] as? Int) ?? 0
        do {
            try FileManager.default.removeItem(at: recording.micURL)
            report.freedBytes += size
        } catch {
            report.errors.append("could not free \(id)")
        }
    }

    // MARK: - Up

    /// Put up anything this device authored that the container does not have.
    public func push(into report: inout CloudReport) async {
        var base = state.base
        defer { state.base = base }

        let mine = library.all()
        if mine.count > 4 { progress?("Checking \(mine.count) recordings") }
        for (index, recording) in mine.enumerated() {
            if mine.count > 4, index % 5 == 0 {
                progress?("Sending \(index + 1) of \(mine.count)")
            }
            let name = CloudNaming.recordName(.recording, recording.id, key: key)
            do {
                let existing = try await store.fetch(name, in: .library)
                var record = try CloudRecords.recording(recording, policy: policy, key: key)
                record.changeTag = existing?.changeTag
                record.audioOn = existing?.audioOn
                record.claimedBy = existing?.claimedBy
                record.claimExpires = existing?.claimExpires

                // A device that holds the audio says so, so the device that
                // does not can stop holding it.
                if recording.hasAudio, ingests { record.audioOn = device }

                if let existing, try sameRecording(existing, as: record) { continue }
                _ = try await store.save(record)
                report.pushedRecordings += 1
            } catch let error as StoreError {
                if case .changedOnServer = error { report.conflicts.append(recording.id) }
                else { report.errors.append("\(recording.id): \(error)") }
            } catch {
                report.errors.append("\(recording.id): \(error.localizedDescription)")
            }
        }

        for note in library.allNotes() {
            let name = CloudNaming.recordName(.note, note.slug, key: key)
            do {
                let existing = try await store.fetch(name, in: .library)
                let theirs = try existing.map { try CloudRecords.openNote($0, key: key) }
                guard decideNote(base: base[note: note.slug], local: note.version,
                                 remote: theirs?.version) == .push else { continue }
                var record = try CloudRecords.note(note, key: key)
                record.changeTag = existing?.changeTag
                _ = try await store.save(record)
                base[note: note.slug] = note.version
                report.pushedNotes += 1
            } catch let error as StoreError {
                if case .changedOnServer = error { report.conflicts.append(note.slug) }
                else { report.errors.append("note \(note.slug): \(error)") }
            } catch {
                report.errors.append("note \(note.slug): \(error.localizedDescription)")
            }
        }

        for name in policy.blobs {
            let url = library.root.appendingPathComponent(name)
            guard let contents = try? Data(contentsOf: url) else { continue }
            let recordName = CloudNaming.recordName(.blob, name, key: key)
            do {
                let existing = try await store.fetch(recordName, in: .library)
                if let existing,
                   try CloudRecords.openBlob(existing, key: key).version == sha256Hex(contents) {
                    continue
                }
                var record = try CloudRecords.blob(name: name, contents: contents, key: key)
                record.changeTag = existing?.changeTag
                _ = try await store.save(record)
            } catch {
                report.errors.append("\(name): \(error.localizedDescription)")
            }
        }
    }

    /// Whether the container's copy already says what ours does.
    ///
    /// Compared on digests rather than on bytes, because the sealed payload is
    /// different every time it is sealed: ChaChaPoly uses a fresh nonce, so two
    /// seals of identical content never match and a byte comparison would push
    /// every record on every pass for ever.
    private func sameRecording(_ existing: StoredRecord,
                               as ours: StoredRecord) throws -> Bool {
        let a = try CloudRecords.openRecording(existing, key: key)
        let b = try CloudRecords.openRecording(ours, key: key)
        return a.digests == b.digests && existing.audioOn == ours.audioOn
    }

    // MARK: - Devices

    /// Say this device is here, and read who else is.
    ///
    /// Its own zone so a heartbeat does not wake every device for the library's
    /// change feed, and **each device writes only its own record**, so there is
    /// no merge to get wrong and no row two machines can fight over.
    @discardableResult
    public func heartbeat(name: String, kind: String, appVersion: String,
                          now: Date = Date()) async -> [CloudRecords.DeviceBlob] {
        let recordName = CloudNaming.recordName(.device, device, key: key)
        do {
            let existing = try await store.fetch(recordName, in: .devices)
            var record = try CloudRecords.device(
                CloudRecords.DeviceBlob(id: device, name: name, kind: kind,
                                        lastSeen: Metadata.stamp(now),
                                        appVersion: appVersion), key: key)
            record.changeTag = existing?.changeTag
            _ = try await store.save(record)
        } catch {
            // A heartbeat that fails is not worth reporting: the device list is
            // a convenience and nothing downstream depends on it being current.
        }
        var everyone: [CloudRecords.DeviceBlob] = []
        if let changes = try? await store.changes(in: .devices, since: nil) {
            for record in changes.changed {
                if let blob = try? CloudRecords.openDevice(record, key: key) {
                    everyone.append(blob)
                }
            }
        }
        return everyone.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: - Voiceprints

    /// Put this device's voiceprints up, for the other Macs.
    ///
    /// A separate zone rather than a filter, because a device subscribes per
    /// zone: this is what makes "the phone never receives one" true rather than
    /// "the phone declines to save one".
    public func pushVoiceprints(into report: inout CloudReport) async {
        guard policy.keepsVoiceprints else { return }
        for recording in library.all() {
            for file in DevicePolicy.voiceprintFiles {
                let url = recording.folder.appendingPathComponent(file)
                guard let contents = try? Data(contentsOf: url) else { continue }
                let name = CloudNaming.recordName(.voiceprint, recording.id, key: key)
                do {
                    let existing = try await store.fetch(name, in: .voiceprints)
                    if let existing,
                       try CloudRecords.openBlob(existing, key: key).version
                           == sha256Hex(contents) { continue }
                    var record = try CloudRecords.voiceprint(id: recording.id,
                                                             contents: contents, key: key)
                    record.changeTag = existing?.changeTag
                    _ = try await store.save(record)
                } catch {
                    report.errors.append("voiceprint \(recording.id): "
                                         + error.localizedDescription)
                }
            }
        }
    }

    /// Take other Macs' voiceprints down. The voice bank has no database and
    /// the set of these files **is** the bank, so a Mac without them cannot
    /// recognise a voice it has already been taught.
    public func pullVoiceprints(into report: inout CloudReport) async {
        guard policy.keepsVoiceprints else { return }
        guard let changes = try? await store.changes(in: .voiceprints, since: nil) else { return }
        for record in changes.changed {
            guard let blob = try? CloudRecords.openBlob(record, key: key),
                  Metadata.isValidID(blob.name) else { continue }
            let folder = library.folder(for: blob.name)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let url = folder.appendingPathComponent("embeddings.json")
            if let have = try? Data(contentsOf: url), sha256Hex(have) == blob.version { continue }
            try? blob.contents.write(to: url, options: .atomic)
            report.pulledSidecars += 1
        }
    }

    // MARK: - Audio in flight

    /// Send a recording this device made, so a Mac can ingest it.
    ///
    /// Its own zone, and deleted after ingest, because it is a pipe and never a
    /// store: a 25 MB asset sitting in the library zone would churn every
    /// device's change feed and eat the user's iCloud quota for something that
    /// exists to be thrown away.
    ///
    /// **This does not free the local audio.** Nothing here does. See
    /// `reclaimIfAcknowledged`, and the reason it keys on a Mac saying it holds
    /// the bytes rather than on this upload finishing.
    public func upload(_ recording: Recording, into report: inout CloudReport) async {
        guard !ingests else { return }
        guard recording.hasAudio, let audio = try? Data(contentsOf: recording.micURL) else { return }
        let metadataURL = recording.folder.appendingPathComponent("metadata.json")
        guard let metadata = try? Data(contentsOf: metadataURL) else { return }
        let name = CloudNaming.recordName(.audioTransfer, recording.id, key: key)
        do {
            if try await store.fetch(name, in: .transfer) != nil { return }
            _ = try await store.save(try CloudRecords.transfer(
                id: recording.id, from: device, metadata: metadata,
                audio: audio, key: key))
            report.pushedRecordings += 1
        } catch {
            report.errors.append("upload \(recording.id): \(error.localizedDescription)")
        }
    }

    /// Ingest whatever is waiting, claiming each before spending anything on it.
    ///
    /// The order is the whole design: claim, then download, then publish, then
    /// say so. A device that downloads first spends the transfer twice when two
    /// Macs are awake; one that says so before the bytes are on disk invites the
    /// phone to delete its only copy.
    public func ingest(preferred: String?, window: TimeInterval = 300,
                       into report: inout CloudReport, now: Date = Date()) async {
        guard ingests else { return }
        guard let changes = try? await store.changes(in: .transfer, since: nil) else { return }

        for record in changes.changed {
            guard let claimed = try? await claim(record, preferred: preferred,
                                                 window: window, now: now), claimed
            else { continue }
            do {
                let blob = try CloudRecords.openTransfer(record, key: key)
                guard Metadata.isValidID(blob.id) else { throw InvalidName.id(blob.id) }
                guard let sealed = record.assets["mic.wav"] else {
                    throw StoreError.unavailable("no audio on the transfer")
                }
                // Sealed exactly once, by `CloudRecords.transfer`. Sealing it
                // again on the way in produced a blob that opened to
                // ciphertext, which a WAV reader accepts as a file it cannot
                // parse rather than reporting as an encryption mistake.
                let audio = try key.open(sealed)

                // Written the way `RecordingWriter` requires: everything else
                // first, `metadata.json` last, so the folder is invisible until
                // it is whole.
                let folder = library.folder(for: blob.id)
                try FileManager.default.createDirectory(at: folder,
                                                        withIntermediateDirectories: true)
                try audio.write(to: folder.appendingPathComponent("mic.wav"), options: .atomic)
                try blob.metadata.write(to: folder.appendingPathComponent("metadata.json"),
                                        options: .atomic)
                report.claimed += 1

                // Only now. This is what lets the phone let go, and the whole
                // reason it is written after the bytes rather than before.
                let recordName = CloudNaming.recordName(.recording, blob.id, key: key)
                if let recording = library.find(blob.id) {
                    var published = try CloudRecords.recording(recording, policy: policy, key: key)
                    published.changeTag = try await store.fetch(recordName, in: .library)?.changeTag
                    published.audioOn = device
                    _ = try await store.save(published)
                }

                // The pipe is emptied only once the library holds it.
                try await store.delete(record.name, in: .transfer)
            } catch {
                report.errors.append("ingest: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Claiming an ingest

    /// Take responsibility for one uploaded recording, before downloading it.
    ///
    /// **Claim first, then download.** Both Macs see the same pending audio,
    /// and the race starts at ingest rather than at transcription: without a
    /// claim, both download the same 25 MB before either writes anything, which
    /// spends the transfer twice and puts `audioOn` in two places.
    ///
    /// The claim also decides where that recording's audio lives **for ever**,
    /// because audio never moves again once it lands. So it decides which
    /// machine can play the memo back and which machine you have to be sitting
    /// at to hear it, which is why first-come-first-served is the wrong default
    /// and a preferred device gets a head start.
    ///
    /// A claim expires so that a Mac which dies mid-ingest does not park a
    /// recording for ever.
    public func claim(_ record: StoredRecord, preferred: String?,
                      window: TimeInterval, now: Date = Date()) async throws -> Bool {
        guard ingests else { return false }

        // Somebody holds it and the hold is still good.
        if let holder = record.claimedBy, holder != device,
           let expires = record.claimExpires, expires > now {
            return false
        }

        // The preferred device gets the window to itself. The fallback matters
        // because the preferred Mac may be shut for a week, and a voice memo
        // should not wait for it.
        if let preferred, preferred != device,
           let uploaded = record.claimExpires.map({ $0.addingTimeInterval(-window) }),
           now.timeIntervalSince(uploaded) < window {
            return false
        }

        var mine = record
        mine.claimedBy = device
        mine.claimExpires = now.addingTimeInterval(window)
        do {
            _ = try await store.save(mine)
            return true
        } catch StoreError.changedOnServer {
            // The other device got there first, and it cost nothing to find out
            // because nothing has been downloaded yet. That is the whole point
            // of claiming before downloading.
            return false
        }
    }
}
