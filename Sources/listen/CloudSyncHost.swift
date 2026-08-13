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
        guard Settings.cloudSync, timer == nil else { return }

        // Anything that rewrites a recording's metadata is worth sending.
        //
        // A meeting recorded here, transcribed, and then titled reached the
        // phone still called "Untitled", because the title was written after
        // the last thing that asked for a sync and nothing before the two
        // minute poll had any reason to ask again. Coalesced by `syncSoon`, so
        // a capture rewriting its metadata repeatedly still costs one pass.
        RecordingEvents.changed = {
            Task { @MainActor in CloudSyncHost.shared.syncSoon() }
        }
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
        guard Settings.cloudSync else { return }
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
        guard !running else { return lastReport ?? CloudReport() }
        running = true
        let pass = UUID()
        passID = pass
        progress = "Starting"
        defer { running = false; passID = nil; progress = nil; lastRun = Date() }

        let library = ListenKit.Library.mac()

        // Keep adopting rather than deleting the old file in this pass.
        // `KeyMigration` is the recovery path if the shared item is missing,
        // and removing its source before removing the migration would turn a
        // recoverable keychain problem into a Mac that silently stops syncing.
        KeyMigration.adoptFileKey(from: library)

        guard let key = KeyStore.shared.load() ?? FileKeyStore(library: library).load() else {
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
        return report
    }
}
