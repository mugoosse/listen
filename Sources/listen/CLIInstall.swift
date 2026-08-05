import AppKit

/// Installing the `listen` command.
///
/// A symlink into the first writable directory on the list, never a copy: the
/// binary inside the bundle is the one that gets updated, and a copy would go
/// stale the first time Sparkle replaced the app, leaving a `listen` on the
/// PATH that is an older version of the app it claims to be.
///
/// Never installed silently on first launch. Writing to `/usr/local/bin`
/// without being asked is not something an app should do on its own.
enum CLIInstall {
    /// Where the command goes, in preference order.
    ///
    /// `/usr/local/bin` first because it is on the default PATH.
    /// `~/.local/bin` is the fallback when it is not writable, which on a Mac
    /// without Homebrew it usually is not, since creating `/usr/local/bin`
    /// needs an admin prompt this app deliberately does not raise.
    static let candidates: [URL] = [
        URL(fileURLWithPath: "/usr/local/bin"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/bin"),
    ]

    static var executable: URL { AppInfo.executable }

    enum State: Equatable {
        case notInstalled
        /// Installed and pointing at this bundle.
        case installed(String)
        /// Installed but pointing somewhere else, usually another copy of the app.
        case stale(String)

        var summary: String {
            switch self {
            case .notInstalled:    return "Not installed"
            case .installed(let p): return "Installed at \(Self.tilde(p))"
            case .stale(let p):     return "Points elsewhere: \(Self.tilde(p))"
            }
        }

        static func tilde(_ path: String) -> String {
            path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    static var state: State {
        for directory in candidates {
            let link = directory.appendingPathComponent("listen")
            guard FileManager.default.fileExists(atPath: link.path) else { continue }
            let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
                ?? link.path
            return target == executable.path ? .installed(link.path) : .stale(link.path)
        }
        return .notInstalled
    }

    /// The version the installed command would actually report, or nil when
    /// there is nothing installed.
    ///
    /// Read from the bundle the symlink resolves to, not from this one. Those
    /// are the same app in the ordinary case, and when they are not, that is
    /// exactly the thing worth showing: a `listen` on the PATH pointing at an
    /// older copy in another folder answers "why is the command behaving like a
    /// version I do not have installed?", which is otherwise unanswerable from
    /// inside the app.
    static var installedVersion: String? {
        for directory in candidates {
            let link = directory.appendingPathComponent("listen")
            guard FileManager.default.fileExists(atPath: link.path) else { continue }
            return AppInfo.versionString(forExecutable: link.resolvingSymlinksInPath())
        }
        return nil
    }

    /// Returns the path installed to, or throws with a reason a person can act on.
    @discardableResult
    static func install() throws -> String {
        var problems: [String] = []
        for directory in candidates {
            do {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
            } catch {
                problems.append("\(directory.path): cannot create")
                continue
            }
            guard FileManager.default.isWritableFile(atPath: directory.path) else {
                problems.append("\(directory.path): not writable")
                continue
            }

            let link = directory.appendingPathComponent("listen")
            // Replace whatever is there. An old symlink to a previous install
            // location is exactly the case this needs to fix, and refusing
            // would leave the stale one on the PATH.
            try? FileManager.default.removeItem(at: link)
            do {
                try FileManager.default.createSymbolicLink(
                    at: link, withDestinationURL: executable)
            } catch {
                problems.append("\(directory.path): \(error.localizedDescription)")
                continue
            }
            return link.path
        }
        throw NSError(domain: "Listen", code: 3, userInfo: [
            NSLocalizedDescriptionKey:
                "Could not install the command. " + problems.joined(separator: "; "),
        ])
    }

    static func uninstall() {
        for directory in candidates {
            let link = directory.appendingPathComponent("listen")
            if FileManager.default.fileExists(atPath: link.path) {
                try? FileManager.default.removeItem(at: link)
            }
        }
    }

    /// True when the directory the command landed in is actually on the PATH.
    ///
    /// `~/.local/bin` frequently is not, and an installed command that cannot
    /// be run is worse than one that was never installed, because nothing says
    /// why.
    static func isOnPath(_ path: String) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        // A GUI launch inherits no shell PATH, so fall back to the list a
        // login shell would have rather than reporting a false negative.
        let effective = paths.isEmpty
            ? ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            : paths.map(String.init)
        return effective.contains(directory)
    }
}

/// The MCP client configuration block, ready to paste.
enum MCPConfig {
    static var command: String {
        if case .installed(let path) = CLIInstall.state { return path }
        return CLIInstall.executable.path
    }

    static var json: String {
        """
        {
          "mcpServers": {
            "listen": {
              "command": "\(command)",
              "args": ["mcp"]
            }
          }
        }
        """
    }
}

/// The app's own version and paths, resolved so they survive being run through
/// a symlink.
///
/// `Bundle.main` is derived from the path the process was launched by, and the
/// installed `listen` command is a symlink in `~/.local/bin`. Launched that
/// way, `Bundle.main` points at the symlink's directory, finds no `Info.plist`,
/// and every version string becomes "unbundled build" while the MCP
/// configuration block loses the command path it is supposed to print.
///
/// So resolve the real executable first, then walk up to the bundle.
enum AppInfo {
    /// The real binary, with symlinks resolved.
    static var executable: URL {
        let launched = Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        return URL(fileURLWithPath: launched).resolvingSymlinksInPath()
    }

    /// `…/Listen.app/Contents/Info.plist`, if this binary lives in a bundle.
    private static var infoPlist: [String: Any]? {
        if let info = Bundle.main.infoDictionary, info["CFBundleShortVersionString"] != nil {
            return info
        }
        return plist(beside: executable)
    }

    /// The `Info.plist` two directories above an executable, which is where a
    /// `.app` keeps it.
    private static func plist(beside executable: URL) -> [String: Any]? {
        let contents = executable.deletingLastPathComponent()   // MacOS
                                .deletingLastPathComponent()    // Contents
        let path = contents.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: path),
              let info = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any] else { return nil }
        return info
    }

    /// "0.1.0 (build 16)" for whichever bundle contains this executable.
    ///
    /// Takes the executable as an argument rather than reading `Bundle.main`,
    /// so it can answer for a *different* copy of the app: the one an installed
    /// symlink points at is not always this one.
    static func versionString(forExecutable url: URL) -> String? {
        guard let info = plist(beside: url),
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        let build = info["CFBundleVersion"] as? String
        return version + (build.map { " (build \($0))" } ?? "")
    }

    static var version: String? { infoPlist?["CFBundleShortVersionString"] as? String }
    static var build: String? { infoPlist?["CFBundleVersion"] as? String }
}
