import Foundation
import ListenKit

enum ContextCLI {
    static let usage = """
    listen context status [--json]
    listen context person <name> [--question <question>] [--budget <tokens>] [--as-of YYYY-MM-DD] [--json]
    listen context project <name-or-id> [--question <question>] [--budget <tokens>] [--as-of YYYY-MM-DD] [--json]
    listen context history <person> [--json]
    listen context entities [--json]
    listen context alias <entity-id> <alias>
    listen context correct <claim-id> <corrected text>
    listen context pin|unpin|restore <claim-id>
    listen context jobs|usage [--json]
    listen context update [--person <name>] [--source rec:<id>|note:<slug>] [--limit <parts>] [--retry] [--claude|--codex] [--json]
    listen context auto on|off [--person <name>]
    listen context enrol on|off
    listen context note --person <name> <text> [--exclude-from-ai]
    listen context forget --person <name>
    listen context dismiss <claim-id>
    listen context suggestions [--accept <claim-id>] [--dismiss <claim-id>] [--json]
    listen context search <query> [--person <name>] [--limit <count>] [--as-of YYYY-MM-DD] [--json]
    listen context index
    listen context embeddings status|download|apple|multilingual|evaluate

    Facts and relationships keep exact quotes, dates and source references.
    Updates use your background model, or follow Ask. Automatic updates require Ask.
    Apple embeddings work without a download. Optional multilingual embeddings
    run locally after one model download. Briefs and corrections use encrypted
    owner-device sync; jobs and search vectors stay on this Mac.
    """

    /// How much of the library person and project memory has actually read.
    ///
    /// Lifted out of `context status` when the MCP server needed the same
    /// numbers. One type and one reader rather than two, because a CLI and a
    /// tool that disagreed about how many sources are pending would be a
    /// disagreement nobody could reproduce from either side.
    struct Coverage: Encodable {
        var automatic: Bool
        var askEnabled: Bool
        var sources: Int
        /// Recordings that cannot be extracted from until somebody names who is
        /// speaking. The one number here that names a fix rather than a state.
        var waitingForNames: Int
        var pending: Int
        var failed: Int
        var processed: Int
        var embeddingModels: [String]
        var indexedPassages: Int
        /// Whether somebody nobody has answered for yet is enrolled
        /// automatically.
        var enrolsNewPeople: Bool
        /// People at least one extractable source can speak for.
        var people: Int
        /// How many of them the sweep is allowed to read about.
        var enrolled: Int
        /// What those people between them are still waiting to have read.
        ///
        /// Not the same number as `pending`, and larger: `pending` counts each
        /// source once, and extraction is scoped per subject, so a meeting
        /// with three enrolled people in it is read three times. This is the
        /// one that answers "how long until it has caught up".
        var enrolledPending: Int
        /// Whole days of automatic work that backlog is at the current daily
        /// limit. A floor rather than an estimate: consolidation and summaries
        /// spend requests too, and they are not counted here.
        var estimatedDays: Int
        /// Who the sweep would read about next, soonest first.
        ///
        /// The same `ContextEnrolment.order` the sweep itself walks, so this
        /// is the queue rather than a description of it. It is here because
        /// round-robin fairness is otherwise unobservable: the old
        /// alphabetical scan starved everybody after the first name in the
        /// list for as long as their backlog lasted, and nothing anywhere
        /// could have shown that happening.
        ///
        /// The entity id travels with the name because the queue is keyed by
        /// id and a name cannot be turned back into one from outside: without
        /// it, a script can read this queue and has no way to say "and then
        /// this person was served".
        var nextUp: [Queued]
    }
    struct Queued: Encodable {
        var name: String
        var id: String
        var pending: Int
    }

