import Foundation
import NaturalLanguage

/// Which language a meeting was held in, and which model that means.
///
/// The problem this exists for is the one `.agents/notes/asr.md` calls the
/// worst failure in the app: an English-only decoder handed Dutch audio writes
/// fluent, confident English, nothing errors, and the only evidence is that a
/// human reads it. Two questions follow from that, and they have different
/// answers.
///
/// **"What language is this transcript in?" is only answerable for a transcript
/// a multilingual model produced.** Measured over three real Dutch calls: the
/// v2 transcript of Dutch audio identifies as English at 0.994 to 1.000
/// confidence, because every word in it *is* English. Language identification
/// over v2 output is therefore not a weak signal, it is a confidently wrong
/// one, and nothing here may run it on a transcript v2 made.
///
/// **"Did the English-only model just mishear a whole meeting?" is answerable,
/// and not from the words.** It is answerable from how few of them there are.
/// See `looksMisheard`.
enum SpokenLanguage {

    // MARK: - Reading a language off a transcript

    /// Whether a transcript this model produced can be asked what language it
    /// is in.
    ///
    /// v2 cannot be wrong about the language in a way that means anything: it
    /// has one, so its output is English whatever went in. Only a model that
    /// could have chosen otherwise carries the information.
    static func canReport(_ repo: String) -> Bool {
        ModelChoice.forRepo(repo)?.isMultilingual ?? false
    }

    /// How many words it takes before an identification is worth having.
    ///
    /// `NLLanguageRecognizer` will answer for three words and the answer is a
    /// coin toss. Every caller here has a whole meeting to hand, so the floor
    /// costs nothing and stops a track holding one "okay" from filing somebody
    /// under Danish.
    static let minimumWords = 40

