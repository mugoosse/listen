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
    /// Something asked for a sync while one was already going.
    private var again = false
    private var subscribed = false
    private var passID: UUID?

    /// What the last pass did, for the Devices pane to show. A sync that
    /// reports nothing is indistinguishable from one that silently failed.
    private(set) var lastReport: CloudReport?
    private(set) var lastRun: Date?
    private(set) var devices: [CloudRecords.DeviceBlob] = []
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

        guard let key = KeyStore.shared.load() else {
            var report = CloudReport()
            report.errors.append("No sync key yet.")
            lastReport = report
            return report
        }

        let state = EngineState(library: library)
        // Adopt whatever the LAN transport agreed last, once, then remove the
        // legacy merge base and device registry from the library. Neither is
        // consulted after this point, and leaving per-device state inside the
        // replicated tree would keep the retired transport alive on disk.
        state.adoptLegacyBase(from: library)
        try? FileManager.default.removeItem(
            at: library.root.appendingPathComponent("devices.json"))

        let identity = state.identity(name: Host.current().localizedName ?? "Mac", kind: "Mac")
        let store = CloudKitStore(containerID: CloudAccount.containerID)
        let core = CloudSyncCore(
            library: library, state: state, store: store,
            key: key, policy: .mac, device: identity.id, ingests: true,
            progress: { message in
                Task { @MainActor in
                    guard CloudSyncHost.shared.passID == pass else { return }
                    CloudSyncHost.shared.progress = message
                }
            })

        // Ask to be told rather than asking repeatedly. A Mac keeps
        // voiceprints, so it subscribes to all four zones; a phone does not,
        // and is not woken by another Mac teaching itself a voice.
        if !subscribed {
            await store.subscribe(to: CloudNaming.Zone.allCases)
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
        // Claim before downloading, and prefer whichever Mac was chosen to keep
        // phone recordings. Empty means no preference and the first Mac awake
        // takes it.
        let preferred = Settings.preferredTranscriber
        await core.ingest(preferred: preferred.isEmpty ? nil : preferred, into: &report)

        // Anything that arrived may be a recording with audio and no
        // transcript, which is the definition of a pending job.
        if report.pulledRecordings > 0 || report.claimed > 0 { Queue.shared.resume() }

        lastReport = report
        trace("cloud sync: \(report.summary)")
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
        let library = ListenKit.Library.mac()
        let state = EngineState(library: library)
        guard let holder = state.base[audioOn: id] else { return nil }
        guard holder != state.identity(name: Host.current().localizedName ?? "Mac",
                                       kind: "Mac").id else { return nil }
        return shared.devices.first { $0.id == holder }?.name
            ?? "your other Mac"
    }
}
