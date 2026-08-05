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
        if Queue.shared.running == id { return Queue.shared.stage ?? "transcribing" }
        if Queue.shared.isQueued(id) { return "waiting" }
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

    /// The transcript as one string, for searching.
    var transcriptText: String {
        storedTurns.map(\.text).joined(separator: " ")
    }

    var storedTranscript: StoredTranscript? {
        guard let data = try? Data(contentsOf: transcriptURL) else { return nil }
        return try? JSONDecoder().decode(StoredTranscript.self, from: data)
    }

    var storedTurns: [Turn] {
        guard let data = try? Data(contentsOf: turnsURL),
              let turns = try? JSONDecoder().decode([Turn].self, from: data)
        else { return [] }
        return turns
    }
}
