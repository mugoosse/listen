import Foundation

/// The `listen` command.
///
/// The same binary as the app, dispatched on arguments, so there is one code
/// path over the library rather than two that have to be kept agreeing. Modes
/// that are not built yet are listed and say which milestone they arrive in,
/// because a command that is missing entirely is indistinguishable from one
/// that is misspelled.
enum CLI {
    /// Subcommands that do something. Anything else that looks like a command
    /// is still handled here, so it can be told it is misspelled.
    private static let commands = [
        "record", "list", "show", "transcribe", "export", "label", "calibrate", "mcp",
        "import", "enroll", "sources", "people", "rename", "me",
        "help", "--help", "-h", "--version", "-v",
    ]

    /// True when this invocation is the CLI rather than the app.
    ///
    /// A bare word is always the CLI, including one we do not recognise:
    /// gating on the known list instead meant `listen bogus` silently launched
    /// the app and hung a terminal, which reads as the binary being broken
    /// rather than the command being wrong.
    ///
    /// Anything starting with `-` that is not one of ours falls through to
    /// AppKit on purpose. Launch services and Xcode pass their own flags
    /// (`-psn_0_…`, `-NSDocumentRevisionsDebugMode`), and refusing to start
    /// because of one would break launching the app entirely.
    static func wants(_ args: [String]) -> Bool {
        guard args.count > 1 else { return false }
        return commands.contains(args[1]) || !args[1].hasPrefix("-")
    }

    /// Runs the requested mode and exits. Never returns.
    static func run(_ args: [String]) async -> Never {
        let command = args.count > 1 ? args[1] : "help"
        let rest = Array(args.dropFirst(2))

        switch command {
        case "transcribe":
            await transcribe(rest)
        case "record":
            await record(rest)
        case "list":
            list(rest)
        case "show":
            show(rest)
        case "export":
            export(rest)
        case "label":
            label(rest)
        case "people":
            people(rest)
        case "rename":
            renamePerson(rest)
        case "me":
            me(rest)
        case "import":
            await importLegacy(rest)
        case "enroll":
            await enroll(rest)
        case "help", "--help", "-h":
            print(usage)
            exit(0)
        case "--version", "-v":
            print(version)
            exit(0)
        case "calibrate":
            calibrate()
        case "sources":
            sources()
        case "mcp":
            MCP.serve()
        default:
            fail("unknown command `\(command)`. Try `listen help`.")
        }
    }

    /// `listen calibrate`: the voiceprint threshold report.
    private static func calibrate() -> Never {
        guard let report = Calibrate.run() else {
            fail("not enough named voiceprints yet. Name speakers in at least two "
                 + "recordings, then run this again.")
        }
        Calibrate.print(report)
        exit(0)
    }

    /// `listen sources`: what meeting detection can see right now.
    ///
    /// Detection has no other way to be checked. It fires on a state inside
    /// Core Audio that lasts as long as a call does and leaves nothing behind,
    /// so "it did not offer to record my meeting" is otherwise unanswerable:
    /// the rule may not have matched, the app may be in the skip list, or the
    /// process list may not be readable at all. This prints all three.
    ///
    /// Run it during a call, which is the only time it says anything.
    private static func sources() -> Never {
        let processes = MeetingDetector.report()
        let skipped = Settings.skippedBundleIDs
        print("audio processes: \(processes.count)")
        print("")
        print("  in  out  pid      bundle")
        for p in processes.sorted(by: { ($0.bundleID ?? "") < ($1.bundleID ?? "") }) {
            // Everything is listed, including the processes the rule ignores,
            // because the interesting case is usually one that should have
            // matched and did not.
            let mark = p.input && p.output ? "*" : " "
            print(String(format: "%@  %@   %@   %-7@  %@",
                         mark,
                         p.input ? "y" : "-",
                         p.output ? "y" : "-",
                         p.pid.map(String.init) ?? "?",
                         p.bundleID ?? "(none)"))
        }

        let callers = MeetingDetector.activeCallers()
        print("")
        if callers.isEmpty {
            print("nothing looks like a call. Run this during one.")
        } else {
            for id in callers {
                print(skipped.contains(id) ? "on a call, skipped: \(id)"
                                           : "on a call: \(id)")
            }
        }
        if !skipped.isEmpty {
            print("")
            print("skip list: " + skipped.sorted().joined(separator: ", "))
        }
        print("")
        print(Settings.autoDetectMeetings
              ? "detection is on."
              : "detection is off, so none of this would start a recording.")
        exit(0)
    }

