import AppKit
import Foundation

/// The Claude app as an MCP client, connected for the user rather than by
/// hand-edited JSON.
///
/// The Developers pane has always shown the configuration block with a copy
/// button, and that is the right floor: it works for every MCP client ever
/// written. It is also a wall for exactly the person most likely to own the
/// Claude app and least likely to own a terminal. The app's config file is a
/// JSON file at a known path, so Listen can do the paste itself, and the only
/// honest reasons not to were the failure modes; they are each handled here
/// rather than wished away:
///
/// - **A malformed file is never clobbered.** The Claude app and other tools
///   write this file too, and "I connected Listen and my other servers
///   disappeared" is worse than any error message. Unparseable JSON is
///   refused with the reason, and the file is left byte-for-byte alone.
/// - **The first write makes a backup** beside the file, once, and never
///   rewrites it: the backup's value is being the file from before Listen
///   ever touched it.
/// - **Only `mcpServers.listen` is written.** Everything else, foreign
///   servers and unknown top-level keys alike, is carried through the
///   re-serialisation untouched in content (formatting is JSON-normalised,
///   which the Claude app itself also does on save).
/// - **The Claude app reads the file at launch**, so connecting while it runs
///   changes nothing until it is restarted. The pane says so and offers the
///   restart instead of leaving that discovery to the user.
///
/// `LISTEN_CLAUDE_CONFIG` points everything here at a scratch file, which is
/// what `verify_desktop_connect.sh` drives; the same pattern as
/// `LISTEN_LIBRARY`.
enum ClaudeDesktop {
    static let bundleID = "com.anthropic.claudefordesktop"

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var isInstalled: Bool { appURL != nil }

    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// Set by `runCLI` for `--config`, so the flag and the environment
    /// override cannot disagree about which file everything here means.
    static var overrideURL: URL?

    static var configURL: URL {
        if let overrideURL { return overrideURL }
        if let override = ProcessInfo.processInfo.environment["LISTEN_CLAUDE_CONFIG"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json")
    }

    /// The one entry this type is allowed to write.
    private static var desired: [String: Any] {
        ["command": MCPConfig.command, "args": ["mcp"]]
    }

    enum State: Equatable {
        case notInstalled
        case notConnected
        /// Connected, and pointing at the command this build would write.
        case connected
        /// A `listen` entry exists and points somewhere else, usually a
        /// previous install location. `connect()` repairs it.
        case connectedElsewhere(String)
        /// The file exists and cannot be parsed, with the reason. Connecting
        /// is refused in this state.
        case brokenConfig(String)
    }

    static func state() -> State {
        // A pointed-at scratch config is a stand-in for the app being there,
        // which is what lets the verify script run on a machine without it.
        let overridden = overrideURL != nil
            || ProcessInfo.processInfo.environment["LISTEN_CLAUDE_CONFIG"] != nil
        guard isInstalled || overridden else { return .notInstalled }
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return .notConnected }
        let object: [String: Any]
        do {
            object = try parse(url)
        } catch {
            return .brokenConfig(error.localizedDescription)
        }
        guard let servers = object["mcpServers"] as? [String: Any],
              let listen = servers["listen"] as? [String: Any] else { return .notConnected }
        let command = listen["command"] as? String ?? ""
        let args = listen["args"] as? [String] ?? []
        if command == MCPConfig.command, args == ["mcp"] { return .connected }
        return .connectedElsewhere(command)
    }

    struct Refusal: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    struct Outcome {
        /// False when the entry was already exactly right and nothing was
        /// written, backup included.
        let changed: Bool
        let message: String
    }

