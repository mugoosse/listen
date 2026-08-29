import Foundation
import ListenKit

/// The CloudKit sync, running by itself while the app is open.
///
/// There is no socket here, no address to find, no local-network permission and
/// nothing that needs both devices awake at once.
///
/// **Off unless `Settings.cloudSync` says otherwise.** The first write to a
/// container is the first moment somebody's meetings leave their machine, and
/// that is a decision to be taken rather than a default to be inherited.
@MainActor
final class CloudSyncHost {
    static let shared = CloudSyncHost()

    private var timer: Timer?
    private var running = false
    /// One store for the life of the app rather than one per pass.
    ///
    /// It caches the server's copy of each record it has seen, which is what
    /// CloudKit's compare-and-swap needs: a change tag cannot be synthesised,
    /// so the only way to say "I am updating what I read" is to hold what was
    /// read. Two stores would each hold half of that, and the transcription
    /// lease is written from outside a pass while `push` writes the same `r1`
    /// records inside one.
    private var store: CloudKitStore?
    /// Something asked for a sync while one was already going.
    private var again = false
    private var subscribed = false
    private var passID: UUID?

    /// What the last pass did, for the Devices pane to show. A sync that
    /// reports nothing is indistinguishable from one that silently failed.
    private(set) var lastReport: CloudReport?
    /// Whether the previous pass ended with errors, so the telemetry event
    /// below fires on the onset of a failure rather than on every retry.
    private var lastPassFailed = false
    private(set) var lastRun: Date?
    /// Where the key stands, so the pane can say what to do rather than
    /// printing the same sentence as both status and error. `.unknown` until
    /// a pass has asked; a keyless pass sets one of the other answers.
    enum KeyState: Equatable {
        case unknown, present, onItsWay, unreachable(String)
    }
    private(set) var keyState: KeyState = .unknown
    private(set) var devices: [CloudRecords.DeviceBlob] = []
    /// Live work keyed by recording, shared by the sidebar and detail pane.
    private(set) var activities: [String: CloudActivity] = [:]
    /// Redraw only the recording whose activity moved.
    var onActivity: ((String) -> Void)?
    /// The part of the current pass somebody is waiting on. Cleared when the
    /// pass ends so the Devices pane cannot mistake an old count for live work.
    private(set) var progress: String?

    /// Every two minutes while the app is open.
    ///
    /// A poll rather than a push subscription, for now. `CKSyncEngine`'s silent
    /// pushes are what make this arrive within seconds rather than within
    /// minutes, and they are worth adding, but a poll is what makes the feature
    /// correct and a push only makes it prompt.
    private let interval: TimeInterval = 120

