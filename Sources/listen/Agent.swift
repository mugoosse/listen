import Foundation

/// Asking questions about the library, through an agent CLI the user already
/// has.
///
/// Listen ships no language model for this and calls no API of its own. It
/// drives `claude` or `codex`, already installed and already signed in, as a
/// child process, and hands it Listen's own MCP server as the way to reach the
/// library. The agent is the user's, the subscription is the user's, and
/// nothing about the arrangement is a Listen account.
///
/// That is the whole reason this is possible at all. A meeting recorder that
/// wanted to summarise meetings used to need a model, a key and somebody's
/// server. Two of the three are already on the machine of anybody who would
/// want this feature, and the third was never wanted.
///
/// ## The agent cannot reach the library except through `listen mcp`
///
/// Claude is started with `--tools ""`, which removes every built-in tool
/// including Bash, Read and WebFetch, so the only callable thing left is the
/// MCP surface Listen serves out of its own process. Three consequences, and
/// all three are the point:
///
/// - No TCC prompt can appear, because the process reading
///   `~/Library/Application Support/Listen` is Listen, which already has the
///   right to. A child process rummaging through `~/Documents` would raise a
///   dialog attributed to Listen, and the user would be right to be alarmed.
/// - The writable surface stays exactly what `MCP.swift` argues for. Notes and
///   tags, nothing else, and only when the caller asked for writes.
/// - A question costs tool calls rather than a directory walk, so the retrieval
///   ladder in `.claude/skills/listen-library` is the whole cost model.
///
/// Codex cannot be locked down that far, and the difference was measured
/// rather than assumed. It keeps its shell: asked to, it ran
/// `head -1 /etc/hosts` and returned the real first line, so it can read
/// library files directly instead of asking for them. `--sandbox read-only`
/// does hold on the writing side, where a shell redirect into `/tmp` came back
/// "Operation not permitted" with exit 1 and no file appeared. Same data,
/// weaker guarantee, and it is why `claude` is preferred when both are
/// installed.
///
/// One thing to know before trusting any measurement of Codex taken this way:
/// it will cheerfully *predict* a command's output rather than run it. Two
/// earlier attempts at that write probe produced an entirely plausible
/// "Operation not permitted" with no `command_execution` event in the stream at
/// all. The event stream is the evidence, and the prose never is.
///
/// ## Nothing of the user's own agent configuration runs
///
/// Both CLIs are started with their user configuration suppressed:
/// `--setting-sources ""` and `--strict-mcp-config` for Claude,
/// `--ignore-user-config` for Codex. This is not tidiness. Measured on this
/// machine, without it: five `SessionStart` hooks fired inside what the user
/// thinks is a text field in a meeting recorder, every MCP server in their
/// global config was launched, and Codex's `notify` hook started a
/// computer-use client. An app that spawns an agent inherits the blast radius
/// of that agent's configuration unless it says otherwise, and a chat box is
/// not consent to run somebody's hooks.
///
/// Auth survives suppression in both, which is what makes it usable: Claude
/// still reads its keychain entry, Codex still reads `CODEX_HOME`.
enum AgentBackend: String, CaseIterable {
    case claude
    case codex

    var name: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        }
    }

    /// The binary's name on disk, which is also the `rawValue`.
    var command: String { rawValue }

    /// What to tell somebody who has not got it. Both lines end in the sign-in
    /// step on purpose: an installed CLI that was never signed into fails at
    /// the first question with a message about credentials, and that reads as
    /// Listen being broken.
    var installHint: String {
        switch self {
        case .claude:
            return "Install with `npm install -g @anthropic-ai/claude-code`, "
                 + "then run `claude` once and sign in."
        case .codex:
            return "Install with `brew install codex`, then run `codex login` once."
        }
    }

    /// Claude first when both are present, for the tool-isolation reason in the
    /// type comment above.
    static var preferenceOrder: [AgentBackend] { [.claude, .codex] }
}

// ---------------------------------------------------------------------------
// Finding the binary
// ---------------------------------------------------------------------------

