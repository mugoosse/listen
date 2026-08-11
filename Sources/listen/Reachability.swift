import Foundation
import Network

/// Whether this Mac has a route out, and whether a given host answers on it.
///
/// This exists because neither agent CLI says, which was measured rather than
/// assumed. Against a blackholed API (192.0.2.1, packets dropped rather than
/// refused, which is what an unplugged uplink looks like):
///
/// - `claude -p --output-format stream-json` ran for 100 seconds emitting
///   nothing but its own hook events, wrote nothing to stderr and did not exit.
/// - `codex exec --json` ran the same 100 seconds, printed `thread.started` and
///   `turn.started`, then nothing. Its only stderr was a models-manager
///   timeout, which names neither the network nor the question.
///
/// With the connection outright *refused* rather than dropped, `claude` got as
/// far as `system init` and then sat silent for 90 more seconds. So even the
/// fast, unambiguous network error is retried in silence for longer than
/// anybody will wait, and waiting for the CLI to report it is not a design.
///
/// Two halves, because one of them is a lie on its own:
///
/// - `offline()` is the path, from `NWPathMonitor`. Cheap, continuous, no
///   traffic. `.unsatisfied` means no interface can carry anything, which is
///   definite; `.satisfied` only means an interface exists.
/// - `answers(_:)` opens a TCP connection to a named host. Costly, occasional,
///   and the only one of the two that can see a Wi-Fi network whose router is
///   up and whose uplink is not, which is the commonest way an internet
///   connection is actually gone.
enum Reachability {
    /// Forced answers, for measurement, and deliberately not for users.
    ///
    /// `LISTEN_OFFLINE=1` makes every check say offline, which is the whole
    /// pre-flight path without touching the Mac's connection.
    /// `LISTEN_PROBE_HOST` replaces the host `answers` opens a connection to:
    /// point it at `192.0.2.1`, which is reserved and drops packets rather than
    /// refusing them, and a run whose CLI is pointed at the same address by
    /// `ANTHROPIC_BASE_URL` reproduces the silent hang end to end.
    ///
    /// Without these the only way to test any of this is to unplug the machine,
    /// which is a thing nobody does twice and so a thing nobody checks again
    /// after the first time.
    ///
    /// **`LISTEN_OFFLINE` also takes a path**, and then it means offline for as
    /// long as that file exists. An environment variable cannot change under a
    /// running app, and the one thing worth watching is the moment a connection
    /// **comes back**: Try again is only interesting when the retry succeeds.
    /// A file somebody can delete mid-question is the smallest thing that
    /// expresses that.
    private static let offlineSwitch = ProcessInfo.processInfo.environment["LISTEN_OFFLINE"]

    private static var forcedOffline: Bool {
        guard let offlineSwitch, !offlineSwitch.isEmpty else { return false }
        if offlineSwitch == "1" { return true }
        return FileManager.default.fileExists(atPath: offlineSwitch)
    }
    private static let probeHost = ProcessInfo.processInfo.environment["LISTEN_PROBE_HOST"]

    private static let monitor = NWPathMonitor()
    private static let queue = DispatchQueue(label: "listen.reachability")
    private static let lock = NSLock()

    /// `nil` until the first path update lands. Never treated as offline: a
    /// state nobody has measured yet must not stop somebody asking a question.
    private static var known: Bool?
    private static var started = false
    private static var watchers: [UUID: (Bool) -> Void] = [:]

    /// Empties when the first update arrives.
    ///
    /// A `DispatchGroup` rather than a semaphore because every waiter has to be
    /// woken, and a semaphore signalled once wakes one of them.
    private static let firstUpdate = DispatchGroup()

    /// Idempotent, and called from both ends: the app at launch, and
    /// `Reachability` itself from every question the CLI asks. A monitor that
    /// starts when the first question is asked has no answer yet when that
    /// question needs one.
    static func begin() {
        lock.lock()
        guard !started else { return lock.unlock() }
        started = true
        firstUpdate.enter()
        lock.unlock()

        monitor.pathUpdateHandler = { path in
            let online = path.status != .unsatisfied
            lock.lock()
            let first = known == nil
            let changed = known != online
            known = online
            let listeners = Array(watchers.values)
            lock.unlock()
            if first { firstUpdate.leave() }
            guard changed else { return }
            for listener in listeners { listener(online) }
        }
        monitor.start(queue: queue)
    }

    /// True only when the last path update said nothing can carry traffic.
    ///
    /// One-way on purpose. A `false` here is not a promise that anything
    /// answers, which is why nothing in this app *disables* a control on the
    /// strength of it: a wrong reading would lock a working feature, where a
    /// wrong sentence only has to be read.
    ///
    /// The wait is for the CLI, which starts the monitor and asks it in the same
    /// millisecond. In the window `begin()` ran at launch, so `known` is long
    /// since set and this returns without blocking.
    static func offline(waitingUpTo seconds: TimeInterval = 0.5) -> Bool {
        if forcedOffline { return true }
        begin()
        lock.lock()
        let answer = known
        lock.unlock()
        if let answer { return !answer }
        _ = firstUpdate.wait(timeout: .now() + seconds)
        lock.lock()
        defer { lock.unlock() }
        return known == false
    }

    /// Told when the path changes, on an unspecified queue. Hop to `.main`
    /// yourself. Watching stops when the returned token is released.
    static func watch(_ onChange: @escaping (Bool) -> Void) -> Watcher {
        begin()
        let watcher = Watcher()
        lock.lock()
        watchers[watcher.id] = onChange
        lock.unlock()
        return watcher
    }

    fileprivate static func forget(_ id: UUID) {
        lock.lock()
        watchers[id] = nil
        lock.unlock()
    }

    final class Watcher {
        fileprivate let id = UUID()
        fileprivate init() {}
        deinit { Reachability.forget(id) }
    }

    /// The host `answers` would really open a socket to, which is what anything
    /// putting the result in a sentence has to name. Without this the message
    /// said `api.anthropic.com` while `LISTEN_PROBE_HOST` sent the connection
    /// somewhere else entirely, which is a test that lies about what it tested.
    static func host(_ preferred: String) -> String { probeHost ?? preferred }

    /// Does `host` accept a TCP connection within `seconds`?
    ///
    /// Nothing is sent and nothing is read: the handshake completing is the
    /// whole answer, so this costs no request against anybody's account and
    /// says nothing about whether the credentials are any good.
    ///
    /// `.waiting` counts as no. That is the state `NWConnection` sits in when
    /// there is no route, and it will sit there indefinitely rather than fail,
    /// which is the same trap as the CLIs one level down.
    static func answers(_ host: String, port: UInt16 = 443,
                        within seconds: TimeInterval = 5,
                        then body: @escaping (Bool) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: port) else { return body(false) }
        let connection = NWConnection(host: .init(self.host(host)), port: port, using: .tcp)
        // Both the handler and the deadline run on `queue`, which is serial, so
        // this needs no lock of its own.
        var settled = false
        let settle: (Bool) -> Void = { ok in
            guard !settled else { return }
            settled = true
            connection.cancel()
            body(ok)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:                     settle(true)
            case .failed, .cancelled, .waiting: settle(false)
            default:                         break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + seconds) { settle(false) }
    }
}
