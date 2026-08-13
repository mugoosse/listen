import Foundation
import ListenKit

/// `listen sync …`, which used to live in a separate LAN helper.
///
/// The split was justified by two things: the recorder should not have to hold
/// a socket open to be useful, and a sync daemon should be stoppable without
/// stopping the recorder. Both were true of a LAN listener and neither survives
/// the move to CloudKit, where there is no socket and nothing to listen on. So
/// the two halves genuinely evaporate rather than moving somewhere less
/// convenient.
///
/// What forced it is smaller and harder: **a bare executable cannot hold an
/// iCloud entitlement.** Restricted entitlements need a provisioning profile,
/// a profile has to be embedded in a bundle, and that helper was a file in
/// `~/.local/bin`. It could never have reached a container from there.
///
/// Only CloudKit-facing verbs remain. The LAN listener, manifest and device
/// engine were one transport, so keeping their commands after deleting that
/// transport would advertise paths that can no longer work.
enum SyncCLI {
    static func run(_ args: [String]) async -> Never {
        var rest = Array(args.dropFirst())
        switch args.first ?? "help" {
        case "status":   status()
        case "--fake":   await fake(&rest)
        case "cloud":    await cloud(&rest)
        case "inspect":  await inspect(&rest)
        case "trash":    trash()
        case "enable":   enable(&rest)
        default:         help()
        }
    }

    // MARK: - Shared

    /// Honour `LISTEN_LIBRARY` exactly as the rest of Listen does, so a
    /// scratch CloudKit run remains isolated from the real library.
    private static var library: ListenKit.Library { .mac() }

    /// iCloud Keychain, and nothing else.
    ///
    /// There was a file beside the library and a migration that copied it into
    /// the keychain, kept through Phase 6 so that removing the source before
    /// the migration could not strand a Mac. Both Macs were then checked:
    /// `sync status` reported "from iCloud Keychain" on the second one, which
    /// has no file at all, so the net was holding nothing up.
    private static var pairingKey: PairingKey? { KeyStore.shared.load() }

    private static func option(_ name: String, _ args: inout [String]) -> String? {
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        let value = args[i + 1]
        args.removeSubrange(i...(i + 1))
        return value
    }

