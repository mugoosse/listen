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
    /// An OpenAI-compatible base URL, which is the one backend that is not a
    /// CLI and the one where Listen runs the tool loop itself. See
    /// `AgentChat.swift`, which owns everything about it except this case.
    ///
    /// **It names a kind, not a server.** Which server is `Provider.id`, on
    /// `AgentStatus.provider`. This case briefly had a sibling called
    /// `openrouter`, which was the moment it became clear the enum was being
    /// asked to enumerate the world: providers are a table now and this stays
    /// a three-case enum whose raw value is safe to write to disk.
    case endpoint

    var name: String {
        switch self {
        case .claude:     return "Claude Code"
        case .codex:      return "Codex"
        // Whatever the endpoint is called, which is a preset's name, a typed
        // name, or the host. "Endpoint" is a word about plumbing and nobody
        // picks a model from a menu row that says it.
        // Only ever seen on a status that has no provider, which is a
        // programming error rather than a state. The real name is
        // `AgentStatus.name`.
        case .endpoint:   return "Endpoint"
        }
    }

    /// Whether this backend is a program on disk, which is what `AgentCLI`'s
    /// three-pass search and everything about child processes applies to.
    var isCLI: Bool { self == .claude || self == .codex }

    /// The two that run the tool loop in this process, over HTTP.
    var isEndpoint: Bool { !isCLI }

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
        case .endpoint:
            return "Add a provider in Settings › Ask. For a model on this Mac, "
                 + "install Ollama from ollama.com and run `ollama pull qwen3`."
        }
    }

    /// The single command that installs it, and the single command that signs
    /// it in.
    ///
    /// Separate from `installHint` because two places offer them as something
    /// to *run* rather than to read: the Agent pane's copy button and the Ask
    /// pane's setup notice. A command that differs between the two is a command
    /// one of them is wrong about.
    var installCommand: String {
        switch self {
        case .claude: return "npm install -g @anthropic-ai/claude-code"
        case .codex:  return "brew install codex"
        }
    }

    var signInCommand: String {
        switch self {
        case .claude: return "claude auth login"
        case .codex:  return "codex login"
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
    ///
    /// For the endpoint backend there is nothing to find: the base URL is the
    /// location, and nil means nobody has typed one. Returning it here is what
    /// lets `AgentStatus.path == nil` keep its one meaning across all three,
    /// which is "there is nothing to talk to yet".
    static func locate(_ backend: AgentBackend) -> URL? {
        // A provider is not located, it is configured. `statuses()` walks
        // `Settings.providers` directly and never comes through here.
        guard backend.isCLI else { return nil }
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

/// A model the user can pick, as the backend names it.
struct AgentModel: Equatable {
    /// What goes after `--model`, and what is stored.
    let id: String
    /// What the menu says.
    ///
    /// A provider's catalogue carries a human name beside the slug, and using
    /// it is most of the difference between a readable menu and a list of
    /// vendor paths: "Claude Opus 5" against `anthropic/claude-opus-5`.
    let name: String
    /// When the provider published it, for sorting.
    ///
    /// **Newest first, never alphabetical.** Sorted by name, the top of
    /// OpenRouter's 318 tool-capable models is `ai21/jamba`, four `aion-labs`
    /// entries and five `amazon/nova` ones: twelve rows nobody chose, which is
    /// what the composer's menu showed until this existed.
    var created: Int?
    /// Dollars per million prompt tokens, when the provider prices it.
    var pricePerMTok: Double?
    /// The context window, which is the other number worth knowing before
    /// pointing a model at an hour-long transcript.
    var context: Int?

    /// One line under the name in the picker: what it costs and what it holds.
    var detail: String {
        var parts: [String] = [id]
        if let pricePerMTok {
            parts.append(pricePerMTok == 0
                         ? "free"
                         : String(format: "$%.2f/Mtok", pricePerMTok))
        }
        if let context, context > 0 {
            parts.append("\(context / 1000)k context")
        }
        return parts.joined(separator: "   ")
    }
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
    /// It answered, and it refused the credentials it was given.
    ///
    /// Only an endpoint reaches this, and it exists because "nothing is there"
    /// and "it is there and said no" are one URL apart and two entirely
    /// different things to do about it. Reading that back off the `account`
    /// prose would be this app parsing its own sentences.
    var refused = false
    /// Which server this is, for a `.endpoint` status. Nil for the two CLIs.
    var provider: Provider?

    /// What identifies this backend everywhere a choice is stored or compared:
    /// the settings picker, the composer's model menu, `Chat.backend`, and the
    /// per-backend model preference.
    ///
    /// A provider's id for a provider, the enum's raw value for a CLI. One
    /// string either way, which is what let `Chat.backend` keep its type when
    /// one endpoint became many.
    var key: String { provider?.id ?? backend.rawValue }

    /// What to call it on screen.
    var name: String { provider?.name ?? backend.name }

    /// Whether a question to this backend has to leave the Mac.
    ///
    /// The reason this is on the status rather than on the backend: a model
    /// running under Ollama answers with the Wi-Fi off, so telling somebody on
    /// that provider that their question "will not get through" is untrue, and
    /// untrue in the direction that stops them asking. The LAN case counts as
    /// needing the network, because the interface going down takes the other
    /// machine with it.
    var needsNetwork: Bool {
        guard let provider else { return backend.needsNetwork }
        return !provider.isLoopback
    }

    var usable: Bool { path != nil && signedIn != false }

    /// One line, for a settings row or a CLI report.
    ///
    /// The two halves read differently per backend and neither wording works
    /// for the other. A CLI is installed or not and signed in or not; an
    /// endpoint is configured or not and answering or not. "Codex is not
    /// configured" and "Ollama is not installed" are both sentences that send
    /// somebody to do the wrong thing.
    var summary: String {
        guard let path else {
            return backend.isCLI ? "Not installed" : "Not configured"
        }
        var parts = [version ?? (backend.isCLI ? "installed" : "configured")]
        parts.append(backend.isCLI
                     ? path.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                     : path.absoluteString)
        switch (signedIn, backend.isCLI) {
        case (true?, true):   parts.append(account.map { "signed in as \($0)" } ?? "signed in")
        case (false?, true):  parts.append("not signed in")
        case (nil, true):     parts.append("sign-in unknown")
        case (true?, false):  parts.append(account ?? "answering")
        case (false?, false): parts.append(refused ? "refused the key" : "not answering")
        case (nil, false):    parts.append("not checked")
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

    /// One CLI's answer to "could Listen use you right now?".
    ///
    /// Providers do not come through here. They are probed by
    /// `Provider.probe()` over HTTP, from `statuses()` below.
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
        case .endpoint:
            // Unreachable: answered by `probe` at the top of this function,
            // which learns all three facts from one request. Listed rather than
            // defaulted so a fourth backend is a compile error here.
            break
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
        case .endpoint:
            // Unreachable: `status` answers the endpoint from `probe`, which
            // reads `/models` in the same request that establishes it is there
            // at all. Listed rather than defaulted, so adding a fourth backend
            // is a compile error here rather than an empty menu.
            return []
        }
    }

    /// The two CLIs, then every provider the user has added.
    ///
    /// The providers are probed **concurrently**, which is not a micro
    /// optimisation once there can be a dozen of them: each is an HTTP round
    /// trip with a three second timeout, and one unreachable hosted provider
    /// would otherwise add its whole timeout to the pane's first draw. The CLIs
    /// stay sequential because they are process launches sharing a lock.
    static func statuses() -> [AgentStatus] {
        // **Says so when the rule is broken, because it has been broken twice.**
        // The rule is on `chosen()` and in `.agents/notes/agent.md`, and both
        // times it was reintroduced by code that looked harmless: a settings
        // row asking which backend is in use. Unconditional rather than behind
        // `LISTEN_DEBUG`, because this can only print when there is a bug, and
        // the message is the whole diagnosis.
        if Thread.isMainThread {
            let warning = "[Listen] BUG: agent detection ran on the main thread. "
                + "Use cachedChosen() or choose(from:).\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
        var out = [status(.claude), status(.codex)]

        let providers = Settings.providers
        guard !providers.isEmpty else { return out }
        var probed = [String: AgentStatus]()
        let group = DispatchGroup()
        let guard_ = NSLock()
        for provider in providers {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let status = provider.probe()
                guard_.lock(); probed[provider.id] = status; guard_.unlock()
                group.leave()
            }
        }
        // Generous next to the three second per-request timeout, and it is a
        // backstop rather than a schedule: a hung DNS resolver must not leave
        // the settings pane saying "Looking" for ever.
        _ = group.wait(timeout: .now() + 20)
        guard_.lock(); defer { guard_.unlock() }
        // The staleness clock is reset here too. Without it the first check
        // after a full detection finds every provider infinitely old and probes
        // the lot again, seconds later.
        lock.lock()
        for id in probed.keys { probedAt[id] = Date() }
        lock.unlock()
        // In the order they were added, not the order they answered, so the
        // list does not reshuffle itself between draws.
        out += providers.compactMap { probed[$0.id] }
        return out
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
        return choose(from: all)
    }

    /// The selection rule, over a list somebody already has.
    ///
    /// **Pure, and that is the point.** Every other spelling of this question
    /// runs detection: `chosen()` probes both CLIs and every provider, which is
    /// about three seconds of process launches and HTTP. A caller that already
    /// holds a list of statuses, which the settings pane does the moment
    /// detection finishes, must be able to ask which one wins without paying
    /// for that again.
    static func choose(from all: [AgentStatus]) -> AgentStatus? {
        if let preferred = Settings.agentChoice,
           let match = all.first(where: { $0.key == preferred }), match.usable {
            return match
        }
        return all.first(where: { $0.usable })
    }

    /// Run detection once, in the background, unless it has already run.
    static func warmUp(_ completion: @escaping () -> Void = {}) {
        if cached != nil { refreshStaleProviders(completion); return }
        statuses { _ in completion() }
    }

    /// When each provider was last asked what it offers.
    private static var probedAt: [String: Date] = [:]

    /// How old a provider's answer may get before it is worth asking again.
    ///
    /// **Two windows, because the two kinds of provider cost different things
    /// to ask.** A loopback probe is a millisecond and never leaves the Mac,
    /// and `ollama pull` is something people do in the middle of a session and
    /// then expect to see, so two minutes there is generous. A hosted one is a
    /// round trip to somebody else's server for a catalogue that changes about
    /// weekly, so an hour is already more often than the data moves.
    private static func staleAfter(_ provider: Provider) -> TimeInterval {
        provider.isLoopback ? 120 : 3600
    }

    /// Re-ask any provider whose answer has gone stale, in the background.
    ///
    /// **This is what makes a new model appear without relaunching.** The cache
    /// had no timestamp and no expiry: it was filled once by `warmUp` and
    /// otherwise refreshed only by opening Settings › Ask or pressing "Check
    /// again". That is fine for a CLI, whose aliases do not change, and wrong
    /// for a provider: Listen sits in the menu bar for weeks, and OpenRouter
    /// ships models continuously, so the list somebody searched was as old as
    /// their last launch.
    ///
    /// Providers only. The two CLIs are process launches and a login shell, and
    /// re-running those on a timer is exactly the freeze `statuses(_:)` was
    /// split up to avoid. What a CLI offers is three aliases that outlive any
    /// release anyway.
    ///
    /// The refresh lands in the cache for the *next* read rather than the
    /// current one, which is the honest trade: a menu that blocked on the
    /// network to open would be a worse bug than a menu that is occasionally a
    /// few minutes behind.
    static func refreshStaleProviders(_ completion: @escaping () -> Void = {}) {
        let now = Date()
        // The defaults read happens outside the lock. `NSLock` is not
        // reentrant, and holding it across code that could one day take it
        // again is how a deadlock gets written by somebody who is not looking
        // for one.
        let configured = Settings.providers
        lock.lock()
        let due = configured.filter { provider in
            let age = probedAt[provider.id].map { now.timeIntervalSince($0) } ?? .infinity
            return age >= staleAfter(provider)
        }
        lock.unlock()
        guard !due.isEmpty else { completion(); return }

        DispatchQueue.global(qos: .utility).async {
            var fresh = [String: AgentStatus]()
            let group = DispatchGroup()
            let guard_ = NSLock()
            for provider in due {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let status = provider.probe()
                    guard_.lock(); fresh[provider.id] = status; guard_.unlock()
                    group.leave()
                }
            }
            _ = group.wait(timeout: .now() + 20)

            guard_.lock(); let probed = fresh; guard_.unlock()
            // Observable on demand, because a background refresh that works and
            // one that never fires look identical from outside. `LISTEN_DEBUG=1`
            // is the same switch capture state changes use.
            if DEBUG {
                for (id, status) in probed {
                    FileHandle.standardError.write(Data(
                        "[Listen] refreshed \(id): \(status.models.count) models\n".utf8))
                }
            }
            lock.lock()
            for (id, status) in probed {
                probedAt[id] = Date()
                if let index = cache?.firstIndex(where: { $0.key == id }) {
                    cache?[index] = status
                } else {
                    cache?.append(status)
                }
            }
            lock.unlock()
            DispatchQueue.main.async { completion() }
        }
    }

    /// The one Listen would use: the setting when it names an installed and
    /// signed-in backend, otherwise the first that is usable.
    /// **Runs full detection. Never call this on the main thread.**
    ///
    /// Process launches for both CLIs, including three concurrent `claude`
    /// sessions to resolve what the aliases currently mean, plus an HTTP probe
    /// per provider with a twenty second ceiling. Measured on this Mac with two
    /// CLIs and two providers: about three seconds.
    ///
    /// `cachedChosen()` is the main thread's version, and `choose(from:)` is
    /// for anybody who already has the list.
    static func chosen() -> AgentStatus? {
        choose(from: statuses())
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
        /// What the endpoint backend's `usage` reported, summed over the rounds
        /// of one answer. Nil for the CLIs, which do not break it out.
        ///
        /// Parsed and **not drawn**, the same as `costUSD`, but the argument is
        /// weaker here and worth knowing about: the reason no number appears
        /// under an answer is that everybody on the CLI backends pays a flat
        /// monthly price, so a figure would read as a meter on a plan that has
        /// none. A metered API key genuinely is a meter. Nothing is shown yet
        /// because tokens are not money without a price list, and Listen has no
        /// business keeping one.
        var promptTokens: Int?
        var completionTokens: Int?
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
        /// Which server, for a `.endpoint` question.
        ///
        /// Carried rather than looked up from `path`. The lookup version had to
        /// guess which configured provider a base URL meant, and got it wrong
        /// as soon as `--to` pointed somewhere that was not the configured one.
        var provider: Provider?
        /// The conversation so far, for a backend that has no session to
        /// resume.
        ///
        /// The two mechanisms are exclusive rather than alternative. A CLI owns
        /// the thread and is handed an id; an endpoint is stateless and is
        /// handed the messages, every time. `AgentRun` ignores this and
        /// `AgentChat` ignores `resume`, so a `Question` never has to say which
        /// kind it is.
        var history: [Chat.Turn] = []
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

        Cite what you are drawing on, with a marker straight after the sentence \
        it supports: after its full stop, and with no space before it, the way a \
        footnote is numbered:

        - `[rec:<id>]` for a recording, the id `list_recordings` gave you
        - `[note:<slug>]` for a note
        - `[person:<name>]` for somebody in the library

        Listen draws each one as a small number the reader can click to open \
        that page, so spell the id exactly as a tool returned it: a marker \
        naming something that is not there is dropped, and the claim is left \
        with nothing behind it. Cite only what you actually read. Two markers \
        may sit side by side when a sentence rests on two recordings.
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
            // **Codex does not give an MCP server its own environment.**
            // Measured, and it is the kind of wrong that reports success:
            // pointed at a five-recording scratch library, `listen ask --codex`
            // answered "56", which is the size of the real one. Claude answered
            // 5 from the identical setup, so it forwards and Codex does not.
            //
            // Every measurement of Codex taken against a scratch library before
            // this was therefore reading the wrong library and looked fine. It
            // matters to users only if they set the variable, and it matters to
            // anybody testing this app every single time.
            if let library = ProcessInfo.processInfo.environment["LISTEN_LIBRARY"] {
                args += ["-c", "mcp_servers.listen.env.LISTEN_LIBRARY=\"\(library)\""]
            }
            if let model = question.model { args += ["--model", model] }
            // Codex has no --append-system-prompt, so the brief rides in front
            // of the question. On a resumed thread it is already in the
            // history, so it is sent once.
            args.append(question.resume == nil
                        ? brief(allowWrites: question.allowWrites) + "\n\n---\n\n" + question.text
                        : question.text)
            return args

        case .endpoint:
            // There is no command. The equivalent thing to look at is the POST
            // body, which `AgentChat.requestBody` builds and
            // `listen ask --print-request` prints. Empty rather than a
            // `fatalError`, because the one caller is a debugging flag and it
            // says so itself.
            return []
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
    /// Internal rather than private: `AgentChat` runs its own tool loop and has
    /// exactly the same line to draw beside a call, and two copies of this rule
    /// would be two answers to "what is worth showing".
    static func detail(_ input: [String: Any]?) -> String {
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

/// One conversation, kept in the library as `chats/<id>.json`.
///
/// **It used to be `chat.json` inside the recording's own folder**, on the
/// argument `turns.json` and `embeddings.json` make: the folder is the
/// recording, so nothing can be stranded and a conversation about a meeting
/// cannot outlive it. Asking about the library is what settles that the other
/// way. A question spanning four meetings has four bad homes and no good one,
/// and a question about none of them has nowhere at all to go, which is exactly
/// the argument that moved notes out of those folders before anything shipped.
///
/// So `recordings` is an array all the way down and a conversation about one
/// meeting is an array of one, which is `Notes`' arrangement for `Notes`'
/// reasons. It also earns the back links for free: the conversations about a
/// recording are the ones naming it, computed the way `Notes.sources` is
/// computed in reverse.
///
/// **Still not a note.** A note is somebody's finished reading of a meeting and
/// is listed in the library; this is the working-out, and is reached from the
/// composer's own history instead. The button that turns one into the other is
/// the whole point of keeping them apart: everything here is disposable until
/// somebody says otherwise.
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

    /// Everything below is `Optional`, and that is load-bearing rather than
    /// tidy. Swift's synthesized decoder throws `keyNotFound` on a missing key
    /// **even where the property has a default**, and `load` treats a file that
    /// will not decode as absent, so a non-optional added here would silently
    /// empty every conversation already on disk. Measured on `Metadata.tags`
    /// and on `StoredTranscript.dictionary` before this, both times.
    ///
    /// The filename's stem. Absent in a file written before conversations moved
    /// out of recording folders, and filled in by `migrate`.
    var id: String?
    /// The first question, which is what the history list shows. An answer's
    /// opening line is usually a sentence rather than a name, so the question is
    /// the half worth keeping: the same argument `saveAsNote` already makes when
    /// it titles a note.
    var title: String?
    var created: String?
    var updated: String?
    /// The meetings this conversation is about. One for a question asked on a
    /// recording's page, several for a question spanning them, none for a
    /// question about the library.
    var recordings: [String]?
    /// The person this conversation is about, when it was asked from their
    /// card. A name rather than an id, because a person *is* a name in this
    /// app and there is nothing else to key on.
    var person: String?

    static let you = "you", agent = "agent"

    var sources: [String] { recordings ?? [] }

    /// What the history list calls it.
    ///
    /// Falls back to the first thing the user said, because every conversation
    /// on disk before `title` existed has one and none of them have a title.
    var displayTitle: String {
        let asked = title?.isEmpty == false
            ? title!
            : (turns.first { $0.who == Chat.you }?.text ?? "")
        return asked.isEmpty ? "Conversation" : Chat.shorten(asked)
    }

    /// Cut at a word, and say that it was cut.
    ///
    /// A hard `prefix(60)` ends mid-word: measured on the first real
    /// conversation, "…then the key po", which reads as a title somebody typed
    /// badly rather than as one that continues. Falls back to the hard cut for a
    /// 60-character first word, which is a URL rather than a sentence.
    static func shorten(_ text: String, to limit: Int = 60) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard flat.count > limit else { return flat }
        let cut = String(flat.prefix(limit))
        guard let space = cut.lastIndex(of: " "), space > cut.startIndex else {
            return cut + "…"
        }
        return cut[cut.startIndex..<space] + "…"
    }
}

extension Chat {
    /// Beside `notes/`, and for the reason stated on the type.
    static var directory: URL { Library.root.appendingPathComponent("chats") }

    private static func url(id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    /// A conversation by id, or nil.
    ///
    /// A file that will not decode is treated as absent rather than as an
    /// error. The alternative is a window that refuses to open because a
    /// disposable sidecar is malformed, and nothing here is worth that.
    static func load(id: String) -> Chat? {
        guard let data = try? Data(contentsOf: url(id: id)),
              var chat = try? JSONDecoder().decode(Chat.self, from: data) else { return nil }
        // The filename is the identity, so a file somebody renamed by hand is
        // the id it now has rather than the one written inside it.
        chat.id = id
        return chat
    }

    /// Every conversation, most recently touched first.
    ///
    /// Which is the order the history list wants and the opposite of the
    /// library's: a conversation is picked up where it was left, so the one
    /// edited last is the one being resumed, whereas a recording is filed under
    /// the day it happened and never moves. This is the same reason `Note.date`
    /// reads `created` and this reads `updated`.
    static func all() -> [Chat] {
        migration
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { load(id: $0.deletingPathExtension().lastPathComponent) }
            .sorted { ($0.updated ?? "") > ($1.updated ?? "") }
    }

    /// The conversations about one recording, which is its back links.
    ///
    /// `Notes.sources` computed the other way round. A recording that has been
    /// deleted simply matches nothing, so there is no orphan to tidy up, which
    /// is the property the note store already relies on.
    static func about(_ recordingID: String) -> [Chat] {
        all().filter { $0.sources.contains(recordingID) }
    }

    /// Write it, filling in whatever identity it does not have yet.
    ///
    /// `mutating` so the caller keeps the id it was given: a conversation is
    /// saved after every exchange, and one that took a fresh id each time would
    /// leave a file per question behind it.
    ///
    /// `touch: false` writes without moving `updated`, which only the migration
    /// wants. `all()` orders the history by that field, so stamping every
    /// migrated conversation with the moment the migration happened to run would
    /// land the whole history in one second and lose the order it is sorted by.
    /// Measured on the first migrated conversation: `updated` came out as the
    /// migration's own clock rather than the last thing said in it.
    mutating func save(touch: Bool = true) {
        let now = Metadata.iso(Date())
        if id == nil { id = Metadata.makeID(Date()) }
        if created == nil { created = now }
        if title == nil || title?.isEmpty == true {
            let asked = turns.first { $0.who == Chat.you }?.text ?? ""
            // Shortened here rather than where it is drawn. A hard cut stored on
            // disk is indistinguishable from a title that is genuinely 60
            // characters long, so nothing downstream can tell it was truncated
            // and put the ellipsis back: measured, the first migrated
            // conversation read "…then the key po" in the back link.
            if !asked.isEmpty { title = Chat.shorten(asked) }
        }
        if touch || updated == nil { updated = now }

        guard let id else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Chat.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Chat.url(id: id), options: .atomic)
    }

    static func forget(id: String) {
        try? FileManager.default.removeItem(at: url(id: id))
    }

    /// Once per process, from a `static let`, for the reason `Notes.migration`
    /// records: there is no one startup path the CLI, the app and the pipeline
    /// actor all go through, and a `static let` is initialised lazily and
    /// exactly once by the runtime.
    private static let migration: Int = migrate()

    /// Move `recordings/<id>/chat.json` into `chats/`, naming its source.
    ///
    /// Idempotent, and free after the first run: with no `chat.json` in any
    /// recording folder there is nothing to move. The conversation keeps its
    /// turns, its session and its backend, so a migrated conversation can still
    /// be followed up rather than only read.
    @discardableResult
    static func migrate() -> Int {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: Library.recordings, includingPropertiesForKeys: nil) else { return 0 }

        var moved = 0
        for folder in folders {
            let old = folder.appendingPathComponent("chat.json")
            guard fm.fileExists(atPath: old.path),
                  let data = try? Data(contentsOf: old),
                  var chat = try? JSONDecoder().decode(Chat.self, from: data) else { continue }

            let recordingID = folder.lastPathComponent
            chat.recordings = [recordingID]
            // The recording's own id, so a migrated conversation sorts beside
            // the meeting it came from rather than at whatever moment the
            // migration happened to run.
            chat.id = recordingID
            chat.created = chat.created ?? chat.turns.first?.at
            chat.updated = chat.updated ?? chat.turns.last?.at ?? Metadata.iso(Date())
            chat.save(touch: false)
            try? fm.removeItem(at: old)
            moved += 1
        }
        return moved
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

    /// Which backend to use, by `AgentStatus.key`, or nil to take whichever is
    /// ready.
    ///
    /// A string rather than an `AgentBackend`, because the thing being chosen
    /// is no longer always an enum case: `claude` and `codex` are, and every
    /// provider is its id. Absent by default rather than defaulting to Claude,
    /// so somebody who adds a provider later gets a working feature without
    /// having to find a setting they were never shown.
    ///
    /// **A choice that no longer exists is ignored rather than cleared.**
    /// `cachedChosen` simply finds no match and falls through to the first
    /// usable backend, so removing a provider and adding it back finds the same
    /// preference waiting.
    static var agentChoice: String? {
        get {
            let raw = defaults.string(forKey: agentBackendKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        set {
            if let newValue, !newValue.isEmpty { defaults.set(newValue, forKey: agentBackendKey) }
            else { defaults.removeObject(forKey: agentBackendKey) }
        }
    }

    private static func agentModelKey(_ key: String) -> String { "agentModel_" + key }

    /// The model to ask for, or nil to let the backend choose.
    ///
    /// Keyed by `AgentStatus.key`, so switching between backends in the
    /// composer's menu and back remembers what each was set to rather than
    /// carrying a Codex slug over to Claude, or an Ollama tag over to
    /// OpenRouter, either of which would be rejected.
    static func agentModel(_ key: String) -> String? {
        let stored = defaults.string(forKey: agentModelKey(key))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else { return nil }
        return stored
    }

    static func setAgentModel(_ key: String, _ model: String?) {
        if let model, !model.isEmpty {
            defaults.set(model, forKey: agentModelKey(key))
        } else {
            defaults.removeObject(forKey: agentModelKey(key))
        }
    }

    /// The same, for a backend rather than a key.
    static func agentModel(_ backend: AgentBackend) -> String? {
        agentModel(backend.rawValue)
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
