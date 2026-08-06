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
    }

    @discardableResult
    static func apply(_ edit: Edit, to recording: Recording) -> Bool {
        switch edit {
        case .rename(let speaker, let name):
            guard change(recording, { segments in
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
    private static func change(_ recording: Recording,
                               _ mutate: (inout [LabelledSegment]) -> Bool) -> Bool {
        guard var transcript = recording.storedTranscript else { return false }
        var proposed = transcript.segments
        guard mutate(&proposed) else { return false }

        // The path lives on `Recording` because this is no longer the only
        // reader: whether a backup exists is how `hasHumanEdits` knows somebody
        // has corrected a sentence, which is what makes transcribing again ask
        // before it throws the corrections away.
        let backup = recording.rawBackupURL
        if !FileManager.default.fileExists(atPath: backup.path) {
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
        return true
    }
}
