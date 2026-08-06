import Foundation

/// The stored transcript: segments with speakers, plus what produced them.
struct StoredTranscript: Codable {
    var segments: [LabelledSegment]
    var duration: Double
    var model: String
    /// Whether the segments carry word-level assignment. False today.
    var wordLevel: Bool
    /// How often each cleanup rule fired, so the Whisper-era cleanup can be
    /// judged on Parakeet output rather than assumed necessary.
    var cleanup: [String: Int]
    /// How often each dictionary rule fired, keyed `term:x` / `correction:y`.
    ///
    /// The dictionary rewrites this transcript before it is written, and this is
    /// the record that it did. Without it a rule that fires somewhere nobody
    /// expected is invisible: the transcript reads as what the model said, and
    /// the only way to find out otherwise is to listen to the meeting again.
    var dictionary: [String: Int] = [:]
}

extension StoredTranscript {
    /// Decoded by hand so a field added later does not orphan the library.
    ///
    /// Swift's synthesized decoder throws on a missing key even when the
    /// property has a default value, so adding `dictionary` to the struct alone
    /// would have made every `transcript.json` written before today fail to
    /// decode. That failure is silent in the worst possible way: `storedTurns`
    /// and `storedTranscript` both return empty on a decode error, so the whole
    /// library would have gone on showing "not transcribed yet" with the
    /// transcripts still sitting on disk.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        segments = try c.decode([LabelledSegment].self, forKey: .segments)
        duration = try c.decode(Double.self, forKey: .duration)
        model = try c.decode(String.self, forKey: .model)
        wordLevel = try c.decode(Bool.self, forKey: .wordLevel)
        cleanup = try c.decode([String: Int].self, forKey: .cleanup)
        dictionary = try c.decodeIfPresent([String: Int].self, forKey: .dictionary) ?? [:]
    }
}

/// What transcription is doing, and how far through it is.
///
/// **Every number here is counted, none of it is predicted.** `everyone` and
/// `you` are pieces decoded over pieces to decode, which is work finished on the
/// machine doing it. There is deliberately no estimate of time remaining: the
/// only way to have one before the first piece lands is to carry a throughput
/// figure measured somewhere else, and a figure measured on a 128 GB Mac Studio
/// is a promise an M1 Air cannot keep. A machine's own speed shows up here as
/// how fast the bar moves, which is the honest form of the same information.
///
/// `overall` averages the two passes rather than weighting them, because they
/// are the same model over two tracks of the same length and there is nothing
/// to weight. Diarization sits between them and reports no fraction at all, so
/// the bar holds at one half while it runs, with the message saying why. That is
/// a stall of about 7 seconds in 57 on the hour-long recording this was measured
/// against, and a bar that visibly waits next to a sentence explaining the wait
/// is better than one that invents movement to cover it.
struct TranscriptionProgress: Sendable {
    /// The sentence the sidebar row and the pane both show.
    var message: String = "starting"

    /// 0...1 through the track carrying everybody who is not the user. Also the
    /// whole of the work for an imported recording, which has one mixed track.
    var everyone: Double = 0

    /// 0...1 through the microphone track.
    var you: Double = 0

    /// Whether this recording has two tracks. False for an imported one, where
    /// there is a single mixed track and no separate side to fill.
    var split: Bool = true

    /// 0...1 across the whole job.
    var overall: Double {
        split ? (everyone + you) / 2 : everyone
    }
}

/// Somewhere thread-safe for the running totals to live.
///
/// Progress is reported from inside the `ASR` actor, from a `@Sendable` closure,
/// while `Pipeline` is a different actor holding the totals it updates. A
/// captured `var` cannot cross that boundary, and the alternative of rebuilding
/// the whole value at every call site loses whichever field the current stage is
/// not touching.
private final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TranscriptionProgress
    private let report: (@Sendable (TranscriptionProgress) -> Void)?

    /// Fixed for the life of the job, so it needs no lock and the caller can
    /// word a stage differently for a recording with only one track.
    let split: Bool

    init(split: Bool, report: (@Sendable (TranscriptionProgress) -> Void)?) {
        self.split = split
        value = TranscriptionProgress(split: split)
        self.report = report
    }

    /// Change one or both fields and tell whoever is listening.
    func update(_ change: (inout TranscriptionProgress) -> Void) {
        lock.lock()
        change(&value)
        let snapshot = value
        lock.unlock()
        report?(snapshot)
    }

    func say(_ message: String) { update { $0.message = message } }
}

