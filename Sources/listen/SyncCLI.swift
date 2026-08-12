import Foundation
import Network
import ListenKit

/// `listen sync …`, which used to be a separate binary called `listen-sync`.
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
/// a profile has to be embedded in a bundle, and `listen-sync` was a file in
/// `~/.local/bin`. It could never have reached a container from there.
///
/// The verbs keep their names and their arguments, because
/// `spec/05-testing.md`'s harnesses are the way every seam here is proved and
/// they should not have to be rewritten to prove the same things.
enum SyncCLI {
    static func run(_ args: [String]) async -> Never {
        var rest = Array(args.dropFirst())
        switch args.first ?? "help" {
        case "status":   status()
        case "pair":     pair(&rest)
        case "serve":    await serve(&rest)
        case "manifest": manifest()
        case "run":      await runEngine(&rest)
        case "note":     note(&rest)
        case "devices":  devices(&rest)
        case "--fake":   await fake(&rest)
        case "cloud":    await cloud(&rest)
        case "inspect":  await inspect(&rest)
        case "enable":   enable(&rest)
        default:         help()
        }
    }

    // MARK: - Shared

    /// The library this Mac is serving, honouring `LISTEN_LIBRARY` exactly as
    /// the rest of Listen does, so a scratch library works here too.
    private static var library: ListenKit.Library { .mac() }

