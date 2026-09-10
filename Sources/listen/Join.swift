import AVFoundation
import Foundation
import ListenKit

/// Two recordings of one conversation, made one.
///
/// **This exists because a meeting can be interrupted by something that is not
/// the meeting.** On 10 September 2026 a build of Listen was installed over the
/// running app eleven minutes into a call: the app was quit, the recording
/// stopped, and the rest of the conversation went into a second folder started
/// 97 seconds later. Nothing in the library could say the two were one thing,
/// and nothing could put them back together. A crash, a forced quit, a Mac
/// running out of disk and an accidental Stop all land in exactly the same
/// shape, so the repair is worth having as a mechanism rather than as a script
/// somebody writes twice.
///
/// **The earlier recording is the one that survives.** Its id carries the start
/// of the meeting, the calendar match was made against that instant, and every
/// note, tag and conversation already pointing at it keeps pointing at it. The
/// later recording is folded in and then deleted through the ordinary path, so
/// the deletion is a tombstone and no other device brings it back.
///
/// **The gap becomes silence and is never closed up.** This is the same
/// argument `WAVWriter.pad(to:)` makes about a track that lost time: closing a
/// hole loses no word but moves every word after it earlier, and on a joined
/// recording that would put the second half's timestamps somewhere the
/// conversation never was. A reader scrubbing the waveform sees the hole, which
/// is the truth about what was recorded.
enum Join {

    // MARK: - Finding one

    /// How long after one recording's audio ends another may start and still be
    /// offered as its continuation.
    ///
    /// **A judgement rather than a measurement, and stated as one.** The only
    /// observation behind it is the case that prompted this: an install killed
    /// a recording and the user had it going again 97 seconds later. Five
    /// minutes is room for noticing, relaunching and pressing Record, and it is
    /// deliberately far short of the ten minutes `MeetingCalendar` allows for
    /// matching an event, because these are different questions. That one asks
    /// whether a recording belongs to a meeting on the calendar; this one asks
    /// whether somebody was cut off and started again, and a wrong offer here
    /// invites a person to destroy a separate recording.
    static let window: TimeInterval = 300

    /// What makes two recordings look like one conversation.
    ///
    /// Kept as the facts rather than reduced to a bool, so the row that offers
    /// the join can say which of them it has. "Same app, 1m 37s apart" is a
    /// reason somebody can check; "these look related" is not.
    struct Evidence {
        var gap: TimeInterval
        var app: String?
        var sameCalendarEvent: Bool

        var phrase: String {
            var parts = [Join.spell(gap) + " apart"]
            if let app { parts.append("both " + app) }
            if sameCalendarEvent { parts.append("the same calendar event") }
            return parts.joined(separator: ", ")
        }
    }

    /// The recording `later` looks like a continuation of, if there is one.
    ///
    /// Nearest first: with two candidates inside the window the one that ended
    /// last is the one the conversation actually ran on from.
    static func predecessor(of later: Recording, in library: [Recording]) -> (Recording, Evidence)? {
        guard let start = later.date else { return nil }
        var best: (Recording, Evidence)?
        for earlier in library where earlier.id != later.id {
            guard let previousStart = earlier.date,
                  let length = audioDuration(of: earlier), length > 0 else { continue }
            let gap = start.timeIntervalSince(previousStart.addingTimeInterval(length))
            guard gap >= 0, gap <= window else { continue }

            // One of the two has to be true. The bundle id is the ordinary
            // case: the same call in the same app. The calendar event carries
            // the ones where it is not, such as a call joined in a browser and
            // resumed in a desktop client.
            let sameApp = later.metadata.app_bundle_id != nil
                && later.metadata.app_bundle_id == earlier.metadata.app_bundle_id
            let sameEvent = later.metadata.calendar_event_id != nil
                && later.metadata.calendar_event_id == earlier.metadata.calendar_event_id
            guard sameApp || sameEvent else { continue }

            if let current = best, current.1.gap <= gap { continue }
            best = (earlier, Evidence(gap: gap,
                                      app: sameApp ? earlier.metadata.app_name : nil,
                                      sameCalendarEvent: sameEvent))
        }
        return best
    }

