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
        case "help", "--help", "-h":
            print(usage)
            exit(0)
        case "--version", "-v":
            print(version)
            exit(0)
        case "calibrate":
            calibrate()
        case "mcp":
            fail("`listen \(command)` is not built yet (\(milestone[command] ?? "later")).")
        default:
            fail("unknown command `\(command)`. Try `listen help`.")
        }
    }

    private static let milestone = [
        "mcp": "milestone 8, CLI install and MCP",
    ]

    /// `listen calibrate`: the voiceprint threshold report.
    private static func calibrate() -> Never {
        guard let report = Calibrate.run() else {
            fail("not enough named voiceprints yet. Name speakers in at least two "
                 + "recordings, then run this again.")
        }
        Calibrate.print(report)
        exit(0)
    }

    private static var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        // Run from .xcbuild rather than the bundle and there is no Info.plist
        // to read. Say so instead of printing "listen (null)".
        guard let v else { return "listen (unbundled build)" }
        return "listen \(v)" + (b.map { " (build \($0))" } ?? "")
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
      calibrate                  voiceprint threshold report
      mcp                        stdio MCP server                 (milestone 8)

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
            for t in turns { print("[\(TranscriptFormat.stamp(t.start))] \(t.speaker): \(t.text)") }
        default:
            print("# \(recording.metadata.title)\n")
            print("\(recording.when)\n")
            for t in turns {
                print("**\(t.speaker)** · \(TranscriptFormat.stamp(t.start))\n\n\(t.text)\n")
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
            let transcript = try await Pipeline().run(recording) { log($0) }
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