/// Runs a recording through ASR, diarization and the merge, and writes the
/// results next to the audio.
///
/// One job at a time, by construction: the models are GPU and ANE bound and
/// parallel jobs fight over the same hardware rather than finishing sooner.
/// `Pipeline` is an actor, and `Queue` below serialises the whole app onto it.
actor Pipeline {
    private let asr = ASR()
    private let diarizer = Diarizer()

    /// What the user's own track is called before anyone names it.
    ///
    /// A word rather than a letter, because it is not a guess. The mic track is
    /// the user by definition, and calling it "A" would invite the labelling UI
    /// to ask a question that has no doubt in it.
    static let userLabel = "Me"

    /// Transcribe a whole recording: both tracks, diarized and merged.
    ///
    /// The model is an argument rather than a read of `Settings` in here,
    /// because a recording can carry its own (`Metadata.asr_model`) and the two
    /// readers of that rule must not be able to disagree. `Recording.asrModel`
    /// resolves it; every caller passes the result.
    func run(_ recording: Recording, using choice: ModelChoice,
             progress: (@Sendable (TranscriptionProgress) -> Void)? = nil) async throws -> StoredTranscript {
        let fm = FileManager.default
        var hasSystem = fm.fileExists(atPath: recording.systemURL.path)
        let hasMic = fm.fileExists(atPath: recording.micURL.path)

        // Asked here rather than at the mic pass below, where it used to be,
        // because whether there is a second pass decides the shape of the
        // picture and the picture is drawn before the first pass starts. A
        // meeting nobody spoke into would otherwise show a lane for the user
        // that stays empty for ever, which reads as the job having stalled
        // halfway rather than as there being nothing to put in it.
        let micHasSpeech = hasMic && !Self.isSilent(recording.micURL)

        let tally = Tally(split: hasSystem && micHasSpeech, report: progress)
        try await asr.load(choice) { tally.say($0) }

        // An imported recording has neither track, only the mixdown the legacy
        // recorder produced. Treat that as the everyone-track: diarize it whole
        // and discover every speaker, including the user. There is deliberately
        // no shortcut labelling anybody "Me" here, because in a mixed track the
        // user is not distinguishable by which file they are in, and guessing
        // would be worse than asking.
        var everyone = recording.systemURL
        if !hasSystem, !hasMic, fm.fileExists(atPath: recording.mixURL.path) {
            everyone = recording.mixURL
            hasSystem = true
        }

        var labelled: [LabelledSegment] = []
        var embeddings: [String: [Float]] = [:]
        var speech: [String: Double] = [:]
        var wordLevel = false
        var model = choice.repo

        // The system track carries everyone who is not the user, so it is the
        // only one worth diarizing. Doing both would spend ANE time to
        // rediscover something already known and occasionally get it wrong by
        // splitting the user into two people.
        if hasSystem {
            // "the other participants" only when there is a separate mic track
            // to be the other side of. An imported recording is one mixed track
            // holding everybody including the user, and naming it after the
            // people who are not you is simply wrong there.
            tally.say(tally.split ? "transcribing the other participants"
                                  : "transcribing the meeting")
            let transcript = try await asr.transcribe(everyone) { fraction in
                tally.update { $0.everyone = fraction }
            }
            wordLevel = transcript.hasWordTimings
            model = transcript.model
            Self.reportCuts(transcript, track: "everyone")

            tally.say("identifying speakers")
            // Diarization failing must not cost the transcript. It throws on a
            // track with no speech in it, which is an ordinary thing for a
            // recording to contain, and a transcript with everybody under one
            // label is worth enormously more than no transcript at all.
            var turns: [SpeakerTurn] = []
            do {
                try await diarizer.load { tally.say($0) }
                let diarization = try await diarizer.run(everyone)
                turns = diarization.turns
                embeddings = diarization.embeddings
                speech = diarization.speech
            } catch {
                log("speakers not identified: \(error.localizedDescription)")
            }

            var assigned = Merge.assign(transcript.segments, to: turns,
                                        fallback: "A")
            let mapping = Merge.relabel(&assigned)
            // Carry the voiceprints over to the letters the transcript uses,
            // otherwise the embeddings are filed under labels nothing displays.
            embeddings = Self.remap(embeddings, using: mapping)
            speech = Self.remap(speech, using: mapping)
            labelled += assigned
        }

        // The mic is the user. One step, no clustering, no doubt.
        if micHasSpeech {
            tally.say("transcribing you")
            let transcript = try await asr.transcribe(recording.micURL) { fraction in
                tally.update { $0.you = fraction }
            }
            wordLevel = wordLevel || transcript.hasWordTimings
            Self.reportCuts(transcript, track: "you")
            labelled += transcript.segments.map {
                LabelledSegment(start: $0.start, end: $0.end,
                                speaker: Self.userLabel, text: $0.text)
            }
        }

        // No speech is an answer, not a failure. Some recordings really are a
        // muted microphone and a silent tab, and throwing here left them with
        // no transcript, which is exactly the condition `Queue.resume()` reads
        // as "still pending": they were re-transcribed on every launch, for
        // ever, and the audio was re-read each time to reach the same nothing.
        //
        // Writing an empty transcript records that the work was done. The
        // detail pane already says "This recording has no speech in it."
        if labelled.isEmpty {
            let empty = StoredTranscript(segments: [], duration: recording.metadata.duration,
                                         model: model, wordLevel: wordLevel, cleanup: [:])
            try write(empty, turns: [], embeddings: [:], speech: [:], to: recording)
            return empty
        }

        // Interleave the two tracks by time. They were captured together, so
        // their clocks agree and sorting is all the alignment needed.
        labelled.sort { $0.start < $1.start }
        var (cleaned, fired) = Merge.clean(labelled)
        if !fired.isEmpty { trace("cleanup fired: \(fired)") }

        let rules = Self.applyDictionary(to: &cleaned)
        // On stderr rather than behind LISTEN_DEBUG, unlike the cleanup counts.
        // Cleanup is the app tidying up after the model, and the rules are ours.
        // The dictionary is the user's own list rewriting their own meeting, and
        // somebody who added a rule this morning should be told it fired.
        if !rules.isEmpty { log("dictionary applied: \(rules)") }

        let stored = StoredTranscript(
            segments: cleaned,
            duration: recording.metadata.duration,
            model: model,
            wordLevel: wordLevel,
            cleanup: fired,
            dictionary: rules)

        try write(stored, turns: Merge.turns(from: cleaned),
                  embeddings: embeddings, speech: speech, to: recording)
        return stored
    }

    /// Transcribe a bare file, with diarization but no track split.
    ///
    /// What `listen transcribe --diarize` uses. There is no mic and system
    /// distinction here, so every speaker is discovered rather than one of them
    /// being known in advance.
    func runFile(_ url: URL, using choice: ModelChoice,
                 progress: (@Sendable (String) -> Void)? = nil) async throws -> StoredTranscript {
        try await asr.load(choice) { progress?($0) }
        let transcript = try await asr.transcribe(url)
        Self.reportCuts(transcript, track: url.lastPathComponent)

        progress?("identifying speakers")
        try await diarizer.load { progress?($0) }
        let diarization = try await diarizer.run(url)

        var assigned = Merge.assign(transcript.segments, to: diarization.turns,
                                    fallback: "unknown")
        Merge.relabel(&assigned)
        let (cleaned, fired) = Merge.clean(assigned)
        return StoredTranscript(segments: cleaned, duration: transcript.duration,
                                model: transcript.model,
                                wordLevel: transcript.hasWordTimings, cleanup: fired)
    }

    /// Say how the track was cut, on stderr, every run.
    ///
    /// Same argument as the dictionary counts rather than the cleanup ones: this
    /// is the app deciding where to break somebody's meeting, and a cut that
    /// could not find a pause costs about one word with nothing left behind to
    /// find it by. The whole case for cutting at silence is that `hard` is zero
    /// on ordinary speech, and a case nobody can check is not one.
    private static func reportCuts(_ transcript: Transcript, track: String) {
        guard transcript.chunks > 1 else { return }
        let hard = transcript.hardCuts
        log("\(track): \(transcript.chunks) chunks, "
            + (hard == 0 ? "every cut in a pause"
                         : "\(hard) cut(s) with no pause to land in"))
    }

    // MARK: - Writing

    private func write(_ transcript: StoredTranscript, turns: [Turn],
                       embeddings: [String: [Float]], speech: [String: Double],
                       to recording: Recording) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Atomic writes throughout. A transcript half-written by a crash would
        // look like a finished one to the next launch, and the recording would
        // never be picked up again.
        try enc.encode(transcript).write(to: recording.transcriptURL, options: .atomic)
        try enc.encode(turns).write(to: recording.turnsURL, options: .atomic)

        if !embeddings.isEmpty {
            // One embedding per speaker per recording, stored next to the audio.
            // There is deliberately no separate database: the set of sidecar
            // files is the voice bank, so deleting a recording cannot strand an
            // entry in it.
            let bank = embeddings.mapValues { vector in
                Voiceprint(embedding: vector, speech: 0)
            }
            var withSpeech = bank
            for (label, seconds) in speech {
                withSpeech[label]?.speech = seconds
            }
            try enc.encode(withSpeech).write(to: recording.embeddingsURL, options: .atomic)
        }
    }

    /// Run the user's dictionary over every segment, and report what fired.
    ///
    /// **After `Merge.clean`, deliberately.** Cleanup exists to answer whether
    /// Parakeet needs the Whisper-era repetition rules at all, and that question
    /// is only answerable against Parakeet's own output: measuring it after the
    /// dictionary had rewritten the text would count rules firing on words the
    /// model never produced.
    ///
    /// Per segment rather than over the whole transcript joined together. A
    /// segment is one ASR sentence, so every real term sits inside one, and the
    /// alternative would mean splitting the result back up afterwards against
    /// text that changed length.
    ///
    /// Loaded once. `CustomDictionary.load` reads the file on every call by
    /// design, and an hour-long meeting is a few thousand segments.
    private static func applyDictionary(to segments: inout [LabelledSegment])
        -> [String: Int] {
        let entries = CustomDictionary.load()
        guard !entries.isEmpty else { return [:] }
        var fired: [String: Int] = [:]
        for i in segments.indices {
            let applied = CustomDictionary.apply(to: segments[i].text, entries: entries)
            segments[i].text = applied.text
            CustomDictionary.combine(applied.fired, into: &fired)
        }
        return fired
    }

    private static func remap<T>(_ values: [String: T],
                                 using mapping: [String: String]) -> [String: T] {
        var out: [String: T] = [:]
        for (key, value) in values { out[mapping[key] ?? key] = value }
        return out
    }

    /// True when a track holds no signal worth transcribing.
    ///
    /// A meeting where nobody used the microphone leaves a mic track of pure
    /// room noise, and running Parakeet over an hour of that produces confident
    /// hallucinated sentences attributed to the user. Cheaper and more truthful
    /// to skip it.
    ///
    /// Reads the file directly rather than decoding it: the writer's format is
    /// known, so this is a scan of floats.
    static func isSilent(_ url: URL, threshold: Float = 0.002) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        _ = try? handle.seek(toOffset: 44)
        guard let data = try? handle.readToEnd(), data.count >= 4 else { return true }
        var peak: Float = 0
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            // Sample rather than scan every value: an hour is 57 million floats
            // and the answer does not need all of them.
            let stride = max(1, floats.count / 200_000)
            for i in Swift.stride(from: 0, to: floats.count, by: stride) {
                peak = Swift.max(peak, abs(floats[i]))
            }
        }
        return peak < threshold
    }
}

