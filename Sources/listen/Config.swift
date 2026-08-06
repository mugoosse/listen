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
///
/// The choice is per recording as well as app-wide (`Metadata.asr_model`),
/// because the default is right for the language somebody usually meets in and
/// wrong for the one call that was not. v2 on a Dutch meeting does not fail: it
/// decodes Dutch as English and writes fluent nonsense, so the model is the
/// only lever there is and the recording has to remember which one it wants.
struct ModelChoice {
    let id: String
    let title: String
    /// What the model is good and bad at, without its size.
    let blurb: String
    /// Which languages it can read, and nothing else.
    ///
    /// Separate from `blurb` rather than cut out of it, for the menu on
    /// Transcribe Again. The rest of the blurb is a caveat about short clips,
    /// which is true and belongs in Settings, and which is misleading at the
    /// moment somebody is re-transcribing a meeting: a meeting is not short.
    let coverage: String
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
              coverage: "English only",
              repo: "mlx-community/parakeet-tdt-0.6b-v2",
              approxBytes: 2_471_601_146),
        .init(id: "v3", title: "Parakeet v3",
              blurb: "25 languages · may misdetect short clips",
              coverage: "25 languages",
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

    /// The model a transcript says produced it.
    ///
    /// `StoredTranscript.model` is the repo string rather than an id, because it
    /// records what actually ran rather than what was asked for. Nil for a
    /// legacy import, whose transcripts name a model this app has never had.
    static func forRepo(_ repo: String) -> ModelChoice? { all.first { $0.repo == repo } }

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

    /// How far a download has got, for a progress bar.
    ///
    /// A maximum rather than a sum, unlike `bytesUsed`: this follows one
    /// download through two locations, the hub cache while fetching and
    /// mlx-audio's copy once it is unpacked there, so the larger reading is
    /// the truthful one.
    var bytesOnDisk: Int64 {
        max(size(of: downloadDirectory), size(of: cacheDirectory))
            + Self.inFlightBytes()
    }

    /// Bytes of a download still streaming into the temp directory.
    ///
    /// **This is the only place the transfer is observable, and the obvious
    /// alternative does not work.** The library exposes a `Progress` and
    /// samples it every 100 ms, but on this transport the large file's bytes
    /// never reach it, so it sits at 0% for the whole download and then jumps
    /// to done. Ported from Speak, where it was measured: `URLSession` writes
    /// to `CFNetworkDownload_XXXXXX.tmp` and moves the finished file into the
    /// cache only at the end, so the destination stays flat at a megabyte of
    /// JSON throughout while the temp file went 969 MB, 1001 MB, 1076 MB over
    /// six seconds.
    ///
    /// The most recently written file, not the largest. A cancelled download
    /// leaves its temp file behind at whatever size it reached, and taking the
    /// largest latches onto exactly that: in Speak, cancelling at 58% pinned
    /// the display to 1.42 GB while the real transfer climbed from zero
    /// underneath it, invisible until it passed the abandoned file. The active
    /// download is the one being written, so mtime identifies it and size does
    /// not.
    ///
    /// Measured here against a genuinely hostile temp directory, which is why
    /// that choice is not academic: this machine had **54 abandoned
    /// `CFNetworkDownload` files totalling 13 GB**, four of them larger than
    /// the model. Taking the largest would have reported 100% before the real
    /// download had fetched a byte. Watching a live fetch instead, the newest
    /// mtime tracked it cleanly and its age never exceeded one second:
    ///
    ///     308 MB → 600 → 872 → 1074 → 1279 → 1465 → 1529 over 66 s
    ///
    /// So the ten second cutoff is doing real work, and comfortably: nothing
    /// stale ever came close to qualifying. About 23 MB/s here, 2.5 GB in
    /// roughly 110 s, which is what the progress bar is pacing against.
    static func inFlightBytes() -> Int64 {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return 0 }

        var newest = Date().addingTimeInterval(-10)
        var bytes: Int64 = 0
        for url in entries where url.lastPathComponent.hasPrefix("CFNetworkDownload") {
            guard let v = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let modified = v.contentModificationDate, modified > newest
            else { continue }
            newest = modified
            bytes = Int64(v.fileSize ?? 0)
        }
        return bytes
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

/// What the speech model is doing, so a screen can say something specific
/// rather than leaving somebody watching nothing for ten minutes.
///
/// Ported from Speak. Listen needs it for a reason Speak does not have: Speak
/// loads its model at launch and keeps it warm, so there is always something
/// to ask. Listen loads inside a transcription job, so before the first
/// recording there is no owner of this question at all, and the Models pane
/// could only report what was already on disk.
enum ModelStatus {
    case idle
    /// `fraction` is nil until the first reading, and stays nil for the whole
    /// download if nothing usable ever arrives. See `inFlightBytes`.
    case downloading(total: Int64, received: Int64?, fraction: Double?)
    case loading
    case ready
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .loading: return true
        case .idle, .ready, .failed: return false
        }
    }

    var fraction: Double? {
        if case .downloading(_, _, let f) = self { return f }
        return nil
    }

    var summary: String {
        switch self {
        case .downloading(let total, let received, let fraction):
            let f = ByteCountFormatter()
            f.countStyle = .file
            f.allowsNonnumericFormatting = false
            guard let fraction, let received else {
                // The first second, before a measurement exists. Say what is
                // coming and nothing else: a percentage here would be a guess.
                return "downloading… \(f.string(fromByteCount: total))"
            }
            let pct = Int((fraction * 100).rounded())
            return "downloading… \(pct)% · \(f.string(fromByteCount: received))"
                 + " of \(f.string(fromByteCount: total))"
        case .idle:    return ""
        case .loading: return "loading the model…"
        case .ready:   return "ready"
        case .failed(let why): return why
        }
    }

    /// Turns library errors into something somebody can act on.
    static func describe(_ error: Error) -> String {
        let raw = "\(error)"
        if raw.contains("offline") || raw.contains("network")
            || raw.contains("NSURLError") || raw.contains("Internet") {
            return "no internet connection, so the model cannot be downloaded"
        }
        if raw.contains("401") || raw.contains("404") || raw.contains("Not Found") {
            return "model not found on Hugging Face"
        }
        if raw.contains("No space") || raw.contains("ENOSPC") {
            return "not enough disk space for the model"
        }
        return "could not download the model"
    }
}

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

