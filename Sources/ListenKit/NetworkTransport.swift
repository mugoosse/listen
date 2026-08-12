import Foundation
import Network

/// A continuation that may only be resumed once, safely, from any thread.
///
/// Network.framework calls its handlers on its own queue and calls some of
/// them more than once: a connection can report `.failed` after `.ready`, and
/// a browser reports results repeatedly. Resuming a continuation twice is a
/// crash rather than a warning, so the guard has to be real rather than a
/// captured `Bool`.
final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ value: T) {
        lock.lock(); let k = continuation; continuation = nil; lock.unlock()
        k?.resume(returning: value)
    }

    func fail(_ error: Error) {
        lock.lock(); let k = continuation; continuation = nil; lock.unlock()
        k?.resume(throwing: error)
    }
}

/// One connection, framed. Shared by both ends so the framing can only be
/// wrong in one place.
public actor Channel {
    private let connection: NWConnection
    private var buffer = Data()

    public init(_ connection: NWConnection) { self.connection = connection }

    /// Every await here is wrapped in `withTaskCancellationHandler`, and the
    /// cancel action is `connection.cancel()`.
    ///
    /// This is what makes `withTimeout` work at all. A `CheckedContinuation`
    /// ignores cancellation, and a task group **awaits its children before it
    /// returns even when the body throws**, so a timeout that fires against a
    /// continuation nothing will ever resume does not abandon the operation: it
    /// hangs the whole group for ever. Cancelling the connection is the only
    /// thing that makes Network.framework deliver the terminal state that
    /// resumes it.
    ///
    /// Measured on 2026-08-08. The Mac's server was killed mid-request, this
    /// task never returned, and `AppModel.sync`'s `defer { syncing = false }`
    /// therefore never ran. `syncing` stayed true for the life of the process,
    /// so every later sync returned at its `guard` and the phone stopped
    /// talking to the Mac entirely, with a permanently greyed "Sync now" and
    /// no packets on the wire. Only force-quitting the app cleared it.
    public func start() async throws {
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let once = Once(k)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.resume(())
                    case .failed(let e): once.fail(e)
                    case .cancelled: once.fail(SyncError.disconnected)
                    default: break
                    }
                }
                connection.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func send(_ data: Data) async throws {
        let connection = self.connection
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                let once = Once(k)
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error { once.fail(error) } else { once.resume(()) }
                })
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Read exactly `count` bytes, or throw. Network.framework hands back
    /// whatever has arrived, so everything above this needs a function that
    /// does not return short: a header read that returns three of four bytes
    /// desynchronises the stream for the rest of the session, and the symptom
    /// is a frame length in the gigabytes rather than an error.
    private func read(_ count: Int) async throws -> Data {
        let connection = self.connection
        while buffer.count < count {
            let chunk: Data = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
                    let once = Once(k)
                    connection.receive(minimumIncompleteLength: 1,
                                       maximumLength: 256 * 1024) { data, _, isComplete, error in
                        if let error { once.fail(error) }
                        else if let data, !data.isEmpty { once.resume(data) }
                        else if isComplete { once.fail(SyncError.disconnected) }
                        else { once.resume(Data()) }
                    }
                }
            } onCancel: {
                connection.cancel()
            }
            // An empty chunk ends the read rather than going round again. We
            // asked for at least one byte, so a callback carrying none and not
            // reporting completion has nothing left to give; looping on it
            // spins this actor for ever on a connection that will never
            // deliver, which is the same "sync never returns" failure the
            // cancellation handlers above exist to prevent.
            if chunk.isEmpty { throw SyncError.disconnected }
            buffer.append(chunk)
        }
        let out = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(out)
    }

    private func readLength() async throws -> Int {
        let d = try await read(4)
        let n = Int(d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard n >= 0, n <= Wire.maxFrame else { throw SyncError.oversizedFrame(n) }
        return n
    }

    public func readFrame() async throws -> (header: Data, body: Data) {
        let h = try await read(try await readLength())
        let b = try await read(try await readLength())
        return (h, b)
    }

    public func writeFrame(_ header: Data, body: Data = Data()) async throws {
        try await send(Wire.frame(header, body: body))
    }

    public func close() { connection.cancel() }
}

