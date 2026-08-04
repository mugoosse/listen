import AppKit

/// Naming a speaker, and the two destructive repairs.
///
/// Opened by clicking a speaker name in the transcript. It offers a name field,
/// a "sounds like" row ranking this voice against everyone already labelled,
/// and the rest of the roster, so a recurring participant is one click.
///
/// Renaming writes straight to the stored transcript and re-renders. It never
/// re-transcribes: the audio has not changed, and re-running the pipeline to
/// change a string would cost minutes and could come back different.
@MainActor
enum SpeakerSheet {

    static func present(for recording: Recording, speaker: String,
                        in parent: NSWindow?, done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Who is \(speaker)?"

        let suggestions = VoiceBank.suggestions(for: speaker, in: recording)
        alert.informativeText = suggestions.isEmpty
            ? "Naming a speaker updates this transcript only."
            : "Sounds like: " + suggestions.prefix(3).map(\.summary).joined(separator: ", ")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = VoiceBank.currentName(of: speaker, in: recording) ?? ""
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        // Both destructive actions are here rather than in a context menu
        // because both were needed often enough in dashboard.py to earn a
        // place: diarization invents phantom speakers over silence, and splits
        // one real person into two.
        alert.addButton(withTitle: "Merge into…")
        alert.addButton(withTitle: "Discard speaker")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != speaker else { done(); return }
            apply(rename: speaker, to: name, in: recording)
            done()
        case .alertThirdButtonReturn:
            merge(speaker, in: recording, parent: parent, done: done)
        case NSApplication.ModalResponse(rawValue:
                NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            discard(speaker, in: recording, parent: parent, done: done)
        default:
            done()
        }
    }

    // MARK: - Edits

    /// Rewrite one speaker's label everywhere in the stored transcript.
    static func apply(rename speaker: String, to name: String, in recording: Recording) {
        TranscriptEditor.apply(.rename(speaker, to: name), to: recording)
    }

    /// Drop a speaker's segments entirely.
    ///
    /// For a phantom speaker: diarization finds "someone" in a stretch of
    /// silence or background noise and Parakeet obligingly writes down filler
    /// for it. There is no real person to name and the rows are noise.
    private static func discard(_ speaker: String, in recording: Recording,
                                parent: NSWindow?, done: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Discard everything attributed to \(speaker)?"
        alert.informativeText = "Their segments are removed from the transcript. "
            + "The audio is untouched, so transcribing again brings them back."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { done(); return }

        TranscriptEditor.apply(.discard(speaker), to: recording)
        done()
    }

    /// Reassign one speaker's segments onto another.
    ///
    /// For when diarization split one real person into two, which it does when
    /// someone changes microphone, moves away from it, or joins twice.
    private static func merge(_ speaker: String, in recording: Recording,
                              parent: NSWindow?, done: @escaping () -> Void) {
        let others = recording.speakers.filter { $0 != speaker }
        guard !others.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "There is nobody else in this recording to merge into."
            alert.runModal()
            done()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Merge \(speaker) into which speaker?"
        alert.informativeText = "Every segment attributed to \(speaker) is reassigned. "
            + "This cannot be undone from here."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: others)
        alert.accessoryView = popup
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              let target = popup.titleOfSelectedItem else { done(); return }

        TranscriptEditor.apply(.merge(speaker, into: target), to: recording)
        done()
    }

}

extension Recording {
    /// Every speaker in this transcript, in order of first appearance.
    var speakers: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for turn in storedTurns where !seen.contains(turn.speaker) {
            seen.insert(turn.speaker)
            out.append(turn.speaker)
        }
        return out
    }
}