    // MARK: - Planning

    struct Plan {
        var earlier: Recording
        var later: Recording
        /// Where the later recording's zero lands on the joined timeline.
        ///
        /// Taken from the wall clock rather than from the earlier recording's
        /// audio length, because the clock is what both halves actually share.
        /// They agree when the first recording ended cleanly, and when it did
        /// not it is the audio that is short, not the clock that is wrong.
        var offset: TimeInterval
        var silence: TimeInterval
        var duration: TimeInterval
        var speakers: [String]
        var warnings: [String]
    }

    enum Problem: Error, CustomStringConvertible {
        case message(String)
        var description: String { if case .message(let m) = self { return m }; return "" }
    }

    static func plan(_ later: Recording, into earlier: Recording) throws -> Plan {
        guard later.id != earlier.id else {
            throw Problem.message("a recording cannot be joined to itself.")
        }
        guard let earlierStart = earlier.date, let laterStart = later.date else {
            throw Problem.message("both recordings need a `recorded_at` to be placed on one timeline.")
        }
        guard laterStart > earlierStart else {
            throw Problem.message("\(later.id) starts before \(earlier.id). Name the earlier one second.")
        }
        guard let earlierAudio = audioDuration(of: earlier) else {
            throw Problem.message("\(earlier.id) has no audio on this Mac, so there is nothing to join onto.")
        }
        guard let laterAudio = audioDuration(of: later) else {
            throw Problem.message("\(later.id) has no audio on this Mac, so there is nothing to join.")
        }

        let offset = laterStart.timeIntervalSince(earlierStart)
        guard offset >= earlierAudio else {
            throw Problem.message("""
                these overlap: \(earlier.id) holds \(spell(earlierAudio)) of audio and \(later.id) \
                starts \(spell(offset)) in. Joining them would put two recordings of the same \
                seconds on top of each other.
                """)
        }

        var warnings: [String] = []
        if offset - earlierAudio > window {
            warnings.append("\(spell(offset - earlierAudio)) between them, which is longer than the "
                + "\(spell(window)) Listen would offer this for on its own.")
        }
        // Both formats have to line up sample for sample, because the joined
        // file is one continuous stream and nothing in a WAV re-states the rate
        // part way through.
        for name in ["mic.wav", "system.wav"] {
            let a = earlier.folder.appendingPathComponent(name)
            let b = later.folder.appendingPathComponent(name)
            guard let fa = try? AVAudioFile(forReading: a),
                  let fb = try? AVAudioFile(forReading: b) else { continue }
            if fa.fileFormat.sampleRate != fb.fileFormat.sampleRate
                || fa.fileFormat.channelCount != fb.fileFormat.channelCount {
                throw Problem.message("\(name) is \(Int(fa.fileFormat.sampleRate)) Hz / "
                    + "\(fa.fileFormat.channelCount) ch in one and \(Int(fb.fileFormat.sampleRate)) Hz / "
                    + "\(fb.fileFormat.channelCount) ch in the other. These cannot be joined.")
            }
        }

        let first = earlier.storedTranscript, second = later.storedTranscript
        if let a = first?.model, let b = second?.model, a != b {
            warnings.append("different models (\(a) and \(b)), so the joined transcript is two "
                + "readings of one conversation.")
        }
        if (first == nil) != (second == nil) {
            warnings.append("only one half has a transcript. The joined recording keeps it, and the "
                + "other half's audio is read only if you ask for it.")
        }

        let speakers = Array(Set(earlier.storedTurns.map(\.speaker)
            + later.storedTurns.map(\.speaker))).sorted()
        return Plan(earlier: earlier, later: later, offset: offset, silence: offset - earlierAudio,
                    duration: offset + laterAudio, speakers: speakers, warnings: warnings)
    }

    // MARK: - Doing it

