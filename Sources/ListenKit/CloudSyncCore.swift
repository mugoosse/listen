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
    /// Audio masters published by this device, and taken down by it. Counted
    /// apart from recordings because one of them is 25 MB, and a person
    /// watching a pass deserves to know which kind of work it is doing.
    public var pushedMasters = 0
    public var pulledMasters = 0
    public var freedBytes = 0
    public var conflicts: [String] = []
    public var errors: [String] = []

    public var didSomething: Bool {
        pushedRecordings + pulledRecordings + pulledSidecars + pushedNotes
            + pulledNotes + deletedLocally + deletedRemotely + claimed
            + pushedMasters + pulledMasters > 0 || freedBytes > 0
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
        if pushedMasters > 0 { parts.append("sent audio for \(pushedMasters)") }
        if pulledMasters > 0 { parts.append("got audio for \(pulledMasters)") }
        if freedBytes > 0 { parts.append("freed \(freedBytes / 1_048_576) MB") }
        return parts.joined(separator: ", ")
    }

    public init() {}
}

/// What is happening to one recording right now.
///
/// Shared by both apps so a phone upload and a Mac transcription use the same
/// state vocabulary. `fraction` is present only when the device observing the
/// work has a real measured value. A remote Mac's chunk progress is not
/// invented on the iPhone.
public struct CloudActivity: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        case uploadingAudio
        case waitingForMac
        case downloadingAudio
        case downloadingTranscript
        case queued
        case startingTranscription
        case transcribing
        case sendingTranscript
        case transcribingElsewhere
        case retrying
        case ready
        case failed
    }

    public var recordingID: String
    public var stage: Stage
    public var fraction: Double?
    public var detail: String?

    public init(recordingID: String, stage: Stage,
                fraction: Double? = nil, detail: String? = nil) {
        self.recordingID = recordingID
        self.stage = stage
        self.fraction = fraction.map { min(1, max(0, $0)) }
        self.detail = detail
    }

    public var title: String {
        switch stage {
        case .uploadingAudio: return "Uploading audio"
        case .waitingForMac: return detail ?? "Waiting for your Mac"
        case .downloadingAudio: return "Downloading audio"
        case .downloadingTranscript: return "Downloading transcript"
        case .queued: return "Queued for transcription"
        case .startingTranscription: return "Starting transcription"
        case .transcribing: return detail ?? "Transcribing"
        case .sendingTranscript: return "Syncing transcript"
        case .transcribingElsewhere: return detail ?? "Transcribing on another Mac"
        case .retrying: return "Retrying sync"
        case .ready: return "Ready"
        case .failed: return "Could not finish"
        }
    }

    public var percentage: String? {
        fraction.map { "\(Int(($0 * 100).rounded()))%" }
    }

    public var isFailure: Bool { stage == .failed }

    public var isMoving: Bool {
        switch stage {
        case .uploadingAudio, .downloadingAudio, .downloadingTranscript,
             .startingTranscription, .transcribing, .sendingTranscript,
             .transcribingElsewhere, .retrying:
            return true
        case .waitingForMac, .queued, .ready, .failed:
            return false
        }
    }
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
    /// Take the change feed in two halves: the rows first, the contents
    /// after, so a library appears while it is still arriving.
    ///
    /// **Off for a device that ingests.** Between the two halves this device
    /// holds a recording whose transcript is in the container and not on this
    /// disk, and a push in that window would replace the record with the half
    /// it has. A phone is safe from that twice over, by `addingPhoneContent`
    /// and by the `owed` skip in `push`; a Mac has only the second, and the
    /// Mac is not the device anybody is watching a first sync on.
    let progressive: Bool

    /// True when this device has been asked to keep a copy of the audio.
    ///
    /// Two things at once, and they are the same switch seen from each side.
    /// On, this device fetches the master for anything it does not already
    /// have audio for, and never frees what it holds. Off, it fetches nothing
    /// and frees a local copy as soon as another device that *is* keeping
    /// audio says it holds those bytes. See `reclaim`.
    let keepAudio: Bool

    /// Said out loud as the pass runs, so a screen can show something moving.
    ///
    /// A first sync fetches every recording a library has, which on a real
    /// library is a minute of a spinner saying "Syncing…" and nothing else.
    /// That is indistinguishable from stuck, and a person watching it has no
    /// way to tell whether to wait or to give up.
    let progress: (@Sendable (String) -> Void)?
    /// Per-recording progress for the library row and recording page.
    let activity: (@Sendable (CloudActivity) -> Void)?
    /// Something is on disk that was not there a moment ago, said **during**
    /// the pass rather than at the end of it.
    ///
    /// The report at the end is what decides whether anything happened; this
    /// is what makes a first sync a library filling up rather than a spinner
    /// followed by seventy rows at once.
    let arrived: (@Sendable () -> Void)?

    public init(library: Library, state: EngineState, store: any RecordStore,
                key: PairingKey, policy: DevicePolicy, device: String,
                ingests: Bool, keepAudio: Bool = false, progressive: Bool = false,
                progress: (@Sendable (String) -> Void)? = nil,
                activity: (@Sendable (CloudActivity) -> Void)? = nil,
                arrived: (@Sendable () -> Void)? = nil) {
        state.repairSuppressedRecordingPushesOnce()
        self.library = library; self.state = state; self.store = store
        self.key = key; self.policy = policy; self.device = device
        self.ingests = ingests; self.keepAudio = keepAudio
        self.progressive = progressive && !ingests
        self.progress = progress
        self.activity = activity
        self.arrived = arrived
    }

    private func reportActivity(_ id: String, _ stage: CloudActivity.Stage,
                                fraction: Double? = nil, detail: String? = nil) {
        activity?(CloudActivity(recordingID: id, stage: stage,
                                fraction: fraction, detail: detail))
    }

    // MARK: - Down

    /// Take everything the container has that this device does not.
    ///
    /// `metadata.json` is written **last** for every recording, for the reason
    /// `RecordingWriter` exists: a folder without it does not load, and
    /// `Library.all` is a compactMap over `load`, so a recording arriving is
    /// invisible rather than half-present and a pull that dies halfway leaves
    /// nothing to clean up.
    ///
    /// **A progressive pull inverts that on purpose**, and pays for it. It
    /// takes the feed without the asset bodies, so metadata is all there is to
    /// write and a recording becomes visible with no transcript behind it.
    /// What used to be "invisible until whole" becomes "listed, and still
    /// arriving", which is a state the screen has to be able to say out loud:
    /// see `CloudActivity.downloadingTranscript`. The debt is written down in
    /// `SyncState.owed` before the token moves, because the change feed will
    /// not mention that record again, and it is settled by
    /// `collectOwedSidecars` at the end of this same pass. A pass that dies
    /// halfway leaves rows with no contents and a note of what to go back for,
    /// rather than nothing to clean up.
    public func pull(into report: inout CloudReport, now: Date = Date()) async {
        var seen = state.everSeen
        var base = state.base
        defer { state.everSeen = seen; state.base = base }

        do {
            let changes = try await store.changes(in: .library, since: base[file: "token"],
                                                  withAssets: !progressive)

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
                        let pulled = try await pullRecording(record, base: &base,
                                                             into: &report)
                        let id = pulled.id
                        // Remember who holds the audio even when that is
                        // nobody. A device without the bytes had no way to
                        // name the device with them, so the window inferred it
                        // from `metadata.source` and told a two-Mac library
                        // that every phone recording was on its way *here*.
                        // For one that another Mac had claimed hours earlier
                        // that sentence was false in the only way that
                        // matters: it named a machine that was never going to
                        // do anything, and hid the one that owed the work.
                        base[audioOn: id] = record.audioOn
                        if !ingests, let holder = record.audioOn, holder != device {
                            // A claim is not a delivery, and the difference is
                            // what stops a Mac parking a recording for ever.
                            // See `audioMarker`.
                            base[sent: "audio:" + id] = pulled.delivered
                                ? CloudSyncCore.acknowledged
                                : CloudSyncCore.claimed(at: now)
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
            if report.didSomething { arrived?() }
        } catch {
            report.errors.append(error.localizedDescription)
        }

        // Contents after rows, and inside the same pass, so one pull is still
        // one pull as far as its report and its caller are concerned.
        await collectOwedSidecars(&base, into: &report)
        await askWhoHoldsTheWaiting(&base)
    }

    /// Go back for the contents of every recording whose row has already
    /// arrived.
    ///
    /// The second half of a progressive pull, and the reason the first half is
    /// allowed to write a recording with nothing in it. One fetch per
    /// recording, newest first, each one reported as it moves so the row it
    /// belongs to can say what it is doing rather than the whole screen saying
    /// it once.
    ///
    /// Uncapped, unlike `askWhoHoldsTheWaiting`. That one asks a question it
    /// can afford to ask again next pass; this one is a debt, and the bytes it
    /// fetches are the same bytes a single-phase pull would have fetched
    /// before showing anything at all. A pass cut short leaves the rest owed,
    /// and the next pass picks them up in the same order.
    ///
    /// Nothing is cleared on failure. A recording whose fetch fails is still
    /// owed, which is what makes this self-repairing across passes; the two
    /// things that do clear a debt are a record that has gone from the
    /// container and a folder that has gone from this device.
    private func collectOwedSidecars(_ base: inout SyncState,
                                     into report: inout CloudReport) async {
        let owing = base.owing
        guard !owing.isEmpty else { return }
        if owing.count > 1 { progress?("Fetching \(owing.count) transcripts") }
        for (index, id) in owing.enumerated() {
            guard FileManager.default.fileExists(atPath: library.folder(for: id).path) else {
                base[owed: id] = false
                continue
            }
            if owing.count > 1 { progress?("Transcript \(index + 1) of \(owing.count)") }
            reportActivity(id, .downloadingTranscript, fraction: 0)
            let name = CloudNaming.recordName(.recording, id, key: key)
            do {
                let record = try await store.fetch(name, in: .library, progress: { value in
                    activity?(CloudActivity(recordingID: id,
                                            stage: .downloadingTranscript,
                                            fraction: value))
                })
                guard let record else {
                    // Deleted while this device was holding its row. The
                    // deletion itself arrives through the feed; there is
                    // simply nothing left to collect.
                    base[owed: id] = false
                    reportActivity(id, .ready, fraction: 1)
                    continue
                }
                let blob = try CloudRecords.openRecording(record, key: key)
                let outcome = try writeSidecars(blob, from: record, base: &base, into: &report)
                // Whatever the manifest still names and this record still did
                // not carry is not a debt any more: the record came whole this
                // time, so anything absent is absent from the container.
                base[owed: id] = false
                base[audioOn: id] = record.audioOn
                if outcome.written > 0 { arrived?() }
                reportActivity(id, .ready, fraction: 1)
            } catch {
                report.errors.append("\(id): \(error.localizedDescription)")
                reportActivity(id, .retrying, detail: error.localizedDescription)
            }
        }
    }

    /// Ask, for the few recordings this device is waiting on, which device
    /// holds their audio.
    ///
    /// The change feed cannot answer this. It reports what has changed since a
    /// token, and a recording that is stuck is precisely one whose record is
    /// **not** changing: the Mac that claimed it published once and then went
    /// quiet. So the device that most needs to say where the audio went is the
    /// one the pull will never tell. Found immediately after adding
    /// `audioOn:<id>` to the pull, on the recording that prompted all of this:
    /// zero keys written, because nothing had moved in the container since.
    ///
    /// Waiting is "no audio here and no transcript here", which is the exact
    /// set somebody is looking at a spinner over. It is normally empty or one,
    /// and it is capped at eight newest-first so that a Mac midway through its
    /// first sync spends eight fetches rather than one per recording it has yet
    /// to receive. Nothing is written for a record that cannot be fetched, and
    /// an unclaimed recording is asked about again next pass, because "nobody
    /// holds it yet" is a state that changes.
    private func askWhoHoldsTheWaiting(_ base: inout SyncState) async {
        let waiting = library.all()
            .filter { !$0.hasAudio && !$0.hasTranscript }
            .prefix(8)
        for recording in waiting {
            let name = CloudNaming.recordName(.recording, recording.id, key: key)
            guard let record = try? await store.fetch(name, in: .library) else { continue }
            base[audioOn: recording.id] = record.audioOn
        }
    }

    /// What a pull of one recording leaves the caller needing to know.
    ///
    /// `delivered` is whether the record carries work made *from* the audio,
    /// which is a different question from whether a device holds the audio and
    /// is the one a phone has to ask before it stops offering its copy.
    struct Pulled { var id: String; var delivered: Bool }

    @discardableResult
    private func pullRecording(_ record: StoredRecord, base: inout SyncState,
                               into report: inout CloudReport) async throws -> Pulled {
        let blob = try CloudRecords.openRecording(record, key: key)
        guard Metadata.isValidID(blob.id) else { throw InvalidName.id(blob.id) }
        let folder = library.folder(for: blob.id)
        let isNew = Recording.load(folder) == nil

        // Sidecars first, metadata last. See `pull` for what a progressive
        // pull does to that order and what it writes down instead.
        let outcome = try writeSidecars(blob, from: record, base: &base, into: &report)
        // Written down before the token moves, because the change feed will
        // never mention this record again and this is the only thing that
        // will remember the transcript is still out there.
        base[owed: blob.id] = outcome.owed

        let metadataURL = folder.appendingPathComponent("metadata.json")
        let have = try? Data(contentsOf: metadataURL)

        // **The device holding the audio authors this document from ingest
        // onwards, and a pull must not write over it.**
        //
        // `ingest` publishes the phone's `metadata.json` verbatim, because at
        // that instant the phone is still the author. The pipeline then runs
        // here and rewrites the file: `state` leaves `pending`, `asr_model`
        // and `room` are decided, `AutoTitle` may name it. The record still
        // carries the pre-ingest snapshot until the next push, so the pull in
        // between was handing this Mac its own recording back with the state
        // reset, and the push that followed republished `pending` for work
        // that had finished hours earlier. Measured on the memo in
        // `.agents/notes/cloud-sync.md`: the record read `state pending` for a
        // recording that was transcribed, diarized and speaker-labelled.
        //
        // Narrow on purpose. Every other device still stores the bytes
        // verbatim, which is the rule in `CLAUDE.md` and is what keeps fields
        // this build has never heard of alive. This is the one device the rule
        // was wrong about, and `audioOn` is how it says so rather than a guess
        // from `metadata.source`. It cannot lose a phone edit either: a rename
        // on the phone already loses to `addingPhoneContent` on the way up.
        let authored = have != nil && record.audioOn == device
        if !authored, have.map(sha256Hex) != blob.digests["metadata.json"] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Verbatim. The bytes the authoring device wrote, not a
            // re-encoding of them through whatever struct this device happens
            // to model. See `DevicePolicy`.
            try blob.metadata.write(to: metadataURL, options: .atomic)
            if isNew { report.pulledRecordings += 1 }
        }

        // Nothing is freed here. A pull applies what arrived; letting go of
        // the only other copy of a recording is a decision about the whole
        // device roster and it is taken once a pass, in `reclaim`. It used to
        // live in this function and could therefore only ever be reconsidered
        // when a recording's own record changed, which is exactly what a
        // stalled recording's record does not do. `askWhoHoldsTheWaiting`
        // below exists because of the same blind spot.

        // Work made from the audio, rather than a device holding the audio.
        // A transcript is the usual evidence; a finished state is the other
        // half, because a recording with no speech in it never gains a
        // transcript and would otherwise look like a Mac that had done nothing
        // for ever. See `.agents/notes/asr.md`, "A silent track must not cost a
        // transcript".
        //
        // `transcribing` is deliberately not finished. It says a Mac started,
        // which is the claim itself restated, and a run that dies leaves it
        // behind: believing it would rebuild the latch this replaces.
        let state = (try? JSONDecoder().decode(Metadata.self, from: blob.metadata))
            .flatMap { $0.state }.flatMap(Metadata.State.init(rawValue:))
        let finished: Set<Metadata.State> = [.needs_labelling, .done, .failed]
        let delivered = blob.digests["transcript.json"] != nil
            || state.map(finished.contains) == true
        if outcome.owed {
            // Listed, and still arriving. This is what the row says until
            // `collectOwedSidecars` reaches it, which is in this same pass.
            reportActivity(blob.id, .downloadingTranscript, fraction: 0)
        } else if delivered {
            reportActivity(blob.id, .ready, fraction: 1)
        }
        return Pulled(id: blob.id, delivered: delivered)
    }

    /// What one record's sidecars did.
    struct Sidecars {
        var written = 0
        /// A file the container holds, that this device keeps, and that this
        /// record arrived without. Only a progressive pull produces one.
        var owed = false
    }

    /// Write every sidecar in this record that this device keeps and does not
    /// already hold, and say what was left behind.
    ///
    /// Shared by both halves of a progressive pull deliberately. The second
    /// half runs exactly this against the same record fetched whole, so there
    /// is one three-way decision about a transcript rather than two that can
    /// drift apart.
    private func writeSidecars(_ blob: CloudRecords.RecordingBlob,
                               from record: StoredRecord,
                               base: inout SyncState,
                               into report: inout CloudReport) throws -> Sidecars {
        var outcome = Sidecars()
        let folder = library.folder(for: blob.id)
        // Only what this device keeps.
        for file in policy.files(for: blob.id) where file != "metadata.json" {
            // On disk it keeps its real name; in the record it may not. See
            // `CloudRecords.assetKey`.
            let stored = CloudRecords.assetKey(file, id: blob.id)
            guard let want = blob.digests[stored] else { continue }
            let local = folder.appendingPathComponent(file)
            let have = (try? Data(contentsOf: local)).map(sha256Hex)
            if have == want {
                // Agreement, which is worth writing down: it is the base every
                // later disagreement is read against.
                base[sidecar: blob.id, file: file] = want
                continue
            }

            // **A local file that differs from the container is not
            // automatically the older one.**
            //
            // This is a three-way decision and it used to be a two-way one, so
            // a transcript corrected on this Mac was overwritten by the
            // container's copy of it on the next pull. The pull runs before the
            // push, so until the push lands the container still holds what this
            // device had before the edit, and a second Mac pushing its own copy
            // is enough to bring that record round again. Measured on a real
            // library: a speaker corrected at 21:27:19, `transcript.json` and
            // `turns.json` rewritten at 21:28:14 with the pre-edit copy, and
            // `metadata.json` left at 21:27 because it had not changed. See
            // `SyncState`, which is the file that already knew this about
            // notes.
            //
            // So: local matches what we last agreed, take the remote; local has
            // moved since then, keep it and let the push carry it. Unknown is
            // the migration case and takes the remote, which is what this did
            // before per-file bases existed.
            if let have, let agreed = base[sidecar: blob.id, file: file], agreed != have {
                report.conflicts.append("\(blob.id)/\(file): edited here and not yet sent")
                continue
            }
            let data: Data?
            if file == DevicePolicy.sourceIcon {
                data = blob.sourceIcon
            } else {
                data = try CloudRecords.openAsset(record, stored, key: key)
            }
            guard let data else {
                // The manifest names a file this record did not carry, which
                // is what the feed looks like when it was asked for without
                // its asset bodies. Not the icon: that travels inside the
                // payload and is never the half left behind, so treating a
                // missing one as a debt would mean re-fetching the record on
                // every pass for ever.
                if file != DevicePolicy.sourceIcon { outcome.owed = true }
                continue
            }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: local, options: .atomic)
            base[sidecar: blob.id, file: file] = want
            outcome.written += 1
            report.pulledSidecars += 1
        }
        return outcome
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
            base.forgetSidecars(recording.id)
            base[owed: recording.id] = false
            base[audioOn: recording.id] = nil
            base[master: recording.id] = nil
            base[pinned: recording.id] = false
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

    /// Free this device's audio **only** for recordings another live device
    /// says it is keeping. Never when an upload completes, and never on the
    /// strength of the container holding a copy.
    ///
    /// Between "upload finished" and "another device has it" the only copy of
    /// that recording can be an asset in a zone whose entire purpose is to be
    /// purged. Deleting the local copy in that window loses the recording
    /// permanently, and it is the only place in this design where that is
    /// possible.
    ///
    /// **What changed, and why `audioOn` was not enough any more.** `audioOn`
    /// is one string on the recording, written by whichever Mac ingested it
    /// and true for ever afterwards, including after that Mac has been wiped,
    /// sold or reinstalled. It also only ever answers for the ingest, so it
    /// could authorise a phone to let go and could say nothing at all about
    /// two Macs. `holdsAudio` is a list republished from disk on every
    /// heartbeat, so it goes stale the way a heartbeat does rather than the
    /// way a latch does, and it answers for every device.
    ///
    /// Three conditions, and each one is load-bearing:
    ///
    /// - **Another device, live.** A week without a heartbeat and its list
    ///   stops being evidence: see `DeviceBlob.isLive`.
    /// - **That device keeps audio.** Otherwise two devices that are both
    ///   trying to get rid of the same recording each read the other as a safe
    ///   holder and delete on the same pass. That is mutual deletion of the
    ///   only two copies, and it is the exact failure this whole invariant is
    ///   about. A device that is keeping audio is not going to change its
    ///   mind inside one pass.
    /// - **Nothing is still owed on it here.** A device that transcribes does
    ///   not free audio it has yet to produce a transcript from, and the
    ///   caller names anything the queue is holding. Without the first, a Mac
    ///   with the switch off would ingest a memo and delete it before the job
    ///   started, and the phone would offer it again six hours later, for ever.
    ///
    /// `protecting` is the queue's, and it is a parameter rather than a lookup
    /// because `CloudSyncCore` runs identically on a phone that has no queue.
    public func reclaim(_ devices: [CloudRecords.DeviceBlob],
                        protecting: Set<String> = [],
                        into report: inout CloudReport, now: Date = Date()) async {
        guard !keepAudio else { return }
        let holders = keepers(devices, now: now)
        guard !holders.isEmpty else { return }

        let base = state.base
        for recording in library.all() where recording.hasAudio {
            guard holders.contains(recording.id), !protecting.contains(recording.id) else {
                continue
            }
            // Asked for by hand, one recording at a time. The device-wide
            // switch is a policy and this is an instruction; without the
            // difference, a phone with **Keep audio** off could never be given
            // one meeting to listen to, because the next pass would take it
            // straight back and the button would appear not to work.
            if base[pinned: recording.id] { continue }
            // A device that transcribes keeps the audio until there is
            // something made from it. `delivered` is the same test a pull
            // makes on an arriving record, and for the same reason: a
            // recording with no speech in it never gains a transcript, so a
            // finished state is the second half of it rather than a fallback.
            if ingests, !delivered(recording) { continue }
            for url in recording.audioFiles {
                let size = (try? FileManager.default.attributesOfItem(
                    atPath: url.path)[.size] as? Int) ?? 0
                do {
                    try FileManager.default.removeItem(at: url)
                    report.freedBytes += size
                } catch {
                    report.errors.append("could not free \(recording.id)")
                }
            }
        }
    }

    /// The recordings held by another device that is both live and keeping its
    /// audio. The only set anything is allowed to be deleted on.
    private func keepers(_ devices: [CloudRecords.DeviceBlob],
                         now: Date) -> Set<String> {
        var held: Set<String> = []
        for blob in devices where blob.id != device && blob.keeps && blob.isLive(now) {
            held.formUnion(blob.holdsAudio ?? [])
        }
        return held
    }

    /// Whether anything has been made from this recording's audio yet.
    ///
    /// A transcript is the usual evidence and a finished state is the other
    /// half, because a recording with no speech in it never gains a transcript
    /// and would otherwise read as work nobody had done. `transcribing` is
    /// deliberately not finished: it says a run started, and a run that dies
    /// leaves it behind.
    private func delivered(_ recording: Recording) -> Bool {
        if recording.hasTranscript { return true }
        let finished: Set<Metadata.State> = [.needs_labelling, .done, .failed]
        guard let raw = recording.metadata.state,
              let state = Metadata.State(rawValue: raw) else { return false }
        return finished.contains(state)
    }

    // MARK: - The audio master

    /// How many masters one pass builds, sends or fetches.
    ///
    /// Three. Building one is an encode of the whole recording and sending it
    /// is tens of megabytes; a library meeting this for the first time has
    /// forty to make, and doing them all inside one pass would be an hour of
    /// CPU and 1.7 GB of upload during which no other part of the sync runs.
    /// Three a pass against a two-minute poll is the whole library within the
    /// hour, in the background, with everything else still moving.
    static let masterBatch = 3

    /// Publish the audio this device holds, so every other device can have it.
    ///
    /// **Only from the raw tracks.** A device whose only audio is a master it
    /// was given has nothing to add, and if it published anyway two devices
    /// would take turns re-uploading the same bytes for ever. Raw tracks exist
    /// on exactly one device per recording: the one that captured it, or the
    /// one that won its ingest.
    ///
    /// `ingest` is untouched and stays the raw pipe it is, so the first
    /// transcription still reads the tracks as they were captured rather than
    /// a round trip through an encoder.
    public func pushMasters(into report: inout CloudReport) async {
        var base = state.base
        defer { state.base = base }

        // Anything with audio of its own that no master has been published for.
        // `hasTracks` is the usual case; a recording whose only audio is the
        // mixdown a legacy recorder produced is the other, and it used to be
        // skipped in silence, so an import could never reach a second device in
        // any playable form at all.
        let owed = library.all()
            .filter { base[master: $0.id] == nil && ($0.hasTracks || $0.hasMixdownOnly) }
            .prefix(CloudSyncCore.masterBatch)
        guard !owed.isEmpty else { return }

        for (index, recording) in owed.enumerated() {
            progress?("Preparing audio \(index + 1) of \(owed.count)")
            do {
                guard let built = try AudioMaster.make(micURL: recording.micURL,
                                                       systemURL: recording.systemURL,
                                                       mixURL: recording.mixURL,
                                                       into: recording.folder) else { continue }
                let audio = try Data(contentsOf: built.url)
                let record = try CloudRecords.master(
                    id: recording.id, from: device, audio: audio,
                    channels: built.channels, layout: built.layout, key: key)
                _ = try await store.save(record)
                base[master: recording.id] = sha256Hex(audio)
                report.pushedMasters += 1
                // Removed once it has landed. This device holds the raw tracks
                // by construction, which is a better copy than the master in
                // every way that matters here: playback reads them, the
                // pipeline reads them, and `hasAudio` is already true because
                // of them. Keeping the master beside them would add 12% to
                // every recording on the one machine that never needs it,
                // which on this library is 1.5 GB to hold a second copy of
                // audio it already has. Rebuilding one is four seconds.
                //
                // Not for a mixdown-only recording. There are no tracks there
                // to be the better copy, so removing it would leave the device
                // that published it holding an m4a its own pipeline reads and
                // nothing else does.
                if built.layout == .tracks {
                    try? FileManager.default.removeItem(at: built.url)
                }
            } catch StoreError.changedOnServer(let theirs) {
                // Somebody published it first, which is possible only in the
                // window where two devices both hold the raw tracks. Their
                // copy is as good as ours by construction: it is the same
                // audio, encoded losslessly. Stamped from what came back, so
                // this device never asks again.
                base[master: recording.id] =
                    (try? CloudRecords.openMaster(theirs, key: key))?.digest ?? "theirs"
            } catch {
                report.errors.append("audio \(recording.id): \(error.localizedDescription)")
            }
        }
    }

    /// Take down the audio for recordings this device wants and does not have.
    ///
    /// Gated on the device roster rather than on asking the container, because
    /// a master is tens of megabytes and **"is it there" costs the same fetch
    /// as "give it to me"**: `CKDatabase.record(for:)` brings the asset with
    /// it. So the cheap question is answered from `holdsAudio`, which arrives
    /// every pass in the device zone and carries no audio at all. A recording
    /// no other device claims to hold is not asked about.
    public func pullMasters(_ devices: [CloudRecords.DeviceBlob],
                            into report: inout CloudReport, now: Date = Date()) async {
        guard keepAudio else { return }
        var base = state.base
        defer { state.base = base }

        var holders: Set<String> = []
        for blob in devices where blob.id != device && blob.isLive(now) {
            holders.formUnion(blob.holdsAudio ?? [])
        }
        guard !holders.isEmpty else { return }

        let wanted = library.all().filter { !$0.hasAudio && holders.contains($0.id) }
            .prefix(CloudSyncCore.masterBatch)
        for (index, recording) in wanted.enumerated() {
            progress?("Fetching audio \(index + 1) of \(wanted.count)")
            await receiveMaster(recording, base: &base, into: &report)
        }
    }

    /// Fetch one recording's audio because somebody asked for it, and keep it.
    ///
    /// The deliberate exception to `pullMasters`, which is a policy. This is an
    /// instruction, so it works on a device whose switch is off, and it pins
    /// the recording: `reclaim` leaves a pinned copy alone however many other
    /// devices report holding it. Without the pin the next pass would free what
    /// the tap had just downloaded, which is the whole reason the phone could
    /// not offer this before.
    ///
    /// False when there is nothing to fetch yet, which is ordinary: no device
    /// holding the tracks has published this one.
    @discardableResult
    public func fetchMaster(_ id: String, into report: inout CloudReport) async -> Bool {
        guard Metadata.isValidID(id), let recording = library.find(id) else { return false }
        var base = state.base
        defer { state.base = base }
        if recording.hasAudio {
            // Already here. Pin it anyway: being asked for it is the
            // instruction, and it must survive whatever the switch says next.
            base[pinned: id] = true
            return true
        }
        let received = await receiveMaster(recording, base: &base, into: &report)
        if received { base[pinned: id] = true }
        return received
    }

    /// Let go of one recording's audio on this device, because somebody asked.
    ///
    /// The other half of `fetchMaster`, and the only thing in this file that
    /// frees audio without consulting the roster: a person saying "remove this"
    /// is not the reclaim invariant, it is somebody deciding about their own
    /// disk. It still refuses when nobody else reports holding the bytes,
    /// because "I want the space back" is not "I want to lose the recording".
    @discardableResult
    public func freeMaster(_ id: String, _ devices: [CloudRecords.DeviceBlob],
                           into report: inout CloudReport,
                           now: Date = Date()) async -> Bool {
        guard Metadata.isValidID(id), let recording = library.find(id),
              recording.hasAudio else { return false }
        guard keepers(devices, now: now).contains(id) else { return false }
        var base = state.base
        defer { state.base = base }
        base[pinned: id] = false
        for url in recording.audioFiles {
            let size = (try? FileManager.default.attributesOfItem(
                atPath: url.path)[.size] as? Int) ?? 0
            if (try? FileManager.default.removeItem(at: url)) != nil { report.freedBytes += size }
        }
        return true
    }

    /// Take one master down and write it beside the recording. Shared by the
    /// policy path and the asked-for path so the two cannot verify differently.
    @discardableResult
    private func receiveMaster(_ recording: Recording, base: inout SyncState,
                               into report: inout CloudReport) async -> Bool {
        do {
            let name = CloudRecords.masterName(recording.id, key: key)
            // Absent is ordinary: the device that holds the tracks has not
            // published this one yet, and it publishes three a pass.
            reportActivity(recording.id, .downloadingAudio, fraction: 0)
            guard let record = try await store.fetch(name, in: .masters, progress: { value in
                activity?(CloudActivity(recordingID: recording.id,
                                        stage: .downloadingAudio,
                                        fraction: value))
            }) else {
                reportActivity(recording.id, .retrying,
                               detail: "Audio is not available in iCloud yet")
                return false
            }
            let blob = try CloudRecords.openMaster(record, key: key)
            guard blob.id == recording.id,
                  let audio = try CloudRecords.openMasterAudio(record, blob, key: key)
            else {
                report.errors.append("audio \(recording.id): the copy did not verify")
                return false
            }
            try audio.write(to: AudioMaster.url(in: recording.folder, blob.layout),
                            options: .atomic)
            base[master: recording.id] = blob.digest
            report.pulledMasters += 1
            reportActivity(recording.id, recording.hasTranscript ? .ready : .queued,
                           fraction: 1)
            return true
        } catch {
            report.errors.append("audio \(recording.id): \(error.localizedDescription)")
            reportActivity(recording.id, .retrying, detail: error.localizedDescription)
            return false
        }
    }

    /// Deletes owed to the master zone, for recordings that have gone. Safe to
    /// retry for ever, because deleting a record that is not there is a no-op
    /// in both stores. The same shape as `settleVoiceprintDebts`, and separate
    /// from it because the two zones fail independently.
    private func settleMasterDebts(_ base: inout SyncState,
                                   into report: inout CloudReport) async {
        for entry in base.base.keys.filter({ $0.hasPrefix(SyncState.r5DropKey("")) }) {
            let id = String(entry.dropFirst(SyncState.r5DropKey("").count))
            do {
                try await store.delete(CloudRecords.masterName(id, key: self.key), in: .masters)
                base.base[entry] = nil
            } catch {
                report.errors.append("audio delete \(id): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Up

    /// Put up anything this device authored that the container does not have.
    /// Write down that the container now holds exactly these sidecars.
    ///
    /// The other half of the three-way rule in `pullRecording`: without a base
    /// there is nothing to compare a later disagreement against, and every
    /// disagreement reads as "I am behind". Called wherever the container is
    /// known to agree with this device, which is a save that landed and a
    /// record that already matched. Never on a pull that only *wrote* some of
    /// the files, which is why `pullRecording` stamps per file rather than here.
    private func agreeSidecars(_ recording: Recording, in base: inout SyncState) {
        for file in policy.files(for: recording.id) where file != "metadata.json" {
            let url = recording.folder.appendingPathComponent(file)
            guard let data = try? Data(contentsOf: url) else { continue }
            base[sidecar: recording.id, file: file] = sha256Hex(data)
        }
    }

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
        // **Never push half a recording.**
        //
        // Between the two halves of a progressive pull this device holds a
        // recording whose transcript is in the container and not on this disk.
        // Its local stamp therefore disagrees with what was sent, which is
        // exactly the condition this filter selects on, so without this line
        // the pass that made the row visible would offer the container the
        // version without the transcript. On a phone `addingPhoneContent`
        // would merge the remote copy back over it and the damage would be a
        // wasted round trip; on any device that ingests it is the transcript
        // erased for everybody. One line, and it is the invariant the whole
        // two-phase pull rests on, so it is not written as an `if progressive`
        // anywhere: an empty debt makes it free.
        let mine = stamps.filter { base[sent: $0.0.id] != $0.1 && !base[owed: $0.0.id] }
        if mine.count > 4 { progress?("Checking \(mine.count) recordings") }
        for (index, pair) in mine.enumerated() {
            let (recording, stamp) = pair
            let storedState = recording.metadata.state.flatMap(Metadata.State.init(rawValue:))
            let finishedStates: Set<Metadata.State> = [.done, .needs_labelling, .failed]
            let sendingTranscript = recording.hasTranscript
                || storedState.map(finishedStates.contains) == true
            if mine.count > 4, index % 5 == 0 {
                progress?("Sending \(index + 1) of \(mine.count)")
            }
            let name = CloudNaming.recordName(.recording, recording.id, key: key)
            do {
                let existing = try await store.fetch(name, in: .library)
                var record = try CloudRecords.recording(recording, policy: policy, key: key)
                if let existing, !ingests {
                    record = try CloudRecords.addingPhoneContent(record, to: existing, key: key)
                } else if let existing {
                    // A Mac may be unable to make the source icon at all, and
                    // must not take one away because of it.
                    record = try CloudRecords.keepingSourceIcon(record, from: existing, key: key)
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
                    agreeSidecars(recording, in: &base)
                    if sendingTranscript {
                        reportActivity(recording.id, .ready, fraction: 1)
                    }
                    continue
                }
                if sendingTranscript {
                    reportActivity(recording.id, .sendingTranscript, fraction: 0)
                }
                _ = try await store.save(record, progress: { value in
                    guard sendingTranscript else { return }
                    activity?(CloudActivity(recordingID: recording.id,
                                            stage: .sendingTranscript,
                                            fraction: value))
                })
                base[sent: recording.id] = stamp
                agreeSidecars(recording, in: &base)
                report.pushedRecordings += 1
                if sendingTranscript {
                    reportActivity(recording.id, .ready, fraction: 1)
                }
            } catch let error as StoreError {
                if case .changedOnServer = error { report.conflicts.append(recording.id) }
                else { report.errors.append("\(recording.id): \(error)") }
                if sendingTranscript {
                    reportActivity(recording.id, .retrying, detail: String(describing: error))
                }
            } catch {
                report.errors.append("\(recording.id): \(error.localizedDescription)")
                if sendingTranscript {
                    reportActivity(recording.id, .retrying, detail: error.localizedDescription)
                }
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
                //
                // **Moved, not removed**, which this branch did not do and cost
                // somebody their notes. `deleteLocally` states the rule for the
                // pull side: a deletion arriving over sync was made on some
                // other device, and this one cannot tell a deliberate one from
                // a bug or from a library that briefly looked empty, so it goes
                // to the trash for a fortnight. This is the same class of event
                // by its own comment above, and it was calling `deleteNote`,
                // which is a bare `removeItem` with nothing behind it.
                //
                // Found on a real library: `sync_deleted count: 4` in the
                // activity log on 2026-08-18, four notes gone, and `listen sync
                // trash` holding two recordings and no notes at all. The trash
                // even tells the reader to "put one back by moving it into
                // recordings/ or notes/", which was a promise only the pull
                // path kept.
                if existing == nil, let agreed = base[note: note.slug], agreed == note.version {
                    Trash.accept(library.notes.appendingPathComponent(note.slug + ".md"),
                                 in: library)
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

        // Voiceprint debts first, and on every device: the phone does not
        // keep voiceprints, but a recording deleted from the phone still has
        // to take its r6 record with it, and this is the retry path when
        // that delete failed on the pass that deleted r1.
        await settleVoiceprintDebts(&base, into: &report)
        await settleMasterDebts(&base, into: &report)

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
                // The voiceprint goes with the recording. Not gated on
                // `keepsVoiceprints`: the phone never holds one, but a
                // deletion it originates still has to clean the zone it
                // cannot see. A miss is a no-op, a failure becomes a debt.
                do {
                    try await store.delete(CloudNaming.recordName(.voiceprint, id,
                                                                  key: self.key),
                                           in: .voiceprints)
                } catch {
                    base.base[SyncState.r6DropKey(id)] = "due"
                }
                // And the audio master, which is the largest thing a deleted
                // recording can leave behind: tens of megabytes in a zone
                // nothing lists, so nothing would ever notice it again.
                do {
                    try await store.delete(CloudRecords.masterName(id, key: self.key),
                                           in: .masters)
                } catch {
                    base.base[SyncState.r5DropKey(id)] = "due"
                }
                base[master: id] = nil
                base[pinned: id] = false
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
            // Read off the disk here rather than taken from the caller. It is
            // the sentence every other device's reclaim rule is going to
            // believe about this one, so there must be no way for a caller to
            // be a version behind on what it means. A stat per audio file per
            // recording: 61 recordings is a few hundred, and the pass it rides
            // in is a network round trip.
            let held = library.all().filter(\.hasAudio).map(\.id)
            var record = try CloudRecords.device(
                CloudRecords.DeviceBlob(id: device, name: name, kind: kind,
                                        lastSeen: Metadata.stamp(now),
                                        appVersion: appVersion,
                                        keepsAudio: keepAudio, holdsAudio: held), key: key)
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
        var base = state.base
        defer { state.base = base }

        // This device's forgets are applied before anything is sealed, so a
        // pass never pushes a name the user has asked to be gone. A bank that
        // empties becomes a debt, settled below.
        let stones = VoiceprintTombstones.load(library)
        let applied = VoiceprintTombstones.apply(stones.activeNames(), to: library)
        for id in applied.emptied { base.base[SyncState.r6DropKey(id)] = "due" }

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

        await settleVoiceprintDebts(&base, into: &report)

        // The tombstone record, merged rather than replaced. Two Macs that
        // forget different people in the same window both land, because
        // whichever pushes second starts from a fetch of the first, and the
        // changeTag turns a genuine cross push into a retry rather than an
        // overwrite.
        let name = CloudNaming.recordName(.voiceprint, VoiceprintTombstones.cloudKey,
                                          key: key)
        do {
            let existing = try await store.fetch(name, in: .voiceprints)
            var remote = VoiceprintTombstones()
            if let existing {
                let blob = try CloudRecords.openBlob(existing, key: key)
                remote = (try? JSONDecoder().decode(VoiceprintTombstones.self,
                                                    from: blob.contents)) ?? remote
            }
            let merged = VoiceprintTombstones.merged(stones, remote)
            if merged != stones { merged.save(library) }
            let shouldSave = existing == nil
                ? !merged.entries.isEmpty
                : merged != remote
            if shouldSave {
                var record = try CloudRecords.voiceprint(
                    id: VoiceprintTombstones.cloudKey,
                    contents: try JSONEncoder().encode(merged), key: key)
                record.changeTag = existing?.changeTag
                _ = try await store.save(record)
            }
        } catch {
            report.errors.append("forgotten people: " + error.localizedDescription)
        }
    }

    /// Deletes owed to the voiceprint zone: banks that emptied under a
    /// forget, and voiceprints whose recording went while the record delete
    /// failed. Safe to retry for ever, because deleting a record that is not
    /// there is a no-op in both stores.
    private func settleVoiceprintDebts(_ base: inout SyncState,
                                       into report: inout CloudReport) async {
        let owed = base.base.keys.filter { $0.hasPrefix(SyncState.r6DropKey("")) }
        for entry in owed {
            let id = String(entry.dropFirst(SyncState.r6DropKey("").count))
            do {
                try await store.delete(CloudNaming.recordName(.voiceprint, id,
                                                              key: self.key),
                                       in: .voiceprints)
                base.base[entry] = nil
            } catch {
                report.errors.append("voiceprint delete \(id): "
                                     + error.localizedDescription)
            }
        }
    }

    /// Take other Macs' voiceprints down. The voice bank has no database and
    /// the set of these files **is** the bank, so a Mac without them cannot
    /// recognise a voice it has already been taught.
    public func pullVoiceprints(into report: inout CloudReport) async {
        guard policy.keepsVoiceprints else { return }
        var base = state.base
        defer { state.base = base }
        guard let changes = try? await store.changes(in: .voiceprints, since: nil) else { return }

        // The tombstone record first, so a forget that arrives in the same
        // pass as the banks it strips is applied to them rather than one pass
        // late. An old build never reaches this record: its blob name is not
        // a valid recording id, so the guard below skips it silently.
        var stones = VoiceprintTombstones.load(library)
        let tombName = CloudNaming.recordName(.voiceprint,
                                              VoiceprintTombstones.cloudKey, key: key)
        for record in changes.changed where record.name == tombName {
            guard let blob = try? CloudRecords.openBlob(record, key: key),
                  let remote = try? JSONDecoder().decode(VoiceprintTombstones.self,
                                                         from: blob.contents)
            else { continue }
            let merged = VoiceprintTombstones.merged(stones, remote)
            if merged != stones { merged.save(library); stones = merged }
        }
        let active = stones.activeNames()
        let applied = VoiceprintTombstones.apply(active, to: library)
        for id in applied.emptied { base.base[SyncState.r6DropKey(id)] = "due" }

        for record in changes.changed {
            guard record.name != tombName,
                  let blob = try? CloudRecords.openBlob(record, key: key),
                  Metadata.isValidID(blob.name) else { continue }
            let folder = library.folder(for: blob.name)
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let url = folder.appendingPathComponent("embeddings.json")
            // Strip before the compare, so a record still carrying a
            // forgotten name neither lands on disk nor reads as agreement.
            // The record itself is repaired by this device's next push, which
            // sees the stripped file disagree with the fat record.
            var contents = blob.contents
            var version = blob.version
            if let stripped = VoiceprintTombstones.strip(active, fromBank: contents) {
                if stripped.empty {
                    try? FileManager.default.removeItem(at: url)
                    base.base[SyncState.r6DropKey(blob.name)] = "due"
                    continue
                }
                contents = stripped.data
                version = sha256Hex(contents)
            }
            if let have = try? Data(contentsOf: url), sha256Hex(have) == version { continue }
            try? contents.write(to: url, options: .atomic)
            report.pulledSidecars += 1
        }

        // One sweep of voiceprints whose recording was deleted before r6
        // records were deleted alongside r1. Absence on this disk proves
        // nothing on a Mac mid first pull, so the recording record is asked
        // for: absent in the container is the evidence that counts.
        if base.base["migration:r6-orphans-v1"] == nil {
            var swept = true
            for record in changes.changed {
                guard record.name != tombName,
                      let blob = try? CloudRecords.openBlob(record, key: key),
                      Metadata.isValidID(blob.name),
                      !FileManager.default.fileExists(
                          atPath: library.folder(for: blob.name).path)
                else { continue }
                do {
                    let r1 = CloudNaming.recordName(.recording, blob.name, key: key)
                    if try await store.fetch(r1, in: .library) == nil {
                        try await store.delete(record.name, in: .voiceprints)
                    }
                } catch { swept = false }
            }
            if swept { base.base["migration:r6-orphans-v1"] = "done" }
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
    /// A Mac has published work made from this recording's audio. Final: there
    /// is nothing left for this phone to offer, whatever it still holds.
    static let acknowledged = "acknowledged"

    /// A Mac took the audio and has published nothing made from it yet.
    ///
    /// Stamped rather than boolean, because it expires. `acknowledged` used to
    /// be written the moment any `audioOn` appeared and nothing ever cleared
    /// it, so a Mac that took a recording and then could not publish it parked
    /// that recording for ever: the phone went quiet holding the only other
    /// copy, and clearing `audioOn` in the container would not have woken it.
    /// That is not hypothetical, and the incident is in
    /// `.agents/notes/cloud-sync.md`.
    static func claimed(at when: Date) -> String { "claimed:" + Metadata.stamp(when) }

    /// How long a claim with nothing to show for it is believed.
    ///
    /// Six hours. A Mac that has taken the audio and published neither a
    /// transcript nor a finished state in six hours is asleep, stuck, or on a
    /// build that cannot publish, and in all three cases offering the audio to
    /// whichever Mac is awake beats waiting. Shorter would re-offer across an
    /// ordinary closed lid; longer stops being same-day. Being wrong costs one
    /// upload of audio this phone still has, and **cannot** cost the recording:
    /// nothing here deletes anything, and `reclaimIfAcknowledged` is still the
    /// only thing that frees a local copy.
    static let claimGrace: TimeInterval = 6 * 3600

    public func upload(_ recording: Recording, into report: inout CloudReport,
                       now: Date = Date()) async {
        guard !ingests else { return }
        guard recording.hasAudio, let audio = try? Data(contentsOf: recording.micURL) else { return }

        // Remember a Mac's acknowledgement, because the transfer record is
        // deleted on purpose the moment a Mac takes the audio.
        //
        // Until that acknowledgement arrives, a remembered upload is not
        // durable proof. If the transfer has disappeared while this phone still
        // owns the bytes, recreate it. Once acknowledged, keep-audio phones can
        // retain their WAVs without re-sending the whole library every pass.
        //
        // A bare claim is believed only for `claimGrace`, and then this phone
        // offers the audio again. One offer per window, because the pull that
        // follows re-stamps the claim, so a Mac that is merely slow is not
        // hammered and one that is stuck does not win by silence.
        var base = state.base
        let sentKey = "audio:" + recording.id
        switch base[sent: sentKey] {
        case CloudSyncCore.acknowledged:
            reportActivity(recording.id,
                           recording.hasTranscript ? .ready : .waitingForMac,
                           fraction: recording.hasTranscript ? 1 : nil)
            return
        case let marker? where marker.hasPrefix("claimed:"):
            let stamp = String(marker.dropFirst("claimed:".count))
            guard let when = Metadata.parser.date(from: stamp),
                  now.timeIntervalSince(when) >= CloudSyncCore.claimGrace
            else {
                reportActivity(recording.id, .waitingForMac)
                return
            }
        default:
            break
        }

        let metadataURL = recording.folder.appendingPathComponent("metadata.json")
        guard let metadata = try? Data(contentsOf: metadataURL) else { return }
        let name = CloudNaming.recordName(.audioTransfer, recording.id, key: key)
        do {
            if try await store.fetch(name, in: .transfer) != nil {
                reportActivity(recording.id, .waitingForMac)
                return
            }
            reportActivity(recording.id, .uploadingAudio, fraction: 0)
            _ = try await store.save(try CloudRecords.transfer(
                id: recording.id, from: device, metadata: metadata,
                audio: audio, key: key), progress: { value in
                    activity?(CloudActivity(recordingID: recording.id,
                                            stage: .uploadingAudio,
                                            fraction: value))
                })
            base[sent: sentKey] = "1"
            state.base = base
            report.pushedRecordings += 1
            reportActivity(recording.id, .waitingForMac, fraction: 1)
        } catch {
            report.errors.append("upload \(recording.id): \(error.localizedDescription)")
            reportActivity(recording.id, .retrying, detail: error.localizedDescription)
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
                reportActivity(blob.id, .downloadingAudio)
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

                reportActivity(blob.id, .queued, fraction: 1)

                // The pipe is emptied only once the library holds it.
                try await store.delete(record.name, in: .transfer)
            } catch {
                report.errors.append("ingest: \(error.localizedDescription)")
                if let blob = try? CloudRecords.openTransfer(record, key: key) {
                    reportActivity(blob.id, .retrying, detail: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Claiming a transcription

    /// Who is transcribing a recording, and until when.
    public struct TranscriptionLease: Sendable, Equatable {
        public var device: String
        public var expires: Date
        public var mine: Bool
    }

    /// **`claimedBy` and `claimExpires` on the recording record, which were
    /// already deployed and written by nothing.**
    ///
    /// `claim` only ever touches transfer records; `push` merely carries these
    /// two through on `r1`. So the lease costs no Production schema at all,
    /// and Production schema is append-only for ever. They are also exactly
    /// the right shape: typed and readable, because they are written by a
    /// device that is not the content's author and read to decide a race,
    /// which is the reason those three fields are in the clear at all.
    ///
    /// **Why a lease is needed now and was not before.** Audio used to land on
    /// one Mac, so "has the bytes" *was* the lock: no other machine could have
    /// transcribed if it wanted to. A replicated master removes that accident,
    /// and `Queue.resume` enqueues anything with audio and no transcript, so
    /// without this every Mac transcribes every recording, burning an hour of
    /// each machine to produce two answers to the same question.
    ///
    /// It expires so a Mac that dies mid-run does not park a recording for
    /// ever, and it is renewed while the job runs, because a long meeting
    /// outlives any window short enough to be useful after a crash.
    public func transcriptionLease(_ id: String, now: Date = Date()) async -> TranscriptionLease? {
        guard Metadata.isValidID(id) else { return nil }
        let name = CloudNaming.recordName(.recording, id, key: key)
        guard let record = try? await store.fetch(name, in: .library),
              let holder = record.claimedBy, let expires = record.claimExpires,
              expires > now
        else { return nil }
        return TranscriptionLease(device: holder, expires: expires, mine: holder == device)
    }

    /// What asking for the lease answered.
    ///
    /// Three cases and not two, because "yes" and "nobody could say no" are
    /// different facts and the caller has to be able to tell them apart. The
    /// old signature was a `Bool` and the difference was a comment.
    public enum LeaseOutcome: Sendable, Equatable {
        /// It is this device's, and the container agreed.
        case taken
        /// Somebody else holds it, and this is their claim.
        case held(TranscriptionLease)
        /// **Granted by default.** The container could not be reached, so
        /// nothing could refuse. Listen works with the network off and a Mac
        /// must still transcribe its own recording, so the answer is yes; but
        /// the caller now knows nothing checked, and `othersRunLooksLive` is
        /// what it is expected to ask next.
        case unreachable

        /// Whether the caller may go ahead on this answer alone. False only
        /// for `.held`: `.unreachable` is a yes with a caveat, not a no.
        public var granted: Bool {
            if case .held = self { return false }
            return true
        }

        /// Who has it, when somebody does.
        public var holder: TranscriptionLease? {
            if case .held(let lease) = self { return lease }
            return nil
        }
    }

    /// How long another device's unfinished run is believed when the container
    /// cannot be asked about it.
    ///
    /// Six hours, the same number and the same argument as `claimGrace`. A
    /// lease is fifteen minutes and renewed, but renewals live in the container
    /// and this is the window where the container is exactly what cannot be
    /// read, so the only clock available is `transcribe_started` in a
    /// `metadata.json` that arrived before the network went. A run that has
    /// shown nothing for six hours is asleep, stuck or on a machine that has
    /// been shut, and in all three cases transcribing it here beats waiting.
    /// Being wrong costs one duplicated hour of CPU and cannot cost data:
    /// nothing here deletes anything.
    public static let offlineGrace: TimeInterval = 6 * 3600

    /// Whether the recording's own metadata says another device is on this,
    /// recently enough to be believed.
    ///
    /// **The deterrent for the offline window, promoted from a comment to a
    /// function.** `state: transcribing` used to be described as travelling in
    /// the metadata and nothing read it, so a Mac that could not reach the
    /// container started every job it had regardless of what the last sync had
    /// told it. This is that sentence, asked.
    ///
    /// Pure, so it can be checked without a network and without a queue.
    /// Takes the four fields rather than a `Metadata`, because the Mac app
    /// models that document with a struct of its own and the answer must not
    /// depend on which of the two the caller happens to hold.
    public static func othersRunLooksLive(transcribedBy: String?, state: String?,
                                          started: String?, finished: String?,
                                          device: String, now: Date = Date()) -> Bool {
        guard let holder = transcribedBy, holder != device else { return false }
        guard Metadata.State(rawValue: state ?? "") == .transcribing else { return false }
        // Finished is finished, whatever `state` still says.
        guard finished == nil else { return false }
        // A run that never said when it began is not evidence: it could be from
        // any build and any month, and believing it would park the recording.
        guard let began = started.flatMap(Metadata.parser.date(from:)) else { return false }
        let age = now.timeIntervalSince(began)
        return age >= 0 && age < CloudSyncCore.offlineGrace
    }

    /// Take it, or lose it to whoever already has it.
    ///
    /// `.taken` also when there is no record yet, which is a recording this
    /// device has made and not pushed: nobody else can be transcribing
    /// something they have never heard of, and refusing would stall the common
    /// case on the network.
    @discardableResult
    public func takeTranscriptionLease(_ id: String, window: TimeInterval = 900,
                                       now: Date = Date()) async -> LeaseOutcome {
        guard Metadata.isValidID(id) else { return .unreachable }
        let name = CloudNaming.recordName(.recording, id, key: key)
        // A throw here is the container being unreachable, and that must not
        // stop a Mac transcribing its own recording: Listen works with the
        // network off, and the cost of two Macs doing the same hour of work is
        // wasted CPU rather than lost data. Reported as its own case so the
        // caller can apply the second deterrent rather than assume there is
        // one.
        let found: StoredRecord?
        do { found = try await store.fetch(name, in: .library) } catch { return .unreachable }
        guard var record = found else { return .taken }
        if let holder = record.claimedBy, holder != device,
           let expires = record.claimExpires, expires > now {
            return .held(TranscriptionLease(device: holder, expires: expires, mine: false))
        }
        record.claimedBy = device
        record.claimExpires = now.addingTimeInterval(window)
        // The compare-and-swap is the whole mechanism: two Macs waking
        // together both read no holder, and exactly one save lands.
        do {
            _ = try await store.save(record)
            return .taken
        } catch StoreError.changedOnServer(var theirs) {
            // A concurrent write is not necessarily a competing claim. A title
            // edit or another metadata update may have moved the record while
            // leaving it unclaimed. Retry the compare-and-swap once with the
            // server copy instead of parking the recording behind a fiction.
            if let holder = theirs.claimedBy, holder != device,
               let expires = theirs.claimExpires, expires > now {
                return .held(TranscriptionLease(device: holder, expires: expires, mine: false))
            }
            theirs.claimedBy = device
            theirs.claimExpires = now.addingTimeInterval(window)
            do {
                _ = try await store.save(theirs)
                return .taken
            } catch {
                return await leaseAfterFailedSave(name, now: now)
            }
        } catch {
            return await leaseAfterFailedSave(name, now: now)
        }
    }

    /// Resolve an ambiguous failed save without inventing a holder.
    ///
    /// CloudKit may fail the request after the server accepted it, so a
    /// read-back can still prove this device owns the lease. It may also show a
    /// real competing device. If it shows neither, the container did not grant
    /// a lease and did not refuse one. That is `.unreachable`, the existing
    /// offline-safe answer, rather than a made-up 15 minute refusal.
    private func leaseAfterFailedSave(_ name: String, now: Date) async -> LeaseOutcome {
        guard let record = try? await store.fetch(name, in: .library),
              let holder = record.claimedBy,
              let expires = record.claimExpires,
              expires > now else { return .unreachable }
        if holder == device { return .taken }
        return .held(TranscriptionLease(device: holder, expires: expires, mine: false))
    }

    /// Hold it for another window. A job that outlives its lease invites a
    /// second Mac to start the same hour of work.
    public func renewTranscriptionLease(_ id: String, window: TimeInterval = 900,
                                        now: Date = Date()) async {
        guard Metadata.isValidID(id) else { return }
        let name = CloudNaming.recordName(.recording, id, key: key)
        guard var record = try? await store.fetch(name, in: .library),
              record.claimedBy == device
        else { return }
        record.claimExpires = now.addingTimeInterval(window)
        _ = try? await store.save(record)
    }

    /// Let it go, on success or on failure alike. A failed run that keeps the
    /// lease until it expires is fifteen minutes in which nothing retries.
    public func releaseTranscriptionLease(_ id: String) async {
        guard Metadata.isValidID(id) else { return }
        let name = CloudNaming.recordName(.recording, id, key: key)
        guard var record = try? await store.fetch(name, in: .library),
              record.claimedBy == device
        else { return }
        record.claimedBy = nil
        record.claimExpires = nil
        _ = try? await store.save(record)
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
