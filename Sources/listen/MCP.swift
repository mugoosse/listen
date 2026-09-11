import ListenKit
import Foundation

/// `listen mcp`: an MCP server over stdio, where notes, tags and the user's
/// own vocabulary are the writable surface.
///
/// Hand-rolled rather than pulled from the SDK. The surface is twenty-nine
/// tools and two resources over files already on disk, though one session may
/// be given fewer: see `serve(_:)` and `--tools`. The official Swift SDK
/// brings a dependency tree and a concurrency model into a binary that already
/// carries MLX, CoreML and Sparkle. The protocol needed here is a few hundred
/// lines of JSON-RPC with no streaming and no subscriptions.
///
/// **It opens no port**, and the app does not need to be running: the library on
/// disk is the source of truth.
///
/// **Everything except notes, tags, the dictionary and a recording's name is
/// read-only, and that is a boundary rather than a milestone.** This server
/// used to write nothing at all. It now writes note artifacts, a recording's
/// tags, the user's own vocabulary and a derived title, and proposes a
/// correction to person memory without applying one. It cannot rename a
/// speaker, delete a recording, or change a fact the user has written down.
///
/// The line is between evidence and opinion. A transcript is a record of what
/// was said; a note is somebody's reading of it and a tag is somebody's filing
/// of it. Both are reversible, both are visible in the window the moment they
/// are written, and a wrong one is a wrong opinion sitting beside the recording
/// that disproves it. A wrong transcript edit is a fact that is simply gone,
/// because the audio is an hour long and nobody re-listens. So anything that
/// changes the evidence goes through a human, in the window or at the CLI where
/// it can be seen and undone, and everything derived from it is open.
///
/// ## Why the dictionary is on the writable side, and the backfill still is not
///
/// A dictionary rule is the one write that crosses that line, so it is split
/// rather than admitted whole. Adding a rule changes nothing that exists: it
/// says how the next recording should be spelled, and `remove_dictionary_entry`
/// takes it back. That is an opinion about vocabulary, and it belongs with tags
/// for the same reason tags do, which is that the user telling an agent "it is
/// called Seapoint, not C point" and the agent being unable to write that down
/// makes them say it again next week.
///
/// Applying that rule to transcripts that already exist is the other half, and
/// it is exactly the transcript edit the paragraph above rules out:
/// `DictionaryBackfill.apply` takes no backup, on purpose, so the audio is the
/// only surviving copy of what the pipeline first wrote. It is still offered,
/// because a rule that fixes tomorrow and leaves the meeting where you noticed
/// the mistake spelled wrong for ever is the thing `DictionaryBackfill` exists
/// to avoid. What keeps it honest is that `apply_dictionary_backfill` will not
/// run without the sentence total `preview_dictionary_backfill` returned, over
/// the same scope. An agent cannot reach the write without having first
/// produced the lines a human reads, and a library that moved in between
/// refuses rather than writing something nobody saw.
///
/// Tags earn their place on the writable side for a second reason: they are how
/// a question says what it is about. "Summarise the job hunt calls" needs the
/// job hunt calls to be named, and an agent that can read a tag but never write
/// one can only ever answer questions somebody already did the filing for.
///
/// Transcripts are long, so pagination is not optional, and the transcript is a
/// separate call from the metadata so an agent can decide what it needs before
/// paying for it.
enum MCP {
    static let protocolVersion = "2024-11-05"

