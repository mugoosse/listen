import Foundation

/// The name the capturing device gave a recording before anything had listened
/// to it.
///
/// The phone writes `Memo, 26 August, 12:20` into `metadata.title` when nobody
/// types anything, which is most of them. Until `Metadata.TitleSource.device`
/// existed that string was indistinguishable from a title somebody chose:
/// `Recording.mayTitle` reads a title with no source as "a person named this"
/// and refuses every automatic writer against it, so naming the last speaker
/// on a phone memo rewrote the transcript and left the title alone, and the
/// calendar could never reach one either. Measured on the real library the day
/// this was written: six of the eight phone recordings were frozen that way.
///
/// The phone now stamps `title_source` at capture, which fixes every recording
/// made from that build onwards and none of the ones already on disk. This is
/// the other half: recognising the string the phone would have written, so a
/// memo made by an older build, or by a phone that has not been updated yet,
/// reaches the same place.
enum DeviceTitle {

    /// What the phone puts in front of the timestamp. Its own copy is
    /// `Recorder.defaultTitle` in the iOS app.
    private static let prefix = "Memo, "

    /// The date format the phone uses, which is the other half of that
    /// function and the reason this can be reconstructed at all.
    private static let dateFormat = "d MMMM, HH:mm"

    /// The strings the capturing device might have written for this recording,
    /// or empty for a recording no device names.
    ///
    /// **Derived from the id, never from `recorded_at`.** `Metadata.makeID`
    /// stamps `yyyy-MM-dd-HHmmss` in the *writing device's* local time, and so
    /// does the title, so the two are two renderings of one wall clock and
    /// comparing them needs no timezone at all. `recorded_at` is UTC, so
    /// matching against it means guessing where the phone was: measured over
    /// the eight phone recordings in the real library, the id-derived string
    /// matched all six defaults and neither of the two typed titles, while a
    /// `recorded_at` rendered in this Mac's own zone missed
    /// `2026-08-17-041112-0ADB`, recorded three hours away from here.
    ///
    /// More than one string because the phone formats month names in its own
    /// locale and nothing on disk records which that was. The current locale
    /// first, then `en_US_POSIX`, which covers a Mac and a phone set the same
    /// way and a phone left in English. A pairing neither covers is not
    /// recognised and the recording stays exactly as frozen as it is today,
    /// which is the failure this is allowed to have: it never invents a fact.
    static func candidates(for recording: Recording) -> [String] {
        // The one device that writes a default title. Not a guess from the
        // shape of the string: `source` is the evidence, the same rule
        // `AutoTitle` follows for `app_bundle_id`.
        guard recording.metadata.source == "iphone" else { return [] }
        guard let stamp = wallClock(recording.id) else { return [] }

        var seen: [String] = []
        for locale in [Locale.current, Locale(identifier: "en_US_POSIX")] {
            let f = DateFormatter()
            f.locale = locale
            // The same zone the id was parsed in, so this is a rearrangement of
            // the components rather than a conversion of an instant.
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = dateFormat
            let candidate = prefix + f.string(from: stamp)
            if !seen.contains(candidate) { seen.append(candidate) }
        }
        return seen
    }

    /// The title this recording falls back to when nothing better can name it.
    ///
    /// `Metadata.untitled` for everything the Mac recorded, which is what
    /// `AutoTitle` has always done, and the phone's own string for a memo,
    /// because throwing that away in favour of "New recording" would lose
    /// something the device already knew. It is the one computation
    /// `AutoTitle.outcome` and `AutoTitle.refresh` share, for the reason
    /// `Outcome` exists at all: the preview and the apply cannot be allowed to
    /// work it out separately.
    ///
    /// Three answers, in the order they are asked:
    ///
    /// 1. **Already the placeholder**, so it stays there. `Untitled` is a
    ///    decision too, and a phone recording somebody cleared by hand must not
    ///    grow its memo title back on the next speaker edit.
    /// 2. **Already wearing one of the device's strings**, so that exact one is
    ///    the floor. Not `candidates.first`, or a Mac and a phone set to
    ///    different languages would rewrite each other's month names for ever.
    /// 3. Otherwise the device's string if it writes one, and the placeholder
    ///    if it does not.
    static func floor(for recording: Recording) -> String {
        if recording.isUntitled { return Metadata.untitled }
        let options = candidates(for: recording)
        if options.contains(recording.metadata.title) { return recording.metadata.title }
        return options.first ?? Metadata.untitled
    }

    /// The one to write when this has to produce a title rather than recognise
    /// one, which is `AutoTitle`'s unname path.
    ///
    /// The current locale, because nothing records the phone's and a placeholder
    /// in the reader's own language is the better of the two guesses. If it
    /// picks the wrong one the string still reads as a memo and `candidates`
    /// still recognises it, so the mistake costs a month name and nothing else.
    static func standIn(for recording: Recording) -> String? {
        candidates(for: recording).first
    }

    /// Whether this recording is still carrying the name its device gave it.
    ///
    /// `title_source` has to be absent: a recording that has been through here
    /// already says so, and one the calendar or a person has named is not this
    /// code's to reclassify.
    static func isDefault(_ recording: Recording) -> Bool {
        guard recording.metadata.title_source == nil else { return false }
        return candidates(for: recording).contains(recording.metadata.title)
    }

    /// Say on disk what the title already is, so the automatic titlers may
    /// write over it.
    ///
    /// It renames nothing. `AutoTitle` is driven by speaker edits, so a
    /// recording stamped here keeps the memo string until its speakers are
    /// named or `listen title backfill --apply` runs, and one with nobody to
    /// name it after keeps it for good.
    ///
    /// Returns the updated recording, or nil when there was nothing to do.
    @discardableResult
    static func adopt(_ recording: Recording) -> Recording? {
        guard isDefault(recording) else { return nil }
        var current = recording
        current.metadata.title_source = Metadata.TitleSource.device.rawValue
        try? current.save()
        return current
    }

    /// The wall clock in a recording id, as components in UTC.
    ///
    /// `Metadata.makeID` is `yyyy-MM-dd-HHmmss` plus a dash and four hex
    /// characters, and the legacy Python ids are the same shape, so the first
    /// seventeen characters are the timestamp on every recording in the
    /// library. Anything else answers nil rather than a date it made up.
    private static func wallClock(_ id: String) -> Date? {
        guard id.count >= 17 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.date(from: String(id.prefix(17)))
    }
}
