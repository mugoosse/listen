import Foundation
import Security

/// Asking the library through an OpenAI-compatible provider, which is the
/// backend family where **Listen is the harness**.
///
/// `claude` and `codex` are agents. Listen hands them a brief, an MCP config, a
/// tool allowlist and a model, and they run the loop. A provider is one
/// stateless POST that can answer with "I would like to call this tool", so the
/// loop, the tool execution, the conversation history and the streaming parse
/// are all this file's job.
///
/// Everything above `AgentRun.Event` is untouched by that. The pane, the
/// settings pane and `listen ask` consume the same eight events and cannot tell
/// which backend produced them, which is why this is an addition rather than a
/// rewrite.
///
/// ## What it costs and what it buys
///
/// It buys the case this app should be best at: a model on the same Mac as the
/// recordings, at `http://localhost:11434/v1`, with no account anywhere and no
/// byte leaving the machine. It also buys everybody who has neither CLI.
///
/// It costs the sentence `.agents/notes/agent.md` opens with. Listen holds keys
/// now, for hosted providers, and a hosted provider means transcripts go over
/// the network. That is not hidden behind a checkbox: `Exposure` below is
/// three-valued and the settings pane says which of the three a URL is, in
/// words, before it is saved.

// ---------------------------------------------------------------------------
// One provider
// ---------------------------------------------------------------------------

/// One OpenAI-compatible server Listen can put a question to.
///
/// **A list, not a slot.** This began as a single configurable endpoint plus a
/// hardcoded OpenRouter case, on the argument that a list would stop
/// `AgentBackend` being a raw-value enum whose raw value is written into every
/// `chat.json`. The argument was sound and the conclusion was wrong: the enum
/// keeps its three cases and stops trying to name *which* server, and a
/// provider's `id` names that instead. `Chat.backend` stores the id, which is a
/// string either way, so nothing on disk had to change shape.
///
/// The shape is `anarlog`'s, whose `owhisper-client` carries 27 of these. The
/// lesson worth copying is that almost every provider is **a row in a table
/// rather than an implementation**: one shared request path, and per-provider
/// data for the handful of things that genuinely differ. Its `groq` adapter is
/// 62 lines and most of that is filling in six fields.
struct Provider: Codable, Equatable {
    /// Stable, lowercase, and written into `chat.json` as the backend that
    /// answered. Never derived from the name, which a user can change.
    var id: String
    /// What the menus call it.
    var name: String
    /// The base, ending at `/v1` or wherever the server roots its API. Paths
    /// are appended to it, so a trailing slash is normalised away on the way in.
    var base: URL
    /// Whether it is useless without a key. Ollama ignores one entirely; every
    /// hosted provider refuses without it.
    var needsKey: Bool
    /// One clause for the row in Settings, in the user's terms rather than the
    /// protocol's.
    var note: String
    /// Where to get a key, for the providers that need one.
    var docs: String?
    /// The header the key rides in, when it is not `Authorization: Bearer`.
    ///
    /// **The single biggest axis of difference between providers**, and the
    /// reason it is a field rather than a branch: anarlog's `Auth` enum has
    /// exactly three shapes across 27 providers, and two of them are "a
    /// different header name". Nothing in the catalogue below needs it yet;
    /// Azure would, and it costs one optional string to be ready.
    var authHeader: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, base, needsKey, note, docs, authHeader
    }

    init(id: String, name: String, base: URL, needsKey: Bool,
         note: String, docs: String? = nil, authHeader: String? = nil) {
        self.id = id
        self.name = name
        // A trailing slash makes `appendingPathComponent` produce `//models`,
        // which some servers route and some 404. Normalising here means the
        // text field can be forgiving and nothing downstream has to be.
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        self.base = URL(string: text) ?? base
        self.needsKey = needsKey
        self.note = note
        self.docs = docs
        self.authHeader = authHeader
    }

    /// Every field past the first three decodes to a default when absent, for
    /// the reason `notes-tags-dictionary.md` records: a non-optional added later
    /// throws `keyNotFound` on every file already written, and this one is
    /// stored in preferences that outlive any release.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        base = try c.decode(URL.self, forKey: .base)
        needsKey = (try? c.decode(Bool.self, forKey: .needsKey)) ?? false
        note = (try? c.decode(String.self, forKey: .note)) ?? ""
        docs = try? c.decode(String.self, forKey: .docs)
        authHeader = try? c.decode(String.self, forKey: .authHeader)
    }

    var host: String { base.host ?? "" }

    /// OpenRouter gets two things no other provider does: attribution headers,
    /// and a model list filtered to the ones that will accept tools at all.
    var isOpenRouter: Bool { host.hasSuffix("openrouter.ai") }

    /// The server's root, for the endpoints that are not under `/v1`.
    ///
    /// Ollama's own `/api/version` sits beside the compatibility layer rather
    /// than inside it, and it is the one cheap way to learn that a URL is
    /// Ollama rather than something else answering the same shape.
    var origin: URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.path = ""
        components?.query = nil
        return components?.url ?? base
    }

    /// The header a request carries its key in.
    func authorization(_ key: String) -> (name: String, value: String) {
        if let authHeader { return (authHeader, key) }
        return ("Authorization", "Bearer \(key)")
    }

    // MARK: What a URL says about where the recordings go

    /// Three answers, because "is this local?" is not a yes or a no.
    ///
    /// The app's whole claim is that recordings do not leave the Mac. A
    /// loopback provider keeps that claim exactly as it was. A machine on the
    /// LAN breaks it in a way many people are fine with and should still be
    /// told about. A host on the internet breaks it in the way the claim was
    /// written to rule out, so that case names the host rather than saying
    /// "remote": the difference between "transcripts go somewhere else" and
    /// "transcripts go to openrouter.ai" is the difference between a warning
    /// somebody reads and one they skip.
    enum Exposure {
        case thisMac
        case thisNetwork
        case elsewhere(String)

        var sentence: String {
            switch self {
            case .thisMac:
                return "Runs on this Mac. Nothing about your recordings leaves it."
            case .thisNetwork:
                return "Runs on another machine on your network. Transcripts leave "
                     + "this Mac, and stay on this network."
            case .elsewhere(let host):
                return "Transcripts of the meetings you ask about are sent to "
                     + "\(host). This is the one part of Listen that is not local."
            }
        }

        var isLocal: Bool { if case .thisMac = self { return true }; return false }
    }

    var exposure: Exposure {
        guard let host = base.host?.lowercased() else { return .elsewhere("an unknown host") }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" {
            return .thisMac
        }
        if Self.isPrivate(host) { return .thisNetwork }
        return .elsewhere(host)
    }

    var isLoopback: Bool { exposure.isLocal }

    /// The reserved IPv4 ranges plus mDNS names, which is as far as a hostname
    /// can be classified without resolving it.
    ///
    /// A name that resolves to a private address is reported as `.elsewhere`,
    /// which overstates the exposure rather than understating it. That is the
    /// right way round for a sentence about where somebody's meetings go, and
    /// resolving here would mean a DNS lookup on every keystroke in a text
    /// field.
    private static func isPrivate(_ host: String) -> Bool {
        if host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }

    /// Plain http is accepted only where the packets stay: this Mac or this
    /// network. A hosted endpoint receives transcripts of the meetings asked
    /// about, so it has to be https, or those transcripts cross the internet
    /// in clear text. Returns the sentence to show, or nil when the URL is
    /// fine. One rule, used by the pane and the CLI, so they cannot disagree.
    static func schemeProblem(_ url: URL) -> String? {
        guard url.scheme == "http" else { return nil }
        if case .elsewhere(let host) = Provider.custom(url: url).exposure {
            return "\(host) is not on this Mac or your network, so it needs "
                 + "https. Plain http would send transcripts across the "
                 + "internet unencrypted."
        }
        return nil
    }
}

