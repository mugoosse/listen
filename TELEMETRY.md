# What Listen's telemetry sends, exactly

Listen sends anonymous usage statistics and crash reports by default, and
Settings, Privacy is where you turn it off. This file is the complete
dictionary: every event, every property,
every bucket boundary. An event or property that is not written down here is
not merely undocumented, it is dropped before it leaves your device, by a
filter compiled from the same file both apps share:
[`Sources/ListenKit/TelemetrySchema.swift`](Sources/ListenKit/TelemetrySchema.swift).

The policy in one sentence, borrowed from the app's own activity log: events
and ids, never names, questions or transcript text.

## What is never sent

Audio, transcripts, notes, titles, speaker or contact names, tags, dictionary
terms, search text, Ask questions or answers, calendar contents, recording or
CloudKit identifiers, file paths, URLs, API keys, raw error messages, and the
device's name. Not as a promise of restraint: the send filter strips
everything outside the tables below, and the filter's source is public.

## Where it goes, and as whom

- Host: `eu.i.posthog.com` (PostHog Cloud, EU region). PostHog is the
  processor; the project is configured to discard client IP addresses at
  ingestion, so location is kept only as a country.
- Identity: a random install ID the PostHog SDK generates the moment
  telemetry turns on. It is not derived from anything, it is never synced
  between your devices (a Mac and an iPhone are two installs, deliberately),
  it is deleted the moment you turn telemetry off, and turning it back on
  later creates a fresh one.
- There are no accounts, no person profiles, no cookies, no session replay,
  no cross-site or cross-app tracking, and no advertising identifiers.

## Consent

- Every install is on by default. A one-time, unconditional migration turns
  it on the first time a build carrying this behaviour launches, overriding
  even an earlier no from before that build existed. There is no question on
  either platform any more; the migration is the whole mechanism.
- The switch afterwards is Settings, Privacy on both platforms. Turning it
  off stops the sending, deletes anything still queued, and deletes the
  install ID. Turning it back on later creates a fresh one.
- Organisations can force it off for managed Macs with the `telemetryDisabled`
  key; see `docs/MANAGED.md`. A forced-off Mac never runs the migration.
- A build with no project token configured sends nothing regardless of the
  switch.
- **A build made for day-to-day development, on either platform, never sends
  to the real project, whatever the switch says.** On the Mac this means a build
  from `./build.sh && ./make_app.sh` run by hand: only `release.sh` marks a
  build as released, by asking `make_app.sh` to stamp `ListenReleaseBuild`
  into `Info.plist`, and `Telemetry.blocked` requires that key. On iOS this
  means a build Xcode ran directly, on the Simulator or on a real phone,
  debug or release configuration alike: only a copy installed through
  TestFlight or the App Store carries an installation receipt at all, and
  `Telemetry.blocked` requires one. Both checks step aside for
  `LISTEN_TELEMETRY_ENDPOINT`, which is how `verify_telemetry.sh` and manual
  testing point telemetry at a chosen host on purpose; neither can be talked
  into reaching the real one.

## Properties on every event

| Property | Values |
|---|---|
| `platform` | `mac` or `iphone` |
| `app_build` | the app version, e.g. `0.16.0` |
| `os_major` | the OS major version, e.g. `26` |
| `install_age_bucket` | `day_0`, `week_1`, `month_1`, `month_2_3`, `over_3_months`, measured from the day you opted in |
| `acquisition_channel` | only if you answered "How did you hear about Listen?": `github`, `homebrew`, `app_store`, `search`, `reddit`, `hacker_news`, `youtube_podcast`, `friend`, `other` |
| `schema_version` | this dictionary's version, currently 2 |

The SDK also stamps its own context: OS name and version, app version and
build, and SDK name and version. Nothing else of its automatic context
survives the filter, and `$device_name` is stripped explicitly.

## Events

### `installation_activated`
Once, at the moment consent first becomes yes. No properties beyond the
common ones.

### `setup_completed`
Once, at the end of setup. `mic_granted` (bool), `model` (model id or
`none`), `dictation_on` (bool), `sync_on` (bool), `calendar_on` (bool).
Choices, never contents.

### `recording_completed`
When a capture made on that device lands in its library. Only the device
that made a recording counts it; one arriving over sync is never counted
again.

| Property | Values |
|---|---|
| `kind` | `meeting`, `memo`, `phone_memo`, `import`, `cli` |
| `source_app` | `zoom`, `teams`, `slack`, `facetime`, `discord`, `whatsapp`, `telegram`, `signal`, `webex`, `browser`, `other`, `none`. Mapped from the call's app bundle id through a fixed table; anything unrecognised is `other`, never the raw id |
| `duration_bucket` | `under_1_min`, `1_5_min`, `5_15_min`, `15_30_min`, `30_60_min`, `1_2_h`, `over_2_h` |

