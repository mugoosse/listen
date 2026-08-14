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
    /// Records taken out of the container because this device deleted them.
    public var deletedRemotely = 0
    public var claimed = 0
    public var freedBytes = 0
    public var conflicts: [String] = []
    public var errors: [String] = []

    public var didSomething: Bool {
        pushedRecordings + pulledRecordings + pulledSidecars + pushedNotes
            + pulledNotes + deletedLocally + deletedRemotely + claimed > 0 || freedBytes > 0
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
        if deletedRemotely > 0 { parts.append("deleted \(deletedRemotely) everywhere") }
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
        state.repairSuppressedRecordingPushesOnce()
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
                    case .recording:
                        // Do not stamp the local folder as sent here. A pull
                        // writes only the files named by the remote manifest
                        // and deliberately leaves any other local sidecars in
                        // place. The folder can therefore be richer than what
                        // arrived. Marking that richer stamp as sent hides a
                        // transcript written after the previous push, and the
                        // following push never repairs the cloud record. Let
                        // push fetch and compare once; an exact match is still
                        // a no-op, while a richer folder is sent.
                        let id = try await pullRecording(record, into: &report)
                        if !ingests, let holder = record.audioOn, holder != device {
                            base[sent: "audio:" + id] = "acknowledged"
                        }
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
                if deleteLocally(named: name, base: &base) { report.deletedLocally += 1 }
                seen.remove(name)
            }

            base[file: "token"] = changes.token
        } catch {
            report.errors.append(error.localizedDescription)
        }
    }

    @discardableResult
    private func pullRecording(_ record: StoredRecord,
                               into report: inout CloudReport) async throws -> String {
        let blob = try CloudRecords.openRecording(record, key: key)
        guard Metadata.isValidID(blob.id) else { throw InvalidName.id(blob.id) }
        let folder = library.folder(for: blob.id)
        let isNew = Recording.load(folder) == nil

        // Sidecars first, metadata last, and only what this device keeps.
        for file in policy.files(for: blob.id) where file != "metadata.json" {
            // On disk it keeps its real name; in the record it may not. See
            // `CloudRecords.assetKey`.
            let stored = CloudRecords.assetKey(file, id: blob.id)
            guard let want = blob.digests[stored] else { continue }
            let local = folder.appendingPathComponent(file)
            if let have = try? Data(contentsOf: local), sha256Hex(have) == want { continue }
            let data: Data?
            if file == DevicePolicy.sourceIcon {
                data = blob.sourceIcon
            } else {
                data = try CloudRecords.openAsset(record, stored, key: key)
            }
            guard let data else { continue }
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
        return blob.id
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
    /// Apply a deletion the container reported.
    ///
    /// Clears this device's own record of having sent the thing, which is what
    /// stops `pushDeletions` from turning an obeyed deletion into an outgoing
    /// one: without it the next push would ask the container to delete a record
    /// that is already gone, on every device, every pass, for ever.
    private func deleteLocally(named recordName: String, base: inout SyncState) -> Bool {
        // Moved, not removed. A deletion arriving over sync was made on some
        // other device, and this one cannot tell a deliberate one from a bug or
        // from a library that briefly looked empty. See `Trash`.
        for recording in library.all()
        where CloudNaming.recordName(.recording, recording.id, key: key) == recordName {
            Trash.accept(recording.folder, in: library)
            base[sent: recording.id] = nil
            return true
        }
        for note in library.allNotes()
        where CloudNaming.recordName(.note, note.slug, key: key) == recordName {
            Trash.accept(library.notes.appendingPathComponent(note.slug + ".md"),
                         in: library)
            base[note: note.slug] = nil
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

        // Only the ones that have changed since this device last sent them.
        //
        // Every recording used to be sealed and then asked about, on every
        // pass, for ever. On a phone with 71 recordings on cellular that was
        // minutes of encrypting files that had not changed and a round trip
        // each to be told so, while the screen said "Sending 71 of 71" and the
        // pull the person was waiting for had not begun. The stamp is local and
        // costs a read; see `CloudRecords.recordingStamp` for what is in it and
        // why `hasAudio` had to be.
        let stamps = library.all().map { ($0, CloudRecords.recordingStamp($0, policy: policy)) }
        let mine = stamps.filter { base[sent: $0.0.id] != $0.1 }
        if mine.count > 4 { progress?("Checking \(mine.count) recordings") }
        for (index, pair) in mine.enumerated() {
            let (recording, stamp) = pair
            if mine.count > 4, index % 5 == 0 {
                progress?("Sending \(index + 1) of \(mine.count)")
            }
            let name = CloudNaming.recordName(.recording, recording.id, key: key)
            do {
                let existing = try await store.fetch(name, in: .library)
                var record = try CloudRecords.recording(recording, policy: policy, key: key)
                if let existing, !ingests {
                    record = try CloudRecords.addingPhoneContent(record, to: existing, key: key)
                }
                record.changeTag = existing?.changeTag
                record.audioOn = existing?.audioOn
                record.claimedBy = existing?.claimedBy
                record.claimExpires = existing?.claimExpires

                // A device that holds the audio says so, so the device that
                // does not can stop holding it.
                if recording.hasAudio, ingests { record.audioOn = device }

                // Recorded only after the container agrees, either because it
                // already held this or because the save landed. A failure
                // leaves no stamp, so the next pass tries again.
                if let existing, try sameRecording(existing, as: record) {
                    base[sent: recording.id] = stamp
                    continue
                }
                _ = try await store.save(record)
                base[sent: recording.id] = stamp
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

                // Gone from the container, and we agreed on what was there.
                //
                // That is somebody else's deletion, not a note this device has
                // yet to send, and the two are only distinguishable by the
                // base: a note never pushed has none. Without this the deleting
                // device removes the record and the next device to push puts it
                // straight back, so a deleted note returns and nothing reports
                // anything. Recordings are safe from this by their stamps,
                // which match without a fetch; notes have no stamp.
                //
                // Ordinarily the pull earlier in the same pass has already
                // applied the deletion. This is for the pass whose pull failed
                // on the network and whose push ran anyway.
                if existing == nil, let agreed = base[note: note.slug], agreed == note.version {
                    library.deleteNote(note.slug)
                    base[note: note.slug] = nil
                    report.deletedLocally += 1
                    continue
                }

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

        await pushDeletions(&base, into: &report)
    }

    /// Take out of the container what this device has deleted.
    ///
    /// Deletion was receive-only until now: `deleteLocally` applied what the
    /// container reported, and nothing reported the other way. So a recording
    /// deleted in the Mac app went from that Mac and stayed in the container
    /// and on every other device for ever, and the change token being
    /// incremental was the only reason it did not immediately come back. Found
    /// by deleting one recording and counting: 71 on this Mac, 72 in the
    /// container. The offline suite passed throughout, because the seam it
    /// covered called `store.delete` itself and then checked the receiving
    /// device, which tests half a round trip.
    ///
    /// **A local absence is only a deletion if the folder is gone.** Not if it
    /// merely fails to load: `Library.all` is a compactMap over `Recording
    /// .load`, so one unreadable `metadata.json` looks exactly like a deleted
    /// recording, and treating it as one would delete the last good copy of a
    /// meeting from every device at once. Checking the directory is what makes
    /// a corrupt sidecar cost nothing.
    ///
    /// The stamps are what make this answerable at all. An id this device has
    /// pushed and no longer holds was deleted here; an id it has never pushed
    /// is not this device's to speak about, which is also why nothing is
    /// deleted on the first pass after the stamps arrive.
    private func pushDeletions(_ base: inout SyncState, into report: inout CloudReport) async {
        let manager = FileManager.default
        var drop: [String] = []

        // A library that has lost everything is not a library that deleted
        // everything.
        //
        // This is the failure it exists to stop, and it happened: a scratch
        // library was removed and recreated at the same path, its state
        // directory survived because that is keyed on the path, and the next
        // pass saw a stamp for every recording and a folder for none. It
        // deleted seventy-three recordings and fourteen notes from the
        // container, both Macs followed, and the recovery was a backup.
        //
        // Nothing about that required a scratch library. A disk that fails to
        // mount, a library restored underneath a running app, a folder moved
        // in the Finder: each of them presents as "everything is gone" and each
        // would have propagated. One person deleting one meeting looks nothing
        // like this, so the two are worth telling apart even though the check
        // is crude.
        //
        // Refuse rather than ask, and report it, because a sync engine that is
        // this unsure of itself should not be the thing that decides.
        var missingRecordings = 0, missingNotes = 0
        for key in base.base.keys {
            if key.hasPrefix(SyncState.sentKey("")) {
                let id = String(key.dropFirst(SyncState.sentKey("").count))
                guard !id.hasPrefix("audio:") else { continue }
                if !manager.fileExists(atPath: library.folder(for: id).path) {
                    missingRecordings += 1
                }
            } else if key.hasPrefix(SyncState.noteKey("")) {
                let slug = String(key.dropFirst(SyncState.noteKey("").count))
                if !manager.fileExists(
                    atPath: library.notes.appendingPathComponent(slug + ".md").path) {
                    missingNotes += 1
                }
            }
        }
        let heldRecordings = library.all().count
        let heldNotes = library.allNotes().count

        // Per kind, not in total. The first attempt compared everything to
        // everything, and the notes that survived kept the total above zero
        // while every recording had gone, which is the exact shape of the
        // event this is here to stop.
        //
        // Vanishing entirely is the signal. More than one, because deleting
        // your last remaining recording is a thing somebody may genuinely do
        // and is indistinguishable from it otherwise.
        let gone = (heldRecordings == 0 && missingRecordings > 1)
            || (heldNotes == 0 && missingNotes > 1)
            || (missingRecordings + missingNotes > 5
                && missingRecordings + missingNotes > heldRecordings + heldNotes)
        if gone {
            report.errors.append(
                "\(missingRecordings + missingNotes) items are missing from this "
                + "device and only \(heldRecordings + heldNotes) remain, so nothing "
                + "was deleted from iCloud. If you meant to empty this library, "
                + "remove its sync state.")
            return
        }

        for key in base.base.keys where key.hasPrefix(SyncState.sentKey("")) {
            let id = String(key.dropFirst(SyncState.sentKey("").count))
            // `sent:audio:<id>` marks an upload, not a recording this device
            // claims to hold, and an upload is deleted by whoever ingests it.
            if id.hasPrefix("audio:") { continue }
            guard !manager.fileExists(atPath: library.folder(for: id).path) else { continue }
            do {
                try await store.delete(CloudNaming.recordName(.recording, id, key: self.key),
                                       in: .library)
                report.deletedRemotely += 1
                drop.append(key)
            } catch {
                report.errors.append("delete \(id): \(error.localizedDescription)")
            }
        }

        for key in base.base.keys where key.hasPrefix(SyncState.noteKey("")) {
            let slug = String(key.dropFirst(SyncState.noteKey("").count))
            let file = library.notes.appendingPathComponent(slug + ".md")
            guard !manager.fileExists(atPath: file.path) else { continue }
            do {
                try await store.delete(CloudNaming.recordName(.note, slug, key: self.key),
                                       in: .library)
                report.deletedRemotely += 1
                drop.append(key)
            } catch {
                report.errors.append("delete note \(slug): \(error.localizedDescription)")
            }
        }

        for key in drop { base.base[key] = nil }
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
    /// Take one device off the list now, rather than waiting a month.
    ///
    /// It comes back if that device is still running: a device record is a
    /// heartbeat, not a permission, and nothing about sync consults this list.
    /// So this is a tidy-up, and cannot lock anybody out by being wrong.
    public func forgetDevice(_ id: String) async throws {
        try await store.delete(CloudNaming.recordName(.device, id, key: key), in: .devices)
    }

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
                guard let blob = try? CloudRecords.openDevice(record, key: key) else { continue }

                // Devices that have said nothing for a month are dropped.
                //
                // Nothing ever removed one, so the list only grew: six rows for
                // three machines, three of them called "iPhone", because a
                // device's identity is generated per install and every phone
                // install after the first arrived as somebody new. A list that
                // cannot be trusted to describe your devices is worse than no
                // list, since the only thing it is for is answering "did that
                // reach my other Mac".
                //
                // A month rather than a week: a laptop left shut over a holiday
                // is not a laptop you have thrown away, and the cost of being
                // wrong is that it reappears when it is next opened.
                if let when = Metadata.parser.date(from: blob.lastSeen),
                   now.timeIntervalSince(when) > 30 * 86_400, blob.id != device {
                    try? await store.delete(record.name, in: .devices)
                    continue
                }
                everyone.append(blob)
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

        // Remember a Mac's acknowledgement permanently, because the transfer
        // record is deleted on purpose the moment a Mac takes the audio.
        //
        // Until that acknowledgement arrives, a remembered upload is not
        // durable proof. If the transfer has disappeared while this phone still
        // owns the bytes, recreate it. Once acknowledged, keep-audio phones can
        // retain their WAVs without re-sending the whole library every pass.
        var base = state.base
        let sentKey = "audio:" + recording.id
        if base[sent: sentKey] == "acknowledged" { return }

        let metadataURL = recording.folder.appendingPathComponent("metadata.json")
        guard let metadata = try? Data(contentsOf: metadataURL) else { return }
        let name = CloudNaming.recordName(.audioTransfer, recording.id, key: key)
        do {
            if try await store.fetch(name, in: .transfer) != nil { return }
            _ = try await store.save(try CloudRecords.transfer(
                id: recording.id, from: device, metadata: metadata,
                audio: audio, key: key))
            base[sent: sentKey] = "1"
            state.base = base
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