// ---------------------------------------------------------------------------
// The catalogue
// ---------------------------------------------------------------------------

extension Provider {
    /// The providers Listen knows how to fill in for you.
    ///
    /// **A table, and adding to it is the whole point.** Every one of these
    /// speaks the same protocol, so a new row costs a URL and a sentence and no
    /// code at all. That is the property `anarlog` bought with its adapter
    /// directory and the reason to copy the shape rather than the code.
    ///
    /// Local first, because a model on this Mac is the option that keeps the
    /// app's own claim intact, and because it is the only one that costs
    /// nothing to try.
    static let catalogue: [Provider] = [
        Provider(id: "ollama", name: "Ollama",
                 base: URL(string: "http://localhost:11434/v1")!,
                 needsKey: false, note: "on this Mac, no key needed",
                 docs: "https://ollama.com"),
        Provider(id: "lmstudio", name: "LM Studio",
                 base: URL(string: "http://localhost:1234/v1")!,
                 needsKey: false, note: "on this Mac, no key needed",
                 docs: "https://lmstudio.ai"),
        Provider(id: "llamacpp", name: "llama.cpp",
                 base: URL(string: "http://localhost:8080/v1")!,
                 needsKey: false, note: "on this Mac, no key needed"),
        Provider(id: "openrouter", name: "OpenRouter",
                 base: URL(string: "https://openrouter.ai/api/v1")!,
                 needsKey: true, note: "hundreds of hosted models behind one key",
                 docs: "https://openrouter.ai/keys"),
        Provider(id: "openai", name: "OpenAI",
                 base: URL(string: "https://api.openai.com/v1")!,
                 needsKey: true, note: "GPT models, billed by OpenAI",
                 docs: "https://platform.openai.com/api-keys"),
        Provider(id: "groq", name: "Groq",
                 base: URL(string: "https://api.groq.com/openai/v1")!,
                 needsKey: true, note: "open models, very fast",
                 docs: "https://console.groq.com/keys"),
        Provider(id: "cerebras", name: "Cerebras",
                 base: URL(string: "https://api.cerebras.ai/v1")!,
                 needsKey: true, note: "open models, very fast",
                 docs: "https://cloud.cerebras.ai"),
        Provider(id: "together", name: "Together",
                 base: URL(string: "https://api.together.xyz/v1")!,
                 needsKey: true, note: "open models, hosted",
                 docs: "https://api.together.ai/settings/api-keys"),
        Provider(id: "fireworks", name: "Fireworks",
                 base: URL(string: "https://api.fireworks.ai/inference/v1")!,
                 needsKey: true, note: "open models, hosted",
                 docs: "https://fireworks.ai/account/api-keys"),
        Provider(id: "mistral", name: "Mistral",
                 base: URL(string: "https://api.mistral.ai/v1")!,
                 needsKey: true, note: "Mistral's own models",
                 docs: "https://console.mistral.ai/api-keys"),
        Provider(id: "deepinfra", name: "DeepInfra",
                 base: URL(string: "https://api.deepinfra.com/v1/openai")!,
                 needsKey: true, note: "open models, hosted",
                 docs: "https://deepinfra.com/dash/api_keys"),
        Provider(id: "xai", name: "xAI",
                 base: URL(string: "https://api.x.ai/v1")!,
                 needsKey: true, note: "Grok models",
                 docs: "https://console.x.ai"),
    ]

    static func known(_ id: String) -> Provider? { catalogue.first { $0.id == id } }

    /// An id for a server that is not in the catalogue.
    ///
    /// Derived from the host so that adding the same URL twice is the same
    /// provider rather than two rows that disagree, and prefixed so it can
    /// never collide with a catalogue id added in a later version.
    static func customID(for url: URL) -> String {
        let host = (url.host ?? "custom").lowercased()
        let port = url.port.map { ":\($0)" } ?? ""
        return "custom-" + (host + port).replacingOccurrences(of: ".", with: "-")
    }

    /// A provider for a typed URL, which is a catalogue entry whenever the URL
    /// is one Listen already has a name for.
    ///
    /// Matching matters more than it looks: somebody who pastes
    /// `http://localhost:11434/v1` rather than pressing Ollama should get the
    /// row called Ollama, not a second row called `localhost` that behaves
    /// identically and confuses every list they appear in together.
    static func custom(url: URL, name: String? = nil) -> Provider {
        // Through the initialiser, so the trailing slash is normalised the same
        // way the catalogue's own URLs were.
        let normalised = Provider(id: "", name: "", base: url, needsKey: false, note: "").base
        if let known = catalogue.first(where: { $0.base == normalised }) { return known }
        let host = normalised.host ?? "endpoint"
        let probe = Provider(id: "", name: "", base: normalised, needsKey: false, note: "")
        return Provider(id: customID(for: normalised), name: name ?? host, base: normalised,
                        // A URL nobody catalogued may or may not want a key, and
                        // the field is offered either way. Loopback almost never
                        // needs one; anything else usually does. Through
                        // `exposure` rather than a third hand-rolled host list,
                        // which is how `[::1]` was missed here before.
                        needsKey: !probe.isLoopback,
                        note: "added by you")
    }
}

