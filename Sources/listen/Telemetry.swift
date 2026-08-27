import Foundation
import PostHog
import ListenKit

/// Listen's one gate onto PostHog, and the only file in the app target that
/// imports it.
///
/// The policy is ActivityLog's, adopted verbatim: events and ids, never names,
/// questions or transcript text. Every function here takes domain values and
/// does the bucketing and mapping itself, so a call site cannot leak a raw
/// duration, a bundle id or a title even by mistake, and everything that does
/// go out is filtered against `TelemetrySchema.allowedProperties` first. What
/// that schema permits is written down in TELEMETRY.md.
///
/// The SDK object is never constructed until consent is yes. That is a
/// stronger promise than initialising it opted-out, it is the promise the
/// verify script asserts (zero requests, not zero events), and it means a
/// crash before consent is never reported either.
enum Telemetry {

    // MARK: - Consent

    /// nil is "never asked", and it is a real state: setup asks new users,
    /// the one-time prompt asks existing ones, and until one of them has
    /// answered nothing is sent and no identity exists.
    static var consent: Bool? {
        get { Settings.defaults.object(forKey: Settings.telemetryConsentKey) as? Bool }
        set {
            let old = consent
            if let newValue {
                Settings.defaults.set(newValue, forKey: Settings.telemetryConsentKey)
            } else {
                Settings.defaults.removeObject(forKey: Settings.telemetryConsentKey)
            }
            apply(from: old, to: newValue)
        }
    }

    /// Off for everyone when any of these says so, whatever consent says:
    /// an organisation's forced key, the environment seam, a build with no
    /// project token (the constant is empty until the PostHog project
    /// exists, so the feature can merge before the account does), or a
    /// build nobody released.
    static var blocked: Bool {
        if Settings.forcedBool("telemetryDisabled") == true { return true }
        if ProcessInfo.processInfo.environment["LISTEN_NO_TELEMETRY"] == "1" { return true }
        if TelemetrySchema.projectToken.isEmpty && endpointOverride == nil { return true }
        // A build made by hand for day-to-day development never sends to the
        // real project, whatever consent says: `ListenReleaseBuild` is set
        // only by `make_app.sh`, only when `release.sh` asked for it, so
        // rebuilding today's work fifty times cannot count as fifty installs.
        // The endpoint override is the deliberate exception, not a loophole
        // in it: pointing telemetry at a chosen host by hand is what
        // `verify_telemetry.sh` and manual testing do on purpose, which is a
        // different thing from a local build quietly reaching the real one.
        if !isReleaseBuild && endpointOverride == nil { return true }
        return false
    }

    /// True only for a build `release.sh` produced.
    private static var isReleaseBuild: Bool {
        (Bundle.main.infoDictionary?["ListenReleaseBuild"] as? Bool) == true
    }

    static var enabled: Bool { consent == true && !blocked }

    /// The verify script points this at a listener on localhost. It exists
    /// because "no events were sent" must be measurable from outside the
    /// process, and safe for the LISTEN_MANAGED reason: a Finder launch
    /// inherits no shell environment.
    private static var endpointOverride: String? {
        ProcessInfo.processInfo.environment["LISTEN_TELEMETRY_ENDPOINT"]
    }

    // MARK: - Lifecycle

    private static var started = false

