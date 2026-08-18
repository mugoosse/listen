import Foundation
import ListenKit

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

    /// Recordings a live device other than this one is transcribing, and when
    /// its claim runs out.
    ///
    /// Not a cache of the lease, which lives in the container. This is what
    /// stops `resume` asking about the same contested recording on every pass:
    /// it enqueues anything with audio and no transcript, and once audio is on
    /// every device that is every recording the other Mac is working through.
    private var elsewhere: [String: Date] = [:]

    /// Renews the running job's lease while it runs. Cancelled when it ends.
    private var renewal: Task<Void, Never>?

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

    /// Everything this Mac has taken on and not finished.
    ///
    /// Read by the sync pass before it frees any audio: a recording waiting
    /// here is one whose audio this machine still needs, however many other
    /// devices report holding a copy. See `CloudSyncCore.reclaim`.
    var activeIDs: Set<String> {
        Set(waiting).union(running.map { [$0] } ?? [])
    }

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

        // Another device is on it and its claim has not run out. Asked once
        // and remembered, rather than a round trip per recording per pass.
        // A person pressing Transcribe Again is not affected: that clears the
        // note by passing a model, and an expired claim is simply retried.
        if let until = elsewhere[id] {
            if until > Date(), choice == nil {
                trace("not queueing \(id): another device is transcribing it")
                return false
            }
            elsewhere[id] = nil
        }

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
        // The row before the transcript. A meeting recorded here is worth
        // sending as soon as it exists, so the phone shows it as waiting to be
        // transcribed rather than showing nothing until the transcript lands
        // minutes later. Coalesced, so the launch sweep that enqueues a backlog
        // still costs one pass.
        CloudSyncHost.shared.syncSoon()
        advance()
        return true
    }

    private func advance() {
        guard running == nil, !waiting.isEmpty else { return }
        let id = waiting.removeFirst()
        guard let recording = Recording.find(id) else { advance(); return }

        // The slot is taken before the lease is asked for, so a second call
        // into `advance` while that round trip is in flight cannot start a
        // second job. Nothing is written to `metadata.json` yet: a recording
        // this Mac turns out not to be allowed to transcribe must not be left
        // saying `transcribing` on every other device.
        running = id
        progress = TranscriptionProgress()
        onChange?(id)
        Task { await self.start(recording) }
    }

    /// Take the recording on, if no other device has it, and run it.
    ///
    /// **The lease is taken before anything is written or read.** Audio used to
    /// land on one Mac, so "has the bytes" was the lock and no second machine
    /// could have transcribed if it wanted to. A replicated master removes that
    /// accident and `resume` enqueues anything with audio and no transcript, so
    /// without this the first pass that puts audio on both Macs starts both on
    /// the same hour of work.
    private func start(_ found: Recording) async {
        var recording = found
        let id = recording.id

        guard await CloudSyncHost.shared.takeTranscriptionLease(id) else {
            // Somebody else has it. Remembered with its expiry so the queue
            // stops asking until that claim runs out: `resume` runs after
            // every pass that pulls anything, and a contested recording would
            // otherwise cost a round trip each time to be told the same thing.
            let lease = await CloudSyncHost.shared.transcriptionLease(id)
            let who = lease.flatMap { CloudSyncHost.deviceName(for: $0.device) }
                ?? "another device"
            elsewhere[id] = lease?.expires ?? Date().addingTimeInterval(900)
            trace("not transcribing \(id): \(who) is")
            running = nil
            progress = nil
            onChange?(id)
            advance()
            return
        }

        // A Mac whose only copy is the master takes it apart first. The
        // pipeline reads the two tracks separately on purpose, and a mono sum
        // is not a substitute for them: see `AudioMaster`.
        var splitHere = false
        if !recording.hasTracks,
           FileManager.default.fileExists(atPath: recording.masterURL.path) {
            do {
                _ = try AudioMaster.split(recording.masterURL, into: recording.folder,
                                          micURL: recording.micURL,
                                          systemURL: recording.systemURL)
                // On what actually appeared, not on the call returning. `split`
                // answers 0 rather than throwing when it cannot make a buffer,
                // and a run that then removed tracks it never wrote would be
                // tidying up somebody else's files.
                splitHere = recording.hasTracks
                trace(splitHere ? "split the master for \(id)"
                                : "the master for \(id) produced no tracks")
            } catch {
                log("could not take the master apart for \(id): \(error.localizedDescription)")
            }
        }

        recording.metadata.state = Metadata.State.transcribing.rawValue
        // Written before the run rather than after it, for the same reason the
        // model is: this is what every other device reads while the hour it
        // takes goes by, and a field only written on success says nothing at
        // all about a job that is still going or one that died.
        recording.metadata.transcribed_by = CloudSyncHost.deviceID
        recording.metadata.transcribed_on = CloudSyncHost.deviceName
        recording.metadata.transcribe_started = Metadata.iso(Date())
        recording.metadata.transcribe_finished = nil
        try? recording.save()
        onChange?(id)
        // Say so promptly. `state: transcribing` travelling in the metadata is
        // the second deterrent behind the lease, and the only one at all in the
        // window where the container is unreachable and the lease was therefore
        // granted by default.
        CloudSyncHost.shared.syncSoon()

        // Resolved here rather than inside the pipeline, and traced, because a
        // recording carrying its own model is the case a resumed job gets wrong
        // if anything reads the app default instead.
        let choice = recording.asrModel
        trace("transcribing \(id) with \(choice.title)")

        // A meeting outlives any window short enough to be useful after a
        // crash. Fifteen minutes is the window and five is the renewal, so a
        // Mac that dies loses the recording to whichever machine is awake
        // within a quarter of an hour, while an hour-long job keeps it
        // throughout.
        renewal = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                await CloudSyncHost.shared.renewTranscriptionLease(id)
            }
        }

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

        renewal?.cancel()
        renewal = nil

        var finished = Recording.find(id) ?? recording
        switch result {
        case .success(let transcript):
            finished.markTranscribed(transcript)
        case .failure(let error):
            finished.metadata.state = Metadata.State.failed.rawValue
            log("transcription failed for \(id): \(error.localizedDescription)")
        }
        finished.metadata.transcribe_finished = Metadata.iso(Date())
        try? finished.save()

        // The tracks this run made out of the master go with it. A device
        // holding only a master is holding 68 MB an hour; leaving the split
        // behind would quietly make it 570, on a machine that was never asked
        // to keep the raw audio and did not have it a moment ago.
        if splitHere {
            for url in [finished.micURL, finished.systemURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // On success and on failure alike. A failed run that keeps the lease
        // until it expires is fifteen minutes in which nothing retries.
        await CloudSyncHost.shared.releaseTranscriptionLease(id)

        running = nil
        progress = nil
        onChange?(id)
        // Send it now rather than at the next tick of the two minute poll. A
        // phone that recorded a memo has one thing it is waiting for and it is
        // this, and waiting out the poll is the difference between a transcript
        // that appears and one that has to be waited for without knowing how
        // long. The phone's upload already works this way, which is why the
        // trip felt fast in one direction and slow in the other.
        CloudSyncHost.shared.syncSoon()
        advance()
    }
}