    func startIfEnabled() {
        // Refused rather than silently skipped, because a scratch library that
        // does not sync looks exactly like one that does until the damage shows
        // up on another device, and by then it is somebody else's screen.
        if Settings.cloudSync, !Settings.cloudSyncApplies {
            trace("""
                  cloud sync: off for this library.
                    consented:  \(Settings.cloudSyncLibrary)
                    active:     \(ListenKit.Library.mac().root.path)
                  Turn it on for this one with `listen sync enable`.
                  """)
            return
        }
        guard Settings.cloudSyncApplies, timer == nil else { return }

        // Anything that changes the library is worth sending, and the file
        // system is what knows. See `LibraryWatch` for why this is not a hook
        // called from each writer any more.
        LibraryWatch.shared.start(root: ListenKit.Library.mac().root)

        // Old enough to be safe to forget. Deletions received in the last
        // fortnight are still on disk: see `Trash`.
        Trash.purge(in: ListenKit.Library.mac())

        // A copy on this disk, daily. iCloud is a replica and propagates a
        // deletion in seconds, so it is not the thing that gets a library back.
        // See `Backups`.
        Backups.runIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await CloudSyncHost.shared.syncNow() }
        }
        Task { await syncNow() }
        trace("cloud sync: on, every \(Int(interval))s")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        soon?.invalidate()
        soon = nil
        LibraryWatch.shared.stop()
        // The per-recording sync lines go with the engine. "Syncing
        // transcript" or "Retrying sync" over a library that no longer syncs
        // is a promise nobody is going to keep, and only a pass could have
        // cleared them. The queue's own stages stay: a job that is queued or
        // transcribing is still true with sync off, and the queue is what
        // ends those.
        let syncOwned: Set<CloudActivity.Stage> = [
            .sendingTranscript, .retrying, .uploadingAudio, .downloadingAudio,
            .downloadingTranscript, .waitingForMac, .transcribingElsewhere,
        ]
        let cleared = activities.filter { syncOwned.contains($0.value.stage) }.map(\.key)
        for id in cleared {
            activities.removeValue(forKey: id)
            onActivity?(id)
        }
        trace("cloud sync: off")
    }

    private var soon: Timer?

    /// Push in a few seconds, because something worth sending just happened.
    ///
    /// Coalesced rather than immediate: transcribing a backlog finishes several
    /// jobs in a row, and each one calling straight through would start a pass
    /// that the next one has to wait behind. The delay is short enough that the
    /// phone still sees the transcript while it is looking at the recording it
    /// is waiting for.
    func syncSoon() {
        guard Settings.cloudSyncApplies else { return }
        soon?.invalidate()
        soon = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
            Task { @MainActor in await CloudSyncHost.shared.syncNow() }
        }
    }

    /// One pass. Reentrant-safe, because a slow pass and a timer that fires
    /// again would otherwise have two engines writing the same records and
    /// each refusing the other's compare-and-swap.
    @discardableResult
    func syncNow() async -> CloudReport {
        // **The consent is checked here and not only by the callers.** Every
        // route into a pass had its own `Settings.cloudSync` guard, which is
        // five places that have to agree and a sixth that will be added without
        // one. This is the choke point, so this is where the question is
        // answered; the callers keep their own checks for what they say and
        // draw, not for whether the pass may run.
        //
        // `cloudSyncApplies`, because sync being on for this Mac is not the
        // same as it being on for the library that is open. See
        // `Config.cloudSyncLibrary` for what that cost.
        guard Settings.cloudSyncApplies else { return lastReport ?? CloudReport() }

        // Asked while busy means asked again the moment this finishes.
        //
        // Refusing is right: two passes writing the same records would each
        // refuse the other's compare-and-swap. Forgetting the request is not.
        // A recording made while a pass was running waited out the two minute
        // poll rather than going as soon as the pass ended, which reads as sync
        // being slow when it is only being deaf.
        guard !running else {
            again = true
            return lastReport ?? CloudReport()
        }
        running = true
        let pass = UUID()
        passID = pass
        progress = "Starting"
        defer { running = false; passID = nil; progress = nil; lastRun = Date() }

        let library = ListenKit.Library.mac()

        // The key, made here when this Mac is the first device to sync. This
        // used to be a bare `KeyStore.shared.load()`, and nothing anywhere
        // created what it looked for: a fresh install's every pass ended at
        // "No sync key yet" while its iPhone waited for a key that did not
        // exist. See `KeyStore.provision`.
        let key: PairingKey
        switch await KeyStore.shared.provision(store: sharedStore(), mayCreate: true) {
        case .existing(let held):
            key = held
        case .created(let made):
            key = made
            ActivityLog.append("sync_key_created")
            trace("cloud sync: created the sync key, this account's first")
        case .keyOnItsWay, .noDeviceSyncingYet:
            // Another device is already syncing, so its key travels here by
            // iCloud Keychain. Said as state rather than as an error: nothing
            // failed, and the next pass asks again.
            keyState = .onItsWay
            var report = CloudReport()
            report.errors.append("Waiting for your sync key to arrive from "
                                 + "your other device through iCloud Keychain.")
            lastReport = report
            return report
        case .unreachable(let why):
            keyState = .unreachable(why)
            var report = CloudReport()
            report.errors.append("iCloud could not be reached: \(why)")
            lastReport = report
            return report
        }
        keyState = .present

        let state = EngineState(library: library)
        // Adopt whatever the LAN transport agreed last, once, then remove the
        // legacy merge base and device registry from the library. Neither is
        // consulted after this point, and leaving per-device state inside the
        // replicated tree would keep the retired transport alive on disk.
        state.adoptLegacyBase(from: library)
        try? FileManager.default.removeItem(
            at: library.root.appendingPathComponent("devices.json"))

        let identity = state.identity(name: Host.current().localizedName ?? "Mac", kind: "Mac")
        let store = sharedStore()
        let core = CloudSyncCore(
            library: library, state: state, store: store,
            key: key, policy: .mac, device: identity.id, ingests: true,
            keepAudio: Settings.keepAudio,
            progress: { message in
                Task { @MainActor in
                    guard CloudSyncHost.shared.passID == pass else { return }
                    CloudSyncHost.shared.progress = message
                }
            },
            activity: { update in
                Task { @MainActor in CloudSyncHost.shared.setActivity(update) }
            })

        // Ask to be told rather than asking repeatedly. A Mac keeps
        // voiceprints, so it subscribes to all four zones; a phone does not,
        // and is not woken by another Mac teaching itself a voice.
        if !subscribed {
            // Named rather than `allCases`, because the master zone is
            // deliberately not among them. A master is fetched by name by a
            // device that has already decided it wants those bytes, so a
            // subscription would wake every Mac forty times over the hour a
            // library first publishes its audio, for records none of them
            // would read from the notification.
            await store.subscribe(to: [.library, .voiceprints, .devices, .transfer])
            subscribed = true
        }

        var report = CloudReport()
        devices = await core.heartbeat(name: identity.name, kind: identity.kind,
                                       appVersion: AppInfo.version ?? "unknown")

        // **A device that has never synced pulls before it pushes.**
        //
        // It cannot know whether its copy is ahead or behind, and pushing first
        // means a Mac that has been shut for a week overwrites a week of work
        // with what it remembers. Measured on a real second Mac: its library
        // was four days stale, 57 recordings against 63, and a push-first pass
        // would have written its older transcripts over the current ones.
        //
        // Notes were never at risk, because `decideNote` reports a conflict
        // when neither side is the agreed base and touches neither. Recordings
        // have no such three-way guard: there is normally one writer, and this
        // is the case where that assumption does not hold yet.
        // Down before up, always, rather than only on the first pass.
        //
        // The rule above is why it was written; the reason it is now
        // unconditional is that a pull is incremental and a push is not. The
        // pull asks for what has changed since a token, so it is one request
        // and usually empty. The push walks the whole library. Doing it second
        // means what somebody is waiting for arrives first, and nothing about
        // the ordering was load bearing in the other direction.
        await core.pull(into: &report)
        await core.pullVoiceprints(into: &report)

        // iOS cannot inspect applications installed on this Mac. Export a
        // compact copy of each source app icon before the recording manifest is
        // built, including for older recordings that predate the sidecar.
        SourceIconExporter.prepare(Recording.all())

        await core.push(into: &report)
        await core.pushVoiceprints(into: &report)
        // The audio, in both directions and after everything small. A master
        // is tens of megabytes, so it goes last: a pass that spends its time
        // on audio first is a pass where the transcript somebody is waiting
        // for arrives behind it.
        await core.pushMasters(into: &report)
        await core.pullMasters(devices, into: &report)
        // Claim before downloading, and prefer whichever Mac was chosen to keep
        // phone recordings. Empty means no preference and the first Mac awake
        // takes it.
        let preferred = Settings.preferredTranscriber
        await core.ingest(preferred: preferred.isEmpty ? nil : preferred, into: &report)

        // Anything that arrived may be a recording with audio and no
        // transcript, which is the definition of a pending job. Audio that
        // arrived as a master counts: that is the whole point of replicating
        // it, and `Queue` splits it back into tracks before it runs.
        if report.pulledRecordings > 0 || report.claimed > 0 || report.pulledMasters > 0 {
            Queue.shared.resume()
        }

        // Last, and only now that this pass has published what this Mac holds.
        // Freeing a local copy is the one write here that cannot be undone, so
        // it is taken with the freshest roster the pass has and never before
        // this Mac's own heartbeat has said what it is keeping.
        //
        // Whatever the queue is holding is named, because a recording waiting
        // to be transcribed here is a recording whose audio this Mac still
        // needs, however many other devices have a copy.
        await core.reclaim(devices, protecting: Queue.shared.activeIDs, into: &report)

        lastReport = report
        // On disk as well as in memory, because `listen sync status` is a
        // fresh process: the one command a stalled install gets asked to run
        // could name the account and the container and not the thing actually
        // wrong. See `EngineState.LastPass`.
        EngineState(library: library).lastPass = EngineState.LastPass(
            when: Date(), summary: report.summary, error: report.errors.first)
        trace("cloud sync: \(report.summary)")
        // A throttled pass is not a failed one: the server asked for a pause
        // measured in fractions of a second, the store already waited once,
        // and the report kept it out of `errors` so nothing turns red. What
        // is still owed is the retry, and `syncSoon` is exactly that shape.
        if report.throttled { syncSoon() }
        // Edge-triggered, one event per onset. The poll retries every two
        // minutes, so an event per failing pass would be one broken container
        // repeating the same fact all day into the quota. The report's error
        // strings never travel; the code is the whole message.
        let failed = !report.errors.isEmpty
        if failed, !lastPassFailed {
            Telemetry.failure(.sync, code: "sync.pass_failed", retryable: true)
        }
        lastPassFailed = failed
        // Deletions applied on another device's say-so are the one write here
        // the user did not make on this Mac, so they are the one thing a pass
        // leaves in the activity log. Counts only: `CloudReport` carries no
        // ids, deliberately, and the trash holds the folders for a fortnight.
        if report.deletedLocally > 0 {
            ActivityLog.append("sync_deleted", ["count": report.deletedLocally])
        }

        // Whatever arrived mid-pass, now. Cleared before running so a pass that
        // is itself interrupted asks once more rather than looping.
        if again {
            again = false
            running = false
            return await syncNow()
        }
        return report
    }

    private func sharedStore() -> CloudKitStore {
        if let store { return store }
        let made = CloudKitStore(containerID: CloudAccount.containerID)
        store = made
        return made
    }

    func activity(for id: String) -> CloudActivity? { activities[id] }

    func setActivity(_ activity: CloudActivity) {
        activities[activity.recordingID] = activity
        onActivity?(activity.recordingID)
    }

    // MARK: - The transcription lease

    /// A core built outside a pass, for the three lease calls the queue makes.
    ///
    /// Nil when this Mac is not syncing this library, and every caller reads
    /// that as "there is nobody to race with". Listen works with the network
    /// off and with iCloud never switched on, and a lease that could not be
    /// taken must never be the reason a Mac declines to transcribe its own
    /// recording.
    private func leaseCore() -> CloudSyncCore? {
        guard Settings.cloudSyncApplies, let key = KeyStore.shared.load() else { return nil }
        let library = ListenKit.Library.mac()
        let state = EngineState(library: library)
        let identity = state.identity(name: Host.current().localizedName ?? "Mac", kind: "Mac")
        return CloudSyncCore(library: library, state: state, store: sharedStore(),
                             key: key, policy: .mac, device: identity.id,
                             ingests: true, keepAudio: Settings.keepAudio)
    }

    /// This Mac's own id, which is what `Metadata.transcribed_by` records.
    ///
    /// Resolved once. It reads a file, and it is asked on every redraw of the
    /// transcript pane, which is thirty times a track while a job runs. The
    /// answer cannot change inside a process: `EngineState` is keyed on the
    /// library path and `LISTEN_LIBRARY` is read at launch.
    private static var cachedDeviceID: String?
    static var deviceID: String {
        if let cachedDeviceID { return cachedDeviceID }
        let id = EngineState(library: ListenKit.Library.mac())
            .identity(name: Host.current().localizedName ?? "Mac", kind: "Mac").id
        cachedDeviceID = id
        return id
    }

    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    /// Take the right to transcribe one recording, or find out who has it.
    ///
    /// `.unreachable` when there is nothing to ask, which is a Mac that does
    /// not sync and a Mac whose container is down alike. Both mean go ahead,
    /// and both mean nothing refused, which is why the caller is told which
    /// answer it got: see `CloudSyncCore.othersRunLooksLive` for the second
    /// deterrent that applies inside that window.
    func takeTranscriptionLease(_ id: String) async -> CloudSyncCore.LeaseOutcome {
        guard let core = leaseCore() else { return .unreachable }
        return await core.takeTranscriptionLease(id)
    }

    /// Fetch one recording's audio because somebody asked for it, and keep it.
    @discardableResult
    func fetchAudio(_ id: String) async -> Bool {
        guard let core = leaseCore() else { return false }
        var report = CloudReport()
        let got = await core.fetchMaster(id, into: &report)
        if got { RecordingEvents.changed?() }
        return got
    }

    /// Let go of one recording's audio here, when another device is keeping it.
    @discardableResult
    func freeAudio(_ id: String) async -> Bool {
        guard let core = leaseCore() else { return false }
        var report = CloudReport()
        let freed = await core.freeMaster(id, devices, into: &report)
        if freed { RecordingEvents.changed?() }
        return freed
    }

    /// Whether this device was asked to keep this one recording's audio.
    static func isPinned(_ id: String) -> Bool {
        EngineState(library: ListenKit.Library.mac()).base[pinned: id]
    }

    func renewTranscriptionLease(_ id: String) async {
        await leaseCore()?.renewTranscriptionLease(id)
    }

    func releaseTranscriptionLease(_ id: String) async {
        await leaseCore()?.releaseTranscriptionLease(id)
    }

    /// Who is transcribing this recording, when it is not this Mac.
    func transcriptionLease(_ id: String) async -> CloudSyncCore.TranscriptionLease? {
        guard let core = leaseCore() else { return nil }
        return await core.transcriptionLease(id)
    }

    /// The name of the device holding a lease, as the roster knows it.
    static func deviceName(for id: String) -> String? {
        shared.devices.first { $0.id == id }?.name
    }

    /// The Mac that holds this recording's audio, when it is not this one.
    ///
    /// Nil means nothing else has claimed it, which is the ordinary state of a
    /// phone recording still on its way here, and of every recording in a
    /// library that does not sync.
    ///
    /// **Why this is not `metadata.source`.** A phone recording goes to
    /// whichever Mac claims the transfer first, so on a two-Mac library the
    /// source says who *made* it and never who has it. That was wrong in the
    /// worst direction for the recording that made this necessary: the other
    /// Mac had taken the audio hours earlier and was on a build that never
    /// published the transcript it then made, and this Mac spent the afternoon
    /// promising to transcribe audio that was never coming.
    ///
    /// The name is the heartbeat's, so it is the name shown in Settings and
    /// on the machine itself. Before the first pass of a launch there is no
    /// device list yet, and an unnamed holder is still worth saying.
    static func audioHolder(of id: String) -> String? {
        guard Settings.cloudSyncApplies else { return nil }
        // The roster first, because it is the live answer and the other one is
        // a latch. `holdsAudio` is republished from disk on every heartbeat by
        // every device, so it names whichever machines have the bytes **now**,
        // including one that was given a master and never recorded anything.
        // `audioOn` names whichever Mac won an ingest, once, for ever, and
        // says nothing at all about a meeting recorded on a Mac.
        let holders = audioHolders(of: id)
        if let first = holders.first {
            if holders.count == 1 { return first.name }
            // Two is worth saying rather than picking one: it is the answer to
            // "is this safe" as well as to "where do I go".
            return holders.map(\.name).joined(separator: " and ")
        }
        let library = ListenKit.Library.mac()
        let state = EngineState(library: library)
        guard let holder = state.base[audioOn: id] else { return nil }
        guard holder != state.identity(name: Host.current().localizedName ?? "Mac",
                                       kind: "Mac").id else { return nil }
        return shared.devices.first { $0.id == holder }?.name
            ?? "your other Mac"
    }

    /// Every device other than this one that says it holds this recording's
    /// audio, most recently heard from first.
    ///
    /// Live devices only. A machine that has said nothing for a week is a
    /// claim about a disk nobody can see, and the reclaim rule refuses to act
    /// on one, so a screen that named it would be promising something the sync
    /// itself does not believe. See `CloudRecords.DeviceBlob.isLive`.
    /// `among` is the roster to answer from, and it is a parameter because the
    /// CLI runs in a process where no pass has ever run: `shared.devices` is
    /// filled by a sync pass, so a command that read it would silently answer
    /// "nobody" every time. `listen audio` fetches the device zone itself and
    /// hands it in.
    static func audioHolders(of id: String,
                             among devices: [CloudRecords.DeviceBlob]? = nil)
        -> [CloudRecords.DeviceBlob] {
        guard Settings.cloudSyncApplies else { return [] }
        let me = deviceID
        return (devices ?? shared.devices)
            .filter { $0.id != me && $0.isLive() && $0.holds(id) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    /// Nothing anywhere has said it holds this recording's audio.
    ///
    /// **A statement about what has been reported, not about the universe**,
    /// and worded that way wherever it is shown. A Mac shut in a drawer still
    /// has whatever it had; it simply is not saying so, and a library cannot
    /// tell that apart from a disk that was wiped. What it is good for is the
    /// case that matters: every device that is talking has let go, so the next
    /// thing to do is turn **Keep audio** on somewhere before the last copy
    /// goes with a machine.
    ///
    /// False on a library with one device in it, where the question does not
    /// arise and the answer would be alarming rather than useful.
    static func nothingHolds(_ recording: Recording,
                             among devices: [CloudRecords.DeviceBlob]? = nil) -> Bool {
        let roster = devices ?? shared.devices
        guard Settings.cloudSyncApplies, roster.count > 1 else { return false }
        guard !recording.hasAudio else { return false }
        return audioHolders(of: recording.id, among: roster).isEmpty
    }

    /// Every recording nothing has reported keeping the audio for.
    ///
    /// Counted in one pass over the roster rather than by asking per
    /// recording, because the per-recording question reloads the library to
    /// find the folder and a settings pane that refreshes every two seconds
    /// would do that sixty times over.
    static func unheld(among devices: [CloudRecords.DeviceBlob]? = nil) -> [Recording] {
        let roster = devices ?? shared.devices
        guard Settings.cloudSyncApplies, roster.count > 1 else { return [] }
        let me = deviceID
        var held: Set<String> = []
        for blob in roster where blob.id != me && blob.isLive() {
            held.formUnion(blob.holdsAudio ?? [])
        }
        return Recording.all().filter { !$0.hasAudio && !held.contains($0.id) }
    }

    /// The device roster, read straight from the container.
    ///
    /// For a process that never runs a pass, which is every CLI invocation.
    /// Empty when this Mac does not sync this library, which is also the
    /// honest answer: there is no roster.
    static func roster() async -> [CloudRecords.DeviceBlob] {
        guard Settings.cloudSyncApplies, let key = KeyStore.shared.load() else { return [] }
        let store = CloudKitStore(containerID: CloudAccount.containerID)
        guard let changes = try? await store.changes(in: .devices, since: nil) else { return [] }
        return changes.changed
            .compactMap { try? CloudRecords.openDevice($0, key: key) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

}
