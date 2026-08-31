import Foundation

/// The complete vocabulary of Listen's telemetry, and the proof that it is
/// complete.
///
/// Every event name, every property either app may attach, and every bucket
/// boundary lives in this one file. Both apps' send paths are filtered against
/// `allowedProperties` before anything leaves the device, so an event or a
/// property that is not written down here is not merely undocumented, it is
/// dropped. TELEMETRY.md at the repository root is the prose form of this file
/// and points back at it, which is what lets the claim "counts and buckets,
/// never content" be checked rather than believed.
///
/// The policy sentence is ActivityLog's, adopted verbatim: events and ids,
/// never names, questions or transcript text. Nothing here may ever carry a
/// title, a person, a path, a URL, a tag, a dictionary term, or the text of an
/// error somebody's file name could be sitting inside.
///
/// In ListenKit because the iPhone app compiles these same files: one copy
/// with two consumers rather than two copies that have to be kept agreeing.
/// Foundation only, on purpose. The PostHog SDK is imported by the Mac app
/// target and never by this one.
public enum TelemetrySchema {

    // MARK: - Destination

    /// EU ingestion on purpose: the data is anonymous, but there is no reason
    /// for it to cross an ocean to be counted.
    public static let host = "https://eu.i.posthog.com"

    /// The PostHog project token. A write-only public key, safe to commit:
    /// possessing it lets someone send junk into the project, not read
    /// anything out of it.
    ///
    /// The "Listen" project in PostHog EU, one project for both platforms:
    /// `platform` (mac/iphone) is the super property that tells them apart in
    /// dashboards, rather than splitting the data across two projects that
    /// could never be summed into one activation or retention number.
    public static let projectToken = "phc_wxWX9s4FHq5BkAnXgMNZae4ip9GfJLeaheiNvcVh6ZYZ"

    /// Stamped on every event. Bucket boundaries are forever once shipped,
    /// because moving one silently would make week 12 incomparable with week
    /// 11; this number is the escape hatch when one genuinely has to move.
    public static let schemaVersion = 3

    // MARK: - Events

    public enum Event: String, CaseIterable, Sendable {
        /// Exactly once, the moment consent first becomes yes. The install ID
        /// is created at the same moment, which is what makes "once" true.
        case installationActivated = "installation_activated"
        /// One summary at the end of setup, not a step-by-step trail: what
        /// was chosen, never a trace of walking through the wizard to get
        /// there.
        case setupCompleted = "setup_completed"
        /// A capture this install made landed in the library. Only the
        /// authoring install sends it; a recording arriving over sync was
        /// already counted by the device that made it.
        case recordingCompleted = "recording_completed"
        /// A transcription run finished, either way. Separate from
        /// `recordingCompleted` because hours recorded must count recordings
        /// whose transcription later failed, and the speaker count does not
        /// exist until the diarizer has run.
        case recordingTranscribed = "recording_transcribed"
        case dictationCompleted = "dictation_completed"
        /// One content-free performance summary for one user question. It is
        /// emitted after success or failure, never while the question is being
        /// written, and carries buckets and closed identifiers rather than any
        /// prompt, answer, transcript, title or source id.
        case askCompleted = "ask_completed"
        case featureUsed = "feature_used"
        case operationFailed = "operation_failed"
    }

    // MARK: - Property allowlist

    /// Registered once and attached to every event by the SDK (or by the
    /// phone's sender). Allowed on any event in addition to that event's own
    /// row in `allowedProperties`.
    public static let superProperties: Set<String> = [
        "platform", "app_build", "os_major", "install_age_bucket",
        "acquisition_channel", "schema_version",
    ]

    /// Per-event properties, keyed by `Event.rawValue`. The send filter keeps
    /// an event only if its name is a key here, and strips any property that
    /// is in neither the event's set nor `superProperties`. `$exception` is
    /// absent deliberately: it is the SDK's own crash event, filtered by
    /// prefix in the app instead.
    public static let allowedProperties: [String: Set<String>] = [
        Event.installationActivated.rawValue: ["activation"],
        Event.setupCompleted.rawValue: [
            "outcome", "mic_granted", "model", "dictation_on", "sync_on",
            "calendar_on",
        ],
        Event.recordingCompleted.rawValue: [
            "kind", "source_app", "duration_bucket",
        ],
        Event.recordingTranscribed.rawValue: [
            "outcome", "asr_model", "duration_bucket", "processing_bucket",
            "speaker_count", "track_layout", "kind",
        ],
        Event.dictationCompleted.rawValue: [
            "duration_bucket", "word_count_bucket", "engine",
        ],
        Event.askCompleted.rawValue: [
            "outcome", "backend", "model", "scope", "latency_bucket",
            "round_count", "retry_count", "tool_call_count", "local_read_count",
            "request_size_bucket", "prompt_tokens_bucket", "completion_tokens_bucket",
            "cost_bucket", "reference_count_bucket", "zdr",
        ],
        Event.featureUsed.rawValue: ["feature"],
        Event.operationFailed.rawValue: ["subsystem", "code", "retryable"],
    ]

