import AppKit

/// Audible feedback for dictation, using system sounds rather than bundled
/// audio files.
///
/// Push-to-talk is used while looking at something else, so sound is often the
/// only feedback that arrives. System sounds are used deliberately: they already
/// match the user's volume and alert settings, they are familiar, and shipping
/// custom audio would mean choosing something that eventually grates on someone
/// who hears it forty times a day.
///
/// Dictation only. Recording a meeting is not a thing you do while looking
/// elsewhere, the panel is already on screen for it, and a chime at the top of
/// every call would be played to the room.
enum Cue {
    /// Shown in the Settings pickers. Read from disk rather than hardcoded, so
    /// a macOS release that adds or removes one does not leave a picker
    /// offering something that will not play.
    static var available: [String] {
        let dir = "/System/Library/Sounds"
        return (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".aiff") }
            .map { String($0.dropLast(5)) }
            .sorted() ?? []
    }

    /// Chosen because it is short and unobtrusive: this one fires every time you
    /// begin speaking, so anything with character becomes irritating fast.
    static let defaultStart = "Tink"

    /// Blow rather than Glass: this one lands while you are reading back what
    /// you said, and Glass is close enough to the system alert sound to read as
    /// something going wrong.
    static let defaultDone = "Blow"

    /// Sentinel for "no sound for this event", kept separate from the master
    /// toggle so one cue can be silenced without losing the others.
    static let none = "None"

    /// The microphone is live. Fired from the first audio buffer, never from the
    /// keypress, so it cannot lie about whether recording began.
    static func start() { play(Settings.dictationStartSound) }

    /// A transcript reached the clipboard.
    static func done() { play(Settings.dictationDoneSound) }

    /// The dictation was abandoned deliberately. Distinct from `done`, or
    /// cancelling sounds like success.
    static func cancel() { play("Bottle") }

    /// Nothing was heard, or transcription failed.
    static func failed() { play("Basso") }

    /// Ignores the master toggle, for previewing a choice in Settings: you are
    /// asking to hear it, so hearing nothing would be a broken control.
    static func preview(_ name: String) {
        guard name != none else { return }
        NSSound(named: name)?.play()
    }

    private static func play(_ name: String) {
        guard Settings.dictationSounds, name != none else { return }
        NSSound(named: name)?.play()
    }
}

extension Settings {
    private static let dictationSoundsKey = "dictationSounds"
    private static let dictationStartSoundKey = "dictationStartSound"
    private static let dictationDoneSoundKey = "dictationDoneSound"

    /// Audible cues on start and finish. On by default: the whole point of a
    /// push-to-talk shortcut is that you are looking at something else, and a
    /// sound is the only feedback that needs no glance.
    static var dictationSounds: Bool {
        get { defaults.object(forKey: dictationSoundsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: dictationSoundsKey) }
    }

    /// Which system sound each cue uses. Taste in notification sounds is
    /// personal and these fire dozens of times a day, so they are a setting
    /// rather than a decision made on the user's behalf.
    static var dictationStartSound: String {
        get { defaults.string(forKey: dictationStartSoundKey) ?? Cue.defaultStart }
        set { defaults.set(newValue, forKey: dictationStartSoundKey) }
    }

    static var dictationDoneSound: String {
        get { defaults.string(forKey: dictationDoneSoundKey) ?? Cue.defaultDone }
        set { defaults.set(newValue, forKey: dictationDoneSoundKey) }
    }
}
