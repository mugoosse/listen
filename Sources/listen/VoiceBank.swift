import Foundation
import ListenKit

/// Cross-recording speaker recognition on the Mac, over the sidecar files.
///
/// **The arithmetic moved and this did not.** `VoiceBankCore` in ListenKit now
/// holds the thresholds, the cosine, the centroid and the ranking, because the
/// phone reads the same bank through the same CloudKit zone and two copies of
/// `certainThreshold` is how two devices come to disagree about who is
/// speaking. What is left here is everything that writes: naming a speaker goes
/// through `TranscriptEditor` so the transcript, the turns and the bank move
/// together, and none of that exists on a phone.
///
/// **There is no database.** The set of `embeddings.json` files next to the
/// recordings *is* the voice bank, which is what makes deleting a recording in
/// Finder safe: it cannot strand an entry, because the entry lived in the
/// folder that was deleted. Preserve this property; a cache would reintroduce
/// exactly the inconsistency it removes.
enum VoiceBank {

    // MARK: - Thresholds

    /// Measured with `listen calibrate` on real recordings, and documented
    /// where they are defined. Re-exported rather than re-declared: every call
    /// site in this app reads `VoiceBank.certainThreshold`, and a second
    /// literal is the thing worth preventing.
    static let matchThreshold = VoiceBankCore.matchThreshold
    static let strongThreshold = VoiceBankCore.strongThreshold
    static let certainThreshold = VoiceBankCore.certainThreshold
    static let marginThreshold = VoiceBankCore.marginThreshold

    // MARK: - Reading

    /// Every named voiceprint in the library that counts as evidence.
    ///
    /// Placeholders are excluded: "A" in one meeting has nothing to do with
    /// "A" in another, and suggesting one for the other would be worse than
    /// suggesting nothing.
    ///
    /// **Automatically applied names are excluded too, and that is the rule
    /// that keeps this feature from compounding its own mistakes.** A name the
    /// bank chose is not somebody saying who this is, so letting it back in as
    /// evidence means one wrong assignment recruits the next, and the next, with
    /// each round more confident than the last. This library has already shown
    /// what a single wrong identity does to the bank from a *human* assertion:
    /// different-person pairs went from +0.371 to +0.871 and `listen calibrate`
    /// lost its separation entirely. The bank only ever grows from a person.
    static func named(excluding recording: Recording? = nil) -> [(String, Voiceprint)] {
        var out: [(String, Voiceprint)] = []
        for r in Recording.all() where r.id != recording?.id {
            for (label, print) in r.voiceprints
            where !isPlaceholder(label) && print.auto != true {
                out.append((label, print))
            }
        }
        return out
    }

    /// Rank the named voices in the library against one speaker here.
    ///
    /// The scoring is `VoiceBankCore.rank`, shared with the phone. What this
    /// adds is the Mac's idea of where the candidates come from: every other
    /// recording's `embeddings.json`, filtered to what counts as evidence.
    static func suggestions(for speaker: String, in recording: Recording) -> [VoiceMatch] {
        guard let mine = recording.voiceprints[speaker], mine.canQuery else { return [] }
        var prints: [String: [[Float]]] = [:]
        for other in Recording.all() where other.id != recording.id {
            VoiceBankCore.addEvidence(from: other.voiceprints, to: &prints)
        }
        return VoiceBankCore.rank(mine.embedding, against: prints)
    }

    /// One direction standing for one person.
    static func centroid(of embeddings: [[Float]]) -> [Float] {
        VoiceBankCore.centroid(of: embeddings)
    }

    /// A vector scaled to length one, so a dot product is a cosine.
    static func unit(_ v: [Float]) -> [Float] { VoiceBankCore.unit(v) }

