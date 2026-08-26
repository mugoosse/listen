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

    /// Whether there are two tracks **with speech in them**. False for an
    /// imported recording, which is a single mixed track with no separate side
    /// to fill, and false for a meeting held in a room, where the system track
    /// is an hour of silence nothing transcribes.
    var split: Bool = true

    /// 0...1 across the whole job.
    ///
    /// A single-lane job fills exactly one of the two fields, and which one
    /// depends on which track had speech: an import reports into `everyone`,
    /// a room recording with a silent system track reports into `you`. This
    /// used to read `everyone` alone, so a room recording's percentage held
    /// at zero for the whole job and the transcript arrived out of nowhere.
    /// `max` is whichever track is actually running, since the other stays 0.
    var overall: Double {
        split ? (everyone + you) / 2 : max(everyone, you)
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
    /// Shared with dictation rather than owned, so the 2.5 GB of weights are
    /// resident once. `Queue.shared` holds one `Pipeline` for the life of the
    /// process, so this was already the only instance in the app; the change is
    /// that dictation now loads the same one. See `ASR.shared`.
    private let asr = ASR.shared
    private let diarizer = Diarizer()

    /// What the user's own track is called before anyone names it.
    ///
    /// A word rather than a letter, because it is not a guess. On a call the mic
    /// track is the user, and calling it "A" would invite the labelling UI to
    /// ask a question that has no doubt in it.
    ///
    /// A room recording never uses this label. There the microphone holds
    /// several people, none of them known in advance, so they arrive as letters
    /// like anybody else and the voice bank names the user if it has heard them
    /// before. See `decideRoom`.
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
        let hasSystemFile = fm.fileExists(atPath: recording.systemURL.path)
        let hasMic = fm.fileExists(atPath: recording.micURL.path)

        // Asked here rather than at the mic pass below, where it used to be,
        // because whether there is a second pass decides the shape of the
        // picture and the picture is drawn before the first pass starts. A
        // meeting nobody spoke into would otherwise show a lane for the user
        // that stays empty for ever, which reads as the job having stalled
        // halfway rather than as there being nothing to put in it.
        let micHasSpeech = hasMic && !Self.isSilent(recording.micURL)

        // How much of the system track carries anything, which nothing used to
        // ask. A meeting held in a room leaves it nearly empty: nothing is
        // playing, so the tap records an hour of an idle Mac.
        //
        // Two numbers off one measurement, because the two decisions it feeds
        // should be wrong in opposite directions. Transcribing a track that
        // holds a few seconds of something costs a pass that finds nothing;
        // skipping one costs whatever was said. So five seconds is enough to
        // look, and thirty is what it takes to say somebody was on the far end,
        // which is the claim that decides whether the microphone is one person
        // or a room. See `signalSeconds` for the measurement behind the shape.
        let systemSignal = hasSystemFile ? Self.signalSeconds(recording.systemURL) : 0
        let systemHasSpeech = systemSignal >= 5
        let somebodyRemote = systemSignal >= 30

        // An imported recording has neither track, only the mixdown the legacy
        // recorder produced. Treat that as the everyone-track: diarize it whole
        // and discover every speaker, including the user. There is deliberately
        // no shortcut labelling anybody "Me" here, because in a mixed track the
        // user is not distinguishable by which file they are in, and guessing
        // would be worse than asking.
        var everyone = recording.systemURL
        var everyoneHasSpeech = systemHasSpeech
        if !hasSystemFile, !hasMic, fm.fileExists(atPath: recording.mixURL.path) {
            everyone = recording.mixURL
            // `isSilent` reads raw floats past a WAV header and a mixdown is an
            // m4a, so it cannot be asked about this file. An import is a
            // mixdown of a meeting somebody kept, so assume speech and let the
            // diarizer be the one to say otherwise.
            everyoneHasSpeech = true
        }

        // Which side of the microphone the meeting is on. Everything the mic
        // pass does below turns on this one answer.
        let room = decideRoom(recording, somebodyRemote: somebodyRemote,
                              micHasSpeech: micHasSpeech)

        let tally = Tally(split: everyoneHasSpeech && micHasSpeech, report: progress)
        try await asr.load(choice) { tally.say($0) }

        var labelled: [LabelledSegment] = []
        var embeddings: [String: [Float]] = [:]
        var speech: [String: Double] = [:]
        var wordLevel = false
        var model = choice.repo
        /// Kept past the system pass, because a room recording needs to know
        /// when the far end was talking. See `bleedClusters`.
        var systemTurns: [SpeakerTurn] = []

        if everyoneHasSpeech {
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
            do {
                try await diarizer.load { tally.say($0) }
                let diarization = try await diarizer.run(everyone)
                // Tagged with the track, because the mic track below can now
                // produce a speaker 1 of its own and the two are not the same
                // person. Untangled by the single `Merge.relabel` after the
                // merge, which is also what makes the letters follow the order
                // people first speak across the whole meeting.
                systemTurns = Merge.namespaced(diarization.turns, "system")
                embeddings = Merge.namespaced(diarization.embeddings, "system")
                speech = Merge.namespaced(diarization.speech, "system")
            } catch {
                log("speakers not identified: \(error.localizedDescription)")
            }

            labelled += Merge.assign(transcript.segments, to: systemTurns,
                                     fallback: Merge.namespaced("?", "system"))
        }

        if micHasSpeech {
            // The mic is the user, unless it is the room. See `decideRoom`.
            tally.say(room ? "transcribing the room" : "transcribing you")
            let transcript = try await asr.transcribe(recording.micURL) { fraction in
                tally.update { $0.you = fraction }
            }
            wordLevel = wordLevel || transcript.hasWordTimings
            Self.reportCuts(transcript, track: room ? "room" : "you")

            var mic: DiarizationOutput?
            if room {
                tally.say("identifying the people in the room")
                do {
                    try await diarizer.load { tally.say($0) }
                    // No `expecting:` prior. How many people are around the
                    // table is exactly the question being asked, and it is the
                    // one number nothing here knows: the calendar counts
                    // invitations, not chairs. See .agents/notes/speakers.md on
                    // what a wrong prior does to a track.
                    //
                    // `room: true` is not decoration. One microphone across a
                    // table puts two people far closer together in embedding
                    // space than two people on separate calls, and at the
                    // threshold a system track wants they merge. Without it a
                    // two-person phone memo came back as one voice, which the
                    // branch below then labels `Me`. See `Diarizer.roomThreshold`.
                    let diarization = try await diarizer.run(recording.micURL,
                                                             room: true)
                    mic = DiarizationOutput(
                        turns: Merge.namespaced(diarization.turns, "room"),
                        embeddings: Merge.namespaced(diarization.embeddings, "room"),
                        speech: Merge.namespaced(diarization.speech, "room"))
                } catch {
                    log("the room was not separated: \(error.localizedDescription)")
                }
            }

            // One voice on the microphone is the user, however this recording
            // was read. That is the sentence that makes a generous room
            // inference safe: a solo recording and a call both land here, the
            // label is the same `Me` it has always been, and the difference is
            // that the clustering was looked at rather than assumed.
            // Counted over the turns rather than the embeddings, because a
            // cluster the model produced no embedding for is still a voice that
            // spoke, and reading the count off the bank would quietly file it
            // under the user.
            if var room = mic, Set(room.turns.map(\.label)).count > 1 {
                // Assigned against every cluster, including the bled ones, and
                // filtered afterwards. Dropping a cluster first would leave its
                // sentences to fall through to the nearest surviving turn, which
                // hands the far end's words to somebody in the room.
                var assigned = Merge.assign(transcript.segments, to: room.turns,
                                            fallback: Merge.namespaced("?", "room"))
                let bled = Self.bleedClusters(room, against: systemTurns)
                if !bled.isEmpty {
                    let before = assigned.count
                    assigned.removeAll { bled.contains($0.speaker) }
                    for label in bled {
                        room.embeddings[label] = nil
                        room.speech[label] = nil
                    }
                    log("\(bled.count) voice(s) and \(before - assigned.count) "
                        + "sentence(s) dropped from the microphone: the far end "
                        + "coming back in through the speakers")
                }
                log("\(Set(room.turns.map(\.label)).subtracting(bled).count) "
                    + "voice(s) in the room")

                labelled += assigned
                embeddings.merge(room.embeddings) { a, _ in a }
                speech.merge(room.speech) { a, _ in a }
            } else {
                // Said out loud, because this is the one failure with no face.
                // A room that clusters to a single voice is labelled `Me` and
                // is then indistinguishable on screen from an ordinary solo
                // memo, which is how a two-person meeting filed itself under
                // one name and nothing anywhere said so.
                if room, let mic {
                    let voices = Set(mic.turns.map(\.label)).count
                    log("\(recording.id): the room separated into \(voices) "
                        + "voice(s), so the whole recording is \(Self.userLabel)")
                }
                labelled += transcript.segments.map {
                    LabelledSegment(start: $0.start, end: $0.end,
                                    speaker: Self.userLabel, text: $0.text)
                }
                await printUser(recording, from: mic, into: &embeddings,
                                speech: &speech, tally: tally)
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

        // Before the letters are handed out, not after: a cluster too small to
        // be a person must never be given one, or the alphabet skips a letter
        // and the transcript still says three people were here. See
        // `Merge.foldCrumbs` for the measurement and for why this folds rather
        // than dropping, which is the opposite of what `bleedClusters` does.
        let folded = Merge.foldCrumbs(&labelled, embeddings: embeddings,
                                      keeping: [Self.userLabel])
        for (crumb, target) in folded {
            // Added, not remapped: `remap` overwrites on a collision and this
            // is a sum. The voiceprint is dropped rather than averaged in,
            // because a crumb is the evidence that made the model wrong once
            // already and the target's own print is built from minutes.
            speech[target, default: 0] += speech[crumb] ?? 0
            speech[crumb] = nil
            embeddings[crumb] = nil
        }
        if !folded.isEmpty {
            log("\(folded.count) voice(s) folded into the speaker they most "
                + "resemble: too little speech to be a person")
            trace("  folded: \(folded)")
        }

        // One alphabet for the whole meeting, handed out after the merge rather
        // than per track. Both tracks can now arrive holding a cluster called 1,
        // and letters given out per track would either collide or number the
        // room's speakers as though the far end had spoken first.
        //
        // `Me` is spared, because it is not a cluster the letters are hiding: it
        // is the one label in a transcript that is already an answer.
        let mapping = Merge.relabel(&labelled, keeping: [Self.userLabel])
        // Carry the voiceprints over to the letters the transcript uses,
        // otherwise the embeddings are filed under labels nothing displays.
        embeddings = Self.remap(embeddings, using: mapping)
        speech = Self.remap(speech, using: mapping)

        var (cleaned, fired) = Merge.clean(labelled)
        if !fired.isEmpty { trace("cleanup fired: \(fired)") }

        let rules = Self.applyDictionary(to: &cleaned)
        // The count stays on stderr unconditionally: the dictionary is the
        // user's own list rewriting their own meeting, and somebody who added
        // a rule this morning should be told it fired. The rule text is behind
        // LISTEN_DEBUG, because a GUI launch sends stderr to the unified log
        // and a correction like a person's name should not sit there in plain
        // text.
        if !rules.isEmpty {
            log("dictionary applied: \(rules.count) rule(s)")
            trace("  rules: \(rules)")
        }

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

    // MARK: - Which side the microphone is on

    /// Whether the microphone track holds a room rather than one person.
    ///
    /// **"The mic is the user" is a remote-call assumption, and a laptop on the
    /// table in a meeting room breaks it.** There the microphone carries
    /// everybody and the system track carries nobody, so labelling the whole
    /// track `Me` files an entire meeting of four people under one name, with
    /// nothing on screen suggesting anything went wrong.
    ///
    /// A person's answer wins where there is one and is never re-decided.
    /// Everything else is inferred, from two facts the folder already holds:
    /// nothing was on a call (`app_bundle_id`), and nothing sustained came out
    /// of the speakers (`somebodyRemote`). Together those mean nobody was
    /// remote, and a microphone with nobody remote is carrying the room.
    ///
    /// Inferred here rather than at capture, where it would be cheaper to ask,
    /// because neither fact is settled while the recording runs: the call app
    /// can appear minutes in (`Capture.noteApp`), and how much a track holds is
    /// not known until it has stopped.
    ///
    /// **A solo recording infers "room" too, and that is deliberate.** Nothing
    /// distinguishes one person at a desk from four at a table before the
    /// microphone has been clustered, so the answer here is only "cluster it
    /// and see". The mic pass treats one cluster as the user, which is exactly
    /// what this used to assume without looking, so the inference being
    /// generous costs a diarizer pass and never a wrong name.
    ///
    /// **It cannot call the hybrid meeting**, some people in the room and some
    /// on the far end, because the system track holds speech either way. That
    /// case is what the override is for, and it is the one the user has to know
    /// about; every other case decides itself.
    private func decideRoom(_ recording: Recording, somebodyRemote: Bool,
                            micHasSpeech: Bool) -> Bool {
        if recording.metadata.room_auto != true, let chosen = recording.metadata.room {
            return chosen
        }
        // `appBundleID` rather than `metadata.app_bundle_id`, which is the trap
        // recorded against that property: a recording made before the field
        // existed keeps the identifier in `source`, and reading the field
        // directly says "nobody was on a call" for the older half of the
        // library. Every one of those would have been a candidate for being
        // re-read as a room.
        let inferred = micHasSpeech && recording.appBundleID == nil && !somebodyRemote

        // Written down rather than re-derived by every reader, so the menu can
        // show what happened and `listen show` can print it. Re-read before
        // saving, for the reason `Capture.noteApp` re-reads: a recording can be
        // renamed and tagged while the queue is working on it, and writing back
        // the copy the job started with would undo that.
        if var fresh = Recording.load(recording.folder) {
            fresh.metadata.room = inferred
            fresh.metadata.room_auto = true
            try? fresh.save()
        }
        if inferred { log("\(recording.id): treating the microphone as a room") }
        return inferred
    }

    /// Microphone clusters that are the far end coming back in through the
    /// speakers.
    ///
    /// There is no echo cancellation on the microphone track: `MicRecorder`
    /// taps the input node raw. So in a hybrid meeting played out loud, the far
    /// end lands on both tracks. On the system track it is a clean copy; on the
    /// microphone it is a second cluster holding the same sentences, and without
    /// this one remote person would attend their own meeting twice.
    ///
    /// **A cluster, not a sentence**, because that is what separates the two
    /// cases. A voice that speaks only while the system track is speaking is the
    /// system track; somebody in the room who talks over the far end does it
    /// occasionally rather than always. Dropping by overlap per sentence would
    /// instead delete exactly the interruptions, which are the sentences a
    /// reader most wants.
    ///
    /// 0.8 is chosen rather than measured, and it is deliberately not 1.0
    /// because the two diarizations do not agree on boundaries to the
    /// millisecond. Measuring it needs a hybrid meeting recorded on speakers,
    /// which is why the count is logged on every run rather than traced.
    private static func bleedClusters(_ mic: DiarizationOutput,
                                      against system: [SpeakerTurn]) -> Set<String> {
        guard !system.isEmpty else { return [] }
        var total: [String: Double] = [:]
        var covered: [String: Double] = [:]
        for turn in mic.turns {
            let length = turn.end - turn.start
            guard length > 0 else { continue }
            total[turn.label, default: 0] += length
            // Clamped per turn, because system turns can overlap each other and
            // a sum of overlaps can otherwise exceed the turn it is measuring.
            var inside: Double = 0
            for other in system {
                inside += max(0, min(turn.end, other.end) - max(turn.start, other.start))
            }
            covered[turn.label, default: 0] += min(inside, length)
        }
        return Set(total.compactMap { label, seconds in
            seconds > 0 && (covered[label] ?? 0) / seconds >= 0.8 ? label : nil
        })
    }

    /// File one voiceprint for the user, from the microphone track.
    ///
    /// **Nothing used to.** The mic track was never diarized, so `Me` was the
    /// one label in the library with no voice behind it: the bank could
    /// recognise every person in a meeting except the person it belongs to. A
    /// room recording needs precisely that print, because a room arrives as
    /// letters and something has to say which letter is you, and this is where
    /// it comes from. Two or three ordinary calls and the bank knows.
    ///
    /// `expecting: 1` is the case the prior is genuinely known for (see
    /// `.agents/notes/speakers.md`), and it is what stops an hour of one person
    /// being split into two voices. It costs one diarizer pass over the mic
    /// track, which the system pass measured at about 7 seconds for an hour.
    ///
    /// `from` is the free clustering a room recording already paid for, reused
    /// rather than re-run when it came back holding one voice. The prior would
    /// have asked for exactly what it found.
    ///
    /// A room misread as a call writes a print averaged over several people,
    /// which is the one way this puts something wrong into the bank. Correcting
    /// the recording corrects the bank in the same gesture: a re-run rewrites
    /// `embeddings.json` whole, so the mixed print is replaced by one per
    /// person rather than left behind.
    private func printUser(_ recording: Recording, from clustered: DiarizationOutput?,
                           into embeddings: inout [String: [Float]],
                           speech: inout [String: Double], tally: Tally) async {
        do {
            var mine = clustered
            if mine == nil {
                try await diarizer.load { tally.say($0) }
                mine = try await diarizer.run(recording.micURL, expecting: 1)
            }
            guard let mine else { return }
            // The longest cluster rather than the first. The prior asks for one
            // and the diarizer has always given one, but "whichever the
            // dictionary happened to yield" is not a rule, and what this picks
            // is the user's own identity.
            guard let label = mine.speech.max(by: { $0.value < $1.value })?.key
                    ?? mine.embeddings.keys.first,
                  let vector = mine.embeddings[label], !vector.isEmpty else { return }
            embeddings[Self.userLabel] = vector
            speech[Self.userLabel] = mine.speech[label] ?? 0
        } catch {
            log("no voiceprint for the microphone track: \(error.localizedDescription)")
        }
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
        // Same fold as the two-track path, and before the letters for the same
        // reason. Nothing here is namespaced, so every label shares one track
        // and a crumb is compared against the whole file.
        Merge.foldCrumbs(&assigned, embeddings: diarization.embeddings)
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

    /// Seconds of a track that carry signal, counted in one-second windows.
    ///
    /// **`isSilent` is a peak test and cannot answer this question.** Measured
    /// on the 47-minute meeting this was written for, a laptop on a table with
    /// three people around it:
    ///
    ///     system.wav  peak 0.364  rms 0.00094     7 of 2828 seconds over 0.01
    ///     mic.wav     peak 1.376  rms 0.01199  2777 of 2828 seconds over 0.01
    ///
    /// The system track is an idle Mac with a notification chime in it. A peak
    /// test called it "not silent", which read the meeting as a call with
    /// somebody on the far end, and being wrong about that is what decides
    /// whether the microphone is one person or four.
    ///
    /// A window rather than a sample is the whole point: what separates a chime
    /// from a conversation is not how loud it got but how much of the hour it
    /// occupied. 0.01 sits above the idle track's noise and below the
    /// microphone's continuous speech, with three orders of magnitude of RMS
    /// between them to place it in.
    ///
    /// Reads the file directly for the reason `isSilent` does: the writer's
    /// format is known, so this is a scan of floats.
    static func signalSeconds(_ url: URL, floor: Float = 0.01) -> Double {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44), header.count == 44
        else { return 0 }
        // Offset 24 of a canonical header, which is what `WAVWriter` writes.
        let rate = header.withUnsafeBytes { raw in
            raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self)
        }
        let window = Int(rate > 0 ? rate : UInt32(SAMPLE_RATE))
        guard let data = try? handle.readToEnd(), data.count >= 4 else { return 0 }

        var seconds = 0
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            var start = 0
            while start < floats.count {
                let end = min(start + window, floats.count)
                // Every tenth sample. A second of speech is not carried by one
                // sample in ten, and this is read over a two-track hour.
                var peak: Float = 0
                for i in stride(from: start, to: end, by: 10) {
                    peak = max(peak, abs(floats[i]))
                }
                if peak > floor { seconds += 1 }
                start = end
            }
        }
        return Double(seconds)
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
