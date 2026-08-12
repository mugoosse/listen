import Foundation

/// One person, across the whole library.
///
/// The join key is the label written in the transcripts, and nothing cleverer.
/// Voiceprints rank a voice against the bank; they never decide identity. Two
/// recordings hold the same person when somebody said so by naming them the
/// same thing, which is a decision a human made, and a cosine score is not.
///
/// Placeholders are therefore never people. `A` in one meeting has nothing to
/// do with `A` in another, and grouping them would manufacture a person out of
/// two strangers who happened to be listed second.
struct Person {
    /// As written on disk. `Me` for the user, whatever they are called on
    /// screen.
    let label: String
    /// Every recording they appear in, newest first.
    let recordings: [Recording]
    /// Seconds of transcript attributed to them, summed over all of them.
    let seconds: Double

    var isYou: Bool { label == SpeakerName.you }
    var display: String { SpeakerName.display(label) }
    var lastSeen: Date? { recordings.compactMap(\.date).max() }

    /// "7 recordings · 3h 12m", for a header that has to say how much is behind
    /// a name before anyone spends a click on it.
    var summary: String {
        // "no recordings yet" rather than "0 recordings": a contact somebody
        // created from an address is waiting to be heard, not empty.
        if recordings.isEmpty { return "no recordings yet" }
        let count = recordings.count == 1 ? "1 recording" : "\(recordings.count) recordings"
        let time = Recording.length(seconds)
        return time.isEmpty ? count : count + " · " + time
    }
}

/// Who is in the library, and renaming them everywhere at once.
///
/// No index and no cache, for the same reason there is no job table: the
/// transcripts are the truth, and anything derived from them that lives
/// somewhere else is something that can be wrong. Every call here re-reads
/// `turns.json`, which is what the sidebar's transcript search already does on
/// every keystroke. If a library ever grows big enough for that to hurt, the
/// fix is a cache keyed on the file's modification date, not a database.
enum People {

    // MARK: - Reading

    /// Talk time per speaker in one recording, longest first.
    ///
    /// Placeholders are included: they are really in this recording, and the
    /// chip that shows one is how it gets named. It is only *across* recordings
    /// that they mean nothing.
    static func speakers(in recording: Recording) -> [(label: String, seconds: Double)] {
        var seconds: [String: Double] = [:]
        var order: [String] = []
        for turn in recording.storedTurns {
            if seconds[turn.speaker] == nil { order.append(turn.speaker) }
            seconds[turn.speaker, default: 0] += max(0, turn.end - turn.start)
        }
        // First appearance breaks ties, so a meeting where two people said one
        // word each is listed in the order it happened rather than at random.
        return order.map { (label: $0, seconds: seconds[$0] ?? 0) }
            .sorted { $0.seconds > $1.seconds }
    }