enum Settings {
    /// Where preferences are stored, which is not always `standard`.
    ///
    /// `UserDefaults.standard` is the app's own domain only while the process
    /// is bundled. Run through the installed symlink there is no `Info.plist`
    /// above the executable, `Bundle.main.bundleIdentifier` is nil, and the
    /// standard domain becomes one named after the process. Measured: `listen
    /// me "Symlink Test"` printed the new name, `defaults read com.mgo.listen
    /// userName` said the pair did not exist, and the app went on showing "Me".
    /// A setting that reports success and reaches nothing is the worst shape
    /// this bug can take.
    ///
    /// Reads had the same fault the other way round: `listen sources` answered
    /// "detection is on" from the default rather than from the preference,
    /// however the app was actually configured.
    ///
    /// This is the `Bundle.main` trap in `AppInfo`, one layer down, and it is
    /// resolved the same way: from the `Info.plist` beside the real binary.
    static let defaults: UserDefaults = {
        if Bundle.main.bundleIdentifier != nil { return .standard }
        guard let id = AppInfo.bundleID, let suite = UserDefaults(suiteName: id) else {
            return .standard
        }
        return suite
    }()

    private static let modelKey = "modelID"

    /// The chosen model, or the default when nothing has been chosen.
    ///
    /// `modelChosen` is the presence of the key, not a value that always has
    /// one. Setup uses the difference: nothing downloads until somebody presses
    /// a button that says what it will cost, and a `choice` that always returns
    /// v2 cannot express "not yet asked".
    static var model: ModelChoice {
        get { ModelChoice.named(defaults.string(forKey: modelKey) ?? "")
                ?? ModelChoice.fallback }
        set { defaults.set(newValue.id, forKey: modelKey) }
    }

    static var modelChosen: Bool { defaults.string(forKey: modelKey) != nil }

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
        // A different library, for a screenshot or a demo, without touching the
        // real one. Same family as `LISTEN_DEBUG` and `LISTEN_CHUNK`: an
        // environment variable, so a Finder launch inherits no shell and can
        // never see it, and nothing inside the app can set it by accident.
        //
        // It exists because the alternative for publishing a screenshot is
        // renaming real people in a real library and hoping to put them back.
        if let path = ProcessInfo.processInfo.environment["LISTEN_LIBRARY"],
           !path.trimmingCharacters(in: .whitespaces).isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Listen")
    }

    static var recordings: URL { root.appendingPathComponent("recordings") }

    /// The note artifacts, one markdown file each.
    ///
    /// Beside the recordings rather than inside one, which is where
    /// `dictionary.json` and `contacts.json` already sit and for the same
    /// reason: a note can be about four meetings at once, so it is about the
    /// library rather than about any single folder in it.
    ///
    /// The consequence is that deleting a recording no longer deletes the notes
    /// that mention it, and that is deliberate. A synthesis of four meetings
    /// must not vanish because one of them was tidied up, so a note keeps
    /// naming an id the library no longer has and shows it unresolved.
    static var notes: URL { root.appendingPathComponent("notes") }
}

extension Settings {
    private static let startAtLoginAppliedKey = "startAtLoginDefaultApplied"
    private static let autoDetectKey = "autoDetectMeetings"
    private static let skippedKey = "skippedBundleIDs"
    private static let onboardedKey = "onboarded"
    private static let nameFromCalendarKey = "nameFromCalendar"

