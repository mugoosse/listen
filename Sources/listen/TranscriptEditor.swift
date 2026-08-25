import Foundation

/// Edits to a stored transcript: rename, discard, merge.
///
/// Deliberately not part of the sheet that presents them. The UI owns asking
/// the question; this owns the answer reaching disk. Keeping them apart is what
/// lets `listen label` exercise exactly the code path the window uses, rather
/// than a second implementation that agrees with it right up until it does not.
///
/// None of these re-transcribe. The audio has not changed, and re-running the
/// pipeline to change a string would cost minutes and could come back
/// different, which would look like the app corrupting a transcript someone had
/// already corrected.
enum TranscriptEditor {

    enum Edit {
        case rename(String, to: String)
        case discard(String)
        case merge(String, into: String)
        /// Replace one sentence's text, identified by its position in the stored
        /// segments **and** by the text it is expected to still hold.
        ///
        /// Both, because the position on its own is not a safe name for a
        /// sentence. It comes from a pane that was rendered at some point in the
        /// past, and `.discard` removes segments, so an index taken before one
        /// runs points at a different sentence afterwards. Carrying the old text
        /// makes this a compare-and-swap: if the segment is not the one the user
        /// was looking at, the edit is refused rather than applied to whatever
        /// moved into its place.
        case retext(segment: Int, was: String, to: String)

        /// Move some of one speaker's segments onto another speaker, leaving the
        /// rest of what they said alone.
        ///
        /// The three edits above are all about a *speaker*: everything they said
        /// is renamed, folded into somebody else, or thrown away. This one is
        /// about some *words*, and it is the correction the diarizer's own
        /// mistakes need. A cluster boundary in the wrong place gives one
        /// paragraph, or one sentence inside a paragraph, to somebody who did
        /// not say it, and neither renaming nor merging can fix that without
        /// also moving the parts that were right.
        case reassign(Scope, from: String, to: String)
    }

    /// Which segments a reassignment moves.
    ///
    /// Two shapes, because the two callers name a segment differently and both
    /// have to be safe against a pane that was drawn before something else
    /// edited the transcript.
    ///
    /// `.sentence` is a position and the text that position must still hold: the
    /// same compare-and-swap `.retext` uses, for the same reason, since
    /// `.discard` removes segments and an index taken from an older render then
    /// points at a different sentence.
    ///
    /// `.turn` is a time window rather than a list of indices, because a
    /// paragraph on screen is a fold over however many segments happen to lie
    /// inside it. A window is stated in the transcript's own units, so it names
    /// the same stretch of the meeting whatever has happened to the numbering
    /// since, and it also catches the segments `Merge.sentences` could not place
    /// in the paragraph, which an index list built from the screen would leave
    /// behind under the old speaker with nothing saying so.
    ///
    /// **The window names the turn; it does not select the segments.** It is
    /// resolved back through `Merge.fold`, the same fold that produced the
    /// paragraph, and only that paragraph's segments move. Applying the window
    /// to the segments directly moved the next turn as well whenever two turns
    /// by one speaker touched, which on a two-track recording is most of them.
    /// See `Merge.fold` for the measurement.
    enum Scope {
        case sentence(index: Int, text: String)
        case turn(start: Double, end: Double)
    }

