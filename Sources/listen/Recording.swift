import Foundation

/// What a recording folder knows about itself.
///
/// The keys are the Python pipeline's where they overlap (`title`,
/// `recorded_at`, `duration`), so the existing tools keep working against the
/// new app's output during the port.
struct Metadata: Codable {
    var id: String
    var title: String
    var recorded_at: String
    var duration: Double
    var source: String
    var state: String

    /// The meeting this recording is of, when the calendar knew about one.
    ///
    /// The iCal UID rather than an `eventIdentifier`, which is per-store and
    /// shared by every occurrence of a repeating event.
    ///
    /// Its presence is also the "already looked" flag: matching runs once and
    /// then never again, so a rename or a merge cannot be undone by a later
    /// pass. `nil` means nothing matched, not that nothing was tried, and
    /// `listen calendar match <id>` is how the difference is inspected.
    var calendar_event_id: String?

    /// Who was invited, snapshotted at match time.
    ///
    /// A snapshot and not a live read, for the reason the voiceprints live
    /// beside the audio: the event can be edited or deleted, calendar access
    /// can be revoked, and the library still has to answer. A recording is a
    /// folder and the files in it are the truth.
    var calendar_people: [CalendarPerson]?

    /// The app the call was in, as Core Audio reported it.
    ///
    /// The identifier is the stable fact and the name is what a person reads,
    /// the same split as `Me` and `Speaker A`. It is stored with the parent
    /// resolved (`com.google.Chrome`, never `…helper.renderer`), because a
    /// per-renderer identifier is unrecognisable and matches nothing later.
    ///
    /// `nil` means nobody was on a call when capture began and none was seen
    /// while it ran, which is the ordinary state of a recording made by
    /// pressing Record in a quiet room.
    var app_bundle_id: String?

    /// What that app was called at the time, snapshotted.
    ///
    /// Kept beside the identifier for the reason `calendar_people` is a
    /// snapshot: `AppNames.display` resolves through `NSWorkspace`, so an app
    /// that has since been uninstalled resolves to nothing and the subtitle
    /// would read `net.whatsapp.WhatsApp` instead of "WhatsApp". Display
    /// prefers the live lookup and falls back to this.
    var app_name: String?

    /// What this recording is about, in the user's own words.
    ///
    /// The user's own classification and nothing derived: a recruiter screen, a
    /// hiring manager chat and a referral catch-up share no words, no attendee
    /// and no week, so free text, a person and a date range between them cannot
    /// name "the job hunt calls". A tag is how a question says what it is about.
    ///
    /// Held here rather than in a library-level file, which is the opposite of
    /// the call `Notes` made and for the reason `Notes` gives: a note can be
    /// about four meetings and outlive all of them, and a tag is a claim about
    /// this one recording with no meaning apart from it. So deleting a
    /// recording takes its tags with it and strands nothing.
    ///
    /// Sorted case-insensitively on the way in, so the row of pills is stable
    /// and the file diffs cleanly. `Tags` owns every write.
    var tags: [String]?

    /// Which speech model to transcribe this one recording with.
    ///
    /// A `ModelChoice.id`, and `nil` means the app default, which is every
    /// recording on disk before this field existed and every new one.
    ///
    /// It lives on the recording rather than on the queue job, and that is the
    /// whole design. The queue has no job table: `Queue.resume()` rebuilds it at
    /// launch from "audio exists and a transcript does not". A choice carried
    /// only by the running job would be lost to a quit or a crash, and the
    /// relaunch would re-run a Dutch meeting on the English-only model and write
    /// the same confident gibberish a second time, with nothing anywhere saying
    /// why. The file system already carries every other fact the queue needs.
    ///
    /// The id and not the repo string, because the id is what `Settings` stores
    /// and what `--model` already takes. An id no longer in `ModelChoice.all`
    /// resolves to nil and falls back to the default, which is what
    /// `Settings.model` does with the same kind of stale value.
    var asr_model: String?

    // The calendar, app, tag and model fields are all `Optional`, and that is
    // what makes them safe to add to a struct with 47 files already on disk.
    //
    // The trap recorded against `StoredTranscript` is that Swift's synthesized
    // decoder throws `keyNotFound` on a missing key *even when the property has
    // a default value*, which is why that type has a hand-written
    // `init(from:)`. It does not apply here: for an `Optional` property the
    // synthesized decoder uses `decodeIfPresent`, so a missing key decodes as
    // nil and every `metadata.json` written before today still reads. Verified
    // with `listen list` over the whole library rather than assumed.

    enum State: String {
        /// Captured but not confirmed by the user. Lives in `staging/`.
        case unconfirmed
        /// In the library, waiting for the transcription queue.
        case pending
        case transcribing
        /// Transcribed, speakers not yet named.
        case needsLabelling = "needs_labelling"
        case done
        case failed
    }

