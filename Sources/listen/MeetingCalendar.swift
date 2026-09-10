import EventKit
import Foundation
import ListenKit

/// Matching a recording to a meeting, and writing what it finds beside the
/// audio.
///
/// **Reading the calendar is `ListenKit.MeetingCalendar`'s**, because the phone
/// does that too now and a rule with a measurement behind it is written once.
/// What is here is everything about a *recording*, which is the half the phone
/// has no use for: the ten minute window, the second rule for a meeting that
/// began while capture was running, and the guarded write of a title and a
/// guest list into `metadata.json`.
///
/// Read-only towards the calendar, always, on both sides of that split.
/// Nothing anywhere creates, edits or deletes an event.
extension MeetingCalendar {

    // MARK: - Matching a recording to a meeting

    /// How far a meeting's start may sit from a recording's and still be the
    /// same meeting.
    ///
    /// Measured over the 47 recordings in the real library, anchoring on start
    /// time. `matched` counts recordings with at least one candidate;
    /// `named` counts the seven that somebody had bothered to title by hand,
    /// which is the closest thing to ground truth available:
    ///
    ///     +/- 5m    matched  9/47   named 3/7   ambiguous 1
    ///     +/- 10m   matched 14/47   named 6/7   ambiguous 2
    ///     +/- 15m   matched 14/47   named 6/7   ambiguous 2
    ///     +/- 20m   matched 14/47   named 6/7   ambiguous 2
    ///     +/- 30m   matched 16/47   named 6/7   ambiguous 4
    ///
    /// Ten minutes is the knee. Ten, fifteen and twenty are identical, so the
    /// widest of them buys nothing; thirty buys two extra matches and **both
    /// are wrong** (a WhatsApp call matched a solo calendar block 26 minutes
    /// away, titled "Review the Q3 launch Reel"). Since the title is
    /// applied without asking, a wrong match is the expensive direction.
    static let window: TimeInterval = 10 * 60

    /// A meeting that began while the recording was already running.
    ///
    /// The second rule, and deliberately **asymmetric**. "The recording
    /// overlaps the event" would also cover a recording that started in the
    /// middle of somebody's hour-long focus block, which is exactly the wrong
    /// match the thirty minute row above bought: a WhatsApp call landing inside
    /// a solo block called "Review the Q3 launch Reel". This rule says
    /// something much narrower and much stronger, that capture was already
    /// running at the minute the invitation said the meeting would begin.
    ///
    /// It exists because of a real recording: a Google Meet link opened 26
    /// minutes early, capture started by detection at 17:19, and the meeting
    /// beginning at 17:45 while it ran. Every offset in the measured table was
    /// between -9 and +0 minutes, so joining early was simply not in the
    /// sample; it is not rare, it is what a link in an invitation invites.
    ///
    /// Somebody else has to be on the invitation. This rule reaches as far as
    /// the recording is long, which on an 80 minute meeting is far past the
    /// thirty minutes already measured as too wide, so it asks for a second
    /// piece of evidence that this is a meeting with people in it rather than a
    /// block somebody put in their own calendar. That is the same standard
    /// `people` is held to everywhere else here.
    ///
    /// Measured over the 42 recordings now in the library: with and without
    /// this check the rule finds the same one match, so today it costs nothing.
    /// It stays because the wrong match the thirty minute row bought was
    /// exactly a solo block, and a rule that reaches further should not be
    /// looser as well.
    private static func beganDuring(_ event: CalendarEvent,
                                    _ start: Date, _ end: Date) -> Bool {
        guard event.start >= start, event.start <= end else { return false }
        return event.people.contains { !$0.is_me }
    }

    /// Every meeting that could be the one this recording is of.
    ///
    /// Two rules: a meeting that **started when the recording did**, within
    /// `window` either way, and a meeting that **started while it ran**.
    ///
    /// Anchored on starts, never on overlap. A recording that merely overlaps
    /// an event is not evidence of anything on a Mac that is on all day.
    ///
    /// The second rule can only ever *add* a match, never change one. Anything
    /// it finds is by definition more than `window` from the recording's start,
    /// so it sorts behind everything the first rule found and the winner of a
    /// non-empty first rule is untouched. The fourteen matches in the table
    /// above are therefore still those fourteen.
    ///
    /// `duration` is zero for a recording that is still running, which switches
    /// the second rule off: capture has no span yet. That is why `Capture` asks
    /// again when it stops.
    static func candidates(for start: Date, lasting duration: TimeInterval = 0) -> [CalendarEvent] {
        let end = start.addingTimeInterval(max(0, duration))
        return events(from: start.addingTimeInterval(-window),
                      to: max(end, start.addingTimeInterval(window)))
            .filter(\.couldBeAMeeting)
            .filter { abs($0.start.timeIntervalSince(start)) <= window
                      || beganDuring($0, start, end) }
            .sorted {
                // Nearest start wins. Attendees only break a tie: the table
                // above was measured with nearest-start alone, and preferring
                // the invite with more people in it would be an unmeasured
                // change to a rule that produced fourteen plausible matches.
                let a = abs($0.start.timeIntervalSince(start))
                let b = abs($1.start.timeIntervalSince(start))
                if a != b { return a < b }
                return $0.people.count > $1.people.count
            }
    }

