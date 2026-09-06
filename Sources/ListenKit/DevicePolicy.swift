import Foundation

/// Which files a device keeps a copy of.
///
/// This used to be one constant, `syncedSidecars`, which could only answer the
/// question for a phone talking to a Mac. It is a type now because the answer
/// differs per device and the difference is about to become structural: a
/// second Mac needs `embeddings.json` and the phone must never receive it, and
/// under CloudKit that distinction is which zone a device subscribes to.
///
/// **`metadata.json` is in every set, and it was in none of them.** The phone
/// used to rebuild it from a handful of manifest fields, which silently dropped
/// `tags`, `calendar_event_id`, `calendar_people` and `app_name` on every
/// single pull. It is transferred as bytes now, and the rule that goes with
/// that is worth stating plainly because everything downstream depends on it:
///
/// > Only the device that authored a recording serialises its `metadata.json`.
/// > Every other device writes the bytes it was given, verbatim, and parses
/// > them leniently and read-only.
///
/// A device that re-encodes a document it did not author drops every field its
/// own struct has never heard of, and the phone's struct deliberately models
/// fewer fields than the Mac's. `Recording.patch` exists so that an edit made
/// on a device that is not the author does not have to break the rule.
public struct DevicePolicy: Sendable, Equatable {
    /// The small app icon a Mac exports for rows on devices that cannot inspect
    /// the Mac's installed applications.
    public static let sourceIcon = "source-icon.png"

    /// Per-recording files this device holds, digest-tracked, `metadata.json`
    /// first because everything else is written before it.
    public let sidecars: [String]

    /// Whether this device also keeps the pre-edit copy of a transcript.
    ///
    /// **A file named after the recording, so it cannot be a constant.**
    /// `<id>.raw.json.bak` is written once, the first time somebody corrects a
    /// sentence, and it holds what the machine said before they did.
    ///
    /// It matters because its *presence* is how `hasHumanEdits` knows a
    /// transcript has been corrected, and that is what makes transcribing
    /// again ask before it throws the corrections away. A device that has the
    /// corrected transcript and not this file answers "no human edits here"
    /// and destroys somebody's work without the warning that exists to stop
    /// exactly that. A guard that only fires on the machine where the editing
    /// happened is not a guard.
    public let keepsRawBackup: Bool

    /// The pre-edit backup for one recording, which is named after it.
    public static func rawBackup(for id: String) -> String { "\(id).raw.json.bak" }

    /// Library-level files, one copy for the whole library rather than one per
    /// recording.
    public let blobs: [String]

    public init(sidecars: [String], blobs: [String], keepsRawBackup: Bool = true,
                ownsVoiceprints: Bool = false) {
        self.sidecars = sidecars; self.blobs = blobs
        self.keepsRawBackup = keepsRawBackup
        self.ownsVoiceprints = ownsVoiceprints
    }

    /// Every per-recording file this device keeps for one id, backup included.
    public func files(for id: String) -> [String] {
        keepsRawBackup ? librarySidecars + [DevicePolicy.rawBackup(for: id)] : librarySidecars
    }

    /// Whether this device stores a given per-recording file.
    public func wants(_ file: String) -> Bool { sidecars.contains(file) }

    /// Voiceprint material, which lives in its own zone rather than beside the
    /// transcript.
    ///
    /// **The zone is the mechanism, not the policy.** A device subscribes per
    /// zone, so a file placed in the library zone is delivered to every device
    /// that syncs the library, whether or not that device then writes it to
    /// disk. Keeping these out of the library record is what makes *Recognise
    /// voices on this iPhone* a real switch: off, the phone does not subscribe
    /// and never receives one, rather than receiving one and declining to save
    /// it. Only the first is worth claiming.
    public static let voiceprintFiles = ["embeddings.json"]

    /// The per-recording files that belong in the library zone: everything
    /// this device keeps, minus anything with a zone of its own.
    public var librarySidecars: [String] {
        sidecars.filter { !DevicePolicy.voiceprintFiles.contains($0) }
    }