    /// `listen mcp [--tools a,b,c]`.
    ///
    /// Without `--tools` the server offers everything it has, which is what a
    /// hand-configured client such as Claude Desktop or Hermes gets. With it,
    /// the named tools are the whole surface: `tools/list` shows those and
    /// `tools/call` refuses the rest by name.
    ///
    /// The flag exists because **the allowlist could not be enforced from the
    /// client side, and two of the three backends were not enforcing it at
    /// all.** Codex has no way to filter an MCP server's tools (measured against
    /// codex-cli 0.147.0: a server takes a command, args, env, cwd and two
    /// timeouts, and nothing else), and an OpenAI-compatible endpoint only
    /// decides which schemas to *advertise*, so a model that invented a tool
    /// name reached the library anyway. See `AgentRun.tools(allowWrites:)`,
    /// which is still the one place that decides what a question may call.
    static func serve(_ arguments: [String] = []) -> Never {
        allowed = parseAllowed(arguments)
        transport = "stdio"
        // Line-delimited JSON-RPC on stdin. Nothing else may write to stdout
        // for the lifetime of the process: a stray print corrupts the stream
        // and the client sees a parse error rather than a message from us.
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                send(error(id: nil, code: -32700, message: "parse error"))
                continue
            }
            handle(request)
        }
        exit(0)
    }

    /// The allowlist this *process* is serving under, or nil for all of them.
    ///
    /// A static here and a parameter on `call`, which is not a contradiction:
    /// one `listen mcp` process serves exactly one client under exactly one
    /// allowlist, so for the stdio transport this is as much a property of the
    /// process as `transport` is. The in-app agent is the other caller, and it
    /// has as many live allowlists as there are conversations, which is why
    /// `call` takes it rather than reading this.
    private static var allowed: Set<String>?

    /// `--tools a,b,c`, repeatable, or a refusal on stderr.
    ///
    /// Comma-separated, which is not this CLI's usual rule. The rule against it
    /// exists because a user's text may contain a comma, which is exactly why
    /// `Tags.check` refuses one; a tool name is an identifier out of a fixed
    /// list compiled into this binary. Claude's own `--allowedTools` has this
    /// shape, and one flag is what keeps `listen ask --print-command` readable
    /// enough to reproduce a failure by hand.
    ///
    /// **Every refusal goes to stderr and exits.** `serve` owns stdout for the
    /// life of the process, so a usage line there corrupts the stream before
    /// the client has finished connecting, and the client reports a parse error
    /// rather than the thing that is actually wrong.
    private static func parseAllowed(_ arguments: [String]) -> Set<String>? {
        var wanted: Set<String>?
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--tools":
                i += 1
                guard i < arguments.count else { refuse("--tools needs a list of tool names.") }
                let names = arguments[i].split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                // An empty value is almost always a quoting accident, and it
                // would otherwise produce a server that refuses everything and
                // says nothing about why.
                guard !names.isEmpty else { refuse("--tools was given no tool names.") }
                let known = Set(tools.compactMap { $0["name"] as? String })
                for name in names where !known.contains(name) {
                    // Refused rather than dropped. The only thing that produces
                    // this list is `AgentRun.tools`, so a name that is not a
                    // tool is a bug in this repo, and a tool silently missing
                    // from an agent's surface is a capability lost with nothing
                    // anywhere to explain it.
                    refuse("no tool named `\(name)`. The tools are: "
                           + known.sorted().joined(separator: ", "))
                }
                wanted = (wanted ?? []).union(names)
            default:
                // Until now `listen mcp --anything` started an ordinary server
                // and ignored the argument, which is its own trap.
                refuse("unknown option `\(arguments[i])`. Try `listen help`.")
            }
            i += 1
        }
        return wanted
    }

    private static func refuse(_ message: String) -> Never {
        FileHandle.standardError.write(Data("listen mcp: \(message)\n".utf8))
        exit(2)
    }

    private static func handle(_ request: [String: Any]) {
        let id = request["id"]
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            send(result(id: id, [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:] as [String: Any],
                                 "resources": [:] as [String: Any]],
                "serverInfo": ["name": "listen", "version": versionString],
            ]))

        // A notification has no id and takes no reply. Answering one is a
        // protocol violation that some clients treat as fatal.
        case "notifications/initialized", "initialized":
            return

        case "tools/list":
            send(result(id: id, ["tools": tools(allowing: allowed)]))

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                send(result(id: id, [
                    "content": [["type": "text",
                                 "text": try call(name, arguments, allowing: allowed)]],
                ]))
            } catch {
                // An error inside a tool call is reported as content with
                // isError, not as a JSON-RPC error: the call reached us and was
                // understood, and the agent should see why it failed.
                send(result(id: id, [
                    "content": [["type": "text", "text": error.localizedDescription]],
                    "isError": true,
                ]))
            }

        case "resources/list":
            send(result(id: id, ["resources": resources]))

        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            // The resource route reads the same transcripts the tools do, so
            // it leaves the same trace. The uri's last component is the id.
            ActivityLog.append("mcp_resource", [
                "transport": transport,
                "recordings": ActivityLog.recordingIDs(
                    in: ["recording_id": uri.split(separator: "/")
                        .dropLast(uri.hasSuffix("/transcript") ? 1 : 0)
                        .last.map(String.init) ?? ""]),
            ])
            if let text = readResource(uri) {
                send(result(id: id, ["contents": [[
                    "uri": uri,
                    "mimeType": uri.contains("/transcript") ? "text/plain" : "text/markdown",
                    "text": text,
                ]]]))
            } else {
                send(error(id: id, code: -32602, message: "no such resource: \(uri)"))
            }

        case "ping":
            send(result(id: id, [:]))

        default:
            send(error(id: id, code: -32601, message: "unknown method: \(method)"))
        }
    }

    // MARK: - Tools

    /// The tool list, and `call` below, are internal rather than private
    /// because stdio is no longer the only transport onto them.
    ///
    /// `serve()` is what Claude and Codex talk to, over a pipe, in a second
    /// process. An OpenAI-compatible endpoint has no MCP client at all, so
    /// `AgentChat` runs the tool loop itself and calls straight into `call`.
    /// Both routes therefore reach the library through the same function, which
    /// is the property worth protecting: two transports that resolved a
    /// recording differently would be a bug nobody could reproduce from one
    /// side.
    static var tools: [[String: Any]] {
        [
            [
                "name": "list_recordings",
                "description": "List recordings, newest first. Returns metadata only. "
                    + "Filters combine with AND, so person plus a date range is the "
                    + "cheapest way to narrow a library before asking for transcripts. "
                    // Measured, and it is worth the sentence. Asked "how many
                    // recordings are in the library?", gemma4 called nothing and
                    // answered "I cannot provide the total number, the available
                    // tools allow…", because nothing said the count was already
                    // in the reply. `pagination.total` has always been there.
                    // Naming it turns a refusal into a one-call answer, and the
                    // smaller the model the more it needs saying.
                    + "**`pagination.total` is how many recordings match**, whatever "
                    + "`limit` you asked for, so counting needs one call and no paging.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string",
                                  "description": "Filter on title and transcript text."],
                        "person": ["type": "string",
                                   "description": "Only recordings this person speaks in. "
                                       + "Matches the name from list_people, and your own "
                                       + "name matches the microphone track."],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Only recordings carrying **all** of "
                                + "these tags. A tag is the user's own filing, so it "
                                + "is usually the right way to name a subject. Call "
                                + "list_tags first rather than guessing.",
                        ],
                        "after": ["type": "string",
                                  "description": "Only recordings on or after this date, "
                                      + "as YYYY-MM-DD or a full ISO 8601 timestamp."],
                        "before": ["type": "string",
                                   "description": "Only recordings on or before this date. "
                                       + "A bare YYYY-MM-DD includes the whole day."],
                        "limit": ["type": "integer", "description": "Default 20, max 200."],
                        "offset": ["type": "integer", "description": "Default 0."],
                    ],
                ],
            ],
            [
                "name": "get_recording",
                "description": "Metadata, participants, speaker names, tags and the "
                    + "slugs of any notes for one recording. Does not include "
                    + "transcript text; use get_transcript.\n\n"
                    + "Also the provenance, which says how far to trust the "
                    + "transcript before you read it. `asr_model` is which model "
                    + "read it, and an older one can be wrong about the language "
                    + "rather than say so. `recorded_by` is `phone` for a recording "
                    + "whose voices were never separated or named. `app` is the "
                    + "call it was in, `room` marks a recording made in a room "
                    + "instead, and `transcribed_by` names the device that did the "
                    + "work. Each is absent when the library does not have it.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["recording_id": ["type": "string"]],
                    "required": ["recording_id"],
                ],
            ],
            [
                "name": "get_transcript",
                "description": "Speaker turns for one recording, paginated.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": ["type": "string"],
                        "offset": ["type": "integer", "description": "Default 0."],
                        "limit": ["type": "integer", "description": "Default 200, max 500."],
                    ],
                    "required": ["recording_id"],
                ],
            ],
            [
                "name": "search_transcripts",
                "description": "Full-text search across every transcript. Returns "
                    + "matching turns with their recording ids.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "person": ["type": "string",
                                   "description": "Only turns spoken by this person, "
                                       + "rather than every turn in a recording they "
                                       + "were in."],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Only turns from recordings carrying all "
                                + "of these tags. Paired with person, this is the "
                                + "whole of \"what do I keep saying across my job "
                                + "hunt calls\" in one call.",
                        ],
                        "limit": ["type": "integer", "description": "Default 20, max 200."],
                    ],
                    "required": ["query"],
                ],
            ],
            [
                "name": "list_people",
                "description": "Named people and saved contacts, including people without voiceprints. "
                    + "Returns their recording count and whether preprocessed person context is available. "
                    + "Use get_person_context for facts, summary, relationships and source quotes.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "get_person_context",
                "description": "Read a person's preprocessed summary, facts and relationships with exact "
                    + "source quotes, dates and citation markers. Start here for person questions. "
                    + "No LLM request or transcript download. Historical facts are marked; changed or "
                    + "deleted sources are excluded. Pending/failed counts describe incomplete coverage. "
                    + "Memory is generated and fallible; use original evidence for precise answers.",
                "inputSchema": ["type": "object", "properties": [
                    "person": ["type": "string"],
                    "question": ["type": "string", "description": "Optional question to prioritize relevant details."],
                    "token_budget": ["type": "integer", "description": "Estimated output tokens, default 1500, range 256 to 16000."],
                    "as_of": ["type": "string", "description": "Effective date YYYY-MM-DD, distinct from recording date. Unknown effective dates remain explicitly unknown."],
                    "limit": ["type": "integer", "description": "Candidate details, default 100. The token budget can return fewer."],
                    "offset": ["type": "integer", "description": "Candidate offset, default 0. When `omitted` is nonzero, prefer a focused question or a larger token_budget."],
                ],
                                "required": ["person"]],
            ],
            [
                "name": "get_project_context",
                "description": "Compact preprocessed project brief, related people, sourced facts and temporal status. No model request or transcript download. Resolve aliases with list_context_entities.",
                "inputSchema": ["type": "object", "properties": [
                    "project": ["type": "string"],
                    "question": ["type": "string"],
                    "token_budget": ["type": "integer"],
                    "as_of": ["type": "string"],
                ], "required": ["project"]],
            ],
            [
                "name": "list_context_entities",
                "description": "Stable person and project IDs and explicitly reviewed aliases for compact memory retrieval.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "search_context",
                "description": "Search people, projects, facts, relationships and source passages by meaning "
                    + "and keywords. Text embeddings are generated locally on this Mac. Returns compact "
                    + "ranked matches with evidence and citation markers, not whole transcripts. "
                    + "person means context ABOUT a person (including mentions), not only words they spoke. "
                    + "Unsupported query languages use keyword search. Ranking scores are not truth confidence.",
                "inputSchema": ["type": "object", "properties": [
                    "query": ["type": "string"], "person": ["type": "string"],
                    "kinds": ["type": "array", "items": ["type": "string", "enum": ["fact", "relationship", "passage"]]],
                    "tags": ["type": "array", "items": ["type": "string"]],
                    "after": ["type": "string"], "before": ["type": "string"],
                    "as_of": ["type": "string", "description": "Optional effective date YYYY-MM-DD. Searches memory valid on that day, including historical claims, without raw passages."],
                    "limit": ["type": "integer", "description": "Default 12, max 50."],
                ], "required": ["query"]],
            ],
            [
                "name": "list_tags",
                "description": "Every tag in the library, with how many "
                    + "recordings and how many notes carry it, most first. A tag "
                    + "is the user's own filing of a meeting or of a write-up, in "
                    + "their own words, so this is the vocabulary a question can "
                    + "be asked in and there is nothing else to derive it from. "
                    + "**Read this before filtering on tags**: the names are "
                    + "invented rather than drawn from a fixed list, and a tag "
                    + "nobody uses does not exist. Recordings and notes share one "
                    + "vocabulary, so a tag may have notes and no recordings.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "add_tags",
                "description": "Tag a recording or a note. Adds to what it already "
                    + "carries rather than replacing it. A tag already in the "
                    + "library is matched however it was capitalised, so reuse the "
                    + "exact names from list_tags rather than coining a "
                    + "near-duplicate: \"job hunt\" and \"job-hunt\" are two tags "
                    + "and neither has everything. Returns everything that "
                    + "recording or note carries afterwards.\n\n"
                    + "**Tagging a recording does not tag the notes about it.** A "
                    + "note carries only what is put on it, so filing a subject "
                    + "means tagging both. This is the one write that may touch "
                    + "the user's own note: a tag is filing rather than wording, "
                    + "and it is one click to remove in the window.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": [
                            "type": "string",
                            "description": "The recording to tag. Give this or "
                                + "`note`, never both.",
                        ],
                        "note": [
                            "type": "string",
                            "description": "The slug or title of the note to tag. "
                                + "Give this or `recording_id`, never both.",
                        ],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Free text, up to 40 characters each, no "
                                + "commas. A space is fine: \"job hunt\" is one tag.",
                        ],
                    ],
                    "required": ["tags"],
                ],
            ],
            [
                "name": "remove_tags",
                "description": "Take tags off a recording or a note. Tags not on "
                    + "it are ignored rather than refused. Nothing else about it "
                    + "changes, and a tag that ends up on nothing simply stops "
                    + "existing: there is no separate list to tidy. Returns what "
                    + "it carries afterwards.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": [
                            "type": "string",
                            "description": "Give this or `note`, never both.",
                        ],
                        "note": [
                            "type": "string",
                            "description": "Slug or title. Give this or "
                                + "`recording_id`, never both.",
                        ],
                        "tags": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["tags"],
                ],
            ],
            [
                "name": "list_dictionary",
                // A term is matched by sound; a correction is a literal swap.
                // Read before adding, so a rule that exists is not added twice,
                // and read when a name in a transcript looks mangled, because
                // the spelling the user actually uses is often already here.
                "description": "The user's own vocabulary: terms Listen should "
                    + "spell right, and mishearings it replaces. Read it before "
                    + "adding one, and when a name in a transcript looks wrong.\n\n"
                    + "Returns kind and text each, plus replacement and "
                    + "case_sensitive on a correction, and `enabled: false` where "
                    + "the user switched one off.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "add_dictionary_entry",
                // A term is a guess by sound and has two silent failure modes,
                // both reported in `warnings` rather than refused: under five
                // letters (eight across a phrase) it is never matched, and one
                // that sounds like an ordinary English word never fires. A
                // correction whose halves differ only in capitals is forced
                // case-sensitive, or it matches its own replacement for ever.
                "description": "Teach Listen a word. With `replacement` it is a "
                    + "correction, an exact swap: \"C point\" -> \"Seapoint\". "
                    + "Without one it is a term, matched by sound.\n\n"
                    + "**Prefer a correction when the user gives both halves** "
                    + "(\"it says X, it should be Y\"). A term fires on nothing if "
                    + "it is too short or sounds like an English word; either comes "
                    + "back in `warnings`, meaning it was saved and will do "
                    + "nothing.\n\n"
                    + "Applies to what is transcribed from now on, and to "
                    + "dictation. Not to transcripts that already exist: that is "
                    + "preview_dictionary_backfill.\n\n"
                    + "Returns the entry as saved, which may differ from the one "
                    + "asked for.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "The term, or the misheard text a "
                                + "correction looks for. Spaces are fine: \"C "
                                + "point\" is one entry.",
                        ],
                        "replacement": [
                            "type": "string",
                            "description": "What the misheard text should say. "
                                + "Omit for a term.",
                        ],
                        "case_sensitive": [
                            "type": "boolean",
                            "description": "Corrections only. Default false, which "
                                + "means the text is matched however it was "
                                + "capitalised.",
                        ],
                    ],
                    "required": ["text"],
                ],
            ],
            [
                "name": "remove_dictionary_entry",
                "description": "Take an entry out of the dictionary, matched on "
                    + "text however capitalised. Undoes a rule the user did not "
                    + "want. **It does not undo a backfill**: sentences already "
                    + "rewritten stay rewritten. Returns what was removed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "The entry's text, as list_dictionary "
                                + "returned it.",
                        ],
                    ],
                    "required": ["text"],
                ],
            ],
            [
                "name": "preview_dictionary_backfill",
                // The whole dictionary is previewed, not only a rule just added,
                // so the count can include rules the user never backfilled.
                "description": "What the dictionary would change in transcripts "
                    + "that already exist. Writes nothing. Without a recording_id "
                    + "it reads every transcript in the library, the most expensive "
                    + "call here, so scope it to one meeting where you can.\n\n"
                    + "Returns `sentences` and `recordings` totals and, per "
                    + "recording, `changes`: an excerpt either side of each edit. "
                    + "Recordings with nothing to change are not listed, so an "
                    + "empty result means the rule matches nothing that was said. "
                    + "Check get_transcript rather than guessing a second rule.\n\n"
                    + "**Show the user these lines before applying anything.**",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": [
                            "type": "string",
                            "description": "Optional. One recording, rather than "
                                + "the whole library.",
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "How many changed sentences to quote per "
                                + "recording. Default 5, max 50. The totals count "
                                + "them all either way.",
                        ],
                    ],
                ],
            ],
            [
                "name": "apply_dictionary_backfill",
                // Notes, chats and saved answers are never touched: those are the
                // user's own writing. A refusal on `sentences` means something was
                // transcribed or edited between the preview and this call, so the
                // lines the user read are no longer what would be written.
                "description": "Rewrite the sentences preview_dictionary_backfill "
                    + "just listed. **This cannot be undone**: it takes no backup, "
                    + "so the audio becomes the only copy of what the model first "
                    + "wrote.\n\n"
                    + "Only when the user asked for the transcripts they already "
                    + "have to change, and only after they have seen the preview. "
                    + "Adding a rule is not that request: \"fix the transcription\" "
                    + "asks for both, \"remember it is called Seapoint\" asks only "
                    + "for the rule.\n\n"
                    + "`sentences` must be the preview's total over the same scope, "
                    + "or this is refused. Returns what was rewritten.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": [
                            "type": "string",
                            "description": "Optional, and it must match the scope "
                                + "the preview was taken at.",
                        ],
                        "sentences": [
                            "type": "integer",
                            "description": "The `sentences` total from "
                                + "preview_dictionary_backfill.",
                        ],
                    ],
                    "required": ["sentences"],
                ],
            ],
            [
                "name": "suggest_context_correction",
                // The wording only, and that is the shape rather than a rule:
                // the one field carried is the replacement text, which is what
                // `context correct <claim-id> <text>` takes. Identity, predicate
                // and evidence stay Listen's, per `person-context.md`.
                "description": "Say that a claim in person or project memory "
                    + "misreads its own evidence. **This proposes and does not "
                    + "apply**: the user accepts or dismisses it, because a claim "
                    + "is quoted with the user's authority behind it. It waits on "
                    + "that person's page in Listen, so say that you have left one "
                    + "there.\n\n"
                    + "Only the wording. You cannot move a claim to somebody else, "
                    + "change what kind of claim it is, or touch its evidence.\n\n"
                    + "Propose one when you have read the source and the claim "
                    + "disagrees with it, not when it merely looks incomplete: "
                    + "memory being behind is get_context_status's answer, not a "
                    + "correction. A claim the user has already dismissed is not "
                    + "queued again, and the call says so.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "claim_id": ["type": "string",
                                     "description": "The `id` of an entry from "
                                         + "get_person_context, get_project_context "
                                         + "or search_context."],
                        "text": ["type": "string",
                                 "description": "What the claim should say, as one "
                                     + "sentence in the same voice as the rest."],
                        "why": ["type": "string",
                                "description": "What you read that says so. This is "
                                    + "what the user decides on, so quote or cite "
                                    + "the source rather than asserting."],
                    ],
                    "required": ["claim_id", "text", "why"],
                ],
            ],
            [
                "name": "set_recording_title",
                // `TitleSource.model` has existed since the ladder was written,
                // documented as "not yet written by anything". This is what
                // writes it, so the ordering in `Recording.mayTitle` settles the
                // question rather than a new rule here.
                "description": "Name a recording after what was said in it. Use it "
                    + "on one called \"Untitled\", or when the user asks for a "
                    + "better name.\n\n"
                    + "**A name the user typed is never overwritten**, and neither "
                    + "is the meeting's own name from the calendar: this ranks "
                    + "below both, and a call that cannot write says so and "
                    + "changes nothing. `clear` puts it back to whatever it was "
                    + "called before anybody named it, which is not always "
                    + "\"Untitled\".",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": ["type": "string"],
                        "title": ["type": "string",
                                  "description": "A few words. Omit with `clear`."],
                        "clear": ["type": "boolean",
                                  "description": "Take the name off instead of "
                                      + "setting one."],
                    ],
                    "required": ["recording_id"],
                ],
            ],
            [
                "name": "list_conversations",
                "description": "Questions the user has put to their own agent, most "
                    + "recently touched first, without the answers. A conversation "
                    + "may name the recordings or the person it was about, and one "
                    + "asked before a meeting names the invitation.\n\n"
                    + "Use it when the user refers to something they asked before. "
                    + "**A conversation is not a note**: nothing here was filed on "
                    + "purpose, and only what somebody pressed Save as note on is "
                    + "in list_notes. Read-only, both of these.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": ["type": "string",
                                         "description": "Optional. Only conversations "
                                             + "about this recording."],
                        "person": ["type": "string",
                                   "description": "Optional. Only conversations asked "
                                       + "about this person."],
                        "limit": ["type": "integer", "description": "Default 20, max 100."],
                    ],
                ],
            ],
            [
                "name": "read_conversation",
                // Text turns only. A `Step` of kind `activity` is the shimmer
                // line under a running answer, which is progress rather than
                // content, and the same rule the window follows when it replays
                // a conversation.
                "description": "One conversation in full: what was asked and what "
                    + "was answered, oldest turn first. `who` is `you` for the user "
                    + "and `agent` for the answer. A turn that failed carries "
                    + "`failure` and no text.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "conversation_id": ["type": "string",
                                            "description": "The id from list_conversations."],
                        "offset": ["type": "integer", "description": "Default 0."],
                        "limit": ["type": "integer", "description": "Default 50, max 200."],
                    ],
                    "required": ["conversation_id"],
                ],
            ],
            [
                "name": "get_context_status",
                // `waitingForNames` is the only number here that names something
                // the user can go and do, which is why it is worth a tool rather
                // than being left to the per-entity `pending` on a packet.
                "description": "How much of the library Listen's person and project "
                    + "memory has actually read. Covers the whole library, where "
                    + "get_person_context reports only one entity's share.\n\n"
                    + "`pending` is sources not yet processed, so a person with no "
                    + "facts and a high pending is unread rather than unknown. "
                    + "`waitingForNames` is the one number that names a "
                    + "fix: those recordings cannot be extracted until somebody "
                    + "names who is speaking. Say so rather than reporting an "
                    + "absence of facts as an absence of the thing.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "list_upcoming",
                // **`authorized` is not a courtesy field.** `MeetingCalendar`
                // answers an unauthorized Mac with an empty list, which reads
                // exactly like a clear afternoon, so a tool returning only the
                // array would have the agent tell somebody their day is free
                // when it is actually blind. See `calendar.md`.
                "description": "Meetings coming up on this Mac's calendars, "
                    + "soonest first. Twelve hours ahead and fifteen minutes back, "
                    + "so one that has just started is still listed.\n\n"
                    + "**Check `authorized` before reporting an empty list.** "
                    + "False means Listen cannot see the calendar at all, which is "
                    + "not the same answer as nothing being scheduled.\n\n"
                    + "Each event has a `kind`: `call` has guests and a link, "
                    + "`inPerson` has guests and nowhere to click, `blocked` is an "
                    + "hour held with nobody else invited. A `recording_id` means "
                    + "Listen already has a recording of it. Nothing here has a "
                    + "transcript until it has happened.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Default 10, max 50."],
                        "include_blocked": [
                            "type": "boolean",
                            "description": "Default false, which lists calls and "
                                + "in-person meetings only. True adds time blocked "
                                + "out with nobody else invited.",
                        ],
                    ],
                ],
            ],
            [
                "name": "get_event",
                // `invitation` is what the Prepare button already puts in front
                // of a model, so this returns that string rather than a second
                // description of a meeting that could disagree with it.
                "description": "One upcoming meeting, by the id list_upcoming gave "
                    + "you: its title, when it runs, who is invited, whether there "
                    + "is a link, and the agenda with the dial-in boilerplate "
                    + "stripped. `invitation` is the whole thing as one sentence, "
                    + "which is what to build on when the user asks to be prepared "
                    + "for it.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["event_id": ["type": "string"]],
                    "required": ["event_id"],
                ],
            ],
            [
                "name": "list_notes",
                "description": "Notes, without their text. With a recording_id, the "
                    + "notes that name that recording among their sources; without "
                    + "one, every note in the library, newest first. A note with "
                    + "source `you` is what the user typed themselves: read it "
                    + "first, and never write it.\n\n"
                    + "With a `query` this searches note bodies, which nothing else "
                    + "here does: search_transcripts reads what was said, this reads "
                    + "what has been written up. A match comes back with an "
                    + "`excerpt`, a `matches` count, and whether the hit was in the "
                    + "title, the body or both.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": ["type": "string",
                                         "description": "Optional. Omit for the "
                                             + "whole library."],
                        "query": ["type": "string",
                                  "description": "Only notes whose body or title "
                                      + "contains this, ignoring case and accents."],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Only notes carrying **all** of these "
                                + "tags, combined with recording_id by AND. A note "
                                + "carries only what was put on it: it does not "
                                + "inherit a tag from a meeting it is about, so "
                                + "this and list_recordings with the same tag "
                                + "answer two different questions.",
                        ],
                    ],
                ],
            ],
            [
                "name": "read_note",
                "description": "One note in full. Returns `body`, which is what "
                    + "edit_note wants back as `was`, and `recordings`, which is "
                    + "every meeting it is about.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "note": ["type": "string",
                                 "description": "The slug from list_notes, or the title."],
                        "recording_id": ["type": "string",
                                         "description": "Optional. Narrows a title "
                                             + "that several notes share, such as "
                                             + "\"Outline\"."],
                    ],
                    "required": ["note"],
                ],
            ],
            [
                "name": "write_note",
                "description": "Add a note. Markdown body, free-text title, and "
                    + "the recordings it is about. **A note can name several "
                    + "meetings**: a synthesis across four catch-ups names all "
                    + "four. Never overwrites: a title already in use is numbered, "
                    + "and edit_note changes one that exists. The user's own note "
                    + "is readable and not writable from here; add one beside it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recordings": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Recording ids this note is about, at "
                                + "least one. State every meeting you actually drew "
                                + "on; nothing here infers them.",
                        ],
                        "title": ["type": "string",
                                  "description": "What this note is, in a few words. "
                                      + "It becomes the filename."],
                        "body": ["type": "string", "description": "Markdown."],
                        "prompt": ["type": "string",
                                   "description": "What you were asked, kept beside "
                                       + "the note. Strongly recommended."],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional. What to file this note under, "
                                + "from list_tags where one already fits.",
                        ],
                    ],
                    "required": ["recordings", "title", "body"],
                ],
            ],
            [
                "name": "edit_note",
                "description": "Rewrite a note. `was` must be the body exactly as "
                    + "read_note returned it, or the write is refused: the window and "
                    + "another agent can be holding the same note, and this is what "
                    + "stops one of them silently overwriting the other.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "note": ["type": "string", "description": "Slug or title."],
                        "body": ["type": "string", "description": "The new markdown."],
                        "was": ["type": "string",
                                "description": "The body as you last read it."],
                        "title": ["type": "string",
                                  "description": "Optional. Renames it; the slug and "
                                      + "every link to it stay as they are."],
                        "recordings": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional, and replaces the list rather "
                                + "than adding to it. Omit unless the sources really "
                                + "changed: adding a paragraph is not a claim about "
                                + "which meetings a note is about.",
                        ],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional, and replaces the list rather "
                                + "than adding to it, the way `recordings` does. "
                                + "Omit to leave the filing alone; use add_tags to "
                                + "add one without restating the rest.",
                        ],
                        "prompt": ["type": "string", "description": "Optional."],
                    ],
                    "required": ["note", "body", "was"],
                ],
            ],
            [
                "name": "delete_note",
                "description": "Remove a note. This and remove_tags are the only "
                    + "destructive tools here, and between them they reach notes and "
                    + "tags only: transcripts, speakers, titles and recordings cannot "
                    + "be changed through this server.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "note": ["type": "string", "description": "Slug or title."],
                    ],
                    "required": ["note"],
                ],
            ],
        ]
    }

    /// The subset of `tools` one caller may see, or all of them for nil.
    ///
    /// nil is not the same as an empty set, and the difference is the whole
    /// point: nil is "nobody restricted this", which is a hand-configured
    /// client, and an empty set is a caller that may call nothing.
    static func tools(allowing allowed: Set<String>?) -> [[String: Any]] {
        guard let allowed else { return tools }
        return tools.filter { ($0["name"] as? String).map(allowed.contains) == true }
    }

    /// The same tools, in the shape OpenAI's function calling wants them.
    ///
    /// A mechanical translation, and that is the whole reason this feature is
    /// small: `inputSchema` is already JSON Schema, so there is nothing to
    /// convert and no second description of any tool to keep in step with this
    /// one. A tool documented here is documented everywhere.
    ///
    /// The caller passes which names it will allow rather than a `allowWrites`
    /// flag, because the allowlist is the agent's decision and lives on
    /// `AgentRun.tools(allowWrites:)`. This file knows what the tools *are*;
    /// it has never known who is permitted to call them.
    ///
    /// **Advertising a shorter list is not enforcing it**, which is what this
    /// function was doing alone until `call` learned to refuse: a model that
    /// named a tool it had never been offered was handed it. See `call`.
    static func toolSchemas(_ allowed: Set<String>) -> [[String: Any]] {
        tools.compactMap { tool in
            guard let name = tool["name"] as? String, allowed.contains(name) else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": name,
                    "description": tool["description"] ?? "",
                    "parameters": tool["inputSchema"]
                        ?? ["type": "object", "properties": [:] as [String: Any]],
                ] as [String: Any],
            ]
        }
    }

    /// Which way the library is being read, for the activity log. `serve()`
    /// stamps it `stdio` at startup; everything in-process stays `in-app`.
    /// One static rather than a parameter, because `call` has many callers
    /// and exactly two transports.
    ///
    /// **`allowing:` looks like this and is not**, so do not follow this one.
    /// A transport is a property of the process. An allowlist is a property of
    /// the caller, and the window can have two conversations running at once
    /// with different answers to whether writes are on, so a static would hand
    /// the second one the first one's permissions.
    static var transport = "in-app"

    /// Run one tool and return what it would have sent back over the wire.
    ///
    /// The single choke point for every tool invocation: the stdio server,
    /// the in-app agent, and the CLI harnesses (which reach the library only
    /// through a spawned `listen mcp`) all land here, which is what lets one
    /// line make the whole surface auditable. The log carries the tool name
    /// and recording ids, never arguments: a query names what a meeting was
    /// about, and the log must stay safe to read aloud.
    ///
    /// `allowed` nil means unrestricted, which is what the CLI's own commands
    /// and a hand-configured MCP client get. Being the one choke point is what
    /// makes this the right place for the check: `AgentRun.tools` decides, and
    /// every route into the library asks the same function whether the caller
    /// may.
    static func call(_ name: String, _ args: [String: Any],
                     allowing allowed: Set<String>? = nil) throws -> String {
        do {
            // Inside the `do`, so a refusal is logged the way every other
            // failure is. A refused call that leaves no trace is the one an
            // audit most wants to find.
            if let allowed, !allowed.contains(name) {
                throw MCPError.notAllowed(name)
            }
            let out = try perform(name, args)
            ActivityLog.append("mcp_call", [
                "tool": name, "transport": transport,
                "recordings": ActivityLog.recordingIDs(in: args), "ok": true,
            ])
            return out
        } catch {
            ActivityLog.append("mcp_call", [
                "tool": name, "transport": transport,
                "recordings": ActivityLog.recordingIDs(in: args), "ok": false,
            ])
            throw error
        }
    }

    /// Synchronous, and it reads the library off disk: `Recording.all()` walks
    /// every folder and `search_transcripts` reads every transcript. Over stdio
    /// that cost lands in a second process and nobody notices. In-process it is
    /// the caller's job to be off the main thread, which `AgentChat` is.
    private static func perform(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "list_context_entities":
            // The cards as well as the entities, so a row says whether there is
            // anything behind the name. Without this, finding out who Listen
            // knows something about costs one `get_person_context` per entity,
            // and the answer for most of them is "nothing yet".
            // Loaded once and passed down, because the fallback below reads it
            // per entity and this file is on the caller's thread.
            let document = try PeopleMemory.load()
            let cards = Dictionary(
                (try? ContextRetrieval.cards())?.map { ($0.id, $0) } ?? [],
                uniquingKeysWith: { first, _ in first })
            return json(["entities": try ContextRetrieval.listedEntities().map { entity -> [String: Any] in
                var row: [String: Any] = ["id": entity.id, "kind": entity.kind,
                                          "name": entity.name, "aliases": entity.aliases]
                guard let card = cards[entity.id] else {
                    // No card at all, which is not the same as nothing to know:
                    // `cards()` builds one only for a label that appears in a
                    // valid receipt, so somebody with a full queue and nothing
                    // extracted yet is missing from it entirely. Reporting
                    // `claims: 0` and no `pending` would read as "nothing known
                    // and nothing coming", and the measured case is Edgar: no
                    // card, and 53 sources waiting.
                    row["claims"] = 0
                    if entity.kind == "person",
                       let memory = try? PeopleMemory.person(entity.name, document: document) {
                        row["pending"] = memory.pending
                        row["failed"] = memory.failed
                    }
                    return row
                }
                row["claims"] = card.entries.count
                row["pending"] = card.pending
                row["failed"] = card.failed
                if let updated = card.updated { row["updated"] = updated }
                return row
            }])
        case "get_project_context":
            guard let project = args["project"] as? String else { throw MCPError.badArguments("get_project_context needs a project") }
            return try ContextCLI.json(ContextRetrieval.packet(project, kind: "project",
                question: args["question"] as? String ?? "", tokenBudget: args["token_budget"] as? Int ?? 1500,
                asOf: args["as_of"] as? String))
        case "get_person_context":
            guard let person = args["person"] as? String, !person.isEmpty else {
                throw MCPError.badArguments("get_person_context needs a person")
            }
            let offset = max(0, args["offset"] as? Int ?? 0)
            return try ContextCLI.json(ContextRetrieval.packet(person, kind: "person",
                question: args["question"] as? String ?? "", tokenBudget: args["token_budget"] as? Int ?? 1500,
                asOf: args["as_of"] as? String, offset: offset, limit: clamp(args["limit"], default: 100, min: 1, max: 100)))

        case "search_context":
            guard let query = args["query"] as? String else {
                throw MCPError.badArguments("search_context needs a query")
            }
            let kinds = try strings(args["kinds"], field: "kinds")
            guard Set(kinds).isSubset(of: ["fact", "relationship", "passage"]) else {
                throw MCPError.badArguments("kinds must be fact, relationship or passage")
            }
            let person = args["person"] as? String
            return try ContextCLI.json(SemanticIndex.search(query, person: person,
                limit: clamp(args["limit"], default: 12, min: 1, max: 50), kinds: kinds,
                tags: strings(args["tags"], field: "tags"),
                after: dayBound(args["after"], endOfDay: false, field: "after"),
                before: dayBound(args["before"], endOfDay: true, field: "before"), asOf: args["as_of"] as? String))

        case "list_recordings":
            let limit = clamp(args["limit"], default: 20, min: 1, max: 200)
            let offset = max(0, args["offset"] as? Int ?? 0)
            // The cheap-before-expensive ordering lives in `RecordingFilter`,
            // which the sidebar and `listen list` go through too.
            var filter = RecordingFilter()
            filter.query = args["query"] as? String ?? ""
            // Still one name over MCP. The filter takes a list because the
            // window's lenses stack, and an agent that wants two people can
            // already say so by intersecting two calls.
            filter.people = [args["person"] as? String].compactMap { $0 }
            filter.tags = try strings(args["tags"], field: "tags")
            filter.after = try dayBound(args["after"], endOfDay: false, field: "after")
            filter.before = try dayBound(args["before"], endOfDay: true, field: "before")

            let all = filter.apply(to: Recording.all())
            let page = Array(all.dropFirst(offset).prefix(limit))
            return json([
                "recordings": page.map(brief),
                "pagination": pagination(total: all.count, offset: offset,
                                         returned: page.count),
            ])

        case "get_recording":
            let recording = try find(args)
            var out = brief(recording)
            out["speakers"] = recording.speakers
            out["has_transcript"] = recording.hasTranscript
            out["turns"] = recording.storedTurns.count
            // The slugs of every note that names this recording, including one
            // written about four meetings at once. This is the step of the
            // ladder where an agent decides what to read, and "the user has
            // written a note on this one" is the cheapest thing it can be told
            // before it asks for 5,000 tokens of transcript.
            out["notes"] = Notes.list(about: recording).filter { !$0.excludedFromAI }.map(\.slug)

            // Provenance, and it is here rather than in `brief` on purpose: a
            // fifty row listing does not need it, and this is the step where an
            // agent decides whether to believe what it is about to read.
            //
            // Each one answers a question the transcript itself cannot. Which
            // model read it says whether the language could be wrong, because a
            // v2 Parakeet transcript cannot be asked what language it is in and
            // the wrong one leaves a thin transcript rather than an error. Where
            // it came from says whether the speakers were ever separated: a
            // phone recording splits the voices and never names them. The app
            // is the evidence behind "Call with", and a room recording is not a
            // call at all.
            //
            // Absent rather than null when the library does not have it, which
            // is most of `Metadata`'s own rule: these fields decode from four
            // years of files and a missing key is normal.
            let meta = recording.metadata
            if let model = meta.asr_model { out["asr_model"] = model }
            // Non-optional here, unlike the rest: the Mac's own `Metadata`
            // always has it, and `ListenKit`'s is the lenient one.
            out["recorded_by"] = meta.source
            if let app = meta.app_name { out["app"] = app }
            if meta.room == true { out["room"] = true }
            if let event = meta.calendar_event_id { out["calendar_event_id"] = event }
            if let device = meta.transcribed_by { out["transcribed_by"] = device }
            return json(out)

        case "suggest_context_correction":
            let claim = try nonEmpty(args["claim_id"], "claim_id",
                                     for: "suggest_context_correction")
            let text = try nonEmpty(args["text"], "text",
                                    for: "suggest_context_correction")
            let why = try nonEmpty(args["why"], "why",
                                   for: "suggest_context_correction")
            // Resolved against the store rather than taken on trust, so a
            // hallucinated id is refused here instead of sitting in the worklist
            // until somebody tries to accept it and finds nothing behind it.
            guard let found = try ContextRetrieval.cards().lazy
                .compactMap({ card in
                    card.entries.first { $0.id == claim }.map { (card, $0) }
                }).first else {
                throw MCPError.notFound(
                    "no claim \(claim). The id comes from an `entries` row of "
                    + "get_person_context, get_project_context or search_context.")
            }
            guard found.1.text != text else {
                throw MCPError.badArguments(
                    "the claim already says that, so there is nothing to correct.")
            }
            let queued = ContextSuggestions.propose(.init(
                claim: claim, entity: found.0.id, entityName: found.0.name,
                was: found.1.text, text: text, why: why, at: Date()))
            guard queued else {
                throw MCPError.badArguments(
                    "the user has already dismissed a correction to this claim, so "
                    + "it is not offered again. Say what you found in your answer "
                    + "instead.")
            }
            return json([
                "claim_id": claim,
                "about": found.0.name,
                "was": found.1.text,
                "proposed": text,
                // True as of the person page carrying the row. Before that it
                // was a queue with no surface, and this string was the only
                // thing claiming otherwise.
                "status": "waiting on \(found.0.name)'s page in Listen, where the "
                    + "user can accept or dismiss it beside the evidence. Nothing "
                    + "has changed in memory. Tell them it is there.",
            ])

        case "set_recording_title":
            var recording = try find(args)
            let clearing = args["clear"] as? Bool ?? false
            // Refused before anything is read, because "set it to nothing" and
            // "clear it" are the same intent said two ways and only one of them
            // is spelled here.
            guard clearing || (args["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw MCPError.badArguments(
                    "set_recording_title needs `title`, or `clear: true`.")
            }
            // **Not `Recording.rename`.** That one clears `title_source`, which
            // is what marks a title as one a person typed and freezes it against
            // every automatic writer for ever. A name from here is derived, so
            // it takes the `model` rank and stays as replaceable as it should be.
            guard recording.mayTitle(from: .model) else {
                let whose = recording.metadata.titleSourceValue
                throw MCPError.badArguments(
                    "`\(recording.metadata.title)` was "
                    + (whose.map { "\($0.phrase)" } ?? "named by the user")
                    + ", and this does not write over that. Nothing changed.")
            }
            if clearing {
                // Back to the floor rather than to the placeholder, which is
                // `AutoTitle`'s rule: a phone memo lands on the phone's own
                // string, and the recording is left exactly as titleable as it
                // was before anybody named it.
                let floor = DeviceTitle.floor(for: recording)
                recording.metadata.title = floor
                recording.metadata.title_source =
                    floor == Metadata.untitled ? nil : Metadata.TitleSource.device.rawValue
            } else {
                recording.metadata.title =
                    (args["title"] as! String).trimmingCharacters(in: .whitespacesAndNewlines)
                recording.metadata.title_source = Metadata.TitleSource.model.rawValue
            }
            try recording.save()
            return json(["recording_id": recording.id,
                         "title": recording.metadata.title,
                         "title_source": recording.metadata.title_source ?? "none"])

        case "list_conversations":
            let limit = clamp(args["limit"], default: 20, min: 1, max: 100)
            let about = (args["recording_id"] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let who = (args["person"] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let chats = Chat.all()
                .filter { about.isEmpty || $0.sources.contains(about) }
                .filter { who.isEmpty || ($0.person.map { SpeakerName.matches($0, who) } ?? false) }
                .prefix(limit)
            return json(["conversations": chats.map { chat -> [String: Any] in
                var row: [String: Any] = [
                    "conversation_id": chat.id ?? "",
                    "title": chat.title ?? "",
                    "turns": chat.turns.count,
                ]
                if let created = chat.created { row["created"] = created }
                if let updated = chat.updated { row["updated"] = updated }
                if let backend = chat.backend { row["backend"] = backend }
                if !chat.sources.isEmpty { row["recordings"] = chat.sources }
                if let person = chat.person { row["person"] = person }
                // The invitation it was asked ahead of, which is the one case
                // where a conversation is about a meeting that had not happened.
                if let event = chat.event { row["event_id"] = event }
                if let title = chat.event_title { row["event_title"] = title }
                return row
            }])

        case "read_conversation":
            let id = try nonEmpty(args["conversation_id"], "conversation_id",
                                  for: "read_conversation")
            guard let chat = Chat.load(id: id) else {
                throw MCPError.notFound("no conversation \(id)")
            }
            let offset = max(0, args["offset"] as? Int ?? 0)
            let limit = clamp(args["limit"], default: 50, min: 1, max: 200)
            let page = Array(chat.turns.dropFirst(offset).prefix(limit))
            return json([
                "conversation_id": chat.id ?? id,
                "title": chat.title ?? "",
                "turns": page.map { turn -> [String: Any] in
                    var row: [String: Any] = ["who": turn.who, "at": turn.at]
                    if let failure = turn.failure { row["failure"] = failure }
                    // The text a turn settled on. `steps` also holds the
                    // activity line, which is progress rather than content, so
                    // it is dropped here the way the window drops it on replay.
                    if !turn.text.isEmpty { row["text"] = turn.text }
                    return row
                },
                "pagination": pagination(total: chat.turns.count, offset: offset,
                                         returned: page.count),
            ])

        case "get_context_status":
            return try ContextCLI.json(ContextCLI.coverage())

        case "list_upcoming":
            let limit = clamp(args["limit"], default: 10, min: 1, max: 50)
            let kinds = (args["include_blocked"] as? Bool ?? false)
                ? MeetingKind.everything : MeetingKind.meetings
            let events = MeetingCalendar.upcoming(limit: limit, including: kinds)
            // Built once for the whole list rather than per event: `Recording.all`
            // walks every folder, and a ten row answer would otherwise walk it
            // ten times.
            let recorded = Dictionary(
                Recording.all().compactMap { recording -> (String, String)? in
                    guard let event = recording.metadata.calendar_event_id else { return nil }
                    return (event, recording.id)
                }, uniquingKeysWith: { first, _ in first })
            return json([
                "authorized": MeetingCalendar.isAuthorized,
                "horizon_hours": Int(MeetingCalendar.horizon / 3600),
                "lateness_minutes": Int(MeetingCalendar.lateness / 60),
                "events": events.map { row(for: $0, recorded: recorded) },
            ])

        case "get_event":
            let id = try nonEmpty(args["event_id"], "event_id", for: "get_event")
            // Found through the same window `list_upcoming` reads, so the two
            // cannot disagree about which meetings exist. An id that has fallen
            // out of the horizon is not found rather than silently empty.
            guard let found = MeetingCalendar
                .upcoming(limit: 200, including: MeetingKind.everything)
                .first(where: { $0.id == id }) else {
                throw MCPError.notFound(
                    MeetingCalendar.isAuthorized
                    ? "no upcoming meeting \(id). list_upcoming has the ids, and "
                      + "only reaches twelve hours ahead."
                    : "Listen cannot see this Mac's calendar, so no meeting can be "
                      + "looked up. This is a permission, not an empty calendar.")
            }
            var out = row(for: found, recorded: [:])
            out["invitation"] = MeetingBrief.invitation(found)
            return json(out)

        case "list_tags":
            // Both counts on every row, always, including the zeroes. A key
            // that appears only sometimes reads as a tag of a different kind,
            // and there is only one kind.
            let visibleNotes = Notes.all().filter { !$0.excludedFromAI }
            return json(["tags": Tags.all().compactMap { tag -> [String: Any]? in
                let count = visibleNotes.filter { $0.tags.contains(tag.name) }.count
                guard tag.count > 0 || count > 0 else { return nil }
                return ["name": tag.name, "recordings": tag.count, "notes": count]
            }])

        case "add_tags":
            let tags = try wanted(args["tags"], for: "add_tags")
            switch try subject(args, for: "add_tags") {
            case .recording(let recording):
                return json(["recording_id": recording.id,
                             "tags": try Tags.add(tags, to: recording)])
            case .note(let note):
                return json(["note": note.slug,
                             "tags": try Tags.add(tags, to: note)])
            }

        case "remove_tags":
            let tags = try wanted(args["tags"], for: "remove_tags")
            switch try subject(args, for: "remove_tags") {
            case .recording(let recording):
                return json(["recording_id": recording.id,
                             "tags": try Tags.remove(tags, from: recording)])
            case .note(let note):
                return json(["note": note.slug,
                             "tags": try Tags.remove(tags, from: note)])
            }

        case "list_dictionary":
            return json(["entries": CustomDictionary.load().map { entry -> [String: Any] in
                var out: [String: Any] = ["kind": entry.kind.rawValue,
                                          "text": entry.text]
                if entry.kind == .correction {
                    out["replacement"] = entry.replacement
                    out["case_sensitive"] = entry.caseSensitive
                }
                // Only when it is off. The list is mostly enabled entries and a
                // true on every row is tokens spent saying nothing.
                if !entry.enabled { out["enabled"] = false }
                return out
            }])

        case "add_dictionary_entry":
            let text = try nonEmpty(args["text"], "text", for: "add_dictionary_entry")
            let replacement = ((args["replacement"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: CustomDictionary.Kind = replacement.isEmpty ? .term : .correction

            // The two halves differing only in capitals is the one case where an
            // insensitive correction matches its own replacement for ever, so it
            // is forced rather than warned about. `DictionarySuggestions.entry`
            // makes the same choice from `caseOnly`, and the two must agree:
            // accepting a suggestion and asking for it here are the same request.
            let caseOnly = kind == .correction
                && text != replacement
                && text.caseInsensitiveCompare(replacement) == .orderedSame
            let caseSensitive = caseOnly || (args["case_sensitive"] as? Bool ?? false)

            guard !(kind == .correction && text == replacement) else {
                throw MCPError.badArguments(
                    "`text` and `replacement` are the same, so the rule would do "
                    + "nothing. Give the misheard text as `text` and the right "
                    + "words as `replacement`.")
            }

            var entries = CustomDictionary.load()
            let entry = CustomDictionary.Entry(kind: kind, text: text,
                                               replacement: replacement,
                                               caseSensitive: caseSensitive)
            let merged = CustomDictionary.merge([entry], into: entries)
            guard !merged.added.isEmpty else {
                throw MCPError.badArguments(
                    "`\(text)` is already in the dictionary as a \(kind.rawValue). "
                    + "list_dictionary shows what is there.")
            }
            entries.append(contentsOf: merged.added)
            CustomDictionary.save(entries)

            // Saved first, then told what it will not do. Both of these leave a
            // rule that fires on nothing, and the CLI reports them the same way
            // round: refusing would lose a rule the user asked for over a rule
            // this file cannot be sure is useless.
            var warnings: [String] = []
            if kind == .term, !CustomDictionary.eligible(text) {
                warnings.append(
                    "a term needs five letters, or eight across a phrase, to be "
                    + "matched by sound, so this one will not fire. Add it as a "
                    + "correction instead if you know what comes out wrong.")
            }
            if kind == .term, let word = CustomDictionary.englishSoundalike(for: text) {
                warnings.append(
                    "`\(text)` sounds like `\(word)`, an ordinary English word, so "
                    + "the sounds-like pass leaves it alone and this will not fire. "
                    + "A correction naming the exact mishearing does work.")
            }
            var out: [String: Any] = ["kind": kind.rawValue, "text": text,
                                      "warnings": warnings]
            if kind == .correction {
                out["replacement"] = replacement
                out["case_sensitive"] = caseSensitive
                if caseOnly {
                    out["forced_case_sensitive"] = true
                }
            }
            return json(out)

        case "remove_dictionary_entry":
            let text = try nonEmpty(args["text"], "text", for: "remove_dictionary_entry")
            let before = CustomDictionary.load()
            let gone = before.filter { $0.text.caseInsensitiveCompare(text) == .orderedSame }
            guard !gone.isEmpty else {
                throw MCPError.notFound(
                    "no dictionary entry matching `\(text)`. list_dictionary shows "
                    + "them all.")
            }
            CustomDictionary.save(before.filter {
                $0.text.caseInsensitiveCompare(text) != .orderedSame
            })
            return json(["removed": gone.map {
                ["kind": $0.kind.rawValue, "text": $0.text, "replacement": $0.replacement]
            }])

        case "preview_dictionary_backfill":
            let plans = try backfillPlans(args, for: "preview_dictionary_backfill")
            let quote = clamp(args["limit"], default: 5, min: 1, max: 50)
            return json([
                "sentences": plans.reduce(0) { $0 + $1.changes.count },
                "recordings": plans.count,
                "summary": DictionaryBackfill.summary(plans),
                "changes": plans.map { plan -> [String: Any] in
                    var row: [String: Any] = [
                        "recording_id": plan.recording.id,
                        "title": plan.recording.displayTitle,
                        "sentences": plan.changes.count,
                        "changes": plan.changes.prefix(quote)
                            .map { DictionaryBackfill.excerpt($0) },
                    ]
                    if plan.changes.count > quote { row["truncated"] = true }
                    return row
                },
            ])

        case "apply_dictionary_backfill":
            guard let expected = args["sentences"] as? Int else {
                throw MCPError.badArguments(
                    "apply_dictionary_backfill needs `sentences`: the total "
                    + "preview_dictionary_backfill returned. It is what says the "
                    + "user has seen what this would change.")
            }
            let plans = try backfillPlans(args, for: "apply_dictionary_backfill")
            let sentences = plans.reduce(0) { $0 + $1.changes.count }
            // Compare-and-swap on the whole pass, above the one TranscriptEditor
            // already does per recording. That one catches a transcript that
            // moved; this one catches an apply that never previewed, which is
            // the failure this tool is actually guarding against.
            guard sentences == expected else {
                throw MCPError.badArguments(
                    "`sentences` was \(expected) and this pass would change "
                    + "\(sentences). Nothing was written. Run "
                    + "preview_dictionary_backfill again over the same scope, show "
                    + "the user what it says now, and pass that total.")
            }
            guard sentences > 0 else {
                throw MCPError.badArguments(
                    "nothing to change. preview_dictionary_backfill lists what "
                    + "would be rewritten.")
            }
            var written: [[String: Any]] = []
            var refused = 0
            for plan in plans {
                if DictionaryBackfill.apply(plan) {
                    written.append(["recording_id": plan.recording.id,
                                    "title": plan.recording.displayTitle,
                                    "sentences": plan.changes.count])
                } else {
                    refused += 1
                }
            }
            var applied: [String: Any] = [
                "rewritten": written,
                "sentences": written.reduce(0) { $0 + (($1["sentences"] as? Int) ?? 0) },
            ]
            // Not swallowed, for the reason the CLI does not swallow it: the
            // compare-and-swap did its job and the user has to know that some of
            // what they read is still unwritten.
            if refused > 0 {
                applied["refused"] = refused
                applied["note"] = "\(refused) recording(s) changed while this ran "
                    + "and were left alone. Preview again to see what is left."
            }
            return json(applied)

        case "get_transcript":
            let recording = try find(args)
            let offset = max(0, args["offset"] as? Int ?? 0)
            let limit = clamp(args["limit"], default: 200, min: 1, max: 500)
            let turns = recording.storedTurns
            let page = Array(turns.dropFirst(offset).prefix(limit))
            return json([
                "recording_id": recording.id,
                "turns": page.map { ["start": $0.start, "end": $0.end,
                                     "speaker": $0.speaker, "text": $0.text] },
                "pagination": pagination(total: turns.count, offset: offset,
                                         returned: page.count),
            ])

        case "search_transcripts":
            guard let query = (args["query"] as? String)?.lowercased(), !query.isEmpty else {
                throw MCPError.badArguments("search_transcripts needs a query")
            }
            let limit = clamp(args["limit"], default: 20, min: 1, max: 200)
            // `person` here means "said by", which is a different question from
            // the one `list_recordings` answers ("was in the room"). Asking what
            // somebody said about a topic is the whole point of the pairing.
            let person = (args["person"] as? String ?? "")
            // `tags` narrows which recordings are read at all, so it goes on the
            // library rather than into the turn loop below. That is the same
            // cheap-before-expensive ordering `RecordingFilter` exists for: with
            // a tag given, this reads three transcripts instead of thirty-three.
            var scope = RecordingFilter()
            scope.tags = try strings(args["tags"], field: "tags")
            var hits: [[String: Any]] = []
            for recording in scope.apply(to: Recording.all()) {
                for turn in recording.storedTurns
                where turn.text.lowercased().contains(query)
                    && (person.isEmpty || SpeakerName.matches(turn.speaker, person)) {
                    hits.append([
                        "recording_id": recording.id,
                        "title": recording.metadata.title,
                        "recorded_at": recording.metadata.recorded_at,
                        "start": turn.start,
                        "speaker": SpeakerName.display(turn.speaker),
                        "text": turn.text,
                    ])
                    if hits.count >= limit { break }
                }
                if hits.count >= limit { break }
            }
            return json(["matches": hits, "truncated": hits.count >= limit])

        case "list_people":
            let context = (try? PeopleMemory.load()) ?? MemoryDocument()
            let known = Set(PeopleMemory.validReceipts(context).flatMap { $0.claims.map(\.person) })
            let people = People.roster().map { person -> [String: Any] in
                let label = person.label
                var row: [String: Any] = [
                    "name": SpeakerName.display(label),
                    "recordings": person.recordings.count,
                    "speech_seconds": Int(person.seconds),
                    "has_context": known.contains(label),
                ]
                // The disk label only when it differs, which is the user's own
                // track and nothing else. Printing `label: "Edgar"` beside
                // `name: "Edgar"` on every row is noise; printing it for `Me`
                // is the one case where an agent reading a raw transcript will
                // see a word that is in no list it was given.
                if row["name"] as? String != label { row["label"] = label }
                return row
            }
            return json(["people": people])

        // The write side. Everything below goes through `Notes`, which the CLI
        // and the detail pane also go through, so an agent cannot reach a note
        // by a path a human never takes.
        case "list_notes":
            // ANDed with `recording_id` below, and applied to both branches, so
            // `tags` alone asks the library and the two together ask one
            // meeting. Nothing here consults the recordings' own tags: a note
            // carries what was put on it. See `list_tags`.
            let filed = try strings(args["tags"], field: "tags")
            // ANDed with the tags and the recording, so a query alone searches
            // the library and the three together search one meeting's notes for
            // a phrase.
            let query = (args["query"] as? String ?? "")
                .trimmingCharacters(in: .whitespaces)
            func matching(_ notes: [Note]) -> [[String: Any]] {
                notes.filter { !$0.excludedFromAI && $0.carries(filed) }
                    .compactMap { note -> [String: Any]? in
                        guard !query.isEmpty else { return brief(note) }
                        var row = brief(note)
                        // The title is searched as well as the body, and it is
                        // searched first, so a note that matched only its own
                        // name grows no excerpt repeating it. That is the rule
                        // `RecordingFilter.search` follows for a recording.
                        let titled = Find.contains(query, in: note.title)
                        guard let hit = excerpt(query, in: note.body) else {
                            guard titled else { return nil }
                            row["matched"] = "title"
                            return row
                        }
                        row["matched"] = titled ? "title and body" : "body"
                        row["excerpt"] = hit
                        row["matches"] = Find.count(of: query, in: Excerpt.flattened(note.body))
                        return row
                    }
            }
            // Optional, unlike everywhere else: a note can be about four
            // meetings, so "every note" is a question worth being able to ask.
            guard args["recording_id"] != nil else {
                return json(["notes": matching(Notes.all())])
            }
            let recording = try find(args)
            return json([
                "recording_id": recording.id,
                "notes": matching(Notes.list(about: recording)),
            ])

        case "read_note":
            let note = try note(args)
            var out = brief(note)
            out["body"] = note.body
            return json(out)

        case "write_note":
            guard let title = args["title"] as? String else {
                throw MCPError.badArguments("write_note needs a title")
            }
            guard let written = args["body"] as? String else {
                throw MCPError.badArguments("write_note needs a body")
            }
            // Without the citation markers. `Agent.brief` asks for them and the
            // Ask pane draws them as numbers, but a note is a markdown file
            // somebody may open in another editor, and `[rec:2026-08-08-…]` in
            // the middle of a sentence there is this app's private punctuation
            // leaking into their document. What the note is about is a field on
            // it, which is where provenance belongs.
            let body = AnswerReferences.strip(written)
            let note = try Notes.create(title: title, body: body, source: .agent,
                                        prompt: args["prompt"] as? String,
                                        recordings: try ids(args["recordings"],
                                                            field: "recordings"),
                                        tags: try strings(args["tags"], field: "tags"))
            // The slug back, because it may not be the one the title implies:
            // a colliding title is numbered rather than refused, and an agent
            // that assumed otherwise would edit the wrong note next.
            return json(["written": brief(note)])

        case "edit_note":
            let existing = try writable(args)
            guard let body = args["body"] as? String else {
                throw MCPError.badArguments("edit_note needs a body")
            }
            // Required here and optional on the CLI, deliberately. A person at
            // a terminal is one writer and can see what they are replacing;
            // this is the surface where two writers meet.
            guard let was = args["was"] as? String else {
                throw MCPError.badArguments(
                    "edit_note needs `was`: the body as read_note returned it. "
                        + "Read the note first.")
            }
            let note = try Notes.replace(
                // Markers out, the same way `write_note` takes them out. `was`
                // is compared against what `read_note` returned, which is the
                // stored body, so stripping the new one cannot move the swap.
                existing.slug, body: AnswerReferences.strip(body),
                title: args["title"] as? String,
                prompt: args["prompt"] as? String, source: .agent,
                recordings: args["recordings"] == nil
                    ? nil : try ids(args["recordings"], field: "recordings"),
                // Absent means unchanged, the same as `recordings` above.
                tags: args["tags"] == nil
                    ? nil : try strings(args["tags"], field: "tags"),
                expecting: was)
            return json(["edited": brief(note)])

        case "delete_note":
            return json(["deleted": brief(try Notes.delete(try writable(args).slug))])

        default:
            throw MCPError.badArguments("unknown tool: \(name)")
        }
    }

    /// Everything about a note except its text, which is the expensive part.
    ///
    /// Same shape as `brief(_ recording:)` and for the same reason: an agent
    /// should be able to see what is there and decide what to read.
    /// One calendar event as a row.
    ///
    /// `recorded` maps a calendar id to the recording of that meeting, and is
    /// passed in rather than looked up, because the caller listing ten events
    /// would otherwise walk the library ten times.
    ///
    /// **A meeting being recorded right now is marked, not dropped.** The
    /// sidebar excludes it because it shows the live recording immediately
    /// above; a tool has no such second place, and "this is the meeting you are
    /// in, and here is its id" is strictly more use to an agent than an event
    /// silently missing from the list.
    private static func row(for event: CalendarEvent,
                            recorded: [String: String]) -> [String: Any] {
        var out: [String: Any] = [
            "event_id": event.id,
            "title": event.title,
            "start": Timestamps.stamp(event.start),
            "end": Timestamps.stamp(event.end),
            "kind": event.kind.rawValue,
            "calendar": event.calendar,
            "has_link": event.link != nil,
        ]
        if !event.guestNames.isEmpty { out["guests"] = event.guestNames }
        if let agenda = MeetingBrief.trimmedAgenda(event) { out["agenda"] = agenda }
        if let id = recorded[event.id] { out["recording_id"] = id }
        return out
    }

    private static func brief(_ note: Note) -> [String: Any] {
        var out: [String: Any] = [
            "slug": note.slug,
            "title": note.title,
            "source": note.source,
            "created": note.created,
            "updated": note.updated,
            "recordings": note.recordings,
        ]
        if let about = note.aboutPersonID {
            let id = MemoryPreferences.canonicalID(about, root: Library.root)
            out["about_person_id"] = id
            out["about_person"] = People.roster().first { MemoryPreferences.personID($0.label, root: Library.root) == id }?.display
            out["attribution"] = "Written by the library owner about this person; first-person statements refer to the owner."
        }
        if let prompt = note.prompt, !prompt.isEmpty { out["prompt"] = prompt }
        // Only when there are any, which is `brief(_ recording:)`'s rule for
        // the same key.
        if !note.tags.isEmpty { out["tags"] = note.tags }
        // Only when it is true, so its presence is the signal. A note somebody
        // has been into by hand is one to rewrite carefully or not at all.
        //
        // Tagging a note does not set this, because `Notes.setTags` leaves
        // `updated` alone on purpose: filing a note is not editing its words,
        // and an agent's own add_tags marking it hand-edited would be a lie it
        // reads back next turn.
        if note.updated != note.created { out["edited_by_hand"] = true }
        // An id the library no longer has, listed rather than dropped. A note
        // about four meetings must not quietly claim it was about three because
        // one of them was deleted.
        let unresolved = Notes.sources(of: note).filter { $0.title == nil }.map(\.id)
        if !unresolved.isEmpty { out["unresolved_recordings"] = unresolved }
        return out
    }

    /// Which of the two `add_tags` and `remove_tags` were pointed at.
    ///
    /// Both errors name the tool and say what to do, because both are things a
    /// model does. Giving neither is the ordinary slip; giving both is the
    /// interesting one, and it is refused rather than resolved in some order,
    /// because a tag on a meeting and a tag on the write-up of it are two
    /// different claims and guessing which was meant would make one of them
    /// silently.
    ///
    /// **Not `writable`, so the user's own note can be tagged.** That note is
    /// unwritable because its words were not derived from anything and cannot
    /// be got back. A tag is filing rather than wording: it takes one click to
    /// remove in the window, and the argument for tags being writable at all
    /// applies hardest to the note an agent most wants to find again.
    private static func subject(_ args: [String: Any], for tool: String) throws -> Taggable {
        let id = args["recording_id"] as? String
        let name = args["note"] as? String
        switch (id, name) {
        case (.some, .some):
            throw MCPError.badArguments(
                "\(tool) takes recording_id or note, not both: a tag on a "
                    + "recording and a tag on a note are two different claims.")
        case (.none, .none):
            throw MCPError.badArguments(
                "\(tool) needs recording_id or note, saying what to tag.")
        case (.some, .none):
            return .recording(try find(args))
        case (.none, .some):
            return .note(try note(args))
        }
    }

    private static func note(_ args: [String: Any]) throws -> Note {
        guard let name = args["note"] as? String else {
            throw MCPError.badArguments("note is required: the slug from list_notes")
        }
        // The recording, when given, only narrows a shared title. It is not
        // part of the note's identity any more: the slug is unique library-wide.
        let about = (args["recording_id"] as? String).flatMap(Recording.find)
        guard let note = Notes.find(name, about: about), !note.excludedFromAI else {
            throw MCPError.notFound("no note `\(name)`")
        }
        return note
    }

    /// The same note, refused when it is the user's own.
    ///
    /// **The one asymmetry in the note surface.** An agent reads the user's
    /// note freely, because what somebody typed during the call is exactly the
    /// context that is in no transcript and that nothing else can supply. It
    /// cannot write it, for the reason it cannot edit a transcript: that text
    /// was not derived from anything and there is no way to get it back.
    ///
    /// A refusal that only said "no" would leave an agent with nowhere to put
    /// the work it had already done, so it names the way through.
    private static func writable(_ args: [String: Any]) throws -> Note {
        let note = try note(args)
        guard !Notes.isYours(note) else {
            throw MCPError.badArguments(
                "`\(note.slug)` is the user's own note and cannot be changed from "
                    + "here. Read it, and write what you have as a separate note "
                    + "with write_note.")
        }
        return note
    }

    /// A JSON array of recording ids, refusing the shapes that look like one.
    private static func ids(_ raw: Any?, field: String) throws -> [String] {
        if let list = raw as? [String] { return list }
        // A single string where an array belongs is the mistake an agent
        // actually makes, and silently accepting it would teach it the wrong
        // shape. Naming both is cheaper than a refusal it cannot act on.
        if let one = raw as? String {
            throw MCPError.badArguments(
                "\(field) is a list of recording ids, not one id: [\"\(one)\"]")
        }
        throw MCPError.badArguments("\(field) is required: a list of recording ids")
    }

    /// The same, for an optional list that is not recording ids.
    ///
    /// Absent means "no constraint" rather than an error, because `tags` is a
    /// filter on `list_recordings` and every filter there is optional. A bare
    /// string is still refused by name, for the reason `ids` refuses one.
    private static func strings(_ raw: Any?, field: String) throws -> [String] {
        if raw == nil { return [] }
        if let list = raw as? [String] { return list }
        if let one = raw as? String {
            throw MCPError.badArguments(
                "\(field) is a list, not one value: [\"\(one)\"]")
        }
        throw MCPError.badArguments("\(field) must be a list of strings")
    }

    /// The same again where the list is the point of the call.
    ///
    /// An empty list is refused rather than treated as a no-op: `add_tags` with
    /// nothing in it is a mistake somewhere upstream, and answering it with the
    /// recording's unchanged tags would read as success.
    private static func wanted(_ raw: Any?, for tool: String) throws -> [String] {
        let list = try strings(raw, field: "tags")
        guard !list.isEmpty else {
            throw MCPError.badArguments("\(tool) needs at least one tag")
        }
        return list
    }

    // MARK: - Resources

    private static var resources: [[String: Any]] {
        Recording.all().prefix(200).flatMap { recording -> [[String: Any]] in
            [
                ["uri": "listen://recordings/\(recording.id)",
                 "name": recording.metadata.title,
                 "mimeType": "text/markdown"],
                ["uri": "listen://recordings/\(recording.id)/transcript",
                 "name": recording.metadata.title + " transcript",
                 "mimeType": "text/plain"],
            ]
        }
    }

    private static func readResource(_ uri: String) -> String? {
        guard uri.hasPrefix("listen://recordings/") else { return nil }
        var rest = String(uri.dropFirst("listen://recordings/".count))
        // Strip any query before splitting: the transcript resource takes
        // offset and limit.
        var offset = 0, limit = 200
        if let q = rest.firstIndex(of: "?") {
            for pair in rest[rest.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2, let value = Int(kv[1]) else { continue }
                if kv[0] == "offset" { offset = max(0, value) }
                if kv[0] == "limit" { limit = min(max(1, value), 500) }
            }
            rest = String(rest[..<q])
        }

        let wantsTranscript = rest.hasSuffix("/transcript")
        let id = wantsTranscript ? String(rest.dropLast("/transcript".count)) : rest
        guard let recording = Recording.find(id) else { return nil }

        let turns = recording.storedTurns
        if wantsTranscript {
            return Array(turns.dropFirst(offset).prefix(limit))
                .map { "[\(TranscriptFormat.stamp($0.start))] \($0.speaker): \($0.text)" }
                .joined(separator: "\n")
        }
        var out = "# \(recording.metadata.title)\n\n"
        out += "\(recording.metadata.recorded_at)\n\n"
        if !recording.speakers.isEmpty {
            out += "Speakers: " + recording.speakers.joined(separator: ", ") + "\n\n"
        }
        for turn in turns {
            out += "**\(turn.speaker)** · \(TranscriptFormat.stamp(turn.start))\n\n"
                + "\(turn.text)\n\n"
        }
        return out
    }

    // MARK: - Filters

    /// Parse `after` and `before` into an instant, or nil when absent.
    ///
    /// A bare `YYYY-MM-DD` names a day, and a day has two ends. `before:
    /// 2026-07-14` meaning midnight would exclude everything recorded on the
    /// 14th, which is the opposite of what anybody asking that means, so the
    /// bare form is widened to the end of the day here and to its start for
    /// `after`. A full timestamp is taken literally.
    private static func dayBound(
        _ raw: Any?, endOfDay: Bool, field: String
    ) throws -> Date? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespaces),
              !text.isEmpty
        else { return nil }

        if let exact = Timestamps.parse(text) { return exact }
        if let day = Timestamps.parseDay(text) {
            return endOfDay ? day.addingTimeInterval(24 * 60 * 60 - 1) : day
        }
        throw MCPError.badArguments(
            "\(field) must be YYYY-MM-DD or an ISO 8601 timestamp, got \"\(text)\"")
    }

    // MARK: - Plumbing

    private static func brief(_ recording: Recording) -> [String: Any] {
        var out: [String: Any] = [
            "id": recording.id,
            "title": recording.metadata.title,
            "recorded_at": recording.metadata.recorded_at,
            "duration_seconds": Int(recording.metadata.duration),
            "state": recording.metadata.state,
        ]
        // Only when there are some. An empty array on every row of a fifty
        // recording listing is fifty lines saying nothing, and this is the
        // payload an agent pages through before deciding what to read.
        let tags = Tags.of(recording)
        if !tags.isEmpty { out["tags"] = tags }
        return out
    }

    private static func pagination(total: Int, offset: Int, returned: Int) -> [String: Any] {
        var out: [String: Any] = ["total": total, "offset": offset, "returned": returned]
        // next_offset only when there is a next page, so an agent can loop on
        // its presence rather than comparing arithmetic.
        if offset + returned < total { out["next_offset"] = offset + returned }
        return out
    }

    /// A required string argument, trimmed, or a refusal naming it.
    private static func nonEmpty(_ raw: Any?, _ field: String,
                                 for tool: String) throws -> String {
        guard let text = (raw as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw MCPError.badArguments("\(tool) needs `\(field)`")
        }
        return text
    }

    /// The backfill scope both dictionary backfill tools read, planned once.
    ///
    /// Shared so preview and apply cannot disagree about what `recording_id`
    /// means: the `sentences` compare-and-swap on apply is only worth anything
    /// while the two are planning the same pass from the same arguments.
    private static func backfillPlans(_ args: [String: Any],
                                      for tool: String) throws -> [DictionaryBackfill.Plan] {
        let entries = CustomDictionary.load()
        guard !entries.isEmpty else {
            throw MCPError.badArguments(
                "the dictionary is empty, so a backfill would change nothing. "
                + "add_dictionary_entry starts one.")
        }
        var library: [Recording]?
        if let id = (args["recording_id"] as? String)?
            .trimmingCharacters(in: .whitespaces), !id.isEmpty {
            guard let one = Recording.find(id) else {
                throw MCPError.notFound("no recording \(id)")
            }
            library = [one]
        }
        return DictionaryBackfill.preview(entries, in: library)
    }

    /// One window of `body` around the first hit, as plain text.
    ///
    /// Not `Excerpt.around`, which answers with an `NSAttributedString` and
    /// wants a font and a colour: this file is reached from a CLI process with
    /// no window, and a tool result is JSON either way. The two agree on what
    /// *matches*, because both go through `Find`, and that is the part that has
    /// to agree; how wide a window each draws is presentation.
    ///
    /// Flattened first. A note body is a document, and an excerpt that keeps
    /// its newlines and its `##` markers is three lines of JSON where one
    /// sentence was wanted. The note row in the window flattens for the same
    /// reason.
    private static func excerpt(_ query: String, in body: String,
                                width: Int = 160) -> String? {
        let text = Excerpt.flattened(body)
        guard let range = Find.ranges(of: query, in: text).first else { return nil }
        let full = text as NSString
        // A third of the room in front and the rest behind, for the reason
        // `Excerpt.around` gives: what follows a term is more often the answer.
        let lead = max(0, range.location - width / 3)
        let trail = min(full.length, NSMaxRange(range) + (width - width / 3))
        let window = full.substring(with: NSRange(location: lead, length: trail - lead))
        return (lead > 0 ? "…" : "") + window + (trail < full.length ? "…" : "")
    }

    private static func find(_ args: [String: Any]) throws -> Recording {
        guard let id = args["recording_id"] as? String else {
            throw MCPError.badArguments("recording_id is required")
        }
        guard let recording = Recording.find(id) else {
            throw MCPError.notFound("no recording \(id)")
        }
        return recording
    }

    private static func clamp(_ value: Any?, default fallback: Int,
                              min lower: Int, max upper: Int) -> Int {
        guard let n = value as? Int else { return fallback }
        return Swift.min(Swift.max(n, lower), upper)
    }

    private static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static func result(id: Any?, _ value: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value]
    }

    private static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(),
         "error": ["code": code, "message": message]]
    }

    private static func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        FileHandle.standardOutput.write(text.data(using: .utf8)!)
    }
}

