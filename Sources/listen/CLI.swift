import Foundation
import ListenKit

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
        "record", "list", "show", "transcribe", "export", "label", "title", "calibrate", "mcp",
        "import", "enroll", "sources", "dictionary", "people", "rename", "merge", "unname", "me", "edit",
        "calendar", "contacts", "notes", "tags", "ask", "sync", "backup", "activity", "forget",
        "audio",
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

    /// Start again as the real binary when we were launched through a symlink.
    ///
    /// The installed `listen` is a symlink in `~/.local/bin`, and `Bundle.main`
    /// is derived from the path the process was launched by rather than the
    /// binary it landed on. `AppInfo` already works around that for the version
    /// string, but a workaround only helps the code that remembers to use it,
    /// and **MLX does not**: `load_default_library` in mlx-swift's `device.cpp`
    /// tries five locations for `default.metallib`, and the only one that ever
    /// succeeds here is `NS::Bundle::allBundles()` reaching the main bundle's
    /// `resourceURL`, which is `Listen.app/Contents/Resources`. Launched through
    /// the symlink the main bundle is `~/.local/bin`, all five fail, and every
    /// command that loads a model dies with "Failed to load the default
    /// metallib".
    ///
    /// Measured on the shipped 0.9.0: the same binary on the same file
    /// transcribed fine at `/Applications/Listen.app/Contents/MacOS/Listen` and
    /// failed at `~/.local/bin/listen`, exiting 255. So `listen transcribe` had
    /// never once worked through the installed command, which is every use of it
    /// that follows the Developers pane's own instructions.
    ///
    /// It fails loudly, which is the one merciful part and worth not
    /// misremembering: an early reading here called it a silent exit 0, and that
    /// was a piped exit code being read (`… | tail` reports `tail`'s status).
    /// Check `$?` on the unpiped command when judging how bad a CLI failure is.
    ///
    /// Fixed at the root rather than by teaching MLX where to look, because the
    /// root is one line of process setup and there is no list of
    /// commands-that-load-a-model to keep in agreement with reality. Everything
    /// downstream, including `Settings`' bundle identifier, is simply correct
    /// afterwards.
    ///
    /// `execv` rather than spawning a child: the process is replaced, so stdin,
    /// stdout, the exit code and any signal handling belong to the real binary
    /// with nothing to forward. The environment carries over, which is how
    /// `LISTEN_LIBRARY` survives, and is also how the loop guard gets across.
    /// If the exec fails there is nothing to do but carry on and be no worse
    /// off than before.
    private static func reexecAsRealBinary() {
        // A binary that re-launches itself must be able to say it has already
        // done so, or a resolve that disagrees with itself is an exec loop.
        guard ProcessInfo.processInfo.environment["LISTEN_REEXEC"] == nil else { return }
        guard let launched = Bundle.main.executablePath, !launched.isEmpty else { return }
        let real = URL(fileURLWithPath: launched).resolvingSymlinksInPath().path
        guard real != launched else { return }

        setenv("LISTEN_REEXEC", "1", 1)
        // Built from the real path rather than by patching `CommandLine`'s copy,
        // so argv[0] agrees with the process image rather than with how the
        // command was typed, and there is no index to be wrong about. The
        // duplicated strings are never freed on purpose: either `execv` succeeds
        // and the address space goes with it, or it failed and a few bytes are
        // the least of it.
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(real)]
        argv += CommandLine.arguments.dropFirst().map { strdup($0) }
        argv.append(nil)
        execv(real, &argv)
    }

    /// Runs the requested mode and exits. Never returns.
    static func run(_ args: [String]) async -> Never {
        reexecAsRealBinary()
        let command = args.count > 1 ? args[1] : "help"
        let rest = Array(args.dropFirst(2))

        switch command {
        case "transcribe":
            await transcribe(rest)
        case "dictate":
            await dictate(rest)
        case "polish":
            await polish(rest)
        case "dictations":
            dictations(rest)
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
        case "title":
            title(rest)
        case "people":
            people(rest)
        case "rename":
            renamePerson(rest)
        case "merge":
            mergePeople(rest)
        case "unname":
            unnamePerson(rest)
        case "forget":
            forgetPerson(rest)
        case "activity":
            activity(rest)
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
        case "voices":
            voices(rest)
        case "sources":
            sources()
        case "calendar":
            calendar(rest)
        case "contacts":
            contacts(rest)
        case "dictionary":
            dictionary(rest)
        case "notes":
            notes(rest)
        case "tags":
            tags(rest)
        case "edit":
            edit(rest)
        case "mcp":
            MCP.serve()
        case "ask":
            ask(rest)
        case "provider":
            provider(rest)
        case "backup":
            // Prints rather than takes one, unless asked. Somebody running this
            // is usually checking whether the net is there, not asking for it
            // to be re-made.
            await MainActor.run {
                if rest.contains("--now") { Backups.runNow() }
                print(Backups.describe())
            }
            exit(0)
        case "sync":
            await SyncCLI.run(rest)
        case "audio":
            await AudioCLI.run(rest)
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

    /// `listen voices <id> [--apply]`: what the bank thinks of each unnamed
    /// speaker, and what it would do about it.
    ///
    /// Exists for the reason `listen calendar` and `listen sources` do. A name
    /// applied automatically leaves nothing behind to argue with: the losing
    /// candidates, the margin between them and the thresholds they were judged
    /// against are all gone by the time anybody wonders why a transcript says
    /// Marcia. This prints all three, and it is also the only way to see the
    /// scoring at all without transcribing something.
    ///
    /// `--apply` runs the same `VoiceBank.autoAssign` the pipeline runs, so a
    /// recording transcribed before this existed can be caught up without
    /// re-running an hour of audio.
    private static func voices(_ args: [String]) -> Never {
        var ids: [String] = []
        var apply = false
        for arg in args {
            if arg == "--apply" { apply = true }
            else if arg.hasPrefix("-") { fail("unknown option `\(arg)`. Try `listen help`.") }
            else { ids.append(arg) }
        }
        guard let first = ids.first, let recording = Recording.find(first) else {
            fail("voices needs a recording. `listen list` prints them.")
        }

        print(recording.id + "  " + recording.displayTitle)
        let automatic = Set(recording.metadata.auto_named ?? [])
        for speaker in recording.speakers.sorted() {
            let print_ = recording.voiceprints[speaker]
            var head = "  " + SpeakerName.display(speaker)
            if let p = print_ { head += String(format: "  (%.0fs of speech)", p.speech) }
            if automatic.contains(speaker) { head += "  [named by voice]" }
            print(head)

            guard let p = print_ else { print("      no voiceprint"); continue }
            guard p.isEvidence else {
                print("      under \(Int(Voiceprint.minimumSpeechForEvidence))s, "
                      + "too short to be an identity")
                continue
            }
            let ranked = VoiceBank.suggestions(for: speaker, in: recording)
            guard !ranked.isEmpty else {
                print(String(format: "      nobody above %+.2f", VoiceBank.matchThreshold))
                continue
            }
            for m in ranked {
                // Padded by hand. `String(format:)` ignores a width on `%@` on
                // this platform, so the columns silently collapse and the
                // numbers stop lining up, which is most of what a table is for.
                let name = m.name.padding(toLength: max(m.name.count, 20),
                                          withPad: " ", startingAt: 0)
                let how = m.confidence.label.lowercased()
                print("      " + name + "  "
                      + how.padding(toLength: max(how.count, 22), withPad: " ", startingAt: 0)
                      + String(format: "score %+.3f  margin %+.3f", m.score, m.margin)
                      + (m.autoAssignable ? "  -> would name automatically" : ""))
            }
        }
        print(String(format: "\njudged against: match %+.2f, likely %+.2f, "
                     + "certain %+.2f, margin %+.2f",
                     VoiceBank.matchThreshold, VoiceBank.strongThreshold,
                     VoiceBank.certainThreshold, VoiceBank.marginThreshold))

        if apply {
            let applied = VoiceBank.autoAssign(in: recording)
            print(applied.isEmpty
                  ? "\nnothing was sure enough to name."
                  : "\nnamed: " + applied.map { "\($0.speaker) -> \($0.name)" }
                      .joined(separator: ", "))
        }
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

        // Listen's own processes match the rule while somebody dictates, and
        // they are dropped before anything else in the app sees the list. Said
        // out loud here because this command is the only place that decision is
        // visible: without it, a copy of Listen sitting there with `* y y` and
        // no prompt on screen reads as detection being broken.
        let callers = MeetingDetector.activeCallers()
        let ours = processes.filter {
            $0.input && $0.output
                && $0.bundleID.map(MeetingDetector.parentBundleID) == AppInfo.bundleID
        }
        print("")
        if callers.isEmpty && ours.isEmpty {
            print("nothing looks like a call. Run this during one.")
        } else {
            for id in callers {
                print(skipped.contains(id) ? "on a call, skipped: \(id)"
                                           : "on a call: \(id)")
            }
            for p in ours {
                print("on a call by the rule, ignored because it is Listen: "
                      + "\(AppInfo.bundleID ?? "?") (pid \(p.pid.map(String.init) ?? "?"))")
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

    // MARK: - The calendar

    /// `listen calendar`: what EventKit can see, and how it maps onto recordings.
    ///
    /// This exists for the reason `listen sources` exists. Matching a recording
    /// to a meeting leaves nothing behind to inspect: the title lands silently,
    /// and "why is my meeting called that?" is otherwise unanswerable, because
    /// the candidate that won, the ones that lost and the window they were
    /// judged in are all gone by the time anybody looks.
    private static func calendar(_ args: [String]) -> Never {
        let rest = Array(args.dropFirst())
        switch args.first ?? "status" {
        case "status":   calendarStatus()
        case "events":   calendarEvents(rest)
        case "match":    calendarMatch(rest)
        case "backfill": calendarBackfill(rest)
        default:
            fail("unknown calendar subcommand `\(args[0])`. Try `listen help`.")
        }
    }

    private static func calendarStatus() -> Never {
        guard MeetingCalendar.isAuthorized else {
            if Permissions.calendarDenied {
                log("calendar access is denied. Settings → Permissions → Calendar, "
                    + "or System Settings → Privacy & Security → Calendars.")
            } else {
                log("calendar access has not been granted yet. Open Listen's Settings → "
                    + "Permissions and press Allow, which is the only place the system "
                    + "prompt can be raised from.")
            }
            exit(1)
        }

        let calendars = MeetingCalendar.calendars()
        print("calendars: \(calendars.count)")
        var source = ""
        for c in calendars {
            if c.source != source { print("\n  \(c.source)"); source = c.source }
            print("    \(c.title)")
        }

        // Today rather than a week, because the question this answers is "is it
        // seeing my calendar at all", and a day is enough to tell.
        let day = Foundation.Calendar.current.startOfDay(for: Date())
        let events = MeetingCalendar.events(from: day, to: day.addingTimeInterval(86400))
        print("\ntoday: \(events.count) event(s)")
        for e in events { print("  " + line(for: e)) }
        print("\nnaming recordings from the calendar is "
              + (Settings.nameFromCalendar ? "on." : "off."))
        exit(0)
    }

    private static func calendarEvents(_ args: [String]) -> Never {
        guard MeetingCalendar.isAuthorized else { fail("no calendar access.") }
        var days = 7
        var i = 0
        while i < args.count {
            if args[i] == "--days" {
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else {
                    fail("--days needs a positive number.")
                }
                days = n
            } else {
                fail("unknown option `\(args[i])`.")
            }
            i += 1
        }

        let now = Date()
        let events = MeetingCalendar.events(from: now, to: now.addingTimeInterval(
            Double(days) * 86400))
        guard !events.isEmpty else {
            log("nothing in the next \(days) day(s).")
            exit(0)
        }
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        var day = ""
        for e in events {
            let heading = f.string(from: e.start)
            if heading != day { print(day.isEmpty ? heading : "\n" + heading); day = heading }
            print("  " + line(for: e))
        }
        exit(0)
    }

    /// One line of an event, wherever it is printed.
    private static func line(for event: CalendarEvent) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let when = event.isAllDay ? "all day" : f.string(from: event.start)
        var out = String(format: "%-8@ %@", when as NSString, event.title as NSString)
        let people = event.people.compactMap { $0.is_me ? nil : ($0.bestName ?? $0.email) }
        if !people.isEmpty { out += "  (" + people.joined(separator: ", ") + ")" }
        // Said out loud rather than left implied. An all-day or declined event
        // is in the list and can never be matched, and somebody looking for
        // theirs deserves to know which of the two it is.
        if !event.couldBeAMeeting {
            out += event.isAllDay ? "  [all-day, never matched]"
                                  : "  [declined, never matched]"
        }
        return out
    }

    /// `listen calendar match <id>`: every candidate, and which one wins.
    private static func calendarMatch(_ args: [String]) -> Never {
        guard let id = args.first else { fail("match needs a recording id.") }
        guard let recording = Recording.find(id) else { fail("no recording `\(id)`.") }
        guard MeetingCalendar.isAuthorized else { fail("no calendar access.") }
        guard let start = recording.date else {
            fail("`\(id)` has no start time to match against.")
        }

        print("\(recording.displayTitle)")
        // The length, because it is half the question: the second rule matches
        // a meeting that began before this recording ended, so a report that
        // did not say how long it ran would not explain its own answer.
        print("started \(recording.when)"
              + (recording.lengthText.isEmpty ? "" : " · ran \(recording.lengthText)"))
        if let attached = recording.metadata.calendar_event_id {
            print("already attached to event \(attached)")
        }
        print("")

        let candidates = MeetingCalendar.candidates(for: start,
                                                    lasting: recording.metadata.duration)
        guard !candidates.isEmpty else {
            let minutes = Int(MeetingCalendar.window / 60)
            print("no event starts within \(minutes) minutes of this recording, "
                  + "and none started while it was running.")
            // The near misses, because "nothing matched" and "something matched
            // and lost" look identical from the outside and have different fixes.
            let near = MeetingCalendar.events(from: start.addingTimeInterval(-3600),
                                              to: start.addingTimeInterval(3600))
                .filter(\.couldBeAMeeting)
            if !near.isEmpty {
                print("\nwithin an hour, and therefore too far away:")
                for e in near { print("  " + offset(of: e, from: start) + "  " + e.title) }
            }
            exit(0)
        }

        for (i, e) in candidates.enumerated() {
            // Which rule found it. The two are not equally strong and the
            // second one reaches much further, so a match nobody expected
            // should say which one it came from rather than leaving the offset
            // to be reconciled with a window it plainly exceeds.
            let during = abs(e.start.timeIntervalSince(start)) > MeetingCalendar.window
                ? "  [began while recording]" : ""
            print("\(i == 0 ? "→" : " ") \(offset(of: e, from: start))  \(e.title)\(during)")
            print("    \(e.summary)")
            if let link = e.link { print("    \(link.absoluteString)") }
            for p in e.people {
                let who = p.bestName ?? p.email ?? "(unnamed)"
                let tags = [p.is_me ? "you" : nil,
                            p.is_organizer ? "organizer" : nil].compactMap { $0 }
                print("    · \(who)" + (p.email.map { " <\($0)>" } ?? "")
                      + (tags.isEmpty ? "" : "  [" + tags.joined(separator: ", ") + "]"))
            }
        }
        if candidates.count > 1 {
            print("\nthe first wins: nearest start, with the longer guest list "
                  + "breaking a tie.")
        }
        exit(0)
    }

    private static func offset(of event: CalendarEvent, from start: Date) -> String {
        let minutes = Int((event.start.timeIntervalSince(start) / 60).rounded())
        return String(format: "%+4dm", minutes)
    }

    /// `listen calendar backfill`: what the calendar would do to the library.
    ///
    /// A dry run unless `--apply` is given, and deliberately not something that
    /// happens at launch. Renaming eight recordings at once without being asked
    /// is exactly the surprise the rest of this app avoids.
    private static func calendarBackfill(_ args: [String]) -> Never {
        guard MeetingCalendar.isAuthorized else { fail("no calendar access.") }
        var apply = false
        var refresh = false
        for arg in args {
            switch arg {
            case "--apply":   apply = true
            case "--refresh": refresh = true
            default:          fail("unknown option `\(arg)`.")
            }
        }

        let library = Recording.all()
        var matched = 0, renamed = 0, keptOwnName = 0, alreadyAttached = 0
        var derived = 0, fromCalendar = 0, began = 0

        for recording in library.sorted(by: { $0.id < $1.id }) {
            if !refresh, recording.metadata.calendar_event_id != nil {
                alreadyAttached += 1
                continue
            }
            guard let event = MeetingCalendar.match(for: recording) else { continue }
            matched += 1
            // Counted separately, because the two rules are not equally strong
            // and this is where the weaker one is answerable for itself over a
            // whole library rather than one recording at a time.
            let during = recording.date.map {
                abs(event.start.timeIntervalSince($0)) > MeetingCalendar.window
            } ?? false
            if during { began += 1 }

            // Count where the attendee names would come from. This is the one
            // number in the feature that is not measured yet: how often an
            // address alone produces a name a human would accept.
            for p in event.people where !p.is_me {
                if p.name != nil { fromCalendar += 1 } else if p.bestName != nil { derived += 1 }
            }

            let how = during ? "  [began while recording]" : ""
            // The same question `attach` asks, asked the same way. This read
            // `isUntitled` while `attach` had moved on to `mayTitle`, so a
            // recording carrying a title `AutoTitle` derived was previewed as
            // "keeps its name" and then renamed by the line below it. A dry run
            // that disagrees with the apply is worse than no dry run, because it
            // is the thing somebody reads before saying yes.
            if recording.mayTitle(from: .calendar) {
                renamed += 1
                print(String(format: "  %@  %-28@ → %@%@", recording.id as NSString,
                             recording.displayTitle as NSString,
                             MeetingCalendar.title(from: event) as NSString,
                             how as NSString))
            } else {
                keptOwnName += 1
                print(String(format: "  %@  %-28@ (keeps its name; guest list attached)%@",
                             recording.id as NSString,
                             recording.displayTitle as NSString,
                             how as NSString))
            }
            if apply { MeetingCalendar.attach(to: recording, refresh: refresh) }
        }

        print("")
        print("\(library.count) recordings, \(matched) matched an event.")
        if began > 0 {
            print("  \(began) of them by a meeting that began while they ran")
        }
        print("  \(renamed) would be named from the calendar")
        print("  \(keptOwnName) keep the name they have")
        if alreadyAttached > 0 { print("  \(alreadyAttached) already attached, left alone") }
        print("attendee names: \(fromCalendar) from the invitation, "
              + "\(derived) derived from an address.")
        print(apply ? "\napplied." : "\nnothing was written. `--apply` does it.")
        exit(0)
    }

    // MARK: - Contacts

    /// `listen contacts`: which address belongs to whom.
    ///
    /// Needed for the reason `listen dictionary test` is needed. Whether an
    /// address resolves to a name, and which of the three sources answered, is
    /// not something anybody can work out by reading their own file: the book
    /// is consulted first, then what the invitation said, then a guess made
    /// from the address itself, and only the last of those is visible.
    private static func contacts(_ args: [String]) -> Never {
        let rest = Array(args.dropFirst())
        switch args.first ?? "list" {
        case "list":   contactsList()
        case "link":   contactsLink(rest)
        case "unlink": contactsUnlink(rest)
        case "test":   contactsTest(rest)
        case "note":   contactsNote(rest)
        default:
            fail("unknown contacts subcommand `\(args[0])`. Try `listen help`.")
        }
    }

    /// `listen contacts note <name> [text]`: what you know about somebody.
    ///
    /// The same write the person page makes, so the field is exercised without
    /// the window. With no text it prints what is there, which is also how you
    /// check that a note landed on the person you meant.
    private static func contactsNote(_ args: [String]) -> Never {
        guard let name = args.first else {
            fail("note needs a person. Try `listen contacts note \"Ryan\" \"CTO\"`.")
        }
        let existing = ContactBook.contact(name)
        let text = args.dropFirst().joined(separator: " ")
        guard !args.dropFirst().isEmpty else {
            let note = existing?.note ?? ""
            print(note.isEmpty ? "no note for \(name)" : note)
            exit(0)
        }
        guard People.findByDisplayName(name) != nil || existing != nil else {
            fail("nobody called `\(name)`. `listen people` lists everyone.")
        }
        ContactBook.set(Contact(name: name, emails: existing?.emails ?? [],
                                notes: text.isEmpty ? nil : text))
        print(text.isEmpty ? "note cleared for \(name)" : "\(name): \(text)")
        exit(0)
    }

    private static func contactsList() -> Never {
        let book = ContactBook.load()
        guard !book.isEmpty else {
            log("no addresses have been claimed yet. Naming a speaker from a calendar "
                + "suggestion files one, or `listen contacts link <email> <name>`.")
            exit(0)
        }
        let library = Recording.all()
        for contact in book {
            // How much is behind the name, so a contact filed against somebody
            // who is not actually in the library is visible rather than
            // plausible.
            let person = People.find(contact.name, in: library)
            let seen = person.map { " · " + $0.summary } ?? " · not in any recording"
            print(contact.name + seen)
            for email in contact.emails { print("    " + email) }
        }
        exit(0)
    }

    private static func contactsLink(_ args: [String]) -> Never {
        guard args.count >= 2 else { fail("link needs an address and a name.") }
        let email = args[0]
        let name = args.dropFirst().joined(separator: " ")
        guard email.contains("@") else { fail("`\(email)` is not an email address.") }
        if let problem = People.check(name) { fail(problem.localizedDescription) }

        if let held = ContactBook.name(for: email), held != name {
            // Said rather than done quietly. An address belongs to one person,
            // so this is a correction of an earlier claim and worth seeing.
            log("\(email) was \(held); it is now \(name).")
        }
        ContactBook.link(email, to: name)
        exit(0)
    }

    private static func contactsUnlink(_ args: [String]) -> Never {
        guard let email = args.first else { fail("unlink needs an address.") }
        guard ContactBook.unlink(email) else { fail("nothing here claims `\(email)`.") }
        log("forgot \(email).")
        exit(0)
    }

    /// `listen contacts test <email>`: which of the three sources would answer.
    private static func contactsTest(_ args: [String]) -> Never {
        guard let email = args.first else { fail("test needs an address.") }
        if let claimed = ContactBook.name(for: email) {
            print("\(claimed)  (claimed: somebody said so)")
        } else if let guessed = ContactBook.suggestedName(from: email) {
            print("\(guessed)  (guessed from the address, never applied on its own)")
        } else {
            print("no name. The address would be shown as it is.")
        }
        exit(0)
    }

    // MARK: - Correcting a transcript

    /// `listen edit <id> "<old sentence>" "<new sentence>"`.
    ///
    /// The same `TranscriptEditor.retext` the transcript pane's right-click
    /// menu uses, for the reason `listen label` exists: with no test target, a
    /// command that drives the exact code path the window drives is the only
    /// verification the write path gets.
    ///
    /// Matched on the old text rather than on a segment number, because a
    /// number is not something anybody has. It is also the identity the write
    /// itself checks, so the command cannot ask for an edit the editor would
    /// then refuse for a different reason than the one reported here.
    private static func edit(_ args: [String]) -> Never {
        guard args.count >= 3 else {
            fail("edit needs a recording, the sentence as it stands, and the replacement. "
                 + "Quote both.")
        }
        guard let recording = Recording.find(args[0]) else {
            fail("no recording `\(args[0])`.")
        }
        guard let transcript = recording.storedTranscript else {
            fail("\(recording.id) has no transcript to edit yet.")
        }

        let was = args[1].trimmingCharacters(in: .whitespacesAndNewlines)
        let now = args[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = transcript.segments.indices.filter {
            transcript.segments[$0].text
                .trimmingCharacters(in: .whitespacesAndNewlines) == was
        }
        guard !hits.isEmpty else {
            fail("no sentence in \(recording.id) reads exactly `\(was)`. "
                 + "`listen show \(recording.id)` prints them.")
        }
        // Ambiguity is reported rather than resolved. Picking the first of four
        // identical sentences would be a guess about which one the user meant,
        // and a wrong guess edits a different minute of the meeting.
        guard hits.count == 1 else {
            fail("\(hits.count) sentences read exactly that. Edit it in the window, "
                 + "where each one is in its own paragraph.")
        }

        guard TranscriptEditor.apply(.retext(segment: hits[0], was: was, to: now),
                                     to: recording) else {
            fail(now.isEmpty ? "a sentence cannot be emptied."
                             : "nothing to change: it already reads that way.")
        }
        log("\(recording.id): sentence \(hits[0]) rewritten")
        print(now)
        exit(0)
    }

    // MARK: - Tags

    /// `listen tags <sub>`: what the recordings are about.
    ///
    /// The same `Tags` the detail pane's strip and the MCP tools go through, for
    /// the reason `listen dictionary` shares the Dictionary pane's file: a
    /// second implementation agrees with the first right up until it does not,
    /// and there is no test target to catch the day it stops.
    private static func tags(_ args: [String]) -> Never {
        let rest = Array(args.dropFirst())
        switch args.first ?? "list" {
        case "list":   tagsList()
        case "add":    tagsAdd(rest)
        case "remove": tagsRemove(rest)
        case "rename": tagsRename(rest)
        case "delete": tagsDelete(rest)
        default:
            fail("unknown tags subcommand `\(args[0])`. Try `listen help`.")
        }
    }

    /// Every tag in the library, with how many recordings carry it.
    private static func tagsList() -> Never {
        let all = Tags.all()
        guard !all.isEmpty else {
            log("no tags yet. `listen tags add <id> <tag>` starts one.")
            exit(0)
        }
        // Pad to the widest name, which is the table style everywhere here.
        let width = all.map(\.name.count).max() ?? 0
        for tag in all {
            print(tag.name.padding(toLength: width, withPad: " ", startingAt: 0)
                  + "  \(tag.count)")
        }
        exit(0)
    }

    /// The recording and the tags a subcommand was given, or a refusal.
    private static func tagged(_ args: [String], verb: String) -> (Recording, [String]) {
        guard let id = args.first else {
            fail("\(verb) needs a recording id and at least one tag.")
        }
        guard let recording = Recording.find(id) else { fail("no recording `\(id)`.") }
        let names = Array(args.dropFirst())
        guard !names.isEmpty else {
            fail("\(verb) needs at least one tag. Give them one at a time, "
                 + "quoting any with a space in.")
        }
        return (recording, names)
    }

    private static func tagsAdd(_ args: [String]) -> Never {
        let (recording, names) = tagged(args, verb: "add")
        let before = Tags.of(recording)
        do {
            let after = try Tags.add(names, to: recording)
            print(after.joined(separator: ", "))
            let added = after.filter { name in !before.contains(name) }
            log(added.isEmpty
                ? "already tagged. Nothing changed."
                : "added \(added.joined(separator: ", ")) to \(recording.id).")
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }

    private static func tagsRemove(_ args: [String]) -> Never {
        let (recording, names) = tagged(args, verb: "remove")
        let before = Tags.of(recording)
        do {
            let after = try Tags.remove(names, from: recording)
            if !after.isEmpty { print(after.joined(separator: ", ")) }
            let gone = before.filter { name in !after.contains(name) }
            log(gone.isEmpty
                ? "not tagged with that. Nothing changed."
                : "removed \(gone.joined(separator: ", ")) from \(recording.id).")
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }

    private static func tagsRename(_ args: [String]) -> Never {
        guard args.count >= 2 else {
            fail("rename takes the tag and its new name. Quote either if it has "
                 + "a space in.")
        }
        let old = args[0]
        let new = args[1]
        guard Tags.find(old) != nil else {
            fail("no recording is tagged `\(old)`. `listen tags` lists them.")
        }
        do {
            let changed = try Tags.rename(old, to: new)
            log(changed.isEmpty
                ? "nothing changed."
                : "renamed in \(changed.count) recording\(changed.count == 1 ? "" : "s").")
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }

    /// Take a tag off everything.
    ///
    /// Not a delete of anything: a tag has no existence apart from the
    /// recordings carrying it, so there is nothing else for this to mean.
    private static func tagsDelete(_ args: [String]) -> Never {
        guard let name = args.first, args.count == 1 else {
            fail("delete takes one tag. Quote it if it has a space in.")
        }
        guard let tag = Tags.find(name) else {
            fail("no recording is tagged `\(name)`. `listen tags` lists them.")
        }
        let changed = Tags.delete(tag.name)
        log("took `\(tag.name)` off \(changed.count) "
            + "recording\(changed.count == 1 ? "" : "s").")
        exit(0)
    }

    // MARK: - Dictionary

    /// `listen dictionary <sub>`: the user's own terms and corrections.
    ///
    /// The same file and the same code the Dictionary pane uses, for the reason
    /// `listen label` exists: a second implementation agrees with the first
    /// right up until it does not, and there is no test target to catch the day
    /// it stops.
    private static func dictionary(_ args: [String]) -> Never {
        let rest = Array(args.dropFirst())
        switch args.first ?? "list" {
        case "list":   dictionaryList()
        case "add":    dictionaryAdd(rest)
        case "remove": dictionaryRemove(rest)
        case "test":   dictionaryTest(rest)
        case "import": dictionaryImport(rest)
        case "export": dictionaryExport(rest)
        default:
            fail("unknown dictionary subcommand `\(args[0])`. Try `listen help`.")
        }
    }

    /// Every entry, and how often each has rewritten a transcript.
    ///
    /// The counts are the point. A dictionary applied at transcription time
    /// edits recordings nobody has read yet, so the list is only trustworthy
    /// next to the evidence of what it has done.
    private static func dictionaryList() -> Never {
        let entries = CustomDictionary.load()
        guard !entries.isEmpty else {
            log("the dictionary is empty. `listen dictionary add <term>` starts one.")
            exit(0)
        }

        var totals: [String: Int] = [:]
        for recording in Recording.all() {
            guard let counts = recording.storedTranscript?.dictionary else { continue }
            CustomDictionary.combine(counts, into: &totals)
        }

        let width = entries.map { $0.text.count + $0.replacement.count }.max() ?? 0
        for kind in [CustomDictionary.Kind.term, .correction] {
            let group = entries.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            print(kind == .term ? "terms" : "corrections")
            for entry in group {
                let subject = entry.kind == .term
                    ? entry.text
                    : "\(entry.text) -> \(entry.replacement)"
                var notes: [String] = []
                if !entry.enabled { notes.append("off") }
                if entry.caseSensitive, entry.kind == .correction { notes.append("case") }
                // A term too short to be matched by sound is stored and does
                // nothing at all, which from the outside looks exactly like the
                // feature being broken.
                if entry.kind == .term, !CustomDictionary.eligible(entry.text) {
                    notes.append("too short to match")
                }
                if let n = totals[entry.countKey] { notes.append("fired \(n)") }
                print("  " + subject.padding(toLength: max(width + 4, subject.count + 2),
                                             withPad: " ", startingAt: 0)
                      + notes.joined(separator: ", "))
            }
        }

        let fired = totals.values.reduce(0, +)
        print("")
        log(fired == 0
            ? "no transcript has been rewritten by these rules yet. Only recordings "
              + "transcribed since you added them are counted."
            : "\(fired) replacement(s) across the library.")
        exit(0)
    }

    /// `listen dictionary add <term>` or `add <text> <replacement>`.
    ///
    /// Which kind it is comes from whether a replacement was given, which is the
    /// same rule `CustomDictionary.decode` uses for a file with no `kind` in it.
    /// Two commands would have been a third place for the two to disagree.
    private static func dictionaryAdd(_ args: [String]) -> Never {
        var caseSensitive = false
        var words: [String] = []
        for arg in args {
            if arg == "--case-sensitive" { caseSensitive = true }
            else if arg.hasPrefix("-") { fail("unknown option `\(arg)`. Try `listen help`.") }
            else { words.append(arg) }
        }
        guard let text = words.first,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail("add needs a term, or a text and its replacement.")
        }
        guard words.count <= 2 else {
            fail("add takes a term, or a text and its replacement. Quote anything with "
                 + "spaces in it.")
        }

        let replacement = words.count == 2 ? words[1] : ""
        let kind: CustomDictionary.Kind = replacement.isEmpty ? .term : .correction
        var entries = CustomDictionary.load()
        let result = CustomDictionary.merge(
            [CustomDictionary.Entry(kind: kind, text: text, replacement: replacement,
                                    caseSensitive: caseSensitive)],
            into: entries)
        guard !result.added.isEmpty else {
            fail("`\(text)` is already in the dictionary as a \(kind.rawValue).")
        }
        entries.append(contentsOf: result.added)
        CustomDictionary.save(entries)

        // The event without the words: a spawned `listen` sends stderr to the
        // caller's log, and a dictionary entry is often a person's name. The
        // user typed the text one line up, so echoing it back adds nothing.
        log("added \(kind.rawValue)"
            + (replacement.isEmpty ? "" : " with a correction"))
        trace("  `\(text)`" + (replacement.isEmpty ? "" : " -> `\(replacement)`"))
        if kind == .term, !CustomDictionary.eligible(text) {
            log("it will do nothing as it stands: a term needs five letters, or eight "
                + "across a phrase, to be matched by sound. Add it as a correction "
                + "instead if you know exactly what comes out wrong.")
        }
        if kind == .term, caseSensitive {
            log("--case-sensitive applies to corrections only, and is ignored here.")
        }
        log("it applies to recordings transcribed from now on, not to transcripts you "
            + "already have.")
        exit(0)
    }

    private static func dictionaryRemove(_ args: [String]) -> Never {
        guard let text = args.first else { fail("remove needs the text of an entry.") }
        var entries = CustomDictionary.load()
        let before = entries.count
        entries.removeAll { $0.text.caseInsensitiveCompare(text) == .orderedSame }
        guard entries.count < before else {
            fail("no entry matching `\(text)`. `listen dictionary list` shows them all.")
        }
        CustomDictionary.save(entries)
        let gone = before - entries.count
        log("removed \(gone) \(gone == 1 ? "entry" : "entries") matching `\(text)`")
        exit(0)
    }

    /// `listen dictionary test <sentence>`: what the rules would do to a line.
    ///
    /// The escape hatch the sounds-like half needs. Whether "Gusens" becomes
    /// "Goossens" depends on a consonant code and on the system word list, so
    /// nobody can predict it by reading their own rule, and the alternative to
    /// trying it here is finding out an hour later on a real meeting.
    private static func dictionaryTest(_ args: [String]) -> Never {
        let input = args.joined(separator: " ")
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            fail("test needs a sentence. Quote it.")
        }
        let entries = CustomDictionary.load()
        guard !entries.isEmpty else { fail("the dictionary is empty.") }

        let applied = CustomDictionary.apply(to: input, entries: entries)
        // The rewritten line on stdout so it can be piped or diffed; which rules
        // fired on stderr, because it is commentary on the answer.
        print(applied.text)
        if applied.fired.isEmpty {
            log("no rule matched.")
        } else {
            for (key, n) in applied.fired.sorted(by: { $0.key < $1.key }) {
                log("\(key) fired \(n) time(s)")
            }
        }
        exit(0)
    }

    /// Merge a file in, keeping what is already here.
    ///
    /// Merging rather than replacing, because replacing is one mistyped path
    /// away from destroying a list somebody built up over months.
    private static func dictionaryImport(_ args: [String]) -> Never {
        let url: URL
        var source = ""
        if args.first == "--from-speak" {
            guard CustomDictionary.speakDictionaryExists else {
                // The path and the link together: the file may be missing
                // because Speak is not installed, or because it is and has no
                // dictionary yet, and those are different things to do next.
                fail("no Speak dictionary on this Mac "
                     + "(\(CustomDictionary.speakFile.path)).")
            }
            url = CustomDictionary.speakFile
            source = "Speak's dictionary"
        } else {
            guard let path = args.first, !path.hasPrefix("-") else {
                fail("import needs a path, or --from-speak.")
            }
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            source = url.lastPathComponent
        }

        guard let data = try? Data(contentsOf: url),
              let incoming = CustomDictionary.decode(data) else {
            fail("\(source) is not a dictionary file Listen understands. It reads its own "
                 + "exports, Speak's, and TypeWhisper's.")
        }

        var entries = CustomDictionary.load()
        let result = CustomDictionary.merge(incoming, into: entries)
        entries.append(contentsOf: result.added)
        CustomDictionary.save(entries)

        let terms = result.added.filter { $0.kind == .term }.count
        log("imported \(terms) term(s) and \(result.added.count - terms) correction(s)"
            + (result.duplicates > 0
               ? ", skipped \(result.duplicates) already in the dictionary" : ""))
        exit(0)
    }

    /// Write the list out in the shape Speak's own import reads, so the
    /// dictionary travels both ways.
    private static func dictionaryExport(_ args: [String]) -> Never {
        let entries = CustomDictionary.load()
        guard let data = CustomDictionary.encode(entries) else {
            fail("could not encode the dictionary.")
        }
        guard let path = args.first else {
            print(String(data: data, encoding: .utf8) ?? "")
            exit(0)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            fail("could not write \(url.path): \(error.localizedDescription)")
        }
        log("wrote \(entries.count) \(entries.count == 1 ? "entry" : "entries") "
            + "to \(url.path)")
        exit(0)
    }

    // MARK: - Notes

    /// `listen notes <sub>`: the note artifacts in the library.
    ///
    /// The same `Notes` store the MCP server and the detail pane use, for the
    /// reason `listen label` and `listen edit` exist: with no test target, a
    /// command that drives the exact write path the window drives is the only
    /// verification that path gets. It also came first, before any of the UI,
    /// because a store that can be exercised from a terminal is a store whose
    /// behaviour is settled before anything renders it.
    ///
    /// A note is named by its slug alone, because slugs are unique across the
    /// library: `read` and `delete` take no recording, and `--recording` on
    /// `write` is repeatable because a note can be about four meetings.
    private static func notes(_ args: [String]) -> Never {
        let rest = Array(args.dropFirst())
        switch args.first ?? "list" {
        case "list":    notesList(rest)
        case "read":    notesRead(rest)
        case "write":   notesWrite(rest)
        case "delete":  notesDelete(rest)
        default:
            fail("unknown notes subcommand `\(args[0])`. Try `listen help`.")
        }
    }

    /// Collect a repeatable `--recording <id>` out of an argument list.
    ///
    /// Repeatable rather than comma-separated, because a recording id has no
    /// commas in it today and a flag that quietly changes meaning the day one
    /// does is the sort of thing nobody finds again.
    private static func notesRecordings(_ ids: [String]) -> [Recording] {
        ids.map { id in
            guard let recording = Recording.find(id) else { fail("no recording `\(id)`.") }
            return recording
        }
    }

    /// Every note, or the ones about one recording, with who wrote each.
    ///
    /// The provenance is the point, the same way the dictionary's fire counts
    /// are. A note is derived from a meeting nobody may read for a week, and
    /// "which of these did I write and which did an agent write" is the first
    /// question anybody has about a folder of them.
    private static func notesList(_ args: [String]) -> Never {
        var about: [String] = []
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--recording":
                i += 1
                guard i < args.count else { fail("--recording needs a recording id.") }
                about.append(args[i])
            default:
                // A bare id still works, because `listen notes list <id>` is
                // what anybody who used the previous shape will type.
                guard !args[i].hasPrefix("-") else {
                    fail("unknown option `\(args[i])`. Try `listen help`.")
                }
                about.append(args[i])
            }
            i += 1
        }

        let recordings = notesRecordings(about)
        let notes = recordings.isEmpty
            ? Notes.all()
            : recordings.flatMap(Notes.list(about:))
                .reduce(into: [Note]()) { out, note in
                    if !out.contains(where: { $0.slug == note.slug }) { out.append(note) }
                }
        guard !notes.isEmpty else {
            log(recordings.isEmpty
                ? "no notes in the library yet."
                : "no notes about \(recordings.map(\.id).joined(separator: ", ")) yet.")
            exit(0)
        }

        let width = notes.map(\.slug.count).max() ?? 0
        for note in notes {
            var facts = [note.source]
            if !note.updated.isEmpty { facts.append(note.updated) }
            if note.updated != note.created { facts.append("edited") }
            // How many meetings it covers, but only when it is more than one.
            // Printing "1 recording" on every row of a library where almost
            // every note has one source is noise; printing "4 recordings" is
            // the whole reason the field exists.
            if note.recordings.count > 1 {
                facts.append("\(note.recordings.count) recordings")
            }
            print(note.slug.padding(toLength: max(width + 2, note.slug.count + 2),
                                    withPad: " ", startingAt: 0)
                  + note.title + "  (" + facts.joined(separator: ", ") + ")")
        }
        exit(0)
    }

    /// One note. The body on stdout, everything about it on stderr.
    ///
    /// Split that way so the body pipes and diffs cleanly, which is what makes
    /// the compare-and-swap usable from a terminal:
    /// `listen notes read <note> > was.md` gives you exactly the string
    /// `--was-file` wants back.
    private static func notesRead(_ args: [String]) -> Never {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("read needs a note. `listen notes list` shows them.")
        }
        guard let note = Notes.find(name) else {
            fail("no note `\(name)`. `listen notes list` shows them.")
        }
        print(note.body)
        // The body already went to stdout, where the user asked for it. The
        // stderr sidecar keeps to slugs and ids: a spawned `listen` sends
        // stderr to the caller's log, and a note title can hold anything a
        // meeting held.
        log("\(note.slug), written by \(note.source)"
            + (note.updated.isEmpty ? "" : " on \(note.updated)"))
        trace("  title: \(note.title)")
        if let prompt = note.prompt, !prompt.isEmpty { trace("  prompt: \(prompt)") }
        // Every source, including one the library no longer has, which prints
        // as a bare id. A note that quietly stopped listing a deleted meeting
        // would be claiming it was never about it.
        for source in Notes.sources(of: note) {
            log("about: \(source.id)"
                + (source.title == nil ? "  [no longer in the library]" : ""))
        }
        exit(0)
    }

    /// `listen notes write <title> --recording <id>…`, or `--replace <note>`.
    ///
    /// `--was` is optional here and required on the MCP surface, which is not
    /// an inconsistency. A person at a terminal is one writer and can see what
    /// they are replacing; an agent and the window can be holding the same note
    /// at the same time, and that is the surface where a lost edit is possible.
    private static func notesWrite(_ args: [String]) -> Never {
        var title: String?
        var body: String?
        var prompt: String?
        var replacing: String?
        var was: String?
        var about: [String] = []
        var i = 0
        while i < args.count {
            func value(_ flag: String) -> String {
                i += 1
                guard i < args.count else { fail("\(flag) needs a value.") }
                return args[i]
            }
            switch args[i] {
            case "--body":      body = value("--body")
            case "--file":      body = read(file: value("--file"), for: "--file")
            case "--prompt":    prompt = value("--prompt")
            case "--replace":   replacing = value("--replace")
            case "--title":     title = value("--title")
            case "--recording": about.append(value("--recording"))
            case "--was":       was = value("--was")
            case "--was-file":  was = read(file: value("--was-file"), for: "--was-file")
            case let other where other.hasPrefix("-"):
                fail("unknown option `\(other)`. Try `listen help`.")
            default:
                guard title == nil else {
                    fail("write takes one title. Quote it, and name recordings "
                         + "with --recording.")
                }
                title = args[i]
            }
            i += 1
        }

        // Validated here rather than left to the store, so a mistyped id is
        // refused before anything reads a body off stdin.
        _ = notesRecordings(about)
        if body == nil { body = readStdin() }
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fail("write needs a body: --body \"…\", --file <path>, or piped in.")
        }

        do {
            let note: Note
            if let replacing {
                // Nil rather than an empty array when no --recording was given:
                // adding a paragraph is not a claim about what the note is
                // about, so the sources are left exactly as they were.
                note = try Notes.replace(replacing, body: body, title: title,
                                         prompt: prompt, source: .cli,
                                         recordings: about.isEmpty ? nil : about,
                                         expecting: was)
                log("rewrote `\(note.slug)`")
            } else {
                guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                    fail("write needs a title, or --replace to rewrite a note "
                         + "that already has one.")
                }
                if was != nil {
                    fail("--was checks a rewrite, so it needs --replace. Without it "
                         + "this would add a note rather than change one.")
                }
                note = try Notes.create(title: title, body: body, source: .cli,
                                        prompt: prompt, recordings: about)
                log("wrote `\(note.slug)`, about "
                    + note.recordings.joined(separator: ", "))
            }
            // The slug on stdout, so a script can pipe it into the next command
            // the way `listen record` prints its folder.
            print(note.slug)
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func notesDelete(_ args: [String]) -> Never {
        guard let name = args.first, !name.hasPrefix("-") else {
            fail("delete needs a note. `listen notes list` shows them.")
        }
        do {
            let note = try Notes.delete(name)
            log("deleted `\(note.slug)`")
            trace("  title: \(note.title)")
            exit(0)
        } catch {
            fail(error.localizedDescription)
        }
    }

    /// A file, or stdin for `-`.
    private static func read(file path: String, for flag: String) -> String {
        if path == "-" { return readStdin() ?? "" }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fail("\(flag): could not read \(url.path).")
        }
        return text
    }

    /// Everything on stdin, or nil when there is nobody piping anything in.
    ///
    /// The `isatty` check is what stops `listen notes write <id> "Title"` with
    /// no body from sitting silently waiting for a terminal to reach EOF, which
    /// reads exactly like the command having hung.
    private static func readStdin() -> String? {
        guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return nil }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
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
      dictate <file>             run the dictation pipeline over a file
      polish [text|-]            polish and correct text, as a dictation would
      dictations [--limit N]     what you have dictated. --json for the fields.
      record [--seconds N]       capture until stopped, or for N seconds
      list [--limit N] [--tag T]
                                 recordings as a table. --json for the metadata.
      show <id>                  metadata and transcript
      export <id> [--format]     write a transcript out
      label <id> <speaker> ...   name, merge or discard a speaker
      title <id> [<text>]        what one recording is called. --clear un-names
                                 it. No text prints the current one.
      title backfill [--apply]   name every unnamed recording after the people
                                 in it. Prints and changes nothing without
                                 --apply.
      edit <id> <old> <new>      correct one sentence of a transcript
      people [<name>]            who is in the library, or where one person is
      rename <name> <new name>   rename one person in every recording
      merge <name> <into>        two rows in the roster, one human
      unname <name>              take a name off, leaving speakers to name again
      forget <name>              strip their voiceprints from every bank, on
                                 every Mac. Transcripts are untouched.
      me [<name> | --clear]      what the microphone track is called on screen
      import <path>              bring in a meet_transcriptions library
      enroll [<id>…] [--force]   re-derive voiceprints for named speakers
      dictionary <sub>           your own terms and corrections
      notes <sub>                the note artifacts, one or many recordings each
      tags <sub>                 what the recordings are about, in your words
      calendar <sub>             the calendars on this Mac, and what they name
      contacts <sub>             which email addresses belong to which person
      calibrate                  voiceprint threshold report
      voices <id> [--apply]      who the bank thinks each unnamed speaker is
      sources                    what meeting detection sees, run during a call
      audio [<id>] [--build]     what audio this Mac holds and which devices
                                 are keeping it. An id narrows it to one
                                 recording; --build makes its master here and
                                 says what that cost.
      mcp                        stdio MCP server. Notes and tags are the only
                                 things an agent can write.
      activity [--limit N]       what has touched the library: tool calls,
                                 agent runs, exports, deletions, backups.
                                 Ids only, never content. --json for jq.
      provider <sub>             the OpenAI-compatible backends: list, add,
                                 key, model, remove. Ollama and anything else
                                 speaking the same shape.
      ask [<question>]           put a question to Claude Code, Codex or an
                                 OpenAI-compatible endpoint, all of which read
                                 the library through the tools `listen mcp`
                                 serves. No question reports what is set up.

    ask options:
      --claude, --codex          which CLI, when both are installed
      --endpoint                 the endpoint configured in Settings › Ask
      --to <url>                 a base URL for this run only, such as
                                 http://localhost:11434/v1 for Ollama. Changes
                                 no preference, so trying one is free.
      --write                    let it write notes and tags. Read-only without.
      --resume <id>              a session id for a CLI, a conversation id from
                                 this library for an endpoint
      --model <name>             which model. Required for an endpoint unless
                                 one is set in Settings.
      --stream                   type the answer out as it is written, which is
                                 what the window does. Not Codex.
      --json                     the answer's own event stream, unread
      --print-command            the command Listen would run, and nothing else
      --print-request            the same for an endpoint: the POST body, which
                                 never contains the key

    calendar subcommands:
      status                     access, calendars and today. The default.
      events [--days N]          what is coming up, 7 days by default
      match <id>                 every meeting that could be this recording,
                                 with the offsets, and which one wins
      backfill [--apply]         name every unnamed recording that matches an
                                 event. Prints and changes nothing without --apply.
      backfill --refresh         also re-read recordings already attached

    contacts subcommands:
      list                       every person and the addresses they answer to
      link <email> <name>        say who an address belongs to
      unlink <email>             forget one address
      note <name> [text]         what you know about them, or read it back
      test <email>               the name that address would suggest

    dictionary subcommands:
      list                       every entry, with what each has changed
      add <term>                 a word to spell right, matched by sound
      add <text> <replacement>   an exact replacement
      remove <text>              drop the entry matching that text
      test <sentence>            what the dictionary would do to a line
      import <path>              merge a file in, keeping what is here
      import --from-speak        merge Speak's dictionary in
      export [<path>]            write the list out, stdout by default

    notes subcommands:
      list [<id>]                every note, or the ones about one recording
      read <note>                one note. Body on stdout, provenance on stderr.
      write <title> --recording <id>…
                                 add one. Body from --body, --file or stdin.
      write --replace <note>     rewrite one instead of adding one
      delete <note>              remove one

    notes options:
      --recording <id>           which meeting the note is about. Repeat it:
                                 a note can be about four at once.
      --body <text>              the note itself, inline
      --file <path>              the note itself, from a file. `-` is stdin.
      --prompt <text>            what was asked for, kept beside the note
      --replace <note>           rewrite a note by slug or title
      --was <text>               refuse the rewrite unless it still reads this
      --was-file <path>          the same check, from a file
      --title <text>             rename it while rewriting it

    Notes live in the library rather than inside a recording folder, so a note
    can be about several meetings and deleting one meeting does not delete it.

    tags subcommands:
      list                       every tag, with how many recordings. The default.
      add <id> <tag>…            tag a recording
      remove <id> <tag>…         take tags off a recording
      rename <tag> <new name>    rename one tag in every recording
      delete <tag>               take one tag off everything

    A tag is free text, so quote any with a space in: `listen tags add <id>
    "job hunt"`. Tags are given one at a time rather than comma-separated, and
    `listen list --tag` repeats the same way; several tags mean all of them.

    A tag lives on the recording, so deleting a meeting takes its tags with it,
    and a tag nothing carries stops existing. That is the opposite of a note,
    and both are on purpose.

    import options:
      --dry-run                  list what would be imported, copy nothing
      --replace                  re-import recordings already in the library
      --apps-only                attach which app the call was in to recordings
                                 already imported, and change nothing else

    label options:
      <name>                     name the speaker
      --unname                   take the name off, leaving the speaker in this
                                 recording as a letter to be named again
      --merge-into <speaker>     reassign them onto another speaker
      --discard                  delete their segments. Not an undo for naming:
                                 use --unname for that
      --move <n> <name>          hand segment n to somebody else, leaving the
                                 rest of this speaker alone
      --move-turn <from> <to> <name>
                                 hand every segment of theirs that starts
                                 between those two seconds to somebody else

    transcribe options:
      --format md|json|txt       default md. json carries the timings.
      --model v2|v3              v2 is English only, v3 reads 25 languages.
                                 On a recording this is remembered: every later
                                 run of that one uses it. Without it, whatever
                                 that recording already carries, or the default.
      --diarize                  label speakers in a bare audio file.
                                 Implied when the argument is a recording.
      --room / --no-room         whether the microphone held a room of people
                                 or just you. Remembered on the recording.
                                 Only needed for a meeting that was partly in
                                 the room and partly on a call: every other
                                 kind is worked out from the audio.

    Running `listen` with no command starts the app.
    """

    // -----------------------------------------------------------------------

    /// `listen dictations [--limit N] [--json]`: what you have dictated.
    ///
    /// Read-only, and it stays that way. There is nothing to edit here: a
    /// dictation is a moment that already happened and whose text is on the
    /// clipboard, so the useful operations are reading the tail and grepping the
    /// file, which `jq` does better than any flag this could grow.
    ///
    /// Deliberately not an MCP tool either. The server's rule is that the agent
    /// reads evidence and writes opinion, and a dictation is neither: it is
    /// whatever the user last typed with their voice, which may be a password
    /// hint, a message to somebody else, or half a thought. Meetings are
    /// recorded knowingly and shared knowingly; this is a keyboard.
    private static func dictations(_ args: [String]) -> Never {
        var limit = 20
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

        let entries = DictationHistory.recent(limit)
        guard !entries.isEmpty else {
            log("nothing dictated yet. The shortcut is in Settings, Dictation.")
            exit(0)
        }

        if asJSON {
            // Rebuilt rather than echoed, so the shape is this command's and not
            // whatever the file happens to hold. Same key names, though: the
            // file is the documented artifact and two spellings of `duration_sec`
            // would be a needless thing to know.
            let rows: [[String: Any]] = entries.map { e in
                var row: [String: Any] = [
                    "at": ISO8601DateFormatter().string(from: e.date),
                    // Through `NSDecimalNumber`, for the reason written up on
                    // `DictationHistory.tenths`: a rounded `Double` still
                    // serialises as 6.5999999999999996. The same helper, so the
                    // file and this command cannot print a duration two ways.
                    "duration_sec": DictationHistory.tenths(e.duration),
                    "words": e.text.split(separator: " ").count,
                    "text": e.text,
                ]
                if let raw = e.raw { row["raw"] = raw }
                if !e.fired.isEmpty { row["dictionary"] = e.fired }
                return row
            }
            guard let data = try? JSONSerialization.data(
                withJSONObject: rows,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                let text = String(data: data, encoding: .utf8)
            else { fail("could not render the history as JSON") }
            print(text)
            exit(0)
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        for e in entries {
            let words = e.text.split(separator: " ").count
            print("\(stamp.string(from: e.date))  \(String(format: "%5.1fs", e.duration))"
                  + "  \(String(format: "%4d", words))w  "
                  + e.text.replacingOccurrences(of: "\n", with: " "))
        }
        // The file, because the useful next step is almost always grep or jq
        // over the whole thing rather than a longer --limit.
        log("\(DictationHistory.file.path)")
        exit(0)
    }

    /// `listen polish [text|-]`: the post-processing chain, on text.
    ///
    /// The other half of `dictate`'s escape hatch, and the one that matters most,
    /// because every defence in `Polisher` is a measured response to a real
    /// failure and none of them can be checked by reading the code. `-` reads
    /// stdin, so a whole history can be replayed through it.
    ///
    /// `LISTEN_POLISH=0` skips the model so the dictionary can be exercised on
    /// its own, and `LISTEN_REPAIR=1` / `LISTEN_REPAIR=0` forces the
    /// self-correction pass, which is how to A/B it without touching the saved
    /// setting. `verify_polish.sh` drives all three.
    private static func polish(_ args: [String]) async -> Never {
        var pieces: [String] = []
        for arg in args {
            if arg == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                pieces.append(String(data: data, encoding: .utf8) ?? "")
            } else if arg.hasPrefix("-") {
                fail("unknown option `\(arg)`. Try `listen help`.")
            } else {
                pieces.append(arg)
            }
        }
        let text = pieces.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail("polish needs text, or `-` to read stdin. Try `listen help`.")
        }

        // Said rather than left to be inferred from unchanged output: on a Mac
        // that cannot polish, text coming back identical is the correct result
        // and looks exactly like a broken command.
        if let why = Polisher.unavailableReason { log(why) }

        let t0 = Date()
        // `force`, because this is somebody asking for it explicitly. The
        // environment override still wins, which is what makes
        // `LISTEN_POLISH=0 listen polish` reach the corrections-only path.
        let polished = await Polisher.shared.polish(text, force: true) { step, total in
            if total > 1 { log("chunk \(step)/\(total)") }
        }
        // Corrections after, matching `applyAround`'s second pass. The first pass
        // belongs to the raw transcript and there is no transcript here.
        let corrected = CustomDictionary.apply(to: polished)

        log(String(format: "%.1fs for %d characters", Date().timeIntervalSince(t0), text.count))
        if !corrected.fired.isEmpty {
            log("dictionary: " + corrected.fired.map { "\($0.key) x\($0.value)" }
                .sorted().joined(separator: ", "))
        }
        print(corrected.text)
        exit(0)
    }

    /// `listen dictate <file>`: the dictation pipeline over one file.
    ///
    /// The same escape hatch `transcribe` is, for the other pipeline. Dictation
    /// is otherwise only reachable by holding a chord and talking, which needs
    /// Accessibility, a microphone and a person, so a change to it could
    /// otherwise only be tested by hand. This runs everything the shortcut runs
    /// except the shortcut, the microphone and the clipboard: engine, then the
    /// custom dictionary, then the fragment trim.
    ///
    /// Speak's equivalent is `--transcribe`, and its notes call it the fastest
    /// way to separate a model problem from a shortcut problem before touching
    /// UI code. That is exactly what it is for here.
    private static func dictate(_ args: [String]) async -> Never {
        var path: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case let other where other.hasPrefix("-"):
                fail("unknown option `\(other)`. Try `listen help`.")
            default:
                guard path == nil else { fail("dictate takes one file.") }
                path = args[i]
            }
            i += 1
        }
        guard let path else { fail("dictate needs an audio file. Try `listen help`.") }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("no such file: \(url.path)")
        }

        do {
            let choice = Settings.model
            try await ASR.shared.load(choice) { log($0) }
            let samples = try ASR.samples(from: url)
            let t0 = Date()
            guard let raw = await ASR.shared.transcribe(samples: samples) else {
                log("nothing transcribed")
                exit(0)
            }
            let spoken = Date()

            // The same two steps, in the same order, as `Dictation.finish`.
            let corrected = CustomDictionary.apply(to: raw)
            let text = Punctuation.trimFragment(corrected.text)

            // Timings and what changed on stderr, so stdout stays pipeable.
            log(String(format: "transcribe %.1fs for %.0fs of audio",
                       spoken.timeIntervalSince(t0),
                       Double(samples.count) / SAMPLE_RATE))
            if !corrected.fired.isEmpty {
                log("dictionary: " + corrected.fired.map { "\($0.key) x\($0.value)" }
                    .sorted().joined(separator: ", "))
            }
            if text != raw { log("raw: \(raw)") }
            print(text)
        } catch {
            fail("\(error.localizedDescription)")
        }
        exit(0)
    }

    /// `listen transcribe <file>`.
    ///
    /// The debugging escape hatch as much as a feature: it needs no
    /// permissions, so it separates a model problem from a capture problem
    /// before anyone touches UI code.
    private static func transcribe(_ args: [String]) async -> Never {
        var path: String?
        var format = "md"
        // nil is "not asked for", which is not the same as the default. On a
        // recording, no flag means the model that recording already carries,
        // and `--model` means change it. Collapsing the two here would pin every
        // recording ever transcribed from the CLI to whatever the default
        // happened to be that day.
        var chosen: ModelChoice?
        var diarize = false
        // Three states again, and for the same reason as `chosen`: no flag
        // leaves the pipeline to infer, which is right for almost every
        // recording. Only a hybrid meeting needs telling.
        var room: Bool?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--diarize":
                diarize = true
            case "--room":
                room = true
            case "--no-room":
                room = false
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
                chosen = m
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
            await transcribeRecording(recording, format: format, chosen: chosen, room: room)
        }
        if room != nil {
            fail("--room applies to a recording, not to a bare file. A file has no"
                 + " track split, so `--diarize` is the flag that finds its speakers.")
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("no such file or recording: \(url.path)")
        }

        // A bare file is not in the library and has nothing to remember a model
        // with, so the default stands in when none was named.
        let choice = chosen ?? Settings.model

        if diarize {
            await transcribeDiarized(url, format: format, choice: choice)
        }

        let asr = ASR()
        do {
            let t0 = Date()
            try await asr.load(choice) { log($0) }
            let loaded = Date()
            // The chunk counter on stderr, so a long file says something while
            // it works. The same callback the window's picture is driven by, so
            // what the CLI reports and what the pane draws cannot come apart.
            let transcript = try await asr.transcribe(url) { fraction in
                log(String(format: "%.0f%%", fraction * 100))
            }
            let done = Date()

            // Timings on stderr so the transcript on stdout stays pipeable.
            log(String(format: "load %.1fs, transcribe %.1fs for %.0fs of audio (%.1fx)",
                       loaded.timeIntervalSince(t0),
                       done.timeIntervalSince(loaded),
                       transcript.duration,
                       transcript.duration / max(done.timeIntervalSince(loaded), 0.001)))

            // What the file was actually cut into, rather than what a chunk
            // length implies it was cut into. These used to be the same
            // statement because the cuts were at fixed offsets; now a cut moves
            // back up to ten seconds to find a pause, so the count is a count.
            //
            // `hard` is the number that matters and the reason this is printed
            // every run. A cut that found no pause behaves like one of the old
            // fixed-offset seams and costs about one word, and the whole case
            // for cutting at silence is that it is zero on ordinary speech.
            log(String(format: "chunk %.0fs, %d piece(s), %d hard cut(s)",
                       ASR.chunkSeconds, transcript.chunks, transcript.hardCuts))

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

    /// `listen list [--limit N] [--tag <name>] [--json]`.
    private static func list(_ args: [String]) -> Never {
        var limit = Int.max
        var asJSON = false
        var filter = RecordingFilter()
        var i = 0
        while i < args.count {
            func value(_ flag: String) -> String {
                i += 1
                guard i < args.count else { fail("\(flag) needs a value.") }
                return args[i]
            }
            switch args[i] {
            case "--limit":
                i += 1
                guard i < args.count, let n = Int(args[i]), n > 0 else {
                    fail("--limit needs a positive number")
                }
                limit = n
            // Repeatable rather than comma-separated, which is this CLI's rule
            // and is also why `Tags.check` refuses a comma in a tag: neither
            // half of that can quietly change meaning later.
            case "--tag": filter.tags.append(value("--tag"))
            case "--json": asJSON = true
            default: fail("unknown option `\(args[i])`. Try `listen help`.")
            }
            i += 1
        }

        for name in filter.tags where Tags.find(name) == nil {
            // An empty result is indistinguishable from a typo, and a tag is
            // something the user invented rather than something with a fixed
            // vocabulary to check against.
            log("nothing is tagged `\(name)`. `listen tags` lists them.")
        }

        let recordings = Array(filter.apply(to: Recording.all()).prefix(limit))
        if asJSON {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = (try? enc.encode(recordings.map(\.metadata))) ?? Data()
            print(String(data: data, encoding: .utf8) ?? "[]")
            exit(0)
        }

        guard !recordings.isEmpty else {
            // "no recordings yet" is a lie when a filter is what emptied the
            // list, and it is the kind of lie that sends somebody looking for a
            // library that is sitting right there.
            log(filter.isEmpty
                ? "no recordings yet. `listen record` makes one."
                : "no recordings match. `listen list` shows all of them.")
            exit(0)
        }
        // Pad to the widest id so the columns line up without a table library.
        let width = recordings.map(\.id.count).max() ?? 0
        for r in recordings {
            let state = r.metadata.stateValue == .done ? "" : "  \(r.metadata.state)"
            print("\(r.id.padding(toLength: width, withPad: " ", startingAt: 0))  "
                  + "\(r.lengthText.isEmpty ? "-" : r.lengthText)  \(r.displayTitle)\(state)")
        }
        exit(0)
    }

    /// `listen show <id>`.
    private static func show(_ args: [String]) -> Never {
        guard let id = args.first else { fail("show needs a recording id.") }
        guard let recording = Recording.find(id) else { fail("no recording `\(id)`.") }

        // Marked when the app named it, for the reason the speakers below are:
        // an automatic name is otherwise indistinguishable from one somebody
        // chose, and "why is this called Call with Céline when I never said so"
        // has to be answerable from outside the window.
        print(recording.displayTitle
              + (recording.metadata.titleSourceValue.map { "  (\($0.phrase))" } ?? ""))
        // The model that produced the transcript, on the same line as the rest
        // of the provenance and in the same order as the detail pane. It is the
        // only fact that explains a transcript in the wrong language, and until
        // it was printed here there was nowhere to read it but the raw JSON.
        print([recording.when, recording.lengthText, recording.appLabel ?? "",
               recording.storedTranscript.map { Recording.modelName($0.model) } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " · "))
        // Marked, because an automatic name is otherwise indistinguishable from
        // one somebody chose, and "why does this say Marcia?" has to be
        // answerable from outside the window.
        let automatic = Set(recording.metadata.auto_named ?? [])
        let speakers = recording.speakers
            .map { automatic.contains($0) ? "\($0) (by voice)" : $0 }
        if !speakers.isEmpty { print("speakers: " + speakers.joined(separator: ", ")) }
        // Only when it is true, and marked when nobody said so. This is the
        // answer to "why is this whole meeting one speaker" and to its opposite,
        // "why am I three people", and both questions are asked from here.
        if recording.isRoom {
            print("microphone: the room"
                  + (recording.metadata.room_auto == true ? " (inferred)" : ""))
        }
        let tags = Tags.of(recording)
        if !tags.isEmpty { print("tags: " + tags.joined(separator: ", ")) }
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
        ActivityLog.append("export", ["recording_id": recording.id, "format": format])
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

    /// `listen label <id> <speaker> [<name> | --unname | --merge-into X |
    /// --discard | --move <n> <name> | --move-turn <from> <to> <name>]`.
    ///
    /// The same `TranscriptEditor` calls the window makes, so this is a real
    /// exercise of that path rather than a parallel implementation. It is also
    /// how speaker edits get verified, there being no test target.
    ///
    /// The two `--move` forms are the transcript menu's reassignment, and they
    /// are here for that reason: a correction that can only be made by
    /// right-clicking a paragraph is a correction nothing can check.
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
        case "--unname":
            // Not `.rename` written out here: `People.unname(_:in:)` picks a
            // letter this recording is not already using, and reusing one would
            // silently merge two speakers.
            guard People.unname(speaker, in: recording) else {
                fail("\(speaker) cannot be unnamed. It is a placeholder already, "
                     + "or the microphone track.")
            }
            guard let updated = Recording.find(recording.id) else { exit(0) }
            log("speakers now: \(updated.speakers.joined(separator: ", "))")
            log("state: \(updated.metadata.state)")
            exit(0)
        case "--move":
            guard rest.count >= 3, let index = Int(rest[1]) else {
                fail("--move needs a segment number and a name.")
            }
            guard let segments = recording.storedTranscript?.segments,
                  index >= 0, index < segments.count else {
                fail("no segment \(rest[1]) in \(recording.id).")
            }
            // The text this segment holds right now. `.sentence` is a
            // compare-and-swap against a pane that was drawn before somebody
            // else edited the transcript, and there is no such pane here: what
            // was read a line ago is what the window would have been looking at.
            edit = .reassign(.sentence(index: index, text: segments[index].text),
                             from: speaker, to: rest[2])
        case "--move-turn":
            guard rest.count >= 4, let start = Double(rest[1]),
                  let end = Double(rest[2]) else {
                fail("--move-turn needs a start, an end and a name.")
            }
            edit = .reassign(.turn(start: start, end: end), from: speaker, to: rest[3])
        case .some(let name) where !name.hasPrefix("-"):
            edit = .rename(speaker, to: name)
        default:
            fail("label needs a name, --unname, --merge-into <speaker>, "
                 + "--discard, --move <n> <name>, or "
                 + "--move-turn <from> <to> <name>.")
        }

        guard TranscriptEditor.apply(edit, to: recording) else {
            // Three ways to get here and the edit says which: no transcript at
            // all, a segment that is not this speaker's, or a window with none
            // of their segments in it. Nothing was written in any of them.
            fail("nothing was written. \(recording.id) has no transcript to edit, "
                 + "or nothing matched.")
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
            guard let person = People.findByDisplayName(name)
                    ?? ContactBook.contact(name).map({
                        Person(label: $0.name, recordings: [], seconds: 0) }) else {
                fail("nobody called `\(name)`. `listen people` lists everyone.")
            }
            card(person)
            exit(0)
        }

        let everyone = People.roster()
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

    /// One person as the card shows them.
    ///
    /// Printed by the same reads the window makes, so "what does the app think
    /// it knows about Ryan" is answerable without opening it. That is the
    /// whole reason these commands exist in a project with no test target.
    private static func card(_ person: Person) {
        let contact = ContactBook.contact(person.label)
        print("\(person.display)  \(person.summary)")

        var facts: [String] = []
        if person.isYou { facts.append("you, on the microphone track") }
        if let seen = person.lastSeen, !person.isYou {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .none
            facts.append("last heard " + f.string(from: seen))
        }
        let voiced = person.recordings.filter {
            $0.voiceprints[person.label]?.isEvidence == true
        }
        if !voiced.isEmpty {
            facts.append("recognised by voice in \(voiced.count)")
        } else if !person.recordings.isEmpty, !person.isYou {
            facts.append("no voiceprint yet")
        }
        if !facts.isEmpty { print("  " + facts.joined(separator: " · ")) }

        for email in contact?.emails ?? [] { print("  " + email) }
        if let note = contact?.note, !note.isEmpty { print("  " + note) }

        guard !person.recordings.isEmpty else {
            print("  in no recordings yet")
            return
        }
        print("")
        let width = person.recordings.map(\.id.count).max() ?? 0
        for recording in person.recordings {
            let spoken = People.speakers(in: recording)
                .first { $0.label == person.label }
                .map { Recording.length($0.seconds) } ?? ""
            print("  " + recording.id.padding(toLength: width, withPad: " ", startingAt: 0)
                  + "  " + recording.displayTitle
                  + (spoken.isEmpty ? "" : "  (\(spoken))"))
        }
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

    /// `listen merge <person> <into>`: two rows in the roster, one human.
    ///
    /// The imported case: you are `Me` on the recordings made here and a name
    /// on the ones that came from somewhere else. Merging into `Me` is allowed
    /// where renaming to it is refused, because "that speaker was me" is a fact
    /// about a recording rather than a name somebody typed.
    private static func mergePeople(_ args: [String]) -> Never {
        guard args.count >= 2 else {
            fail("merge needs a person and who they are. Try `listen help`.")
        }
        guard let person = People.findByDisplayName(args[0]) else {
            fail("nobody called `\(args[0])`. `listen people` lists everyone.")
        }
        let wanted = args.dropFirst().joined(separator: " ")
        let target = People.findByDisplayName(wanted)?.label
            ?? (wanted == SpeakerName.you ? SpeakerName.you : nil)
        guard let target else {
            fail("nobody called `\(wanted)`. `listen people` lists everyone.")
        }
        guard person.label != target else { fail("that is the same person.") }
        guard person.label != SpeakerName.you else {
            fail("you cannot be folded into somebody else. `\(SpeakerName.you)` is "
                 + "what the pipeline writes for the microphone track, so the next "
                 + "recording would put it back. Merge them into you instead.")
        }

        let changed = People.merge(person.label, into: target)
        guard !changed.isEmpty else { fail("nothing was changed.") }
        print("merged \(person.display) into \(SpeakerName.display(target)) in "
              + "\(changed.count) recording(s)")
        for id in changed { print("  \(id)") }
        exit(0)
    }

    /// `listen unname <person>`: take a name off without losing the speaker.
    ///
    /// The wrong person named in ten recordings is a common enough mistake, and
    /// the only way back used to be renaming them to something else. This puts
    /// every one of them back to `Speaker A`, keeps the voiceprint on that
    /// speaker, and removes the card that was filed under the name.
    private static func unnamePerson(_ args: [String]) -> Never {
        guard let name = args.first else {
            fail("unname needs a person. Try `listen help`.")
        }
        guard let person = People.findByDisplayName(args.joined(separator: " "))
                ?? People.findByDisplayName(name) else {
            fail("nobody called `\(name)`. `listen people` lists everyone.")
        }
        guard person.label != SpeakerName.you else {
            fail("`\(SpeakerName.you)` is the microphone track, which is you by "
                 + "construction rather than by name, so there is no name to take off.")
        }
        let changed = People.unname(person.label)
        print("unnamed \(person.display) in \(changed.count) recording(s)")
        for id in changed { print("  \(id)") }
        exit(0)
    }

    /// `listen forget <person>`: strip their voiceprints, here and everywhere.
    ///
    /// The other half of `unname`, for the person who asked to be forgotten.
    /// `unname` keeps the print so the bank can suggest them again; this
    /// removes it from every bank, and the forget travels: other Macs drop
    /// theirs on the next sync pass, and the CloudKit records go with it.
    /// Transcripts and audio are untouched, because deleting what somebody
    /// said is a recording deletion, and that verb already exists.
    private static func forgetPerson(_ args: [String]) -> Never {
        guard let name = args.first else {
            fail("forget needs a person. Try `listen help`.")
        }
        guard let person = People.findByDisplayName(args.joined(separator: " "))
                ?? People.findByDisplayName(name) else {
            fail("nobody called `\(name)`. `listen people` lists everyone.")
        }
        guard person.label != SpeakerName.you else {
            fail("`\(SpeakerName.you)` is the microphone track. Forgetting your "
                 + "own voice would only make the next recording ask who you are.")
        }
        let touched = People.forgetVoiceprints(person.label)
        print("forgot \(person.display)'s voiceprints in \(touched.count) recording(s)")
        print("Other Macs drop theirs on the next sync pass. Their name in the "
              + "transcripts is untouched: `listen unname` is the verb for that.")
        exit(0)
    }

    /// `listen activity [--limit N] [--json]`: what has touched the library.
    ///
    /// Reads `activity.jsonl`, which carries events and ids and never content,
    /// so this output is safe wherever it lands. `--json` prints the raw lines
    /// for jq.
    private static func activity(_ args: [String]) -> Never {
        var limit = 50
        if let index = args.firstIndex(of: "--limit"), index + 1 < args.count,
           let n = Int(args[index + 1]) { limit = max(1, n) }
        let entries = ActivityLog.recent(limit)
        if args.contains("--json") {
            for entry in entries {
                guard let data = try? JSONSerialization.data(
                    withJSONObject: entry,
                    options: [.sortedKeys, .withoutEscapingSlashes]),
                      let line = String(data: data, encoding: .utf8) else { continue }
                print(line)
            }
            exit(0)
        }
        guard !entries.isEmpty else {
            print("No activity recorded yet. The log starts with the first tool "
                  + "call, agent run, export, deletion or backup.")
            exit(0)
        }
        for entry in entries {
            let at = (entry["at"] as? String ?? "")
                .replacingOccurrences(of: "T", with: " ")
                .replacingOccurrences(of: "Z", with: "")
            var parts = [at, entry["event"] as? String ?? "?"]
            if let tool = entry["tool"] as? String { parts.append(tool) }
            if let host = entry["host"] as? String { parts.append(host) }
            else if let backend = entry["backend"] as? String { parts.append(backend) }
            if let ids = entry["recordings"] as? [Any] {
                let names = ids.compactMap { $0 as? String }
                if !names.isEmpty { parts.append(names.joined(separator: ",")) }
            }
            if let id = entry["recording_id"] as? String { parts.append(id) }
            if let count = entry["count"] { parts.append("count=\(count)") }
            if let transport = entry["transport"] as? String { parts.append(transport) }
            print(parts.joined(separator: "  "))
        }
        exit(0)
    }

    /// `listen me [<name> | --clear]`: what the microphone track is called.
    ///
    /// A preference, not an edit. The transcripts keep saying `Me` and this is
    /// resolved on the way to the screen, so it applies to every recording ever
    /// made and changing it again costs nothing.
    /// `listen title <id> [<text> | --clear]`: what one recording is called.
    ///
    /// The window was the only way to name a recording, which made naming a
    /// day's worth of them the one part of tidying a library that could not be
    /// scripted. `listen rename` is people, and there was nothing for this.
    ///
    /// The remaining arguments are joined with a space rather than quoted, which
    /// is `listen me`'s rule and the opposite of `listen tags add`'s. Both are
    /// right: a tag joins a derived vocabulary where two spellings of one name
    /// split a group in half, and a title is free text belonging to one
    /// recording where there is nothing for it to disagree with.
    ///
    /// No argument prints the current title, so a script can read one back
    /// without parsing `listen show`.
    private static func title(_ args: [String]) -> Never {
        // Before the id is resolved, and safe to do that way round: every id is
        // a timestamp, so no recording can be called `backfill`. The same shape
        // `listen calendar` uses, one level down, because a subcommand on
        // `title` and a subcommand on `calendar` should not be two different
        // ideas of a subcommand.
        if args.first == "backfill" { titleBackfill(Array(args.dropFirst())) }

        guard let id = args.first else {
            fail("title needs a recording id. `listen list` shows them.")
        }
        guard var recording = Recording.find(id) else { fail("no recording `\(id)`.") }
        let rest = Array(args.dropFirst())

        guard let first = rest.first else {
            // The stored string, deliberately, where `listen list` and
            // `listen show` print `displayTitle`. This is the read-back the doc
            // comment above calls the script path, so it has to answer with what
            // is in `metadata.json` and keep answering the same thing when the
            // placeholder is reworded. The hint below is where a person is told
            // what it means.
            print(recording.metadata.title)
            if recording.isUntitled {
                log("nobody has named this one. `listen title \(recording.id) <text>` does.")
            } else if let source = recording.metadata.titleSourceValue {
                // Which also says it is not yours yet: typing over it freezes
                // it, and until somebody does the app keeps the name current.
                log("\(source.phrase). Typing a name of your own replaces it for good.")
            }
            exit(0)
        }
        // Only when it stands alone, so a recording may still be called
        // `--clear` by somebody determined to.
        let clearing = first == "--clear" && rest.count == 1
        guard clearing || !first.hasPrefix("-") else {
            fail("unknown option `\(first)`. Try `listen help`.")
        }

        do {
            let changed = try recording.rename(to: clearing ? "" : rest.joined(separator: " "))
            print(recording.metadata.title)
            if !changed { log("already called that. Nothing changed.") }
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }

    /// `listen title backfill`: name every recording its speakers can name.
    ///
    /// A dry run unless `--apply` is given, and deliberately not something that
    /// happens at launch, which is the rule `listen calendar backfill` already
    /// sets and for the same reason: renaming a library at once without being
    /// asked is the surprise the rest of this app avoids.
    ///
    /// It exists because `AutoTitle` is driven by speaker edits, so a recording
    /// whose speakers were all named before this feature existed will never see
    /// one and would stay unnamed for ever with nothing explaining why.
    ///
    /// **Every recording is accounted for, including the ones it does nothing
    /// to.** A backfill that printed only its hits would leave somebody
    /// counting rows to work out what happened to the rest, and the answer per
    /// recording is the useful half: waiting on a speaker is something they can
    /// act on, nobody to name it after is not.
    private static func titleBackfill(_ args: [String]) -> Never {
        var apply = false
        for arg in args {
            switch arg {
            case "--apply": apply = true
            default:        fail("unknown option `\(arg)`.")
            }
        }

        let library = Recording.all()
        var named = 0, unnamed = 0, waiting = 0, nobody = 0, notOurs = 0
        var outranked = 0, alreadyRight = 0

        for recording in library.sorted(by: { $0.id < $1.id }) {
            let outcome = AutoTitle.outcome(for: recording)
            switch outcome {
            case .name(let title):
                named += 1
                print(String(format: "  %@  %-30@ → %@", recording.id as NSString,
                             recording.displayTitle as NSString, title as NSString))
            case .unname:
                unnamed += 1
                print(String(format: "  %@  %-30@ → %@", recording.id as NSString,
                             recording.displayTitle as NSString,
                             Metadata.untitledDisplay as NSString))
            case .waitingOnSpeakers(let count):
                waiting += 1
                print(String(format: "  %@  %-30@ (waiting on %d unnamed speaker%@)",
                             recording.id as NSString, recording.displayTitle as NSString,
                             count, (count == 1 ? "" : "s") as NSString))
            case .nobodyToNameItAfter:  nobody += 1
            case .notOurs:              notOurs += 1
            case .outranked:            outranked += 1
            case .nothingToDo:          alreadyRight += 1
            }
            if apply { AutoTitle.refresh(recording) }
        }

        print("")
        print("\(library.count) recordings.")
        if named > 0 { print("  \(named) would be named after their speakers") }
        if unnamed > 0 { print("  \(unnamed) would go back to the placeholder") }
        if waiting > 0 { print("  \(waiting) waiting on a speaker to be named") }
        if nobody > 0 { print("  \(nobody) have nobody to name them after") }
        if alreadyRight > 0 { print("  \(alreadyRight) already say what their speakers say") }
        // "have a title" and never "named by hand": see `Outcome.notOurs`.
        // Most of these are the legacy imports and the iPhone's dated memos,
        // and calling those somebody's own work would be the app inventing a
        // fact about its own library.
        if notOurs > 0 { print("  \(notOurs) have a title already, left alone") }
        if outranked > 0 { print("  \(outranked) named from the calendar, left alone") }
        print(apply ? "\napplied." : "\nnothing was written. `--apply` does it.")
        exit(0)
    }

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
        var appsOnly = false
        for arg in args {
            switch arg {
            case "--dry-run": dryRun = true
            case "--replace": replace = true
            case "--apps-only": appsOnly = true
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

        // Backfill only. Recordings imported before Listen recorded which app
        // the call was in still have it in the legacy folder and nowhere else,
        // and that is most of the library. Prints without `--apply` for the
        // reason `calendar backfill` does: this rewrites recordings nobody
        // asked it to touch.
        if appsOnly {
            let changed = LegacyImport.backfillApps(candidates, apply: !dryRun)
            guard !changed.isEmpty else {
                log("every imported recording already knows which app it was in.")
                exit(0)
            }
            for (id, app) in changed {
                print("\(dryRun ? "would set" : "set") \(id)  \(app)")
            }
            log("\(dryRun ? "would attach" : "attached") the app to \(changed.count) recording(s)"
                + (dryRun ? ". Run without --dry-run to write." : ""))
            exit(0)
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
    ///
    /// `--model` is filed on the recording, so the next run of any kind uses it
    /// too and a job interrupted by a crash resumes on it. This used to write
    /// `Settings.model = choice` instead, which meant transcribing one meeting
    /// with `--model v3` quietly changed the model **every future recording**
    /// would use, with nothing anywhere reporting it.
    ///
    /// With no flag the recording's own model wins, not the app default. The
    /// two differ for exactly the recordings somebody has already had to
    /// correct, which are the ones most likely to be run again.
    private static func transcribeRecording(_ recording: Recording, format: String,
                                            chosen: ModelChoice?,
                                            room: Bool? = nil) async -> Never {
        var updated = recording
        if let chosen, updated.metadata.asr_model != chosen.id {
            updated.metadata.asr_model = chosen.id
            try? updated.save()
        }
        // Stored on the recording rather than passed to the run, the same shape
        // as the model and for the same reason: the answer has to survive a
        // crash and the relaunch that re-runs the job, and the folder is the
        // only thing that does. `room_auto` cleared marks it as somebody's.
        if let room, updated.metadata.room != room || updated.metadata.room_auto == true {
            updated.metadata.room = room
            updated.metadata.room_auto = nil
            try? updated.save()
        }
        let choice = chosen ?? updated.asrModel

        // **The same lease the queue takes, and for the same reason.** This
        // command is a second way into the pipeline, so a Mac running it while
        // the other Mac's queue is on the same recording is exactly the race
        // the lease exists to stop, and a path that skipped it would be a hole
        // in the guard rather than a shortcut around it.
        let outcome = await CloudSyncHost.shared.takeTranscriptionLease(updated.id)
        if let lease = outcome.holder {
            let who = await CloudSyncHost.deviceName(for: lease.device) ?? "another device"
            fail("\(who) is transcribing this recording. It will arrive here when that "
                 + "Mac has finished, or try again after \(ListenKit.Metadata.stamp(lease.expires)).")
        }
        if outcome == .unreachable,
           CloudSyncCore.othersRunLooksLive(
               transcribedBy: updated.metadata.transcribed_by,
               state: updated.metadata.state,
               started: updated.metadata.transcribe_started,
               finished: updated.metadata.transcribe_finished,
               device: await CloudSyncHost.deviceID) {
            fail("\(updated.metadata.transcribed_on ?? "another device") started transcribing "
                 + "this recording and iCloud cannot be reached to check whether it finished. "
                 + "Try again when this Mac is back online.")
        }
        await MainActor.run { updated.markTranscribeStarted() }

        // A Mac that was given a master and never had the tracks is an
        // ordinary state now, and this command meets it as often as the queue
        // does. Without the split it finds no audio at all on a machine whose
        // own library says it has some.
        // **Not a `defer`.** Both ways out of this function are `exit`, which
        // does not unwind, so a deferred cleanup here never runs: measured by
        // running it, which left a 60 MB `mic.wav` beside a master on a Mac
        // that had deliberately not kept the raw audio.
        let splitHere = updated.splitMasterIfNeeded()
        if splitHere { log("split the master into its tracks") }
        func dropSplitTracks() { if splitHere { updated.removeSplitTracks() } }

        log("transcribing with \(choice.title)")
        do {
            let t0 = Date()
            // The percentage as well as the sentence: this is the one place the
            // pipeline's progress can be watched without a window, so it is
            // also where a stage that is not moving has to be visible.
            let transcript = try await Pipeline().run(updated, using: choice) {
                log("\($0.message) (\(Int(($0.overall * 100).rounded()))%)")
            }
            // The same bookkeeping the queue does, through the same call, so
            // the two cannot come to different conclusions about a recording
            // they both just transcribed.
            updated.markTranscribed(transcript)
            updated.markTranscribeFinished()
            dropSplitTracks()
            await CloudSyncHost.shared.releaseTranscriptionLease(updated.id)
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
            // The lease goes back on failure too. A run that dies holding one
            // is fifteen minutes in which nothing retries, anywhere.
            updated.markTranscribeFinished()
            dropSplitTracks()
            await CloudSyncHost.shared.releaseTranscriptionLease(updated.id)
            fail(error.localizedDescription)
        }
    }

    /// `listen transcribe <file> --diarize`: the whole pipeline over one file.
    private static func transcribeDiarized(_ url: URL, format: String,
                                           choice: ModelChoice) async -> Never {
        let pipeline = Pipeline()
        do {
            let t0 = Date()
            let transcript = try await pipeline.runFile(url, using: choice) { log($0) }
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

        // Watch the levels the meters are drawn from, so that path can be checked
        // with no window. "The audio arrived" and "the meter moved" are separate
        // claims: they leave the same callback by different routes, and a broken
        // sink draws a flat strip over a perfectly good recording, which is
        // indistinguishable on screen from the dead microphone the strips exist
        // to report. Peaks are printed at the end beside the file sizes.
        await MainActor.run {
            Capture.shared.addLevelSink(Capture.LevelPeaks.shared) { track, level in
                switch track {
                case .you:  Capture.LevelPeaks.shared.you = max(Capture.LevelPeaks.shared.you, level)
                case .them: Capture.LevelPeaks.shared.them = max(Capture.LevelPeaks.shared.them, level)
                }
            }
        }

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
        // A peak of 0 on a track whose file has audio in it means the meter path
        // is broken, not the microphone. That is the one failure the strips
        // themselves cannot report, because a broken meter and a dead microphone
        // draw the same flat line.
        log(String(format: "levels: you %.3f, them %.3f (peak, 0...1)",
                   Capture.LevelPeaks.shared.you, Capture.LevelPeaks.shared.them))
        // The folder, on stdout, so it composes: `listen transcribe $(listen record ...)`.
        print(recording.folder.path)
        exit(0)
    }

    // MARK: - Asking an agent

    /// `listen ask [<question>]`: put a question to Claude Code, Codex or an
    /// OpenAI-compatible endpoint.
    ///
    /// This is the same engine the window uses, with a terminal in front of it,
    /// and it exists first because of what it can show that a chat box cannot.
    /// A wrong answer here has three possible causes: the agent could not be
    /// found, the agent could not reach the library, or the agent read the
    /// wrong part of it. `--print-command` settles the first, the tool calls on
    /// stderr settle the second, and `--json` hands over the raw stream for the
    /// third. None of those are visible from inside a window.
    ///
    /// The answer goes to stdout and everything else to stderr, which is the
    /// rule `listen notes read` already follows, so `listen ask … > answer.md`
    /// gets the answer and nothing else.
    private static func ask(_ args: [String]) -> Never {
        var backend: AgentBackend?
        var allowWrites = false
        var resume: String?
        var model: String?
        var rawStream = false
        var printCommand = false
        var printRequest = false
        var streaming = false
        /// A base URL for this one run, which is the whole test mechanism for
        /// the endpoint backend: it tries a server without writing anything
        /// into preferences, so measuring one does not reconfigure the app.
        var endpointOverride: URL?
        var words: [String] = []

        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--claude":        backend = .claude
            case "--codex":         backend = .codex
            case "--endpoint":      backend = .endpoint
            case "--write":         allowWrites = true
            case "--stream":        streaming = true
            case "--json":          rawStream = true
            case "--print-command": printCommand = true
            case "--print-request": printRequest = true
            case "--to":
                index += 1
                guard index < args.count else { fail("--to needs a base URL.") }
                guard let url = URL(string: args[index]), url.host != nil else {
                    fail("--to needs a base URL, such as http://localhost:11434/v1")
                }
                endpointOverride = url
                backend = .endpoint
            case "--resume":
                index += 1
                guard index < args.count else { fail("--resume needs a session id.") }
                resume = args[index]
            case "--model":
                index += 1
                guard index < args.count else { fail("--model needs a model name.") }
                model = args[index]
            default:
                guard !arg.hasPrefix("--") else {
                    fail("unknown option `\(arg)`. Try `listen help`.")
                }
                words.append(arg)
            }
            index += 1
        }

        // Joined with a space, the way `listen me` and `listen title` do, so
        // the shell quoting is optional for a plain question.
        let question = words.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { agentReport() }

        let status: AgentStatus
        if let endpointOverride {
            // **Deliberately not probed.** The point of `--to` is to try a URL
            // that may well not be working, and a probe here would refuse it
            // with a guess where the real request is about to say exactly what
            // is wrong: refused key, no such model, tools unsupported.
            status = AgentStatus(backend: .endpoint, path: endpointOverride, version: nil,
                                 signedIn: true, account: nil)
        } else if let backend {
            status = AgentCLI.status(backend)
            guard status.path != nil else {
                fail("\(backend.name) is not installed. \(backend.installHint)")
            }
        } else if let chosen = AgentCLI.chosen() {
            status = chosen
        } else {
            fail("no agent found. `listen ask` with no question lists what was "
                 + "looked for and where.")
        }
        guard let path = status.path else { fail("\(status.name) is not set up.") }
        if status.signedIn == false {
            fail("\(status.name) is installed but not signed in. "
                 + status.backend.installHint)
        }

        // A CLI resumes its own thread by id. An endpoint has no thread, so the
        // same flag names a conversation in this library and the turns are
        // replayed into the request. Same word, same intent, and the two
        // mechanisms never meet: `AgentChat` ignores `resume` and `AgentRun`
        // ignores `history`.
        var history: [Chat.Turn] = []
        if status.backend == .endpoint, let resume {
            guard let chat = Chat.load(id: resume) else {
                fail("no conversation `\(resume)`. For an endpoint, --resume takes a "
                     + "conversation id from the library rather than a session id.")
            }
            history = chat.turns
        }

        let query = AgentRun.Question(text: question, backend: status.backend, path: path,
                                      resume: status.backend == .endpoint ? nil : resume,
                                      provider: status.provider, history: history,
                                      allowWrites: allowWrites,
                                      // A provider has no default model of its
                                      // own to fall back on, so the preference
                                      // stands in when the flag is absent. Keyed
                                      // by `status.key`, which is the provider's
                                      // id: `agentModel_endpoint` belongs to no
                                      // provider now and always read as nil.
                                      model: model ?? Settings.agentModel(status.key),
                                      streaming: streaming)

        if printRequest {
            // What `--print-command` is for the CLIs. The key is never in it:
            // it rides in a header, and this prints the body, so there is
            // nothing to redact and nothing that can leak into a bug report.
            guard status.backend == .endpoint else {
                fail("--print-request is for a provider. For \(status.name), "
                     + "--print-command prints what would run.")
            }
            let chat = AgentChat(query, on: DispatchQueue(label: "listen.ask.print")) { _ in }
            let body = chat.requestBody()
            guard let data = try? JSONSerialization.data(
                withJSONObject: body,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8) else {
                fail("the request could not be encoded.")
            }
            print("POST " + path.appendingPathComponent("chat/completions").absoluteString)
            print(text)
            exit(0)
        }

        if printCommand {
            guard status.backend != .endpoint else {
                fail("there is no command: an endpoint is a URL, not a program. "
                     + "--print-request shows the request body instead.")
            }
            // Quoted well enough to paste back into a shell, which is the only
            // reason this exists: a flag that is wrong in Listen has to be
            // reproducible outside it.
            let quoted = ([path.path] + AgentRun.arguments(for: query)).map { part -> String in
                // The empty string has to be quoted explicitly. `allSatisfy` is
                // vacuously true for it, so `--tools ""` printed as `--tools`
                // and the pasted command meant the opposite of what Listen runs.
                guard !part.isEmpty else { return "''" }
                return part.allSatisfy { $0.isLetter || $0.isNumber || "-_./=".contains($0) }
                    ? part : "'" + part.replacingOccurrences(of: "'", with: "'\\''") + "'"
            }
            print(quoted.joined(separator: " "))
            exit(0)
        }

        // A CLI's raw stream is its own stdout, so it is dumped by running the
        // process with nothing in the way. An endpoint's is an HTTP response
        // that only `AgentChat` can obtain, so the raw payloads are tapped on
        // their way past instead. Both print the bytes the parser saw and
        // nothing this file has interpreted, which is the only property that
        // makes either useful.
        if rawStream && status.backend != .endpoint { runAgentRaw(query) }

        // `--to` is deliberately not a configured provider, so it has no
        // stored name. It gets one from the catalogue by URL, which names
        // `http://localhost:11434/v1` as Ollama rather than as a bare host.
        let label = endpointOverride.map { Provider.custom(url: $0).name } ?? status.name
        // The backend, not the question: a spawned `listen ask` sends stderr
        // to the caller's log, and the question names what the meeting was
        // about. The user typed it one line up.
        log("\(label) · asking")
        trace("  \(question)")
        let done = DispatchSemaphore(value: 0)
        var failure: String?
        // Not `.main`: this thread is about to block on the semaphore, and
        // events delivered to the main queue would never be drained.
        let events = DispatchQueue(label: "listen.ask")
        let run = query.session(on: events) { event in
            switch event {
            case .started(let session):
                log("session \(session)")
            case .thinking:
                break
            case .toolCall(let name, let detail):
                log("  · \(name)\(detail.isEmpty ? "" : " " + detail)")
            case .toolResult:
                break
            case .note(let text):
                log("  ! \(text)")
            case .offline(let trouble):
                // On stderr with the rest of the tracing, because stdout is the
                // answer. A run that is waiting for the network says so once
                // here and once again when it comes back.
                log("  ! " + (trouble ?? "the connection is back."))
            case .text(let text):
                // With --json the raw payloads are already going to stdout, and
                // a second, cooked copy of the same words interleaved with them
                // would make the one output nobody may misread unreadable.
                guard !rawStream else { break }
                print(text)
            case .textDelta(let text):
                guard !rawStream else { break }
                // Unbuffered and without a newline, because a delta is a few
                // characters in the middle of a sentence. `print` would break
                // the line and stdout would stop being the answer.
                FileHandle.standardOutput.write(Data(text.utf8))
            case .finished(let outcome):
                if query.streaming && !rawStream {
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
                var parts = ["\(outcome.toolCalls) tool call"
                             + (outcome.toolCalls == 1 ? "" : "s")]
                if let ms = outcome.durationMS {
                    parts.append(String(format: "%.1fs", Double(ms) / 1000))
                }
                // No cost line. See `AgentRun.Outcome.costUSD`: it is metered
                // API pricing, nobody reaching this is on metered pricing, and
                // a number that is not a bill reads as one.
                if let session = outcome.session {
                    parts.append("continue with --resume \(session)")
                }
                log(parts.joined(separator: ", "))
                failure = outcome.failure
                done.signal()
            }
        }

        if rawStream, let chat = run as? AgentChat {
            chat.onRawLine = { print($0) }
        }

        do { try run.start() } catch {
            // A refusal to start is not always a broken binary, and prefixing
            // "could not start /opt/homebrew/bin/claude:" onto "No internet
            // connection" sends somebody to reinstall a CLI that is fine. The
            // endpoint's own refusals are the same shape: "no model is chosen"
            // is not a fault in a path.
            guard !(error is AgentRun.Failure), !(error is AgentChat.Failure) else {
                fail(error.localizedDescription)
            }
            fail("could not start \(path.path): \(error.localizedDescription)")
        }
        done.wait()
        if let failure { fail(failure) }
        exit(0)
    }

    /// `listen ask --json`: the agent's own event stream, untouched.
    ///
    /// Not routed through `AgentRun`, on purpose. This is the thing to look at
    /// when `AgentRun`'s reading of the stream is what is suspected, so it must
    /// not be the same code doing the reading.
    private static func runAgentRaw(_ query: AgentRun.Question) -> Never {
        let process = Process()
        process.executableURL = query.path
        process.arguments = AgentRun.arguments(for: query)
        process.currentDirectoryURL = AgentRun.workspace
        process.environment = AgentRun.childEnvironment(for: query.path)
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            fail("could not start \(query.path.path): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        exit(process.terminationStatus)
    }

    /// `listen provider`: add, key and remove the OpenAI-compatible backends.
    ///
    /// The settings pane is the route most people take. This exists for the
    /// same reason `listen ask` does: a state that can only be reached by
    /// clicking is a state nobody can set up in a script, reproduce in a bug
    /// report, or check on a machine over SSH.
    ///
    /// **A key is read from stdin and never from an argument.** A key in `argv`
    /// is in the shell history, in `ps` output while it runs, and in any
    /// transcript of the terminal. `listen provider key <id>` reads a line
    /// instead, so `pbpaste | listen provider key openrouter` leaves nothing
    /// behind.
    private static func provider(_ args: [String]) -> Never {
        let sub = args.first ?? "list"
        let rest = Array(args.dropFirst())

        switch sub {
        case "list":
            let configured = Settings.providers
            if configured.isEmpty {
                print("No providers added.")
            } else {
                let width = configured.map(\.name.count).max() ?? 8
                for provider in configured {
                    let name = provider.name.padding(toLength: width, withPad: " ", startingAt: 0)
                    var parts = [provider.base.absoluteString]
                    if provider.needsKey {
                        parts.append(AgentKey.has(provider.host) ? "key stored" : "no key")
                    }
                    if let model = Settings.agentModel(provider.id) { parts.append(model) }
                    print("\(name)  \(parts.joined(separator: "   "))")
                    log("  " + provider.exposure.sentence)
                }
            }
            print("")
            print("Available to add:")
            let already = Set(configured.map(\.id))
            for known in Provider.catalogue where !already.contains(known.id) {
                let id = known.id.padding(toLength: 12, withPad: " ", startingAt: 0)
                print("  \(id)  \(known.base.absoluteString)   (\(known.note))")
            }
            exit(0)

        case "add":
            guard let word = rest.first else {
                fail("`listen provider add <id|url>` needs a catalogue id or a base URL.")
            }
            let provider: Provider
            if let known = Provider.known(word.lowercased()) {
                provider = known
            } else if let url = URL(string: word), url.host != nil,
                      url.scheme == "http" || url.scheme == "https" {
                if let problem = Provider.schemeProblem(url) { fail(problem) }
                provider = Provider.custom(url: url, name: rest.dropFirst().first)
            } else {
                fail("`\(word)` is neither a catalogue id nor a base URL. "
                     + "`listen provider list` shows what is available.")
            }
            // The profile's refusal comes before the question: asking y/n
            // about a provider a managed profile will refuse anyway reads as
            // the CLI not knowing its own rules.
            if Settings.agentLoopbackOnly, !provider.isLoopback {
                fail("your organisation's device profile restricts Ask to "
                     + "endpoints on this Mac, so `\(provider.name)` cannot be "
                     + "added. Ollama and LM Studio still work.")
            }
            // Said on the way in rather than after the save, and answered
            // before it: this is the moment the claim on the tin changes, so
            // a non-loopback provider is confirmed the way the pane confirms
            // it. `--yes` is for scripts, which cannot answer.
            if !provider.isLoopback && !rest.contains("--yes") {
                print("Send transcripts to \(provider.host)?")
                print(provider.exposure.sentence)
                print("Type y to add it, anything else to stop: ", terminator: "")
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
                guard answer == "y" || answer == "yes" else {
                    fail("Not added.")
                }
            }
            guard Settings.addProvider(provider) else {
                fail("your organisation's device profile restricts Ask to "
                     + "endpoints on this Mac, so `\(provider.name)` cannot be "
                     + "added. Ollama and LM Studio still work.")
            }
            print("\(provider.name)  \(provider.base.absoluteString)")
            print(provider.exposure.sentence)
            if provider.needsKey && !AgentKey.has(provider.host) {
                print("")
                print("Set a key with `listen provider key \(provider.id)`.")
                if let docs = provider.docs { print("Keys: \(docs)") }
            }
            exit(0)

        case "key":
            guard let id = rest.first, let provider = Settings.provider(id) else {
                fail("`listen provider key <id>` needs a provider that is added. "
                     + "`listen provider list` shows them.")
            }
            if rest.contains("--clear") {
                AgentKey.save(nil, for: provider.host)
                print("Key for \(provider.host) removed.")
                exit(0)
            }
            log("Paste the key for \(provider.host) and press return. It is stored "
                + "in the Keychain and never in Listen's preferences.")
            guard let key = readLine(strippingNewline: true)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                fail("nothing was read from stdin, so nothing was stored.")
            }
            guard AgentKey.save(key, for: provider.host) else {
                fail("the Keychain refused to store the key.")
            }
            // Never the key, and not even its length: a length is a fact about
            // a secret that a screenshot should not carry.
            print("Key stored for \(provider.host).")
            exit(0)

        case "model":
            guard let id = rest.first, let provider = Settings.provider(id) else {
                fail("`listen provider model <id> [<model>]` needs a provider that is added.")
            }
            guard rest.count > 1 else {
                let status = provider.probe()
                print(Settings.agentModel(provider.id) ?? "(default)")
                for model in status.models { log("  " + model.id) }
                exit(0)
            }
            Settings.setAgentModel(provider.id, rest[1])
            // The same bookkeeping the window does, so the composer's menu
            // reflects a model chosen at the terminal. Two paths that disagree
            // about what has been used is a menu that is wrong for whichever
            // one you did not use.
            Settings.noteModelUsed(provider.id, rest[1])
            print("\(provider.name) will use \(rest[1]).")
            exit(0)

        case "remove":
            guard let id = rest.first, let provider = Settings.provider(id) else {
                fail("`listen provider remove <id>` needs a provider that is added.")
            }
            AgentKey.save(nil, for: provider.host)
            Settings.removeProvider(provider.id)
            print("\(provider.name) removed, with its key and model.")
            exit(0)

        default:
            fail("unknown subcommand `\(sub)`. Try list, add, key, model or remove.")
        }
    }

    /// `listen ask` with no question: what is installed, and what Listen would
    /// use.
    ///
    /// Prints the paths it found rather than a yes or no. "Not installed" is
    /// the answer somebody with two copies of the CLI needs least, and the path
    /// is what tells them which one Listen picked.
    private static func agentReport() -> Never {
        let all = AgentCLI.statuses()
        // Padded by hand. `String(format: "%-12@", …)` does not honour the
        // width for an object argument, so the columns did not line up.
        //
        // The width is measured rather than fixed at 12, because an endpoint is
        // named by whoever configured it: `padding(toLength:)` **truncates** as
        // well as pads, so a hardcoded number turned "Custom endpoint" into
        // "Custom endpo" the first time this ran with three backends.
        let width = all.map(\.name.count).max() ?? 12
        for status in all {
            let label = status.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print(label + "  " + status.summary)
            if status.path == nil { log("  " + status.backend.installHint) }
        }
        print("")
        // `choose(from: all)`, not `chosen()`. The latter runs the whole
        // detection again, which doubled the cost of this report: measured at
        // 6.1s where one detection is about 3s.
        guard let chosen = AgentCLI.choose(from: all) else {
            print("No usable agent, so the library cannot be asked anything yet.")
            exit(1)
        }
        print("Listen would use \(chosen.name).")
        print("")
        print("It reaches the library only through the tools `listen mcp` serves, which")
        print("means it can read transcripts, people, tags and notes, and can write")
        print("nothing at all unless you pass --write, which adds notes and tags.")
        if chosen.backend.isCLI {
            print("Your own agent settings, hooks, plugins and other MCP servers are not")
            print("loaded.")
        } else {
            // The sentence the CLI backends earn by being sandboxed is not the
            // one an endpoint earns, and printing theirs here would be a claim
            // about somebody else's server. What is true of this one is where
            // the words go, which is the only part Listen knows.
            print("Listen runs the tool loop itself here, so no second program is started")
            print("and no configuration of yours is read.")
            if let provider = chosen.provider {
                print("")
                print(provider.exposure.sentence)
            }
        }
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        log(message)
        exit(1)
    }
}