    /// Everybody the library has a name for, most recordings first.
    static func all(in library: [Recording] = Recording.all()) -> [Person] {
        var recordings: [String: [Recording]] = [:]
        var seconds: [String: Double] = [:]
        for recording in library {
            for (label, spoken) in speakers(in: recording)
            where !VoiceBank.isPlaceholder(label) {
                recordings[label, default: []].append(recording)
                seconds[label, default: 0] += spoken
            }
        }
        return recordings.map {
            Person(label: $0.key, recordings: $0.value, seconds: seconds[$0.key] ?? 0)
        }
        .sorted {
            if $0.recordings.count != $1.recordings.count {
                return $0.recordings.count > $1.recordings.count
            }
            if $0.seconds != $1.seconds { return $0.seconds > $1.seconds }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Everybody, including the ones with nothing recorded yet.
    ///
    /// A contact created from a card, or filed against a calendar address that
    /// has not spoken in anything, is still a person: somebody typed an address
    /// and a note for them. Leaving them out of the one list of people would
    /// make the card that created them unreachable, which is how a store grows
    /// entries nobody can see.
    ///
    /// One rule, used by the roster and by `listen people`, so the window and
    /// the CLI cannot come to different answers about who exists.
    static func roster(in library: [Recording] = Recording.all()) -> [Person] {
        var everyone = all(in: library)
        let known = Set(everyone.map(\.label))
        for contact in ContactBook.load() where !known.contains(contact.name) {
            everyone.append(Person(label: contact.name, recordings: [], seconds: 0))
        }
        return everyone.sorted {
            if $0.isYou != $1.isYou { return $0.isYou }
            if $0.recordings.count != $1.recordings.count {
                return $0.recordings.count > $1.recordings.count
            }
            return $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending
        }
    }

    /// One person by their on-disk label, or nil if nobody is called that.
    static func find(_ label: String, in library: [Recording] = Recording.all()) -> Person? {
        let matching = library.filter { $0.speakers.contains(label) }
        guard !matching.isEmpty else { return nil }
        let total = matching.reduce(0.0) { sum, recording in
            sum + (speakers(in: recording).first { $0.label == label }?.seconds ?? 0)
        }
        return Person(label: label, recordings: matching, seconds: total)
    }

    /// The same lookup by what is on screen rather than what is on disk, so
    /// `listen people Emily` finds you when that is what you renamed `Me` to.
    static func findByDisplayName(_ name: String,
                                  in library: [Recording] = Recording.all()) -> Person? {
        if let exact = find(name, in: library) { return exact }
        if SpeakerName.display(SpeakerName.you).localizedCaseInsensitiveCompare(name)
            == .orderedSame {
            return find(SpeakerName.you, in: library)
        }
        guard let label = all(in: library).first(where: {
            $0.label.localizedCaseInsensitiveCompare(name) == .orderedSame
        })?.label else { return nil }
        return find(label, in: library)
    }

    // MARK: - Renaming everywhere

    /// Why a name cannot be used for everybody at once.
    enum RenameProblem: LocalizedError {
        case empty
        case looksLikePlaceholder(String)
        case isYou
        case recordingHasYou

        var errorDescription: String? {
            switch self {
            case .empty:
                return "A person needs a name."
            case .looksLikePlaceholder(let name):
                return "\"\(name)\" is how unnamed speakers are written, so a person "
                    + "called that would read as one nobody has labelled yet."
            case .isYou:
                return "\(SpeakerName.you) is the microphone track, which is you by "
                    + "construction rather than by name. To fold somebody into "
                    + "yourself in one recording, use Merge in that transcript."
            case .recordingHasYou:
                return "This recording already has a microphone track, which is you. "
                    + "Use Merge to fold this speaker into it."
            }
        }
    }

    /// Check a new name before anything is written.
    static func check(_ name: String) -> RenameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        // Renaming somebody to "A" would put the recording back into
        // needs-labelling and drop them out of the voice bank, which looks like
        // the rename having silently failed.
        if VoiceBank.isPlaceholder(trimmed) { return .looksLikePlaceholder(trimmed) }
        if trimmed == SpeakerName.you { return .isYou }
        return nil
    }

    /// The same question about one speaker in one recording, which is a
    /// different question.
    ///
    /// **`check` refuses `Me` and this must not**, and the reason is the whole
    /// of why there are two functions. There, the name is being applied to
    /// everybody called something across the library, and folding another
    /// person into yourself everywhere at once is not an edit anybody means.
    /// Here it is a label on one speaker in one transcript, and for two kinds of
    /// recording it is the **only** way to say "that speaker is me". A mix-only
    /// imported one, where the legacy recorder produced a single track so
    /// `Pipeline` labels nobody `Me` and there is no microphone side to Merge
    /// into. And a meeting recorded in a room, where the microphone held
    /// everybody and they all arrive as letters, including you. The advice
    /// `.isYou` gives points at a button that has nothing to offer.
    ///
    /// `listen label <id> A Me` has always allowed this. The window refused it,
    /// which is exactly the two-implementations-of-one-rule failure the CLI
    /// exists to catch, and it took a user picking a name the app itself had
    /// just suggested at 85% to find.
    static func checkSpeaker(_ name: String, in recording: Recording) -> RenameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if VoiceBank.isPlaceholder(trimmed) { return .looksLikePlaceholder(trimmed) }
        // You can only be one speaker in a recording. Where the microphone
        // track is already here, this is a merge, and the button that says so
        // is at the bottom of the same popover.
        if trimmed == SpeakerName.you, recording.speakers.contains(SpeakerName.you) {
            return .recordingHasYou
        }
        return nil
    }

    /// Recordings that already have somebody called `name`, where renaming
    /// `label` into it merges the two.
    ///
    /// Worth counting before the fact rather than after: nothing about the
    /// result would show that two people became one, and the transcript would
    /// simply look as though it had always been that way.
    static func collisions(renaming label: String, to name: String,
                           in library: [Recording] = Recording.all()) -> [Recording] {
        library.filter { $0.speakers.contains(label) && $0.speakers.contains(name) }
    }