    /// `backup` exists for exactly one caller, `VoiceBank.autoAssign`.
    ///
    /// The `.raw.json.bak` is how `Recording.hasHumanEdits` knows somebody has
    /// corrected this transcript, which is what makes Transcribe Again ask
    /// before throwing the corrections away. An automatic name is not a
    /// correction and must not start that conversation, or every recording the
    /// bank ever named would warn about losing work nobody did. It runs before
    /// anybody has been asked anything, so there is also nothing yet to
    /// preserve: the file it would copy is the pipeline's own output, minus a
    /// speaker label that `metadata.auto_named` records and a rename undoes.
    @discardableResult
    static func apply(_ edit: Edit, to recording: Recording, backup: Bool = true) -> Bool {
        switch edit {
        case .rename(let speaker, let name):
            guard change(recording, backup: backup, { segments in
                for i in segments.indices where segments[i].speaker == speaker {
                    segments[i].speaker = name
                }
                return true
            }) else { return false }
            VoiceBank.rename(speaker, to: name, in: recording)
            return true

        case .discard(let speaker):
            guard change(recording, {
                $0.removeAll { $0.speaker == speaker }
                return true
            }) else { return false }
            VoiceBank.remove(speaker, in: recording)
            return true

        case .merge(let speaker, let target):
            guard change(recording, { segments in
                for i in segments.indices where segments[i].speaker == speaker {
                    segments[i].speaker = target
                }
                return true
            }) else { return false }
            VoiceBank.remove(speaker, in: recording)
            return true

        case .retext(let index, let was, let text):
            let new = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty sentence is refused rather than treated as a deletion.
            // Clearing a field is how you start typing a replacement, not how
            // you say "remove this", and a sentence removed by an empty commit
            // would take its timing with it with nothing on screen having asked.
            guard !new.isEmpty else { return false }
            return change(recording) { segments in
                guard index >= 0, index < segments.count else { return false }
                // Trimmed on both sides. The window's copy of the old text is
                // the substring it found inside the turn, and `Merge.sentences`
                // searches for the *trimmed* segment text, so an imported
                // transcript whose segments carry surrounding whitespace would
                // otherwise fail this check and refuse every edit for a reason
                // nothing on screen could explain.
                let current = segments[index].text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard current == was.trimmingCharacters(in: .whitespacesAndNewlines),
                      current != new else { return false }
                segments[index].text = new
                return true
            }

        case .reassign(let scope, let speaker, let target):
            let to = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !to.isEmpty, to != speaker else { return false }
            guard change(recording, { segments in
                switch scope {
                case .sentence(let index, let text):
                    guard index >= 0, index < segments.count,
                          segments[index].speaker == speaker else { return false }
                    // Trimmed on both sides, for the reason `.retext` gives: an
                    // imported transcript carries whitespace around a segment
                    // that the window never shows, so an untrimmed comparison
                    // refuses every edit on those recordings and nothing on
                    // screen could explain why.
                    let current = segments[index].text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard current == text.trimmingCharacters(in: .whitespacesAndNewlines)
                    else { return false }
                    segments[index].speaker = to
                    return true

                case .turn(let start, let end):
                    // **Through the fold, not over the window.** A window in the
                    // transcript's own units is how the paragraph is named, and
                    // it is not how the segments are found: two turns by one
                    // speaker with somebody else's interjection between them
                    // touch or overlap, so a sweep by start time moves the
                    // paragraph after this one as well. Measured, on a real
                    // call, in `Merge.fold`, which is where the rest of it is.
                    //
                    // Matched on all three, and refused unless exactly one turn
                    // answers. The pane was drawn before this ran; a window that
                    // names no turn, or two, is a transcript that has moved
                    // underneath, and that is the case the caller reports rather
                    // than the case it guesses at.
                    let folded = Merge.fold(segments).filter {
                        $0.turn.speaker == speaker
                            && abs($0.turn.start - start) <= 0.001
                            && abs($0.turn.end - end) <= 0.001
                    }
                    guard folded.count == 1 else { return false }
                    for i in folded[0].segments { segments[i].speaker = to }
                    return true
                }
            }) else { return false }

            // Only when nothing of theirs is left. A voiceprint is built from
            // everything one speaker said, so it still describes the segments
            // that stayed behind; what it stops describing is a label that has
            // gone from the transcript entirely, and a bank entry for somebody
            // who is no longer in the recording goes on being offered as a
            // suggestion in the next one, on evidence that was reassigned away.
            //
            // Re-read rather than reasoned about: `change` has just rewritten
            // the file, and whether the label survived is a question about what
            // is on disk now.
            if Recording.find(recording.id)?.speakers.contains(speaker) != true {
                VoiceBank.remove(speaker, in: recording)
            }
            return true
        }
    }

    /// Apply a change to the stored transcript and rebuild `turns.json`.
    ///
    /// Backs up once, before the first edit, to `<id>.raw.json.bak`. Once,
    /// because the point of the backup is the pipeline's own output: rewriting
    /// it on every edit would overwrite it with edited data the second time,
    /// and it would no longer be a way back to what the model actually said.
    ///
    /// `mutate` returns false to abandon the edit. Nothing is then written and
    /// no backup is taken, which matters because the alternative is a refused
    /// edit that still leaves a `.raw.json.bak` and a rewritten `turns.json`
    /// behind it. The transcript is re-read here rather than passed in, so the
    /// check inside `mutate` is against what is on disk now.
    private static func change(_ recording: Recording, backup takeBackup: Bool = true,
                               _ mutate: (inout [LabelledSegment]) -> Bool) -> Bool {
        guard var transcript = recording.storedTranscript else { return false }
        var proposed = transcript.segments
        guard mutate(&proposed) else { return false }

        // The path lives on `Recording` because this is no longer the only
        // reader: whether a backup exists is how `hasHumanEdits` knows somebody
        // has corrected a sentence, which is what makes transcribing again ask
        // before it throws the corrections away.
        let backup = recording.rawBackupURL
        if takeBackup, !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: recording.transcriptURL, to: backup)
        }
        transcript.segments = proposed

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic, and the transcript before the turns. A crash between the two
        // leaves turns.json stale rather than describing speakers the
        // transcript no longer has.
        try? enc.encode(transcript).write(to: recording.transcriptURL, options: .atomic)
        try? enc.encode(Merge.turns(from: transcript.segments))
            .write(to: recording.turnsURL, options: .atomic)

        // Once nobody is left with a bare letter, the recording is done rather
        // than waiting for someone.
        var updated = recording
        let unnamed = transcript.segments.map(\.speaker).filter(VoiceBank.isPlaceholder)
        updated.metadata.state = unnamed.isEmpty
            ? Metadata.State.done.rawValue
            : Metadata.State.needsLabelling.rawValue
        try? updated.save()

        // Here rather than in `apply`, so it covers a merge and a discard as
        // well as a rename: all three change who is in this recording, and the
        // people title is a view over exactly that. `.retext` reaches this line
        // too and derives the same string it derived last time, which `refresh`
        // recognises and does not write.
        //
        // After the save, for the reason `markTranscribed` gives about the same
        // pair of writes: `refresh` re-reads, and the state it should re-read
        // is the one this edit has just settled.
        AutoTitle.refresh(updated)
        return true
    }
}