    static func match(for start: Date, lasting duration: TimeInterval = 0) -> CalendarEvent? {
        candidates(for: start, lasting: duration).first
    }

    /// The same, for a recording. Nil when it has no usable start time.
    ///
    /// The duration is the one on disk, which is zero while capture is running
    /// and the real length afterwards.
    static func match(for recording: Recording) -> CalendarEvent? {
        guard let date = recording.date else { return nil }
        return match(for: date, lasting: recording.metadata.duration)
    }

    // MARK: - Attaching a meeting to a recording

    /// A calendar title long enough to be a problem as a filename.
    ///
    /// Titles come from other people's calendars and Listen applies them
    /// without asking, so unlike a title somebody typed this one is not
    /// self-inflicted. The longest seen in the real library is 68 characters.
    private static let maxTitle = 120

    /// Record which meeting a recording is of, and name it if nobody has.
    ///
    /// One function, so the automatic path and `listen calendar backfill` write
    /// exactly the same fields in exactly the same order. Returns the updated
    /// recording, or nil when nothing changed.
    ///
    /// The attendees are stored **whether or not the title is applied**. A
    /// recording somebody named by hand still has a guest list worth keeping,
    /// and the speaker sheet is the thing that spends it.
    ///
    /// `refresh` re-reads a recording that is already attached. Only
    /// `listen calendar backfill --refresh` passes it, because the automatic
    /// path must not: a guest list that has already been picked from is a
    /// decision, and quietly replacing it with whatever the invitation says
    /// today would undo one. It exists for the case where this file learns to
    /// read the same event better, which has happened once already.
    @discardableResult
    static func attach(to recording: Recording, refresh: Bool = false) -> Recording? {
        guard isAuthorized else { return nil }
        // Attached once. A second pass must not overwrite a guest list that a
        // rename or a merge has already been reasoned about.
        guard refresh || recording.metadata.calendar_event_id == nil else { return nil }
        guard let event = match(for: recording) else { return nil }

        var updated = recording
        updated.metadata.calendar_event_id = event.id
        updated.metadata.calendar_people = event.people
        // Never over a name somebody typed. `mayTitle` is the whole guard, and
        // it used to be `isUntitled` on its own: still the placeholder, or a
        // title this app derived from something the calendar outranks. The
        // invitation is the strongest evidence there is, so a backfill that
        // finds one later correctly replaces a title `AutoTitle` built out of
        // the guest list, and still refuses the fourteen imported names, which
        // have no source at all.
        if updated.mayTitle(from: .calendar) {
            updated.metadata.title = title(from: event)
            updated.metadata.title_source = Metadata.TitleSource.calendar.rawValue
        }
        try? updated.save()
        // Anything asked ahead of this meeting belongs to it now. This is the
        // only moment a folder and an invitation are known to be the same
        // meeting, and it is what makes preparing worth doing: the conversation
        // is on the meeting's page afterwards rather than somewhere in History.
        let adopted = Chat.adopt(eventID: event.id, into: recording.id)
        trace("calendar: \(recording.id) is \"\(event.title)\" (\(event.summary))"
              + (adopted > 0 ? ", adopting \(adopted) conversation(s)" : ""))
        return updated
    }

    /// The automatic path, which the setting governs. `attach` itself does not
    /// consult it, so `listen calendar backfill` still works for somebody who
    /// turned the automatic naming off and wants to do one by hand.
    @discardableResult
    static func attachIfEnabled(to recording: Recording) -> Recording? {
        guard Settings.nameFromCalendar else { return nil }
        return attach(to: recording)
    }

    static func title(from event: CalendarEvent) -> String {
        guard event.title.count > maxTitle else { return event.title }
        return String(event.title.prefix(maxTitle))
            .trimmingCharacters(in: .whitespaces) + "…"
    }
}