    /// Cosine similarity. Both vectors come from the same model, so no
    /// normalisation beyond this is needed.
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        VoiceBankCore.cosine(a, b)
    }

    /// True for a label the pipeline invented rather than a person's name.
    static func isPlaceholder(_ label: String) -> Bool {
        VoiceBankCore.isPlaceholder(label)
    }

    static func currentName(of speaker: String, in recording: Recording) -> String? {
        isPlaceholder(speaker) ? nil : speaker
    }

    // MARK: - Naming without being asked

    /// Name the speakers the bank is sure about, and report what it did.
    ///
    /// Runs once, from `Recording.markTranscribed`, so it happens before anybody
    /// has been asked anything and covers both the queue and `listen
    /// transcribe` through the one call they share.
    ///
    /// Four things hold this together, and each is a way it could have gone
    /// wrong:
    ///
    /// 1. **Both gates, not one.** `autoAssignable` wants the level *and* the
    ///    margin. See `marginThreshold`.
    /// 2. **A name is claimed once.** Two placeholders in one recording cannot
    ///    both become Marcia. The second is left for a human, because two
    ///    speakers resolving to one person is either a diarizer split or a wrong
    ///    match, and neither is something to decide silently.
    /// 3. **It goes through `TranscriptEditor`**, the same write the window and
    ///    `listen label` use, so there is no second implementation of renaming a
    ///    speaker to disagree with the first.
    /// 4. **It is recorded as automatic**, in `metadata.auto_named` and on the
    ///    voiceprint, so it is visible, reversible, and never becomes evidence.
    @discardableResult
    static func autoAssign(in recording: Recording) -> [(speaker: String, name: String)] {
        var current = recording
        var applied: [(speaker: String, name: String)] = []
        var claimed = Set(recording.speakers)

        // Sorted, so the outcome does not depend on dictionary ordering. Two
        // runs over the same recording have to agree, or the same audio names
        // different people on two Macs.
        for speaker in recording.speakers.filter(isPlaceholder).sorted() {
            guard let top = suggestions(for: speaker, in: current).first,
                  top.autoAssignable, !claimed.contains(top.name) else { continue }
            guard TranscriptEditor.apply(.rename(speaker, to: top.name), to: current,
                                         backup: false) else { continue }
            claimed.insert(top.name)
            applied.append((speaker, top.name))
            markAuto(top.name, in: current)
            // Re-read: the edit rewrote the transcript and the sidecar, and the
            // next speaker is scored against what is on disk now.
            current = Recording.find(recording.id) ?? current
        }

        guard !applied.isEmpty else { return [] }
        var updated = current
        updated.metadata.auto_named =
            (updated.metadata.auto_named ?? []) + applied.map(\.name)
        try? updated.save()
        // The event stays on stderr unconditionally: this is the app writing
        // into an archive nobody may open for a month, and that has to be
        // visible. The name itself is behind `LISTEN_DEBUG`, because a GUI
        // launch sends stderr to the unified log, where a person's name would
        // sit in plain text for any diagnostic report to sweep up.
        for a in applied {
            log("named \(SpeakerName.display(a.speaker)) by voice "
                + "in \(recording.id)")
            trace("  as \(a.name)")
        }
        return applied
    }

    /// Mark a voiceprint as one the bank chose rather than a person.
    private static func markAuto(_ name: String, in recording: Recording) {
        var bank = recording.voiceprints
        guard var print = bank[name] else { return }
        print.auto = true
        bank[name] = print
        write(bank, to: recording)
    }

    // MARK: - Repairing a bank that lost track of a name

    /// A voiceprint sitting under a label the transcript no longer uses, and
    /// the person in that transcript who has no print at all.
    struct Repair {
        var recordingID: String
        var title: String
        /// The name in the transcript, which has nothing in the bank.
        var name: String
        /// The key holding the print, which is in no transcript.
        var key: String
        /// Cosine against that person's centroid built from other recordings,
        /// or nil when they have no print anywhere else to check against.
        var similarity: Float?
        var why: String
    }

    /// Every voiceprint this library has lost the name of.
    ///
    /// **The damage is invisible and it degrades the feature people notice.**
    /// A person named in a transcript whose print is filed under `A` is absent
    /// from the bank, so they are never suggested in any later recording. That
    /// does not read as a bug: it reads as the voice matching being mediocre,
    /// which is not something anybody reports. Measured on a real 60-recording
    /// library: 27 recordings affected and 10 people missing entirely.
    ///
    /// Two shapes, both conservative, and a third case deliberately left alone.
    ///
    /// 1. **A longer name form.** The transcript says `Ann` and the bank says
    ///    `Ann Jacobs`, which is a person auto-named from a contact and then
    ///    shortened by hand. One name is a prefix of the other, so there is
    ///    nothing to guess.
    /// 2. **A single leftover cluster.** Exactly one named speaker with no
    ///    print and exactly one orphan key. Verified against the person's own
    ///    centroid from other recordings when they have one, and refused below
    ///    `matchThreshold` however alone the candidate is: a count of one is
    ///    not evidence, and re-filing somebody else's voice under a name is
    ///    worse than leaving the name without a voice.
    ///
    /// Anything with more than one candidate on either side is skipped. The
    /// mapping from cluster to person is genuinely gone there, and a guess
    /// would poison the bank in the direction that is hardest to notice.
    static func repairs(in library: [Recording] = Recording.all()) -> [Repair] {
        var out: [Repair] = []
        for recording in library {
            let bank = recording.voiceprints
            guard !bank.isEmpty else { continue }
            let speakers = Set(recording.speakers)

            // **`Me` is an orphan like any other key, and excluding it hid the
            // one mislabel this function exists to find.** The exclusion was
            // there because `printUser` writes a `Me` print from the microphone
            // track whether or not the transcript ends up with a `Me` in it, so
            // the shape looked routine. Measured over this library it is not:
            // 2 recordings of 76 have a `Me` print and no `Me` speaker, one is
            // the known Nick mislabel, and the other has nothing unbanked so it
            // proposes no repair either way. What the exclusion cost was the
            // whole shape it was written to catch, a voiceprint sitting under a
            // name the transcript does not use.
            //
            // A namespaced key belongs to a track rather than a person
            // (`Merge.namespaced`), and a cluster the merge dropped is not a
            // name anybody lost.
            let orphans = bank.keys.filter {
                !speakers.contains($0) && !$0.contains(":")
            }
            let unbanked = speakers.filter {
                !isPlaceholder($0) && $0 != Pipeline.userLabel && bank[$0] == nil
            }
            guard !orphans.isEmpty, !unbanked.isEmpty else { continue }

            for name in unbanked.sorted() {
                // Shape 1: the same person under a fuller or shorter name.
                let byName = orphans.filter {
                    $0.hasPrefix(name + " ") || name.hasPrefix($0 + " ")
                }
                var key: String?
                var why = ""
                if byName.count == 1 {
                    key = byName[0]
                    why = "the same name, written in full"
                } else if unbanked.count == 1 && orphans.count == 1 {
                    key = orphans[0]
                    why = "the only voice in this recording nobody is named for"
                }
                guard let key, let print = bank[key] else { continue }

                // Checked against the rest of the library wherever that is
                // possible. `centroid` pools every print filed under the name,
                // so this asks "does the voice in this key sound like the
                // person the transcript says was here".
                var score: Float?
                let elsewhere = named(excluding: recording)
                    .filter { $0.0 == name }
                    .map { unit($0.1.embedding) }
                if !elsewhere.isEmpty {
                    score = cosine(print.embedding, centroid(of: elsewhere))
                    guard let s = score, s >= matchThreshold else { continue }
                }
                // Everything else may be proposed on shape alone, because a key
                // no transcript uses is already an anomaly. `Me` may not: it is
                // the one label this pipeline writes without a transcript
                // asking it to, so moving one has to be corroborated by the
                // voice rather than by counting.
                if key == Pipeline.userLabel, score == nil { continue }
                out.append(Repair(recordingID: recording.id,
                                  title: recording.displayTitle,
                                  name: name, key: key, similarity: score, why: why))
            }
        }
        out.append(contentsOf: misfiled(in: library))
        return out
    }

    /// Prints filed under a name whose voice they are not.
    ///
    /// **A different shape from the orphan search above, and the reason it
    /// exists is that the orphan search cannot see a swap.** That one pairs a
    /// key no transcript uses with a name no key holds, so it needs a gap to
    /// aim at. When two prints in one recording are simply the wrong way round
    /// there is no gap: every name is spoken for, and the bank is confidently,
    /// silently wrong. Measured on `2026-08-26-140435-53C7`, where the print
    /// filed as `Me` scored +0.880 against Nick and +0.364 against the user,
    /// while the one filed `B` scored +0.849 against the user. Both are over
    /// five minutes of speech, so this is not a short-print artefact.
    ///
    /// Four things keep it from deciding anything on a guess:
    ///
    /// 1. **Both gates**, as everywhere else: `certainThreshold` on the level
    ///    and `marginThreshold` clear of the runner-up.
    /// 2. **A print that already matches its own label is left alone**, even if
    ///    something else scores higher. Being filed correctly is not a defect.
    /// 3. **The whole recording is dropped unless the moves form a
    ///    permutation.** Two keys wanting one name, or a name taken by a print
    ///    that is staying put, is exactly the ambiguity a person should settle.
    /// 4. **Ordered so each target is free when its turn comes**, because
    ///    `apply` refuses to overwrite a name that still holds a print. A pure
    ///    two-cycle has no free start and is left for a person, deliberately:
    ///    the one-at-a-time write has nowhere to park the first print.
    private static func misfiled(in library: [Recording]) -> [Repair] {
        var out: [Repair] = []
        for recording in library {
            let bank = recording.voiceprints
            guard bank.count > 1 else { continue }
            let names = Set(recording.speakers.filter { !isPlaceholder($0) })
            guard names.count > 1 else { continue }

            // Centroids on the same terms the bank matches on: evidence only,
            // and never this recording's own prints.
            var prints: [String: [[Float]]] = [:]
            for other in library where other.id != recording.id {
                VoiceBankCore.addEvidence(from: other.voiceprints, to: &prints)
            }
            let cents = prints.filter { names.contains($0.key) }
                .mapValues { centroid(of: $0) }
            guard cents.count > 1 else { continue }

            var moves: [(key: String, name: String, score: Float)] = []
            var settled = false
            for (key, print) in bank {
                let ranked = cents
                    .map { (name: $0.key, score: cosine(print.embedding, $0.value)) }
                    .sorted { $0.score > $1.score }
                guard let best = ranked.first, ranked.count > 1 else { continue }
                let rival = ranked[1].score
                guard best.score >= certainThreshold,
                      best.score - rival >= marginThreshold else { continue }
                if best.name == key { continue }
                // Filed correctly enough is filed correctly.
                if let own = ranked.first(where: { $0.name == key })?.score,
                   own >= matchThreshold { continue }
                moves.append((key, best.name, best.score))
            }
            guard !moves.isEmpty else { continue }
            guard Set(moves.map(\.name)).count == moves.count else { continue }
            let leaving = Set(moves.map(\.key))
            guard moves.allSatisfy({ bank[$0.name] == nil || leaving.contains($0.name) })
            else { continue }

            // Vacate before filling. A move whose target holds no print may go
            // at once; one whose target is occupied waits for that print to
            // leave.
            var free = Set(moves.map(\.name).filter { bank[$0] == nil })
            var pending = moves
            var ordered: [(key: String, name: String, score: Float)] = []
            while !pending.isEmpty {
                guard let i = pending.firstIndex(where: { free.contains($0.name) })
                else { settled = true; break }
                let move = pending.remove(at: i)
                free.insert(move.key)
                ordered.append(move)
            }
            // A cycle with no free start. Left whole rather than half applied.
            if settled { continue }

            for move in ordered {
                out.append(Repair(
                    recordingID: recording.id, title: recording.displayTitle,
                    name: move.name, key: move.key, similarity: move.score,
                    why: "this voice is \(SpeakerName.display(move.name))'s, "
                        + "and it is filed as \(SpeakerName.display(move.key))"))
            }
        }
        return out
    }

    /// Move one lost print back under the name the transcript uses.
    ///
    /// Through `rename`, so it inherits the collision rule and the clearing of
    /// the `auto` flag rather than writing a second copy of either.
    @discardableResult
    static func apply(_ repair: Repair) -> Bool {
        guard let recording = Recording.find(repair.recordingID),
              recording.voiceprints[repair.key] != nil,
              recording.voiceprints[repair.name] == nil else { return false }
        rename(repair.key, to: repair.name, in: recording)
        return Recording.find(repair.recordingID)?.voiceprints[repair.name] != nil
    }

    // MARK: - Writing

    /// Move a voiceprint to its new name, keeping the bank aligned with the
    /// transcript. Without this the embedding stays filed under "B" while the
    /// transcript says "Anna", and the next recording gets no suggestion.
    static func rename(_ speaker: String, to name: String, in recording: Recording) {
        var bank = recording.voiceprints
        guard var moving = bank.removeValue(forKey: speaker) else {
            // **Said out loud, because this branch is how a voice goes missing
            // without anybody noticing.** There is nothing wrong with it: a
            // cluster the diarizer produced no embedding for has no print to
            // move, and the rename of the transcript still stands. What is
            // wrong is that it is indistinguishable from a rename that carried
            // the print, and the result is a person who is named in the
            // transcript and absent from the bank, so they are never suggested
            // again in any later recording.
            //
            // Measured on a real library before this line existed: 27 of 60
            // recordings held a print under a label the transcript no longer
            // used, and 10 people were missing from the bank entirely. Whether
            // this branch is how they got there was never provable after the
            // fact, which is the whole reason it now leaves a trace.
            // `listen voices --repair` is the other half.
            if !bank.isEmpty {
                log("no voiceprint to move for \(speaker) in \(recording.id): "
                    + "renamed to \(name) in the transcript only. "
                    + "The bank holds \(bank.keys.sorted().joined(separator: ", "))")
            }
            return
        }
        // A human has touched this speaker, so whatever the bank decided about
        // it earlier is now somebody's decision and counts as evidence again.
        // This is the only route back: nothing else clears the flag, which is
        // deliberate, because "the name is still there" is not somebody
        // agreeing with it.
        moving.auto = nil
        // Renaming into a name this recording already has merges two speakers,
        // so one person ends up with two voiceprints. Keep whichever was built
        // from more speech: `isEvidence` is a threshold in seconds, and keeping
        // the shorter one can drop a usable identity below it.
        if let existing = bank[name], existing.speech > moving.speech {
            bank[name] = existing
        } else {
            bank[name] = moving
        }
        write(bank, to: recording)
    }

    static func remove(_ speaker: String, in recording: Recording) {
        var bank = recording.voiceprints
        guard bank.removeValue(forKey: speaker) != nil else { return }
        write(bank, to: recording)
    }

    private static func write(_ bank: [String: Voiceprint], to recording: Recording) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(bank).write(to: recording.embeddingsURL, options: .atomic)
    }
}

extension Recording {
    var voiceprints: [String: Voiceprint] {
        guard let data = try? Data(contentsOf: embeddingsURL),
              let bank = try? JSONDecoder().decode([String: Voiceprint].self, from: data)
        else { return [:] }
        return bank
    }
}