    /// Fold the later recording into the earlier one and delete it.
    ///
    /// Audio first and the delete last, so an interruption anywhere in the
    /// middle leaves both recordings on disk. A half-joined library is
    /// recoverable; a deleted second half is not.
    static func apply(_ plan: Plan) throws {
        var earlier = plan.earlier
        let later = plan.later

        for name in ["mic.wav", "system.wav"] {
            try joinTrack(named: name, plan: plan)
        }

        // The transcript and the turns, shifted onto the joined timeline.
        if let second = later.storedTranscript {
            var first = earlier.storedTranscript
                ?? StoredTranscript(segments: [], duration: 0, model: second.model,
                                    wordLevel: second.wordLevel, cleanup: [:])
            first.segments += second.segments.map { shift($0, by: plan.offset) }
            first.duration = plan.duration
            // The weaker claim wins: a transcript is only word-level if every
            // part of it is, and half of one would put a word timing next to a
            // sentence timing with nothing saying which is which.
            first.wordLevel = first.wordLevel && second.wordLevel
            first.cleanup = first.cleanup.merging(second.cleanup, uniquingKeysWith: +)
            first.dictionary = first.dictionary.merging(second.dictionary, uniquingKeysWith: +)
            if first.language != second.language { first.language = nil }
            try write(first, to: earlier.transcriptURL)
        }
        let joinedTurns = earlier.storedTurns + later.storedTurns.map {
            Turn(start: $0.start + plan.offset, end: $0.end + plan.offset,
                 speaker: $0.speaker, text: $0.text)
        }
        if !joinedTurns.isEmpty { try write(joinedTurns, to: earlier.turnsURL) }

        try joinVoiceprints(plan)

        // A backup of a transcript that no longer exists.
        //
        // Restoring it would silently cut the joined recording back to its
        // first half, which is a worse outcome than having no backup, so both
        // halves' copies go rather than one being left to look usable.
        for recording in [earlier, later] {
            try? FileManager.default.removeItem(
                at: recording.folder.appendingPathComponent("\(recording.id).raw.json.bak"))
        }

        // Rebuilt rather than spliced: `Waveform.make` buckets by time across
        // whichever tracks are present, and two envelopes averaged together are
        // not the envelope of the joined audio.
        try? FileManager.default.removeItem(at: earlier.waveformURL)

        earlier.metadata.duration = plan.duration
        // The later half's name only matters when the earlier one has none. The
        // title ladder already ranks the titlers against each other, and the
        // earlier recording is the one the calendar was matched against.
        if earlier.isUntitled, !later.isUntitled {
            earlier.metadata.title = later.metadata.title
            earlier.metadata.title_source = later.metadata.title_source
        }
        if earlier.metadata.calendar_event_id == nil {
            earlier.metadata.calendar_event_id = later.metadata.calendar_event_id
            earlier.metadata.calendar_people = later.metadata.calendar_people
        }
        try earlier.save()

        repoint(later.id, to: earlier.id)

        try later.delete()
    }

    // MARK: - The parts