/// Where the agent CLI is, which is not a question `which` can answer here.
///
/// A GUI launch inherits no shell environment at all, so `PATH` is either empty
/// or the four-entry default launchd hands out, and neither CLI installs into
/// any of it: Claude puts itself in `~/.local/bin`, Codex arrives through
/// Homebrew, and both are frequently somewhere else again because the user
/// installed them with npm, bun, mise, asdf or volta.
///
/// So three passes, cheapest first, and the expensive one is cached for the
/// life of the process.
enum AgentCLI {
    /// Directories worth looking in before paying for a shell.
    ///
    /// Covers the documented install path of both CLIs plus the package
    /// managers whose global bin directory is a fixed location. The ones with a
    /// version number in the path (nvm, asdf) cannot be listed and are what
    /// pass three exists for.
    private static let knownDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "~/.local/bin",
        "~/.claude/local",
        "~/.bun/bin",
        "~/.cargo/bin",
        "~/.deno/bin",
        "~/.volta/bin",
        "/opt/homebrew/opt/node/bin",
    ]

    /// Guards `shellResolved`, which is reached from the settings pane's
    /// background detection as well as from the CLI's main thread.
    private static let lock = NSLock()
    private static var shellResolved: [AgentBackend: URL?] = [:]

    /// The binary, or nil when it is not installed anywhere we can see.
    static func locate(_ backend: AgentBackend) -> URL? {
        if let chosen = Settings.agentPath(backend) {
            // An explicit setting wins even when it is wrong, so a broken path
            // shows up as a broken path rather than being silently replaced by
            // a working one somewhere else.
            return isExecutable(chosen) ? chosen : nil
        }
        if let onPath = searchPATH(backend.command) { return onPath }
        for directory in knownDirectories {
            let url = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                .appendingPathComponent(backend.command)
            if isExecutable(url) { return url }
        }
        lock.lock()
        let cached = shellResolved[backend]
        lock.unlock()
        if let cached { return cached }

        let found = askLoginShell(for: backend.command)
        lock.lock()
        shellResolved[backend] = found
        lock.unlock()
        return found
    }

    /// Forget the login-shell answer, for the settings pane's "Check again".
    ///
    /// Somebody who has just installed one of these in another terminal is the
    /// whole reason that button exists, and a cache held for the life of the
    /// process would make it a button that does nothing.
    static func forgetCachedPaths() {
        lock.lock()
        shellResolved.removeAll()
        lock.unlock()
    }

    private static func isExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.resolvingSymlinksInPath().path)
    }

    /// The `PATH` this process actually has, which is the user's own answer
    /// when Listen was started from a terminal and nearly nothing when it was
    /// started from Finder.
    private static func searchPATH(_ command: String) -> URL? {
        let entries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []
        for entry in entries {
            let url = URL(fileURLWithPath: entry).appendingPathComponent(command)
            if isExecutable(url) { return url }
        }
        return nil
    }

    /// Last resort: ask the user's login shell, which is the only thing that
    /// knows about a version-managed install.
    ///
    /// `-lic` and not `-lc`, because `PATH` for nvm and mise is usually set in
    /// `.zshrc`, which a non-interactive shell does not read. That means rc
    /// files run, so the output is not trustworthy: a prompt theme can print
    /// escape codes before anything of ours appears. Every line is therefore
    /// tested as a path and the first one that is an executable wins, rather
    /// than trusting the last line.
    ///
    /// Five seconds and then give up. A shell that hangs on startup is
    /// somebody's broken profile, and it must not become Listen hanging.
    private static func askLoginShell(for command: String) -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", "command -v \(command)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n") {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("/") else { continue }
            let url = URL(fileURLWithPath: candidate)
            if isExecutable(url) { return url }
        }
        return nil
    }
}

// ---------------------------------------------------------------------------
// What is installed, and whether it is signed in
// ---------------------------------------------------------------------------

/// A model the user can pick, as the CLI names it.
struct AgentModel: Equatable {
    /// What goes after `--model`.
    let id: String
    /// What the menu says.
    let name: String
}

/// One backend's answer to "could Listen use you right now?".
struct AgentStatus {
    let backend: AgentBackend
    let path: URL?
    let version: String?
    /// nil when it could not be determined, which is not the same as "no".
    let signedIn: Bool?
    /// The account, when the CLI says which one.
    let account: String?
    /// What this install offers, beyond whatever it would pick on its own.
    var models: [AgentModel] = []

    var usable: Bool { path != nil && signedIn != false }

    /// One line, for a settings row or a CLI report.
    var summary: String {
        guard let path else { return "Not installed" }
        var parts = [version ?? "installed"]
        parts.append(path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        switch signedIn {
        case true?:  parts.append(account.map { "signed in as \($0)" } ?? "signed in")
        case false?: parts.append("not signed in")
        case nil:    parts.append("sign-in unknown")
        }
        return parts.joined(separator: "   ")
    }
}

extension AgentCLI {
    /// What a short probe command said.
    ///
    /// Both streams, kept apart, plus the exit status. Keeping them apart
    /// matters in both directions: `claude auth status` prints JSON on stdout
    /// that a merged stream could corrupt, and `codex login status` prints
    /// **nothing at all** on stdout. Measured: `codex login status 2>/dev/null`
    /// is empty and exits 0 while `2>&1 1>/dev/null` prints "Logged in using
    /// ChatGPT", so a probe that reads only stdout reports a signed-in Codex as
    /// signed out, and the feature then hides itself behind a message that is
    /// not true.
    struct Probe {
        let out: String
        let err: String
        let status: Int32

        /// Whichever stream this command chose to speak on.
        var text: String {
            let stdout = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return stdout.isEmpty ? err.trimmingCharacters(in: .whitespacesAndNewlines) : stdout
        }
    }