### `recording_transcribed`
When a transcription run ends, on the Mac that ran it, whether it worked.
Fires for phone memos too, on the transcribing Mac. Transcription failures
ride this event's `outcome` and are deliberately not doubled into
`operation_failed`.

| Property | Values |
|---|---|
| `outcome` | `ok`, or a stable code: `transcription.asr_failed`, `transcription.pipeline_failed`, `transcription.diarization_failed`, `network.failed`, `unknown` |
| `asr_model` | the model id, or `unknown` |
| `duration_bucket` | as above |
| `processing_bucket` | transcription time as a fraction of the audio's length: `under_0_1x`, `0_1_to_0_25x`, `0_25_to_0_5x`, `0_5_to_1x`, `over_1x` |
| `speaker_count` | distinct diarized voices, capped at 12 |
| `track_layout` | `mic_only` or `mic_and_system` |
| `kind` | as above |

### `dictation_completed`
When a dictation lands. `duration_bucket` (`under_5_s`, `5_15_s`, `15_30_s`,
`30_60_s`, `over_1_min`), `word_count_bucket` (`1_5`, `6_20`, `21_50`,
`51_100`, `over_100`), `engine` (`parakeet` or `apple`). Never the words.

### `ask_completed`
One event after one Ask question succeeds or fails. It never contains the
question, answer, transcript, title, source ids, quotes, or a conversation/run
identifier. The event is deliberately a performance summary rather than a
trace: exact timings and fixed tool names stay in the device's unified log.

| Property | Values |
|---|---|
| `outcome` | `ok`, `timeout`, `offline`, `provider_error`, `ungrounded`, `invalid_evidence`, `too_many_rounds` |
| `backend` | `openrouter`, `claude_code`, `codex`, `local_endpoint`, `remote_endpoint` |
| `model` | a model id the selected backend advertised, `default`, or `custom`. User-authored custom model text is never sent |
| `scope` | `library`, `recording`, `person`, `note` |
| `latency_bucket` | `under_2_s`, `2_5_s`, `5_15_s`, `15_30_s`, `30_60_s`, `60_90_s`, `over_90_s`, or `unknown` |
| `round_count` | provider rounds, capped at 24; absent when a CLI harness does not expose it |
| `retry_count` | provider retries, capped at 24; absent when the harness does not expose it |
| `tool_call_count` | tool calls, capped at 24 |
| `local_read_count` | local library reads, capped at 24; currently available on iPhone |
| `request_size_bucket` | `under_16_kb`, `16_32_kb`, `32_64_kb`, `64_128_kb`, `over_128_kb`, or `unknown` |
| `prompt_tokens_bucket`, `completion_tokens_bucket` | `under_1k`, `1_4k`, `4_16k`, `16_64k`, `over_64k`, or `unknown` |
| `cost_bucket` | `under_0_001_usd`, `0_001_0_005_usd`, `0_005_0_02_usd`, `0_02_0_10_usd`, `over_0_10_usd`, or `unknown` |
| `reference_count_bucket` | `0`, `1`, `2_4`, `5_plus`, or `unknown` |
| `zdr` | bool; present for OpenRouter, whose requests require Zero Data Retention |

### `feature_used`
A closed list, and the fact only: `note_saved` (never the note), `sync_enabled`, `dictation_enabled`,
`calendar_connected`, `share_export`, `import`, `iphone_capture`,
`keep_audio_toggle`.

### `operation_failed`
`subsystem` (`capture`, `model_download`, `sync`, `dictation`, `library`),
`code` (a fixed identifier such as `model_download.failed` or
`sync.pass_failed`), `retryable` (bool). Error text never travels: a raw
error message routinely contains file names, and file names are content.
Sync failures are edge-triggered, one event when a failure starts rather
than one per retry.

### `$exception`
A crash report: stack trace, app build, OS version. Captured by the PostHog
SDK, only while turned on, so a crash before that is never reported. The
`$device_name` the SDK would attach is stripped.

## Bucket midpoints

Dashboards that sum hours use the midpoint of each duration bucket: 0.5, 3,
10, 22.5, 45, 90 and 150 minutes respectively. Buckets are never re-cut
silently; a change bumps `schema_version` and is noted here.

## Retention and publication

Event data is retained in PostHog for at most 12 months. Anything published
from it (a "users transcribed X hours" style statistic) is aggregate only,
says it comes from installs with telemetry on, and uses no cohort smaller
than 50 installs.

## Verifying all of this

- The allowlist is code, in `Sources/ListenKit/TelemetrySchema.swift`, and
  both apps compile it in.
- `verify_telemetry.sh` in this repository launches the built app against a
  local listener and asserts that a fresh install migrates itself on with no
  question asked, that the migration overrides even a prior no, that a no
  recorded after migration produces zero requests, and that off-schema
  events and properties never arrive.
- `InternetAccessPolicy.plist` declares the PostHog host to firewalls such as
  Little Snitch, with what blocking it costs: nothing but the statistics.
