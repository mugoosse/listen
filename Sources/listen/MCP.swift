import Foundation

/// `listen mcp`: a read-only MCP server over stdio.
///
/// Hand-rolled rather than pulled from the SDK. The surface is five tools and
/// two resources over JSON files already on disk, and the official Swift SDK
/// brings a dependency tree and a concurrency model into a binary that already
/// carries MLX, CoreML and Sparkle. The protocol needed here is a few hundred
/// lines of JSON-RPC with no streaming and no subscriptions.
///
/// **Read-only, and it opens no port.** The app does not need to be running;
/// the library on disk is the source of truth. Nothing here writes, so an agent
/// cannot rename a speaker or delete a meeting.
///
/// Transcripts are long, so pagination is not optional, and the transcript is a
/// separate call from the metadata so an agent can decide what it needs before
/// paying for it.
enum MCP {
    static let protocolVersion = "2024-11-05"

    static func serve() -> Never {
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

    private static var tools: [[String: Any]] {
        [
            [
                "name": "list_recordings",
                "description": "List recordings, newest first. Returns metadata only. "
                    + "Filters combine with AND, so person plus a date range is the "
                    + "cheapest way to narrow a library before asking for transcripts.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string",
                                  "description": "Filter on title and transcript text."],
                        "person": ["type": "string",
                                   "description": "Only recordings this person speaks in. "
                                       + "Matches the name from list_people, and your own "
                                       + "name matches the microphone track."],
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
                "description": "Metadata, participants and speaker names for one "
                    + "recording. Does not include transcript text; use get_transcript.",
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
        ]
    }

    private static func call(_ name: String, _ args: [String: Any]) throws -> String {
        switch name {
        case "list_recordings":
            let query = (args["query"] as? String ?? "").lowercased()
            let person = (args["person"] as? String ?? "")
            let limit = clamp(args["limit"], default: 20, min: 1, max: 200)
            let offset = max(0, args["offset"] as? Int ?? 0)
            let after = try dayBound(args["after"], endOfDay: false, field: "after")
            let before = try dayBound(args["before"], endOfDay: true, field: "before")

            var all = Recording.all()
            // Cheapest filters first. `query` and `person` both read every
            // turns.json in the library, and the date bounds read nothing but
            // the metadata already in hand, so narrowing on dates first is the
            // difference between reading 33 transcripts and reading 3.
            if after != nil || before != nil {
                all = all.filter { recording in
                    guard let at = Timestamps.parse(recording.metadata.recorded_at) else {
                        // A recording whose timestamp will not parse is kept
                        // rather than dropped. Being invisible to every dated
                        // query is a worse answer than being in the wrong one,
                        // and it would be invisible with nothing to explain it.
                        return true
                    }
                    if let after, at < after { return false }
                    if let before, at > before { return false }
                    return true
                }
            }
            if !person.isEmpty {
                all = all.filter { $0.speaks(person) }
            }
            if !query.isEmpty {
                all = all.filter {
                    $0.metadata.title.lowercased().contains(query)
                        || $0.transcriptText.lowercased().contains(query)
                }
            }
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
            return json(out)

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
            var hits: [[String: Any]] = []
            for recording in Recording.all() {
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

        default:
            throw MCPError.badArguments("unknown tool: \(name)")
        }
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
        [
            "id": recording.id,
            "title": recording.metadata.title,
            "recorded_at": recording.metadata.recorded_at,
            "duration_seconds": Int(recording.metadata.duration),
            "state": recording.metadata.state,
        ]
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

extension Recording {
    /// Does this person speak in this recording?
    ///
    /// Matching is on the displayed name as well as the stored label, because
    /// the microphone track is stored as `Me` however the user chooses to be
    /// shown. Somebody who has set their name to Maxime and asks for
    /// `person: "Maxime"` means their own track, and matching only the disk
    /// label would return nothing with no way to tell that from "no such
    /// person". The same rule makes `Speaker A` findable by what the UI calls
    /// it rather than only by `A`.
    func speaks(_ person: String) -> Bool {
        speakers.contains { SpeakerName.matches($0, person) }
    }
}

extension SpeakerName {
    /// Does a stored speaker label answer to this name?
    ///
    /// Case and surrounding space are ignored: an agent is passing through a
    /// name a human typed, and refusing "edgar" for `Edgar` would be a filter
    /// that silently returns nothing.
    static func matches(_ label: String, _ wanted: String) -> Bool {
        let wanted = wanted.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return false }
        return label.caseInsensitiveCompare(wanted) == .orderedSame
            || display(label).caseInsensitiveCompare(wanted) == .orderedSame
    }
}
