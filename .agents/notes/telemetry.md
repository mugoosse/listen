# Telemetry

What Listen sends, and what reading it back for the first time proved wrong.
`Telemetry`, `TelemetrySchema`, `TELEMETRY.md`, `verify_telemetry.sh`, the
PostHog project.

Everything here is measured against the first five days of production data
(2026-08-27 to 2026-08-31, PostHog project 259056, 371 events, 7 installs).
That window is small and 90% of it is one install, so the numbers below are
evidence about the *instrumentation*, not about users.

## The reader is the developer, and that is most of the data

One install sent 338 of the first 371 events: 149 dictations, 167 sync
failures. Every unfiltered aggregate describes whoever is writing the code.
The project has a cohort `Internal / Test users` wired into
`test_account_filters` as `not_in`, and it is **empty**, so "filter test
accounts" currently excludes nobody.

Filling it is not the obvious job it looks: `config.personProfiles = .never`
means there are no person profiles at all, so a property-based dynamic cohort
has nothing to match on. That is not a thing to fix in the cohort, because a
cohort is a set of *persons* and this project has none.

**The filter that works is a HogQL entry in `test_account_filters` itself**,
which needs no cohort and no person:

```json
{"key": "distinct_id != '<the install id>'", "type": "hogql", "value": null}
```

Set through `project-settings-update`, alongside the existing cohort entry.
Measured after applying it: `dictation_completed`, which only this install has
ever sent, went from 205 to 0 with `filterTestAccounts: true`, and
`recording_completed` came back as 4, which is exactly the number the other
three installs made. It removes the one install and nothing else.

**Two things it does not do.** It does not touch `execute-sql`, which ignores
`test_account_filters` entirely, so every raw SQL query in this file's
measurements still counts everybody and has to exclude the id by hand. And it
goes stale silently: the install id is the SDK's random per-install value,
deleted when telemetry is turned off and regenerated fresh when it is turned
back on, so a reinstall, a new Mac, or one trip through the Privacy switch
produces a new id that the filter does not name. Nothing warns about this. The
symptom is a dictation count that is suddenly not zero.

## Nothing said which install was yours, and that is why the filter is guesswork

The events carry no device name, on purpose, and the install ID was never
shown anywhere. So neither the person reading the project nor the person who
owns the Macs could say which rows belonged to whom: the only evidence was
circumstantial timing, such as an iPhone activating 42 minutes after a Mac on
the day telemetry was written.

`Telemetry.installID` now surfaces it in Settings, Privacy and through `listen
telemetry`. The CLI half is the one that matters for this job: a second Mac
reached over SSH has no settings pane to click, and a machine in a drawer is
exactly the one whose rows are hardest to account for.

`listen telemetry` also distinguishes the three ways nothing is being sent,
because they look identical from outside and are fixed differently: forced off
by a device profile, switched off, or a build nobody released. It prints
`Telemetry.destination` rather than `TelemetrySchema.host`, so an endpoint
override is not quietly reported as the real project.

## Development builds cannot be in this data, and it is worth knowing why

`install.sh` calls `make_app.sh` with no `LISTEN_RELEASE_BUILD`, and
`make_app.sh` only writes the `ListenReleaseBuild` key when that variable is
`1`, which only `release.sh` sets. Without the key `Telemetry.blocked` is
true. `verify_telemetry.sh` uses `LISTEN_TELEMETRY_ENDPOINT` and reaches
localhost. So every install in the project is a released build, and "maybe
that row is a test build" is never the explanation for anything.

The corollary is the one that surprises: a developer's own
`/Applications/Listen.app` **is** a release build, so their daily driver is in
the data like anybody else's, and is usually the loudest install in it.

## A per-application firewall makes this blind, and a `curl` test will not find it

One install sent its `installation_activated` and then nothing at all for
three days, while the person using it was dictating daily. Every app-side gate
was healthy: consent had never been toggled (the install ID was unchanged, and
turning telemetry off deletes it), the SDK was started, the build was a
released one. The events were being captured and not delivered.

The cause was a Little Snitch rule on `posthog.com` for Listen.