    /// The pairing key, still read from `.pairing-key` beside the library.
    ///
    /// `FileKeyStore` existed because `listen-sync` was a bare binary and
    /// Listen is a signed app, and a keychain item made by the first prompts
    /// for authorisation when the second reads it. That constraint died with
    /// this file, so the key is free to move into the iCloud Keychain, which
    /// is what makes a second Mac need nothing typed.
    ///
    /// It has not moved yet, and moving it silently would be the wrong way to
    /// do it. Every phone already paired is paired against **this** key: read
    /// a different store and the Mac answers with a key nobody holds, which
    /// presents as a phone that can see the Mac and is refused by it. Measured
    /// here, by doing exactly that. The move happens with a migration that
    /// adopts this file, at the point the rest of the key handling changes.
    static var keyStore: FileKeyStore { FileKeyStore(library: library) }

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
        let store = SyncCLI.keyStore
        print("library:     \(library.root.path)")
        // Both stores, because during the migration the key can be in either
        // and "none yet" while it sits in a file is a lie that sends somebody
        // hunting for a pairing problem they do not have.
        let inFile = store.load() != nil
        let inCloud = KeyStore.shared.load() != nil
        print("key:         " + (inFile && inCloud ? "beside the library, and in iCloud Keychain"
                                 : inFile ? "beside the library only, not yet in iCloud Keychain"
                                 : inCloud ? "from iCloud Keychain" : "none yet"))
        print("environment: \(CloudAccount.environment)")
        print("container:   \(CloudAccount.containerID)")
        let semaphore = DispatchSemaphore(value: 0)
        var line = "unknown"
        CloudAccount.status { line = $0; semaphore.signal() }
        _ = semaphore.wait(timeout: .now() + 20)
        print("account:     \(line)")
        done()
    }

    private static func pair(_ args: inout [String]) -> Never {
        let store = SyncCLI.keyStore
        // Replacing a key that already exists unpairs every device holding it,
        // and this command is called by the test harnesses. One of them ran
        // without LISTEN_LIBRARY set, rotated the real key, and the only
        // symptom was that the phone quietly stopped reaching a Mac it could
        // still see. So a replacement has to be asked for twice.
        let replacing = flag("--new", &args)
        let force = flag("--force", &args)
        if replacing, store.load() != nil, !force {
            die("""
                There is already a key for \(library.root.path).

                Replacing it stops every paired device syncing until it is given
                the new one. If that is what you want:

                    listen sync pair --new --force

                To make a key for a scratch library instead, set LISTEN_LIBRARY.
                """)
        }
        if replacing || store.load() == nil {
            guard store.save(PairingKey.generate()) else { die("could not save the key") }
        }
        guard let key = store.load() else { die("no key") }
        print(key.code)
        done()
    }

    private static func manifest() -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = (try? encoder.encode(SyncServer.manifest(of: library))) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        done()
    }

    private static func serve(_ args: inout [String]) async -> Never {
        guard let key = SyncCLI.keyStore.load() else {
            die("not paired yet. Run:  listen sync pair --new")
        }
        let port = UInt16(option("--port", &args) ?? "8787") ?? 8787
        let transcribes = !flag("--no-transcribe", &args)
        do {
            try await SyncServer(library: library, key: key,
                                 transcribes: transcribes).serve(port: port)
        } catch {
            die("could not serve: \(error.localizedDescription)")
        }
        done()
    }

    /// Run the *phone's* engine from this terminal, against a scratch library.
    ///
    /// The seam that would otherwise need a simulator. It refuses to touch the
    /// real library, because the whole point is to prove sync logic without
    /// risking the thing it operates on.
    private static func runEngine(_ args: inout [String]) async -> Never {
        guard let key = SyncCLI.keyStore.load() else { die("not paired") }
        guard let root = option("--library", &args) else {
            die("--library <dir> is required, and must not be the real one")
        }
        let host = option("--to", &args) ?? "127.0.0.1"
        let port = UInt16(option("--port", &args) ?? "8787") ?? 8787
        let keepAudio = flag("--keep-audio", &args)
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: port)!)
        let engine = SyncEngine(library: ListenKit.Library(root: URL(fileURLWithPath: root)),
                                client: SyncClient(endpoint: endpoint, key: key),
                                keepAudioLocally: keepAudio)
        let report = await engine.run()
        print(report.summary)
        for conflict in report.conflicts { print("conflict: \(conflict)") }
        for error in report.errors { print("error: \(error)") }
        exit(report.errors.isEmpty ? 0 : 1)
    }

    /// Edit a note the way an app does, through `writeNote`, so `updated` is
    /// stamped by the one function allowed to stamp it. A test that edits the
    /// markdown directly proves nothing, because nothing on either device does.
    private static func note(_ args: inout [String]) -> Never {
        guard let root = option("--library", &args) else { die("--library <dir> is required") }
        guard let slug = option("--slug", &args) else { die("--slug <name> is required") }
        let target = ListenKit.Library(root: URL(fileURLWithPath: root))
        let body = option("--body", &args) ?? ""
        let title = option("--title", &args)
        let existing = target.note(slug)
        let note = ListenKit.Note(
            slug: slug,
            title: title ?? existing?.title ?? slug,
            created: existing?.created ?? ListenKit.Metadata.stamp(Date()),
            updated: existing?.updated ?? "",
            source: existing?.source ?? "you",
            recordings: existing?.recordings ?? [],
            body: body.isEmpty ? (existing?.body ?? "") : body,
            // Provenance is carried through. Editing a note is not a reason to
            // forget which conversation it came from.
            prompt: existing?.prompt,
            chat: existing?.chat,
            extra: existing?.extra ?? [:])
        do {
            try target.writeNote(note, expecting: existing?.version)
            print(target.note(slug)?.updated ?? "")
        } catch let conflict as NoteConflict {
            die("conflict: \(conflict.theirs.slug) was written by somebody else")
        } catch {
            die(error.localizedDescription)
        }
        done()
    }

    private static func devices(_ args: inout [String]) -> Never {
        var registry = DeviceRegistry.load(library)
        if let id = option("--revoke", &args) {
            registry.revoke(id); registry.save(library); print("revoked \(id)")
        } else if let id = option("--forget", &args) {
            registry.forget(id); registry.save(library); print("forgot \(id)")
        }
        if registry.devices.isEmpty {
            print("No devices have connected yet.")
        } else {
            for d in registry.devices {
                print("\(d.revoked ? "revoked " : "        ")\(d.name)")
                print("          last seen \(d.lastSeenPhrase)   \(d.id)")
            }
        }
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
        guard let key = SyncCLI.keyStore.load() else { die("not paired") }
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

        // A device says it is here before anything else, so the settings pane
        // on every other device can say when it last was.
        await core.heartbeat(name: name, kind: isPhone ? "iPhone" : "Mac",
                             appVersion: AppInfo.version ?? "unknown")

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
    private static func inspect(_ args: inout [String]) async -> Never {
        guard let key = SyncCLI.keyStore.load() else { die("not paired") }
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
          pair [--new [--force]]          show the pairing code, or make one
          serve [--port N]                serve this library over the network
          devices [--revoke ID|--forget ID]
          manifest                        what a device would be offered
          run --library D [--to H]        run a device's engine from here
          note --library D --slug S       write a note the way an app does
          --fake                          every seam of the CloudKit sync, offline
          cloud --library D               one pass against the real container\n          inspect                         what is in the container, by zone\n          enable [--on|--off]             sync this Mac's real library

        LISTEN_LIBRARY moves the library, exactly as it does for Listen itself.
        """)
        done()
    }
}