    /// At launch, and again at the moment consent flips to yes. Idempotent,
    /// and a no-op in every state but "consented and not blocked".
    static func startIfConsented() {
        // Reported before the guard, not after: the release gate's whole job
        // is to keep this function a no-op on a local build, so the one
        // thing worth being able to check from outside the process is
        // exactly the branch that guard is about to take. Same flag as the
        // allowlist self-test below; both are "assert what this run would
        // have done," and a script has no reason to learn two of them.
        if ProcessInfo.processInfo.environment["LISTEN_TELEMETRY_SELFTEST"] == "1" {
            trace("TELEMETRY_SELFTEST isReleaseBuild=\(isReleaseBuild) blocked=\(blocked)")
        }
        guard enabled, !started else { return }

        let host = endpointOverride ?? TelemetrySchema.host
        let token = TelemetrySchema.projectToken.isEmpty
            ? "phc_local_test" : TelemetrySchema.projectToken
        let config = PostHogConfig(projectToken: token, host: host)

        // Anonymous events only. No person profiles, no identify anywhere, so
        // the distinct id stays the SDK's random per-install value: created on
        // first start, cleared by reset() when consent is withdrawn, fresh if
        // consent is ever granted again. That id is the install identity
        // TELEMETRY.md describes; nothing else stands in for a person.
        config.personProfiles = .never

        // The SDK's conveniences default on, and every one of them would send
        // something this file never decided to. Each is turned off here rather
        // than trusted to stay off, and the beforeSend filter below is the net
        // under this list going stale in a future SDK.
        config.captureApplicationLifecycleEvents = false
        config.captureScreenViews = false
        config.preloadFeatureFlags = false
        config.sendFeatureFlagEvent = false

        // The one automatic capture that is wanted: native crashes. Only ever
        // armed after consent, because this whole object only exists then.
        config.errorTrackingConfig.autoCapture = true

        // The allowlist, applied last before anything is queued. An event not
        // in the schema is dropped whole; a property not in its event's row is
        // stripped. This is what makes TELEMETRY.md checkable.
        config.setBeforeSend { event in filter(event) }

        PostHogSDK.shared.setup(config)
        registerSuperProperties()
        started = true

        selfTestIfAsked()
    }

    /// Everything stamped onto every event. Re-registered at each start so
    /// the install age bucket moves as the install ages.
    private static func registerSuperProperties() {
        var props: [String: Any] = [
            "platform": "mac",
            "app_build": AppInfo.version ?? "unknown",
            "os_major": ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            "install_age_bucket": TelemetrySchema.installAgeBucket(days: participationDays),
            "schema_version": TelemetrySchema.schemaVersion,
        ]
        if let channel = Settings.telemetryChannel {
            props["acquisition_channel"] = channel
        }
        PostHogSDK.shared.register(props)
    }