    /// Rename one person in every recording they appear in.
    ///
    /// Each recording goes through `TranscriptEditor`, which is the same path
    /// the per-recording sheet and `listen label` take, so this cannot come
    /// apart from them: it moves the voiceprint with the name, rebuilds
    /// `turns.json`, and re-derives the recording's state. Anything that
    /// re-implemented one of those three here would be a fourth writer of the
    /// same files.
    ///
    /// Returns the ids it changed, so the caller can say how many rather than
    /// claiming success over a library it did not touch.
    @discardableResult
    static func rename(_ label: String, to name: String,
                       in library: [Recording] = Recording.all()) -> [String] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard check(trimmed) == nil, trimmed != label else { return [] }
        return relabel(label, to: trimmed, in: library)
    }

    /// Fold one person into another, everywhere they both appear.
    ///
    /// **The case this exists for is in every imported library.** The same
    /// human is `Me` on the recordings made here, because the microphone track
    /// is the user by construction, and a name on the ones that came from
    /// somewhere else, because a mixed recording has no microphone track to be
    /// the user of. Two rows in the roster, one person, and no amount of
    /// renaming fixes it: `rename` refuses `Me` as a target, and it is right to.
    ///
    /// Merging is the exception, and only in one direction. Somebody can be
    /// folded **into** you, because saying "that speaker was me" is a fact
    /// about a recording. You cannot be folded into somebody else, because
    /// `Me` is what the pipeline writes for the microphone track and the next
    /// recording would put it straight back.
    static func merge(_ label: String, into target: String,
                      in library: [Recording] = Recording.all()) -> [String] {
        let from = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return [] }
        guard from != SpeakerName.you else { return [] }
        guard !VoiceBank.isPlaceholder(to) else { return [] }
        return relabel(from, to: to, in: library)
    }

    /// Take somebody's name off every recording, leaving the speaker behind.
    ///
    /// **Not a delete.** Nothing is removed from any transcript: the turns, the
    /// audio and the voiceprint all stay, and the speaker goes back to being
    /// `Speaker A` in each recording, which is a speaker waiting to be named
    /// rather than one who never existed. That is what makes this the right
    /// answer to "this is the wrong person": naming them again is one click,
    /// and the voiceprint moves with the letter, so the bank can still suggest
    /// who they are.
    ///
    /// A free letter per recording, because placeholders are per recording.
    /// Reusing one already in the room would silently merge two speakers, which
    /// is the one thing this operation must not do.
    static func unname(_ label: String,
                       in library: [Recording] = Recording.all()) -> [String] {
        guard label != SpeakerName.you else { return [] }
        var changed: [String] = []
        for recording in library where recording.speakers.contains(label) {
            if TranscriptEditor.apply(.rename(label, to: freeLabel(in: recording)),
                                      to: recording) {
                changed.append(recording.id)
            }
        }
        // The card goes with the name. It was filed under a string nobody has
        // any more, and `set` drops an entry with neither an address nor a note.
        ContactBook.set(Contact(name: label, emails: [], notes: nil))
        return changed
    }

    /// Take one speaker's name off in **one** recording, leaving them in it.
    ///
    /// The undo for having named the wrong person, and it had no route at all
    /// until somebody went looking for one and pressed Discard instead. That is
    /// the difference this exists to make: the transcript is untouched, the
    /// speaker is still there as `Speaker A`, the voiceprint moves to the letter
    /// with them, and naming them again is one click. Discard deletes what they
    /// said and is not undoable from the window.
    ///
    /// Not `unname`, which does the same thing to every recording the name
    /// appears in and closes their contact card. Getting one meeting's
    /// attribution wrong says nothing about the others.
    @discardableResult
    static func unname(_ label: String, in recording: Recording) -> Bool {
        guard label != SpeakerName.you, !VoiceBank.isPlaceholder(label) else { return false }
        return TranscriptEditor.apply(.rename(label, to: freeLabel(in: recording)),
                                      to: recording)
    }

    /// A placeholder this recording is not already using.
    ///
    /// Reusing one that is in the room would silently merge two speakers, which
    /// is the one thing unnaming must not do.
    static func freeLabel(in recording: Recording) -> String {
        let taken = Set(recording.speakers)
        var index = 0
        while taken.contains(Merge.letter(index)) { index += 1 }
        return Merge.letter(index)
    }

    /// Rewrite one label as another across the library.
    ///
    /// Shared by rename and merge because they are the same operation with
    /// different permissions: renaming is merging into a name nobody has yet.
    /// `TranscriptEditor` rebuilds the turns, keeps the longer voiceprint when
    /// two land on one name, and re-derives each recording's state.
    private static func relabel(_ label: String, to name: String,
                                in library: [Recording]) -> [String] {
        var changed: [String] = []
        for recording in library where recording.speakers.contains(label) {
            if TranscriptEditor.apply(.rename(label, to: name), to: recording) {
                changed.append(recording.id)
            }
        }
        // Notes are joined rather than dropped: two people who turn out to be
        // one had two halves of the same story written about them.
        let mine = ContactBook.contact(label)?.note ?? ""
        let theirs = ContactBook.contact(name)?.note ?? ""
        let joined = [theirs, mine].filter { !$0.isEmpty }.joined(separator: "\n")
        // The email addresses move with the name, for the same reason the
        // voiceprint does. The contact book is keyed on this label, so leaving
        // it behind points every address at a name nobody has any more, and
        // nothing would say so: the suggestions would simply stop appearing,
        // which reads as the calendar having broken rather than as a stale key.
        ContactBook.rename(label, to: name)
        if !joined.isEmpty {
            let merged = ContactBook.contact(name)
            ContactBook.set(Contact(name: name, emails: merged?.emails ?? [],
                                    notes: joined))
        }
        return changed
    }
}
