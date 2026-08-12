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
        alert.messageText = "Who is \(SpeakerName.display(speaker))?"

        let suggestions = VoiceBank.suggestions(for: speaker, in: recording)
        alert.informativeText = suggestions.isEmpty
            ? "Naming a speaker updates this transcript only."
            : "Sounds like: " + suggestions.prefix(3).map(\.summary).joined(separator: ", ")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = VoiceBank.currentName(of: speaker, in: recording) ?? ""
        field.placeholderString = "Name"

        // Who was invited, from the calendar event this recording was matched
        // to. A different signal from "sounds like" above and kept visually
        // apart from it on purpose: one is who the voice bank thinks this voice
        // resembles, the other is who was actually in the room. Neither decides
        // anything; both fill the field.
        let invited = Invitations(recording: recording, field: field)
        alert.accessoryView = invited.accessory
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
            // Only what was picked, and only if it survived to Save. Picking a
            // suggestion is the assertion that this address is this person;
            // typing a name is not, and links nothing. Editing the name after
            // picking one breaks the claim, which is why the address is
            // remembered against the button rather than against the field.
            invited.claim(name)
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

    /// Ask before deleting a speaker's lines, counting what goes.
    ///
    /// **One implementation, shared with `SpeakerPicker`**, which offers the
    /// same repair from a popover. Two warnings about one destructive edit is
    /// how one of them ends up milder than the other, and the mild one is the
    /// one somebody reads.
    ///
    /// It counts because the word "segments" hid the size: somebody discarded a
    /// speaker holding half a call, expecting it to undo a name they had just
    /// applied, and got a transcript with half its paragraphs deleted. Turns and
    /// minutes are what is on screen, so those are the units it asks in.
    static func confirmDiscard(_ speaker: String, in recording: Recording) -> Bool {
        let mine = recording.storedTurns.filter { $0.speaker == speaker }
        let spoken = Recording.length(mine.reduce(0) { $0 + max(0, $1.end - $1.start) })
        let size = [mine.count == 1 ? "1 turn" : "\(mine.count) turns", spoken]
            .filter { !$0.isEmpty }.joined(separator: " · ")

        let alert = NSAlert()
        alert.messageText = "Delete everything attributed to "
            + "\(SpeakerName.display(speaker))?"
        alert.informativeText = "This removes \(size) from the transcript, and "
            + "the paragraphs on either side join up. It is for a speaker who is "
            + "not a person: silence the diarizer split off with filler written "
            + "over it.\n\nTo take a name off a real speaker instead, cancel and "
            + "use Leave Unnamed, which keeps everything they said.\n\nThe audio "
            + "is untouched, so transcribing again brings it back."
        alert.alertStyle = .warning
        // "Delete" rather than "Discard" on the button that does it. Discard is
        // the mild word for closing a document without saving; this takes words
        // out of a transcript.
        alert.addButton(withTitle: "Delete \(size)")
        alert.addButton(withTitle: "Cancel")
        // Return lands on Cancel, so the destructive one has to be aimed at.
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Drop a speaker's segments entirely.
    ///
    /// For a phantom speaker: diarization finds "someone" in a stretch of
    /// silence or background noise and Parakeet obligingly writes down filler
    /// for it. There is no real person to name and the rows are noise.
    private static func discard(_ speaker: String, in recording: Recording,
                                parent: NSWindow?, done: @escaping () -> Void) {
        guard confirmDiscard(speaker, in: recording) else { done(); return }
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
        alert.messageText = "Merge \(SpeakerName.display(speaker)) into which speaker?"
        alert.informativeText = "Every segment attributed to \(speaker) is reassigned. "
            + "This cannot be undone from here."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: others.map(SpeakerName.display))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              popup.indexOfSelectedItem >= 0,
              popup.indexOfSelectedItem < others.count else { done(); return }
        let target = others[popup.indexOfSelectedItem]

        TranscriptEditor.apply(.merge(speaker, into: target), to: recording)
        done()
    }

}

// ---------------------------------------------------------------------------

/// The guest list from the calendar, as buttons that fill the name field.
///
/// Three sources answer "what is this person called", in descending order of
/// confidence, and `CalendarPerson.bestName` walks them: the contact book first
/// (somebody said so), then the name on the invitation, then a name guessed
/// from the address. The third is why none of this is ever applied on its own.
/// Measured on the development machine, EventKit put the email address in the
/// name field for 118 of 140 attendee entries, so without the book and the
/// guess almost every button here would read as an address.
@MainActor
private final class Invitations {
    let accessory: NSView
    private let field: NSTextField
    /// The address behind the button most recently pressed.
    private var picked: String?

    init(recording: Recording, field: NSTextField) {
        self.field = field

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(field)
        // Assigned before the buttons are built, and not after: their action
        // closures capture `self`, and Swift refuses that while a stored
        // property is still uninitialized.
        accessory = stack

        // Anyone flagged as the user is dropped: the microphone track is `Me`
        // by construction, so offering the user's own name for somebody on the
        // system track would attach it to the wrong person entirely.
        //
        // Anyone already named in this recording is dropped too. They are
        // accounted for, and offering them again invites two speakers to be
        // given one name, which is a merge and belongs on the Merge button
        // where it says what it does.
        let taken = Set(recording.speakers)
        let people = (recording.metadata.calendar_people ?? [])
            .filter { !$0.is_me }
            .filter { !taken.contains($0.bestName ?? "\u{0}") }

        if !people.isEmpty {
            let heading = NSTextField(labelWithString: "In the invitation")
            heading.font = .systemFont(ofSize: 11, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            stack.addArrangedSubview(heading)
        }

        for person in people {
            guard let name = person.bestName ?? person.email else { continue }
            let button = NSButton(title: name, target: nil, action: nil)
            button.bezelStyle = .inline
            button.font = .systemFont(ofSize: 12)
            // The address, always, even when the button already shows a name.
            // Two people called Ryan is the case this has to survive, and the
            // name on the button is the thing that cannot tell them apart.
            button.toolTip = [person.email,
                              person.is_organizer ? "organizer" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            let handler = ActionHandler { [weak self] _ in self?.pick(person, named: name) }
            button.target = handler
            button.action = #selector(ActionHandler.fire(_:))
            objc_setAssociatedObject(button, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
            stack.addArrangedSubview(button)
        }

        // NSAlert sizes an accessory view from its frame, not from its
        // constraints, so a stack left to autolayout arrives zero-high and the
        // sheet looks as though the field is missing.
        stack.layoutSubtreeIfNeeded()
        let size = stack.fittingSize
        stack.frame = NSRect(x: 0, y: 0, width: max(280, size.width), height: size.height)
    }

    private func pick(_ person: CalendarPerson, named name: String) {
        field.stringValue = name
        // The address, not the name. Pressing the button asserts *which
        // attendee* this speaker is; the field says what to call them. Keeping
        // them separate is what makes correcting a guessed name useful rather
        // than destructive: picking "Byjenna0x" and typing "Jenna" over it
        // files that address under Jenna, which is the whole point.
        picked = person.email
    }

    /// Record what was picked, once Save is pressed and not before.
    ///
    /// Nothing is written if the sheet was cancelled, and nothing is written
    /// for a name typed from nothing, because no address was ever asserted.
    func claim(_ name: String) {
        guard let picked else { return }
        ContactBook.link(picked, to: name)
    }
}

// ---------------------------------------------------------------------------

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
