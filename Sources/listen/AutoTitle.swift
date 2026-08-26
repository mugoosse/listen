import Foundation

/// Naming a recording after the people in it.
///
/// The weakest of the automatic titlers and the only one that costs nothing: no
/// model, no network, no permission, and an answer the moment the last speaker
/// gets a name. It exists because the calendar can only name a meeting somebody
/// scheduled, and most calls are not. Measured on the real library the day this
/// was written: 4 recordings sat at "Untitled", and `listen calendar match` put
/// the nearest event to two of them 51 and 32 minutes away, which is to say
/// there was never anything for the calendar to find.
///
/// One function does the writing, for the reason `MeetingCalendar.attach` gives:
/// the automatic path, a backfill and anything added later have to write the
/// same fields in the same order, and there is no test target to catch the day
/// two implementations stop agreeing.
enum AutoTitle {

    /// What this recording's speakers would do to its title, and why not when
    /// they would do nothing.
    ///
    /// One type, because `refresh` and `listen title backfill` have to agree
    /// and the calendar's backfill already proved they will not if each works
    /// it out for itself: its preview asked `isUntitled` while `attach` asked
    /// `mayTitle`, so it printed "keeps its name" for a recording and renamed
    /// it on the next line. The reasons are cases here rather than sentences in
    /// the CLI so that the only thing the printer decides is wording.
    enum Outcome: Equatable {
        /// The title would be written.
        case name(String)
        /// A derived title whose speakers have gone, so the title underneath
        /// comes back: `DeviceTitle.floor`, which is the phone's own string
        /// for a memo and the placeholder for everything else.
        case unname
        /// It already says what the speakers say.
        case nothingToDo
        /// It has a title and no record of where the title came from, so it is
        /// not this code's to change.
        ///
        /// **Not "typed by a person", although that is the common case.** A
        /// title with no source is also every one written before `title_source`
        /// existed: the legacy Python imports, the calendar names from before
        /// the field, and the iPhone's `Memo, 8 August, 12:08`. Nothing can tell
        /// those from a typed title, deliberately, for the reason
        /// `.agents/notes/calendar.md` gives about the same fourteen imports.
        /// So the case says what is known and no printer may say more.
        case notOurs
        /// Named by something this does not outrank, which today is the
        /// calendar.
        case outranked(Metadata.TitleSource)
        /// Speakers are still letters. The count is how many.
        case waitingOnSpeakers(Int)
        /// Nobody to name it after: no speech, or nobody but you.
        case nobodyToNameItAfter
    }

    /// What `refresh` would do, without doing it.
    static func outcome(for recording: Recording) -> Outcome {
        guard recording.mayTitle(from: .people) else {
            guard let source = recording.metadata.titleSourceValue else { return .notOurs }
            return .outranked(source)
        }

        let speakers = recording.speakers
        let letters = speakers.filter(VoiceBank.isPlaceholder).count
        if let derived = fromPeople(recording) {
            return derived == recording.metadata.title ? .nothingToDo : .name(derived)
        }
        // Nothing here can name it, so the question is whether it is still
        // wearing a title this code wrote. `DeviceTitle.floor` is what it falls
        // back to, and for everything the Mac recorded that is
        // `Metadata.untitled`, which is the comparison this line has always
        // made.
        if recording.metadata.title != DeviceTitle.floor(for: recording) { return .unname }
        if letters > 0 { return .waitingOnSpeakers(letters) }
        return .nobodyToNameItAfter
    }

