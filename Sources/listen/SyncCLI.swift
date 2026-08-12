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
        default:         help()
        }
    }

    // MARK: - Shared

    /// The library this Mac is serving, honouring `LISTEN_LIBRARY` exactly as
    /// the rest of Listen does, so a scratch library works here too.
    private static var library: ListenKit.Library { .mac() }

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
        let store = KeyStore()
        print("library:     \(library.root.path)")
        print("key:         \(store.load() == nil ? "none yet" : "present")")
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
        let store = KeyStore()
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
        guard let key = KeyStore().load() else {
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
        guard let key = KeyStore().load() else { die("not paired") }
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

        LISTEN_LIBRARY moves the library, exactly as it does for Listen itself.
        """)
        done()
    }
}