    // MARK: - Closed vocabularies

    /// The only feature names `feature_used` can carry. A closed enum rather
    /// than a string parameter so a new call site has to come here, and
    /// therefore into TELEMETRY.md, before it can ship.
    public enum Feature: String, Sendable {
        case noteSaved = "note_saved"
        case syncEnabled = "sync_enabled"
        case dictationEnabled = "dictation_enabled"
        case calendarConnected = "calendar_connected"
        case shareExport = "share_export"
        case importRecording = "import"
        case iphoneCapture = "iphone_capture"
        case keepAudioToggle = "keep_audio_toggle"
    }

    public enum Subsystem: String, Sendable {
        case capture
        case modelDownload = "model_download"
        case sync
        case dictation
        case library
    }

    public enum AskOutcome: String, Sendable {
        case ok
        case timeout
        case offline
        case providerError = "provider_error"
        case ungrounded
        case invalidEvidence = "invalid_evidence"
        case tooManyRounds = "too_many_rounds"
    }

    public enum AskBackend: String, Sendable {
        case openrouter
        case claudeCode = "claude_code"
        case codex
        case localEndpoint = "local_endpoint"
        case remoteEndpoint = "remote_endpoint"
    }

    /// The answers the one-time "How did you hear about Listen?" picker can
    /// give. Fixed choices and no free text, because a written-in answer is a
    /// place for a name to arrive. "Prefer not to say" is the picker leaving
    /// the property unset, not a value.
    public enum AcquisitionChannel: String, CaseIterable, Sendable {
        case github
        case homebrew
        case appStore = "app_store"
        case search
        case reddit
        case hackerNews = "hacker_news"
        case youtubeOrPodcast = "youtube_podcast"
        case friend
        case other

        /// What the picker shows for each fixed answer, here so the two apps
        /// ask the question in the same words. What is sent is the raw value.
        public var label: String {
            switch self {
            case .github: return "GitHub"
            case .homebrew: return "Homebrew"
            case .appStore: return "The App Store"
            case .search: return "A web search"
            case .reddit: return "Reddit"
            case .hackerNews: return "Hacker News"
            case .youtubeOrPodcast: return "YouTube or a podcast"
            case .friend: return "A friend or colleague"
            case .other: return "Somewhere else"
            }
        }
    }

    // MARK: - Source app

