import AppKit

/// How a recording is described on screen and in the CLI.
///
/// Kept apart from `Recording`, which is the on-disk shape, so that changing
/// the wording never risks changing the format.
extension Recording {
    /// When it was recorded, parsed once so the four places that want it do not
    /// each keep their own formatter and their own idea of what a bad string
    /// means.
    var date: Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: metadata.recorded_at)
    }

    /// The full date and time, for the detail pane where there is no grouping
    /// heading to supply the day.
    var when: String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// A recording nobody has named yet.
    var isUntitled: Bool { metadata.title == Metadata.untitled }

    /// The title as a person reads it.
    ///
    /// **The placeholder is worded here and stored as `Untitled`, and the two
    /// must not be reconciled into one string.** `Metadata.untitled` is not a
    /// word on screen, it is the identity `isUntitled` compares against, which
    /// is what `mayTitle` gates every automatic titler on. Renaming the constant
    /// renames nothing already on disk, so every recording carrying the old
    /// string would stop reading as unnamed and become frozen: indistinguishable
    /// from a title somebody typed, and never named by the calendar or by its
    /// speakers again. That is exactly the failure this file's header exists to
    /// prevent, "so that changing the wording never risks changing the format".
    ///
    /// The wording is therefore free to change as often as anybody likes, and no
    /// migration is ever owed for it.
    ///
    /// Screen and the CLI's human output. `listen title <id>` read back, the
    /// MCP server and an export all print the stored string instead: a script
    /// comparing against `Untitled` and a file being written are not places a
    /// change of wording may reach.
    var displayTitle: String {
        isUntitled ? Metadata.untitledDisplay : metadata.title
    }

    /// The app the call was in, as somebody reads it. Nil when nothing was on
    /// a call, which is most recordings made by pressing Record in a quiet
    /// room, and every one imported from a recorder that did not note it.
    ///
    /// The live lookup wins over the stored name, so an app that has been
    /// renamed on disk is called what it is called now. The stored name is the
    /// fallback and it is why it is stored: an uninstalled app resolves to
    /// nothing, and printing the identifier as though it were a name is worse
    /// than printing the name it had when the recording was made.
    var appLabel: String? {
        guard let id = appBundleID else { return metadata.app_name }
        return AppNames.installedName(id) ?? metadata.app_name ?? id
    }

    /// A filename stem for export. An untitled recording is dated, because a
    /// folder of `Untitled.md`, `Untitled 2.md` is a folder nobody can read.
    var exportName: String {
        var name = metadata.title
        if isUntitled, let date {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH.mm"
            name = "Untitled " + f.string(from: date)
        }
        return name.replacingOccurrences(of: "/", with: "-")
    }

    var lengthText: String {
        Self.length(metadata.duration)
    }

    /// Shared with the row for the recording in progress, whose length is not
    /// on disk yet: `metadata.duration` is written when capture stops, so a
    /// live row asking the file would say nothing for an hour.
    static func length(_ seconds: TimeInterval) -> String {
        let t = Int(seconds)
        guard t > 0 else { return "" }
        return t >= 3600 ? String(format: "%dh %02dm", t / 3600, (t % 3600) / 60)
                         : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// What the row says about progress, and nothing else.
    ///
    /// Empty once there is a transcript. There used to be a "needs labelling"
    /// state here with a filter tab to match, and both went: an unnamed speaker
    /// now reads as "Speaker A" in the transcript, which is legible on its own,
    /// so the list had a status telling people to go and fix something that did
    /// not look broken.
    @MainActor
    var stateText: String {
        // Capture outranks everything below it, and is the one state no file on
        // disk can report: a recording in progress looks exactly like one that
        // was never transcribed.
        if isLive { return "recording" }
        // The percentage first, and the stage after it.
        //
        // A 280 point sidebar truncates the tail, and between "47%" and
        // "transcribing the other participants" the number is what a glance at
        // the row is for. Ordered this way the row degrades to "47% · transcri…"
        // rather than losing the only part that changes. The whole sentence is
        // in the pane, under the picture, where there is room for it.
        if Queue.shared.running == id {
            guard let step = Queue.shared.progress else { return "transcribing" }
            return "\(Int((step.overall * 100).rounded()))% · \(step.message)"
        }
        if Queue.shared.isQueued(id) { return "waiting" }
        if let activity = CloudSyncHost.shared.activity(for: id),
           activity.stage != .ready {
            let stage = activity.title.prefix(1).lowercased()
                + String(activity.title.dropFirst())
            if let percentage = activity.percentage { return "\(percentage) · \(stage)" }
            return stage
        }
        switch effectiveState {
        case .transcribing:  return "transcribing"
        case .failed:        return "could not transcribe"
        case .pending:       return hasTranscript ? "" : "not transcribed"
        case .needsLabelling, .done, .unconfirmed: return ""
        }
    }

    /// This is the recording being captured right now.
    @MainActor
    var isLive: Bool { Capture.shared.current?.id == id }

    /// The microphone track was captured and holds no audio at all.
    ///
    /// Worth saying on every surface that describes a recording, because the
    /// transcript itself cannot. A meeting with a silent mic track produces one
    /// that reads exactly like a conversation in which the other person did all
    /// the talking, with nothing in it to suggest a second person was ever
    /// there. See `Metadata.mic_silent`.
    var micWasSilent: Bool { metadata.mic_silent == true }

    // MARK: - Who did the work

    /// The device that made, or is making, this transcript, as a person reads
    /// it. Nil when nothing recorded it, which is every recording transcribed
    /// before there was a second device to wonder about.
    ///
    /// The stored name rather than the roster's, because a device drops off the
    /// roster after a month of silence and "transcribed on a machine that is
    /// not in your list" is worse than a name that has since changed. The
    /// roster is consulted only to improve on it. See `Metadata.transcribed_by`.
    @MainActor
    var transcriberName: String? {
        guard let device = metadata.transcribed_by else { return nil }
        if device == CloudSyncHost.deviceID { return nil }
        return CloudSyncHost.deviceName(for: device) ?? metadata.transcribed_on
    }

    /// Whether this Mac is the one that did it.
    @MainActor
    var transcribedHere: Bool { metadata.transcribed_by == CloudSyncHost.deviceID }

    /// How long the run took, in words. Nil until both ends are recorded,
    /// which is every recording made before this field existed and every one
    /// still going.
    var transcribeDuration: String? {
        guard let started = metadata.transcribe_started.flatMap(Recording.moment),
              let finished = metadata.transcribe_finished.flatMap(Recording.moment),
              finished > started else { return nil }
        return Recording.spell(finished.timeIntervalSince(started))
    }

    /// A span of time as a duration rather than as a clock.
    ///
    /// Not `length`, which reads `1:23:45` and is right for how long a meeting
    /// is: "transcribed in 1:23:45" invites the reading that it finished at
    /// twenty to two. A duration says its units.
    static func spell(_ seconds: TimeInterval) -> String {
        let t = Int(seconds.rounded())
        if t < 60 { return "\(max(t, 1)) s" }
        if t < 3600 { return "\(t / 60) min" }
        let minutes = (t % 3600) / 60
        return minutes == 0 ? "\(t / 3600) h" : "\(t / 3600) h \(minutes) min"
    }

    /// When the run began, if it has.
    var transcribeStarted: Date? { metadata.transcribe_started.flatMap(Recording.moment) }

    /// One line: how long the transcription took, and which machine did it
    /// when that was not this one.
    ///
    /// **The duration is shown everywhere and the device is not**, which is a
    /// correction to the first shape of this. That one hid the whole line
    /// unless the library had more than one device in it, on the grounds that
    /// naming a machine is noise when there is only one. The naming is; the
    /// hour it took is not, and it is the same fact on one Mac as on three.
    /// "Transcribed on this Mac" was the noise, so that is the half that goes.
    @MainActor
    var transcribedLine: String? {
        guard hasTranscript else { return nil }
        let elsewhere = transcribedHere ? nil : (transcriberName ?? metadata.transcribed_on)
        switch (elsewhere, transcribeDuration) {
        case (let machine?, let took?): return "transcribed on \(machine) in \(took)"
        case (let machine?, nil):       return "transcribed on \(machine)"
        case (nil, let took?):          return "transcribed in \(took)"
        case (nil, nil):                return nil
        }
    }

    /// The same instant parser `date` uses, shared so a bad string means one
    /// thing everywhere.
    static func moment(_ text: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: text)
    }

    /// How long ago something happened, in words a sentence can take.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 120 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) minutes ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) hours ago" }
        return "\(Int(seconds / 86_400)) days ago"
    }

    /// What produced this transcript, as somebody reads it.
    ///
    /// The transcript's own record of what ran, never the recording's choice for
    /// the next run: those differ for exactly the minutes between choosing a
    /// model and the job finishing, which is when somebody is watching.
    ///
    /// A repo this app has never shipped, which is every legacy import, prints
    /// as it is. It is still the true answer to "what made this", and a name
    /// nobody recognises is more use than no name.
    static func modelName(_ repo: String) -> String {
        ModelChoice.forRepo(repo)?.title ?? repo
    }

    /// The transcript as one string, for searching. Cached with the turns it
    /// is built from: `RecordingFilter.search` asks every recording for this
    /// on every keystroke.
    var transcriptText: String { TurnStore.text(at: turnsURL) }

    var storedTranscript: StoredTranscript? {
        guard let data = try? Data(contentsOf: transcriptURL) else { return nil }
        return try? JSONDecoder().decode(StoredTranscript.self, from: data)
    }

    var storedTurns: [Turn] { TurnStore.turns(at: turnsURL) }
}

