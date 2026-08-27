# What Listen's telemetry sends, exactly

Listen can send anonymous usage statistics and crash reports, and only if you
opt in. This file is the complete dictionary: every event, every property,
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
- Identity: a random install ID the PostHog SDK generates the moment you opt
  in. It is not derived from anything, it is never synced between your
  devices (a Mac and an iPhone are two installs, deliberately), it is deleted
  when you opt out, and opting in again later creates a fresh one.
- There are no accounts, no person profiles, no cookies, no session replay,
  no cross-site or cross-app tracking, and no advertising identifiers.

## Consent

- New installs are asked at the end of setup, with nothing pre-ticked.
- Installs that predate the question are asked once, after updating. Closing
  the prompt counts as an answer; it never asks again.
- The switch afterwards is Settings, Privacy on both platforms. Turning it
  off stops the sending, deletes anything still queued, and deletes the
  install ID.
- Organisations can force it off for managed Macs with the `telemetryDisabled`
  key; see `docs/MANAGED.md`. A forced-off Mac never asks the question.
- A build with no project token configured sends nothing regardless of any
  answer.
- **A build made for day-to-day development, on either platform, never sends
  to the real project, whatever consent says.** On the Mac this means a build
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
| `schema_version` | this dictionary's version, currently 1 |

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

### `feature_used`
A closed list, and the fact only: `ask_question` (never the question),
`note_saved` (never the note), `sync_enabled`, `dictation_enabled`,
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
SDK, only while opted in, so a crash before consent is never reported. The
`$device_name` the SDK would attach is stripped.

## Bucket midpoints

Dashboards that sum hours use the midpoint of each duration bucket: 0.5, 3,
10, 22.5, 45, 90 and 150 minutes respectively. Buckets are never re-cut
silently; a change bumps `schema_version` and is noted here.

## Retention and publication

Event data is retained in PostHog for at most 12 months. Anything published
from it (a "users transcribed X hours" style statistic) is aggregate only,
says it comes from opted-in installs, and uses no cohort smaller than 50
installs.

## Verifying all of this

- The allowlist is code, in `Sources/ListenKit/TelemetrySchema.swift`, and
  both apps compile it in.
- `verify_telemetry.sh` in this repository launches the built app against a
  local listener and asserts that an unset or denied consent produces zero
  requests, and that off-schema events and properties never arrive.
- `InternetAccessPolicy.plist` declares the PostHog host to firewalls such as
  Little Snitch, with what blocking it costs: nothing but the statistics.