// ---------------------------------------------------------------------------
// Which providers are set up
// ---------------------------------------------------------------------------

extension Settings {
    private static let providersKey = "agentProviders"
    private static let legacyURLKey = "agentEndpointURL"
    private static let legacyNameKey = "agentEndpointName"

    /// Every provider the user has added, in the order they added them.
    ///
    /// Stored as JSON rather than as a list of ids, so a provider carries its
    /// own URL and name. A catalogue entry whose URL changes in a later version
    /// therefore keeps working for anybody who added it, which is the right way
    /// round: their server is where they said it was.
    static var providers: [Provider] {
        get {
            migrateProviders
            guard let data = defaults.data(forKey: providersKey),
                  let list = try? JSONDecoder().decode([Provider].self, from: data) else {
                return []
            }
            return list
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: providersKey)
        }
    }

    static func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    /// Add or replace by id, so adding the same one twice updates it.
    ///
    /// False, and nothing stored, when a managed profile restricts providers
    /// to this Mac and the candidate is not on it. Refused at the store
    /// rather than only in each surface, so a new surface cannot forget.
    @discardableResult
    static func addProvider(_ provider: Provider) -> Bool {
        if Settings.agentLoopbackOnly, !provider.isLoopback { return false }
        var list = providers.filter { $0.id != provider.id }
        list.append(provider)
        providers = list
        return true
    }

    static func removeProvider(_ id: String) {
        providers = providers.filter { $0.id != id }
        // The model preference goes with it. Left behind, re-adding the same
        // provider silently restores a model that may no longer exist there.
        setAgentModel(id, nil)
    }

    /// One-time move from the single-endpoint arrangement.
    ///
    /// The first version of this feature had one configurable URL in
    /// `agentEndpointURL` and a hardcoded OpenRouter case whose only state was
    /// a Keychain entry. Both become ordinary rows here. Runs once and is free
    /// afterwards, in the family of `Chat.migrate`.
    private static let migrateProviders: Void = {
        guard defaults.data(forKey: providersKey) == nil else { return }
        var list: [Provider] = []
        if let raw = defaults.string(forKey: legacyURLKey),
           let url = URL(string: raw), url.host != nil {
            let name = defaults.string(forKey: legacyNameKey)
            list.append(Provider.custom(url: url, name: name))
        }
        // A key in the Keychain is the only evidence OpenRouter was ever set
        // up, since it had no URL to store.
        if AgentKey.has("openrouter.ai"), let openrouter = Provider.known("openrouter") {
            list.append(openrouter)
        }
        guard !list.isEmpty, let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: providersKey)
        defaults.removeObject(forKey: legacyURLKey)
        defaults.removeObject(forKey: legacyNameKey)

        // **The preferences keyed by the old backend name have to come with
        // it.** Both were keyed `endpoint`, which now matches no provider, so
        // without this the chosen model is silently forgotten and the chosen
        // backend falls through to whatever is first usable. Measured: after
        // the first run of the migration, `provider list` showed Ollama with no
        // model and the composer had quietly switched to Claude Code.
        //
        // The custom endpoint is `list[0]` when there was one, because that is
        // the order it was appended in above.
        if let moved = list.first(where: { $0.id != "openrouter" }) {
            if let model = defaults.string(forKey: "agentModel_endpoint") {
                defaults.set(model, forKey: "agentModel_" + moved.id)
                defaults.removeObject(forKey: "agentModel_endpoint")
            }
            if defaults.string(forKey: "agentBackend") == "endpoint" {
                defaults.set(moved.id, forKey: "agentBackend")
            }
        }
        // OpenRouter kept its own name as a backend, so its model key already
        // reads `agentModel_openrouter` and needs no move. Only the choice does.
        if defaults.string(forKey: "agentBackend") == "openrouter",
           !list.contains(where: { $0.id == "openrouter" }) {
            defaults.removeObject(forKey: "agentBackend")
        }
    }()
}

// ---------------------------------------------------------------------------
// The one secret Listen holds
// ---------------------------------------------------------------------------

/// The API key for a remote endpoint, in the Keychain and nowhere else.
///
/// **Not `UserDefaults`.** Every other preference in this app is in the
/// `com.mgo.listen` domain, which is a plist in `~/Library/Preferences`: world
/// readable by anything running as the user, copied into every backup, and
/// printable with one `defaults read`. That is the correct home for a window
/// width and the wrong one for a credential.
///
/// Keyed by host rather than by a single "the key" slot, so changing the base
/// URL from a local server to a hosted one and back does not lose the key that
/// was typed for either.
enum AgentKey {
    private static let service = "com.mgo.listen.endpoint"