/// One speaker's voiceprint from one recording.
struct Voiceprint: Codable {
    var embedding: [Float]
    /// Seconds of speech it was built from.
    ///
    /// Under 15 seconds the embedding is stored but not used as evidence: it is
    /// too short to be a reliable identity, and a confident wrong suggestion in
    /// the labelling UI is worse than no suggestion.
    var speech: Double

    /// True when the bank named this speaker rather than a person doing it.
    ///
    /// `Optional`, and that is load-bearing for the reason recorded against
    /// `Metadata.calendar_event_id`: Swift's synthesized decoder throws
    /// `keyNotFound` on a missing key even where the property has a default, so
    /// a non-optional `Bool = false` would make every `embeddings.json` written
    /// before this field fail to decode, and `Recording.voiceprints` swallows
    /// that with `try?` and returns `[:]`. The whole voice bank would have
    /// emptied itself with nothing anywhere reporting it.
    ///
    /// Read by `VoiceBank.named`, which is what keeps an automatic name from
    /// becoming the evidence for the next one.
    var auto: Bool?

    static let minimumSpeechForEvidence: Double = 15

    var isEvidence: Bool { speech >= Self.minimumSpeechForEvidence }
}

enum PipelineError: Error, LocalizedError {
    case nothingToTranscribe
    var errorDescription: String? {
        "no audio in this recording that could be transcribed"
    }
}