    /// Runs a short command and reports what it said.
    ///
    /// Used only for `--version` and the sign-in check, both of which are
    /// sub-second. Anything that streams goes through `AgentRun`.
    static func capture(_ url: URL, _ arguments: [String], seconds: Double = 15) -> Probe? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = AgentRun.childEnvironment(for: url)
        process.currentDirectoryURL = AgentRun.workspace
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Both drained on background threads. A pipe whose buffer fills while
        // nobody reads it blocks the child for ever, and the wait below would
        // then never end.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave()
        }

        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }
        _ = group.wait(timeout: .now() + 2)
        return Probe(out: String(data: outData, encoding: .utf8) ?? "",
                     err: String(data: errData, encoding: .utf8) ?? "",
                     status: process.terminationStatus)
    }

    /// What one Claude alias currently means, as a name for a menu.
    ///
    /// Started as a session and killed the moment it says. The `init` event
    /// carries the resolved model id and is emitted **before** the first API
    /// request, so terminating there costs a process launch and no tokens at
    /// all. Measured: `opus` is `claude-opus-5`, `haiku` is
    /// `claude-haiku-4-5-20251001`.
    ///
    /// There is no `claude models` command, and asking for a model that does
    /// not exist prints prose rather than a list, so this is the only route to
    /// a name that stays true across a model release.
    private static func resolvedModelName(_ alias: String, at path: URL) -> String? {
        let process = Process()
        process.executableURL = path
        process.arguments = [
            "--print", ".", "--model", alias,
            "--output-format", "stream-json", "--verbose",
            // No servers and no tools, so nothing is started that would have to
            // be torn down when this is killed a second later.
            "--mcp-config", "{\"mcpServers\":{}}", "--strict-mcp-config",
            "--tools", "", "--setting-sources", "", "--disable-slash-commands",
        ]
        process.environment = AgentRun.childEnvironment(for: path)
        process.currentDirectoryURL = AgentRun.workspace
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        var buffer = Data()
        var found: String?
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning && Date() < deadline && found == nil {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer = buffer[buffer.index(after: newline)...]
                guard let json = try? JSONSerialization.jsonObject(with: line)
                        as? [String: Any],
                      json["subtype"] as? String == "init",
                      let model = json["model"] as? String else { continue }
                found = model
                break
            }
        }
        if process.isRunning { process.terminate() }
        return found.map(prettyModelName)
    }

    /// `claude-haiku-4-5-20251001` reads as "Haiku 4.5".
    ///
    /// The family, then the version parts joined with a dot. A trailing
    /// eight-digit date is a snapshot identifier and not part of any name a
    /// person uses.
    static func prettyModelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }

    static func status(_ backend: AgentBackend) -> AgentStatus {
        guard let path = locate(backend) else {
            return AgentStatus(backend: backend, path: nil, version: nil,
                               signedIn: nil, account: nil)
        }
        let version = capture(path, ["--version"])?.text
            .split(separator: "\n").first.map(String.init)

        var signedIn: Bool?
        var account: String?
        switch backend {
        case .claude:
            // JSON on stdout, so this reads a field rather than matching on
            // prose that is free to change between versions.
            if let probe = capture(path, ["auth", "status"]),
               let data = probe.out.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                signedIn = json["loggedIn"] as? Bool
                let email = json["email"] as? String
                let plan = json["subscriptionType"] as? String
                account = [email, plan.map { "(\($0))" }].compactMap { $0 }
                    .joined(separator: " ")
                if account?.isEmpty == true { account = nil }
            }
        case .codex:
            // No machine-readable mode, so this is the exit status with the
            // wording as a cross-check. Exit alone would be enough today, and
            // the prose is what makes the account readable in the report.
            if let probe = capture(path, ["login", "status"]) {
                let said = probe.text
                signedIn = probe.status == 0 && said.lowercased().hasPrefix("logged in")
                // "Logged in using ChatGPT" becomes "ChatGPT", so the row reads
                // as a row rather than as a sentence inside one.
                if signedIn == true {
                    account = said.replacingOccurrences(of: "Logged in using ", with: "")
                }
            }
        }
        return AgentStatus(backend: backend, path: path, version: version,
                           signedIn: signedIn, account: account,
                           models: models(backend, at: path))
    }

    /// What to offer in the model menu.
    ///
    /// The two backends are answered differently because they *are* different,
    /// not for want of trying to unify them.
    ///
    /// Claude has no command that lists models, and does not need one: it takes
    /// aliases, and an alias resolves to the latest of that family. A list of
    /// three aliases cannot go stale, while a list of exact version strings
    /// starts rotting the day it is written and would have to be shipped in an
    /// app update every time a model ships.
    ///
    /// Codex has `debug models`, which is the real catalog for the signed-in
    /// account, so there is no reason to guess. Its slugs are exact versions
    /// and would rot if hardcoded, which is the other half of the same
    /// argument.
    private static func models(_ backend: AgentBackend, at path: URL) -> [AgentModel] {
        switch backend {
        case .claude:
            // The aliases are what gets passed, and the *names* come from
            // asking what each currently resolves to, so the menu says
            // "Opus 5" rather than "Opus" and stops being right the day
            // Anthropic ships Opus 6 without anybody editing this file.
            //
            // Concurrently, because three sequential process launches is four
            // seconds of a background pass that already has work to do.
            let aliases = ["opus", "sonnet", "haiku"]
            var resolved = [String: String]()
            let lock = NSLock()
            let group = DispatchGroup()
            for alias in aliases {
                group.enter()
                DispatchQueue.global().async {
                    let name = resolvedModelName(alias, at: path)
                    lock.lock(); resolved[alias] = name; lock.unlock()
                    group.leave()
                }
            }
            _ = group.wait(timeout: .now() + 25)
            lock.lock(); defer { lock.unlock() }
            return aliases.map {
                AgentModel(id: $0, name: resolved[$0] ?? $0.capitalized)
            }
        case .codex:
            guard let probe = capture(path, ["debug", "models"], seconds: 20),
                  let data = probe.out.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["models"] as? [[String: Any]] else { return [] }
            // `visibility` is the catalog's own answer to "should a person see
            // this?", and there are a great many entries that say no.
            return list
                .filter { $0["visibility"] as? String == "list" }
                .sorted { ($0["priority"] as? Int ?? 99) < ($1["priority"] as? Int ?? 99) }
                .compactMap { entry in
                    guard let slug = entry["slug"] as? String else { return nil }
                    return AgentModel(id: slug,
                                      name: entry["display_name"] as? String ?? slug)
                }
        }
    }

    /// Every backend, whether installed or not, in preference order.
    static func statuses() -> [AgentStatus] {
        AgentBackend.preferenceOrder.map(status)
    }

    /// The same, off the main thread, and remembered.
    ///
    /// Detection spawns up to four short processes and, the first time, a login
    /// shell that is allowed five seconds. **Nothing on the main thread may
    /// call the synchronous version.** It was called from the Ask pane's status
    /// line, which runs on every recording selection and again on every
    /// question, and the window froze for the whole of it: clicking down a list
    /// of meetings paid for four process launches per click.
    ///
    /// So the answer is cached, and every caller on the main thread reads the
    /// cache. It goes stale when somebody installs or signs into a CLI while
    /// the app is open, which is what the Agent pane's "Check again" is for and
    /// is not worth polling over.
    static func statuses(_ completion: @escaping ([AgentStatus]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let all = statuses()
            lock.lock()
            cache = all
            lock.unlock()
            DispatchQueue.main.async { completion(all) }
        }
    }

    private static var cache: [AgentStatus]?

    /// What detection last found, without running it. nil means it has not run.
    static var cached: [AgentStatus]? {
        lock.lock()
        defer { lock.unlock() }
        return cache
    }

    /// The backend Listen would use, from the cache only.
    ///
    /// Returns nil both when nothing is usable and when nothing has looked yet,
    /// which the caller has to tell apart with `cached`: "no agent installed"
    /// and "still looking" are different sentences to put on a screen.
    static func cachedChosen() -> AgentStatus? {
        guard let all = cached else { return nil }
        if let preferred = Settings.agentBackend,
           let match = all.first(where: { $0.backend == preferred }), match.usable {
            return match
        }
        return all.first(where: { $0.usable })
    }

    /// Run detection once, in the background, unless it has already run.
    static func warmUp(_ completion: @escaping () -> Void = {}) {
        if cached != nil { completion(); return }
        statuses { _ in completion() }
    }

    /// The one Listen would use: the setting when it names an installed and
    /// signed-in backend, otherwise the first that is usable.
    static func chosen() -> AgentStatus? {
        let all = statuses()
        if let preferred = Settings.agentBackend,
           let match = all.first(where: { $0.backend == preferred }), match.usable {
            return match
        }
        return all.first(where: { $0.usable })
    }
}