    /// Days since consent was granted, which is what "install age" means
    /// here: participation age, not disk age. Coarse buckets downstream.
    private static var participationDays: Int {
        guard let since = Settings.telemetryConsentedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(since) / 86400))
    }

    /// The consent transition, in one place. Yes creates the identity and
    /// announces the activation; no tears the identity down and deletes what
    /// is queued. Both directions leave the SDK in a state the next launch
    /// reproduces from the stored consent alone.
    private static func apply(from old: Bool?, to new: Bool?) {
        switch (old == true, new == true) {
        case (false, true):
            Settings.telemetryConsentedAt = Date()
            startIfConsented()
            guard started else { return }
            PostHogSDK.shared.optIn()
            PostHogSDK.shared.capture(
                TelemetrySchema.Event.installationActivated.rawValue)
        case (true, false):
            guard started else { return }
            // Opt out first so nothing new is queued, then reset, which drops
            // the queue and the distinct id together. What was never sent is
            // gone, and a later yes starts as a brand new install.
            PostHogSDK.shared.optOut()
            PostHogSDK.shared.reset()
            Settings.telemetryConsentedAt = nil
        default:
            break
        }
    }

    // MARK: - The allowlist

    /// Keep an event only if the schema names it, and strip every property
    /// the schema does not grant it. `$exception` is the SDK's own crash
    /// event and passes with its `$exception_*` payload; `$device_name` is a
    /// personal name and never passes anything.
    private static let allowedDollarProps: Set<String> = [
        "$os_version", "$os_name", "$app_version", "$app_build", "$app_name",
        "$lib", "$lib_version", "$is_identified", "$process_person_profile",
    ]

    static func filter(_ event: PostHogEvent) -> PostHogEvent? {
        if event.event == "$exception" {
            event.properties.removeValue(forKey: "$device_name")
            return event
        }
        guard let allowed = TelemetrySchema.allowedProperties[event.event] else {
            return nil
        }
        for key in event.properties.keys {
            if allowed.contains(key) { continue }
            if TelemetrySchema.superProperties.contains(key) { continue }
            if allowedDollarProps.contains(key) { continue }
            if key.hasPrefix("$exception_") { continue }
            event.properties.removeValue(forKey: key)
        }
        return event
    }

    // MARK: - Capture surface

    private static func capture(_ event: TelemetrySchema.Event,
                                _ properties: [String: Any] = [:]) {
        guard enabled, started else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
    }

    /// One summary at the end of setup. Choices, never contents.
    static func setupCompleted(micGranted: Bool, model: String,
                               dictationOn: Bool, syncOn: Bool, calendarOn: Bool) {
        capture(.setupCompleted, [
            "mic_granted": micGranted,
            "model": model,
            "dictation_on": dictationOn,
            "sync_on": syncOn,
            "calendar_on": calendarOn,
        ])
    }

    /// A capture this Mac made landed in the library. The caller guards
    /// provenance; this guards content: only the kind, the mapped source app
    /// label and a duration bucket survive the trip.
    static func recordingCompleted(_ recording: Recording) {
        capture(.recordingCompleted, [
            "kind": TelemetrySchema.recordingKind(source: recording.metadata.source),
            "source_app": TelemetrySchema.sourceAppLabel(bundleID: recording.appBundleID),
            "duration_bucket": TelemetrySchema.durationBucket(
                seconds: recording.metadata.duration ?? 0),
        ])
    }

    /// A transcription run ended, either way. `outcome` is "ok" or a stable
    /// code from `code(for:)`, never a description. The processing time is
    /// read from the recording's own provenance stamps, so the caller cannot
    /// hand over a number the recording does not carry.
    static func recordingTranscribed(_ recording: Recording, outcome: String) {
        let duration = recording.metadata.duration ?? 0
        var props: [String: Any] = [
            "outcome": outcome,
            "asr_model": recording.metadata.asr_model ?? "unknown",
            "duration_bucket": TelemetrySchema.durationBucket(seconds: duration),
            "kind": TelemetrySchema.recordingKind(source: recording.metadata.source),
            "speaker_count": TelemetrySchema.cappedSpeakerCount(
                People.speakers(in: recording).count),
            "track_layout": recording.metadata.room == true ? "mic_only" : "mic_and_system",
        ]
        let iso = ISO8601DateFormatter()
        if let startStamp = recording.metadata.transcribe_started,
           let endStamp = recording.metadata.transcribe_finished,
           let start = iso.date(from: startStamp), let end = iso.date(from: endStamp) {
            props["processing_bucket"] = TelemetrySchema.processingBucket(
                processingSeconds: end.timeIntervalSince(start),
                durationSeconds: duration)
        }
        capture(.recordingTranscribed, props)
    }

    /// A stable, content-free code for an error. Type-level rather than
    /// case-level on purpose for the first version: it can never carry a
    /// path or a filename, and the per-case detail lives in the local log.
    static func code(for error: Error) -> String {
        switch error {
        case is ASRError: return "transcription.asr_failed"
        case is PipelineError: return "transcription.pipeline_failed"
        case is DiarizerError: return "transcription.diarization_failed"
        case is CaptureError: return "capture.failed"
        case is URLError: return "network.failed"
        default: return "unknown"
        }
    }

    static func dictationCompleted(duration: Double, wordCount: Int, engine: String) {
        capture(.dictationCompleted, [
            "duration_bucket": TelemetrySchema.dictationDurationBucket(seconds: duration),
            "word_count_bucket": TelemetrySchema.wordCountBucket(wordCount),
            "engine": engine,
        ])
    }

    static func featureUsed(_ feature: TelemetrySchema.Feature) {
        capture(.featureUsed, ["feature": feature.rawValue])
    }

    /// One content-free performance summary for one completed Ask turn. Exact
    /// timings remain in the local logs; PostHog receives only the public model
    /// choice, fixed backend/scope labels, counts and coarse buckets.
    static func askCompleted(outcome: TelemetrySchema.AskOutcome,
                             backend: TelemetrySchema.AskBackend,
                             model: String,
                             scope: String,
                             run: AgentRun.Outcome,
                             zdr: Bool?) {
        var properties: [String: Any] = [
            "outcome": outcome.rawValue,
            "backend": backend.rawValue,
            "model": model,
            "scope": scope,
            "latency_bucket": run.durationMS.map {
                TelemetrySchema.askLatencyBucket(milliseconds: $0)
            } ?? "unknown",
            "tool_call_count": TelemetrySchema.cappedAskCount(run.toolCalls),
            "request_size_bucket": TelemetrySchema.askRequestSizeBucket(
                bytes: run.largestRequestBytes),
            "prompt_tokens_bucket": TelemetrySchema.askTokenBucket(run.promptTokens),
            "completion_tokens_bucket": TelemetrySchema.askTokenBucket(
                run.completionTokens),
            "cost_bucket": TelemetrySchema.askCostBucket(usd: run.costUSD),
            "reference_count_bucket": "unknown",
        ]
        if let rounds = run.providerRounds {
            properties["round_count"] = TelemetrySchema.cappedAskCount(rounds)
        }
        if let retries = run.providerRetries {
            properties["retry_count"] = TelemetrySchema.cappedAskCount(retries)
        }
        if let zdr { properties["zdr"] = zdr }
        capture(.askCompleted, properties)
    }

    static func failure(_ subsystem: TelemetrySchema.Subsystem, code: String,
                        retryable: Bool = false) {
        capture(.operationFailed, [
            "subsystem": subsystem.rawValue,
            "code": code,
            "retryable": retryable,
        ])
    }

    static func setChannel(_ channel: TelemetrySchema.AcquisitionChannel?) {
        Settings.telemetryChannel = channel?.rawValue
        guard enabled, started else { return }
        registerSuperProperties()
    }

    // MARK: - Self test

    /// `LISTEN_TELEMETRY_SELFTEST=1` sends one event the schema knows and one
    /// it does not. The verify script watches its listener for exactly the
    /// first. In the debug environment only because that is the only place it
    /// means anything.
    private static func selfTestIfAsked() {
        guard ProcessInfo.processInfo.environment["LISTEN_TELEMETRY_SELFTEST"] == "1"
        else { return }
        PostHogSDK.shared.capture(TelemetrySchema.Event.featureUsed.rawValue,
                                  properties: ["feature": "note_saved",
                                               "smuggled_title": "must not survive"])
        PostHogSDK.shared.capture("off_schema_event",
                                  properties: ["anything": "must not arrive"])
        PostHogSDK.shared.flush()
    }
}

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