    /// Whether this device keeps voiceprints at all, which decides whether it
    /// subscribes to that zone and takes what is in it.
    public var keepsVoiceprints: Bool {
        sidecars.contains(where: DevicePolicy.voiceprintFiles.contains)
    }

    /// Whether a voiceprint this device made is the last word on a recording.
    ///
    /// **Not whether it may publish one. Every device holding a bank publishes
    /// one.** This is the tie-break for the case where two devices have a
    /// voiceprint of the same audio, which is not hypothetical and is in fact
    /// the ordinary case: a phone diarizes what it records in the minute after
    /// it stops, and then a Mac claims that same audio and diarizes it again
    /// with the full pipeline.
    ///
    /// The two passes are not equal. The phone hears one far-field microphone
    /// carrying everybody. The Mac has the separated tracks, a clusterer told
    /// how many voices to expect on the microphone track, and the mains power
    /// to take its time. So the Mac's print supersedes, and this flag is how a
    /// device knows whether it is the one that gets superseded.
    ///
    /// What it does **not** mean is that the phone's print is thrown away. It
    /// travels the moment it is made, which is what makes a phone recording's
    /// voices available to a second Mac before the first Mac has even woken up,
    /// and it stands down only once a real transcript for that recording exists
    /// (`CloudSyncCore.speaksFor`). Before that it is not the worse of two
    /// prints; it is the only one there is.
    public let ownsVoiceprints: Bool

    /// The sidecars in the order they are written on arrival: `metadata.json`
    /// last, always. `Recording.load` returns nil without it and `Library.all`
    /// is a compactMap over `load`, so a folder mid-transfer is invisible
    /// rather than half-built. See `RecordingWriter`.
    public var writeOrder: [String] {
        sidecars.filter { $0 != "metadata.json" } + sidecars.filter { $0 == "metadata.json" }
    }

    /// Everything a Mac keeps.
    ///
    /// `embeddings.json` is here and deliberately not in `phone`. A second Mac
    /// genuinely needs it, because `VoiceBank` has no database and the set of
    /// those files **is** the voice bank, so a Mac without them cannot
    /// recognise a voice it has already been taught.
    public static let mac = DevicePolicy(
        sidecars: ["metadata.json", "transcript.json", "turns.json",
                   "waveform.json", DevicePolicy.sourceIcon, "embeddings.json"],
        blobs: ["contacts.json", "dictionary.json"],
        ownsVoiceprints: true)