// ---------------------------------------------------------------------------
// Running one question
// ---------------------------------------------------------------------------

/// One question put to one agent, streamed back as it answers.
///
/// Both CLIs emit line-delimited JSON, and both are translated into the same
/// small event type, because the window should not know which one is running
/// and neither should the CLI that tests it.
final class AgentRun {
    enum Event {
        /// The session identifier, which is what a follow-up question resumes.
        case started(session: String)
        case thinking
        /// A whole block of answer, which is how it arrives without streaming.
        case text(String)
        /// A few characters of answer. Only with `Question.streaming`, and then
        /// `.text` never fires, so a reader handles one or the other and never
        /// has to work out whether it is seeing the same words twice.
        case textDelta(String)
        case toolCall(name: String, detail: String)
        case toolResult(name: String, ok: Bool)
        /// Something worth saying that is not part of the answer.
        case note(String)
        case finished(Outcome)
    }

    struct Outcome {
        var session: String?
        /// What the same turn would have cost on metered API pricing.
        ///
        /// Parsed because the stream carries it, and **never put on screen**.
        /// Everyone reaching this feature is signed into a Claude or ChatGPT
        /// subscription, which is a fixed monthly price: a "$0.15" under an
        /// answer is not money anybody is spending, and reads as a meter
        /// running on a flat-rate plan. It would make people ask fewer
        /// questions for no reason at all.
        var costUSD: Double?
        var durationMS: Int?
        var toolCalls: Int
        /// nil on success. Present means the answer is not to be trusted.
        var failure: String?
    }

    struct Question {
        var text: String
        var backend: AgentBackend
        var path: URL
        /// A session to continue, so a chat is a chat rather than a series of
        /// unrelated questions.
        var resume: String?
        /// Notes and tags become writable. Off by default: a question should
        /// not be able to change the library by accident.
        var allowWrites = false
        var model: String?
        /// Deliver the answer as it is written rather than in finished blocks.
        ///
        /// On for the window and off for the CLI, which is not only taste. The
        /// window is a place where five seconds of nothing reads as a hang, and
        /// a terminal is a place where a paragraph arriving in one piece is
        /// easier to read and to pipe. Claude only: Codex has no equivalent, so
        /// setting it there does nothing rather than failing.
        var streaming = false
    }

    // MARK: Where it runs