    static func coverage() throws -> Coverage {
        let sources = ContextSources.all(), document = try PeopleMemory.load()
        let index = try SemanticIndex.load()
        let values = (try? MemoryPreferences.read(root: Library.root)) ?? [:]
        let candidates = ContextEnrolment.candidates(sources)
        let enrolled = candidates.filter {
            values["person:\(MemoryPreferences.personID($0, root: Library.root)):automatic"]?.text == "true"
        }
        // Per person this reads SQLite rather than transcripts, because
        // `personBatchCounts` was written by the index pass. Thirty-four of
        // them is cheap beside the `ContextSources.all()` above.
        let daily = max(1, Settings.contextDailyRequests)
        let served = ContextEnrolment.served()
        var ids: [String: String] = [:], weight: [String: Int] = [:]
        for label in enrolled {
            ids[label] = MemoryPreferences.personID(label, root: Library.root)
            weight[label] = sources.reduce(0) { $0 + ($1.names(label) ? 1 : 0) }
        }
        var backlog: [String: Int] = [:]
        for label in enrolled { backlog[label] = (try? PeopleMemory.person(label, document: document).pending) ?? 0 }
        let waiting = Set(enrolled.filter { (backlog[$0] ?? 0) > 0 })
        return Coverage(
            automatic: Settings.peopleContextEnabled
                && values.contains {
                    $0.key.hasPrefix("person:") && $0.key.hasSuffix(":automatic")
                        && $0.value.text == "true"
                },
            askEnabled: Settings.askEnabled,
            sources: sources.count,
            waitingForNames: sources.filter { $0.kind == "recording" && !$0.extractable }.count,
            pending: ContextProcessor.pending(sources, document, retry: true).count,
            failed: document.receipts.values.filter { $0.failure != nil && $0.source.isCurrent }.count,
            processed: PeopleMemory.validReceipts(document).count,
            embeddingModels: Set(index.entries.compactMap { $0.vector?.model }).sorted(),
            indexedPassages: index.entries.count,
            enrolsNewPeople: MemoryPreferences.enrolsNewPeople(root: Library.root),
            people: candidates.count,
            enrolled: enrolled.count,
            enrolledPending: backlog.values.reduce(0, +),
            estimatedDays: backlog.values.reduce(0, +) == 0 ? 0
                : max(1, (backlog.values.reduce(0, +) + daily - 1) / daily),
            nextUp: ContextEnrolment.order(waiting, ids: ids, weight: weight, served: served).prefix(5).map {
                Queued(name: SpeakerName.display($0), id: ids[$0] ?? "", pending: backlog[$0] ?? 0)
            })
    }