    /// Everything a phone keeps.
    ///
    /// `SYNC.md` measured the whole set at 6.5 MB for 41 recordings, so the
    /// phone takes all of it and searches locally.
    ///
    /// **`embeddings.json` is here now, and it was deliberately absent for two
    /// years.** The line that kept it out said the phone had nothing that reads
    /// a voiceprint, and predicted, correctly, that the day the phone diarized
    /// for itself the argument would reverse. Then the phone did diarize and
    /// the argument did not reverse, because the two halves came apart:
    /// `listen-ios`'s `LocalDiarize` split a room into A, B and C and stopped,
    /// which needs no bank from anywhere.
    ///
    /// What changed is not the mechanism but what the split is *for*. A, B and
    /// C is a shape, not a meeting. Somebody looking at their phone twenty
    /// seconds after a conversation ends wants to see who was in it, and the
    /// answer already exists: it is sitting in the Macs' banks, sealed, in a
    /// zone this phone was declining to subscribe to. Withholding it bought a
    /// property nobody had asked for at the cost of the feature the separation
    /// was done for.
    ///
    /// **Three things make it a smaller change than it sounds.**
    ///
    /// 1. **It is not the largest sidecar and never was.** Measured on this
    ///    library on 6 September 2026: 74 banks, 920 KB in total, about 12 KB
    ///    each, against 2.4 MB of `turns.json` and 1.2 MB of `waveform.json`
    ///    that the phone has always taken. A 256-float vector per speaker is
    ///    cheaper than the waveform drawn behind the play head.
    /// 2. **It travels the way everything else does.** Sealed with the same
    ///    key, through the same container, to a device already holding every
    ///    transcript in the library. A transcript says what was said in a
    ///    therapy session; a voiceprint says which cluster it was. The
    ///    biometric material is the more sensitive of the two in kind, and it
    ///    is not the more sensitive of the two in content, and the phone was
    ///    already trusted with the content.
    /// 3. **It travels both ways, and the Mac still has the last word.**
    ///    `ownsVoiceprints` is false here, which is a precedence rule rather
    ///    than a ban: what the phone hears goes up at once and reaches the
    ///    Macs, and stands down for a given recording only when a real
    ///    transcript for it exists, because at that point a Mac has diarized
    ///    the same audio with separated tracks. Every name the phone applies is
    ///    marked `auto`, so nothing it guessed is ever the evidence for the
    ///    next guess, on any device.
    ///
    /// **It is a person's decision, not a policy constant.** The switch is
    /// *Recognise voices on this iPhone* in Settings, default on where the
    /// phone diarizes at all; turning it off drops every bank on the phone and
    /// stops the subscription. See `AppModel.recogniseVoices`.
    ///
    /// The retired LAN transport never moved `blobs`. CloudKit does, through
    /// the same policy that carries recording sidecars.
    ///
    /// `dictionary.json` rewrites transcripts, so two devices with different
    /// dictionaries produce differently corrected transcripts of the same
    /// audio, which is why it is here: once the phone transcribes for itself
    /// that stops being a two-Mac problem and becomes the difference between
    /// the phone's pass and the Mac's looking like a quality gap when it is a
    /// vocabulary one.
    public static let phone = DevicePolicy(
        sidecars: ["metadata.json", "transcript.json", "turns.json", "waveform.json",
                   DevicePolicy.sourceIcon, "embeddings.json"],
        blobs: ["contacts.json", "dictionary.json"])

    /// A phone that has been told not to recognise voices.
    ///
    /// The same set minus the bank, which turns `keepsVoiceprints` off and with
    /// it the subscription, the pull and every read. A policy rather than a
    /// branch at each call site: the zone is the mechanism, and a device that
    /// does not subscribe never receives one rather than declining to save it.
    public static let phoneWithoutVoices = DevicePolicy(
        sidecars: ["metadata.json", "transcript.json", "turns.json", "waveform.json",
                   DevicePolicy.sourceIcon],
        blobs: ["contacts.json", "dictionary.json"])

    /// Things at the library root that are deliberately in no set, recorded
    /// here because the next person to enumerate that directory will wonder.
    ///
    /// - `dictations.jsonl` is what you have said into the keyboard, which
    ///   Listen 0.12.0 added. A dictation is a keyboard and not a meeting: the
    ///   agent does not read it, no screen in either app shows it, and it is
    ///   the one file here whose contents are least like library content.
    /// - `chats/` and `agent/` are conversations and agent configuration.
    ///   Conversations moved out of recording folders in 0.11.0 and are a
    ///   library-level object now, so they are a candidate for a later zone
    ///   rather than a thing with no home, but nothing on the phone can open
    ///   one and a note's `chat` key is a dangling reference there until
    ///   something can.
    /// - `.pairing-key` is a leftover of the retired file key store and must
    ///   never replicate. The legacy `devices.json` and `.sync-state.json` are
    ///   removed after CloudKit has adopted what it needs from them.
    /// - `.sync/` is Resilio's own metadata and is not Listen data.
    /// - `.forgotten-voices.json` replicates through its own z2 record with a
    ///   per-entry merge, never as a file: a byte-level file sync would let
    ///   the newer list win whole and drop the other device's forgets.
    /// - `activity.jsonl` is this device's own audit trail. A log another
    ///   device can rewrite is not an audit log.
    public static let neverSynced = [Trash.directory, "dictations.jsonl", "chats", "agent",
                                     ".pairing-key", ".sync", ".forgotten-voices.json",
                                     "activity.jsonl"]
}
