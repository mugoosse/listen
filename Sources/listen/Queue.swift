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
    /// 0...1 while a job is going, nil otherwise. Coarse on purpose: the stages
    /// are few and long, and a fake smooth bar would be a lie about progress.
    private(set) var stage: String?

    /// Fires on any queue change so the sidebar can redraw a row.
    var onChange: ((String) -> Void)?

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
    @discardableResult
    func enqueue(_ id: String) -> Bool {
        guard !isQueued(id) else { return false }

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
        stage = "starting"
        recording.metadata.state = Metadata.State.transcribing.rawValue
        try? recording.save()
        onChange?(id)

        Task { [pipeline] in
            var result: Result<StoredTranscript, Error>
            do {
                let transcript = try await pipeline.run(recording) { [weak self] message in
                    Task { @MainActor in
                        self?.stage = message
                        self?.onChange?(id)
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
                self.stage = nil
                self.onChange?(id)
                self.advance()
            }
        }
    }
}