    /// The working directory handed to the agent.
    ///
    /// Not the library, and not the user's home. The current directory is where
    /// both CLIs go looking for project instructions (`CLAUDE.md`,
    /// `AGENTS.md`), where Codex decides whether it is in a git repository, and
    /// what Claude reports as the workspace it was trusted for. Pointing it at
    /// an empty directory Listen owns means the answer does not depend on where
    /// the app happened to be launched from.
    static let workspace: URL = {
        let url = Library.root.appendingPathComponent("agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The environment the child gets.
    ///
    /// Inherited, then repaired. Two repairs, both measured rather than
    /// guessed:
    ///
    /// - `PATH` gets the agent's own directory prepended. A GUI launch has
    ///   `/usr/bin:/bin:/usr/sbin:/sbin` and Codex shells out to run its own
    ///   helpers, which then are not found.
    /// - `CLAUDECODE` and friends are removed. When Listen is itself launched
    ///   from inside a Claude Code session, the child sees those and believes
    ///   it is a nested agent, which changes its output format. Developer-only
    ///   in practice, and exactly the case where a confusing failure costs the
    ///   most time.
    static func childEnvironment(for binary: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT",
                    "CLAUDE_CODE_SIMPLE", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED"] {
            environment.removeValue(forKey: key)
        }
        let own = binary.deletingLastPathComponent().path
        let base = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !base.split(separator: ":").contains(Substring(own)) {
            environment["PATH"] = own + ":" + base
        }
        return environment
    }

    // MARK: What it is allowed to do

    /// The MCP tools a question may call.
    ///
    /// `delete_note` is on neither list. The server offers it because the CLI
    /// and a human at an MCP client should be able to undo a note, but an agent
    /// answering a question in a chat box has no business removing one, and the
    /// asymmetry is deliberate: everything else here is reversible by hand in
    /// the window, and a deleted note is not.
    static func tools(allowWrites: Bool) -> [String] {
        let read = ["list_recordings", "get_recording", "get_transcript",
                    "search_transcripts", "list_people", "list_tags",
                    "list_notes", "read_note"]
        let write = ["write_note", "edit_note", "add_tags", "remove_tags"]
        return (read + (allowWrites ? write : [])).map { "mcp__listen__\($0)" }
    }

    /// The MCP server block, pointing at this very binary.
    ///
    /// `AppInfo.executable` and not the installed symlink, so the agent talks
    /// to the copy of Listen that asked the question. The two differ whenever
    /// somebody is running a build out of a working directory, and an answer
    /// that came from a different library than the window is showing is the
    /// worst possible kind of wrong.
    static var mcpConfigJSON: String {
        let object: [String: Any] = ["mcpServers": [
            "listen": ["command": AppInfo.executable.path, "args": ["mcp"]],
        ]]
        // Slashes unescaped, which JSON does not require either way. It only
        // matters because this string is what `--print-command` shows somebody
        // trying to reproduce a failure by hand.
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// What the agent is told it is doing.
    ///
    /// The retrieval ladder is the important half. Without it the first move is
    /// reliably `get_transcript` on everything recent, which is the one way to
    /// fail at this: transcripts average about 5,500 tokens and everything else
    /// in the surface exists so it can decide which ones it needs. The wording
    /// is the short form of `.claude/skills/listen-library`, which has the
    /// measurements behind it.
    static func brief(allowWrites: Bool) -> String {
        let name = Settings.userName ?? SpeakerName.you
        let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var text = """
        You are answering questions about \(name)'s own meeting recordings, held \
        in Listen, a local meeting recorder on this Mac. Today is \(today).

        The `listen` MCP tools are the only thing you can see. There is no \
        filesystem to search and no web to check. If the tools cannot answer \
        something, say so rather than filling the gap.

        Narrow before you read. Transcripts are the only expensive thing here \
        and every other tool exists so you can decide which ones you need:

        - `list_recordings` first. It takes `query`, `person`, `after` and \
        `before`, combined with AND, and returns titles and ids. `person` here \
        means was in the room.
        - `search_transcripts` when you already know the phrase. `person` there \
        means said it, which is the other question.
        - `list_notes` and `read_note` before any transcript. A note is somebody \
        having already read the meeting.
        - `get_transcript` last, and only for the recordings you have narrowed to.

        Speakers are named where somebody has named them and single letters \
        where nobody has. `Me` is \(name).

        Answer in a few sentences unless asked for more. Name the recording and \
        the date behind any claim, and quote people rather than paraphrasing \
        where the exact words matter.
        """
        if allowWrites {
            text += """


            You may also write notes and tags. Write a note only when asked to, \
            put the recording it is about in `recording_id`, and never delete or \
            overwrite somebody else's wording without being told to.
            """
        }
        return text
    }

    // MARK: Building the command

    static func arguments(for question: Question) -> [String] {
        switch question.backend {
        case .claude:
            var args = [
                "--print", question.text,
                "--output-format", "stream-json",
                // stream-json refuses to run without it, which is not obvious
                // from the flag's name.
                "--verbose",
                "--mcp-config", mcpConfigJSON,
                // Only ours. Without it every MCP server in the user's global
                // config is launched by a meeting recorder.
                "--strict-mcp-config",
                // No Bash, no Read, no WebFetch. The MCP surface is the whole
                // world, which is what makes the TCC story true.
                "--tools", "",
                "--allowedTools", tools(allowWrites: question.allowWrites)
                    .joined(separator: ","),
                // No settings.json from any scope, so no hooks and no plugins.
                // Measured: five SessionStart hooks fired without this.
                "--setting-sources", "",
                "--disable-slash-commands",
                "--append-system-prompt", brief(allowWrites: question.allowWrites),
            ]
            if question.streaming { args.append("--include-partial-messages") }
            if let model = question.model { args += ["--model", model] }
            if let resume = question.resume { args += ["--resume", resume] }
            return args

        case .codex:
            // `exec resume <id>` and `exec <prompt>` are different shapes, so
            // the prompt lands in a different position depending on which.
            var args = ["exec"]
            if let resume = question.resume { args += ["resume", resume] }
            args += [
                "--json",
                // The workspace is deliberately not a repository.
                "--skip-git-repo-check",
                // Reads anything, writes nothing, no network.
                "--sandbox", "read-only",
                // The Codex equivalent of --setting-sources "". Auth still
                // comes from CODEX_HOME, which is what makes it usable.
                "--ignore-user-config",
                "-c", "approval_policy=\"never\"",
                "-c", "mcp_servers.listen.command=\"\(AppInfo.executable.path)\"",
                "-c", "mcp_servers.listen.args=[\"mcp\"]",
                // Not the same gate as approval_policy, and this is the one
                // that matters. With approval_policy alone every MCP call came
                // back "user cancelled MCP tool call" and the model answered
                // "Unable to access the library".
                "-c", "mcp_servers.listen.default_tools_approval_mode=\"approve\"",
                "-C", workspace.path,
            ]
            if let model = question.model { args += ["--model", model] }
            // Codex has no --append-system-prompt, so the brief rides in front
            // of the question. On a resumed thread it is already in the
            // history, so it is sent once.
            args.append(question.resume == nil
                        ? brief(allowWrites: question.allowWrites) + "\n\n---\n\n" + question.text
                        : question.text)
            return args
        }
    }

    // MARK: Running

    private let question: Question
    private let process = Process()
    private let onEvent: (Event) -> Void
    private let queue: DispatchQueue
    private var buffer = Data()
    private var stderrText = ""
    /// Codex item ids already counted.
    ///
    /// Codex emits `item.started` and `item.completed` for the same `item.id`,
    /// so a count that fired on both would double every tool call, and one that
    /// fires only on `started` loses any item that arrives as a completion
    /// alone. Counting the first sighting of an id is right either way.
    private var countedItems = Set<String>()

    /// When the process started, so a backend that reports no duration still
    /// gets one. Claude's result event carries `duration_ms`; Codex's
    /// `turn.completed` carries only token counts, and an answer with no time
    /// under it beside one that has a time reads as a bug in the pane rather
    /// than a difference between two CLIs.
    private var startedAt = Date()
    private var outcome = Outcome(session: nil, costUSD: nil, durationMS: nil,
                                  toolCalls: 0, failure: nil)
    private var finished = false

    /// Parsing happens here and nowhere else.
    ///
    /// `consume` is reached from two directions: the pipe's readability handler
    /// on its own thread, and the termination handler draining what is left.
    /// Those can overlap, and `buffer` is a `Data` being appended to and sliced,
    /// so without this they race over it.
    private let parsing = DispatchQueue(label: "listen.agent.parse")

    /// Held by itself while the process runs.
    ///
    /// Every callback into this object is `[weak self]`, so the only strong
    /// reference is the caller's. A caller that starts a run and then stops
    /// mentioning the object, which is exactly what the CLI does before
    /// blocking on its semaphore, lets the optimiser release it early: the
    /// handlers then fire on nothing, no completion is ever delivered, and the
    /// wait never ends. Cleared in `complete`, which is the one path out.
    private var whileRunning: AgentRun?

    /// Events are delivered on `queue`, which is `.main` for the window.
    init(_ question: Question, on queue: DispatchQueue = .main,
         onEvent: @escaping (Event) -> Void) {
        self.question = question
        self.queue = queue
        self.onEvent = onEvent
    }

    func start() throws {
        process.executableURL = question.path
        process.arguments = Self.arguments(for: question)
        process.currentDirectoryURL = Self.workspace
        process.environment = Self.childEnvironment(for: question.path)

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // Closed, not inherited. Codex reads stdin when it is a pipe and prints
        // "Reading additional input from stdin..." while it waits, so an
        // inherited stdin is a hang with an explanation nobody sees.
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.stderrText += text
        }
        process.terminationHandler = { [weak self] process in
            // Drain whatever the handler has not seen yet. A short answer can
            // arrive and the process exit before readability fires again.
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            self?.consume(out.fileHandleForReading.readDataToEndOfFile())
            if let rest = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) {
                self?.stderrText += rest
            }
            self?.complete(status: process.terminationStatus)
        }

        whileRunning = self
        startedAt = Date()
        do {
            try process.run()
        } catch {
            whileRunning = nil
            throw error
        }
    }