public enum SyncError: Error, LocalizedError, Sendable {
    case disconnected
    case oversizedFrame(Int)
    case notPaired
    case refused(String)
    case noMacFound
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .disconnected: return "The Mac stopped responding."
        case .oversizedFrame(let n): return "A message was too large to be real (\(n) bytes)."
        case .notPaired: return "This iPhone has not been paired with a Mac yet."
        case .refused(let m): return m
        case .noMacFound: return "No Mac running Listen was found on this network."
        case .timedOut:
            // Name the likely cause, because iOS gives no error for it at all.
            // A denied local network permission does not fail a connection, it
            // simply never completes it, so this message is the only place a
            // user can be told what to go and change.
            return "Your Mac did not answer. If this keeps happening, check "
                 + "Settings, Privacy & Security, Local Network, and make sure "
                 + "Listen is allowed."
        }
    }
}

/// Run an operation, or give up.
///
/// Every network call in this file goes through this. Without it a sync can
/// hang for ever and present as a spinner that never stops: `NWConnection`
/// waits indefinitely for a `.ready` that a blocked connection never sends,
/// and **iOS reports a denied local network permission by doing nothing at
/// all** rather than by failing. A timeout is the only way the app can ever
/// find out.
func withTimeout<T: Sendable>(_ seconds: Double,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SyncError.timedOut
        }
        guard let first = try await group.next() else { throw SyncError.timedOut }
        group.cancelAll()
        return first
    }
}

/// The Bonjour type both ends agree on. Bonjour is only how the two find each
/// other without anybody typing an IP address; it is not the security boundary,
/// which is the paired key.
public let listenServiceType = "_listen-sync._tcp"

// MARK: - Client, used by the phone

public struct SyncClient: Sendable {
    public let endpoint: NWEndpoint
    public let key: PairingKey
    public let deviceID: String
    public let deviceName: String

    public init(endpoint: NWEndpoint, key: PairingKey,
                deviceID: String = "", deviceName: String = "") {
        self.endpoint = endpoint; self.key = key
        self.deviceID = deviceID; self.deviceName = deviceName
    }

    /// One request, one connection. Deliberately not a pooled long-lived
    /// socket: a phone sleeps, changes network and gets suspended by the OS
    /// mid-transfer, so a connection that must survive all of that is a
    /// connection that will be observed to fail in ways nobody can reproduce.
    /// `timeout` overrides the default only for callers that are probing
    /// rather than working. Deciding which of two addresses answers should not
    /// cost 20 seconds per wrong guess: see `AppModel.endpoint`.
    public func send(_ request: Request, body: Data = Data(),
                     timeout: Double? = nil) async throws -> (Response, Data) {
        // A chunk is 4 MB, so the ceiling has to cover a slow upload as well as
        // a fast manifest. Generous enough not to abandon real work on a weak
        // signal, short enough that a blocked connection is reported rather
        // than spun on for ever.
        try await withTimeout(timeout ?? (body.isEmpty ? 20 : 120)) {
            try await self.exchange(request, body: body)
        }
    }

    private func exchange(_ request: Request, body: Data) async throws -> (Response, Data) {
        let params = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: params)
        let channel = Channel(connection)
        try await channel.start()
        defer { Task { await channel.close() } }

        var request = request
        request.token = key.token
        request.deviceID = deviceID.isEmpty ? nil : deviceID
        request.deviceName = deviceName.isEmpty ? nil : deviceName
        let header = try JSONEncoder().encode(request)
        let sealed = body.isEmpty ? Data() : try key.seal(body)
        try await channel.writeFrame(header, body: sealed)

        let (rh, rb) = try await channel.readFrame()
        let response = try JSONDecoder().decode(Response.self, from: rh)
        guard response.ok else { throw SyncError.refused(response.error ?? "refused") }
        let opened = rb.isEmpty ? Data() : try key.open(rb)
        return (response, opened)
    }
}

/// Find a Mac running `listen-sync` on this network.
public final class MacBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    public init() {}

    public func find(timeout: TimeInterval = 5) async -> [NWEndpoint] {
        (try? await withCheckedThrowingContinuation { k in
            let once = Once(k)
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: listenServiceType, domain: nil),
                                    using: params)
            self.browser = browser
            browser.browseResultsChangedHandler = { results, _ in
                if !results.isEmpty { once.resume(results.map(\.endpoint)) }
            }
            browser.start(queue: .global())
            // Resolve empty rather than hanging: "no Mac on this network" is a
            // normal answer the UI has to be able to show.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume([]) }
        }) ?? []
    }

    public func stop() { browser?.cancel() }
}