    private static var version: String {
        // Resolved through AppInfo rather than Bundle.main, because the
        // installed command is a symlink and Bundle.main follows the path it
        // was launched by, not the binary it landed on.
        guard let v = AppInfo.version else { return "listen (unbundled build)" }
        return "listen \(v)" + (AppInfo.build.map { " (build \($0))" } ?? "")
    }

    private static let usage = """
    listen: local meeting recorder, transcriber and speaker labeller.

    usage: listen <command> [options]

      transcribe <file|id>       transcribe a file, or a whole recording
      record [--seconds N]       capture until stopped, or for N seconds
      list [--limit N] [--json]  recordings as a table
      show <id>                  metadata and transcript
      export <id> [--format]     write a transcript out
      label <id> <speaker> ...   name, merge or discard a speaker
      people [<name>]            who is in the library, or where one person is
      rename <name> <new name>   rename one person in every recording
      me [<name> | --clear]      what the microphone track is called on screen
      import <path>              bring in a meet_transcriptions library
      enroll [<id>…] [--force]   re-derive voiceprints for named speakers
      calibrate                  voiceprint threshold report
      sources                    what meeting detection sees, run during a call
      mcp                        stdio MCP server, read-only

    import options:
      --dry-run                  list what would be imported, copy nothing
      --replace                  re-import recordings already in the library

    label options:
      <name>                     name the speaker
      --merge-into <speaker>     reassign them onto another speaker
      --discard                  drop their segments

    transcribe options:
      --format md|json|txt       default md. json carries the timings.
      --model v2|v3              default v2, or whatever Settings holds.
      --diarize                  label speakers in a bare audio file.
                                 Implied when the argument is a recording.

    Running `listen` with no command starts the app.
    """

    // -----------------------------------------------------------------------

