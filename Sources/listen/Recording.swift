import Foundation
import ListenKit

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

    /// Speakers the voice bank named without being asked.
    ///
    /// The record of what happened, and the reason it is safe for it to happen
    /// at all: an automatic name is otherwise indistinguishable from one a
    /// person chose, in a transcript nobody may open for a month. Read by
    /// `hasHumanEdits`, printed by `listen show`, and the answer to "why does
    /// this say Marcia when I never said so".
    ///
    /// `Optional` for the reason every other added field here is. See
    /// `calendar_event_id`.
    var auto_named: [String]?

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

    /// Whether the microphone was carrying a room rather than one person.
    ///
    /// The laptop-on-the-table case. `true` means the mic track is diarized like
    /// any other and the people in the room arrive as letters; `false` means the
    /// mic is the user and is labelled `Me` in one step, which is what a call
    /// looks like. `nil` means nothing has decided yet, which is every recording
    /// made before this field existed.
    ///
    /// `Pipeline.decideRoom` owns the value and writes what it inferred, so this
    /// is both the input and the record of the decision. Which of the two it is
    /// on any given recording is what `room_auto` says.
    var room: Bool?

    /// True when `room` is the pipeline's inference rather than somebody's
    /// answer.
    ///
    /// The same split as `auto_named`, for the same reason: a decision the app
    /// made must not be indistinguishable from one a person made. It is also
    /// what keeps the inference alive. An inferred value is re-derived on every
    /// re-run, so a recording whose audio says "room" does not stay wrong
    /// because an early guess was written down; a chosen one is never
    /// re-decided, so the answer survives Transcribe Again.
    var room_auto: Bool?

    /// True when the microphone track was captured and turned out to hold no
    /// audio at all.
    ///
    /// The recording exists, the file is the right length, and the user's own
    /// voice is not in it. That happens for reasons outside the app: a laptop
    /// recorded with its lid shut has no built-in microphone, because macOS
    /// switches it off while leaving the device present, alive, unmuted and
    /// delivering bit-exact zeros. Measured on the recording this field was
    /// added for: 56,239,952 samples, not one of them nonzero, while the system
    /// track was healthy throughout.
    ///
    /// It has to be written down at capture time because it cannot be recovered
    /// afterwards in any way that is safe. A silent file and a meeting where the
    /// user never spoke are byte-identical, and the transcript that comes out of
    /// one reads like an ordinary conversation in which the other person did all
    /// the talking. Set once, at `Capture.stop`, from `MicRecorder.sawAudio`.
    ///
    /// `true` or absent, never `false`: the recordings made before this existed
    /// were never checked, and claiming otherwise would make the flag useless.
    var mic_silent: Bool?

    /// Where the title came from, when nobody typed it.
    ///
    /// The same split as `auto_named` and `room_auto`, and here it is what makes
    /// a second automatic titler possible at all. `isUntitled` used to be the
    /// whole guard, and one bit can only answer "has this a name", which is why
    /// `DetailView` records that naming a recording after its app "would break
    /// calendar naming outright": any writer that puts a string here locks the
    /// calendar out for ever, because the placeholder is gone and nothing can
    /// tell the app's guess from a person's decision.
    ///
    /// So: `nil` on a titled recording means somebody chose it, and nothing
    /// automatic ever writes over that. A value means the app derived it, and a
    /// source of the same rank or higher may derive it again. See
    /// `Recording.mayTitle(from:)` for the ordering and what it protects.
    ///
    /// `nil` also covers every recording that predates this field, including the
    /// fourteen the legacy Python import named `2607-17-Google Chrome`. Freezing
    /// those is the right answer and the one `listen calendar backfill` already
    /// gives: deciding which existing titles are "really" machine-generated
    /// would be a heuristic, and a heuristic that overwrites a meeting's name is
    /// the thing this design is avoiding.
    var title_source: String?

    /// Which device made the transcript, and how long it took.
    ///
    /// Provenance rather than state. `state` says what stage a recording has
    /// reached; these say who did the work and when, which is the question a
    /// library spread over three devices actually raises and one that never
    /// came up while a recording could only be transcribed by the one machine
    /// that could hear it.
    ///
    /// **`transcribed_by` is the device id and `transcribed_on` is its name**,
    /// which is the same split as `app_bundle_id` and `app_name` and exists
    /// for the same reason: the id is what code compares and survives a
    /// rename, the name is what a person reads and survives the device being
    /// dropped from the roster after a month of silence. Read "transcribed on
    /// Studio", not "transcribed on Tuesday": the times are the two fields
    /// below.
    ///
    /// Optional, like every other field added to this struct after there were
    /// files on disk, and mirrored in `ListenKit.Metadata` so the phone can
    /// show the same two lines. They live in `metadata.json` and therefore
    /// inside the sealed payload, so they cost no CloudKit schema at all.
    var transcribed_by: String?
    var transcribed_on: String?
    var transcribe_started: String?
    var transcribe_finished: String?

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

    /// The automatic titlers, worst evidence first.
    ///
    /// The order is the whole point, so it is declared once here rather than
    /// left implicit in the order things happen to run. A calendar title is a
    /// sentence somebody wrote in an invitation, a model title is a guess about
    /// the subject, and a people title is a list of who spoke: each is better
    /// evidence of what a recording *is* than the one below it, and each may
    /// therefore write over the one below it.
    ///
    /// The rank is the declaration order rather than a number written beside
    /// each case, because two numbers can disagree with the list they annotate
    /// and a list cannot disagree with itself. The raw values are what land in
    /// `metadata.json`, so they are the one thing here that may never be
    /// reordered or renamed.
    enum TitleSource: String, CaseIterable {
        /// Who spoke, once they all have names. `AutoTitle`.
        case people
        /// What was said, from a language model. Not yet written by anything.
        case model
        /// The meeting's own name. `MeetingCalendar.attach`.
        case calendar

        var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

        /// How the app says it named this, where somebody reads it.
        ///
        /// Here rather than at each printer, because there is more than one of
        /// them already and a title that explains itself one way in the CLI and
        /// another in the window explains itself twice.
        var phrase: String {
            switch self {
            case .people:   return "named after the speakers"
            case .model:    return "named from what was said"
            case .calendar: return "named from the calendar"
            }
        }
    }

    var titleSourceValue: TitleSource? { title_source.flatMap(TitleSource.init) }

    /// What a recording is called until somebody names it.
    ///
    /// Stored rather than left empty, so every reader outside this app, the
    /// CLI, the MCP server, an export, has a string to print instead of a
    /// blank. It used to be "Recording, 5 Aug 2026 at 14:31", which repeated
    /// the day heading and the time already printed on the same row and made an
    /// unnamed recording look named.
    ///
    /// **This is a key and not a word.** `Recording.isUntitled` compares against
    /// it, and `mayTitle` gates the calendar and `AutoTitle` on that comparison,
    /// so changing this string does not rename anything: it orphans every
    /// recording already carrying the old one, which then reads as a title
    /// somebody typed and is never named automatically again. What is shown is
    /// `untitledDisplay`, which is free.
    static let untitled = "Untitled"

    /// The same thing as a person reads it, and the only one of the two that
    /// may be changed at will. Every drawing of it goes through
    /// `Recording.displayTitle`, which is where the split is argued.
    static let untitledDisplay = "New recording"

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
    /// The replicated copy: one stereo FLAC, mic left and system right, which
    /// is what a Mac that never recorded this meeting can end up holding. See
    /// `AudioMaster`.
    var masterURL: URL { AudioMaster.url(in: folder) }
    var transcriptURL: URL { folder.appendingPathComponent("transcript.json") }
    var turnsURL: URL { folder.appendingPathComponent("turns.json") }
    var embeddingsURL: URL { folder.appendingPathComponent("embeddings.json") }
    var metadataURL: URL { folder.appendingPathComponent("metadata.json") }
    var sourceIconURL: URL { folder.appendingPathComponent(DevicePolicy.sourceIcon) }
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
    /// A name the voice bank applied does not count either, for the same reason
    /// `Me` does not: nobody chose it. Without this, every recording the bank
    /// ever named would warn about losing corrections that were never made,
    /// which is the fastest way to teach somebody to click through the warning
    /// that matters.
    var hasHumanEdits: Bool {
        if FileManager.default.fileExists(atPath: rawBackupURL.path) { return true }
        let automatic = Set(metadata.auto_named ?? [])
        return storedTurns.contains {
            !VoiceBank.isPlaceholder($0.speaker) && $0.speaker != Pipeline.userLabel
                && !automatic.contains($0.speaker)
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

    /// Whether the microphone held a room rather than one person.
    ///
    /// The tick in the menu and the line `listen show` prints. It reads the
    /// answer for this recording without caring who gave it, which is right for
    /// display: what a reader wants to know is how the transcript was made.
    /// `Pipeline.decideRoom` is the one place the distinction between an
    /// inferred and a chosen answer matters.
    var isRoom: Bool { metadata.room == true }

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
    /// The master counts, and that is what it is for. A Mac that was given one
    /// and never had the tracks can play the meeting and transcribe it again,
    /// so answering "no audio here" about it would be false in the direction
    /// that hides a working copy. `Queue` takes it apart before a run, because
    /// the pipeline reads the two tracks separately on purpose.
    var hasAudio: Bool {
        !tracks.isEmpty || FileManager.default.fileExists(atPath: mixURL.path)
            || FileManager.default.fileExists(atPath: masterURL.path)
    }

    /// Whether the two separate tracks are here, which is what the pipeline
    /// reads and a different question from `hasAudio`.
    var hasTracks: Bool { !tracks.isEmpty }

    /// Every audio file for this recording that is on this Mac, so that
    /// measuring what audio costs, or freeing it, means all of it rather than
    /// most of it.
    var audioFiles: [URL] {
        [micURL, systemURL, mixURL, masterURL].filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
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
        // Re-read before writing, the same rule `Capture.noteApp` follows and
        // for a sharper version of the same reason. Transcribing an hour takes
        // an hour's worth of chances for the folder to have changed underneath:
        // the title and the tags are editable from the window while the queue
        // works, and `Pipeline.decideRoom` now writes to `metadata.json` from
        // inside the run itself. Saving the copy this job started with silently
        // undid all of it, which for the room decision meant the pipeline
        // recorded what it had decided and then erased it a minute later.
        if let fresh = Recording.load(folder) { self = fresh }

        // Nothing to label in a recording with no speech in it, so it is
        // finished rather than waiting on somebody.
        metadata.state = transcript.segments.isEmpty
            ? Metadata.State.done.rawValue
            : Metadata.State.needsLabelling.rawValue
        try? save()

        // Name whoever the bank is sure about, before anybody is asked. Here
        // rather than in `Pipeline` because this is the one call the queue and
        // `listen transcribe` share, so the two cannot come to different
        // conclusions about a recording they both just transcribed.
        //
        // After the save above, not before: `TranscriptEditor` re-derives the
        // state from what is left unnamed, and that answer is the better one.
        // The copy in hand is a moment old once it has run.
        VoiceBank.autoAssign(in: self)
        if let fresh = Recording.find(id) { self = fresh }

        // A transcript can arrive with every speaker already named, in which
        // case no rename ever happens and the hook in `TranscriptEditor` never
        // fires. An import is the case that reaches this. On the ordinary path
        // `autoAssign` has just been through that hook for each voice it
        // recognised, so this is a re-derivation of the string already on disk
        // and `refresh` writes nothing.
        if let titled = AutoTitle.refresh(self) { self = titled }
    }

    /// Name this recording, or clear it back to the placeholder.
    ///
    /// The one place a person's chosen title is written. `Tags` records that
    /// until it existed nothing owned a metadata edit at all and
    /// `metadata.title = …; try? save()` was written out in five places; this is
    /// that rule applied to the field the comment names. The window and
    /// `listen title` are the two callers, and the trimming below is why they
    /// have to share: a second implementation of "empty means Untitled" agrees
    /// with the first right up until it does not, and there is no test target to
    /// catch the day it stops.
    ///
    /// Clearing un-names the recording rather than leaving a row with nothing to
    /// click: the placeholder goes back on disk, which is the state it was in
    /// before anybody named it, and `isUntitled` is what the calendar checks
    /// before it applies a name of its own.
    ///
    /// Returns whether anything changed, so a caller that redraws on a rename
    /// does not redraw on a click that committed the same string. `false` is not
    /// a failure; a failed write throws.
    ///
    /// `MeetingCalendar` deliberately does not come through here. It writes a
    /// title derived from an event rather than one a person typed, under its own
    /// `isUntitled` guard, and trimming input nobody typed would be a rule
    /// borrowed from the wrong caller.
    @discardableResult
    mutating func rename(to typed: String) throws -> Bool {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? Metadata.untitled : trimmed
        guard name != metadata.title else { return false }
        metadata.title = name
        // A title somebody typed has no source, and that absence is what freezes
        // it: `mayTitle` refuses every automatic writer against a title with no
        // source. Cleared unconditionally rather than only when a name was
        // given, so clearing the field leaves the recording exactly as
        // titleable as it was before anybody named it, which is what the
        // comment above promises.
        metadata.title_source = nil
        try save()
        return true
    }

    /// Whether `source` may write this recording's title.
    ///
    /// The one place the ordering in `Metadata.TitleSource` is enforced, so the
    /// calendar, `AutoTitle` and anything added later cannot come to different
    /// conclusions about whose name wins. Three answers, in the order they are
    /// asked:
    ///
    /// 1. **Nobody has named it**, so anything may. This is the old
    ///    `isUntitled` guard, unchanged, and it is still the common case.
    /// 2. **A person named it**, and nothing automatic ever writes over that.
    ///    A typed title has no `title_source`, which is what makes this the
    ///    same test as "was this derived", and it is why `rename` clears the
    ///    field rather than setting it to a `user` case.
    /// 3. **The app named it**, and a source may write over one that ranks
    ///    below it or refresh one of its own. Refreshing its own is what lets a
    ///    people title follow the speakers as they are labelled; the ranking is
    ///    what stops that same title outranking the meeting it belongs to when
    ///    `listen calendar backfill` finds the invitation later.
    func mayTitle(from source: Metadata.TitleSource) -> Bool {
        if isUntitled { return true }
        guard let current = metadata.titleSourceValue else { return false }
        return source.rank >= current.rank
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