**The diagnostic that wasted the time was `curl` against the host.** It
returned 400 from the affected Mac, exactly matching a healthy control, and
400 is the right answer there because that endpoint wants a POST. But Little
Snitch rules are **per application**: curl is not Listen, so it has its own
rule and sailed through. A host-reachability test from a different process
says nothing about whether the app is allowed out. Ask for the firewall's view
of *the app*, or have somebody read `listen telemetry` on the machine; do not
ask for a curl.

Two consequences worth keeping.

**Every count in this project is a floor, and the shortfall is not random.**
The people who block an analytics host are exactly the people a local-first
meeting recorder attracts, so the missing population is correlated with the
audience. "Nobody outside these installs has ever dictated" was true of the
data and false about the world.

**This is not a bug to fix.** `InternetAccessPolicy.plist` declares the host
to firewalls precisely so somebody can make this choice, and says blocking it
costs nothing but the statistics. That promise has to keep being true, so
nothing here may retry around a block, fall back to another host, or report
the refusal as an error. Being invisible is the feature working.

The one thing that is worth improving is that the app cannot tell its owner
delivery is failing. `listen telemetry` says whether telemetry is *on*, not
whether anything has ever arrived, and those are different questions.

## `app_build` is VERSION at build time, so a pre-release build pollutes it

83 events arrived stamped `0.21.0`, a version telemetry never shipped in: the
telemetry commit `e8b445f` landed 2026-08-27, one day *after* the v0.21.0 tag.
A release-stamped build made by hand before `VERSION` was bumped sends under
the old number, and nothing downstream can tell it from the real release.

Only `release.sh` sets `ListenReleaseBuild`, so this can only ever be a
developer's own machine, but it means `app_build` is not a safe axis to split
on without checking the value against the tag list first.

## `installation_activated` counted the back catalogue, and the age bucket could not tell

The event fires on the consent flip (`Telemetry.apply(from:to:)`), and
`migrateToDefaultOnIfNeeded()` flips consent for every install on first launch
of any 0.22.0+ build. So an upgrade is indistinguishable from an install, and
the count is a floor on the installed base rather than acquisition.

`install_age_bucket` cannot disambiguate it either: it is measured from the
opt-in day, so the entire population reads `day_0` or `week_1` no matter how
old the install is.

The discriminator was already on disk. `Settings.isFirstRun` is the absence of
the `onboarded` key, which predates telemetry by three weeks, so every
upgrading install has it and a genuinely new one does not. It is still
accurate at `AppDelegate:187` where the migration runs, because
`Onboarding.show()` only orders a window front and the key is not written
until setup ends. That is now the `activation` property
(`new_install` / `existing`), asserted in both directions by
`verify_telemetry.sh` cases 1 and 2.

`existing` rather than `migrated`, because turning telemetry back on from the
Privacy pane lands in the same branch and is not a migration.

## Closing the setup window is a finish, and the funnel could not see it

`Onboarding.windowWillClose` sets `Settings.onboarded = true` without sending
anything, so anyone who walked away from setup was simply absent from the
data. Six activations against one `setup_completed` read as an onboarding
cliff; part of it was people the event was never able to describe.

`setup_completed` now carries `outcome` (`finished` / `dismissed`) and fires
on both paths. The guard matters: `finish()` sets `onboarded` before ordering
the window out, so `windowWillClose` only sends `dismissed` when `onboarded`
is still false, or a completed run would report itself twice.

Note it was never once per install anyway: re-running setup from Settings
sends it again.

## The model a run used is not the model on the recording

`asr_model` came back `unknown` on 8 of the first 11 transcriptions, including
both runs from an install that had explicitly picked v2 during setup. The
event read `recording.metadata.asr_model ?? "unknown"`, and that field only
ever holds a model somebody chose on purpose (`Queue.enqueue` writes it only
when passed an explicit `choice`), so every default-path run reported nothing.

