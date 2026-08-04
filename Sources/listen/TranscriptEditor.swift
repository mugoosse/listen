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
    }

    @discardableResult
    static func apply(_ edit: Edit, to recording: Recording) -> Bool {
        switch edit {
        case .rename(let speaker, let name):
            guard change(recording, { segments in
                for i in segments.indices where segments[i].speaker == speaker {
                    segments[i].speaker = name
                }
            }) else { return false }
            VoiceBank.rename(speaker, to: name, in: recording)
            return true

        case .discard(let speaker):
            guard change(recording, { $0.removeAll { $0.speaker == speaker } }) else {
                return false
            }
            VoiceBank.remove(speaker, in: recording)
            return true

        case .merge(let speaker, let target):
            guard change(recording, { segments in
                for i in segments.indices where segments[i].speaker == speaker {
                    segments[i].speaker = target
                }
            }) else { return false }
            VoiceBank.remove(speaker, in: recording)
            return true
        }
    }

    /// Apply a change to the stored transcript and rebuild `turns.json`.
    ///
    /// Backs up once, before the first edit, to `<id>.raw.json.bak`. Once,
    /// because the point of the backup is the pipeline's own output: rewriting
    /// it on every edit would overwrite it with edited data the second time,
    /// and it would no longer be a way back to what the model actually said.
    private static func change(_ recording: Recording,
                               _ mutate: (inout [LabelledSegment]) -> Void) -> Bool {
        guard var transcript = recording.storedTranscript else { return false }

        let backup = recording.folder.appendingPathComponent("\(recording.id).raw.json.bak")
        if !FileManager.default.fileExists(atPath: backup.path) {
            try? FileManager.default.copyItem(at: recording.transcriptURL, to: backup)
        }

        mutate(&transcript.segments)

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
