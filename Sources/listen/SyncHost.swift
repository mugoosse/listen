import Foundation
import ListenKit

/// The LAN server, running inside the app rather than as a daemon.
///
/// A holding position, and a deliberately small one. `listen-sync` was a
/// LaunchAgent because the recorder should not have to hold a socket open to
/// be useful; that argument dies with the socket at Phase 6, and until then
/// somebody's phone still has to be able to reach their Mac. Putting it here
/// rather than reinstating the agent means there is one thing to install
/// instead of two, and no plist to be quietly not running.
///
/// It starts only when there is a key. An unpaired Mac opens no port at all,
/// which is the right default for a feature most people never turn on: the
/// permission prompt, the firewall dialog and the open socket all arrive when
/// somebody pairs a phone, and never before.
@MainActor
final class SyncHost {
    static let shared = SyncHost()

    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func startIfPaired(port: UInt16 = 8787) {
        guard task == nil else { return }
        guard let key = SyncCLI.keyStore.load() else {
            trace("sync: no pairing key, so no listener")
            return
        }
        let library = ListenKit.Library.mac()
        task = Task.detached(priority: .utility) {
            do {
                try await SyncServer(library: library, key: key,
                                     transcribes: true).serve(port: port)
            } catch {
                // A port already in use is the ordinary case: a second copy of
                // Listen, or a `listen sync serve` left running in a terminal.
                // Said once, at trace level, because the recorder works
                // perfectly well without a listener and a modal about it would
                // be worse than the thing it reports.
                trace("sync: not listening (\(error.localizedDescription))")
            }
        }
        trace("sync: listening on \(port)")
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