    /// The fixed set of labels a recording's `app_bundle_id` may become.
    /// Anything unrecognised is "other", never the raw bundle id: an id can
    /// name an employer's in-house tool, which is a fact about the person.
    /// Browsers collapse to one label because the bundle id says which
    /// browser, not which service was inside it.
    public static func sourceAppLabel(bundleID: String?) -> String {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return "none" }
        if id.contains("zoom") { return "zoom" }
        if id.contains("teams") { return "teams" }
        if id.contains("slack") { return "slack" }
        if id.contains("facetime") { return "facetime" }
        if id.contains("discord") { return "discord" }
        if id.contains("whatsapp") { return "whatsapp" }
        if id.contains("telegram") { return "telegram" }
        if id.contains("signal") { return "signal" }
        if id.contains("webex") || id.contains("cisco") { return "webex" }
        if id.contains("chrome") || id.contains("safari") || id.contains("firefox")
            || id.contains("edgemac") || id.contains("thebrowser")
            || id.contains("brave") || id.contains("arc") || id.contains("vivaldi")
            || id.contains("opera") { return "browser" }
        return "other"
    }

    /// What kind of recording this is, from the provenance word in
    /// `metadata.source`. Legacy recordings put the bundle id itself in
    /// `source`, so a dot means a detected meeting from before the field
    /// moved (the same reconciliation `Recording.appBundleID` does).
    public static func recordingKind(source: String?) -> String {
        switch source {
        case "detected": return "meeting"
        case "imported": return "import"
        case "cli": return "cli"
        case "iphone": return "phone_memo"
        case let s? where s.contains("."): return "meeting"
        default: return "memo"
        }
    }

    // MARK: - Buckets

    /// Recording length. Midpoints for the hours dashboards are written in
    /// TELEMETRY.md next to these boundaries; both move together or not at all.
    public static func durationBucket(seconds: Double) -> String {
        switch seconds {
        case ..<60: return "under_1_min"
        case ..<300: return "1_5_min"
        case ..<900: return "5_15_min"
        case ..<1800: return "15_30_min"
        case ..<3600: return "30_60_min"
        case ..<7200: return "1_2_h"
        default: return "over_2_h"
        }
    }

    /// Dictation length. A different scale from recordings because a
    /// dictation is seconds long, and one bucket would hold them all.
    public static func dictationDurationBucket(seconds: Double) -> String {
        switch seconds {
        case ..<5: return "under_5_s"
        case ..<15: return "5_15_s"
        case ..<30: return "15_30_s"
        case ..<60: return "30_60_s"
        default: return "over_1_min"
        }
    }

    public static func wordCountBucket(_ words: Int) -> String {
        switch words {
        case ..<6: return "1_5"
        case ..<21: return "6_20"
        case ..<51: return "21_50"
        case ..<101: return "51_100"
        default: return "over_100"
        }
    }

    /// Wall-clock time for one question, including local tool calls and every
    /// provider round. Exact milliseconds stay in the local unified log.
    public static func askLatencyBucket(milliseconds: Int) -> String {
        switch max(milliseconds, 0) {
        case ..<2_000: return "under_2_s"
        case ..<5_000: return "2_5_s"
        case ..<15_000: return "5_15_s"
        case ..<30_000: return "15_30_s"
        case ..<60_000: return "30_60_s"
        case ..<90_000: return "60_90_s"
        default: return "over_90_s"
        }
    }

    /// Largest encoded provider request in a run. This tells a slow model from
    /// a long-context request without revealing a byte of that context.
    public static func askRequestSizeBucket(bytes: Int?) -> String {
        guard let bytes else { return "unknown" }
        switch max(bytes, 0) {
        case ..<16_384: return "under_16_kb"
        case ..<32_768: return "16_32_kb"
        case ..<65_536: return "32_64_kb"
        case ..<131_072: return "64_128_kb"
        default: return "over_128_kb"
        }
    }

    public static func askTokenBucket(_ count: Int?) -> String {
        guard let count else { return "unknown" }
        switch max(count, 0) {
        case ..<1_000: return "under_1k"
        case ..<4_000: return "1_4k"
        case ..<16_000: return "4_16k"
        case ..<64_000: return "16_64k"
        default: return "over_64k"
        }
    }

    public static func askCostBucket(usd: Double?) -> String {
        guard let usd, usd >= 0 else { return "unknown" }
        switch usd {
        case ..<0.001: return "under_0_001_usd"
        case ..<0.005: return "0_001_0_005_usd"
        case ..<0.02: return "0_005_0_02_usd"
        case ..<0.10: return "0_02_0_10_usd"
        default: return "over_0_10_usd"
        }
    }

    public static func askReferenceCountBucket(_ count: Int?) -> String {
        guard let count else { return "unknown" }
        switch max(count, 0) {
        case 0: return "0"
        case 1: return "1"
        case 2...4: return "2_4"
        default: return "5_plus"
        }
    }

    public static func cappedAskCount(_ count: Int) -> Int {
        min(max(count, 0), 24)
    }

    /// Transcription speed as a fraction of the recording's own length, so a
    /// two hour meeting and a five minute memo land in the same histogram.
    /// "0_25x" reads as: transcribing took a quarter of the audio's duration.
    public static func processingBucket(processingSeconds: Double,
                                        durationSeconds: Double) -> String {
        guard durationSeconds > 0, processingSeconds >= 0 else { return "unknown" }
        let factor = processingSeconds / durationSeconds
        switch factor {
        case ..<0.1: return "under_0_1x"
        case ..<0.25: return "0_1_to_0_25x"
        case ..<0.5: return "0_25_to_0_5x"
        case ..<1.0: return "0_5_to_1x"
        default: return "over_1x"
        }
    }

    /// How old this install is, recomputed at each launch from the day
    /// consent was granted. Coarse on purpose: an exact install date plus a
    /// small cohort is a fingerprint.
    public static func installAgeBucket(days: Int) -> String {
        switch days {
        case ..<1: return "day_0"
        case ..<7: return "week_1"
        case ..<31: return "month_1"
        case ..<93: return "month_2_3"
        default: return "over_3_months"
        }
    }

    /// Speaker counts above this are reported as the cap. A meeting with an
    /// unusual number of diarized voices is closer to identifying than a
    /// histogram needs.
    public static let speakerCountCap = 12

    public static func cappedSpeakerCount(_ n: Int) -> Int {
        min(max(n, 0), speakerCountCap)
    }
}