    /// Add or repair `mcpServers.listen`, and nothing else.
    @discardableResult
    static func connect(dryRun: Bool = false) throws -> Outcome {
        let url = configURL
        var object: [String: Any] = [:]
        let exists = FileManager.default.fileExists(atPath: url.path)
        if exists {
            do {
                object = try parse(url)
            } catch {
                // The refusal is the feature. Overwriting a file the user or
                // another tool broke would take their other servers with it.
                throw Refusal(reason: "The Claude app's configuration at "
                    + "\(url.path) is not valid JSON, so nothing was changed. "
                    + "Fix or delete that file and try again. "
                    + "(\(error.localizedDescription))")
            }
        }
        if object["mcpServers"] != nil, !(object["mcpServers"] is [String: Any]) {
            throw Refusal(reason: "The Claude app's configuration has an "
                + "`mcpServers` entry that is not an object, so nothing was changed.")
        }
        var servers = object["mcpServers"] as? [String: Any] ?? [:]

        if let listen = servers["listen"] as? [String: Any],
           listen["command"] as? String == MCPConfig.command,
           listen["args"] as? [String] == ["mcp"] {
            return Outcome(changed: false,
                           message: "Already connected. Restart the Claude app "
                               + "if it does not show Listen yet.")
        }
        if dryRun {
            return Outcome(changed: true,
                           message: "Would write mcpServers.listen "
                               + "(\(MCPConfig.command) mcp) into \(url.path).")
        }

        // Once, and never rewritten: the backup's value is being the file
        // from before Listen ever touched it.
        let backup = url.deletingPathExtension()
            .appendingPathExtension("json.listen-backup")
        if exists, !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: url, to: backup)
        }

        servers["listen"] = desired
        object["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)

        // Read back rather than trusted: a write that half-landed is exactly
        // the state this whole type exists to avoid leaving behind.
        guard case .connected = state() else {
            throw Refusal(reason: "The entry was written but did not read back. "
                + "Check \(url.path) by hand; the previous file is beside it "
                + "as \(backup.lastPathComponent).")
        }
        return Outcome(changed: true,
                       message: "Connected. Quit and reopen the Claude app to "
                           + "pick it up.")
    }

    /// Prove the served side answers: the same binary the config names, asked
    /// for its tool list the way `verify_note_tags.sh` asks. A config entry
    /// pointing at a binary that cannot serve is a connection in name only.
    static func serves() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MCPConfig.command)
        process.arguments = ["mcp"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let request = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"# + "\n"
        input.fileHandleForWriting.write(Data(request.utf8))
        input.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate() }
        let said = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8) ?? ""
        return said.contains("list_recordings")
    }

    /// Quit the Claude app and open it again, because it reads the config at
    /// launch and nothing else re-reads it.
    static func restart(_ completion: @escaping (Bool) -> Void) {
        guard let url = appURL else { completion(false); return }
        guard let app = running else {
            NSWorkspace.shared.openApplication(at: url,
                                               configuration: .init()) { opened, _ in
                DispatchQueue.main.async { completion(opened != nil) }
            }
            return
        }
        // `terminate`, never `forceTerminate`: the app may be holding an
        // unsent draft, and losing it to a Listen button would be remembered
        // longer than the connector.
        app.terminate()
        var waited = 0
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                waited += 1
                if app.isTerminated {
                    NSWorkspace.shared.openApplication(at: url,
                                                       configuration: .init()) { opened, _ in
                        DispatchQueue.main.async { completion(opened != nil) }
                    }
                } else if waited < 20 {
                    poll()
                } else {
                    // It declined to quit, which is its right. The connection
                    // is written either way; the user restarts it when ready.
                    completion(false)
                }
            }
        }
        poll()
    }

    private static func parse(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        // An empty file is a config nobody has written yet, not a broken one.
        if data.isEmpty { return [:] }
        let parsed = try JSONSerialization.jsonObject(with: data)
        guard let object = parsed as? [String: Any] else {
            throw Refusal(reason: "the top level is not an object")
        }
        return object
    }

    /// `listen mcp connect-desktop [--config PATH] [--dry-run]`, the headless
    /// twin of the pane's button, and what `verify_desktop_connect.sh` drives.
    static func runCLI(_ arguments: [String]) -> Never {
        var arguments = arguments
        if let flag = arguments.firstIndex(of: "--config") {
            guard arguments.indices.contains(flag + 1) else {
                FileHandle.standardError.write(Data("--config needs a path\n".utf8))
                exit(2)
            }
            overrideURL = URL(fileURLWithPath: arguments[flag + 1])
            arguments.removeSubrange(flag...(flag + 1))
        }
        let dryRun = arguments.contains("--dry-run")
        do {
            let outcome = try connect(dryRun: dryRun)
            print(outcome.message)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