extension Settings {
    fileprivate static let telemetryConsentKey = "telemetryConsent"
    private static let telemetryChannelKey = "telemetryChannel"
    private static let telemetryPromptedKey = "telemetryPrompted"
    private static let telemetryConsentedAtKey = "telemetryConsentedAt"
    private static let lastSeenVersionKey = "lastSeenVersion"

    /// The acquisition channel the user chose to name, raw value of
    /// `TelemetrySchema.AcquisitionChannel`. Absent when they did not, and
    /// "prefer not to say" is that absence rather than a value.
    static var telemetryChannel: String? {
        get { defaults.string(forKey: telemetryChannelKey) }
        set {
            if let newValue, !newValue.isEmpty {
                defaults.set(newValue, forKey: telemetryChannelKey)
            } else {
                defaults.removeObject(forKey: telemetryChannelKey)
            }
        }
    }

    /// The one-time prompt for existing installs has fired. Written whatever
    /// the answer was, including the sheet being closed: one-time is a
    /// promise, and the Settings toggle is the only path back.
    static var telemetryPrompted: Bool {
        get { defaults.bool(forKey: telemetryPromptedKey) }
        set { defaults.set(newValue, forKey: telemetryPromptedKey) }
    }

    /// When consent was granted, driving the install age bucket. Cleared on
    /// withdrawal so a later yes ages from its own day, matching the fresh
    /// identity it gets.
    static var telemetryConsentedAt: Date? {
        get { defaults.object(forKey: telemetryConsentedAtKey) as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: telemetryConsentedAtKey) }
            else { defaults.removeObject(forKey: telemetryConsentedAtKey) }
        }
    }

    /// The version this app last ran as, stamped at every launch after being
    /// read. Nothing recorded "an update just happened" before this key:
    /// `Updater.recall` only sees versions Sparkle was mid-delivery on.
    static var lastSeenVersion: String? {
        get { defaults.string(forKey: lastSeenVersionKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: lastSeenVersionKey) }
            else { defaults.removeObject(forKey: lastSeenVersionKey) }
        }
    }
}