    /// The language of a piece of transcript, or nil when nothing can say.
    static func identify(_ text: String) -> String? {
        guard text.split(separator: " ").count >= minimumWords else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// The language this recording was held in, as far as anything can tell.
    ///
    /// Nil for a recording transcribed by an English-only model, which is not
    /// the same as "English": it is "nobody knows", and the difference is the
    /// whole point. A caller that treats nil as English rediscovers the bug.
    static func of(_ recording: Recording) -> String? {
        guard let transcript = recording.storedTranscript,
              canReport(transcript.model) else { return nil }
        if let stored = transcript.language { return stored }
        return identify(transcript.segments.map(\.text).joined(separator: " "))
    }

    // MARK: - Catching the English-only model handed another language

    /// Words per second of audio that carried signal, below which an
    /// English-only model was probably handed a language it cannot read.
    ///
    /// **Per second of audio, not per second of transcript, and the difference
    /// is the whole measurement.** Scored against the span of the segments it
    /// wrote, this separated Dutch from English on the six calls it was first
    /// tried on and then flagged two English voice memos out of the real
    /// library. Parakeet's segments run straight through a thinking pause, so a
    /// memo where somebody stops to think is mostly silence inside its own
    /// segments, and its rate collapses for a reason that has nothing to do
    /// with language. Every transcript-only statistic tried next had the same
    /// fault or worse: type-token ratio ran backwards, because a decoder
    /// guessing at Dutch produces *more* varied English than a person giving a
    /// briefing, not less.
    ///
    /// `Pipeline.signal` already counts the seconds of a track that carry
    /// anything, for a different question, and it is the right denominator:
    /// silence stops counting against the model, and what is left is how much
    /// the decoder wrote for the speech it was actually given.
    ///
    /// **Calibrated against `Pipeline.signal` itself, not a proxy for it.** The
    /// first number here was measured with ffmpeg's `silencedetect` and was
    /// wrong for this code, because `signal` counts a second as carrying if any
    /// of it peaks over 0.01 and so calls far more of a track voiced. Both
    /// edges below are the real implementation's own output:
    ///
    /// - Five Dutch calls, re-read with v2 by the real pipeline: 0.37, 0.39,
    ///   0.43, 0.46, 0.47. All five flagged.
    /// - Forty-one English v2 recordings across the whole library: 1.11 to
    ///   5.24. The nearest is "Call with Nadia" at 1.11, and the two voice
    ///   memos that the segment-span version wrongly flagged sit at 2.44 and
    ///   2.92.
    ///
    /// 0.79 is the midpoint of that band: 1.7x above the thickest Dutch call
    /// and 1.4x below the thinnest English one. `verify_language.sh` is the
    /// measurement as an assertion.
    ///
    /// The mechanism is why this separates rather than an accident of one
    /// library. Handed phonemes it has no words for, the decoder does not
    /// invent at the rate it transcribes: it emits sparse, short, confident
    /// fragments. The transcript does not read as broken, which is what makes
    /// the failure invisible, but it is thin, and thin is measurable.
    ///
    /// **Dutch is the only language behind this number**, which is the honest
    /// limit of it. The mechanism should hold for anything v2 cannot read; the
    /// threshold is where the evidence there is puts it.
    static let wordsPerCarryingSecond =
        Double(ProcessInfo.processInfo.environment["LISTEN_THIN_FLOOR"] ?? "") ?? 0.79

    /// How much carrying audio it takes before the rate means anything.
    ///
    /// A rate over ten seconds is noise. A minute is short next to any real
    /// meeting and long enough that one pause cannot dominate. Below this the
    /// answer is "no opinion", never "fine", for the same reason `of` returns
    /// nil rather than English.
    static let minimumCarryingSeconds = 60.0

    /// How thin this recording's transcript is, or nil when nothing can say.
    ///
    /// Nil rather than a number whenever the question cannot be asked: a
    /// multilingual model produced it, the audio is not on this Mac, or there
    /// is too little of it. Every one of those is "no opinion", and a caller
    /// that reads nil as "fine" is making a claim this cannot support.
    static func density(of recording: Recording) -> Double? {
        guard let transcript = recording.storedTranscript,
              !canReport(transcript.model) else { return nil }
        // Both tracks, because the transcript is the merge of both and a rate
        // over one of them would be measuring half the words against all the
        // audio, or the reverse.
        let carrying = recording.tracks.reduce(0.0) { $0 + Pipeline.signal($1).carrying }
        guard carrying >= minimumCarryingSeconds else { return nil }
        let words = transcript.segments.reduce(0) { $0 + $1.text.split(separator: " ").count }
        return Double(words) / carrying
    }

    /// Whether the wrong model probably read this meeting.
    ///
    /// Only ever true of a transcript an English-only model produced. A
    /// multilingual model that got the language wrong is a different failure
    /// and this says nothing about it.
    static func looksMisheard(_ recording: Recording) -> Bool {
        guard let density = density(of: recording) else { return false }
        return density < wordsPerCarryingSecond
    }

    // MARK: - Reading it again with a model that could have read it

    /// The model that should read this recording again, when the one that just
    /// finished probably could not read it at all.
    ///
    /// This is the whole of "choose the model automatically", and it is a
    /// second pass rather than a better first guess on purpose. Everything that
    /// could inform the first guess is either absent or unreliable at the
    /// moment it would be needed: the calendar has no event for a WhatsApp
    /// call, a voiceprint only exists for somebody already recorded and named,
    /// and the audio itself cannot be language-identified without decoding it.
    /// The transcript can, so the cheapest correct answer is to decode once,
    /// notice, and decode again. Measured on this library: about 20 seconds
    /// wasted on an hour-long call, against a transcript that was previously
    /// wrong in a way nobody could see.
    ///
    /// **It never downloads anything.** A model that is not on disk is not an
    /// option here, however sure this is: starting a 2.5 GB transfer inside a
    /// job nobody is watching is the one thing that would make an automatic
    /// choice worse than no choice. Setup deliberately fetches one model, so
    /// the common case for a new user is that this returns nil and the screen
    /// offers the download instead, where the size can be named before the
    /// press.
    ///
    /// Nil unless every one of these holds:
    ///
    /// - an English-only model produced the transcript, so `looksMisheard`
    ///   means something,
    /// - the transcript is thin against the audio,
    /// - a multilingual model is already on disk,
    /// - nobody has corrected this transcript by hand, because a re-run
    ///   discards every one of those edits.
    ///
    /// It cannot loop: the pass it asks for is by a multilingual model, and
    /// `looksMisheard` is false for anything one of those wrote.
    static func rescue(for recording: Recording) -> ModelChoice? {
        guard ProcessInfo.processInfo.environment["LISTEN_NO_RESCUE"] == nil,
              looksMisheard(recording),
              !recording.hasHumanEdits,
              let multilingual = ModelChoice.all.first(where: { $0.isMultilingual }),
              multilingual.isDownloaded else { return nil }
        return multilingual
    }

    /// The model that could have read this meeting and is not on this Mac.
    ///
    /// The other half of `rescue`, and the one that covers most people. Setup
    /// downloads a single model, so the ordinary new user has only the
    /// English-only one, and for them `rescue` always returns nil: it refuses
    /// to start a 2.5 GB transfer inside a job nobody is watching. That
    /// refusal is right and it used to end the story, which meant the app
    /// could tell the transcript was wrong and said nothing at all.
    ///
    /// This is what it says instead. Same evidence as `rescue`, opposite
    /// answer about the disk, and the offer it feeds names the size before the
    /// press, where somebody can decide.
    ///
    /// Deliberately not gated on `hasHumanEdits`. A person who has started
    /// correcting a transcript that was never in English has been fixing a
    /// translation by hand, and telling them a model exists that would have
    /// read it properly is worth more than protecting the edits: the offer is
    /// a button, not an action, and Transcribe Again still warns before it
    /// discards anything.
    static func missingModel(for recording: Recording) -> ModelChoice? {
        guard looksMisheard(recording),
              let multilingual = ModelChoice.all.first(where: { $0.isMultilingual }),
              !multilingual.isDownloaded else { return nil }
        return multilingual
    }

    // MARK: - What a person usually speaks

    /// Every language this person has been recorded speaking, and how often.
    ///
    /// Derived, never stored, for the reason `People` gives for having no
    /// index: the transcripts are the truth, and a language cached beside a
    /// name is a thing that can be wrong. Only recordings a multilingual model
    /// read can vote, so this is empty until somebody has re-run one meeting
    /// with v3, which is exactly the correction the banner offers.
    static func languages(of person: String,
                          in library: [Recording] = Recording.all()) -> [String: Int] {
        var counts: [String: Int] = [:]
        for recording in library where recording.speakers.contains(person) {
            guard let language = of(recording) else { continue }
            counts[language, default: 0] += 1
        }
        return counts
    }

    /// The model these people's history argues for, and the sentence that says
    /// why, or nil when nothing in the library has an opinion.
    ///
    /// **Positive evidence of another language is the only thing that moves
    /// this**, and the asymmetry is measured rather than cautious. Running v3
    /// on an English meeting costs 39% of the proper nouns in it, measured
    /// over six of this library's own English meetings: Claude becomes Cloud,
    /// WhatsApp becomes "what's up", Kinsight becomes "kin site". Running v2
    /// on a Dutch meeting costs the meeting. So v2 stays the default and v3 is
    /// reached for only when somebody in the room has been recorded speaking
    /// something else.
    ///
    /// `Me` is excluded. The user speaks both, by definition of the problem:
    /// they are in every recording, so counting them would put every meeting
    /// in whichever language they last held one in.
    static func model(forPeople people: [String],
                      in library: [Recording] = Recording.all())
    -> (choice: ModelChoice, because: String)? {
        guard let multilingual = ModelChoice.all.first(where: \.isMultilingual) else { return nil }
        for person in people where person != Pipeline.userLabel
                                  && !VoiceBank.isPlaceholder(person) {
            let seen = languages(of: person, in: library)
            let foreign = seen.filter { $0.key != "en" }
            guard let top = foreign.max(by: { $0.value < $1.value }) else { continue }
            // One recording is enough. It is not a guess: somebody re-ran that
            // meeting with a model that reads 25 languages and it came back in
            // one of the other 24, which is a fact about a person rather than
            // a score over a population.
            return (multilingual, "\(name(of: top.key)), from \(SpeakerName.display(person))")
        }
        return nil
    }

    /// A language code as a person would say it, falling back to the code.
    static func name(of code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }
}
