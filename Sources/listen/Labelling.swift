import Foundation

/// Speakers nobody has named yet: the one to-do list this app has.
///
/// **`metadata.state` cannot answer this, and neither can `effectiveState`.**
/// Measured over the 31 transcribed recordings in the development library: 14
/// carry `needs_labelling` but only 10 of those actually hold an unnamed voice,
/// and 3 carry `pending` while holding one. The field only becomes `done` when
/// `TranscriptEditor.apply` runs (see the end of `apply`), and the imported half
/// of that library was labelled by a Python pipeline that never called it, so a
/// recording where every speaker has a real name goes on claiming to be waiting
/// for somebody. `effectiveState` is derived from the same field and inherits
/// both errors, reporting 17 where the truth is 13.
///
/// So the question is put to the transcript, which is the only thing that knows:
/// a speaker is waiting exactly when its label is one `Merge.letter` invented.
///
/// This is deliberately **not** a status word on a row. There used to be one,
/// with a filter tab beside it, and the reason both went is recorded in
/// `Recording.stateText`: an unnamed speaker reads as "Speaker A" in the
/// transcript, which is legible on its own, so the list was telling people to go
/// and fix something that did not look broken. What was missing was never a
/// badge, it was a way to ask where the work is. Hence a lens, set from one row
/// that appears only while there is something in it.
enum Labelling {
    /// The unnamed speakers in one recording, in the order they first speak.
    ///
    /// **Cached against `turns.json`'s modification date.** The sidebar asks
    /// this of every recording on every reload, and a reload is every keystroke
    /// in the search field, so the uncached form is a full JSON decode of every
    /// transcript in the library per character typed. Keyed on the date rather
    /// than held for the life of the process, because naming somebody rewrites
    /// that file: a cache that never expired would be a to-do list that does not
    /// go down as the work is done, which is worse than no list at all.
    static func unnamed(in recording: Recording) -> [String] {
        let stamp = (try? FileManager.default
            .attributesOfItem(atPath: recording.turnsURL.path))
            .flatMap { $0[.modificationDate] as? Date }

        // Behind a lock, which is the rule `MeetingCalendar` already sets and
        // for the same reason: the sidebar asks this on the main thread and the
        // MCP server asks it through `RecordingFilter` on another, and a torn
        // dictionary read leaves nothing behind to debug from.
        lock.lock()
        let hit = cache[recording.id]
        lock.unlock()
        if let hit, hit.stamp == stamp { return hit.unnamed }

        let unnamed = recording.speakers.filter(VoiceBank.isPlaceholder)
        lock.lock()
        cache[recording.id] = (stamp, unnamed)
        lock.unlock()
        return unnamed
    }

    /// Is anybody in this recording still waiting for a name?
    static func waits(_ recording: Recording) -> Bool {
        !unnamed(in: recording).isEmpty
    }

    /// Every recording with somebody in it nobody has named, newest first,
    /// which is the order `Recording.all()` already gives.
    static func waiting(in library: [Recording] = Recording.all()) -> [Recording] {
        library.filter(waits)
    }

    /// A recording with no transcript has nothing waiting in it, so it never
    /// counts: it is queued or it failed, and both of those the sidebar already
    /// says out loud. Its `turns.json` is missing, `speakers` is empty, and the
    /// entry is cached against a nil stamp that stops matching the moment the
    /// file arrives.
    private static var cache: [String: (stamp: Date?, unnamed: [String])] = [:]
    private static let lock = NSLock()
}