    static func read(for host: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// Write it, or remove it when the key is nil or empty.
    ///
    /// Delete-then-add rather than `SecItemUpdate`, because the update path has
    /// to handle "there was nothing there" separately anyway and this is the
    /// same number of calls with one branch instead of three.
    @discardableResult
    static func save(_ key: String?, for host: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(base as CFDictionary)
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return true
        }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        // Available whenever the Mac is unlocked, and never synced to iCloud.
        // A key that roamed to another device would be a credential this app
        // put somewhere the user did not put it.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func has(_ host: String) -> Bool { read(for: host) != nil }

    /// The key to use, which is the environment's when it has one.
    ///
    /// `LISTEN_ENDPOINT_KEY` is in the family of `LISTEN_LIBRARY` and
    /// `LISTEN_CHUNK`: an environment variable, so a Finder launch inherits
    /// none of it and nothing inside the app can set it by accident. It exists
    /// for two real cases, and neither is a preference somebody would want
    /// stored:
    ///
    /// - Measuring one endpoint against another without reconfiguring the app,
    ///   which is what `listen ask --to` is for.
    /// - A machine where the Keychain is not the right place, such as a server
    ///   running `listen ask` from a script.
    ///
    /// It wins over the stored key, because an override that loses to a setting
    /// is not an override.
    static func resolve(for host: String) -> String? {
        let environment = ProcessInfo.processInfo.environment["LISTEN_ENDPOINT_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let environment, !environment.isEmpty { return environment }
        return read(for: host)
    }
}

// ---------------------------------------------------------------------------
// Is it there, and what does it offer
// ---------------------------------------------------------------------------

extension Provider {
    /// What `AgentCLI.statuses()` reports for this provider.
    ///
    /// Synchronous, like `AgentCLI.capture`, and called from the same
    /// background pass. Three seconds and then give up: a loopback server that
    /// is not running refuses the connection immediately, and the timeout only
    /// matters for a hosted endpoint on a bad network, where waiting longer
    /// would freeze the settings pane's first draw for no better answer.
    /// The status carries the provider it belongs to, and `cachedChosen`, the
    /// composer's model menu and the settings list all match on `key`. An
    /// earlier version hardcoded the backend here and put two statuses in the
    /// list both claiming to be the same one: the row was labelled "Ollama"
    /// while pointing at `openrouter.ai`, and worse, choosing a model for one
    /// would have set it for the other.
    func probe() -> AgentStatus {
        let key = AgentKey.resolve(for: host)
        var models: [AgentModel] = []
        var account: String?
        var reachable: Bool?
        var refused = false

        // **Filtered at the source for OpenRouter.** Its catalogue is 400
        // models and 81 of them will not accept a `tools` parameter at all, so
        // offering those is offering a choice that cannot work. The filter is
        // the server's own, which is the only list that stays true as models
        // come and go. Measured: 400 unfiltered, 319 with the filter.
        //
        // It is **not** a guarantee the model will use the tools. See the notes
        // on `qwen3-30b-a3b-instruct`, which declares support and fabricates
        // anyway. This removes the ones that certainly cannot, and the runtime
        // grounding check catches the ones that can and do not.
        var listURL = base.appendingPathComponent("models")
        if isOpenRouter,
           var parts = URLComponents(url: listURL, resolvingAgainstBaseURL: false) {
            parts.queryItems = [URLQueryItem(name: "supported_parameters", value: "tools")]
            listURL = parts.url ?? listURL
        }

        switch get(listURL, key: key) {
        case .ok(let data):
            reachable = true
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let list = (json?["data"] as? [[String: Any]]) ?? []
            // Newest first. Everything a provider lists is equally reachable, so
            // the only question an ordering answers is "which of these did
            // somebody most likely mean", and the answer is almost never the one
            // whose vendor name begins with `a`. Servers that publish no
            // `created` keep their own order, which for Ollama is what you
            // pulled.
            let entries = list.sorted {
                ($0["created"] as? Int ?? 0) > ($1["created"] as? Int ?? 0)
            }
            let ids = entries.compactMap { $0["id"] as? String }
            // The cap exists for a pop-up menu. OpenRouter's picker is a combo
            // box that completes as you type, so it takes the whole list: a
            // model you cannot select is worse than a long list you can search.
            // **No cap.** There was one, of thirty, and it existed for a
            // pop-up menu that had to show every model it knew. The menu shows
            // recently-used ones now and `ModelPicker` searches the rest, so a
            // cap here is not a shorter menu, it is models that cannot be
            // reached at all: exactly the complaint that produced the picker,
            // one provider over. `modelsCeiling` is a sanity bound against a
            // pathological response, not a product decision.
            models = entries.prefix(Self.modelsCeiling).compactMap { entry -> AgentModel? in
                guard let id = entry["id"] as? String else { return nil }
                // `name` is often "Vendor: Model Name"; the vendor is already
                // in the id under the name, so the half after the colon is the
                // part worth reading.
                var display = (entry["name"] as? String) ?? id
                if let colon = display.firstIndex(of: ":") {
                    display = String(display[display.index(after: colon)...])
                        .trimmingCharacters(in: .whitespaces)
                }
                let prompt = (entry["pricing"] as? [String: Any])?["prompt"] as? String
                return AgentModel(
                    id: id, name: display.isEmpty ? id : display,
                    created: entry["created"] as? Int,
                    // Priced per token, and per million is the unit anybody
                    // compares in.
                    pricePerMTok: prompt.flatMap(Double.init).map { $0 * 1_000_000 },
                    context: entry["context_length"] as? Int)
            }
            account = "\(ids.count) model" + (ids.count == 1 ? "" : "s")
            if isOpenRouter { account = (account ?? "") + " that accept tools" }
        case .denied:
            reachable = false
            refused = true
            account = key == nil ? "no key set" : "the key was refused"
        case .unreachable:
            reachable = false
        }

        // Only worth asking once the compatibility layer has answered, and only
        // to put a name on the row: "Ollama 0.12.3" is a more useful thing to
        // read beside a URL than the URL again.
        var version: String?
        if reachable == true, case .ok(let data) = get(origin.appendingPathComponent("api/version"),
                                                       key: key),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let number = json["version"] as? String {
            version = "Ollama \(number)"
        }

        return AgentStatus(backend: .endpoint, path: base, version: version,
                           signedIn: reachable, account: account, models: models,
                           refused: refused, provider: self)
    }

    /// Two thousand: a bound on a malformed answer rather than on choice. See
    /// `probe`, where the cap that shaped a menu used to live.
    static let modelsCeiling = 2000

    private enum Answer {
        case ok(Data)
        /// 401 or 403: it is there, and it will not talk to us.
        case denied
        /// Nothing answered, or it answered with something that is not a list.
        case unreachable
    }

    private func get(_ url: URL, key: String?) -> Answer {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.httpMethod = "GET"
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        var answer = Answer.unreachable
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { done.signal() }
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 || http.statusCode == 403 { answer = .denied; return }
            guard (200..<300).contains(http.statusCode), let data else { return }
            answer = .ok(data)
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return answer
    }
}

// ---------------------------------------------------------------------------
// One question, run as a tool loop
// ---------------------------------------------------------------------------

/// Anything that can answer one question and stream it back.
///
/// Declared here rather than in `Agent.swift` because `AgentRun` already
/// satisfies it without changing a line: `start()` and `cancel()` are the two
/// things every caller of it has ever used. The conformance below is what lets
/// `AskView`, `AgentPane` and `listen ask` hold "a run" without naming which
/// kind of run it is.
protocol AgentSession: AnyObject {
    func start() throws
    func cancel()
}

extension AgentRun: AgentSession {}

extension AgentRun.Question {
    /// The one place that decides which engine answers a question.
    ///
    /// Every call site builds a `Question` and asks it for a session, so adding
    /// a fourth backend one day is a case here and nothing at any call site.
    func session(on queue: DispatchQueue = .main,
                 onEvent: @escaping (AgentRun.Event) -> Void) -> AgentSession {
        switch backend {
        case .claude, .codex:
            return AgentRun(self, on: queue, onEvent: onEvent)
        case .endpoint:
            return AgentChat(self, on: queue, onEvent: onEvent)
        }
    }
}

/// One question put to an OpenAI-compatible endpoint, with Listen running the
/// tool loop.
///
/// Built like `AgentRun` rather than like something new, because the two have
/// the same problem: bytes arrive in pieces on somebody else's thread, they
/// have to be split into lines, parsed, and turned into events on a queue the
/// caller chose. `AgentRun` reads a pipe and this reads a socket, and
/// everything after that is the same shape, including the self-retain in
/// `whileRunning` and the single serial queue that owns all the state.
final class AgentChat: NSObject, AgentSession, URLSessionDataDelegate {
    private let question: AgentRun.Question
    private let provider: Provider
    private let onEvent: (AgentRun.Event) -> Void
    private let queue: DispatchQueue

    /// Every payload the server sent, before this file has had an opinion about
    /// it. `listen ask --json` sets it.
    ///
    /// The reason it exists is the reason `runAgentRaw` exists for the CLIs,
    /// and it matters more here: with a CLI, a misread stream is a bug in
    /// reading somebody else's tested output, and this backend's parser is new.
    /// A wrong answer has to be attributable to the model or to this file, and
    /// only the untouched bytes can settle which.
    var onRawLine: ((String) -> Void)?

    /// Every piece of state below is read and written here and nowhere else.
    /// Delegate callbacks hop onto it, and so does `cancel`.
    private let work = DispatchQueue(label: "listen.agent.chat")

    /// Held by itself while a run is in flight, for the reason recorded on
    /// `AgentRun.whileRunning`: the caller is allowed to stop mentioning this
    /// object, and `listen ask` does exactly that before blocking on a
    /// semaphore. Cleared in `complete`, which is the one path out.
    private var whileRunning: AgentChat?

    private var session: URLSession?
    private var task: URLSessionDataTask?

    /// The conversation as the model sees it, grown by one assistant message
    /// and its tool results per round.
    private var messages: [[String: Any]] = []
    private var round = 0
    /// Retries of the *current* round, reset by `startRound`.
    private var attempt = 0
    private var startedAt = Date()
    private var outcome = AgentRun.Outcome(session: nil, costUSD: nil, durationMS: nil,
                                           toolCalls: 0, failure: nil)
    private var finished = false
    private var cancelled = false

    // Per-round state, reset by `startRound`.
    private var buffer = Data()
    private var answer = ""
    private var pending: [Int: PartialCall] = [:]
    private var saidThinking = false
    private var httpStatus = 200
    private var errorBody = Data()
    /// Whether the server honoured `stream: true`. Some do not, and answer with
    /// one JSON object instead of an event stream.
    private var streamed = true

    /// A tool call arrives a few characters at a time, keyed by index rather
    /// than by id: the id is only present on the first fragment, and the index
    /// is on all of them.
    private struct PartialCall {
        var id = ""
        var name = ""
        var arguments = ""
    }

    /// How many times the model may ask for tools before Listen stops it.
    ///
    /// Twelve. The retrieval ladder in `AgentRun.brief` is four steps deep and
    /// a thorough answer over several meetings walks it more than once, so this
    /// is roughly three times the honest worst case. It exists for the failure
    /// the CLIs never showed us: a small model that answers every tool result
    /// by calling the same tool again, which without a cap is an endless
    /// conversation nobody is watching.
    private static let maxRounds = 12

    /// How much of one tool result the model is allowed to see.
    ///
    /// A transcript is about 5,500 tokens and a local model's context is
    /// frequently 4k, so an unguarded `get_transcript` does not overflow
    /// loudly: it pushes the system prompt out of the window and the answer
    /// comes back confident and baseless. Cutting here is visible, and the
    /// truncation says how to ask for less.
    private static let maxToolResultChars = 24_000

    init(_ question: AgentRun.Question, on queue: DispatchQueue = .main,
         onEvent: @escaping (AgentRun.Event) -> Void) {
        self.question = question
        self.queue = queue
        self.onEvent = onEvent
        // The provider comes with the question rather than being looked up
        // from a URL. The lookup version had to guess which configured provider
        // a base URL meant, and got it wrong the moment `--to` pointed at a
        // server that was not the configured one: an OpenRouter answer was
        // labelled "Ollama", in the warning whose whole job is to name the
        // thing to stop trusting.
        self.provider = question.provider
            ?? Provider.custom(url: question.path)
        super.init()
    }

    // MARK: Starting

    func start() throws {
        guard let model = question.model, !model.isEmpty else {
            throw Failure.noModel(provider.name)
        }
        // Belt and braces under a managed profile: `addProvider` refuses new
        // hosted rows, and this catches one stored before the profile
        // arrived, or a `--to` override that never went through the store.
        if Settings.agentLoopbackOnly, !provider.isLoopback {
            throw Failure.managedLoopbackOnly(provider.name)
        }

        // Host and exposure, never the question. The log answers "did
        // transcripts leave, and for where", which is the whole reason a
        // hosted run is worth a line and a loopback one still gets one.
        let exposure: String
        switch provider.exposure {
        case .thisMac: exposure = "thisMac"
        case .thisNetwork: exposure = "thisNetwork"
        case .elsewhere: exposure = "elsewhere"
        }
        ActivityLog.append("agent_run", ["backend": "endpoint",
                                         "provider": provider.id.isEmpty
                                             ? provider.host : provider.id,
                                         "host": provider.host,
                                         "exposure": exposure])

        let configuration = URLSessionConfiguration.ephemeral
        // No timeout on the resource: a local model on a busy Mac can take
        // minutes over a long transcript, and a run that is producing tokens is
        // not stuck. The request timeout below is what catches a server that
        // never answers at all.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        messages = buildMessages()
        startedAt = Date()
        whileRunning = self
        work.async { [weak self] in self?.startRound() }
    }

    func cancel() {
        work.async { [weak self] in
            guard let self, !self.finished else { return }
            self.cancelled = true
            self.task?.cancel()
        }
    }

    enum Failure: LocalizedError {
        case noModel(String)
        case managedLoopbackOnly(String)

        var errorDescription: String? {
            switch self {
            case .noModel(let name):
                return "No model is chosen for \(name). Pick one in Settings › Ask, "
                     + "or pass --model."
            case .managedLoopbackOnly(let name):
                return "Your organisation's device profile restricts Ask to "
                     + "endpoints on this Mac, so \(name) cannot be used. "
                     + "Ollama and LM Studio still work."
            }
        }
    }

    // MARK: The conversation

    /// The message array, rebuilt from the conversation on disk.
    ///
    /// An endpoint has no session to resume, so the history *is* the session
    /// and every request carries all of it. Two rules, and both are load
    /// bearing:
    ///
    /// - **Only finished text turns are replayed.** The tool traffic of an
    ///   earlier answer is not sent again. Those are by far the most expensive
    ///   tokens in the conversation, they are already summarised into the
    ///   answer that follows them, and leaving them out is what makes every
    ///   request valid by construction: a `tool_call` can never end up in the
    ///   array without its result, because neither is ever in the array.
    /// - **`Step.activity` blocks are never replayed.** They are display text
    ///   written for a reader ("Read notes, read the transcript"), not
    ///   something the model said.
    ///
    /// A turn that failed is skipped as well. Its text is whatever got through
    /// before the failure, and replaying half a sentence as a complete
    /// assistant message teaches the model that half sentences are answers.
    private func buildMessages() -> [[String: Any]] {
        var out: [[String: Any]] = [[
            "role": "system",
            "content": AgentRun.brief(allowWrites: question.allowWrites),
        ]]
        for turn in question.history {
            guard turn.failure == nil else { continue }
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch turn.who {
            case Chat.you:   out.append(["role": "user", "content": text])
            case Chat.agent: out.append(["role": "assistant", "content": text])
            default:         break
            }
        }
        out.append(["role": "user", "content": question.text])
        return out
    }

    /// The tools this question may call, by their bare names.
    ///
    /// `AgentRun.tools` is the one owner of that decision, including keeping
    /// `delete_note` off both lists. The prefix it adds is Claude's naming for
    /// an MCP tool and means nothing here.
    private var allowedTools: Set<String> {
        Set(AgentRun.tools(allowWrites: question.allowWrites).map {
            $0.replacingOccurrences(of: "mcp__listen__", with: "")
        })
    }

    /// The POST body for the next round.
    ///
    /// `static` and taking its messages, because `listen ask --print-request`
    /// prints it without running anything, which is this backend's answer to
    /// `--print-command`.
    static func body(model: String, messages: [[String: Any]],
                     tools: [[String: Any]], stream: Bool) -> [String: Any] {
        var out: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
        ]
        if !tools.isEmpty { out["tools"] = tools }
        // Ollama, vLLM and OpenAI all understand this and it is the only way to
        // learn the token counts from a streamed answer. A server that does not
        // is free to ignore it, and none has been seen to refuse it.
        if stream { out["stream_options"] = ["include_usage": true] }
        return out
    }

    /// The body of the next round, **exactly as it goes on the wire**.
    ///
    /// `startRound` sends this and `--print-request` prints it, and the two
    /// being one function is the entire point. The first version built the body
    /// twice and the printed copy was wrong in both possible ways: it had no
    /// messages, because those are filled in by `start()` and printing does not
    /// start anything, and it said `stream: false`, because it read the flag
    /// that decides whether the *reader* wants deltas rather than what is
    /// actually negotiated. A debugging tool that prints a request nobody sends
    /// costs more time than having no debugging tool at all.
    func requestBody() -> [String: Any] {
        Self.body(model: question.model ?? "",
                  messages: messages.isEmpty ? buildMessages() : messages,
                  tools: MCP.toolSchemas(allowedTools),
                  // Always. See `startRound`: the connection is streamed
                  // whatever the caller asked for.
                  stream: true)
    }

    // MARK: One round

    /// Begin a new round of the tool loop.
    ///
    /// Separate from `sendRound` because a retry is not a round: it must not
    /// count towards `maxRounds`, or a busy server would eat the model's
    /// allowance for thinking.
    private func startRound() {
        round += 1
        attempt = 0
        sendRound()
    }

    private func sendRound() {
        buffer = Data()
        answer = ""
        pending = [:]
        saidThinking = false
        httpStatus = 200
        errorBody = Data()
        streamed = true

        var request = URLRequest(url: provider.base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let key = AgentKey.resolve(for: provider.base.host ?? "") {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        // OpenRouter attributes requests to an app by these two headers, and
        // shows the name on its own dashboards. Sent only there, rather than to
        // every endpoint: naming this app to somebody's own server on their own
        // network is data they did not ask to send, however harmless.
        if provider.isOpenRouter {
            request.setValue("Listen", forHTTPHeaderField: "X-Title")
            request.setValue("https://mugoosse.github.io/speak/", forHTTPHeaderField: "HTTP-Referer")
        }
        // Always streamed on the wire, whatever the caller asked for. The
        // `streaming` flag decides whether the *events* are deltas or blocks,
        // which is a question about the reader, and a terminal that wants whole
        // paragraphs still wants to know the connection is alive.
        guard let data = try? JSONSerialization.data(withJSONObject: requestBody()) else {
            complete(failure: "the request could not be encoded.")
            return
        }
        request.httpBody = data

        task = session?.dataTask(with: request)
        task?.resume()
    }

    /// The statuses worth sending the same request again for.
    ///
    /// Exactly the three the notes spike's OpenRouter arm retries
    /// (`listen-notes-spike/or_eval.py`), and for the reason it found them: a
    /// hosted endpoint under load answers 429, and a run that gave up on the
    /// first one failed a question that would have succeeded three seconds
    /// later. Everything else is a real answer, and retrying a 400 just asks
    /// the same wrong question twice.
    private static func retryable(_ status: Int) -> Bool {
        status == 429 || status == 502 || status == 503
    }

    private static let maxAttempts = 3

    // MARK: Reading the answer

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let type = http?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        work.async { [weak self] in
            self?.httpStatus = status
            // A server that ignored `stream: true` answers with one JSON
            // object and no `data:` prefixes. Parsing that as an event stream
            // finds nothing at all and produces an empty answer, which reads as
            // a model that had nothing to say. Noticing here costs one header.
            self?.streamed = type.contains("event-stream")
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        work.async { [weak self] in self?.consume(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        work.async { [weak self] in self?.roundEnded(error) }
    }

    private func consume(_ data: Data) {
        guard (200..<300).contains(httpStatus) else { errorBody.append(data); return }
        guard streamed else { errorBody.append(data); return }

        buffer.append(data)
        // Line-delimited, and a read can end mid-line, so the tail is kept.
        // Same shape as `AgentRun.consume`, which reads a pipe of the same.
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            readEvent(Data(line))
        }
    }

    /// One `data:` line of an SSE stream.
    ///
    /// Comments (`:` lines), blank lines between events and the trailing
    /// `[DONE]` are all skipped rather than treated as errors, because all
    /// three are ordinary parts of the format and only the payload is ours.
    private func readEvent(_ line: Data) {
        guard let text = String(data: line, encoding: .utf8) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        onRawLine?(String(payload))
        guard payload != "[DONE]", !payload.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8))
                as? [String: Any] else { return }
        readChunk(json)
    }

    private func readChunk(_ json: [String: Any]) {
        if let usage = json["usage"] as? [String: Any] { record(usage) }
        guard let choice = (json["choices"] as? [[String: Any]])?.first else { return }
        // A non-streamed answer arrives here too, under `message` rather than
        // `delta`, and is otherwise identical.
        let delta = (choice["delta"] as? [String: Any])
            ?? (choice["message"] as? [String: Any]) ?? [:]

        // `reasoning` is Ollama's and OpenAI's spelling, `reasoning_content` is
        // what several other servers emit for the same thing. Neither is part
        // of the answer, so both produce one event and no text.
        let thought = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String)
        if let thought, !thought.isEmpty, !saidThinking {
            saidThinking = true
            emit(.thinking)
        }

        if let content = delta["content"] as? String, !content.isEmpty {
            answer += content
            // One or the other, never both, which is the contract
            // `AgentRun.Event.textDelta` states: a reader handles deltas or
            // blocks and never has to work out whether it is seeing the same
            // words twice.
            if question.streaming { emit(.textDelta(content)) }
        }

        if let calls = delta["tool_calls"] as? [[String: Any]] { accumulate(calls) }
    }

    private func accumulate(_ calls: [[String: Any]]) {
        for call in calls {
            let index = call["index"] as? Int ?? 0
            var partial = pending[index] ?? PartialCall()
            if let id = call["id"] as? String, !id.isEmpty { partial.id = id }
            if let function = call["function"] as? [String: Any] {
                // Appended rather than assigned. The name usually arrives whole
                // on the first fragment and the arguments never do, but a
                // server is free to split either, and concatenating is correct
                // for both cases.
                if let name = function["name"] as? String { partial.name += name }
                if let arguments = function["arguments"] as? String { partial.arguments += arguments }
            }
            pending[index] = partial
        }
    }

    private func record(_ usage: [String: Any]) {
        let prompt = usage["prompt_tokens"] as? Int
        let completion = usage["completion_tokens"] as? Int
        if prompt != nil || completion != nil {
            outcome.promptTokens = (outcome.promptTokens ?? 0) + (prompt ?? 0)
            outcome.completionTokens = (outcome.completionTokens ?? 0) + (completion ?? 0)
        }
        // **And here `costUSD` stops being hypothetical.** For the CLI backends
        // it is what the turn *would* have cost on metered pricing, which is
        // why nothing draws it: those users pay a flat monthly price and a
        // figure would read as a meter on a plan that has none.
        //
        // OpenRouter streams `usage.cost` in real dollars actually charged.
        // Measured: 0.004878 for a two-message exchange on claude-sonnet-5.
        // Summed over the rounds, because one answer is several requests and a
        // per-round figure would understate what the question cost.
        //
        // Still not drawn anywhere. Capturing it is what makes showing it a
        // decision somebody can take later with a real number rather than a
        // guess; drawing it is a product change, and it must not appear under a
        // Claude Code answer where it would be fiction.
        if let cost = usage["cost"] as? Double, cost > 0 {
            outcome.costUSD = (outcome.costUSD ?? 0) + cost
        }
    }

    // MARK: Deciding what happens next

    private func roundEnded(_ error: Error?) {
        guard !finished else { return }
        if cancelled { complete(failure: nil); return }

        if let error {
            let failed = error as NSError
            // A cancelled task is not a failure to report: `cancel()` is a
            // button somebody pressed.
            if failed.domain == NSURLErrorDomain && failed.code == NSURLErrorCancelled {
                complete(failure: nil)
                return
            }
            complete(failure: describe(failed))
            return
        }

        guard (200..<300).contains(httpStatus) else {
            if Self.retryable(httpStatus), attempt < Self.maxAttempts - 1 {
                attempt += 1
                // Linear, matching the spike: 3s then 6s. Not exponential,
                // because there are only three attempts and the point is to
                // ride out a moment of load rather than to back off politely
                // for a minute while somebody waits at a composer.
                let delay = Double(3 * attempt)
                // Said out loud on the way past. A run that goes quiet for six
                // seconds and then answers is indistinguishable from a slow
                // model, and the one time it matters is when it is about to
                // fail.
                emit(.note("\(provider.name) is busy (HTTP \(httpStatus)). "
                           + "Trying again in \(Int(delay))s."))
                work.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.finished, !self.cancelled else { return }
                    self.sendRound()
                }
                return
            }
            complete(failure: serverError())
            return
        }

        // A server that ignored `stream: true` has sent one whole JSON object,
        // which nothing has parsed yet.
        if !streamed, let json = try? JSONSerialization.jsonObject(with: errorBody)
            as? [String: Any] {
            readChunk(json)
            errorBody = Data()
        }

        let calls = pending.keys.sorted().compactMap { pending[$0] }
            .filter { !$0.name.isEmpty }

        // Whole blocks when the caller did not ask for deltas. Emitted before
        // the tool calls below, so an answer that explains what it is about to
        // do arrives before it does it, which is the order it was written in.
        if !question.streaming && !answer.isEmpty { emit(.text(answer)) }

        guard !calls.isEmpty else { complete(failure: nil); return }

        guard round < Self.maxRounds else {
            // Named rather than silent. An answer that stops because a cap was
            // hit and says nothing about it is indistinguishable from a model
            // that decided it was done.
            complete(failure: "\(provider.name) called tools \(Self.maxRounds) times "
                     + "without reaching an answer, so Listen stopped it. A smaller "
                     + "question, or a model that follows instructions more closely, "
                     + "is the way through.")
            return
        }

        messages.append(assistantMessage(calls))
        for call in calls { messages.append(runTool(call)) }
        startRound()
    }