    var stateValue: State { State(rawValue: state) ?? .pending }

    /// What a recording is called until somebody names it.
    ///
    /// Stored rather than left empty, so every reader outside this app, the
    /// CLI, the MCP server, an export, has a string to print instead of a
    /// blank. It used to be "Recording, 5 Aug 2026 at 14:31", which repeated
    /// the day heading and the time already printed on the same row and made an
    /// unnamed recording look named.
    static let untitled = "Untitled"

    static func makeID(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        // Four hex characters on the end, as the Python pipeline does, so two
        // recordings started in the same second cannot collide.
        let suffix = String(format: "%04X", Int.random(in: 0...0xFFFF))
        return f.string(from: date) + "-" + suffix
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}

/// One recording on disk.
///
/// There is no database. A recording is a folder, and the files in it are the
/// state: audio with no transcript is pending, a transcript with unnamed
/// speakers needs labelling. That is what makes the pipeline resumable across a
/// quit without a job table, and it means deleting a folder in Finder cannot
/// strand a row anywhere.
struct Recording {
    let folder: URL
    var metadata: Metadata

    var id: String { metadata.id }
    var micURL: URL { folder.appendingPathComponent("mic.wav") }
    var systemURL: URL { folder.appendingPathComponent("system.wav") }
    var mixURL: URL { folder.appendingPathComponent("mix.m4a") }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.json") }
    var turnsURL: URL { folder.appendingPathComponent("turns.json") }
    var embeddingsURL: URL { folder.appendingPathComponent("embeddings.json") }
    var metadataURL: URL { folder.appendingPathComponent("metadata.json") }
    /// What the pipeline wrote, kept once before the first edit to it.
    var rawBackupURL: URL { folder.appendingPathComponent("\(id).raw.json.bak") }

    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcriptURL.path) }

    /// Whether somebody has been through this transcript by hand.
    ///
    /// Two things count, and they are the two that transcribing again destroys:
    /// a speaker named something other than a placeholder letter or the
    /// microphone's own `Me`, and the backup `TranscriptEditor` takes once
    /// before the first sentence edit.
    ///
    /// `Me` does not count because the pipeline writes it, not a person, and a
    /// placeholder does not count because nobody chose it either. Counting
    /// either would ask for confirmation on every recording in the library,
    /// which is the same as asking on none of them.
    var hasHumanEdits: Bool {
        if FileManager.default.fileExists(atPath: rawBackupURL.path) { return true }
        return storedTurns.contains {
            !VoiceBank.isPlaceholder($0.speaker) && $0.speaker != Pipeline.userLabel
        }
    }

    /// Which app the call was in, including the recordings made before there
    /// was a field for it.
    ///
    /// Detection used to pass the bundle identifier in as the `source`, so
    /// recordings on disk say `source: "com.google.Chrome"` where a newer one
    /// says `source: "detected"` with the identifier in its own field. Derived
    /// here rather than repaired by a migration pass, for the reason
    /// `effectiveState` is derived: a rewrite of every metadata file to fix a
    /// field nothing had ever read is a lot of risk to buy tidiness, and the
    /// old shape is unambiguous. A bundle identifier has a dot in it and none
    /// of the four provenance words does.
    var appBundleID: String? {
        if let stored = metadata.app_bundle_id { return stored }
        return metadata.source.contains(".") ? metadata.source : nil
    }

    /// The model the next run will use: this recording's own, or the default.
    ///
    /// The one place that rule is written. `Pipeline` takes the choice as an
    /// argument rather than reading `Settings` itself, so a caller can never
    /// transcribe with one model while the library records another.
    var asrModel: ModelChoice {
        ModelChoice.named(metadata.asr_model ?? "") ?? Settings.model
    }

    /// Every track that exists, for whatever wants to read audio.
    var tracks: [URL] {
        [micURL, systemURL].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Whether any audio for this recording is on **this** Mac.
    ///
    /// The mixdown counts as well as the two tracks, because an imported
    /// recording has only `mix.m4a` and `Pipeline.run` transcribes that as the
    /// everyone-track.
    ///
    /// False is a normal state rather than a broken one, and that is the whole
    /// reason this exists. A library shared between two Macs deliberately leaves
    /// the audio on the machine that recorded it: measured here, the WAVs are
    /// 8.3 GB of an 8.4 GB library, and nothing the transcript, the CLI or the
    /// MCP server reads ever opens them. So on the second Mac the ordinary case
    /// is a recording whose transcript is present and whose audio is not, and
    /// anything that would otherwise reach for the audio has to ask first.
    ///
    /// `hasTranscript` is **not** the test to use instead. A recording made on
    /// the other Mac arrives as metadata before its transcript has been written,
    /// so for those minutes it has neither, and it is still not this machine's
    /// job.
    var hasAudio: Bool {
        !tracks.isEmpty || FileManager.default.fileExists(atPath: mixURL.path)
    }

    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    static func load(_ folder: URL) -> Recording? {
        let url = folder.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let meta = try? JSONDecoder().decode(Metadata.self, from: data)
        else { return nil }
        return Recording(folder: folder, metadata: meta)
    }

    /// Every recording in the library, newest first.
    static func all() -> [Recording] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Library.recordings, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap(load).sorted { $0.id > $1.id }
    }

    /// Recordings captured but never confirmed.
    static func staged() -> [Recording] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: Library.staging, includingPropertiesForKeys: nil) else { return [] }
        return entries.compactMap(load).sorted { $0.id > $1.id }
    }

    static func find(_ id: String) -> Recording? {
        (all() + staged()).first { $0.id == id }
    }

    /// Move a staged recording into the library.
    ///
    /// A move, not a copy: the audio is never duplicated and never rewritten,
    /// so confirming cannot fail halfway and leave two half-recordings.
    mutating func promote() throws {
        guard folder.deletingLastPathComponent() == Library.staging else { return }
        let destination = Library.recordings.appendingPathComponent(id)
        try FileManager.default.createDirectory(
            at: Library.recordings, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: folder, to: destination)
        self = Recording(folder: destination, metadata: metadata)
        metadata.state = Metadata.State.pending.rawValue
        try save()
    }

    /// Record the outcome of a transcription run.
    ///
    /// One derivation, called by both the queue and the CLI. They used to each
    /// have their own idea: `listen transcribe` wrote the transcript and left
    /// `state` alone, so four recordings that had been through a failed run
    /// kept saying "could not transcribe" in the sidebar while their transcript
    /// sat next to them on disk.
    /// The state, reconciled against what is actually on disk.
    ///
    /// `metadata.state` is a cache and the files are the truth, which is the
    /// same principle that lets the queue be rebuilt by listing the library. A
    /// process killed mid-job leaves `transcribing` behind for ever, and an
    /// imported recording arrives saying `pending` whatever happens to it
    /// afterwards, so seven recordings sat in the sidebar claiming to be
    /// waiting or working while their finished transcript lay beside them.
    ///
    /// Deriving it here means no repair pass is needed and a future writer that
    /// forgets to update the field cannot reintroduce the same lie.
    var effectiveState: Metadata.State {
        let stored = metadata.stateValue
        guard hasTranscript else {
            // Staging is the one state the files cannot tell you, because it is
            // about which folder the recording is in rather than what is in it.
            return stored == .unconfirmed ? .unconfirmed : .pending
        }
        switch stored {
        case .pending, .transcribing, .failed:
            return storedTurns.isEmpty ? .done : .needsLabelling
        case .unconfirmed, .needsLabelling, .done:
            return stored
        }
    }

    mutating func markTranscribed(_ transcript: StoredTranscript) {
        // Nothing to label in a recording with no speech in it, so it is
        // finished rather than waiting on somebody.
        metadata.state = transcript.segments.isEmpty
            ? Metadata.State.done.rawValue
            : Metadata.State.needsLabelling.rawValue
        try? save()
    }

    func delete() throws {
        try FileManager.default.removeItem(at: folder)
    }
}

extension Library {
    /// Where a capture lives until the user says to keep it.
    ///
    /// Capture writes here from the first second, before anyone has confirmed
    /// anything. Waiting for a human to press something before recording loses
    /// the first minute of every meeting, every time.
    static var staging: URL { root.appendingPathComponent("staging") }

    static func prepare() throws {
        for dir in [recordings, staging] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// Anything unconfirmed and older than this is deleted, which Settings
    /// states plainly rather than hiding.
    static let stagingLifetime: TimeInterval = 24 * 60 * 60

    /// Delete staged recordings nobody ever answered for.
    ///
    /// Returns what was removed, so the caller can say so rather than making
    /// files disappear silently.
    @discardableResult
    static func sweepStaging(now: Date = Date()) -> [String] {
        var removed: [String] = []
        for recording in Recording.staged() {
            guard let created = try? FileManager.default.attributesOfItem(
                atPath: recording.folder.path)[.creationDate] as? Date else { continue }
            if now.timeIntervalSince(created) > stagingLifetime {
                try? recording.delete()
                removed.append(recording.id)
            }
        }
        if !removed.isEmpty { log("swept \(removed.count) unconfirmed recording(s)") }
        return removed
    }
}