**The obvious fix is wrong.** Writing the model back onto the recording at the
end of a run would have fixed the reporting and broken Transcribe Again:
`Recording.asrModel` reads that field, so the recording would be pinned to
whatever ran first, and switching the default to v3 to re-run a meeting in
another language would silently use v2 again. That is the exact recovery path
`.agents/notes/asr.md` describes for a Dutch call transcribed by an
English-only model.

So the model is passed to `Telemetry.recordingTranscribed` as an argument
instead. The event learns what ran; the recording does not acquire an opinion
nobody gave it.

## A burst of sync failures was a throttle, and the edge trigger was right

186 `operation_failed` events, 100% of them `sync.pass_failed`. 183 came from
0.22.0, in bursts of 15 to 18 an hour for eleven hours straight. The poll runs
every two minutes, so that is roughly every other pass failing, recovering and
failing again.

The edge trigger at `CloudSyncHost.swift:328` is correct (`lastPassFailed` is
a process-lifetime property, so it really was one event per onset). The cause
was upstream: CloudKit answers a burst with a sub-second "slow down", and
0.22.0 counted that as a failed pass. 0.23.0 stopped doing so and made passes
cheaper, and the rate fell to 3 events over the next two days, all on one
machine.

The lesson for reading this event: **split `operation_failed` by `app_build`
before concluding anything.** Unsplit, it says sync is the biggest problem in
the product. Split, it says a fixed bug was the biggest problem two releases
ago.

## What the project keeps is not what the privacy page promises

`docs/privacy.html` tells the public the processor is "configured to discard
IP addresses at ingestion and to keep events for at most 12 months", and
`TELEMETRY.md` adds "location is kept only as a country". Measured against
project 259056:

- **IP discarding is real.** `anonymize_ips: true`, and `$ip` is absent from
  every one of the 371 events.
- **Retention is not, and cannot be.** `event_retention_months: 84`, with
  `events_retention_enforced: false`. PostHog has no time-based event deletion
  to switch on: the feature request (PostHog/posthog#17031) has been open
  since 2023. Checked three ways, because it is the kind of claim worth being
  sure about: the field is absent from `project-settings-update`'s schema, the
  UI has no such control under General or Product analytics, and the only
  retention controls on the plan at all are for Logs (14 day, 30 day add-on).
  Both documents now say events are kept indefinitely, because a promise
  nothing enforces is worth less than an accurate sentence.
- **Location was not, and pausing GeoIP only half fixed it.** GeoIP enrichment
  runs before the IP is discarded, so every event carried
  `$geoip_city_name`, `$geoip_postal_code`, `$geoip_subdivision_1_*`,
  `$geoip_latitude` and `$geoip_longitude`.

  Pausing the GeoIP transformation (Data, Transformations; a UI action with no
  API behind it) removed `$geoip_city_name` and `$geoip_postal_code`, and
  **that is all it removed**. The first event ingested afterwards still
  carried `$geoip_country_*`, `$geoip_continent_*`, `$geoip_subdivision_1_*`,
  `$geoip_time_zone`, `$geoip_accuracy_radius`, `$geoip_latitude` and
  `$geoip_longitude`. So "kept only as a country" was still false after the
  change that was supposed to make it true.

  The general lesson: pausing a transformation is not disabling enrichment,
  because some of it is the ingestion pipeline's own work rather than the
  transformation's. TELEMETRY.md now describes the region-level data that
  actually arrives. The untried lever is `$geoip_disable` as an event
  property, which would also need adding to `allowedDollarProps`; it is not in
  the docs this repo checked, so it needs proving against a real ingest before
  anything is claimed for it.

The send filter itself is sound, and this is worth stating because it is the
part the repo can prove: an audit of every property key that arrived
(`SELECT arrayJoin(JSONExtractKeys(properties))`) found nothing outside the
allowlist, and no `$device_name`. Everything above is the processor's doing,
not the app's, which is exactly why the claims about it need checking against
the project rather than against the code.

## `$exception` has never fired

`config.errorTrackingConfig.autoCapture = true` arms it, and zero crash
reports have arrived in five days across seven installs. That is consistent
with no crashes and consistent with the path being broken, and nothing in the
data separates the two. It is unproven end to end in production.
