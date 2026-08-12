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

    public init(sidecars: [String], blobs: [String], keepsRawBackup: Bool = true) {
        self.sidecars = sidecars; self.blobs = blobs
        self.keepsRawBackup = keepsRawBackup
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
    /// disk. Keeping these out of the library record is the difference between
    /// a phone declining to save a voiceprint and a phone never receiving one,
    /// and only the second is worth claiming.
    public static let voiceprintFiles = ["embeddings.json"]

    /// The per-recording files that belong in the library zone: everything
    /// this device keeps, minus anything with a zone of its own.
    public var librarySidecars: [String] {
        sidecars.filter { !DevicePolicy.voiceprintFiles.contains($0) }
    }

    /// Whether this device keeps voiceprints at all, which decides whether it
    /// subscribes to that zone.
    public var keepsVoiceprints: Bool {
        sidecars.contains(where: DevicePolicy.voiceprintFiles.contains)
    }

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
                   "waveform.json", "embeddings.json"],
        blobs: ["contacts.json", "dictionary.json"])

    /// Everything a phone keeps.
    ///
    /// `SYNC.md` measured the whole set at 6.5 MB for 41 recordings, so the
    /// phone takes all of it and searches locally.
    ///
    /// `embeddings.json` is deliberately absent: it is voiceprint material, it
    /// is the largest sidecar, and the phone has nothing that reads it. Sending
    /// biometric data to a second device for no reason is exactly the thing
    /// this product exists not to do.
    ///
    /// **That last clause is a decision rather than a fact, and it has a name.**
    /// The absence rests entirely on the phone having nothing that reads a
    /// voiceprint, which stops being true the day the phone diarizes for
    /// itself: it would need the bank coming down to put names on the voices it
    /// has separated, and the embeddings it makes would have to go up or the
    /// bank forgets every meeting held in a room. So this line reverses, and
    /// the argument that a server refusing is stronger than a client declining
    /// to ask has nothing left to defend.
    ///
    /// **Decided on 12 August 2026, and the answer is narrow:** the phone
    /// transcribes for itself and does not diarize, so this set keeps its shape
    /// and voiceprints stay off the phone. Adding `embeddings.json` here is
    /// therefore not a small convenience but a reversal of a product decision,
    /// and `CLOUDKIT-PLAN.md` decision 6 is what would have to change first.
    ///
    /// The same decision gives `dictionary.json` below a reader it did not have
    /// when this file was written.
    ///
    /// The `blobs` are declared here and are **not** moved by the LAN
    /// transport, which is not an oversight: wire ops for them would be code
    /// written for a transport that is being deleted.
    ///
    /// `dictionary.json` is the one to move first when there is a transport
    /// that can. It rewrites transcripts, so two devices with different
    /// dictionaries produce differently corrected transcripts of the same
    /// audio, and once the phone transcribes for itself that stops being a
    /// two-Mac problem and becomes the difference between the phone's pass and
    /// the Mac's looking like a quality gap when it is a vocabulary one.
    public static let phone = DevicePolicy(
        sidecars: ["metadata.json", "transcript.json", "turns.json", "waveform.json"],
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
    /// - `.pairing-key`, `devices.json` and `.sync-state.json` are per-device
    ///   state and must never replicate. `CLOUDKIT-PLAN.md` §2.7 is about
    ///   exactly this, and `.sync/`, which is Resilio's own metadata, is still
    ///   sitting there from before the library moved.
    public static let neverSynced = ["dictations.jsonl", "chats", "agent",
                                     ".pairing-key", "devices.json",
                                     ".sync-state.json", ".sync"]
}
