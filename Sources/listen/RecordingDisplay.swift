import AppKit

/// How a recording is described on screen and in the CLI.
///
/// Kept apart from `Recording`, which is the on-disk shape, so that changing
/// the wording never risks changing the format.
extension Recording {
    /// The full date and time, for the detail pane where there is no grouping
    /// heading to supply the day.
    var when: String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: metadata.recorded_at) else { return "" }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    var lengthText: String {
        let t = Int(metadata.duration)
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
        if Queue.shared.running == id { return Queue.shared.stage ?? "transcribing" }
        if Queue.shared.isQueued(id) { return "waiting" }
        switch metadata.stateValue {
        case .transcribing:  return "transcribing"
        case .failed:        return "could not transcribe"
        case .pending:       return hasTranscript ? "" : "not transcribed"
        case .needsLabelling, .done, .unconfirmed: return ""
        }
    }

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