    static var startAtLoginDefaultApplied: Bool {
        get { defaults.bool(forKey: startAtLoginAppliedKey) }
        set { defaults.set(newValue, forKey: startAtLoginAppliedKey) }
    }

    /// Watch for a call starting and record it, asking as it goes.
    ///
    /// **On** by default. This was off, on the argument that an app which
    /// starts recording the first time you join a call, before you have asked
    /// it to, is a worse first impression than one that waits. That argument
    /// loses to a simpler one: a meeting recorder you have to remember to turn
    /// on is a meeting recorder that is off for the meeting you needed it for,
    /// and the whole reason capture starts before the question is answered is
    /// that the opening minute is the part worth keeping.
    ///
    /// What makes it defensible is that it asks, immediately and on screen, and
    /// that "No" deletes the audio rather than filing it. Nothing is kept
    /// quietly.
    ///
    /// The presence of the key is the answer, not its truthiness.
    /// `UserDefaults.bool(forKey:)` returns false for a key that was never
    /// written, which cannot tell "not set yet" from "deliberately turned off",
    /// so reading it that way would make a default of true impossible to
    /// express and would silently re-enable detection for anyone who turned it
    /// off.
    static var autoDetectMeetings: Bool {
        get { defaults.object(forKey: autoDetectKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: autoDetectKey) }
    }

    /// Apps that never count as a meeting.
    ///
    /// The detection rule is "input and output running at once", which is
    /// deliberately broader than a list of known meeting apps, so some things
    /// that are not meetings will match it. Other recorders are the obvious
    /// case: Blackbox holds the microphone while it captures a call, so with
    /// both installed each one looks like a meeting to the other.
    ///
    /// Stored as a sorted array rather than a set, because `UserDefaults`
    /// cannot hold a `Set` and an unordered array would rewrite the plist on
    /// every launch.
    static var skippedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: skippedKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: skippedKey) }
    }

    /// Name a recording after the meeting in your calendar that it lines up
    /// with, and remember who was invited.
    ///
    /// **On** by default, and it applies the name without asking, which is only
    /// defensible because of two guards and one measurement. The guards: it
    /// never touches a title somebody typed, and it only considers events whose
    /// start is within ten minutes of the recording's. The measurement, over
    /// the 47 recordings in the real library: at ten minutes fourteen matched
    /// and every match was plausible, while at thirty two more matched and both
    /// of those were wrong. See `MeetingCalendar.window`.
    ///
    /// The presence of the key is the answer, not its truthiness, for the same
    /// reason as `autoDetectMeetings` above: `bool(forKey:)` cannot tell "never
    /// set" from "turned off on purpose", so a default of true would be
    /// inexpressible and anyone who turned it off would have it turned back on.
    static var nameFromCalendar: Bool {
        get { defaults.object(forKey: nameFromCalendarKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: nameFromCalendarKey) }
    }

    static func skip(_ bundleID: String) {
        skippedBundleIDs.insert(bundleID)
    }

    static func unskip(_ bundleID: String) {
        skippedBundleIDs.remove(bundleID)
    }

    /// Setup has been completed. The presence of the key is the answer, so a
    /// fresh install is distinguishable from someone who finished setup and
    /// then turned everything off.
    static var onboarded: Bool {
        get { defaults.bool(forKey: onboardedKey) }
        set { defaults.set(newValue, forKey: onboardedKey) }
    }

    static var isFirstRun: Bool { defaults.object(forKey: onboardedKey) == nil }

    private static let userNameKey = "userName"

    /// What the microphone track is called on screen.
    ///
    /// A preference and not a transcript edit, which is the whole design: the
    /// transcripts keep saying `Me` and `SpeakerName.display` resolves it here,
    /// so choosing a name applies to every recording ever made and changing it
    /// again costs nothing. See `SpeakerName.you` for why the other way round
    /// is worse.
    ///
    /// nil until somebody chooses, and nil again when they clear the field.
    /// Empty is stored as absent rather than as "", so a cleared field shows
    /// `Me` rather than a nameless chip.
    static var userName: String? {
        get {
            // A screenshot must not inherit the name from the developer's real
            // library. This is intentionally an environment-only preview
            // override: Finder launches cannot acquire it by accident, and it
            // never writes to the user's defaults. `make_demo_library.sh` sets
            // it alongside LISTEN_LIBRARY, so its output contains no local
            // profile data.
            if let demo = ProcessInfo.processInfo.environment["LISTEN_DEMO_NAME"]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !demo.isEmpty {
                return demo
            }
            let stored = defaults.string(forKey: userNameKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let stored, !stored.isEmpty else { return nil }
            return stored
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: userNameKey)
            } else {
                defaults.removeObject(forKey: userNameKey)
            }
        }
    }

    /// Offered in the field, never applied on its own.
    ///
    /// The Mac account name is often a login handle or a formal full name, and
    /// a name nobody chose turning up in transcripts is worse than `Me`.
    static var suggestedUserName: String { NSFullUserName() }
}