    private static func flag(_ name: String, _ args: inout [String]) -> Bool {
        guard let i = args.firstIndex(of: name) else { return false }
        args.remove(at: i)
        return true
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    private static func done() -> Never { exit(0) }

    // MARK: - Verbs

    /// `listen sync status`: can this build reach a CloudKit container at all.
    ///
    /// Deliberately says which environment it is signed for as well as what
    /// the account looks like. A Developer ID build can only ever reach
    /// Production, so a development build reporting a healthy account proves
    /// nothing about the one that ships, and this is the command that has to
    /// make that distinction visible rather than reassuring.
    private static func status() -> Never {
        print("library:     \(library.root.path)")
        // One store now, so one sentence. It used to name both while the file
        // was still a fallback, because saying "none yet" when the only copy
        // sat in a file sent somebody hunting a keychain problem they did not
        // have. There is nowhere else to look any more.
        print("key:         " + (KeyStore.shared.load() != nil
                                 ? "from iCloud Keychain" : "none yet"))
        print("environment: \(CloudAccount.environment)")
        print("container:   \(CloudAccount.containerID)")
        let semaphore = DispatchSemaphore(value: 0)
        var line = "unknown"
        CloudAccount.status { line = $0; semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 20)
        print("account:     \(line)")
        done()
    }

    /// Every seam of the CloudKit sync, offline, in about a second.
    ///
    /// No network, no container, no second process and no socket, which makes
    /// it faster than the loopback harness it replaces rather than slower. It
    /// runs from an unsigned `swift build` binary on purpose: nothing here
    /// touches CloudKit, so nothing here needs an entitlement.
    private static func fake(_ args: inout [String]) async -> Never {
        let root = URL(fileURLWithPath: option("--at", &args)
                       ?? NSTemporaryDirectory() + "listen-fake-sync")
        do {
            for line in try await FakeSync.run(root: root) { print(line) }
            print("\nEvery seam passed.")
            done()
        } catch {
            FileHandle.standardError.write(Data("  FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    /// One pass against the real container, for a scratch library.
    ///
    /// The slower half of the two-layer testing story. `--fake` proves the
    /// logic in a second with no network; this proves that CloudKit behaves
    /// the way the fake assumes, which is the one thing a fake can never say.
    ///
    /// It refuses to run against the real library. Everything here is
    /// deliberate practice for an operation that will later touch four years
    /// of recordings, and practising on the real thing is how you find out
    /// that you should not have.
    private static func cloud(_ args: inout [String]) async -> Never {
        guard let key = pairingKey else { die("no sync key") }
        guard let root = option("--library", &args) else {
            die("--library <dir> is required, and must not be the real one")
        }
        let scratch = ListenKit.Library(root: URL(fileURLWithPath: root))
        if scratch.root.standardizedFileURL == ListenKit.Library.mac().root.standardizedFileURL {
            die("that is the real library. Point --library somewhere else.")
        }
        let isPhone = flag("--as-phone", &args)
        let name = option("--device", &args) ?? (isPhone ? "phone" : "mac")
        let state = EngineState(library: scratch)
        let core = CloudSyncCore(
            library: scratch, state: state,
            store: CloudKitStore(containerID: CloudAccount.containerID),
            key: key, policy: isPhone ? .phone : .mac,
            device: name, ingests: !isPhone)

        var report = CloudReport()
        let pullOnly = flag("--pull-only", &args)
        let pushOnly = flag("--push-only", &args)
        let preferred = option("--preferred", &args)

        // Deliberately no heartbeat.
        //
        // A scratch run is a test, not a device, and this used to register one
        // called "mac" on every invocation. It showed up in the settings pane
        // beside the two real Macs and stayed there, because a device record is
        // only ever added. Ask with `--announce` if a run genuinely needs to be
        // seen by the others, which is the two-Mac rehearsal and nothing else.
        if flag("--announce", &args) {
            await core.heartbeat(name: name, kind: isPhone ? "iPhone" : "Mac",
                                 appVersion: AppInfo.version ?? "unknown")
        }

        if !pullOnly {
            await core.push(into: &report)
            await core.pushVoiceprints(into: &report)
            if isPhone { for r in scratch.all() { await core.upload(r, into: &report) } }
        }
        if !pushOnly {
            await core.ingest(preferred: preferred, into: &report)
            await core.pull(into: &report)
            await core.pullVoiceprints(into: &report)
        }
        print(report.summary)
        for conflict in report.conflicts { print("conflict: \(conflict)") }
        for error in report.errors { print("error: \(error)") }
        exit(report.errors.isEmpty ? 0 : 1)
    }

    /// What is actually in the container, by zone and type.
    ///
    /// The check to run before deploying the schema to Production, because
    /// after that moment no record type can be removed and no field retyped,
    /// ever. It reports names and shapes and never opens a payload: if this
    /// prints something readable, that is the bug.
    /// What a deletion took, while it can still be put back.
    ///
    /// Printing the path rather than offering a restore verb, because putting
    /// a recording back is `mv`, and a person doing it by hand is a person who
    /// has looked at what they are restoring.
    private static func trash() -> Never {
        let library = SyncCLI.library
        let root = Trash.root(in: library)
        let days = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        guard !days.isEmpty else {
            print("nothing has been deleted in the last fortnight.")
            done()
        }
        print(root.path + "\n")
        for day in days.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: day, includingPropertiesForKeys: nil)) ?? []
            print("  \(day.lastPathComponent): \(items.count) item(s)")
            for item in items.prefix(20) { print("    \(item.lastPathComponent)") }
        }
        print("\nPut one back by moving it into recordings/ or notes/.")
        done()
    }

    private static func inspect(_ args: inout [String]) async -> Never {
        if let at = args.firstIndex(of: "--forget"), at + 1 < args.count {
            await forget(args[at + 1])
        }
        guard let key = pairingKey else { die("no sync key") }
        let store = CloudKitStore(containerID: CloudAccount.containerID)
        print("container:   \(CloudAccount.containerID)")
        print("environment: \(CloudAccount.environment)\n")
        var total = 0
        for zone in CloudNaming.Zone.allCases {
            guard let changes = try? await store.changes(in: zone, since: nil) else {
                print("  \(zone.rawValue): unreachable"); continue
            }
            var byType: [String: Int] = [:]
            var opaque = true
            for record in changes.changed {
                byType[record.type.rawValue, default: 0] += 1
                // A record name that is not 64 hex characters is a record name
                // that says something, which is the whole thing this design is
                // trying not to do.
                if record.name.count != 64 || !record.name.allSatisfy(\.isHexDigit) {
                    opaque = false
                }
            }
            total += changes.changed.count
            let shape = byType.isEmpty ? "empty"
                : byType.sorted { $0.key < $1.key }
                        .map { "\($0.key)×\($0.value)" }.joined(separator: " ")
            print("  \(zone.rawValue): \(shape)\(opaque ? "" : "   NAMES ARE NOT OPAQUE")")
        }
        print("\n\(total) record(s). Nothing above was decrypted to print it.")

        // The devices, by name, because this is the one list a person has to be
        // able to read and act on. Opened rather than counted, unlike
        // everything above it: a device record is this library's own bookkeeping
        // and printing it locally reveals nothing that the settings pane does
        // not already show.
        if let changes = try? await store.changes(in: .devices, since: nil), !changes.changed.isEmpty {
            print("\ndevices:")
            for record in changes.changed {
                guard let blob = try? CloudRecords.openDevice(record, key: key) else { continue }
                print("  \(blob.id)  \(blob.name) (\(blob.kind)), \(blob.seenAgo)")
            }
            print("\n  drop one with: listen sync inspect --forget <id>")
        }
        done()
    }

    /// Take one device off the list.
    ///
    /// A tidy-up rather than a revocation: nothing about sync consults this
    /// list, and a device still running puts itself back on its next pass. What
    /// it is for is the strays, which on this library were two replaced phone
    /// installs and a scratch run, none of which will ever check in again and
    /// all of which the thirty day rule would take a month to notice.
    private static func forget(_ id: String) async -> Never {
        guard let key = pairingKey else { die("no sync key") }
        let store = CloudKitStore(containerID: CloudAccount.containerID)
        do {
            try await store.delete(CloudNaming.recordName(.device, id, key: key), in: .devices)
            print("forgot \(id)")
        } catch {
            die("could not forget \(id): \(error.localizedDescription)")
        }
        done()
    }

    /// Turn CloudKit sync on or off for this Mac's real library.
    ///
    /// Deliberately a separate verb from everything else here, and deliberately
    /// verbose about what it is about to do. Every other command in this file
    /// operates on a scratch library; this one is the first thing that points
    /// the container at four years of recordings.
    private static func enable(_ args: inout [String]) -> Never {
        if flag("--off", &args) {
            Settings.cloudSync = false
            print("CloudKit sync is off. Nothing was removed from the container.")
            done()
        }
        guard flag("--on", &args) else {
            print("""
                CloudKit sync is \(Settings.cloudSync ? "on" : "off") for
                \(library.root.path)

                  listen sync enable --on     start syncing this library
                  listen sync enable --off    stop, leaving the container as it is

                Turning it on uploads every transcript, note and speaker name in
                this library, sealed with the key beside it. Audio stays here.
                """)
            done()
        }
        Settings.cloudSync = true
        print("CloudKit sync is on for \(library.root.path).")
        print("It runs while Listen is open. `listen sync inspect` says what is up there.")
        done()
    }

    private static func help() -> Never {
        print("""
        listen sync: keeping your devices in step.

          status                          what this build can reach, and as whom
          --fake                          every seam of the CloudKit sync, offline
          cloud --library D               one pass against the real container
          inspect [--forget ID]           what is in the container, by zone
          trash                           deletions received in the last fortnight
          enable [--on|--off]             sync this Mac's real library

        LISTEN_LIBRARY moves the library, exactly as it does for Listen itself.
        """)
        done()
    }
}