    private static func joinTrack(named name: String, plan: Plan) throws {
        let first = plan.earlier.folder.appendingPathComponent(name)
        let second = plan.later.folder.appendingPathComponent(name)
        let haveFirst = FileManager.default.fileExists(atPath: first.path)
        let haveSecond = FileManager.default.fileExists(atPath: second.path)
        guard haveFirst || haveSecond else { return }

        let rate = (try? AVAudioFile(forReading: haveFirst ? first : second))?.fileFormat.sampleRate
            ?? SAMPLE_RATE
        // Written beside the destination and moved into place, so a crash part
        // way through leaves the original track alone rather than half
        // rewritten.
        let staging = plan.earlier.folder.appendingPathComponent(name + ".joining")
        try? FileManager.default.removeItem(at: staging)
        // A half-written track left in the folder is 45 MB of nothing that
        // looks like a file somebody meant to keep, so it goes on the way out
        // however this returns.
        var moved = false
        defer { if !moved { try? FileManager.default.removeItem(at: staging) } }
        let writer = try WAVWriter(url: staging, sampleRate: rate)
        if haveFirst { try copy(first, into: writer) }
        // Silence up to where the second recording's clock says it began, which
        // covers both the time between them and any tail the first one lost.
        writer.pad(to: plan.offset)
        if haveSecond { try copy(second, into: writer) }
        writer.close()

        let destination = plan.earlier.folder.appendingPathComponent(name)
        if haveFirst {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        moved = true
    }

    private static func copy(_ url: URL, into writer: WAVWriter) throws {
        let file = try AVAudioFile(forReading: url)
        let block: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: block) else { return }
        // Bounded by the file's own length, and never by a read that comes back
        // empty.
        //
        // `AVAudioFile.read` **throws** when it is asked for frames at the end
        // of a file rather than returning none, and it throws a bare
        // `_GenericObjCError error 0` that names nothing. So the obvious loop,
        // reading until it is told there is no more, fails on the last block of
        // every track it is given: the first attempt at this wrote all 699
        // seconds of a track and then reported that the join had failed, with
        // the finished audio sitting in the staging file unheadered.
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(min(Int64(block), file.length - file.framePosition))
            try file.read(into: buffer, frameCount: remaining)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channel = buffer.floatChannelData?[0] else { break }
            try writer.append(Array(UnsafeBufferPointer(start: channel, count: frames)))
        }
    }

    /// One print per speaker across the joined recording.
    ///
    /// Weighted by how much speech each half heard, which is what makes this
    /// the same answer the pipeline would have given had the conversation been
    /// recorded in one piece: a speaker who said four words before the
    /// interruption and four minutes after it must not count half.
    private static func joinVoiceprints(_ plan: Plan) throws {
        let first = plan.earlier.voiceprints, second = plan.later.voiceprints
        guard !first.isEmpty || !second.isEmpty else { return }
        var joined = first
        for (label, print) in second {
            guard let existing = joined[label] else { joined[label] = print; continue }
            let auto = (existing.auto ?? false) && (print.auto ?? false)
            joined[label] = Voiceprint(
                embedding: VoiceBankCore.weighted([(existing.embedding, existing.speech),
                                            (print.embedding, print.speech)]),
                speech: existing.speech + print.speech,
                // Automatic only while both halves were, because one hand-named
                // half is a person having said who this is.
                auto: auto ? true : nil)
        }
        try write(joined, to: plan.earlier.embeddingsURL)
    }

    /// Move every note and conversation off the recording that is about to go.
    ///
    /// A note naming a deleted id is a note about nothing, and the id is gone
    /// from the library the moment the tombstone lands. Each format does its own
    /// rewrite, in the file that owns it, so neither has to be understood here.
    @discardableResult
    private static func repoint(_ from: String, to id: String) -> (notes: Int, chats: Int) {
        let notes = Notes.repoint(from, to: id).count
        var chats = 0
        for var chat in Chat.all() where chat.recordings?.contains(from) == true {
            var seen = Set<String>()
            chat.recordings = (chat.recordings ?? [])
                .map { $0 == from ? id : $0 }
                .filter { seen.insert($0).inserted }
            // Not a touch: repointing a conversation is bookkeeping about a
            // recording, and it must not push it to the top of History as
            // though somebody had just been talking to it.
            chat.save(touch: false)
            chats += 1
        }
        return (notes, chats)
    }

    private static func shift(_ segment: LabelledSegment, by offset: TimeInterval) -> LabelledSegment {
        LabelledSegment(start: segment.start + offset, end: segment.end + offset,
                        speaker: segment.speaker, text: segment.text)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    static func audioDuration(of recording: Recording) -> TimeInterval? {
        var longest: TimeInterval?
        for name in ["mic.wav", "system.wav"] {
            let url = recording.folder.appendingPathComponent(name)
            guard let file = try? AVAudioFile(forReading: url),
                  file.fileFormat.sampleRate > 0 else { continue }
            longest = max(longest ?? 0, Double(file.length) / file.fileFormat.sampleRate)
        }
        // The file rather than `metadata.duration`, because the recording this
        // feature exists for is precisely the one whose duration was never
        // written: the app was killed before it could. 688C says 0 seconds on
        // disk and holds 11m 40s of audio.
        return longest
    }

    static func spell(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        return whole % 60 == 0 ? "\(whole / 60)m" : "\(whole / 60)m \(whole % 60)s"
    }
}