    func cancel() {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func emit(_ event: Event) {
        queue.async { [onEvent] in onEvent(event) }
    }

    private func consume(_ data: Data) {
        parsing.sync {
            buffer.append(data)
            // Line-delimited, and a read can end mid-line, so the tail is kept.
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                guard !line.isEmpty,
                      let json = try? JSONSerialization.jsonObject(with: Data(line))
                        as? [String: Any] else { continue }
                switch question.backend {
                case .claude: readClaude(json)
                case .codex:  readCodex(json)
                }
            }
        }
    }

    private func complete(status: Int32) {
        // On the parsing queue, so the outcome cannot be read while the last
        // few lines are still being folded into it.
        parsing.sync {
            guard !finished else { return }
            finished = true
            // Wall clock, which includes process startup and so is slightly
            // longer than the API time Claude reports. That is the honest
            // number anyway: it is how long the person waited.
            if outcome.durationMS == nil {
                outcome.durationMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            }
            if outcome.failure == nil && status != 0 {
                // stderr is usually empty on a clean refusal, so the exit code
                // is the only thing left to report.
                let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                outcome.failure = detail.isEmpty
                    ? "\(question.backend.command) exited \(status)."
                    : detail
            }
            emit(.finished(outcome))
            whileRunning = nil
        }
    }