/// Decoded `turns.json`, kept in memory and checked against the file.
///
/// **Every keystroke in the search field decoded the whole library.**
/// `RecordingFilter.search` scans turn by turn, and `storedTurns` re-read and
/// re-decoded the file on every access, so typing four letters cost four passes
/// over every transcript on disk. Measured on a fixture the shape of the
/// development library, 120 hour-long meetings and 8 MB of turns:
///
///     reload: Recording.all      7 ms
///     reload: Notes.all          8 ms
///     reload: Tags.all           0 ms
///     reload: filter.search    290 ms      <- all of it here
///     sidebar reload           380 ms      <- and two or three of these a keystroke
///     galaxy search              6 ms
///
/// The lag was reported against the galaxy, which is 6 ms of it. `LISTEN_DEBUG`
/// still prints all six lines, because the next person to be sure where the
/// time goes should be able to check rather than believe this comment.
///
/// **Keyed on the file's own modification date and size, never on a
/// notification.** Four writers touch these: the window, the CLI, the
/// transcription queue and a sync pull. A `stat` per access costs microseconds
/// and cannot go stale, where a cache invalidated by whoever remembered to
/// invalidate it would eventually hand somebody an old transcript.
enum TurnStore {
    private struct Entry {
        var stamp: Date
        var size: Int
        var turns: [Turn]
        /// The turns joined, built on the first ask and kept: the search's
        /// cheap pass over a whole recording needs it once per keystroke.
        var joined: String?
        var cost: Int
        var used: UInt64
    }

    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]
    private static var held = 0
    private static var clock: UInt64 = 0

    /// About 32 MB of turn text, which is six times the development library and
    /// still bounded: a library past the cap keeps the ones most recently read
    /// and pays the decode again for the rest. The alternative, no bound, is a
    /// process that grows with every recording anybody searches.
    private static let budget = 32 * 1024 * 1024

    /// Is there room for another transcript, for a warm that should stop
    /// rather than evict what it has just read? See `Sidebar.warmTurns`.
    static var wantsMore: Bool {
        lock.lock(); defer { lock.unlock() }
        return held < budget
    }

    /// Read on the main thread by the sidebar and on background queues by the
    /// galaxy, the context extractor and the enroller, so this is locked.
    static func turns(at url: URL) -> [Turn] { entry(at: url)?.turns ?? [] }

    /// Every turn joined with a space, which is what a search scans first.
    static func text(at url: URL) -> String {
        guard let found = entry(at: url) else { return "" }
        if let joined = found.joined { return joined }
        let joined = found.turns.map(\.text).joined(separator: " ")
        lock.lock()
        entries[url.path]?.joined = joined
        lock.unlock()
        return joined
    }

    private static func entry(at url: URL) -> Entry? {
        let key = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: key)
        let stamp = (attributes?[.modificationDate] as? Date) ?? .distantPast
        let size = (attributes?[.size] as? Int) ?? -1
        lock.lock()
        if let hit = entries[key], hit.stamp == stamp, hit.size == size {
            clock += 1
            entries[key]?.used = clock
            lock.unlock()
            return hit
        }
        lock.unlock()
        // Decoded outside the lock. Two threads asking for the same cold file
        // decode it twice, which costs one wasted parse; holding the lock
        // across the parse would put the galaxy's background read in front of
        // the keystroke this exists to make fast.
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Turn].self, from: data)
        else { return nil }
        let cost = decoded.reduce(0) { $0 + $1.text.utf8.count } * 2
        lock.lock()
        clock += 1
        if let old = entries[key] { held -= old.cost }
        let fresh = Entry(stamp: stamp, size: size, turns: decoded,
                          joined: nil, cost: cost, used: clock)
        entries[key] = fresh
        held += cost
        while held > budget, entries.count > 1,
              let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            held -= entries.removeValue(forKey: oldest)?.cost ?? 0
        }
        lock.unlock()
        return fresh
    }
}

extension Note {
    /// When the note came into being, parsed exactly the way `Recording.date`
    /// is, because the sidebar now sorts the two into one list and a second
    /// formatter with its own idea of a bad string would sort them differently.
    ///
    /// **`created`, never `updated`.** The list is chronological by when a thing
    /// happened, and a recording has nothing that can move it: fixing a typo in
    /// a note would otherwise send a meeting from March back to the top of the
    /// library, which is the one thing a date-ordered list must not do.
    var date: Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        return parser.date(from: created)
    }
}
