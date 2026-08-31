import AppKit

/// Fetching the speech model deliberately, rather than as a side effect.
///
/// **Why this exists at all.** A missing model was never a silent failure:
/// `ASR.load` calls `resolveOrDownloadModel`, so a recording whose model is
/// absent downloads it and then transcribes. But the only way to *ask* for
/// that download was setup's model step, so somebody whose weights went away
/// afterwards found a Models pane that told them the model was not downloaded
/// and offered nothing to do about it. Reported in testing, in exactly those
/// words: "I don't know what to do to actually download it."
///
/// Speak does not need this. It loads at launch and keeps one `Transcriber`
/// warm, so its AppDelegate owns the answer to "what is the model doing".
/// Listen loads inside a transcription job, through an `ASR` built per run, so
/// before the first recording nobody owns that question. This is that owner.
@MainActor
final class ModelDownload {
    static let shared = ModelDownload()

    private(set) var status: ModelStatus = .idle {
        didSet { onChange?() }
    }

    /// Called on the main thread whenever `status` changes, so a pane can
    /// follow a download it did not start.
    var onChange: (() -> Void)?

    private var task: Task<Void, Never>?
    private var watch: Timer?
    /// Holds the last real reading through a stall.
    ///
    /// **Only an exact zero used to count as a stall, and the reading that
    /// broke this was 41 KB.** When `inFlightBytes` lost sight of the temp
    /// file it was following, `bytesOnDisk` fell back to the two JSON files
    /// already in the hub cache: not zero, so not caught here, and the bar
    /// dropped from nearly full to 0% and stuck, because this then took 41 KB
    /// as the value to hold. So the guard is now "never backwards", which is
    /// true of every quantity it is applied to: within one download the bytes
    /// on disk only grow, and `start` clears it.
    ///
    /// Still not a running maximum seeded from elsewhere, which is the trap
    /// the original note recorded: an abandoned temp file latched onto at 1.4
    /// GB froze Speak's display for the rest of a download. `inFlightBytes`
    /// is what keeps that from happening, by adopting only a file it watched
    /// being written.
    private var lastBytes: Int64 = 0

    /// The temp file the last reading came from, handed back to
    /// `inFlightBytes` so a pause does not lose the transfer.
    private var streaming: URL?

    var isDownloading: Bool { status.isBusy }

    /// Which model the current `.ready` is about.
    ///
    /// `.ready` on its own says a model loaded, not which one, so switching the
    /// radio after a successful download would leave setup looking at a green
    /// light belonging to the other model.
    private(set) var readyID: String?

    /// The model whose last attempt failed here.
    ///
    /// A second press replaces the copy on disk rather than loading it again
    /// and failing the same way. Without it there is a state with no way out:
    /// weights of exactly the right size that will not parse, where every Try
    /// again reads the same broken file and reports the same thing.
    private var failedID: String?

    /// True when `choice` has been loaded, in this process, since it was last
    /// asked for. The only honest answer to "is this model going to work",
    /// because everything cheaper is a check on file size.
    func isVerified(_ choice: ModelChoice) -> Bool {
        if case .ready = status { return readyID == choice.id }
        return false
    }

    /// Fetch `choice`, reporting progress. Safe to call when it is already on
    /// disk: the library returns from a populated cache without touching the
    /// network, which is also what makes this usable as a "verify" button.
    func start(_ choice: ModelChoice) {
        guard !status.isBusy else { return }
        lastBytes = 0
        streaming = nil
        readyID = nil

        // Here rather than in `ASR.load`, and this is the only place that can
        // safely do it: a short copy is either damage or a download somebody
        // else is in the middle of, and this object is the only thing in the
        // process that knows there is no download in flight. Without it,
        // pressing Download again on a half-written directory is a no-op,
        // because the library accepts what is already there.
        choice.removePartialCopy()

        // And a copy that is the right size but did not load is thrown away
        // too, but only after it has failed once and only on an explicit press.
        // Deleting 2.5 GB is not something to do on a hunch.
        if failedID == choice.id, choice.isDownloaded {
            log("replacing \(choice.title): the last attempt to load it failed")
            try? FileManager.default.removeItem(at: choice.cacheDirectory)
        }
        failedID = nil

        if choice.isDownloaded {
            status = .loading
        } else {
            status = .downloading(total: choice.approxBytes, received: nil, fraction: nil)
            startWatch(choice)
        }

        task = Task { [weak self] in
            do {
                // ASR.load is the one path that fetches, so the button and a
                // recording take the same route. A second implementation here
                // would be a second thing to keep in agreement with it.
                try await ASR().load(choice)
                guard !Task.isCancelled else { return }
                self?.readyID = choice.id
                self?.finish(.ready)
            } catch {
                guard !Task.isCancelled else { return }
                log("model download failed: \(error)")
                // The code and nothing else: `describe` below is allowed to
                // name paths for the human reading the pane, and exactly that
                // is why it may never cross the telemetry boundary.
                Telemetry.failure(.modelDownload, code: "model_download.failed",
                                  retryable: true)
                self?.failedID = choice.id
                self?.finish(.failed(ModelStatus.describe(error)))
            }
        }
    }

    /// Stop and forget. Switching models mid-download has to cancel, or the
    /// bytes somebody just declined keep arriving anyway.
    func cancel() {
        task?.cancel()
        task = nil
        stopWatch()
        lastBytes = 0
        streaming = nil
        readyID = nil
        status = .idle
    }

    private func finish(_ next: ModelStatus) {
        stopWatch()
        task = nil
        status = next
    }

    /// Poll the transfer once a second.
    ///
    /// A timer rather than the library's progress handler, because that
    /// handler cannot see this transfer at all. See `ModelChoice.inFlightBytes`
    /// for the measurement.
    ///
    /// `.common` mode, not the default: a menu or a resize puts the run loop
    /// into event tracking, and a timer scheduled the usual way stops firing
    /// for exactly as long as somebody is looking at the thing it updates.
    private func startWatch(_ choice: ModelChoice) {
        stopWatch()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // Synchronously, not `Task { @MainActor in }`. A timer on
            // RunLoop.main already fires on the main thread, and that hop
            // re-enters through the main dispatch queue, which does not drain
            // during a tracking loop, undoing `.common` above.
            MainActor.assumeIsolated {
                guard let self, case .downloading = self.status else { return }
                if choice.isDownloaded {
                    self.status = .loading
                    return
                }
                let reading = choice.bytesOnDisk(following: self.streaming)
                self.streaming = reading.streaming
                // Never backwards. See `lastBytes`: a transfer that pauses
                // long enough for `inFlightBytes` to lose it reads as the few
                // kilobytes of JSON already in the cache, and letting that
                // through both empties the bar and becomes the number it
                // holds afterwards.
                let bytes = max(reading.bytes, self.lastBytes)
                self.lastBytes = bytes
                let fraction = choice.approxBytes > 0
                    ? min(1.0, Double(bytes) / Double(choice.approxBytes))
                    : nil
                self.status = .downloading(
                    total: choice.approxBytes, received: bytes, fraction: fraction)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private func stopWatch() {
        watch?.invalidate()
        watch = nil
    }
}