    // MARK: Reading each dialect

    private func readClaude(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "system":
            if json["subtype"] as? String == "init",
               let session = json["session_id"] as? String {
                outcome.session = session
                emit(.started(session: session))
            }
        case "stream_event":
            // Only present with --include-partial-messages, and the finished
            // `assistant` message still follows it carrying the same words. The
            // text half of that message is therefore skipped below, or every
            // answer would appear twice.
            guard let event = json["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return }
            emit(.textDelta(text))

        case "assistant":
            guard let message = json["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    guard !question.streaming else { break }
                    if let text = block["text"] as? String, !text.isEmpty { emit(.text(text)) }
                case "thinking":
                    emit(.thinking)
                case "tool_use":
                    let name = Self.shortToolName(block["name"] as? String ?? "tool")
                    outcome.toolCalls += 1
                    emit(.toolCall(name: name,
                                   detail: Self.detail(block["input"] as? [String: Any])))
                default: break
                }
            }
        case "user":
            guard let message = json["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return }
            for block in blocks where block["type"] as? String == "tool_result" {
                let ok = !((block["is_error"] as? Bool) ?? false)
                emit(.toolResult(name: "", ok: ok))
            }
        case "result":
            outcome.costUSD = json["total_cost_usd"] as? Double
            outcome.durationMS = json["duration_ms"] as? Int
            if (json["is_error"] as? Bool) == true {
                outcome.failure = json["result"] as? String
                    ?? json["subtype"] as? String ?? "the agent reported an error."
            }
        default:
            break
        }
    }

    private func readCodex(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "thread.started":
            if let id = json["thread_id"] as? String {
                outcome.session = id
                emit(.started(session: id))
            }
        case "item.started", "item.completed":
            guard let item = json["item"] as? [String: Any] else { return }
            let completed = json["type"] as? String == "item.completed"
            let id = item["id"] as? String ?? UUID().uuidString
            /// True the first time this item is seen, whichever event that was.
            func first() -> Bool { countedItems.insert(id).inserted }

            switch item["type"] as? String {
            case "agent_message":
                if completed, let text = item["text"] as? String, !text.isEmpty {
                    emit(.text(text))
                }
            case "reasoning":
                if !completed { emit(.thinking) }
            case "mcp_tool_call":
                let name = item["tool"] as? String ?? "tool"
                if first() {
                    outcome.toolCalls += 1
                    emit(.toolCall(name: name,
                                   detail: Self.detail(item["arguments"] as? [String: Any])))
                }
                if completed {
                    let failed = item["status"] as? String != "completed"
                    if failed,
                       let error = (item["error"] as? [String: Any])?["message"] as? String {
                        emit(.note("\(name): \(error)"))
                    }
                    emit(.toolResult(name: name, ok: !failed))
                }
            case "command_execution":
                // Codex keeps its shell under `--sandbox read-only`, so this
                // happens. Surfaced rather than hidden: it is the one visible
                // difference between the two backends, and somebody who chose
                // Codex should be able to see it running commands.
                if first() {
                    outcome.toolCalls += 1
                    emit(.toolCall(name: "shell", detail: (item["command"] as? String) ?? ""))
                }
                if completed {
                    emit(.toolResult(name: "shell",
                                     ok: item["status"] as? String == "completed"))
                }
            default:
                break
            }
        case "turn.failed", "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? json["message"] as? String
            outcome.failure = message ?? "the agent reported an error."
        default:
            break
        }
    }

    /// `mcp__listen__search_transcripts` reads as `search_transcripts`.
    private static func shortToolName(_ raw: String) -> String {
        raw.hasPrefix("mcp__listen__") ? String(raw.dropFirst("mcp__listen__".count)) : raw
    }

    /// The one argument worth showing beside a tool call.
    ///
    /// A whole argument object is noise in a chat transcript and a bare tool
    /// name says nothing. The interesting field is nearly always the thing
    /// being looked for, so the first one present wins.
    private static func detail(_ input: [String: Any]?) -> String {
        guard let input else { return "" }
        for key in ["query", "recording_id", "note", "person", "name", "tags"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
            if let values = input[key] as? [String], !values.isEmpty {
                return values.joined(separator: ", ")
            }
        }
        return ""
    }
}

// ---------------------------------------------------------------------------
// What was asked, and what came back
// ---------------------------------------------------------------------------

