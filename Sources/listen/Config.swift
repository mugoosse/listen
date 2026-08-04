import AppKit

/// Everything downstream of capture works at 16 kHz mono. Parakeet wants it,
/// FluidAudio wants it, and storing anything higher would cost disk for an
/// hour-long meeting to buy accuracy no part of the pipeline can use.
let SAMPLE_RATE = 16000.0

/// Diagnostics on stderr. `LISTEN_DEBUG=1` additionally traces capture state
/// changes, which is the only way to find out what the process tap is really
/// doing over an hour.
let DEBUG = ProcessInfo.processInfo.environment["LISTEN_DEBUG"] == "1"

func log(_ s: String) {
    FileHandle.standardError.write("[Listen] \(s)\n".data(using: .utf8)!)
}

func trace(_ s: @autoclosure () -> String) {
    guard DEBUG else { return }
    log(s())
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// The two Parakeet builds, and where their weights live.
///
/// There is no language picker and there will not be one. mlx-audio's
/// `language` parameter is copied into `STTOutput` and never reaches the
/// decoder, so a picker would be a control that silently does nothing. v2 is
/// the default because it is English-only and therefore cannot emit another
/// language at all. Whether v3 is worth shipping for meeting audio is an open
/// question: its misdetection problem is a short-clip problem, and a meeting is
/// not short. Measure before deciding (SPEC section 10.4).
struct ModelChoice {
    let id: String
    let title: String
    /// What the model is good and bad at, without its size.
    let blurb: String
    let repo: String
    /// Named in full, and empty unless the coverage is a real question. "25
    /// languages" is a claim nobody can check from the outside, and the
    /// decision it informs is whether *your* language is in that 25.
    var languages: [String] = []
    /// Measured on disk.
    let approxBytes: Int64

    var detail: String { blurb + " · \(Self.humanBytes(approxBytes)) download" }

    static let all: [ModelChoice] = [
        .init(id: "v2", title: "Parakeet v2",
              blurb: "English only · most accurate",
              repo: "mlx-community/parakeet-tdt-0.6b-v2",
              approxBytes: 2_471_601_146),
        .init(id: "v3", title: "Parakeet v3",
              blurb: "25 languages · may misdetect short clips",
              repo: "mlx-community/parakeet-tdt-0.6b-v3",
              // The model card's 25, alphabetically rather than in its own
              // order: this list is read to answer "is mine here?", and that
              // question is answered by scanning. Irish is absent, so it is
              // not simply the EU's official languages.
              languages: [
                "Bulgarian", "Croatian", "Czech", "Danish", "Dutch",
                "English", "Estonian", "Finnish", "French", "German",
                "Greek", "Hungarian", "Italian", "Latvian", "Lithuanian",
                "Maltese", "Polish", "Portuguese", "Romanian", "Russian",
                "Slovak", "Slovenian", "Spanish", "Swedish", "Ukrainian",
              ],
              approxBytes: 2_508_579_601),
    ]

    static let fallback = all[0]

    static func named(_ id: String) -> ModelChoice? { all.first { $0.id == id } }

    /// Where the Hugging Face client keeps its cache, resolved the way the
    /// client resolves it.
    ///
    /// Not simply `~/.cache/huggingface/hub`. swift-huggingface checks
    /// `HF_HUB_CACHE`, then `HF_HOME`, then the standard location, and anyone
    /// who runs other local ML tooling is liable to have set one of those.
    /// Speak looked only in the standard place, so with `HF_HOME` pointing
    /// elsewhere it found an earlier copy of the weights, said "already
    /// downloaded", and then sat on "loading model" for four minutes while the
    /// library quietly fetched 2.4 GB into the other cache: no progress bar,
    /// because as far as Speak knew nothing was being downloaded. The
    /// disk-space figures in Settings measured the wrong directory for the same
    /// reason.
    ///
    /// Every rule here is the library's, including the sandbox branch Listen
    /// does not currently take. Agreement is the whole point; a "more sensible"
    /// rule on this side is how the two came apart in the first place.
    ///
    /// This is also what makes sharing weights with Speak free rather than a
    /// feature: both apps resolve to the same directory, so whichever
    /// downloaded first paid for both.
    static var hubRoot: URL {
        let env = ProcessInfo.processInfo.environment
        if let cache = env["HF_HUB_CACHE"] {
            return URL(fileURLWithPath: NSString(string: cache).expandingTildeInPath)
        }
        if let home = env["HF_HOME"] {
            return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath)
                .appendingPathComponent("hub")
        }
        if env["APP_SANDBOX_CONTAINER_ID"] != nil {
            return URL.cachesDirectory
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub")
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub")
    }

    /// The cache root as a person would write it, for UI that names it.
    static var hubRootDisplay: String {
        let path = hubRoot.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Where mlx-audio keeps its own copy, and what it checks before deciding
    /// to fetch anything.
    var cacheDirectory: URL {
        Self.hubRoot
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
    }

    /// Where the bytes actually land while downloading. The Hugging Face client
    /// streams into `blobs/<etag>.incomplete` and only moves files into place at
    /// the end, so watching `cacheDirectory` shows a flat 0% for the whole
    /// download and then a jump to done.
    var downloadDirectory: URL {
        let parts = repo.split(separator: "/")
        return Self.hubRoot.appendingPathComponent("models--" + parts.joined(separator: "--"))
    }

    private func size(of dir: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Complete enough to skip the download. The margin covers small
    /// differences in what the library actually fetches.
    ///
    /// This needs mlx-audio's own copy, not just a populated hub cache: that
    /// still costs a local copy step, but seconds rather than minutes.
    var isDownloaded: Bool {
        size(of: cacheDirectory) > Int64(Double(approxBytes) * 0.97)
    }

    /// What removing this model would give back.
    ///
    /// A sum, because the weights really are stored twice: once in the hub blob
    /// cache and once in mlx-audio's copy.
    var bytesUsed: Int64 { size(of: downloadDirectory) + size(of: cacheDirectory) }

    /// True when Speak is installed and would use these same weights.
    ///
    /// Reported rather than inferred, because "2.47 GB, already on disk" and
    /// "2.47 GB, already on disk (shared with Speak)" answer different
    /// questions: the second one tells you that deleting it here takes
    /// dictation away too.
    var isSharedWithSpeak: Bool {
        guard isDownloaded else { return false }
        return FileManager.default.fileExists(atPath: "/Applications/Speak.app")
    }

    /// "2.3 GB", written the way the rest of macOS writes it.
    static func humanBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

enum Settings {
    private static let modelKey = "modelID"

    /// The chosen model, or the default when nothing has been chosen.
    ///
    /// `modelChosen` is the presence of the key, not a value that always has
    /// one. Setup uses the difference: nothing downloads until somebody presses
    /// a button that says what it will cost, and a `choice` that always returns
    /// v2 cannot express "not yet asked".
    static var model: ModelChoice {
        get { ModelChoice.named(UserDefaults.standard.string(forKey: modelKey) ?? "")
                ?? ModelChoice.fallback }
        set { UserDefaults.standard.set(newValue.id, forKey: modelKey) }
    }

    static var modelChosen: Bool { UserDefaults.standard.string(forKey: modelKey) != nil }

    static var activeRepo: String { model.repo }
}

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

enum Library {
    /// `~/Library/Application Support/Listen`.
    ///
    /// One folder per recording under `recordings/`, with the audio, the
    /// transcript and the voiceprints as sidecar files. There is deliberately
    /// no database: the set of folders is the library, so deleting a recording
    /// in Finder cannot strand a row, and a half-finished job is just a folder
    /// whose transcript does not exist yet.
    static var root: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Listen")
    }

    static var recordings: URL { root.appendingPathComponent("recordings") }
}

extension Settings {
    private static let startAtLoginAppliedKey = "startAtLoginDefaultApplied"
    private static let autoDetectKey = "autoDetectMeetings"
    private static let onboardedKey = "onboarded"

    static var startAtLoginDefaultApplied: Bool {
        get { UserDefaults.standard.bool(forKey: startAtLoginAppliedKey) }
        set { UserDefaults.standard.set(newValue, forKey: startAtLoginAppliedKey) }
    }

    /// Watch for a meeting app becoming audio-active and offer to record.
    ///
    /// Off by default. An app that starts recording on its own the first time
    /// someone joins a call, before they have decided they want that, is a
    /// worse first impression than one that waits to be asked.
    static var autoDetectMeetings: Bool {
        get { UserDefaults.standard.bool(forKey: autoDetectKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoDetectKey) }
    }

    /// Setup has been completed. The presence of the key is the answer, so a
    /// fresh install is distinguishable from someone who finished setup and
    /// then turned everything off.
    static var onboarded: Bool {
        get { UserDefaults.standard.bool(forKey: onboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: onboardedKey) }
    }

    static var isFirstRun: Bool { UserDefaults.standard.object(forKey: onboardedKey) == nil }
}