    /// Re-derive the title from the speakers, if this recording's is ours to
    /// write.
    ///
    /// Called from `TranscriptEditor.change`, which is every rename, merge and
    /// discard in the app, the CLI and the voice bank alike. That is the whole
    /// answer to "what if the speaker is only labelled later": the title is a
    /// view over the speaker list rather than a decision taken once, so it
    /// follows the list until somebody types over it and freezes it.
    ///
    /// Returns the updated recording, or nil when nothing changed.
    @discardableResult
    static func refresh(_ recording: Recording) -> Recording? {
        // Re-read, the same rule `Recording.markTranscribed` follows. The
        // caller has just rewritten `transcript.json` and `turns.json`, and on
        // the `autoAssign` path it is partway through a loop that rewrites them
        // again; the copy in hand is a moment old. `load` rather than `find`
        // because `find` lists the whole library and this runs once per speaker.
        guard var current = Recording.load(recording.folder) else { return nil }

        let title: String
        let source: Metadata.TitleSource?
        switch outcome(for: current) {
        case .name(let derived):
            title = derived
            source = .people
        case .unname:
            // Going back rather than keeping the last good name is the point: a
            // title naming somebody the transcript no longer contains is the app
            // asserting something false about its own files, and this is the
            // same re-derivation rule `room_auto` states.
            //
            // Back to the floor rather than always to the placeholder, so a
            // phone memo lands on the phone's own string and a recording that
            // loses its last named speaker to a discard is exactly as titleable
            // as it was before anybody was named. Nil for the placeholder, for
            // the same reason: `mayTitle` lets anything name an untitled
            // recording, and `device` ranks below every writer.
            title = DeviceTitle.floor(for: current)
            source = title == Metadata.untitled ? nil : .device
        default:
            return nil
        }

        current.metadata.title = title
        current.metadata.title_source = source?.rawValue
        try? current.save()
        return current
    }

    /// The title this recording's speakers give it, or nil for one they cannot.
    ///
    /// Two rules, and both were measured over the 47 transcribed recordings in
    /// the real library rather than chosen.
    ///
    /// **Every speaker has to have a name.** The alternative considered was a
    /// cap on how many speakers a recording may have, which sounds equivalent
    /// and is not: "at least one name, at most three speakers" titled 28
    /// recordings and this rule titles 26, and the two in the difference are
    /// Hermes workshops 2 and 3, each of which would have been called "Call
    /// with Nick" while a second person was still an unnamed letter. All five
    /// recordings in the library with a letter left in them are workshops. So
    /// the cap does not buy coverage, it buys exactly the wrong titles, and
    /// waiting costs nothing because labelling the last speaker is itself the
    /// event that runs this.
    ///
    /// **`Me` never appears.** The user is in every recording they made and a
    /// title saying so distinguishes none of them.
    static func fromPeople(_ recording: Recording) -> String? {
        let speakers = recording.speakers
        guard !speakers.isEmpty else { return nil }
        guard !speakers.contains(where: VoiceBank.isPlaceholder) else { return nil }

        let people = speakers.filter { $0 != Pipeline.userLabel }
        guard !people.isEmpty else { return nil }

        // "Call with" claims something the metadata knows: `app_bundle_id` is
        // set only when an app was on a call when capture began or while it
        // ran. Without one this is a microphone in a room, which is a
        // conversation and not a call.
        //
        // Not the app's *name*, which stays in the subtitle where `DetailView`
        // argues it belongs. Both wordings already appear in titles typed by
        // hand in this library ("Call with Nadia", "Conversation with Andrew"),
        // so neither is a phrase the app invented for itself.
        let opening = recording.appBundleID == nil ? "Conversation with" : "Call with"
        return opening + " " + list(people)
    }

    /// Names as a sentence: "A", "A and B", "A, B and C", "A, B and 2 others".
    ///
    /// Three names is where the list stops, because a fourth is longer than the
    /// sidebar row that has to hold it. Nothing in the library reaches it: the
    /// measured
    /// spread of non-`Me` speakers is 24 recordings with one, 4 with two, and
    /// one each with three, four and five, and the last three are workshops
    /// with letters still in them, which `fromPeople` refuses before this runs.
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 1:  return names[0]
        case 2:  return names[0] + " and " + names[1]
        case 3:  return names[0] + ", " + names[1] + " and " + names[2]
        default:
            let rest = names.count - 2
            return names[0] + ", " + names[1]
                + " and \(rest) other" + (rest == 1 ? "" : "s")
        }
    }
}