    /// What the model just said, in the shape it has to be sent back in.
    ///
    /// The tool results that follow are only valid if this message is in front
    /// of them carrying the same ids, which is the one part of the OpenAI shape
    /// that cannot be skipped.
    private func assistantMessage(_ calls: [PartialCall]) -> [String: Any] {
        [
            "role": "assistant",
            "content": answer,
            "tool_calls": calls.enumerated().map { index, call in
                [
                    // A server that sent no id still needs one here, and it
                    // only has to match the tool message below.
                    "id": call.id.isEmpty ? "call_\(round)_\(index)" : call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments],
                ] as [String: Any]
            },
        ]
    }

    /// Run one tool against the library and turn it into a `tool` message.
    ///
    /// Every failure here comes back **as a result rather than as an error**,
    /// which is the whole difference between this and a CLI backend. Claude
    /// does not hand Listen malformed JSON or invent a tool name; a 7B model
    /// does both, and a run that died on either would be a feature that works
    /// on frontier models and nowhere else. Told what it got wrong, in the
    /// place it is looking, a model retries and usually succeeds.
    private func runTool(_ call: PartialCall) -> [String: Any] {
        outcome.toolCalls += 1

        var arguments: [String: Any] = [:]
        var text: String
        var ok = true

        let raw = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == "{}" {
            // A tool with no required arguments, which several of these are.
        } else if let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
                    as? [String: Any] {
            arguments = parsed
        } else {
            ok = false
            text = "The arguments were not valid JSON, so nothing ran. Send them as a "
                 + "JSON object, for example {\"recording_id\": \"…\"}. What arrived was: "
                 + String(raw.prefix(200))
            emit(.toolCall(name: call.name, detail: ""))
            emit(.toolResult(name: call.name, ok: false))
            return ["role": "tool", "tool_call_id": id(of: call), "content": text]
        }

        emit(.toolCall(name: call.name, detail: AgentRun.detail(arguments)))
        do {
            text = try MCP.call(call.name, arguments)
        } catch {
            ok = false
            text = error.localizedDescription
        }

        if text.count > Self.maxToolResultChars {
            text = String(text.prefix(Self.maxToolResultChars))
                + "\n\n[Cut off after \(Self.maxToolResultChars) characters. Ask for less: "
                + "most tools here take `limit`, and the paginated ones take `offset` too.]"
        }

        emit(.toolResult(name: call.name, ok: ok))
        return ["role": "tool", "tool_call_id": id(of: call), "content": text]
    }

    private func id(of call: PartialCall) -> String {
        call.id.isEmpty ? "call_\(round)_0" : call.id
    }

    // MARK: Failing usefully

    /// What a non-2xx said, preferring the server's own words.
    ///
    /// The sentence that matters most is Ollama's "does not support tools",
    /// which is a 400 with a plain message in it. Reporting the status code
    /// alone would turn the commonest first-run mistake, picking a model that
    /// cannot call tools, into an unexplained failure.
    private func serverError() -> String {
        let body = String(data: errorBody, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var detail = body
        if let json = try? JSONSerialization.jsonObject(with: errorBody) as? [String: Any] {
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                detail = message
            } else if let error = json["error"] as? String {
                detail = error
            }
        }
        if httpStatus == 401 || httpStatus == 403 {
            return "\(provider.name) refused the key (HTTP \(httpStatus)). "
                 + "Settings › Ask is where to change it."
        }
        if detail.isEmpty { return "\(provider.name) answered HTTP \(httpStatus)." }
        return "\(provider.name): \(String(detail.prefix(500)))"
    }

    private func describe(_ error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            // The commonest state of a local endpoint by a distance, and the
            // fix is one command, so the message is that command.
            return "Nothing is answering at \(provider.base.absoluteString). "
                 + (provider.isLoopback
                    ? "Start the server first, with `ollama serve` or whatever runs yours."
                    : "Check the base URL in Settings › Ask.")
        case NSURLErrorTimedOut:
            return "\(provider.name) did not answer in time."
        case NSURLErrorNotConnectedToInternet:
            return "No internet connection, and \(provider.name) is not on this Mac."
        default:
            return error.localizedDescription
        }
    }

    // MARK: Finishing

    /// Whether this answer could possibly have come from the library.
    ///
    /// **The worst failure this backend has, measured.** Asked "how many
    /// recordings are in the library?" through OpenRouter,
    /// `qwen/qwen3-30b-a3b-instruct-2507` called no tools at all and answered
    /// "There are 1,247 recordings in the library.[rec:0001]". Confident, well
    /// formatted, cited, and entirely invented: the real answer was 5.
    ///
    /// It is not a capability problem and cannot be filtered out in advance.
    /// That model *declares* tool support in OpenRouter's own catalogue, as do
    /// 333 of its 400 models. Declaring it means the API accepts the parameter,
    /// not that the model reliably uses it, and the same request answered
    /// correctly on a local Qwen and on Claude Sonnet.
    ///
    /// So it is caught after the fact, by an invariant that is exactly true:
    /// **the tools are the only thing this backend can see.** The brief says
    /// so. If nothing was called and there is no earlier conversation to
    /// remember from, then whatever the answer says about the library came out
    /// of the model's weights.
    ///
    /// The history clause is load-bearing rather than defensive: a follow-up
    /// answered from what was already said is legitimate and calls nothing.
    /// Verified with the "teal" conversation, which correctly makes no tool
    /// calls and must not be flagged.
    ///
    /// A note rather than a failure, because "hello" and "what can you do?" are
    /// real questions that need no tools and deserve their answer. This says
    /// what happened and lets the reader judge it.
    private var answeredFromNothing: Bool {
        outcome.toolCalls == 0
            && question.history.isEmpty
            && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func complete(failure: String?) {
        guard !finished else { return }
        finished = true
        if failure == nil, answeredFromNothing {
            emit(.note("\(provider.name) answered without reading anything from the "
                       + "library, so nothing in this answer is grounded in your "
                       + "recordings. Try a model that uses tools."))
        }
        // Wall clock. No endpoint reports a duration and none could report a
        // useful one: this is how long the person waited, which is the number
        // the pane is putting under the answer.
        outcome.durationMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        outcome.failure = failure
        emit(.finished(outcome))
        session?.finishTasksAndInvalidate()
        session = nil
        // The delegate is retained by the session until it is invalidated, so
        // this and the line above are the two halves of one release.
        whileRunning = nil
    }

    private func emit(_ event: AgentRun.Event) {
        queue.async { [onEvent] in onEvent(event) }
    }
}
