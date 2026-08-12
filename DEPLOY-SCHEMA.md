# Before you deploy the schema to Production

One page, because this is the only step in the CloudKit migration that cannot
be undone.

Production schema is **append-only, for ever**. You can add a record type or a
field. You can never remove one, never change a field's type, and never reset
the Production environment. Development can be wiped whenever you like;
Production is for the life of the container.

Everything else in this migration is reversible. This is not.

## What to check, and how

Run this on the Mac, with a build signed for Development:

```sh
cd ~/Documents/coding/macos-apps/listen
./build.sh && LISTEN_CLOUDKIT_ENV=development ./make_app.sh
./Listen.app/Contents/MacOS/Listen sync inspect
```

Expect, allowing for different counts:

```
container:   iCloud.eu.jacarandalabs.listen
environment: Production or Development

  z1: r1×3 r2×1 r3×2
  z2: r6×1
  z3: r4×2
  z4: empty

9 record(s). Nothing above was decrypted to print it.
```

Four zones and six record types, all of them opaque. `z4` is empty because a
transfer is deleted once a Mac holds the audio: that zone is a pipe, never a
store, and an empty one is the correct state rather than a missing one.

If any record name were readable, `sync inspect` would print `NAMES ARE NOT
OPAQUE` beside its zone. That check is the reason the command exists.

## Then, in the CloudKit Console

[icloud.developer.apple.com/dashboard](https://icloud.developer.apple.com/dashboard),
container `iCloud.eu.jacarandalabs.listen`, **Development**.

**Schema → Record Types.** There should be exactly six, and nothing else:

| type | is | lives in |
|---|---|---|
| `r1` | a recording | `z1` |
| `r2` | a note | `z1` |
| `r3` | a library file: `contacts.json`, `dictionary.json` | `z1` |
| `r4` | a device | `z3` |
| `r5` | audio in flight | `z4` |
| `r6` | a voiceprint | `z2` |

**Fields.** Only these, and no others:

- `payload` — Bytes. The sealed blob. Everything the product knows lives in
  here, which is what keeps this table short and what lets `metadata.json` gain
  a field for ever without touching CloudKit.
- `assetNames` — String List. Which assets a record carries. Absent on records
  that carry none, because CloudKit cannot infer a field's type from an empty
  list.
- `asset_transcript_json`, `asset_turns_json`, `asset_waveform_json`,
  `asset_mic_wav` — Asset. Sealed. Underscores rather than dots because a field
  key may not contain one.
- `claimedBy`, `claimExpires`, `audioOn` — String, Date, String. **The only
  three fields written by a device that did not author the content**, which is
  the whole reason they are readable at all.

**Two things to look at yourself rather than take from me**, because after this
they are permanent:

1. No record name anywhere is readable. Click into `z1` and look. You should
   see 64 hex characters and nothing that suggests a title or a date.
2. There is no field you do not recognise from the list above.

## Deploying

**Deploy Schema Changes…** in the left sidebar, Development → Production.

Then verify with a build signed the way the shipping build is signed, which is
the only configuration that proves anything about what ships:

```sh
./build.sh && ./make_app.sh          # no LISTEN_CLOUDKIT_ENV: Developer ID, Production
./Listen.app/Contents/MacOS/Listen sync status
```

`environment: Production` and `account: available`.

## After it

Production holds a schema and no records. Seeding is Phase 4 and is reversible:
switching sync off and deleting the zones discards the records, and nothing on
disk changes. The schema stays, which is the part that is permanent, and that
is the trade this page exists to make deliberate.

## If it goes wrong before you deploy

`Reset Environment…` wipes Development, schema and all. Re-run the sync and it
rebuilds from nothing. There is no such button for Production.
