import Foundation

/// `listen mcp`: an MCP server over stdio, where notes and tags are the only
/// writable surface.
///
/// Hand-rolled rather than pulled from the SDK. The surface is thirteen tools
/// and two resources over files already on disk, and the official Swift SDK
/// brings a dependency tree and a concurrency model into a binary that already
/// carries MLX, CoreML and Sparkle. The protocol needed here is a few hundred
/// lines of JSON-RPC with no streaming and no subscriptions.
///
/// **It opens no port**, and the app does not need to be running: the library on
/// disk is the source of truth.
///
/// **Everything except notes and tags is read-only, and that is a boundary
/// rather than a milestone.** This server used to write nothing at all. It now
/// writes note artifacts and a recording's tags, and nothing else: an agent
/// cannot rename a speaker, correct a transcript, retitle a recording or delete
/// one.
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

    static func serve() -> Never {
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
            send(result(id: id, ["tools": tools]))

        case "tools/call":
            let name = params["name"] as? String ?? ""
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                send(result(id: id, [
                    "content": [["type": "text", "text": try call(name, arguments)]],
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
                            "description": "Only recordings carrying **all** of these "
                                + "tags. A tag is the user's own filing of a meeting, "
                                + "so this is usually the right way to name a subject "
                                + "that no single word in the transcripts shares. Call "
                                + "list_tags first rather than guessing at names.",
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
                    + "transcript text; use get_transcript.",
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
                "description": "Everyone in the voice bank, with how many recordings "
                    + "they appear in.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "list_tags",
                "description": "Every tag in the library, with how many recordings "
                    + "carries it, most first. A tag is the user's own filing of a "
                    + "meeting, in their own words, so this is the vocabulary a "
                    + "question can be asked in and there is nothing else to derive "
                    + "it from. **Read this before filtering on tags**: the names "
                    + "are invented rather than drawn from a fixed list, and a tag "
                    + "nobody uses does not exist.",
                "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
            ],
            [
                "name": "add_tags",
                "description": "Tag a recording. Adds to what it already carries "
                    + "rather than replacing it. A tag already in the library is "
                    + "matched however it was capitalised, so reuse the exact names "
                    + "from list_tags rather than coining a near-duplicate: "
                    + "\"job hunt\" and \"job-hunt\" are two tags and neither has "
                    + "all the recordings. Returns everything the recording carries "
                    + "afterwards.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": ["type": "string"],
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Free text, up to 40 characters each, no "
                                + "commas. A space is fine: \"job hunt\" is one tag.",
                        ],
                    ],
                    "required": ["recording_id", "tags"],
                ],
            ],
            [
                "name": "remove_tags",
                "description": "Take tags off a recording. Tags not on it are "
                    + "ignored rather than refused. Nothing else about the recording "
                    + "changes, and a tag that ends up on nothing simply stops "
                    + "existing: there is no separate list to tidy. Returns what the "
                    + "recording carries afterwards.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": ["type": "string"],
                        "tags": ["type": "array", "items": ["type": "string"]],
                    ],
                    "required": ["recording_id", "tags"],
                ],
            ],
            [
                "name": "list_notes",
                "description": "Notes, without their text. With a recording_id, the "
                    + "notes that name that recording among their sources; without "
                    + "one, every note in the library, newest first. A note with "
                    + "source `you` is what the user typed themselves: read it "
                    + "first, and never write it.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recording_id": ["type": "string",
                                         "description": "Optional. Omit for the "
                                             + "whole library."],
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
                "description": "Add a note. Markdown body, free-text title, and a "
                    + "list of the recordings it is about. **A note can be about "
                    + "several meetings**: a synthesis across four catch-ups names "
                    + "all four rather than being filed under one of them "
                    + "arbitrarily. Never overwrites: a title already in use is "
                    + "numbered. Use edit_note to change one that exists. The "
                    + "user's own note, which every recording can have, is "
                    + "readable and not writable from here: add a note beside it "
                    + "rather than trying to change it.",
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
                                   "description": "What you were asked for, kept beside "
                                       + "the note so somebody reading it in a month "
                                       + "knows what it was answering. Strongly "
                                       + "recommended."],
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
    static var transport = "in-app"

    /// Run one tool and return what it would have sent back over the wire.
    ///
    /// The single choke point for every tool invocation: the stdio server,
    /// the in-app agent, and the CLI harnesses (which reach the library only
    /// through a spawned `listen mcp`) all land here, which is what lets one
    /// line make the whole surface auditable. The log carries the tool name
    /// and recording ids, never arguments: a query names what a meeting was
    /// about, and the log must stay safe to read aloud.
    static func call(_ name: String, _ args: [String: Any]) throws -> String {
        do {
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
            out["notes"] = Notes.list(about: recording).map(\.slug)
            return json(out)

        case "list_tags":
            return json(["tags": Tags.all().map {
                ["name": $0.name, "recordings": $0.count]
            }])

        case "add_tags":
            let recording = try find(args)
            let tags = try wanted(args["tags"], for: "add_tags")
            return json(["recording_id": recording.id,
                         "tags": try Tags.add(tags, to: recording)])

        case "remove_tags":
            let recording = try find(args)
            let tags = try wanted(args["tags"], for: "remove_tags")
            return json(["recording_id": recording.id,
                         "tags": try Tags.remove(tags, from: recording)])

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
            var counts: [String: Int] = [:]
            var seconds: [String: Double] = [:]
            for recording in Recording.all() {
                for (name, print) in recording.voiceprints where !VoiceBank.isPlaceholder(name) {
                    counts[name, default: 0] += 1
                    seconds[name, default: 0] += print.speech
                }
            }
            let people = counts.keys.sorted().map { label -> [String: Any] in
                var row: [String: Any] = [
                    "name": SpeakerName.display(label),
                    "recordings": counts[label] ?? 0,
                    "speech_seconds": Int(seconds[label] ?? 0),
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
            // Optional, unlike everywhere else: a note can be about four
            // meetings, so "every note" is a question worth being able to ask.
            guard args["recording_id"] != nil else {
                return json(["notes": Notes.all().map(brief)])
            }
            let recording = try find(args)
            return json([
                "recording_id": recording.id,
                "notes": Notes.list(about: recording).map(brief),
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
                                                            field: "recordings"))
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
    private static func brief(_ note: Note) -> [String: Any] {
        var out: [String: Any] = [
            "slug": note.slug,
            "title": note.title,
            "source": note.source,
            "created": note.created,
            "updated": note.updated,
            "recordings": note.recordings,
        ]
        if let prompt = note.prompt, !prompt.isEmpty { out["prompt"] = prompt }
        // Only when it is true, so its presence is the signal. A note somebody
        // has been into by hand is one to rewrite carefully or not at all.
        if note.updated != note.created { out["edited_by_hand"] = true }
        // An id the library no longer has, listed rather than dropped. A note
        // about four meetings must not quietly claim it was about three because
        // one of them was deleted.
        let unresolved = Notes.sources(of: note).filter { $0.title == nil }.map(\.id)
        if !unresolved.isEmpty { out["unresolved_recordings"] = unresolved }
        return out
    }

    private static func note(_ args: [String: Any]) throws -> Note {
        guard let name = args["note"] as? String else {
            throw MCPError.badArguments("note is required: the slug from list_notes")
        }
        // The recording, when given, only narrows a shared title. It is not
        // part of the note's identity any more: the slug is unique library-wide.
        let about = (args["recording_id"] as? String).flatMap(Recording.find)
        guard let note = Notes.find(name, about: about) else {
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

    var errorDescription: String? {
        switch self {
        case .badArguments(let m): return m
        case .notFound(let m):     return m
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

    static func parseDay(_ text: String) -> Date? { day.date(from: text) }
}

// `Recording.speaks` and `SpeakerName.matches` used to live here. They moved to
// `RecordingFilter.swift`, which is the one owner of narrowing the library now
// that the window, the CLI and this file all go through it.