/// One recording's conversation, kept beside it as `chat.json`.
///
/// A sidecar in the recording's own folder, which is the arrangement
/// `turns.json` and `embeddings.json` already have and for the same reason:
/// the folder is the recording, so deleting one in Finder cannot strand
/// anything, and a conversation about a meeting that no longer exists cannot
/// outlive it.
///
/// **Not a note.** A note is somebody's finished reading of a meeting and
/// belongs to the library; this is the working-out, and belongs to the
/// recording. The button that turns one into the other is the whole point of
/// keeping them apart: everything here is disposable until somebody says
/// otherwise.
struct Chat: Codable {
    /// One block of an answer, in the order it happened.
    ///
    /// An answer is not one lump of text: it is usually a sentence about what
    /// it is going to do, then some work, then the answer. Storing that order
    /// is what lets a reopened conversation look like the one that was watched
    /// rather than a paragraph with a list of tools stapled above it.
    struct Step: Codable {
        static let text = "text", activity = "activity"
        /// `text` or `activity`. A string rather than an enum so a file written
        /// by a version that knows a third kind still decodes here.
        var kind: String
        var text: String
    }

    /// One thing said, by either side.
    ///
    /// Every field past the first three is optional, which is the rule
    /// `notes-tags-dictionary.md` records for this codebase: a non-optional
    /// added later needs `init(from:)` written by hand, and this file will grow
    /// fields.
    struct Turn: Codable {
        /// `you` or `agent`. A string rather than an enum so a file written by
        /// a version that knows a third speaker still decodes here.
        var who: String
        var text: String
        /// The tool lines under an agent's answer, one per call. Superseded by
        /// `steps`, and still written so a file stays readable by the version
        /// that shipped first.
        var tools: [String]?
        /// The answer's blocks in order. Absent on a turn written before this
        /// existed, and `AnswerTurn.restore` falls back to `tools` plus `text`.
        var steps: [Step]?
        var at: String
        /// The question this answer came from, so `Save as note` can title it
        /// even when it is not the most recent thing asked. Absent on a `you`
        /// turn, and on an `agent` turn written before this field existed.
        var question: String?
        var durationMS: Int?
        /// Set when the run failed, and then `text` is whatever got through
        /// before it did.
        var failure: String?
    }

    /// The agent session these turns belong to, which is what a follow-up
    /// resumes. Dropped when the backend changes, because a Codex thread id
    /// means nothing to Claude.
    var session: String?
    var backend: String?
    var turns: [Turn] = []

    static let you = "you", agent = "agent"
}

extension Chat {
    private static func url(for recording: Recording) -> URL {
        recording.folder.appendingPathComponent("chat.json")
    }

    /// The conversation about one recording, or an empty one.
    ///
    /// A file that will not decode is treated as absent rather than as an
    /// error. The alternative is a detail pane that refuses to open because a
    /// disposable sidecar is malformed, and nothing here is worth that.
    static func load(for recording: Recording) -> Chat {
        guard let data = try? Data(contentsOf: url(for: recording)),
              let chat = try? JSONDecoder().decode(Chat.self, from: data) else {
            return Chat()
        }
        return chat
    }

    func save(for recording: Recording) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Chat.url(for: recording), options: .atomic)
    }

    static func forget(for recording: Recording) {
        try? FileManager.default.removeItem(at: url(for: recording))
    }
}

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

extension Settings {
    private static let agentBackendKey = "agentBackend"
    private static func agentPathKey(_ backend: AgentBackend) -> String {
        "agentPath_" + backend.rawValue
    }

    /// Which CLI to use, or nil to take whichever is installed and signed in.
    ///
    /// Absent by default rather than defaulting to Claude, so somebody who
    /// installs Codex later gets a working feature without having to find a
    /// setting they were never shown.
    static var agentBackend: AgentBackend? {
        get { AgentBackend(rawValue: defaults.string(forKey: agentBackendKey) ?? "") }
        set {
            if let newValue { defaults.set(newValue.rawValue, forKey: agentBackendKey) }
            else { defaults.removeObject(forKey: agentBackendKey) }
        }
    }

    private static func agentModelKey(_ backend: AgentBackend) -> String {
        "agentModel_" + backend.rawValue
    }

    /// The model to ask for, or nil to let the CLI choose.
    ///
    /// Per backend, so switching between them in the composer's menu and back
    /// remembers what each was set to rather than carrying a Codex slug over to
    /// Claude, which would be rejected.
    static func agentModel(_ backend: AgentBackend) -> String? {
        let stored = defaults.string(forKey: agentModelKey(backend))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static func setAgentModel(_ backend: AgentBackend, _ model: String?) {
        if let model, !model.isEmpty {
            defaults.set(model, forKey: agentModelKey(backend))
        } else {
            defaults.removeObject(forKey: agentModelKey(backend))
        }
    }

    /// An explicit path, for an install in a place nothing can guess.
    static func agentPath(_ backend: AgentBackend) -> URL? {
        guard let path = defaults.string(forKey: agentPathKey(backend))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func setAgentPath(_ backend: AgentBackend, _ path: String?) {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: agentPathKey(backend))
        } else {
            defaults.removeObject(forKey: agentPathKey(backend))
        }
    }
}
