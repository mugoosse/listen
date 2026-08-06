import Foundation

/// Runs transcription jobs, one at a time.
///
/// One at a time is the whole design. Parakeet is on the GPU and FluidAudio is
/// on the Neural Engine, and two jobs do not finish sooner for running
/// together: they contend for the same hardware and, on a 16 GB machine,
/// Parakeet alone is about 2.5 GB resident. `dashboard.py` reached the same
/// conclusion; this keeps it.
///
/// There is no job database. A recording whose audio exists and whose
/// transcript does not is pending, which means the queue can be rebuilt from
/// the file system at launch and a crash mid-job costs one re-run rather than a
/// stuck row.
@MainActor
final class Queue {
    static let shared = Queue()

    private let pipeline = Pipeline()
    private var waiting: [String] = []
    private(set) var running: String?
    /// What the running job is doing and how far through it is, nil otherwise.
    ///
    /// Counted rather than estimated, all the way down: see
    /// `TranscriptionProgress`. This used to be a bare stage string, which was
    /// all there was to report while the chunk loop lived inside mlx-audio and
    /// returned nothing until the whole track was done.
    private(set) var progress: TranscriptionProgress?

    /// The sentence alone, which is all a sidebar row has room for.
    var stage: String? { progress?.message }

    /// Fires on any queue change so the sidebar can redraw a row.
    var onChange: ((String) -> Void)?

    /// Fires as the running job advances, which is once per chunk.
    ///
    /// Separate from `onChange` because the two mean different things to a
    /// window. A queue change is a recording arriving or finishing: the list is
    /// different and a transcript may now exist, so the answer is a reload. This
    /// is the same job moving, thirty times a track, and `LibraryWindow.reload`
    /// re-shows the selected recording, which stops playback and puts the
    /// playhead back to zero. Sending progress down that path would interrupt
    /// anybody listening to one meeting while another transcribes, once per
    /// piece. While the chunk loop was inside mlx-audio there were only three or
    /// four of these in a whole job and one callback was enough for both.
    var onProgress: ((String) -> Void)?

    var isBusy: Bool { running != nil }

    func isQueued(_ id: String) -> Bool { running == id || waiting.contains(id) }

    /// Queue everything on disk that has audio but no transcript.
    ///
    /// Called at launch. Resumability falls out of the layout rather than
    /// needing state: a job interrupted by a quit is simply a recording whose
    /// transcript is still missing.
    func resume() {
        for recording in Recording.all() where !recording.hasTranscript {
            enqueue(recording.id)
        }
        if !waiting.isEmpty { trace("queued \(waiting.count) pending recording(s) at launch") }
    }

    /// Take a recording on, if it is this machine's to transcribe.
    ///
    /// Returns whether it was queued, so a caller that is a control can say why
    /// rather than appearing to do nothing.
    ///
    /// `using` is a model for this recording from here on, not for this run.
    /// It is written to `metadata.json` **before** the job starts, so a quit or
    /// a crash mid-run resumes on the model somebody chose rather than silently
    /// falling back to the default and reproducing the transcript they were
    /// trying to replace. That is the same property the rest of the queue has:
    /// the state is the files, and there is nothing else to lose.
    ///
    /// Written after the already-queued guard, deliberately. A job that has
    /// started has its weights loaded, so filing a different model against it
    /// would leave a claim in `metadata.json` that the transcript on its way out
    /// contradicts.
    @discardableResult
    func enqueue(_ id: String, using choice: ModelChoice? = nil) -> Bool {
        guard !isQueued(id) else { return false }

        if let choice, var recording = Recording.find(id),
           recording.metadata.asr_model != choice.id {
            recording.metadata.asr_model = choice.id
            try? recording.save()
        }

        // Audio is the thing there is to transcribe, and a recording without any
        // cannot be a job however pending it looks.
        //
        // This is what makes the app safe to leave open on two Macs that share a
        // library. "Audio exists and a transcript does not" is how the queue is
        // rebuilt from the file system at launch, with no job table, and it is
        // exactly the sentence that stops being true once a second machine can
        // see the folder: a recording synced from the other Mac has metadata
        // before it has a transcript, so every launch here would queue a run
        // that can only fail, mark it `failed`, and race the real transcript on
        // its way over. `effectiveState` heals the wrong state afterwards, which
        // means the only surviving evidence would be a fan spinning up.
        //
        // Deliberately not a check on which device recorded it. Audio is the
        // fact that matters, it is already on disk, and it stays correct if the
        // WAVs are ever synced too.
        guard Recording.find(id)?.hasAudio == true else {
            trace("not queueing \(id): no audio on this Mac")
            return false
        }

        waiting.append(id)
        onChange?(id)
        advance()
        return true
    }

    private func advance() {
        guard running == nil, !waiting.isEmpty else { return }
        let id = waiting.removeFirst()
        guard var recording = Recording.find(id) else { advance(); return }

        running = id
        progress = TranscriptionProgress()
        recording.metadata.state = Metadata.State.transcribing.rawValue
        try? recording.save()
        onChange?(id)

        // Resolved here rather than inside the pipeline, and traced, because a
        // recording carrying its own model is the case a resumed job gets wrong
        // if anything reads the app default instead.
        let choice = recording.asrModel
        trace("transcribing \(id) with \(choice.title)")

        Task { [pipeline] in
            var result: Result<StoredTranscript, Error>
            do {
                let transcript = try await pipeline.run(recording, using: choice) { [weak self] step in
                    Task { @MainActor in
                        self?.progress = step
                        self?.onProgress?(id)
                    }
                }
                result = .success(transcript)
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                var finished = Recording.find(id) ?? recording
                switch result {
                case .success(let transcript):
                    finished.markTranscribed(transcript)
                case .failure(let error):
                    finished.metadata.state = Metadata.State.failed.rawValue
                    log("transcription failed for \(id): \(error.localizedDescription)")
                }
                try? finished.save()
                self.running = nil
                self.progress = nil
                self.onChange?(id)
                self.advance()
            }
        }
    }
}
