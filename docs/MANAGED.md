# Managing Listen with a device profile

Listen reads a handful of settings as managed preferences. An organisation
that pushes a configuration profile for the `com.mgo.listen` domain can force
them, and a forced setting wins over anything the panes or the CLI stored:
the control that would change it is disabled, with a sentence saying the
device profile decided.

There is no schema of Listen's own. The keys are the app's ordinary
preference keys, forced through the standard managed-preferences payload
(`com.apple.ManagedClient.preferences`), so any MDM that can force a plist
key can manage Listen. [`listen-managed.mobileconfig`](listen-managed.mobileconfig)
is a complete sample.

## The keys

| key | type | when forced |
|---|---|---|
| `cloudSync` | boolean | `false` keeps the library off iCloud entirely. The Sync pane checkbox is disabled, `listen sync enable` is refused, and nothing is uploaded. The reason a regulated deployment wants this: Apple signs no Business Associate Agreement for iCloud, so a library holding regulated data must not sync through it. |
| `agentLoopbackOnly` | boolean | `true` restricts Ask to endpoints on the Mac itself, such as Ollama or LM Studio. Hosted providers cannot be added, ones added earlier are refused at run time, and the Claude and Codex backends are refused outright, because both send the meetings you ask about to their own service. |
| `dictationHistoryDisabled` | boolean | `true` stops `dictations.jsonl` being written. Dictation itself keeps working; the plaintext history file is the part a managed deployment usually does not want. |
| `backupsDisabled` | boolean | `true` stops the daily copies under `~/Backups/Listen`. |
| `backupsPath` | string | Moves the daily copies, for example onto an encrypted volume. |
| `telemetryDisabled` | boolean | `true` switches the anonymous usage statistics off for good: the PostHog SDK is never constructed, and the Privacy pane's checkbox is disabled with a note naming the profile. Telemetry is on by default and never carries content (see [TELEMETRY.md](../TELEMETRY.md)); forcing it off removes even the option, which is the posture a regulated deployment usually wants. |

## Installing the sample

Modern macOS does not install configuration profiles from the command line.
Open the `.mobileconfig` (double-click, or `open listen-managed.mobileconfig`),
then approve it in System Settings, General, Device Management. Through an
MDM, push the same payload.

## Verifying it took

```sh
profiles list
defaults read "/Library/Managed Preferences/$USER/com.mgo.listen"
```

Then, in Listen: the Sync pane shows the sync checkbox disabled with a
note; `listen provider add openrouter` is refused with the reason;
`listen ask` on a Claude or Codex backend is refused before the process
starts; dictate something and confirm `dictations.jsonl` did not grow.

For scripts and CI there is an environment seam that behaves exactly like a
profile: `LISTEN_MANAGED='{"cloudSync": false, "agentLoopbackOnly": true}'`.
A Finder launch inherits no shell environment, so this cannot be used to fake
a profile on a real deployment.

## iPhone

The iPhone app has no managed keys yet. On a supervised device the same
outcome is reached by not signing the device into iCloud, which is the only
network surface the app has.
