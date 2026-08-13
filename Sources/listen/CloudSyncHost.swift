import Foundation
import ListenKit

/// The CloudKit sync, running by itself while the app is open.
///
/// The counterpart to `SyncHost`, which answers a phone over the LAN. That one
/// exists until Phase 6 and this one replaces it: there is no socket here, no
/// address to find, no permission that fails by never completing, and nothing
/// that needs both devices awake at once.
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

    /// What the last pass did, for the Devices pane to show. A sync that
    /// reports nothing is indistinguishable from one that silently failed.
    private(set) var lastReport: CloudReport?
    private(set) var lastRun: Date?
    private(set) var devices: [CloudRecords.DeviceBlob] = []

    /// Every two minutes while the app is open.
    ///
    /// A poll rather than a push subscription, for now. `CKSyncEngine`'s silent
    /// pushes are what make this arrive within seconds rather than within
    /// minutes, and they are worth adding, but a poll is what makes the feature
    /// correct and a push only makes it prompt.
    private let interval: TimeInterval = 120

    func startIfEnabled() {
        guard Settings.cloudSync, timer == nil else { return }
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
        defer { running = false; lastRun = Date() }

        let library = ListenKit.Library.mac()

        // The key moves to the iCloud Keychain the first time CloudKit runs,
        // which is the point at which a second Mac becomes possible. Copied
        // rather than moved: the LAN transport still reads the file and every
        // device already paired is paired against it.
        KeyMigration.adoptFileKey(from: library)

        guard let key = KeyStore.shared.load() ?? SyncCLI.keyStore.load() else {
            var report = CloudReport()
            report.errors.append("No pairing key yet.")
            lastReport = report
            return report
        }

        let state = EngineState(library: library)
        // Adopt whatever the LAN transport agreed last, once, so the first
        // CloudKit pass does not report a conflict on every note this Mac has
        // ever edited.
        state.adoptLegacyBase(from: library)

        let identity = state.identity(name: Host.current().localizedName ?? "Mac", kind: "Mac")
        let store = CloudKitStore(containerID: CloudAccount.containerID)
        let core = CloudSyncCore(
            library: library, state: state, store: store,
            key: key, policy: .mac, device: identity.id, ingests: true)

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
        let firstEver = state.base[file: "token"] == nil
        if firstEver {
            await core.pull(into: &report)
            await core.pullVoiceprints(into: &report)
        }

        await core.push(into: &report)
        await core.pushVoiceprints(into: &report)
        // Claim before downloading, and prefer whichever Mac was chosen to keep
        // phone recordings. Empty means no preference and the first Mac awake
        // takes it.
        let preferred = Settings.preferredTranscriber
        await core.ingest(preferred: preferred.isEmpty ? nil : preferred, into: &report)
        if !firstEver {
            await core.pull(into: &report)
            await core.pullVoiceprints(into: &report)
        }

        // Anything that arrived may be a recording with audio and no
        // transcript, which is the definition of a pending job.
        if report.pulledRecordings > 0 || report.claimed > 0 { Queue.shared.resume() }

        lastReport = report
        trace("cloud sync: \(report.summary)")
        return report
    }
}