    /// One claim, as the window shows it: when, who, what, then its quotes.
    private static func printEntry(_ item: ContextCard.Entry, you: String?) {
        let when = item.evidence.map(\.recordedAt).max().map { String($0.prefix(10)) } ?? ""
        print("  \(when.isEmpty ? "" : when + "  ")\(ContextPresentation.addressed(item.text, you: you)) [\(item.status)]")
        for evidence in item.evidence { print("    [\(evidence.source)] \(evidence.quote)") }
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let command = arguments.first else { print(usage); return 0 }
            if ["help", "--help", "-h"].contains(command) { print(usage); return 0 }
            var jsonOutput = false, retry = false
            var person: String?, limit: Int?, backend: AgentBackend?
            var text: [String] = []
            var question = "", budget = 1500
            var asOf: String?
            var selectedSources: Set<String> = []
            var excluded = false
            // `suggestions` alone reads these, but every option is parsed before
            // the switch, so an unknown one is refused rather than treated as a
            // name. Declared here for that reason and no other.
            var accept: String?, refuse: String?
            var i = 1
            while i < arguments.count {
                let arg = arguments[i]
                switch arg {
                case "--json": jsonOutput = true
                case "--retry": retry = true
                case "--exclude-from-ai": excluded = true
                case "--source":
                    i += 1
                    guard i < arguments.count else { throw ContextProblem.message("--source needs a source ID.") }
                    selectedSources.insert(arguments[i])
                case "--accept", "--dismiss":
                    i += 1
                    guard i < arguments.count else {
                        throw ContextProblem.message("\(arg) needs a claim ID.")
                    }
                    if arg == "--accept" { accept = arguments[i] } else { refuse = arguments[i] }
                case "--claude", "--codex":
                    guard backend == nil else { throw ContextProblem.message("Choose one backend.") }
                    backend = arg == "--claude" ? .claude : .codex
                case "--question", "--budget", "--as-of":
                    i += 1
                    guard i < arguments.count else { throw ContextProblem.message("\(arg) needs a value.") }
                    if arg == "--question" { question = arguments[i] }
                    else if arg == "--as-of" { asOf = arguments[i] }
                    else {
                        guard let number = Int(arguments[i]), (256...16000).contains(number) else { throw ContextProblem.message("Budget must be 256 to 16000 tokens.") }
                        budget = number
                    }
                case "--person", "--limit":
                    i += 1
                    guard i < arguments.count else { throw ContextProblem.message("\(arg) needs a value.") }
                    if arg == "--person" { person = arguments[i] }
                    else {
                        guard let value = Int(arguments[i]), (1...100).contains(value) else {
                            throw ContextProblem.message("Limit must be from 1 to 100.")
                        }
                        limit = value
                    }
                default:
                    guard !arg.hasPrefix("--") else { throw ContextProblem.message("Unknown option: \(arg)") }
                    text.append(arg)
                }
                i += 1
            }
            let value = text.joined(separator: " ")
            if command != "update", retry || backend != nil { throw ContextProblem.message("Backend and retry options belong to context update.") }
            if !["search", "update", "auto", "note", "forget"].contains(command), person != nil || limit != nil { throw ContextProblem.message("Person and limit filters belong to search or update.") }
            if !["person", "project"].contains(command), !question.isEmpty || budget != 1500 || (asOf != nil && command != "search") {
                throw ContextProblem.message("Question, budget and date options belong to person or project context.")
            }
            if excluded && command != "note" { throw ContextProblem.message("--exclude-from-ai belongs to context note.") }
            if !selectedSources.isEmpty && command != "update" { throw ContextProblem.message("--source belongs to context update.") }
            switch command {
            case "status":
                guard text.isEmpty else { throw ContextProblem.message("context status takes no name.") }
                let result = try coverage()
                if jsonOutput { print(try json(result)) }
                else {
                    print("Automatic context: \(result.automatic ? "on" : "off") · Ask: \(result.askEnabled ? "on" : "off")")
                    print("\(result.enrolled) of \(result.people) people remembered · new people \(result.enrolsNewPeople ? "join automatically" : "stay off")")
                    print("\(result.processed) processed parts · \(result.pending) pending · \(result.failed) failed · \(result.waitingForNames) recordings waiting for speaker names")
                    if result.enrolledPending > 0 {
                        print("\(result.enrolledPending) to read for those people · about \(result.estimatedDays) day\(result.estimatedDays == 1 ? "" : "s") at \(Settings.contextDailyRequests) requests a day")
                        if !result.nextUp.isEmpty { print("next: " + result.nextUp.map { "\($0.name) (\($0.pending))" }.joined(separator: ", ")) }
                    }
                    print("\(result.indexedPassages) search entries · embeddings generated locally")
                    if !result.embeddingModels.isEmpty { print(result.embeddingModels.joined(separator: "\n")) }
                }
            case "person", "project":
                guard !value.isEmpty else { throw ContextProblem.message("context person needs a name.") }
                let packet = try ContextRetrieval.packet(value, kind: command, question: question, tokenBudget: budget, asOf: asOf)
                if jsonOutput { print(try json(packet)) }
                else {
                    // The same grouping and the same voice as the person page,
                    // out of `ContextPresentation`, so the window and the
                    // command line cannot describe one card two ways. `--json`
                    // above is untouched: it carries the stored wording and the
                    // stored predicate, which is what a machine reader wants.
                    let you = Settings.userName
                    print(packet.name)
                    for sentence in packet.brief { print(ContextPresentation.addressed(sentence.text, you: you)) }
                    let episodic = packet.entries.filter { ContextPresentation.episodic($0.text) }
                    for section in ContextPresentation.sections {
                        let group = packet.entries.filter {
                            !ContextPresentation.episodic($0.text) && ContextPresentation.section($0.predicate) == section
                        }
                        guard !group.isEmpty else { continue }
                        print("")
                        print(section)
                        for item in group { printEntry(item, you: you) }
                    }
                    if !episodic.isEmpty {
                        print("")
                        print("Last time you spoke")
                        for item in episodic { printEntry(item, you: you) }
                    }
                    print("")
                    print("\(packet.estimatedTokens) estimated tokens · \(packet.omitted) additional details · \(packet.pending) pending")
                }
            case "history":
                guard !value.isEmpty else { throw ContextProblem.message("context history needs a person.") }
                let memory = try ContextRetrieval.displayPerson(PeopleMemory.resolve(value))
                if jsonOutput { print(try json(memory)) }
                else {
                    print(memory.name)
                    for sentence in memory.summary { print(sentence.text) }
                    for item in memory.facts + memory.relations {
                        print("\(item.attribute): \(item.value)\(item.status == "historical" ? " (historical)" : "")")
                        for e in item.evidence { print("  \(e.date) \(e.marker) \(e.quote)") }
                    }
                    print("\(memory.sources) sources · \(memory.pending) pending parts · \(memory.failed) failed")
                }
            case "update":
                guard text.isEmpty else { throw ContextProblem.message("Use --person <name> to scope an update.") }
                let label = try person.map { try PeopleMemory.resolve($0) }
                let status = backend.map { AgentCLI.status($0) }
                try SemanticIndex.refresh()
                let report = try await ContextProcessor.update(person: label, limit: limit ?? 8, retry: retry, backend: status, selectedSources: selectedSources.isEmpty ? nil : selectedSources, progress: { message in
                    FileHandle.standardError.write(Data((message + "\n").utf8))
                })
                try SemanticIndex.refresh()
                if jsonOutput { print(try json(report)) }
                else { print("\(report.processed) parts processed · \(report.summaries) summaries · \(report.pending) pending · \(report.failed) failed") }
                return report.failed == 0 ? 0 : 1
            case "enrol", "enroll":
                guard value == "on" || value == "off" else { throw ContextProblem.message("Use context enrol on|off.") }
                try MemoryPreferences.enrolNewPeople(value == "on", root: Library.root)
                let executor = await MainActor.run { ContextService.deviceID }
                let chosen = ContextModel.chosen()
                let model = chosen.map { MemoryPreferences.Model(provider: $0.key, model: ContextModel.model($0), name: ContextModel.description($0, model: ContextModel.model($0)), executor: executor) }
                // Turning it on enrols the people who are already here, not
                // only the ones who arrive next. Otherwise the answer to "yes,
                // remember the people I talk to" is a library that goes on
                // knowing nothing about everybody already in it.
                let added = value == "on" ? ContextEnrolment.sync(ContextSources.all(), model: model) : 0
                if value == "on" && model == nil {
                    print("New people will be remembered once a model is chosen. Run listen endpoint or choose one in Settings, Ask.")
                } else if value == "on" {
                    print("New people are remembered automatically. \(added) \(added == 1 ? "person" : "people") enrolled now.")
                } else {
                    print("New people stay off. People already enrolled are unchanged; use context auto off --person to stop one.")
                }
            case "auto":
                guard value == "on" || value == "off" else { throw ContextProblem.message("Use context auto on|off.") }
                if let person {
                    let label = try PeopleMemory.resolve(person)
                    let id = MemoryPreferences.personID(label, root: Library.root)
                    if value == "on" {
                        let sources = Set(ContextSources.all().filter { $0.people.contains(label) && $0.extractable }.map(\.id))
                        try MemoryPreferences.select(sources, known: sources, person: id, root: Library.root)
                    }
                    let executor = await MainActor.run { ContextService.deviceID }
                    let chosen = ContextModel.chosen()
                    let model = chosen.map { MemoryPreferences.Model(provider: $0.key, model: ContextModel.model($0), name: ContextModel.description($0, model: ContextModel.model($0)), executor: executor) }
                    try MemoryPreferences.automatic(value == "on", person: id, model: model, root: Library.root)
                    print("Automatic briefs for \(label): \(value)")
                } else {
                    Settings.peopleContextEnabled = value == "on"
                    print("Automatic work on this Mac: \(value). Only individually enabled people may be processed.")
                }
            case "note":
                guard let person else { throw ContextProblem.message("Use context note --person <name> <text>.") }
                let label = try PeopleMemory.resolve(person)
                let note = try Notes.createPersonNote(value, person: label, excluded: excluded)
                print(note.slug)
            case "forget":
                guard let person, text.isEmpty else { throw ContextProblem.message("Use context forget --person <name>.") }
                let label = try PeopleMemory.resolve(person)
                try MemoryPreferences.deleteMemory(person: MemoryPreferences.personID(label, root: Library.root), root: Library.root)
                try SemanticIndex.refresh()
                print("Generated memory deleted. Notes and recordings retained; automatic briefs are off.")
            case "suggestions", "suggest":
                // The same three shapes `listen dictionary suggestions` has, for
                // the same reason: a worklist is only worth keeping if acting on
                // it is one command, and the two lists should not be two ideas
                // of what a worklist is. `--accept` and `--dismiss` are parsed
                // with every other option above.
                guard text.isEmpty else {
                    throw ContextProblem.message(
                        "Use context suggestions [--accept <claim-id>] [--dismiss <claim-id>].")
                }
                if let id = refuse {
                    ContextSuggestions.dismiss(id)
                    print("Dismissed. It will not be offered again.")
                } else if let id = accept {
                    guard let one = ContextSuggestions.find(id) else {
                        throw ContextProblem.message("No suggestion for \(id).")
                    }
                    try ContextSuggestions.accept(one)
                    print("Corrected. \(one.entityName): \(one.text)")
                } else {
                    let waiting = ContextSuggestions.pending()
                    if jsonOutput {
                        print(try json(waiting))
                    } else if waiting.isEmpty {
                        print("Nothing suggested. An agent proposes these when it "
                              + "reads a claim that disagrees with its own source.")
                    } else {
                        for one in waiting {
                            print("\(one.claim) · \(one.entityName)")
                            print("  now: \(one.was)")
                            print("  ->:  \(one.text)")
                            print("  why: \(one.why)")
                        }
                        print("")
                        print("`--accept <claim-id>` applies one, "
                              + "`--dismiss <claim-id>` stops it being offered.")
                    }
                }
            case "dismiss":
                guard text.count == 1, value.count == 64, value.allSatisfy(\.isHexDigit) else {
                    throw ContextProblem.message("context dismiss needs a claim ID from context person --json.")
                }
                try PeopleMemory.dismiss(value)
                try SemanticIndex.refresh()
                print("Claim hidden from person context and search.")
            case "restore", "pin", "unpin", "correct":
                guard let id = text.first, id.count == 64, id.allSatisfy(\.isHexDigit) else {
                    throw ContextProblem.message("Use a claim ID from person context.")
                }
                if command == "correct" {
                    guard text.count > 1 else { throw ContextProblem.message("Supply the corrected text.") }
                    try ContextStore.override(id: id, replacement: text.dropFirst().joined(separator: " "))
                } else if command == "restore" { try ContextStore.override(id: id, hidden: false) }
                else { try ContextStore.override(id: id, pinned: command == "pin") }
                try SemanticIndex.refresh()
                print("Detail updated.")
            case "entities":
                let entities = try ContextRetrieval.listedEntities()
                if jsonOutput { print(try json(entities)) }
                else { for entity in entities { print("\(entity.id) · \(entity.kind) · \(entity.name)") } }
            case "alias":
                guard let id = text.first, text.count > 1 else { throw ContextProblem.message("Use context alias <entity-id> <alias>.") }
                try ContextLedger.alias(text.dropFirst().joined(separator: " "), entity: id, db: ContextStore.database())
                try ContextRetrieval.export()
                print("Alias saved.")
            case "jobs":
                print(try json(ContextStore.database().all(ContextJob.self, in: .jobs).values.sorted { $0.id < $1.id }))
            case "usage":
                print(try json(ContextBudget.today()))
            case "index":
                guard text.isEmpty else { throw ContextProblem.message("context index takes no arguments.") }
                print("\(try SemanticIndex.refresh()) search entries indexed locally.")
            case "embeddings":
                switch value {
                case "evaluate":
                    print(try await Task.detached(priority: .utility) { try MultilingualEmbedding.evaluate() }.value)
                case "status":
                    print(Settings.multilingualSearch ? "Multilingual search selected" : "Apple search selected")
                    print(MultilingualEmbedding.available ? "Multilingual model is downloaded" : "Multilingual model is not downloaded")
                case "download":
                    try await MultilingualEmbedding.download { message in
                        FileHandle.standardError.write(Data((message + "\n").utf8))
                    }
                    print("Multilingual model downloaded. Select it with context embeddings multilingual.")
                case "multilingual", "apple":
                    guard value == "apple" || MultilingualEmbedding.available else {
                        throw ContextProblem.message("First run context embeddings download.")
                    }
                    Settings.multilingualSearch = value == "multilingual"
                    let count = try await Task.detached(priority: .utility) { try SemanticIndex.refresh() }.value
                    print("\(count) entries indexed with \(value) embeddings on this Mac.")
                default: throw ContextProblem.message("Use context embeddings status|download|apple|multilingual.")
                }
            case "search":
                let result = try SemanticIndex.search(value, person: person, limit: limit ?? 12, asOf: asOf)
                if jsonOutput { print(try json(result)) }
                else {
                    for match in result.matches {
                        print("[\(match.kind), \(match.match)] \(match.text)")
                        print(match.evidence.map { "  \($0.date) \($0.marker)" }.joined(separator: "\n"))
                    }
                    if result.matches.isEmpty { print("No matching context.") }
                    if result.mode == "keyword" { print("No sentence embedding is available for this query's language; showing keyword matches.") }
                }
            default: throw ContextProblem.message("Unknown context command: \(command).\n\(usage)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }
}