    /// `listen transcribe <file>`.
    ///
    /// The debugging escape hatch as much as a feature: it needs no
    /// permissions, so it separates a model problem from a capture problem
    /// before anyone touches UI code.
    private static func transcribe(_ args: [String]) async -> Never {
        var path: String?
        var format = "md"
        var choice = Settings.model
        var diarize = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--diarize":
                diarize = true
            case "--format":
                i += 1
                guard i < args.count else { fail("--format needs a value: md, json or txt") }
                format = args[i]
                guard ["md", "json", "txt"].contains(format) else {
                    fail("unknown format `\(format)`. Use md, json or txt.")
                }
            case "--model":
                i += 1
                guard i < args.count else { fail("--model needs a value: v2 or v3") }
                guard let m = ModelChoice.named(args[i]) else {
                    fail("unknown model `\(args[i])`. Use v2 or v3.")
                }
                choice = m
            case let other where other.hasPrefix("-"):
                fail("unknown option `\(other)`. Try `listen help`.")
            default:
                guard path == nil else { fail("transcribe takes one file.") }
                path = args[i]
            }
            i += 1
        }

        guard let path else { fail("transcribe needs a file. Try `listen help`.") }

        // A recording id or folder runs the whole two-track pipeline instead:
        // diarize the system track, label the mic track as the user, merge. A
        // bare audio file cannot take that path because it has no track split.
        if let recording = Recording.find(path) ?? Self.recordingFolder(path) {
            await transcribeRecording(recording, format: format, choice: choice)
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("no such file or recording: \(url.path)")
        }

        if diarize {
            await transcribeDiarized(url, format: format, choice: choice)
        }

        let asr = ASR()
        do {
            let t0 = Date()
            try await asr.load(choice) { log($0) }
            let loaded = Date()
            let transcript = try await asr.transcribe(url)
            let done = Date()

            // Timings on stderr so the transcript on stdout stays pipeable.
            log(String(format: "load %.1fs, transcribe %.1fs for %.0fs of audio (%.1fx)",
                       loaded.timeIntervalSince(t0),
                       done.timeIntervalSince(loaded),
                       transcript.duration,
                       transcript.duration / max(done.timeIntervalSince(loaded), 0.001)))

            // Section 4.4 assigns each word to the overlapping speaker turn, so
            // the absence of word timings is a finding, not a detail. Say it
            // every run rather than leaving it in a document: this is the thing
            // that decides whether milestone 3 can split a segment where the
            // speaker changes mid-sentence.
            if !transcript.hasWordTimings {
                log("no word timings: mlx-audio exposes sentence segments only."
                    + " See CLAUDE.md, word timings.")
            }

            switch format {
            case "json": print(try TranscriptFormat.json(transcript))
            case "txt":  print(TranscriptFormat.plain(transcript))
            default:     print(TranscriptFormat.markdown(transcript))
            }
            exit(0)
        } catch {
            fail("\(error.localizedDescription)")
        }
    }

    // MARK: - Library

    /// `listen list [--limit N] [--json]`.
    private static func list(_ args: [String]) -> Never {
        var limit = Int.max
        var asJSON = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--limit":
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else {
                    fail("--limit needs a positive number")
                }
                limit = n
            case "--json": asJSON = true
            default: fail("unknown option `\(args[i])`. Try `listen help`.")
            }
            i += 1
        }

        let recordings = Array(Recording.all().prefix(limit))
        if asJSON {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = (try? enc.encode(recordings.map(\.metadata))) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "[]")
            exit(0)
        }

        guard !recordings.isEmpty else {
            log("no recordings yet. `listen record` makes one.")
            exit(0)
        }
        // Pad to the widest id so the columns line up without a table library.
        let width = recordings.map(\.id.count).max() ?? 0
        for r in recordings {
            let state = r.metadata.stateValue == .done ? "" : "  \(r.metadata.state)"
            print("\(r.id.padding(toLength: width, withPad: " ", startingAt: 0))  "
                  + "\(r.lengthText.isEmpty ? "-" : r.lengthText)  \(r.metadata.title)\(state)")
        }
        exit(0)
    }

    /// `listen show <id>`.
    private static func show(_ args: [String]) -> Never {
        guard let id = args.first else { fail("show needs a recording id.") }
        guard let recording = Recording.find(id) else { fail("no recording `\(id)`.") }

        print(recording.metadata.title)
        print(recording.when + (recording.lengthText.isEmpty
                                ? "" : " · " + recording.lengthText))
        let speakers = recording.speakers
        if !speakers.isEmpty { print("speakers: " + speakers.joined(separator: ", ")) }
        print("")

        let turns = recording.storedTurns
        guard !turns.isEmpty else {
            print(recording.hasTranscript ? "(no speech)" : "(not transcribed yet)")
            exit(0)
        }
        for t in turns {
            print("[\(TranscriptFormat.stamp(t.start))] \(t.speaker): \(t.text)")
        }
        exit(0)
    }

    /// `listen export <id> [--format md|json|txt]`.
    private static func export(_ args: [String]) -> Never {
        var id: String?
        var format = "md"
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--format":
                i += 1
                guard i < args.count, ["md", "json", "txt"].contains(args[i]) else {
                    fail("--format takes md, json or txt")
                }
                format = args[i]
            case let other where other.hasPrefix("-"):
                fail("unknown option `\(other)`. Try `listen help`.")
            default:
                guard id == nil else { fail("export takes one recording.") }
                id = args[i]
            }
            i += 1
        }
        guard let id else { fail("export needs a recording id.") }
        guard let recording = Recording.find(id) else { fail("no recording `\(id)`.") }
        let turns = recording.storedTurns

        switch format {
        case "json":
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(data: (try? enc.encode(turns)) ?? Data(), encoding: .utf8) ?? "[]")
        case "txt":
            // The written-out forms are for reading, so they say "Speaker A"
            // and whatever the user calls themselves, the same as the window's
            // own export. `show` and `label` keep the on-disk labels, because
            // those are the strings you pass back in.
            for t in turns {
                print("[\(TranscriptFormat.stamp(t.start))] "
                      + "\(SpeakerName.display(t.speaker)): \(t.text)")
            }
        default:
            print("# \(recording.metadata.title)\n")
            print("\(recording.when)\n")
            for t in turns {
                print("**\(SpeakerName.display(t.speaker))** · "
                      + "\(TranscriptFormat.stamp(t.start))\n\n\(t.text)\n")
            }
        }
        exit(0)
    }

    /// `listen label <id> <speaker> [<name> | --merge-into X | --discard]`.
    ///
    /// The same `TranscriptEditor` calls the window makes, so this is a real
    /// exercise of that path rather than a parallel implementation. It is also
    /// how speaker edits get verified, there being no test target.
    private static func label(_ args: [String]) -> Never {
        guard args.count >= 2 else {
            fail("label needs a recording and a speaker. Try `listen help`.")
        }
        guard let recording = Recording.find(args[0]) else { fail("no recording `\(args[0])`.") }
        let speaker = args[1]
        guard recording.speakers.contains(speaker) else {
            fail("no speaker `\(speaker)` in \(recording.id). "
                 + "Present: \(recording.speakers.joined(separator: ", ")).")
        }

        let rest = Array(args.dropFirst(2))
        let edit: TranscriptEditor.Edit
        switch rest.first {
        case "--discard":
            edit = .discard(speaker)
        case "--merge-into":
            guard rest.count >= 2 else { fail("--merge-into needs a speaker") }
            guard recording.speakers.contains(rest[1]) else {
                fail("no speaker `\(rest[1])` to merge into.")
            }
            edit = .merge(speaker, into: rest[1])
        case .some(let name) where !name.hasPrefix("-"):
            edit = .rename(speaker, to: name)
        default:
            fail("label needs a name, --merge-into <speaker>, or --discard.")
        }

        guard TranscriptEditor.apply(edit, to: recording) else {
            fail("\(recording.id) has no transcript to edit yet.")
        }
        guard let updated = Recording.find(recording.id) else { exit(0) }
        log("speakers now: \(updated.speakers.joined(separator: ", "))")
        log("state: \(updated.metadata.state)")
        exit(0)
    }

    // MARK: - People

    /// `listen people [<name>]`: who is in the library, or where one person is.
    private static func people(_ args: [String]) -> Never {
        var name: String?
        for arg in args {
            guard !arg.hasPrefix("-") else {
                fail("unknown option `\(arg)`. Try `listen help`.")
            }
            // Joined rather than refused, so an unquoted `listen people Anna
            // Chen` finds her instead of complaining about the surname.
            name = [name, arg].compactMap { $0 }.joined(separator: " ")
        }

        if let name {
            guard let person = People.findByDisplayName(name) else {
                fail("nobody called `\(name)`. `listen people` lists everyone.")
            }
            print("\(person.display)  \(person.summary)")
            for recording in person.recordings {
                print("  \(recording.id)  \(recording.metadata.title)")
            }
            exit(0)
        }

        let everyone = People.all()
        guard !everyone.isEmpty else {
            log("nobody is named yet. `listen label <id> <speaker> <name>` names one.")
            exit(0)
        }
        // The on-disk label follows the name whenever the two differ, which is
        // only you and only once you have chosen a name. Without it a library
        // that already knows an "Emily" by name shows two identical rows.
        let labelled = everyone.map {
            ($0.display + ($0.display == $0.label ? "" : " (\($0.label))"), $0.summary)
        }
        let width = labelled.map(\.0.count).max() ?? 0
        for (name, summary) in labelled {
            print(name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + summary)
        }
        exit(0)
    }

    /// `listen rename <name> <new name>`: one person, everywhere at once.
    ///
    /// The window's own path, through `People.rename` and therefore through
    /// `TranscriptEditor`, for the same reason `listen label` exists: this is
    /// the only operation in the app that edits many recordings at once, and it
    /// must not be a second implementation of the one that edits one.
    private static func renamePerson(_ args: [String]) -> Never {
        guard args.count >= 2 else {
            fail("rename needs a person and a new name. Try `listen help`.")
        }
        guard let person = People.findByDisplayName(args[0]) else {
            fail("nobody called `\(args[0])`. `listen people` lists everyone.")
        }
        if person.isYou {
            fail("`\(SpeakerName.you)` is the microphone track rather than a name. "
                 + "`listen me <name>` sets what you are called.")
        }
        let name = args.dropFirst().joined(separator: " ")
        if let problem = People.check(name) { fail(problem.localizedDescription) }

        // Said before it happens, not after: nothing in the result would show
        // that two people had become one.
        let collisions = People.collisions(renaming: person.label, to: name)
        if !collisions.isEmpty {
            log("\(collisions.count) recording(s) already have a \(name). "
                + "The two become one person there.")
        }

        let changed = People.rename(person.label, to: name)
        guard !changed.isEmpty else { fail("nothing was changed.") }
        print("renamed \(person.display) to \(name) in \(changed.count) recording(s)")
        for id in changed { print("  \(id)") }
        exit(0)
    }

    /// `listen me [<name> | --clear]`: what the microphone track is called.
    ///
    /// A preference, not an edit. The transcripts keep saying `Me` and this is
    /// resolved on the way to the screen, so it applies to every recording ever
    /// made and changing it again costs nothing.
    private static func me(_ args: [String]) -> Never {
        guard let first = args.first else {
            print(Settings.userName ?? SpeakerName.you)
            if Settings.userName == nil {
                log("the microphone track is shown as `\(SpeakerName.you)`. "
                    + "`listen me <name>` changes that.")
            }
            exit(0)
        }
        if first == "--clear" {
            Settings.userName = nil
            print(SpeakerName.you)
            exit(0)
        }
        guard !first.hasPrefix("-") else {
            fail("unknown option `\(first)`. Try `listen help`.")
        }
        let chosen = args.joined(separator: " ")
        Settings.userName = chosen
        print(SpeakerName.display(SpeakerName.you))
        // Both can exist: an imported recording was labelled with your name by
        // hand, and the microphone track is `Me`. They stay two people, and the
        // list is unreadable if nobody says why there are two of you in it.
        if let other = People.find(chosen), !other.isYou {
            log("there is already a \(chosen) in the library (\(other.summary)), "
                + "named by hand rather than recorded on your microphone. "
                + "They stay separate.")
        }
        exit(0)
    }

    /// `listen enroll`: build voiceprints for recordings that have names but no
    /// embeddings, which is every imported one.
    private static func enroll(_ args: [String]) async -> Never {
        var ids: [String] = []
        var force = false
        for arg in args {
            if arg == "--force" { force = true }
            else if arg.hasPrefix("-") { fail("unknown option `\(arg)`. Try `listen help`.") }
            else { ids.append(arg) }
        }

        // Naming ids explicitly bypasses the "no voiceprints yet" filter, so a
        // recording that enrolled badly can be redone without deleting its
        // sidecar by hand.
        var candidates = ids.isEmpty ? Enroll.candidates()
                                     : ids.compactMap { Recording.find($0) }
        if force, ids.isEmpty { candidates = Enroll.forceCandidates() }
        if !ids.isEmpty, candidates.count != ids.count {
            fail("no recording matching one of: \(ids.joined(separator: ", "))")
        }
        guard !candidates.isEmpty else {
            log("nothing to enrol: every recording with named speakers already has "
                + "voiceprints.")
            exit(0)
        }
        log("enrolling \(candidates.count) recording(s)")

        let enroller = Enroll()
        var people: [String: Double] = [:]
        for recording in candidates {
            do {
                let result = try await enroller.run(recording) { log($0) }
                for (name, seconds) in result.named { people[name, default: 0] += seconds }
                let summary = result.named.keys.sorted().joined(separator: ", ")
                print("\(recording.id)  \(summary.isEmpty ? "no named voice matched" : summary)"
                      + (result.unmatched > 0 ? "  (\(result.unmatched) unmatched)" : ""))
            } catch {
                log("\(recording.id): \(error.localizedDescription)")
            }
        }
        log("voice bank now holds \(people.count) people")
        log("run `listen calibrate` to check the thresholds against real voices")
        exit(0)
    }

    /// `listen import <path> [--dry-run]`.
    private static func importLegacy(_ args: [String]) async -> Never {
        var path: String?
        var dryRun = false
        var replace = false
        for arg in args {
            switch arg {
            case "--dry-run": dryRun = true
            case "--replace": replace = true
            case let other where other.hasPrefix("-"):
                fail("unknown option `\(other)`. Try `listen help`.")
            default:
                guard path == nil else { fail("import takes one path.") }
                path = arg
            }
        }
        guard let path else {
            fail("import needs the path to a meet_transcriptions checkout.")
        }
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        let candidates = LegacyImport.scan(root)
        guard !candidates.isEmpty else {
            fail("nothing importable under \(root.path). Expected a recordings/ folder.")
        }

        let withTranscript = candidates.filter(\.hasTranscript)
        let named = candidates.reduce(0) { $0 + $1.namedCount }
        log("found \(candidates.count) recordings, \(withTranscript.count) transcribed, "
            + "\(named) named speakers")

        do {
            let outcome = try await LegacyImport.run(candidates, dryRun: dryRun,
                                                     replace: replace)
            for id in outcome.imported {
                let c = candidates.first { $0.id == id }
                print("\(dryRun ? "would import" : "imported") \(id)  "
                      + "\(c?.hasTranscript == true ? "with transcript" : "audio only")"
                      + (c.map { $0.names.isEmpty ? "" : "  (\($0.names.values.sorted().joined(separator: ", ")))" } ?? ""))
            }
            for id in outcome.skipped { log("already in the library, skipped: \(id)") }
            for (id, why) in outcome.failed { log("failed \(id): \(why)") }
            log("\(dryRun ? "would copy" : "copied") "
                + ModelChoice.humanBytes(outcome.bytes))

            if !dryRun, !outcome.imported.isEmpty {
                // The pyannote voiceprints are deliberately left behind: they
                // are a different embedding space from FluidAudio's and would
                // produce confident nonsense in the sounds-like ranking. The
                // names came across, so re-deriving is the way to get a real
                // voice bank out of them.
                log("voiceprints were not imported: they are pyannote vectors and "
                    + "Listen uses FluidAudio. Run `listen enroll` to re-derive them "
                    + "from the audio, keeping the names.")
            }
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// A path that is a recording folder, so `transcribe ./staging/<id>` works.
    private static func recordingFolder(_ path: String) -> Recording? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return Recording.load(url)
    }

    /// The two-track pipeline over a stored recording.
    private static func transcribeRecording(_ recording: Recording, format: String,
                                            choice: ModelChoice) async -> Never {
        Settings.model = choice
        do {
            let t0 = Date()
            var updated = recording
            let transcript = try await Pipeline().run(recording) { log($0) }
            // The same bookkeeping the queue does, through the same call, so
            // the two cannot come to different conclusions about a recording
            // they both just transcribed.
            updated.markTranscribed(transcript)
            log(String(format: "%.1fs for %.0fs of audio", Date().timeIntervalSince(t0),
                       transcript.duration))
            log(transcript.cleanup.isEmpty ? "cleanup fired: never"
                                           : "cleanup fired: \(transcript.cleanup)")
            log("wrote transcript.json and turns.json")

            switch format {
            case "json":
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(data: try enc.encode(transcript), encoding: .utf8) ?? "{}")
            case "txt":
                for t in Merge.turns(from: transcript.segments) {
                    print("[\(TranscriptFormat.stamp(t.start))] \(t.speaker): \(t.text)")
                }
            default:
                for t in Merge.turns(from: transcript.segments) {
                    print("**\(t.speaker)** · \(TranscriptFormat.stamp(t.start))\n\n\(t.text)\n")
                }
            }
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// `listen transcribe <file> --diarize`: the whole pipeline over one file.
    private static func transcribeDiarized(_ url: URL, format: String,
                                           choice: ModelChoice) async -> Never {
        Settings.model = choice
        let pipeline = Pipeline()
        do {
            let t0 = Date()
            let transcript = try await pipeline.runFile(url) { log($0) }
            log(String(format: "%.1fs for %.0fs of audio", Date().timeIntervalSince(t0),
                       transcript.duration))
            if !transcript.wordLevel {
                log("segment-level speaker assignment: no word timings available."
                    + " See CLAUDE.md, word timings.")
            }
            // Report whether the Whisper-era cleanup did anything, so the
            // question of deleting it is answered with numbers.
            log(transcript.cleanup.isEmpty ? "cleanup fired: never"
                                           : "cleanup fired: \(transcript.cleanup)")

            switch format {
            case "json":
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(data: try enc.encode(transcript), encoding: .utf8) ?? "{}")
            case "txt":
                for t in Merge.turns(from: transcript.segments) {
                    print("[\(TranscriptFormat.stamp(t.start))] \(t.speaker): \(t.text)")
                }
            default:
                for t in Merge.turns(from: transcript.segments) {
                    print("**\(t.speaker)** · \(TranscriptFormat.stamp(t.start))\n\n\(t.text)\n")
                }
            }
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// `listen record [--seconds N]`.
    ///
    /// Captures in this process until interrupted, or for a fixed time. This is
    /// the capture equivalent of `transcribe`: it exercises the process tap and
    /// the microphone with no UI in the way, which is the only sane way to
    /// debug a tap that has to survive an hour.
    ///
    /// Note this is not SPEC 6's `record --stop`. Stopping a capture running
    /// inside the *app* from a second process needs IPC that does not exist
    /// yet; until it does, saying so is better than shipping a `--stop` that
    /// silently does nothing.
    private static func record(_ args: [String]) async -> Never {
        var seconds: Double?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--seconds":
                i += 1
                guard i < args.count, let v = Double(args[i]), v > 0 else {
                    fail("--seconds needs a positive number")
                }
                seconds = v
            case "--stop":
                fail("`--stop` needs the app running and is not built yet. "
                     + "Use `listen record --seconds N`, or Ctrl-C.")
            default:
                fail("unknown option `\(args[i])`. Try `listen help`.")
            }
            i += 1
        }

        let capture = await Capture.shared
        let recording: Recording
        do {
            recording = try await capture.start(source: "cli")
        } catch {
            fail(error.localizedDescription)
        }
        for warning in await capture.warnings { log(warning) }
        log("recording to \(recording.folder.path)")
        log(seconds.map { "stopping after \(Int($0))s" } ?? "press Ctrl-C to stop")

        // Handle Ctrl-C so the WAV headers are finalised and the tap and
        // aggregate device are destroyed. Killed without this they survive in
        // Core Audio, and the next run adds another.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler {
            Task { @MainActor in finish(capture.stop()) }
        }
        interrupt.resume()

        if let seconds {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                finish(capture.stop())
            }
        }

        // Keep the process alive, pumping the run loop so the main-actor tasks
        // and the signal source above get to run.
        //
        // A bare `RunLoop.current.run()` does not work: it returns immediately
        // when the run loop has no input sources attached, and the process then
        // fell straight through to exit. The symptom was a recording that
        // stopped after 80 milliseconds with a system track containing nothing
        // but a WAV header, which looks exactly like a tap that does not work.
        pumpForever()
    }

    /// Blocks the main thread, servicing the run loop.
    ///
    /// Deliberately not async. `RunLoop.current` and `run(until:)` are both
    /// unavailable from an async context and are a hard error under Swift 6,
    /// so the loop lives in a synchronous function that the async one calls
    /// and never returns from.
    private static func pumpForever() -> Never {
        while true {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
    }

    @MainActor
    private static func finish(_ recording: Recording?) -> Never {
        guard let recording else { exit(1) }
        let mic = recording.micURL, sys = recording.systemURL
        func report(_ label: String, _ url: URL) {
            let bytes = ((try? FileManager.default.attributesOfItem(
                atPath: url.path)[.size]) as? Int) ?? 0
            guard bytes > 44 else { log("\(label): nothing captured"); return }
            // 44 bytes of header, then Float32 mono at 16 kHz.
            log(String(format: "%@: %.1fs, %@", label, Double(bytes - 44) / 4 / SAMPLE_RATE,
                       ModelChoice.humanBytes(Int64(bytes))))
        }
        report("mic", mic)
        report("system", sys)
        // The folder, on stdout, so it composes: `listen transcribe $(listen record ...)`.
        print(recording.folder.path)
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        log(message)
        exit(1)
    }
}