enum MCPError: Error, LocalizedError {
    case badArguments(String)
    case notFound(String)
    /// A tool that exists, asked for by somebody who may not have it.
    ///
    /// Distinct from `badArguments("unknown tool: …")` on purpose. That one
    /// means the name is not a tool at all and the model should stop trying;
    /// this one means the name is real and this session does not have it, and
    /// the difference is the whole of what a model needs to know to do
    /// something else instead.
    case notAllowed(String)

    var errorDescription: String? {
        switch self {
        case .badArguments(let m): return m
        case .notFound(let m):     return m
        case .notAllowed(let name):
            return "\(name) is not one of the tools this session may call. "
                + "tools/list is the whole list."
        }
    }
}

// ---------------------------------------------------------------------------

/// Reading the one timestamp format the library writes.
///
/// `metadata.recorded_at` is ISO 8601 with a `Z`, written by one place, so this
/// parses that and a bare day and nothing else. A `DateFormatter` with a
/// locale-dependent format would read the library differently on a machine set
/// to a different region, which is the sort of failure that appears only on
/// somebody else's Mac.
enum Timestamps {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ text: String) -> Date? { iso.date(from: text) }

    /// The one format this library writes, for the tools that answer with a
    /// date the library did not store: a calendar event has a `Date`, and
    /// everything else in a tool result is `metadata.recorded_at` verbatim.
    /// Same formatter as `parse`, so a stamp this returns round-trips.
    static func stamp(_ date: Date) -> String { iso.string(from: date) }

    static func parseDay(_ text: String) -> Date? { day.date(from: text) }
}

// `Recording.speaks` and `SpeakerName.matches` used to live here. They moved to
// `RecordingFilter.swift`, which is the one owner of narrowing the library now
// that the window, the CLI and this file all go through it.
